-- Verified subscription-only transport. No network or TLS module loading on require.
-- KOReader base currently bundles LuaSec 1.3.2. Its ssl.https does NOT
-- validate hostnames, so use LuaSocket HTTP framing over our verified socket.
-- Sources: koreader-base/thirdparty/luasec/CMakeLists.txt and
-- brunoos/luasec v1.3.2 src/{https.lua,x509.c}. Unknown backends fail closed.
local SecureHTTP = {}
-- Relative to this module's source path (KOReader keeps its working directory).
-- This path is provisioned by the release, never downloaded by authentication.
local source = debug.getinfo(1, "S").source
local plugin_directory = source:match("^@(.*/)")
local bundled_ca = plugin_directory and plugin_directory .. "certs/ca-bundle.crt"
-- Exact subscription hosts only. Anthropic hosts pinned from Jcode commit
-- 02777ce1bea392f03af4eda48c5292bb48946646 (auth/oauth.rs TOKEN_URL and the
-- anthropic provider Messages endpoint). No wildcard or speculative hosts.
-- The setup relay host is the one pinned, deployed X-Ray pairing relay. It only
-- ever carries end-to-end encrypted, fragment-keyed ciphertext (never tokens or
-- bearer headers); see xray_code_transfer.lua. It is not user-configurable.
local allowed = {
    ["auth.openai.com"] = true, ["chatgpt.com"] = true,
    ["platform.claude.com"] = true, ["api.anthropic.com"] = true,
    ["xray-setup.ultimatejimmy.workers.dev"] = true,
    -- Optional TypeSafe Jev decision API (docs.typesafe.ai/api), exact host.
    ["api.typesafe.ai"] = true,
}
local messages = {
    invalid_url = "Only official subscription HTTPS endpoints are allowed.",
    invalid_request = "The secure request was rejected.",
    tls_unavailable = "Verified TLS is unavailable. Update KOReader before signing in.",
    ca_unavailable = "A trusted CA bundle is unavailable. Update KOReader's certificates.",
    tls_failed = "The secure connection could not be verified. Check the reader's clock and CA certificates.",
    network_error = "The secure connection failed. Check connectivity and try again.",
    redirect_rejected = "The service redirected the request. No credentials were forwarded.",
}
local function failure(code)
    return nil, code, messages[code] or messages.network_error, {}
end

-- SAN-only matching, deliberately no legacy Common Name fallback. A wildcard
-- covers exactly one label and never a public suffix or a partial label.
function SecureHTTP:matchesHostname(names, hostname)
    if type(names) ~= "table" or not allowed[hostname] then return false end
    for _, name in ipairs(names) do
        if type(name) == "string" and not name:find("[^%w%.%*%-]") then
            name = name:lower()
            if name == hostname then return true end
            local suffix = name:match("^%*%.([%w%-]+%.[%w%.%-]+)$")
            if suffix and not suffix:find("*", 1, true) then
                local first, rest = hostname:match("^([^.]+)%.(.+)$")
                if first and rest == suffix then return true end
            end
        end
    end
    return false
end

