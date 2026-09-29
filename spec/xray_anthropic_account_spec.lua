-- xray_anthropic_account_spec.lua
-- AIHelper integration for the experimental Claude subscription provider.
-- Fake Auth / SecureHTTP only: no real credentials, no network.
require("spec/spec_helper")

describe("AIHelper anthropic_account provider", function()
    local AIHelper, json, Messages
    local auth, oauth, secure, generic_calls, saved

    local function ev(t) return "data: " .. json.encode(t) .. "\n\n" end
    local function sse_ok(text)
        return ev({ type = "content_block_start", index = 0, content_block = { type = "text", text = "" } })
            .. ev({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = text } })
            .. ev({ type = "message_delta", delta = { stop_reason = "end_turn" } })
            .. ev({ type = "message_stop" })
    end

    local function fakeAuth(opts)
        opts = opts or {}
        local a = { calls = { status = 0, context = 0, refresh = 0, logout = 0 } }
        function a:getStatus()
            self.calls.status = self.calls.status + 1
            return { connected = opts.connected ~= false, expires_at = 99, access_token = "LEAK" }
        end
        function a:getAccessContext(force)
            self.calls.context = self.calls.context + 1
            if force then self.calls.refresh = self.calls.refresh + 1 end
            if opts.connected == false then return nil, "not_connected", "Sign in with Claude first." end
            return { access_token = force and "sk-ant-oat_ROTATED" or "sk-ant-oat_SECRET", expires_at = 99 }
        end
        function a:logout() self.calls.logout = self.calls.logout + 1; return true end
        return a
    end

    local function fakeSecure(responses)
        local s = { calls = {} }
        function s:request(url, method, headers, body, timeout)
            table.insert(self.calls, { url = url, headers = headers, body = body })
            local r = table.remove(responses, 1) or { 500, "" }
            if r[1] == nil then return nil, r[2], r[3], {} end
            return 1, r[1], r[2], {}
        end
        return s
    end

    setup(function()
        json = require("json")
        AIHelper = require("xray_aihelper")
        Messages = require("xray_anthropic_messages")
    end)

    before_each(function()
        saved = {
            makeRequest = AIHelper.makeRequest, callGemini = AIHelper.callGemini,
            callChatGPT = AIHelper.callChatGPT, callClaude = AIHelper.callClaude,
            settings = AIHelper.settings, trap = AIHelper.trap_widget,
            claude_key = AIHelper.providers.claude.api_key,
        }
        generic_calls = {}
        AIHelper.trap_widget = nil
        AIHelper.makeRequest = function(self, url) table.insert(generic_calls, url); return 1, 200, "{}" end
        AIHelper.callGemini = function() table.insert(generic_calls, "gemini"); return { paid = true } end
        AIHelper.callChatGPT = function() table.insert(generic_calls, "chatgpt"); return { paid = true } end
        AIHelper.callClaude = function() table.insert(generic_calls, "claude"); return { paid = true } end
        AIHelper.providers.gemini.api_key = "paid_gemini_key"
        AIHelper.providers.claude.api_key = "paid_claude_key"
        AIHelper.settings = {
            primary_ai = { provider = "anthropic_account", model = "claude-sonnet-5" },
            secondary_ai = { provider = "claude", model = "claude-sonnet-5" },
        }
        auth = fakeAuth()
        oauth = fakeAuth()
        AIHelper._anthropic_auth = auth
        AIHelper._openai_auth = oauth
        AIHelper._secure_http = nil
        AIHelper._anthropic_messages = Messages
    end)

    after_each(function()
        for _, k in ipairs({ "makeRequest", "callGemini", "callChatGPT", "callClaude", "settings" }) do AIHelper[k] = saved[k] end
        AIHelper.trap_widget = saved.trap
        AIHelper.providers.claude.api_key = saved.claude_key
        AIHelper._anthropic_auth = nil
        AIHelper._openai_auth = nil
        AIHelper._secure_http = nil
        AIHelper._anthropic_messages = nil
    end)

    describe("credential gating", function()
        it("status is safe and never exposes tokens", function()
            local st = AIHelper:getAnthropicAccountStatus()
            assert.is_true(st.connected)
            assert.is_nil(st.access_token)
            assert.are.equal(0, auth.calls.context)
            assert.is_true(AIHelper:isProviderConfigured("anthropic_account"))
            assert.is_true(AIHelper:isSubscriptionPrimary())
        end)

        it("hasApiKey recognises connected Claude only", function()
            local old = {}
            for _, id in ipairs({ "gemini", "chatgpt", "deepseek", "claude", "custom1", "custom2" }) do
                old[id] = AIHelper.providers[id].api_key; AIHelper.providers[id].api_key = nil
            end
            AIHelper._openai_auth = fakeAuth({ connected = false })
            assert.is_true(AIHelper:hasApiKey())
            AIHelper._anthropic_auth = fakeAuth({ connected = false })
            assert.is_false(AIHelper:hasApiKey())
            for id, v in pairs(old) do AIHelper.providers[id].api_key = v end
        end)

        it("validateProviderKey does no network or context access", function()
            assert.is_true(AIHelper:validateProviderKey("anthropic_account").ok)
            assert.are.equal(0, auth.calls.context)
            assert.are.equal(0, #generic_calls)
        end)
    end)

    describe("async chain", function()
        it("subscription-primary builds only the pinned secure Claude request", function()
            local reqs = AIHelper:buildComprehensiveRequest(nil, nil, nil, "prompt")
            assert.are.equal(1, #reqs)
            local r = reqs[1]
            assert.are.equal("anthropic_account", r.provider)
            assert.are.equal(Messages.ENDPOINT, r.url)
            assert.is_true(r.secure)
            assert.are.equal("Bearer sk-ant-oat_SECRET", r.headers["Authorization"])
            assert.is_nil(r.headers["x-api-key"])
            local body = json.decode(r.body)
            assert.are.equal("claude-sonnet-5", body.model)
            assert.is_truthy(r.headers["X-Claude-Code-Session-Id"]:match("^%x+%-%x+%-4%x+%-a%x+%-%x+$"))
            assert.are.equal(0, oauth.calls.context)
        end)

        it("forwards claude-sonnet-5-5 unchanged without fallback", function()
            AIHelper.settings.primary_ai = { provider = "anthropic_account", model = "claude-sonnet-5-5" }
            local reqs = AIHelper:buildComprehensiveRequest(nil, nil, nil, "prompt")
            assert.are.equal("claude-sonnet-5-5", json.decode(reqs[1].body).model)
        end)

        it("ignores a custom endpoint configured on the provider", function()
            AIHelper.providers.anthropic_account.endpoint = "https://evil.example"
            local reqs = AIHelper:buildComprehensiveRequest(nil, nil, nil, "p")
            AIHelper.providers.anthropic_account.endpoint = nil
            assert.are.equal(Messages.ENDPOINT, reqs[1].url)
        end)

        it("unauthenticated subscription-primary fails before any paid request", function()
            AIHelper._anthropic_auth = fakeAuth({ connected = false })
            local reqs, code = AIHelper:buildComprehensiveRequest(nil, nil, nil, "p")
            assert.is_nil(reqs)
            assert.are.equal("error_auth", code)
        end)

        it("API-primary with Claude subscription secondary keeps paid primary first", function()
            AIHelper.settings.primary_ai = { provider = "gemini", model = "gemini-3.5-flash-lite" }
            AIHelper.settings.secondary_ai = { provider = "anthropic_account", model = "claude-haiku-4-5" }
            local reqs = AIHelper:buildComprehensiveRequest(nil, nil, nil, "p")
            assert.are.equal(2, #reqs)
            assert.are.equal("gemini", reqs[1].provider)
            assert.are.equal("anthropic_account", reqs[2].provider)
            assert.are.equal("claude-haiku-4-5", json.decode(reqs[2].body).model)
        end)
    end)

    describe("forked child", function()
        local function run(responses, requests)
            secure = fakeSecure(responses)
            AIHelper._secure_http = secure
            local http = package.loaded["socket.http"]
            local old_request = http and http.request
            if http then http.request = function(r) table.insert(generic_calls, r.url); return 1, 200, {} end end
            local real_require = require
            _G.legacy_imports = {}
            _G.require = function(name, ...)
                for _, m in ipairs({ "socket.http", "ssl.https", "socketutil", "ltn12" }) do
                    if name == m then table.insert(_G.legacy_imports, name) end
                end
                return real_require(name, ...)
            end
            local tmp = os.tmpname()
            local ok, err = pcall(AIHelper._runChildRequests, AIHelper, requests, tmp)
            _G.require = real_require
            if http then http.request = old_request end
            assert(ok, err)
            return tmp
        end
        local function subReq() return assert(AIHelper:buildAnthropicAccountRequest("p", "claude-sonnet-5")) end
        local paid = { url = "https://api.anthropic.com/v1/messages", provider = "claude", headers = {}, body = "{}" }

        for _, status in ipairs({ 401, 403, 429, 500, 529 }) do
            it("never falls through to paid API on HTTP " .. status, function()
                local tmp = run({ { status, '{"error":{"type":"x","message":"sk-ant-oat_SECRET"}}' } }, { subReq(), paid })
                assert.are.equal(0, #generic_calls)
                assert.are.equal(1, #secure.calls)
                local data, code, msg = AIHelper:checkAsyncResult(tmp)
                assert.is_false(data)
                assert.is_nil(msg:find("sk-ant", 1, true))
                if status == 401 then assert.are.equal("error_auth", code) end
                if status == 429 then assert.are.equal("error_quota", code) end
            end)
        end

        it("never refreshes in the child", function()
            local req = subReq()
            local before = auth.calls.context
            run({ { 401, "" } }, { req })
            assert.are.equal(before, auth.calls.context)
            assert.are.equal(0, auth.calls.refresh)
        end)

        it("routes via SecureHTTP to the pinned URL and parses a valid stream", function()
            local tmp = run({ { 200, sse_ok('{"characters":[{"name":"Ann"}]}') } }, { subReq() })
            assert.are.equal(Messages.ENDPOINT, secure.calls[1].url)
            assert.are.equal(0, #_G.legacy_imports)
            assert.is_table(AIHelper:checkAsyncResult(tmp))
        end)

        it("rejects truncated stream without fallback or repair", function()
            local trunc = ev({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = '{"a":' } })
            local tmp = run({ { 200, trunc } }, { subReq(), paid })
            local data, code = AIHelper:checkAsyncResult(tmp)
            assert.is_false(data)
            assert.are.equal("error_incomplete", code)
            assert.are.equal(0, #generic_calls)
        end)

        it("refuses substituted endpoint and cross-provider adapter", function()
            local req = subReq(); req.url = "https://evil.example/v1/messages"
            local tmp = run({ { 200, sse_ok('{"a":1}') } }, { req })
            assert.are.equal(0, #secure.calls)
            assert.is_false((AIHelper:checkAsyncResult(tmp)))
            -- Claude credentials must not ride on the OpenAI pinned URL either.
            req = subReq(); req.url = "https://chatgpt.com/backend-api/codex/responses"
            run({ { 200, "" } }, { req })
            assert.are.equal(0, #secure.calls)
        end)

        it("rejects anthropic_account missing secure tag without legacy HTTP", function()
            local req = subReq(); req.secure = nil
            local tmp = run({ { 200, sse_ok('{"a":1}') } }, { req, paid })
            assert.are.equal(0, #secure.calls)
            assert.are.equal(0, #generic_calls)
            assert.are.equal(0, #_G.legacy_imports)
            assert.is_false((AIHelper:checkAsyncResult(tmp)))
        end)

        it("surfaces TLS failures safely", function()
            local tmp = run({ { nil, "tls_failed", "The secure connection could not be verified." } }, { subReq(), paid })
            local data, code = AIHelper:checkAsyncResult(tmp)
            assert.is_false(data)
            assert.are.equal("error_network", code)
            assert.are.equal(0, #generic_calls)
        end)
    end)

    describe("sync chain", function()
        for _, status in ipairs({ 429, 500, 529 }) do
            it("never falls back to paid Claude API on HTTP " .. status, function()
                AIHelper._secure_http = fakeSecure({ { status, "" } })
                local res, code = AIHelper:executeUnifiedRequest("p")
                assert.is_nil(res)
                assert.is_not_nil(code)
                assert.are.equal(0, #generic_calls)
            end)
        end

        it("unauthenticated primary never tries paid secondary", function()
            AIHelper._anthropic_auth = fakeAuth({ connected = false })
            local res, code = AIHelper:executeUnifiedRequest("p")
            assert.is_nil(res)
            assert.are.equal("error_auth", code)
            assert.are.equal(0, #generic_calls)
        end)

        it("parse failure does not fall back", function()
            AIHelper._secure_http = fakeSecure({ { 200, sse_ok("not json") } })
            local res, code = AIHelper:executeUnifiedRequest("p")
            assert.is_nil(res)
            assert.are.equal("error_parse", code)
            assert.are.equal(0, #generic_calls)
        end)

        it("401 refreshes once in parent then asks to reconnect", function()
            local s = fakeSecure({ { 401, "" }, { 401, "" } })
            AIHelper._secure_http = s
            local res, code, msg = AIHelper:executeUnifiedRequest("p")
            assert.is_nil(res)
            assert.are.equal("error_auth", code)
            assert.are.equal(2, #s.calls)
            assert.are.equal(1, auth.calls.refresh)
            assert.are.equal("Bearer sk-ant-oat_ROTATED", s.calls[2].headers["Authorization"])
            assert.is_nil(msg:find("sk-ant", 1, true))
        end)

        it("returns parsed data on a valid stream", function()
            AIHelper._secure_http = fakeSecure({ { 200, sse_ok('{"characters":[{"name":"Ann"}]}') } })
            assert.is_table(AIHelper:executeUnifiedRequest("p"))
            assert.are.equal(0, #generic_calls)
        end)

        it("API-primary Claude key path unchanged", function()
            AIHelper.settings.primary_ai = { provider = "claude", model = "claude-sonnet-5" }
            AIHelper.settings.secondary_ai = { provider = "gemini", model = "gemini-3.5-flash-lite" }
            local res = AIHelper:executeUnifiedRequest("p")
            assert.is_true(res.paid)
            assert.are.equal(0, auth.calls.context)
        end)
    end)

    describe("clearing credentials", function()
        it("clearProviderKey(anthropic_account) only logs out Claude store", function()
            local old = AIHelper.saveSettings
            local wrote = false
            AIHelper.saveSettings = function() wrote = true end
            assert.is_true(AIHelper:clearProviderKey("anthropic_account"))
            AIHelper.saveSettings = old
            assert.are.equal(1, auth.calls.logout)
            assert.are.equal(0, oauth.calls.logout)
            assert.is_false(wrote)
        end)

        it("clearAllAPIKeys logs out both subscriptions without writing tokens to config", function()
            local stubs = { "saveSettings", "saveStoredConfig", "writeConfigToFile", "init" }
            local old, written = {}, {}
            for _, n in ipairs(stubs) do
                old[n] = AIHelper[n]
                AIHelper[n] = function(_, t) if type(t) == "table" then table.insert(written, json.encode(t)) end end
            end
            AIHelper:clearAllAPIKeys()
            for _, n in ipairs(stubs) do AIHelper[n] = old[n] end
            assert.are.equal(1, auth.calls.logout)
            assert.are.equal(1, oauth.calls.logout)
            for _, w in ipairs(written) do
                assert.is_nil(w:find("sk-ant", 1, true))
                assert.is_nil(w:find("anthropic_account", 1, true))
            end
        end)

        local function clearAllWith(claude_auth, openai_auth)
            AIHelper._anthropic_auth = claude_auth
            AIHelper._openai_auth = openai_auth
            local stubs = { "saveSettings", "saveStoredConfig", "writeConfigToFile", "init" }
            local old = {}
            for _, n in ipairs(stubs) do old[n] = AIHelper[n]; AIHelper[n] = function() end end
            local ok, msg = AIHelper:clearAllAPIKeys()
            for _, n in ipairs(stubs) do AIHelper[n] = old[n] end
            return ok, msg
        end
        local function failing(kind)
            local a = fakeAuth()
            function a:logout()
                self.calls.logout = self.calls.logout + 1
                if kind == "throw" then error("store busy sk-ant-oat_SECRET") end
                return nil, "store_busy", "Sign-out is busy; try again."
            end
            return a
        end

        it("clearAllAPIKeys reports failure when Claude logout fails, still attempts OpenAI", function()
            local c, o = failing(), fakeAuth()
            local ok, msg = clearAllWith(c, o)
            assert.is_false(ok)
            assert.is_truthy(msg:find("busy", 1, true))
            assert.are.equal(1, o.calls.logout)
        end)

        it("clearAllAPIKeys reports failure when OpenAI logout throws, still attempts Claude, no secret leak", function()
            local c, o = fakeAuth(), failing("throw")
            local ok, msg = clearAllWith(c, o)
            assert.is_false(ok)
            assert.are.equal(1, c.calls.logout)
            assert.is_truthy(msg:find("ChatGPT", 1, true))
            assert.is_nil(msg:find("sk-ant", 1, true))
        end)

        it("API-only clear-all succeeds when no OAuth account is connected or runtime missing", function()
            local c, o = failing(), failing("throw")
            function c:getStatus() return { connected = false } end
            function o:getStatus() error("store unsupported") end
            local ok, msg = clearAllWith(c, o)
            assert.is_true(ok)
            assert.is_nil(msg)
            assert.are.equal(0, c.calls.logout)
            assert.are.equal(0, o.calls.logout)
            -- Runtime entirely unavailable: the loader returns nil.
            local old_get = AIHelper._getAnthropicAuth
            AIHelper._getAnthropicAuth = function() return nil end
            ok = clearAllWith(nil, fakeAuth({ connected = false }))
            AIHelper._getAnthropicAuth = old_get
            assert.is_true(ok)
        end)

        it("clearProviderKey propagates a safe failure and isolates providers", function()
            local c, o = failing(), fakeAuth()
            AIHelper._anthropic_auth, AIHelper._openai_auth = c, o
            local ok, msg = AIHelper:clearProviderKey("anthropic_account")
            assert.is_false(ok)
            assert.is_string(msg)
            assert.are.equal(0, o.calls.logout)
        end)
    end)
end)
