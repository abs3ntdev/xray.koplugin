-- Never reads real auth: explicit temporary store, fake HTTP, fake entropy.
local json = require("dkjson")

describe("Anthropic experimental account authentication", function()
    local Auth, Store, path, now, calls, replies, previous_json, counter
    local function respond(status, body, callback)
        replies[#replies + 1] = { status = status, body = body, callback = callback }
    end
    local function tokens(extra)
        local t = { access_token = "fake-access", refresh_token = "fake-refresh", expires_in = 3600,
            scope = "user:profile user:inference" }
        for k, v in pairs(extra or {}) do t[k] = v end
        return t
    end
    local function query(url, key)
        local value = url:match("[?&]" .. key .. "=([^&]*)")
        return value and value:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    end
    local function seed(expiry, refresh)
        local release = assert(Store:acquire(path))
        assert(Store:save(path, { access_token = "old-access", refresh_token = refresh or "old-refresh",
            expires_at = expiry or now - 1 }))
        release()
    end
    local function stateOf(flow) return query(flow.authorization_url, "state") end
    before_each(function()
        previous_json = package.loaded.json
        package.loaded.json = json
        Auth = dofile("xray.koplugin/xray_anthropic_auth.lua")
        Store = dofile("xray.koplugin/xray_auth_store.lua")
        package.loaded["xray_crypto"] = dofile("xray.koplugin/xray_crypto.lua")
        path = os.tmpname()
        os.remove(path)
        now, calls, replies, counter = 100000, {}, {}, 0
        Auth.store_path, Auth.store = path, Store
        Auth.now = function() return now end
        Auth.random = function(n)
            counter = counter + 1
            return string.rep(string.char(counter), n)
        end
        Auth.http = { request = function(_, url, method, headers, body, timeout)
            calls[#calls + 1] = { url = url, method = method, headers = headers, body = body, timeout = timeout }
            local reply = table.remove(replies, 1)
            assert(reply, "unexpected network call")
            if reply.callback then reply.callback() end
            return true, reply.status, type(reply.body) == "string" and reply.body or json.encode(reply.body), {}
        end }
    end)
    after_each(function()
        for _, suffix in ipairs({ "", ".lock", ".tmp", ".generation", ".generation.tmp", ".generation.lock" }) do
            os.remove(path .. suffix)
        end
        package.loaded.json = previous_json
        package.loaded["xray_crypto"] = nil
    end)

    it("has no storage, entropy or network access at module load", function()
        local original = package.loaded.datastorage
        package.loaded.datastorage = { getSettingsDir = function() error("must not read") end }
        local opened = io.open
        io.open = function(p, ...) if p == "/dev/urandom" then error("no entropy at load") end return opened(p, ...) end
        local fresh = dofile("xray.koplugin/xray_anthropic_auth.lua")
        io.open = opened
        package.loaded.datastorage = original
        assert.is_table(fresh)
        assert.are.equal(0, #calls)
    end)
    it("reports disconnected and never exports tokens in status", function()
        assert.are.same({ connected = false }, Auth:getStatus())
        seed(now + 10)
        assert.are.same({ connected = true, expires_at = now + 10 }, Auth:getStatus())
        assert.are.equal(0, #calls)
    end)
    it("builds the pinned authorization URL with PKCE and independent state, offline", function()
        local flow = assert(Auth:startLogin())
        assert.are.equal(0, #calls)
        local url = flow.authorization_url
        assert.are.equal("https://claude.com/cai/oauth/authorize", url:match("^([^?]+)"))
        assert.are.equal("true", query(url, "code"))
        assert.are.equal("9d1c250a-e61b-44d9-88ed-5944d1962f5e", query(url, "client_id"))
        assert.are.equal("code", query(url, "response_type"))
        assert.are.equal("https://platform.claude.com/oauth/code/callback", query(url, "redirect_uri"))
        assert.are.equal("org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
            query(url, "scope"))
        assert.are.equal("S256", query(url, "code_challenge_method"))
        local verifier = Auth._base64url(string.rep(string.char(1), 32))
        local expected = Auth._base64url(package.loaded["xray_crypto"]:sha256(verifier))
        assert.are.equal(expected, query(url, "code_challenge"))
        assert.are.equal(Auth._base64url(string.rep(string.char(2), 32)), stateOf(flow))
        assert.are_not.equal(verifier, stateOf(flow))
        assert.is_nil(url:find(verifier, 1, true))
        assert.are.equal(now + 600, flow.expires_at)
    end)
    it("computes RFC 7636 appendix B challenge", function()
        -- Canonical verifier from RFC 7636 appendix B.
        local digest = package.loaded["xray_crypto"]:sha256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        assert.are.equal("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", Auth._base64url(digest))
    end)
    it("fails closed without sufficient entropy and never advances the epoch", function()
        for _, source in ipairs({
            function() return nil end,
            function(n) return string.rep("a", n - 1) end,
            function() error("urandom broken") end,
            function(n) return string.rep("z", n) end, -- identical state and verifier
        }) do
            Auth.random = source
            local ok, code = Auth:startLogin()
            assert.is_nil(ok)
            assert.are.equal("entropy_unavailable", code)
        end
        assert.is_nil(Store:load(path .. ".generation"))
    end)
    it("exchanges code#state with pinned JSON body and saves tokens", function()
        local flow = assert(Auth:startLogin())
        respond(200, tokens())
        assert.is_true(Auth:completeLogin(flow, "  the-code#" .. stateOf(flow) .. "\n"))
        assert.are.equal(1, #calls)
        assert.are.equal("https://platform.claude.com/v1/oauth/token", calls[1].url)
        assert.are.equal("POST", calls[1].method)
        assert.are.equal("application/json", calls[1].headers["Content-Type"])
        assert.are.same({ grant_type = "authorization_code", code = "the-code",
            redirect_uri = "https://platform.claude.com/oauth/code/callback",
            client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            code_verifier = Auth._base64url(string.rep(string.char(1), 32)),
            state = stateOf(flow) }, json.decode(calls[1].body))
        local saved = Store:load(path)
        assert.are.same({ access_token = "fake-access", refresh_token = "fake-refresh",
            expires_at = now + 3600 }, saved)
        assert.is_nil(flow._verifier)
        assert.are.same({ connected = true, expires_at = now + 3600 }, Auth:getStatus())
    end)
    it("accepts the full official callback URL and rejects other hosts", function()
        local flow = assert(Auth:startLogin())
        local ok, code = Auth:completeLogin(flow, "https://evil.example/oauth/code/callback?code=c&state=" .. stateOf(flow))
        assert.is_nil(ok)
        assert.are.equal("invalid_code", code)
        local s = stateOf(flow)
        for _, input in ipairs({ "ftp://evil/?x=1&code=c&state=" .. s, "//evil/?code=c&state=" .. s,
            "javascript:?code=c&state=" .. s, "HTTPS://platform.claude.com/oauth/code/callback?code=c&state=" .. s,
            "https://platform.claude.com/oauth/code/callback?code=c&code=d&state=" .. s,
            "code=c&state=" .. s .. "&state=" .. s }) do
            ok, code = Auth:completeLogin(flow, input)
            assert.is_nil(ok)
            assert.are.equal("invalid_code", code)
        end
        assert.are.equal(0, #calls)
        respond(200, tokens())
        assert.is_true(Auth:completeLogin(flow,
            "https://platform.claude.com/oauth/code/callback?code=c%2Bx&state=" .. stateOf(flow)))
        assert.are.equal("c+x", json.decode(calls[1].body).code)
    end)
    it("requires a matching state and never contacts network or saves on mismatch", function()
        local flow = assert(Auth:startLogin())
        for _, input in ipairs({ "code-only", "", "#state", "code#", "code#wrong-state",
            "code#" .. stateOf(flow) .. "x", "code#" .. Auth._base64url(string.rep(string.char(1), 32)), 42 }) do
            local ok, code = Auth:completeLogin(flow, input)
            assert.is_nil(ok)
            assert.is_truthy(code == "invalid_code" or code == "state_mismatch")
        end
        assert.are.equal(0, #calls)
        assert.are.same({ connected = false }, Auth:getStatus())
        respond(200, tokens())
        assert.is_true(Auth:completeLogin(flow, "c#" .. stateOf(flow)))
    end)
    it("is single use: a failed exchange cannot be replayed", function()
        local flow = assert(Auth:startLogin())
        local state = stateOf(flow)
        respond(400, { error = "invalid_grant" })
        local ok, code = Auth:completeLogin(flow, "c#" .. state)
        assert.is_nil(ok)
        assert.are.equal("invalid_grant", code)
        ok, code = Auth:completeLogin(flow, "c#" .. state)
        assert.is_nil(ok)
        assert.are.equal("cancelled", code)
        assert.are.equal(1, #calls)
        assert.are.same({ connected = false }, Auth:getStatus())
    end)
    it("rejects success responses without inference scope or malformed tokens", function()
        for _, body in ipairs({ tokens({ scope = "user:profile" }), tokens({ access_token = "" }),
            tokens({ expires_in = "3600" }), tokens({ refresh_token = false }), "not json" }) do
            local flow = assert(Auth:startLogin())
            respond(200, body)
            local ok, code = Auth:completeLogin(flow, "c#" .. stateOf(flow))
            assert.is_nil(ok)
            assert.is_truthy(code == "missing_scope" or code == "invalid_response")
        end
        assert.are.same({ connected = false }, Auth:getStatus())
    end)
    it("expires flows and invalidates older flows on new login", function()
        local first = assert(Auth:startLogin())
        local second = assert(Auth:startLogin())
        local ok, code = Auth:completeLogin(first, "c#" .. (stateOf(first)))
        assert.is_nil(ok)
        assert.are.equal("cancelled", code)
        now = now + 601
        ok, code = Auth:completeLogin(second, "c#" .. stateOf(second))
        assert.is_nil(ok)
        assert.are.equal("expired", code)
        assert.are.equal(0, #calls)
    end)
    it("cancel invalidates the flow but keeps an existing account", function()
        seed(now + 1000)
        local flow = assert(Auth:startLogin())
        local state = stateOf(flow)
        assert.is_true(Auth:cancelLogin(flow))
        local ok, code = Auth:completeLogin(flow, "c#" .. state)
        assert.is_nil(ok)
        assert.are.equal("cancelled", code)
        assert.is_true(Auth:getStatus().connected)
        assert.are.equal(0, #calls)
    end)
    it("does not save when cancelled or logged out during the exchange", function()
        local flow = assert(Auth:startLogin())
        respond(200, tokens(), function() Auth:cancelLogin(flow) end)
        local ok, code = Auth:completeLogin(flow, "c#" .. stateOf(flow))
        assert.is_nil(ok)
        assert.are.equal("cancelled", code)
        assert.are.same({ connected = false }, Auth:getStatus())
    end)
    it("rejects a flow after logout in another process (persisted epoch)", function()
        local flow = assert(Auth:startLogin())
        local other = dofile("xray.koplugin/xray_anthropic_auth.lua")
        other.store_path, other.store = path, Store
        assert.is_true(other:logout())
        respond(200, tokens())
        local ok, code = Auth:completeLogin(flow, "c#" .. stateOf(flow))
        assert.is_nil(ok)
        assert.are.equal("cancelled", code)
        assert.are.equal(0, #calls)
        assert.are.same({ connected = false }, Auth:getStatus())
    end)
    it("returns fresh context without network and refreshes near expiry", function()
        seed(now + 1000)
        assert.are.same({ access_token = "old-access", expires_at = now + 1000 }, Auth:getAccessContext())
        assert.are.equal(0, #calls)
        respond(200, tokens({ refresh_token = "rotated" }))
        assert.are.same({ access_token = "fake-access", expires_at = now + 3600 }, Auth:getAccessContext(true))
        assert.are.same({ grant_type = "refresh_token", refresh_token = "old-refresh",
            client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            scope = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload" },
            json.decode(calls[1].body))
        assert.are.equal("rotated", Store:load(path).refresh_token)
    end)
    it("keeps the previous refresh token when omitted and retries once without scope", function()
        seed(now - 1)
        respond(400, { error = "invalid_scope" })
        respond(200, { access_token = "new", expires_in = 60 })
        assert.are.same({ access_token = "new", expires_at = now + 60 }, Auth:getAccessContext())
        assert.is_nil(json.decode(calls[2].body).scope)
        assert.are.equal("old-refresh", Store:load(path).refresh_token)
    end)
    it("clears only on invalid_grant and retains tokens on network failure", function()
        seed(now - 1)
        Auth.http = { request = function() return nil, "network_error" end }
        local ok, code = Auth:getAccessContext()
        assert.is_nil(ok)
        assert.are.equal("network_error", code)
        assert.is_true(Auth:getStatus().connected)
        Auth.http = { request = function() error("Bearer secret") end }
        ok, code = Auth:getAccessContext()
        assert.are.equal("network_error", code)
        assert.is_true(Auth:getStatus().connected)
        Auth.http = { request = function() return true, 400, json.encode({ error = { type = "invalid_grant" } }) end }
        ok, code = Auth:getAccessContext()
        assert.are.equal("invalid_grant", code)
        assert.are.same({ connected = false }, Auth:getStatus())
    end)
    it("rejects a refreshed token lacking inference scope without overwriting", function()
        seed(now - 1)
        respond(200, tokens({ scope = "user:profile" }))
        local ok, code = Auth:getAccessContext()
        assert.is_nil(ok)
        assert.are.equal("missing_scope", code)
        assert.are.equal("old-access", Store:load(path).access_token)
    end)
    it("serializes refresh against a concurrent holder of the store lock", function()
        seed(now - 1)
        local release = assert(Store:acquire(path))
        local ok, code = Auth:getAccessContext()
        release()
        assert.is_nil(ok)
        assert.are.equal("auth_busy", code)
        assert.are.equal(0, #calls)
    end)
    it("persists rotated tokens even if the caller abandons the request", function()
        seed(now - 1)
        respond(200, tokens({ refresh_token = "rotated" }))
        Auth:getAccessContext()
        local other = dofile("xray.koplugin/xray_anthropic_auth.lua")
        other.store_path, other.store, other.now = path, Store, Auth.now
        assert.are.same({ access_token = "fake-access", expires_at = now + 3600 }, other:getAccessContext())
    end)
    it("logout removes only the dedicated store and no messages leak secrets", function()
        seed(now + 1000)
        assert.is_true(Auth:logout())
        assert.are.same({ connected = false }, Auth:getStatus())
        local ok, code, message = Auth:getAccessContext()
        assert.is_nil(ok)
        assert.are.equal("not_connected", code)
        assert.is_nil(message:find("old", 1, true))
        assert.are.equal(0, #calls)
    end)
    it("contains no API-key creation or unused capability endpoints", function()
        local source = assert(io.open("xray.koplugin/xray_anthropic_auth.lua", "rb")):read("*a")
        for _, forbidden in ipairs({ "api_keys", "create_api_key\"", "/api/oauth/profile",
            "claude_cli", "mcp_servers/", "/v1/files" }) do
            assert.is_nil(source:find(forbidden, 1, true))
        end
        local urls = {}
        for url in source:gmatch("\"(https://[^\"]+)\"") do urls[#urls + 1] = url end
        table.sort(urls)
        assert.are.same({ "https://claude.com/cai/oauth/authorize",
            "https://platform.claude.com/oauth/code/callback",
            "https://platform.claude.com/v1/oauth/token" }, urls)
    end)
    it("uses the dedicated default store path", function()
        local root = os.tmpname()
        os.remove(root)
        local previous = package.loaded.datastorage
        package.loaded.datastorage = { getSettingsDir = function() return root .. "/settings" end }
        local fresh = dofile("xray.koplugin/xray_anthropic_auth.lua")
        local seen
        fresh.store = { load = function(_, p) seen = p return nil, "not_connected" end }
        fresh:getStatus()
        package.loaded.datastorage = previous
        assert.are.equal(root .. "/settings/xray/anthropic_auth.json", seen)
    end)
end)