local function trustedCA(self)
    -- Explicit configuration must not silently fall back if invalid.
    -- KOReader's LuaSec build does not establish a bundled CA location.
    -- Use an explicitly provisioned bundle, standard OS trust stores, or our
    -- release-provisioned Mozilla PEM (https://curl.se/docs/caextract.html).
    -- Missing files fail closed. The auth path never fetches trust anchors.
    local paths = self.ca_file and { self.ca_file } or {
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/cert.pem",
        bundled_ca,
    }
    for _, path in ipairs(paths) do
        local file = io.open(path, "rb")
        if file then
            local prefix = file:read(65536) or ""
            file:close()
            if prefix:find("-----BEGIN CERTIFICATE-----", 1, true) then return path end
        end
    end
end

function SecureHTTP:request(url, method, headers, body, timeout)
    if type(url) ~= "string" or url:find("[%c%s\\#]") then return failure("invalid_url") end
    local host, path = url:match("^https://([a-z0-9%.%-]+)(/.*)$")
    if not allowed[host] or not path then return failure("invalid_url") end
    method = method or "POST"
    if method ~= "POST" and method ~= "GET" then return failure("invalid_request") end
    if body ~= nil and type(body) ~= "string" then return failure("invalid_request") end
    if headers ~= nil and type(headers) ~= "table" then return failure("invalid_request") end
    local safe_headers = {}
    for key, value in pairs(headers or {}) do
        if type(key) ~= "string" or not key:match("^[%w%-]+$") or type(value) ~= "string"
            or value:find("[%c]") then return failure("invalid_request") end
        local lower = key:lower()
        if lower == "host" or lower == "proxy-authorization" or lower == "connection"
            or lower == "transfer-encoding" or lower == "content-length" then
            return failure("invalid_request")
        end
        safe_headers[lower] = value
    end
    safe_headers.host = host
    safe_headers.connection = "close"
    safe_headers["content-length"] = tostring(#(body or ""))
    -- A caller-supplied, already validated User-Agent is preserved (the
    -- experimental Claude route pins Jcode's compatibility identity). Absent
    -- one, the default X-Ray identity is used.
    if not safe_headers["user-agent"] or #safe_headers["user-agent"] > 256 then
        safe_headers["user-agent"] = "X-Ray KOReader (experimental subscription integration)"
    end
    timeout = tonumber(timeout) or 15
    if timeout ~= timeout or timeout <= 0 or timeout > 600 then return failure("invalid_request") end

    -- Dependency injection is only for deterministic tests. Production always
    -- uses the actual LuaSec socket API, never global ssl.https.cert_verify.
    local ok_deps, deps = pcall(function()
        return self.dependencies or {
            socket = require("socket"), ssl = require("ssl"),
            http = require("socket.http"), ltn12 = require("ltn12"),
        }
    end)
    if not ok_deps or type(deps.ssl.wrap) ~= "function" or type(deps.socket.tcp) ~= "function"
        or type(deps.http.request) ~= "function" then return failure("tls_unavailable") end
    if deps.http.PROXY then return failure("invalid_request") end
    local ca = trustedCA(self)
    if not ca then return failure("ca_unavailable") end
    local active, verified, transport_error
    local started = (deps.socket.gettime or os.time)()
    local chunks, size = {}, 0
    local function close()
        if active then pcall(active.close, active) end
        active = nil
    end
    local function abort(code)
        transport_error = code
        close()
        error("secure transport failure", 0)
    end
    local function boundTimeout()
        local remaining = timeout - ((deps.socket.gettime or os.time)() - started)
        if remaining <= 0 then abort("network_error") end
        if not active:settimeout(remaining, "b") or not active:settimeout(remaining, "t") then
            abort("network_error")
        end
        return 1
    end
    local function create()
        local raw = deps.socket.tcp()
        if not raw then abort("network_error") end
        active = raw
        local conn = {}
        function conn:settimeout()
            return boundTimeout()
        end
        function conn:connect(request_host, port)
            if request_host ~= host or tonumber(port) ~= 443 then abort("invalid_url") end
            boundTimeout()
            if not active:connect(host, 443) then abort("network_error") end
            local wrapped = deps.ssl.wrap(active, {
                mode = "client", protocol = "any", verify = "peer", cafile = ca,
                options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
            })
            if not wrapped then abort("tls_failed") end
            active = wrapped
            if type(active.sni) ~= "function" or type(active.getpeercertificate) ~= "function"
                or type(active.getpeerverification) ~= "function" then abort("tls_unavailable") end
            active:sni(host)
            boundTimeout()
            if not active:dohandshake() or not active:getpeerverification() then abort("tls_failed") end
            local cert = active:getpeercertificate()
            if not cert or type(cert.extensions) ~= "function" then abort("tls_unavailable") end
            local extensions = cert:extensions()
            local san = extensions and extensions["2.5.29.17"]
            if not SecureHTTP:matchesHostname(san and san.dNSName, host) then abort("tls_failed") end
            verified = true
            return 1
        end
        function conn:send(...)
            if not verified then abort("tls_failed") end
            boundTimeout()
            return active:send(...)
        end
        function conn:receive(...)
            boundTimeout()
            return active:receive(...)
        end
        function conn:getfd() return active:getfd() end
        function conn:dirty() return active:dirty() end
        function conn:close() close() return 1 end
        return conn
    end
    local protected, ok, status, response_headers = pcall(deps.http.request, {
        url = url, method = method, headers = safe_headers,
        source = body and deps.ltn12.source.string(body) or nil,
        sink = function(chunk)
            if (deps.socket.gettime or os.time)() - started > timeout then return nil, "timeout" end
            if chunk then
                size = size + #chunk
                if size > 16 * 1024 * 1024 then return nil, "response too large" end
                chunks[#chunks + 1] = chunk
            end
            return 1
        end,
        create = create, redirect = false,
    })
    close()
    if not protected or not ok or not verified then return failure(transport_error or "network_error") end
    status = tonumber(status)
    if not status then return failure("network_error") end
    if status >= 300 and status < 400 then return failure("redirect_rejected") end
    return true, status, table.concat(chunks), response_headers or {}
end

return SecureHTTP
