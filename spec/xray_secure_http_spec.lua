-- All transport tests inject the complete HTTP/socket stack. No live network.
describe("Verified subscription HTTP", function()
    local HTTP, ca, config, seen, clock, deps
    before_each(function()
        HTTP = dofile("xray.koplugin/xray_secure_http.lua")
        ca = os.tmpname()
        local file = assert(io.open(ca, "wb"))
        file:write("-----BEGIN CERTIFICATE-----\nFAKE TEST CERTIFICATE\n-----END CERTIFICATE-----\n")
        file:close()
        HTTP.ca_file = ca
        clock = 100
        config = { names = { "auth.openai.com" }, status = 200, handshake = true, chain = true }
        seen = { connects = 0, sends = 0, receives = 0, timeouts = {} }
        local raw = {
            settimeout = function(_, value, mode)
                seen.timeouts[#seen.timeouts + 1] = { value = value, mode = mode }
                return 1
            end,
            connect = function(_, host, port)
                seen.connects = seen.connects + 1
                seen.host, seen.port = host, port
                return 1
            end,
            close = function() seen.closed = true return 1 end,
        }
        local tls = {
            settimeout = raw.settimeout, close = raw.close,
            sni = function(_, host) seen.sni = host end,
            dohandshake = function() return config.handshake end,
            getpeerverification = function() return config.chain end,
            getpeercertificate = function()
                return { extensions = function()
                    return { ["2.5.29.17"] = { dNSName = config.names } }
                end }
            end,
            send = function(_, body) seen.sends = seen.sends + 1 return #body end,
            receive = function()
                seen.receives = seen.receives + 1
                return "header"
            end,
        }
        deps = {
            socket = { tcp = function() return raw end, gettime = function() return clock end },
            ssl = { wrap = function(_, options)
                seen.options = options
                if config.missing_verification then tls.getpeerverification = nil end
                return tls
            end },
            ltn12 = { source = { string = function(body) return function() return body end end } },
            http = { request = function(request)
                seen.request = request
                local conn = request.create()
                conn:settimeout(60)
                conn:connect(config.connect_host or request.headers.host, 443)
                conn:send("FAKE-SECRET")
                if config.slow_headers then
                    clock = clock + 11
                    conn:receive("*l")
                    clock = clock + 5
                    conn:receive("*l")
                end
                request.sink("response")
                conn:close()
                return 1, config.status, { location = "https://evil.example/" }
            end },
        }
        HTTP.dependencies = deps
    end)
    after_each(function() if ca then os.remove(ca) end end)
    local function request(url)
        return HTTP:request(url or "https://auth.openai.com/oauth/token", "POST", {
            Authorization = "Bearer FAKE-SECRET", ["Content-Type"] = "application/json",
        }, "{}", 15)
    end

    it("requires no TLS backend or network during module load", function()
        local fresh = dofile("xray.koplugin/xray_secure_http.lua")
        assert.is_table(fresh)
        assert.are.equal(0, seen.connects)
    end)
    it("verifies chain, SNI and SAN before sending any HTTP bytes", function()
        local ok, status, body = request()
        assert.is_true(ok)
        assert.are.equal(200, status)
        assert.are.equal("response", body)
        assert.are.equal("peer", seen.options.verify)
        assert.are.equal(ca, seen.options.cafile)
        assert.are.equal("auth.openai.com", seen.sni)
        assert.are.equal(443, seen.port)
        assert.is_false(seen.request.redirect)
        assert.are.equal(1, seen.sends)
        assert.is_true(seen.closed)
    end)
    it("rejects untrusted chains before sending credentials", function()
        config.chain = false
        local ok, code = request()
        assert.is_nil(ok)
        assert.are.equal("tls_failed", code)
        assert.are.equal(0, seen.sends)
        assert.is_true(seen.closed)
    end)
    it("rejects failed TLS handshakes before sending credentials", function()
        config.handshake = false
        local ok, code = request()
        assert.is_nil(ok)
        assert.are.equal("tls_failed", code)
        assert.are.equal(0, seen.sends)
    end)
    it("rejects a trusted certificate for another hostname before HTTP bytes", function()
        config.names = { "evil.example" }
        local ok, code = request()
        assert.is_nil(ok)
        assert.are.equal("tls_failed", code)
        assert.are.equal(0, seen.sends)
    end)
    it("fails closed if runtime cannot report peer verification", function()
        config.missing_verification = true
        local ok, code = request()
        assert.is_nil(ok)
        assert.are.equal("tls_unavailable", code)
        assert.are.equal(0, seen.sends)
    end)
    it("matches exact and case-insensitive SAN names and one-label wildcard", function()
        assert.is_true(HTTP:matchesHostname({ "AUTH.OPENAI.COM" }, "auth.openai.com"))
        assert.is_true(HTTP:matchesHostname({ "*.openai.com" }, "auth.openai.com"))
        assert.is_true(HTTP:matchesHostname({ "chatgpt.com" }, "chatgpt.com"))
    end)
    it("rejects SAN wildcard overreach, partial wildcards, NUL and CN-only", function()
        for _, name in ipairs({ "*.com", "*.auth.openai.com", "a*.openai.com", "*.*.com",
            "auth.openai.com.evil.example", "auth.openai.com\0.evil.example", "auth.openai.com." }) do
            assert.is_false(HTTP:matchesHostname({ name }, "auth.openai.com"))
        end
        assert.is_false(HTTP:matchesHostname({ "*.chatgpt.com" }, "chatgpt.com"))
        assert.is_false(HTTP:matchesHostname(nil, "auth.openai.com"))
        config.names = nil
        local ok, code = request()
        assert.is_nil(ok)
        assert.are.equal("tls_failed", code)
        assert.are.equal(0, seen.sends)
    end)
    it("rejects every redirect without following location", function()
        for _, status in ipairs({ 301, 302, 303, 307, 308 }) do
            config.status = status
            local ok, code, message, headers = request()
            assert.is_nil(ok)
            assert.are.equal("redirect_rejected", code)
            assert.is_nil(message:find("FAKE-SECRET", 1, true))
            assert.are.same({}, headers)
        end
        assert.are.equal(5, seen.connects)
    end)
    it("rejects nonofficial hosts, URL credentials, ports and malformed schemes", function()
        for _, url in ipairs({
            "http://auth.openai.com/oauth/token", "https://evil.example/", "https://api.openai.com/",
            "https://auth.openai.com.evil.example/", "https://user@auth.openai.com/",
            "https://auth.openai.com:443/", "https://auth.openai.com/#fragment",
            "https://auth.openai.com/\r\nHost: evil.example", "https://auth.openai.com\\@evil.example/",
        }) do
            local ok, code = request(url)
            assert.is_nil(ok)
            assert.are.equal("invalid_url", code)
        end
        assert.are.equal(0, seen.connects)
    end)
    it("rejects Host and proxy/header overrides before connecting", function()
        for _, header in ipairs({ "Host", "host", "Proxy-Authorization", "Transfer-Encoding", "Content-Length" }) do
            local ok, code = HTTP:request("https://auth.openai.com/", "POST", { [header] = "evil" }, "{}")
            assert.is_nil(ok)
            assert.are.equal("invalid_request", code)
        end
        local ok = HTTP:request("https://auth.openai.com/", "POST", { Authorization = "x\r\ny" }, "{}")
        assert.is_nil(ok)
        deps.http.PROXY = "http://evil.example"
        assert.is_nil(request())
        assert.are.equal(0, seen.connects)
    end)
    it("rejects a changed connect target before opening a socket connection", function()
        config.connect_host = "evil.example"
        local ok, code = request()
        assert.is_nil(ok)
        assert.are.equal("invalid_url", code)
        assert.are.equal(0, seen.connects)
        assert.are.equal(0, seen.sends)
    end)
    it("fails closed on an invalid explicit CA without fallback", function()
        HTTP.ca_file = ca .. ".missing"
        local ok, code = request()
        assert.is_nil(ok)
        assert.are.equal("ca_unavailable", code)
        assert.are.equal(0, seen.connects)
    end)
    it("falls back to the module-relative bundle when OS trust stores are absent", function()
        HTTP.ca_file = nil
        local original_open, opened = io.open, {}
        io.open = function(path, mode)
            opened[#opened + 1] = path
            if path == "xray.koplugin/certs/ca-bundle.crt" then return original_open(ca, mode) end
            return nil
        end
        local protected, ok, status = pcall(request)
        io.open = original_open
        assert.is_true(protected)
        assert.is_true(ok)
        assert.are.equal(200, status)
        assert.are.equal("xray.koplugin/certs/ca-bundle.crt", seen.options.cafile)
        assert.are.equal(4, #opened)
    end)
    it("fails closed if neither system nor plugin CA bundle is present", function()
        HTTP.ca_file = nil
        local original_open = io.open
        io.open = function() return nil end
        local protected, ok, code = pcall(request)
        io.open = original_open
        assert.is_true(protected)
        assert.is_nil(ok)
        assert.are.equal("ca_unavailable", code)
        assert.are.equal(0, seen.connects)
    end)
    it("uses the remaining total deadline for slow headers", function()
        config.slow_headers = true
        local ok, code = request()
        assert.is_nil(ok)
        assert.are.equal("network_error", code)
        assert.are.equal(1, seen.receives)
        local last = seen.timeouts[#seen.timeouts]
        assert.are.equal(4, last.value)
        assert.are.equal("t", last.mode)
        assert.is_true(seen.closed)
    end)
    it("sanitizes thrown backend errors", function()
        deps.http.request = function() error("Authorization: Bearer FAKE-SECRET") end
        local ok, code, message = request()
        assert.is_nil(ok)
        assert.are.equal("network_error", code)
        assert.is_nil(message:find("FAKE-SECRET", 1, true))
    end)
    it("allows exactly the pinned Anthropic hosts with SAN/SNI verification", function()
        for _, host in ipairs({ "platform.claude.com", "api.anthropic.com" }) do
            config.names = { host }
            local ok, status = request("https://" .. host .. "/v1/messages")
            assert.is_true(ok)
            assert.are.equal(200, status)
            assert.are.equal(host, seen.sni)
            assert.are.equal("peer", seen.options.verify)
        end
        config.names = { "api.anthropic.com" }
        local ok, code = request("https://platform.claude.com/v1/oauth/token")
        assert.is_nil(ok)
        assert.are.equal("tls_failed", code)
    end)
    it("isolates the configured relay from credential-bearing auth requests", function()
        for _, origin in ipairs({ "https://xray.example.com", "https://xray-setup.ultimatejimmy.workers.dev" }) do
            local host = origin:sub(9)
            config.names = { host }
            local ok, status = HTTP:requestRelay(origin, "/api/session/create", "POST", {}, "{}", 10)
            assert.is_true(ok) assert.are.equal(200, status)
            assert.are.equal(host, seen.sni)
            assert.are.equal(origin .. "/api/session/create", seen.request.url)
            assert.are.equal("peer", seen.options.verify)
            assert.is_false(seen.request.redirect)
            local denied, reason = request(origin .. "/api/session/create")
            assert.is_nil(denied) assert.are.equal("invalid_url", reason)
        end
        config.names = { "*.example.com" }
        assert.is_true(HTTP:requestRelay("https://xray.example.com", "/api/session/AB12CD/poll", "GET", {}, nil, 4))
    end)
    it("never widens token hosts after a relay call and rejects relay credentials and arbitrary paths", function()
        config.names = { "xray.example.com" }
        local origin = "https://xray.example.com"
        for _, headers in ipairs({ { Authorization = "Bearer FAKE-SECRET" }, { Cookie = "FAKE" },
            { ["X-Api-Key"] = "FAKE" }, { ["X-Goog-Api-Key"] = "FAKE" },
            { ["Anthropic-Api-Key"] = "FAKE" }, { Host = "evil.example" }, { ["Proxy-Authorization"] = "FAKE" } }) do
            assert.is_nil(HTTP:requestRelay(origin, "/api/session/create", "POST", headers, "{}", 10))
        end
        for _, path in ipairs({ "/oauth/token", "//evil.example/", "/api/session/AB12CD/poll?token=FAKE",
            "/api/session/../poll", "/api/session/AB12CD/poll#secret" }) do
            assert.is_nil(HTTP:requestRelay(origin, path, "GET", {}, nil, 10))
        end
        assert.is_nil(HTTP:requestRelay(origin, "/api/session/create", "POST", {}, '{"token":"FAKE"}', 10))
        assert.is_nil(HTTP:requestRelay("http://xray.example.com", "/api/session/create", "POST", {}, "{}", 10))
        assert.are.equal(0, seen.connects)
        assert.is_true(HTTP:requestRelay(origin, "/api/session/create", "POST", {}, "{}", 10))
        assert.is_nil(request(origin .. "/oauth/token"))
        config.names = { "auth.openai.com" }
        assert.is_true(request())
    end)
    it("requires the configured relay's certificate and rejects redirects", function()
        config.names = { "evil.example" }
        local ok, reason = HTTP:requestRelay("https://xray.example.com", "/api/session/create", "POST", {}, "{}", 10)
        assert.is_nil(ok) assert.are.equal("tls_failed", reason)
        assert.are.equal(0, seen.sends)
        config.names = { "xray.example.com" }
        config.status = 302
        ok, reason = HTTP:requestRelay("https://xray.example.com", "/api/session/create", "POST", {}, "{}", 10)
        assert.is_nil(ok) assert.are.equal("redirect_rejected", reason)
        assert.is_false(seen.request.redirect)
    end)
    it("rejects unpinned Anthropic and Claude hosts before connecting", function()
        local connects = seen.connects
        for _, url in ipairs({ "https://claude.com/cai/oauth/authorize", "https://claude.ai/",
            "https://console.anthropic.com/", "https://anthropic.com/", "https://evil.api.anthropic.com/",
            "https://api.anthropic.com.evil.example/", "http://api.anthropic.com/v1/messages",
            "https://api.anthropic.com:443/v1/messages" }) do
            local ok, code = request(url)
            assert.is_nil(ok)
            assert.are.equal("invalid_url", code)
        end
        assert.are.equal(connects, seen.connects)
    end)
    it("preserves a validated caller User-Agent and defaults otherwise", function()
        request()
        assert.are.equal("X-Ray KOReader (experimental subscription integration)",
            seen.request.headers["user-agent"])
        config.names = { "api.anthropic.com" }
        HTTP:request("https://api.anthropic.com/v1/messages", "POST", { ["User-Agent"] = "claude-cli/1.0 (external, cli)" }, "{}", 15)
        assert.are.equal("claude-cli/1.0 (external, cli)", seen.request.headers["user-agent"])
        local connects = seen.connects
        local ok, code = HTTP:request("https://api.anthropic.com/v1/messages", "POST", { ["User-Agent"] = "x\r\nHost: evil" }, "{}", 15)
        assert.is_nil(ok)
        assert.are.equal("invalid_request", code)
        assert.are.equal(connects, seen.connects)
    end)
    -- Updater policy: public GitHub hosts only, never credentials, never
    -- widening the subscription host set (and vice versa).
    it("keeps the updater's public GitHub policy separate from subscription hosts", function()
        config.names = { "*.github.com" }
        local ok, status = HTTP:requestPublic("https://codeload.github.com/o/r/zip/abc", {}, 30)
        assert.is_true(ok)
        assert.are.equal(200, status)
        assert.are.equal("GET", seen.request.method)
        assert.is_false(seen.request.redirect)
        assert.are.equal("codeload.github.com", seen.sni)

        local connects = seen.connects
        for _, case in ipairs({
            { "https://auth.openai.com/oauth/token", {} },          -- auth host via public route
            { "https://evil.github.com/x", {} },                     -- unlisted GitHub host
            { "https://api.github.com/x", { Authorization = "Bearer FAKE-SECRET" } },
            { "https://api.github.com/x", { Cookie = "session=FAKE" } },
        }) do
            local rejected = HTTP:requestPublic(case[1], case[2], 30)
            assert.is_nil(rejected)
        end
        local via_auth, code = HTTP:request("https://api.github.com/x", "GET", {}, nil, 15)
        assert.is_nil(via_auth)
        assert.are.equal("invalid_url", code)
        assert.are.equal(connects, seen.connects)
    end)
end)
