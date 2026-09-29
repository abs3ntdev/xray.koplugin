-- xray_openai_responses_spec.lua
require("spec/spec_helper")

describe("OpenAI subscription Responses adapter", function()
    local Responses, json

    setup(function()
        json = require("json")
        Responses = require("xray_openai_responses")
    end)

    local function sse(events)
        local out = {}
        for _, ev in ipairs(events) do
            out[#out + 1] = "event: " .. (ev.type or "x") .. "\ndata: " .. json.encode(ev) .. "\n\n"
        end
        return table.concat(out)
    end

    describe("buildRequest", function()
        it("normalizes the complete Sol 6.1 effort matrix without sampling fields", function()
            for _, case in ipairs({
                { false, "medium" }, { "none", "low" }, { "minimal", "low" },
                { "low", "low" }, { "medium", "medium" }, { "high", "high" },
                { "xhigh", "xhigh" }, { "max", "max" },
            }) do
                local req = assert(Responses.buildRequest({
                    model = "gpt-6.1-sol", prompt = "hello", reasoning_effort = case[1] or nil,
                    access_token = "token", account_id = "account",
                }))
                local body = json.decode(req.body)
                assert.are.equal("gpt-6.1-sol", body.model)
                assert.are.equal(case[2], body.reasoning.effort)
                assert.is_nil(body.temperature)
                assert.is_nil(body.top_p)
                assert.is_nil(body.top_logprobs)
                assert.is_nil(body.logprobs)
                assert.is_nil(body.response_format)
                assert.is_nil(body.tools)
            end
        end)

        it("preserves legacy subscription reasoning behavior", function()
            for _, case in ipairs({ { false, false }, { "none", false }, { "max", false },
                { "minimal", "minimal" }, { "high", "high" } }) do
                local req = assert(Responses.buildRequest({
                    model = "gpt-6-luna", reasoning_effort = case[1] or nil,
                    access_token = "token", account_id = "account",
                }))
                local body = json.decode(req.body)
                assert.are.equal(case[2] or nil, body.reasoning and body.reasoning.effort)
            end
        end)

        it("pins endpoint, streams, disables storage and omits chat-completion fields", function()
            local req = assert(Responses.buildRequest({
                model = "gpt-6-luna", prompt = "hello", instructions = "JSON only",
                reasoning_effort = "high", access_token = "tok_SECRET_123", account_id = "acct_1",
            }))
            assert.are.equal("https://chatgpt.com/backend-api/codex/responses", req.url)
            assert.is_true(req.secure)
            assert.is_nil(req.no_fallback)
            assert.are.equal("openai_account", req.provider)
            assert.are.equal("Bearer tok_SECRET_123", req.headers["Authorization"])
            assert.are.equal("acct_1", req.headers["chatgpt-account-id"])
            assert.are.equal("xray_koplugin", req.headers["originator"])
            local body = json.decode(req.body)
            assert.are.equal(false, body.store)
            assert.are.equal(true, body.stream)
            assert.are.equal("JSON only", body.instructions)
            assert.are.equal("hello", body.input[1].content[1].text)
            assert.are.equal("high", body.reasoning.effort)
            assert.is_nil(body.max_tokens)
            assert.is_nil(body.max_completion_tokens)
            assert.is_nil(body.response_format)
            assert.is_nil(body.messages)
            assert.is_nil(body.tools)
        end)

        it("refuses to build without credentials", function()
            local req, code = Responses.buildRequest({ prompt = "x" })
            assert.is_nil(req)
            assert.are.equal("error_auth", code)
            req, code = Responses.buildRequest({ prompt = "x", access_token = "t" })
            assert.is_nil(req)
            assert.are.equal("error_auth", code)
        end)
    end)

    describe("decodeStream / normalizeStream", function()
        it("accepts chunked deltas only with a terminal completed event", function()
            local body = sse({
                { type = "response.created" },
                { type = "response.output_text.delta", delta = '{"characters":' },
                { type = "response.output_text.delta", delta = '[{"name":"A"}]}' },
                { type = "response.completed", response = { status = "completed" } },
            })
            local normalized, cleaned = Responses.normalizeStream(body)
            assert.is_not_nil(normalized)
            local env = json.decode(normalized)
            assert.are.equal('{"characters":[{"name":"A"}]}', env.choices[1].message.content)
            assert.are.equal(cleaned, env.choices[1].message.content)
        end)

        it("falls back to output items in the completed response", function()
            local body = sse({ { type = "response.completed", response = { status = "completed",
                output = { { type = "message", content = { { type = "output_text", text = '{"a":1}' } } } } } } })
            assert.are.equal('{"a":1}', Responses.decodeStream(body))
        end)

        it("rejects a stream truncated before completion", function()
            local body = sse({ { type = "response.output_text.delta", delta = '{"a":1}' } })
            local ok, code = Responses.normalizeStream(body)
            assert.is_nil(ok)
            assert.are.equal("error_incomplete", code)
        end)

        it("rejects malformed event data", function()
            local ok, code = Responses.normalizeStream("data: {not json\n\n")
            assert.is_nil(ok)
            assert.are.equal("error_parse", code)
        end)

        it("rejects incomplete responses", function()
            local ok, code, msg = Responses.normalizeStream(sse({
                { type = "response.output_text.delta", delta = '{"a":1}' },
                { type = "response.incomplete", response = { incomplete_details = { reason = "max_output_tokens" } } },
            }))
            assert.is_nil(ok)
            assert.are.equal("error_incomplete", code)
            assert.is_truthy(msg:find("max_output_tokens", 1, true))
        end)

        it("rejects completed events whose status is not completed", function()
            local ok, code = Responses.normalizeStream(sse({
                { type = "response.output_text.delta", delta = '{"a":1}' },
                { type = "response.completed", response = { status = "incomplete" } },
            }))
            assert.is_nil(ok)
            assert.are.equal("error_incomplete", code)
        end)

        it("rejects completed stream carrying invalid X-Ray JSON", function()
            local ok, code = Responses.normalizeStream(sse({
                { type = "response.output_text.delta", delta = '{"a":' },
                { type = "response.completed", response = { status = "completed" } },
            }))
            assert.is_nil(ok)
            assert.are.equal("error_parse", code)
        end)

        it("maps failed rate-limit events to quota errors", function()
            local ok, code, msg = Responses.normalizeStream(sse({
                { type = "response.failed", response = { error = { code = "rate_limit_exceeded", message = "secret body" } } },
            }))
            assert.is_nil(ok)
            assert.are.equal("error_quota", code)
            assert.is_nil(msg:find("secret body", 1, true))
        end)

        it("rejects tool invocations", function()
            local ok, code = Responses.normalizeStream(sse({
                { type = "response.output_item.added", item = { type = "function_call", name = "shell" } },
                { type = "response.completed", response = { status = "completed" } },
            }))
            assert.is_nil(ok)
            assert.are.equal("error_api", code)
        end)
    end)

    describe("classifyHttpError", function()
        it("returns safe messages without echoing bodies", function()
            local body = '{"error":{"code":"token_expired","message":"Bearer tok_SECRET leaked"}}'
            local code, msg = Responses.classifyHttpError(401, body)
            assert.are.equal("error_auth", code)
            assert.is_nil(msg:find("tok_SECRET", 1, true))
            assert.is_truthy(msg:find("Reconnect", 1, true))
            assert.are.equal("error_quota", (Responses.classifyHttpError(429, "")))
            assert.are.equal("error_api", (Responses.classifyHttpError(503, "<html>")))
        end)
    end)
end)
