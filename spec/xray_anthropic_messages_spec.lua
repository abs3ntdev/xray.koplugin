-- xray_anthropic_messages_spec.lua
-- Pure adapter for the experimental Claude subscription (anthropic_account).
require("spec/spec_helper")

describe("xray_anthropic_messages", function()
    local M, json
    local SID = "0123abcd-0000-4000-a000-000000000001"

    local function ev(t) return "event: " .. t.type .. "\ndata: " .. json.encode(t) .. "\n\n" end
    local function sse(text, stop_reason)
        return ev({ type = "message_start", message = { id = "m", role = "assistant", content = {} } })
            .. ev({ type = "content_block_start", index = 0, content_block = { type = "text", text = "" } })
            .. ev({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = text } })
            .. ev({ type = "content_block_stop", index = 0 })
            .. ev({ type = "message_delta", delta = { stop_reason = stop_reason or "end_turn" } })
            .. ev({ type = "message_stop" })
    end

    setup(function()
        json = require("json")
        M = require("xray_anthropic_messages")
    end)

    it("uses the real JSON codec", function()
        assert.are.same({ a = { 1, 2 } }, json.decode(json.encode({ a = { 1, 2 } })))
    end)

    describe("buildRequest", function()
        local req, body
        before_each(function()
            req = assert(M.buildRequest({ model = "claude-opus-5-5", prompt = "P", instructions = "I",
                access_token = "tok_SECRET", session_id = SID }))
            body = json.decode(req.body)
        end)

        it("pins endpoint, provider and secure/no-fallback tags", function()
            assert.are.equal("https://api.anthropic.com/v1/messages?beta=true", req.url)
            assert.are.equal("anthropic_account", req.provider)
            assert.is_true(req.secure)
            assert.is_true(req.no_fallback)
            assert.is_true(M.isPinnedRequest(req))
        end)

        it("sends pinned OAuth compatibility headers, no API key header", function()
            local h = req.headers
            assert.are.equal("Bearer tok_SECRET", h["Authorization"])
            assert.are.equal("2023-06-01", h["anthropic-version"])
            assert.is_truthy(h["anthropic-beta"]:find("oauth-2025-04-20", 1, true))
            assert.is_truthy(h["anthropic-beta"]:find("claude-code-20250219", 1, true))
            assert.are.equal("claude-cli/2.1.280 (external, sdk-cli)", h["User-Agent"])
            assert.are.equal("cli", h["x-app"])
            assert.are.equal(SID, h["X-Claude-Code-Session-Id"])
            assert.are.equal("text/event-stream", h["Accept"])
            assert.is_nil(h["x-api-key"])
        end)

        it("builds system blocks in Jcode provider order with no tools", function()
            assert.are.equal("claude-opus-5-5", body.model)
            assert.is_true(body.stream)
            assert.are.equal(3, #body.system)
            assert.are.equal("x-anthropic-billing-header: cc_version=2.1.280; cc_entrypoint=sdk-cli; cch=33f85;", body.system[1].text)
            assert.are.equal("You are a Claude agent, built on Anthropic's Claude Agent SDK.", body.system[2].text)
            assert.are.equal("I", body.system[3].text)
            assert.are.equal("user", body.messages[1].role)
            assert.are.equal("P", body.messages[1].content[1].text)
            assert.is_nil(body.tools)
            assert.is_nil(body.thinking)
            local uid = json.decode(body.metadata.user_id)
            assert.are.equal(SID, uid.session_id)
            assert.is_nil(req.body:find("tok_SECRET", 1, true))
        end)

        it("falls back to default model for unknown ids", function()
            local r = assert(M.buildRequest({ model = "gpt-6-luna", access_token = "t", session_id = SID }))
            assert.are.equal("claude-sonnet-5", json.decode(r.body).model)
            local s = assert(M.buildRequest({ model = "claude-sonnet-5-5", access_token = "t", session_id = SID }))
            assert.are.equal("claude-sonnet-5-5", json.decode(s.body).model)
            assert.are.same({ "claude-opus-5-5", "claude-sonnet-5", "claude-sonnet-5-5", "claude-haiku-4-5" }, M.MODELS)
        end)

        it("fails closed without token or session", function()
            local r, code = M.buildRequest({ session_id = SID })
            assert.is_nil(r); assert.are.equal("error_auth", code)
            r, code = M.buildRequest({ access_token = "t" })
            assert.is_nil(r); assert.are.equal("error_auth", code)
        end)

        it("rejects substituted endpoint or provider", function()
            req.url = "https://evil.example/v1/messages"
            assert.is_false(M.isPinnedRequest(req))
            local r2 = assert(M.buildRequest({ access_token = "t", session_id = SID }))
            r2.provider = "openai_account"
            assert.is_false(M.isPinnedRequest(r2))
        end)
    end)

    describe("decode/normalize", function()
        it("normalizes a completed stream to the choices envelope", function()
            local out, cleaned = M.normalizeStream(sse('{"characters":[{"name":"Ann"}]}'))
            assert.is_string(out)
            local data = json.decode(out)
            assert.are.equal('{"characters":[{"name":"Ann"}]}', data.choices[1].message.content)
            assert.are.equal(cleaned, data.choices[1].message.content)
        end)

        it("rejects a stream without message_stop", function()
            local s = sse('{"a":1}'):gsub("event: message_stop\ndata: [^\n]*\n\n", "")
            local out, code = M.normalizeStream(s)
            assert.is_nil(out); assert.are.equal("error_incomplete", code)
        end)

        it("rejects max_tokens truncation instead of repairing", function()
            local out, code = M.normalizeStream(sse('{"a":', "max_tokens"))
            assert.is_nil(out); assert.are.equal("error_incomplete", code)
        end)

        it("rejects tool use and malformed data", function()
            local s = ev({ type = "content_block_start", index = 0, content_block = { type = "tool_use", id = "x", name = "y" } })
            local out, code = M.normalizeStream(s)
            assert.is_nil(out); assert.are.equal("error_api", code)
            out, code = M.normalizeStream("data: {broken\n\n")
            assert.is_nil(out); assert.are.equal("error_parse", code)
            out, code = M.normalizeStream(sse("not json"))
            assert.is_nil(out); assert.are.equal("error_parse", code)
        end)

        it("maps stream errors, overload and rate limits safely", function()
            local out, code, msg = M.normalizeStream(ev({ type = "error", error = { type = "rate_limit_error", message = "Bearer tok_SECRET" } }))
            assert.is_nil(out); assert.are.equal("error_quota", code)
            assert.is_nil(msg:find("tok_", 1, true))
            out, code = M.normalizeStream(ev({ type = "error", error = { type = "overloaded_error" } }))
            assert.are.equal("error_api", code)
        end)

        it("classifies HTTP errors without echoing bodies", function()
            local body = '{"type":"error","error":{"type":"authentication_error","message":"tok_SECRET"}}'
            local code, msg = M.classifyHttpError(401, body)
            assert.are.equal("error_auth", code)
            assert.is_truthy(msg:find("authentication_error", 1, true))
            assert.is_nil(msg:find("tok_", 1, true))
            assert.are.equal("error_quota", (M.classifyHttpError(429, "")))
            assert.are.equal("error_api", (M.classifyHttpError(529, "<html>cf challenge</html>")))
            assert.are.equal("error_auth", (M.classifyHttpError(403, "<html>challenge</html>")))
        end)
    end)
end)
