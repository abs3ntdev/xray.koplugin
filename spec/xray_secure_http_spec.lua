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
    it("allows only the exact pinned setup relay host with verified TLS", function()
        local relay = "xray-setup.ultimatejimmy.workers.dev"
        config.names = { "*.ultimatejimmy.workers.dev" }
        local ok, status = request("https://" .. relay .. "/api/session/AB12CD/poll")
        assert.is_true(ok)
        assert.are.equal(200, status)
        assert.are.equal(relay, seen.sni)
        assert.are.equal("peer", seen.options.verify)
        config.names = { "*.workers.dev" }
        local bad, code = request("https://" .. relay .. "/api/session/create")
        assert.is_nil(bad)
        assert.are.equal("tls_failed", code)
        local connects = seen.connects
        for _, url in ipairs({ "https://evil.ultimatejimmy.workers.dev/", "https://ultimatejimmy.workers.dev/",
            "https://x.xray-setup.ultimatejimmy.workers.dev/", "https://xray-setup.ultimatejimmy.workers.dev.evil/",
            "http://" .. relay .. "/", "https://" .. relay .. ":443/", "https://" .. relay .. "/#secret",
            "https://XRAY-SETUP.ultimatejimmy.workers.dev/", "https://" .. relay }) do
            local denied, reason = request(url)
            assert.is_nil(denied)
            assert.are.equal("invalid_url", reason)
        end
        assert.are.equal(connects, seen.connects)
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
end)
