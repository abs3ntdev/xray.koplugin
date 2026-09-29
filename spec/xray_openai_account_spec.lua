-- xray_openai_account_spec.lua
-- AIHelper integration for the experimental ChatGPT subscription provider.
-- Uses fake Auth / SecureHTTP modules only: no real credentials, no network.
require("spec/spec_helper")

describe("AIHelper openai_account provider", function()
    local AIHelper, json, Responses
    local auth, secure, generic_calls, saved

    local function sse_ok(text)
        return "data: " .. json.encode({ type = "response.output_text.delta", delta = text }) .. "\n\n"
            .. "data: " .. json.encode({ type = "response.completed", response = { status = "completed" } }) .. "\n\n"
    end

    local function fakeAuth(opts)
        opts = opts or {}
        local a = { calls = { status = 0, context = 0, refresh = 0, logout = 0 } }
        function a:getStatus()
            self.calls.status = self.calls.status + 1
            return { connected = opts.connected ~= false, account_id = "acct_1", expires_at = 99 }
        end
        function a:getAccessContext(force)
            self.calls.context = self.calls.context + 1
            if force then self.calls.refresh = self.calls.refresh + 1 end
            if opts.connected == false then return nil, "not_connected", "Sign in with ChatGPT first." end
            return { access_token = force and "tok_ROTATED_SECRET" or "tok_SECRET_ACCESS", account_id = "acct_1", expires_at = 99 }
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
        Responses = require("xray_openai_responses")
    end)

    before_each(function()
        saved = {
            makeRequest = AIHelper.makeRequest,
            callGemini = AIHelper.callGemini,
            callChatGPT = AIHelper.callChatGPT,
            settings = AIHelper.settings,
            trap = AIHelper.trap_widget,
        }
        generic_calls = {}
        AIHelper.trap_widget = nil
        AIHelper.makeRequest = function(self, url) table.insert(generic_calls, url); return 1, 200, "{}" end
        AIHelper.callGemini = function(self) table.insert(generic_calls, "gemini"); return { paid = true } end
        AIHelper.callChatGPT = function(self) table.insert(generic_calls, "chatgpt"); return { paid = true } end
        AIHelper.providers.gemini.api_key = "paid_gemini_key"
        AIHelper.providers.chatgpt.api_key = "paid_openai_key"
        AIHelper.settings = {
            primary_ai = { provider = "openai_account", model = "gpt-6-luna" },
            secondary_ai = { provider = "gemini", model = "gemini-3.5-flash-lite" },
        }
        auth = fakeAuth()
        AIHelper._openai_auth = auth
        AIHelper._secure_http = nil
        AIHelper._openai_responses = Responses
    end)

    after_each(function()
        AIHelper.makeRequest = saved.makeRequest
        AIHelper.callGemini = saved.callGemini
        AIHelper.callChatGPT = saved.callChatGPT
        AIHelper.settings = saved.settings
        AIHelper.trap_widget = saved.trap
        AIHelper._openai_auth = nil
        AIHelper._secure_http = nil
        AIHelper._openai_responses = nil
    end)

    describe("credential gating", function()
        it("hasApiKey recognises a connected account without network or token access", function()
            AIHelper.providers.gemini.api_key = nil
            AIHelper.providers.chatgpt.api_key = nil
            local old = {}
            for _, id in ipairs({ "deepseek", "claude", "custom1", "custom2" }) do
                old[id] = AIHelper.providers[id].api_key; AIHelper.providers[id].api_key = nil
            end
            assert.is_true(AIHelper:hasApiKey())
            assert.are.equal(0, auth.calls.context)
            AIHelper._openai_auth = fakeAuth({ connected = false })
            assert.is_false(AIHelper:hasApiKey())
            for id, v in pairs(old) do AIHelper.providers[id].api_key = v end
        end)

        it("getOpenAIAccountStatus never exposes tokens", function()
            local st = AIHelper:getOpenAIAccountStatus()
            assert.is_true(st.connected)
            assert.is_nil(st.access_token)
            assert.is_nil(st.refresh_token)
        end)

        it("validateProviderKey does not hit the network for the account", function()
            local res = AIHelper:validateProviderKey("openai_account")
            assert.is_true(res.ok)
            assert.are.equal(0, #generic_calls)
            assert.are.equal(0, auth.calls.context)
        end)
    end)

    describe("async chain (buildComprehensiveRequest)", function()
        it("subscription-primary builds only the pinned secure request", function()
            local reqs = AIHelper:buildComprehensiveRequest(nil, nil, nil, "prompt")
            assert.are.equal(1, #reqs)
            assert.are.equal("openai_account", reqs[1].provider)
            assert.are.equal(Responses.ENDPOINT, reqs[1].url)
            assert.is_true(reqs[1].secure)
            local body = json.decode(reqs[1].body)
            assert.is_nil(body.max_completion_tokens)
            assert.is_nil(body.response_format)
        end)

        it("ignores a custom endpoint configured on the provider", function()
            AIHelper.providers.openai_account.endpoint = "https://evil.example/steal"
            local reqs = AIHelper:buildComprehensiveRequest(nil, nil, nil, "prompt")
            assert.are.equal(Responses.ENDPOINT, reqs[1].url)
            AIHelper.providers.openai_account.endpoint = nil
        end)

        it("unauthenticated subscription-primary fails before any paid request is built", function()
            AIHelper._openai_auth = fakeAuth({ connected = false })
            local reqs, code = AIHelper:buildComprehensiveRequest(nil, nil, nil, "prompt")
            assert.is_nil(reqs)
            assert.are.equal("error_auth", code)
        end)

        it("API-primary behaviour is unchanged", function()
            AIHelper.settings.primary_ai = { provider = "gemini", model = "gemini-3.7-flash" }
            AIHelper.settings.secondary_ai = { provider = "chatgpt", model = "gpt-5.4-mini" }
            local reqs = AIHelper:buildComprehensiveRequest(nil, nil, nil, "prompt")
            assert.are.equal(2, #reqs)
            assert.are.equal("gemini", reqs[1].provider)
            assert.are.equal("chatgpt", reqs[2].provider)
            assert.is_nil(reqs[1].secure)
            assert.are.equal(0, auth.calls.context)
        end)
    end)

    describe("forked child request chain", function()
        local function run(responses, requests)
            secure = fakeSecure(responses)
            AIHelper._secure_http = secure
            local http = package.loaded["socket.http"]
            local old_request = http and http.request
            if http then http.request = function(r) table.insert(generic_calls, r.url); return 1, 200, {} end end
            -- Track any legacy transport import during the child run.
            local legacy_mods = { "socket.http", "ssl.https", "socketutil", "ltn12" }
            local real_require = require
            _G.legacy_imports = {}
            _G.require = function(name, ...)
                for _, m in ipairs(legacy_mods) do
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

        local function subReq()
            return assert(AIHelper:buildOpenAIAccountRequest("p", "gpt-6-luna"))
        end
        local paid = { url = "https://api.openai.com/v1/chat/completions", provider = "chatgpt", headers = {}, body = "{}" }

        for _, status in ipairs({ 401, 429, 500, 503 }) do
            it("does not fall through to a paid request on HTTP " .. status, function()
                local tmp = run({ { status, '{"error":{"message":"Bearer tok_SECRET_ACCESS"}}' }, { status, "" } }, { subReq(), paid })
                assert.are.equal(0, #generic_calls)
                local data, code, msg = AIHelper:checkAsyncResult(tmp)
                assert.is_false(data)
                assert.is_nil(msg:find("tok_SECRET", 1, true))
                if status == 401 then
                    assert.are.equal("error_auth", code)
                    assert.is_truthy(msg:find("Reconnect", 1, true))
                elseif status == 429 then
                    assert.are.equal("error_quota", code)
                end
            end)
        end

        it("never refreshes in the child on 401", function()
            local req = subReq()
            local before = auth.calls.context
            run({ { 401, "" } }, { req })
            assert.are.equal(before, auth.calls.context)
            assert.are.equal(0, auth.calls.refresh)
            assert.are.equal(1, #secure.calls)
        end)

        it("routes through SecureHTTP with the pinned URL and parses a valid stream", function()
            local tmp = run({ { 200, sse_ok('{"characters":[{"name":"Ann"}]}') } }, { subReq() })
            assert.are.equal(1, #secure.calls)
            assert.are.equal(0, #_G.legacy_imports)
            assert.are.equal(Responses.ENDPOINT, secure.calls[1].url)
            assert.are.equal(0, #generic_calls)
            local data = AIHelper:checkAsyncResult(tmp)
            assert.is_table(data)
        end)

        it("rejects incomplete and malformed streams without fallback", function()
            local truncated = "data: " .. json.encode({ type = "response.output_text.delta", delta = '{"a":1}' }) .. "\n\n"
            local tmp = run({ { 200, truncated } }, { subReq(), paid })
            assert.are.equal(0, #generic_calls)
            local data, code = AIHelper:checkAsyncResult(tmp)
            assert.is_false(data)
            assert.are.equal("error_incomplete", code)

            tmp = run({ { 200, "data: {broken\n\n" } }, { subReq(), paid })
            data, code = AIHelper:checkAsyncResult(tmp)
            assert.is_false(data)
            assert.are.equal("error_parse", code)
        end)

        it("refuses to send a secure-tagged request to a substituted endpoint", function()
            local req = subReq()
            req.url = "https://evil.example/v1"
            local tmp = run({ { 200, sse_ok('{"a":1}') } }, { req })
            assert.are.equal(0, #secure.calls)
            assert.are.equal(0, #generic_calls)
            assert.is_false((AIHelper:checkAsyncResult(tmp)))
        end)

        it("rejects openai_account requests missing the secure tag without legacy HTTP", function()
            local req = subReq()
            req.secure = nil
            local https = package.loaded["ssl.https"]
            local before = https and https.cert_verify
            local tmp = run({ { 200, sse_ok('{"a":1}') } }, { req, paid })
            assert.are.equal(0, #secure.calls)
            assert.are.equal(0, #generic_calls)
            assert.are.equal(0, #_G.legacy_imports)
            if https then assert.are.equal(before, https.cert_verify) end
            assert.is_false((AIHelper:checkAsyncResult(tmp)))
        end)

        it("surfaces local TLS failures safely", function()
            local tmp = run({ { nil, "tls_failed", "The secure connection could not be verified." } }, { subReq(), paid })
            assert.are.equal(0, #generic_calls)
            local data, code, msg = AIHelper:checkAsyncResult(tmp)
            assert.is_false(data)
            assert.are.equal("error_network", code)
            assert.is_truthy(msg:find("verified", 1, true))
        end)
    end)

    describe("sync chain (executeUnifiedRequest)", function()
        for _, status in ipairs({ 429, 500 }) do
            it("subscription-primary never falls back to paid secondary on HTTP " .. status, function()
                AIHelper._secure_http = fakeSecure({ { status, "" } })
                local res, code = AIHelper:executeUnifiedRequest("p")
                assert.is_nil(res)
                assert.are.equal(0, #generic_calls)
                assert.is_not_nil(code)
            end)
        end

        it("unauthenticated subscription-primary never tries paid secondary", function()
            AIHelper._openai_auth = fakeAuth({ connected = false })
            local res, code = AIHelper:executeUnifiedRequest("p")
            assert.is_nil(res)
            assert.are.equal("error_auth", code)
            assert.are.equal(0, #generic_calls)
        end)

        it("401 refreshes once in the parent then asks to reconnect", function()
            local s = fakeSecure({ { 401, "" }, { 401, "" } })
            AIHelper._secure_http = s
            local res, code, msg = AIHelper:executeUnifiedRequest("p")
            assert.is_nil(res)
            assert.are.equal("error_auth", code)
            assert.are.equal(2, #s.calls)
            assert.are.equal(1, auth.calls.refresh)
            assert.are.equal("Bearer tok_ROTATED_SECRET", s.calls[2].headers["Authorization"])
            assert.is_nil(msg:find("tok_", 1, true))
            assert.are.equal(0, #generic_calls)
        end)

        it("returns parsed data on a valid stream", function()
            AIHelper._secure_http = fakeSecure({ { 200, sse_ok('{"characters":[{"name":"Ann"}]}') } })
            local res = AIHelper:executeUnifiedRequest("p")
            assert.is_table(res)
            assert.are.equal(0, #generic_calls)
        end)

        it("API-primary still falls back as before", function()
            AIHelper.settings.primary_ai = { provider = "chatgpt", model = "gpt-5.4-mini" }
            AIHelper.settings.secondary_ai = { provider = "gemini", model = "gemini-3.5-flash-lite" }
            AIHelper.callChatGPT = function(self) table.insert(generic_calls, "chatgpt"); return nil, "error_api", "x" end
            local res = AIHelper:executeUnifiedRequest("p")
            assert.is_true(res.paid)
            assert.are.same({ "chatgpt", "gemini" }, generic_calls)
            assert.are.equal(0, auth.calls.context)
        end)
    end)

    describe("clearing credentials", function()
        it("clearProviderKey(openai_account) only logs out of the OAuth store", function()
            local old_save = AIHelper.saveSettings
            local wrote = false
            AIHelper.saveSettings = function() wrote = true end
            assert.is_true(AIHelper:clearProviderKey("openai_account"))
            assert.are.equal(1, auth.calls.logout)
            assert.is_false(wrote)
            AIHelper.saveSettings = old_save
        end)

        it("clearAllAPIKeys also logs out of the OAuth store", function()
            local stubs = { "saveSettings", "saveStoredConfig", "writeConfigToFile", "init" }
            local old = {}
            for _, n in ipairs(stubs) do old[n] = AIHelper[n]; AIHelper[n] = function() end end
            AIHelper:clearAllAPIKeys()
            for _, n in ipairs(stubs) do AIHelper[n] = old[n] end
            assert.are.equal(1, auth.calls.logout)
        end)
    end)
end)
