-- EXPERIMENTAL, UNOFFICIAL Claude account OAuth (manual code#state PKCE flow).
-- Not endorsed by Anthropic. Wire protocol pinned from the public Jcode source
-- at commit 02777ce1bea392f03af4eda48c5292bb48946646,
-- crates/jcode-base/src/auth/oauth.rs (claude module, claude_auth_url,
-- parse_claude_code_input, exchange_claude_code_at_url, refresh_claude_tokens).
-- Deliberate hardening versus that source: state is an INDEPENDENT random value
-- (not the PKCE verifier), state is REQUIRED on completion, flows are single-use,
-- expire, and are invalidated by a persisted epoch across processes.
-- No credential reads, network, entropy or platform dependencies at load time.
local name = ... or "xray_anthropic_auth"
local prefix = name:match("^(.*[/%.])") or ""
local Auth = {}

local CLIENT = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
local AUTHORIZE_URL = "https://claude.com/cai/oauth/authorize"
local TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
local REDIRECT_URI = "https://platform.claude.com/oauth/code/callback"
local SCOPES = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
local REFRESH_SCOPES = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
local FLOW_LIFETIME = 600
-- Scope policy: authorize requests Jcode's exact Claude Code scope string for
-- compatibility (the pinned source gives no evidence that a reduced set is
-- accepted by the authorize endpoint, and live testing is out of scope).
-- Only user:inference is REQUIRED and enforced. X-Ray never uses the others:
-- no API-key creation (org:create_api_key; Jcode itself drops it on refresh),
-- no profile, sessions, MCP or file-upload endpoints are implemented or
-- reachable (SecureHTTP allows only the token and Messages hosts).
Auth.CLIENT_ID, Auth.AUTHORIZE_URL, Auth.TOKEN_URL = CLIENT, AUTHORIZE_URL, TOKEN_URL
Auth.REDIRECT_URI, Auth.SCOPES, Auth.REFRESH_SCOPES = REDIRECT_URI, SCOPES, REFRESH_SCOPES

local messages = {
    not_connected = "Connect your Claude account first.",
    auth_busy = "Another account operation is in progress. Try again shortly.",
    store_unavailable = "The private account store is unavailable.",
    store_invalid = "The saved account is invalid. Sign out and reconnect.",
    store_write_failed = "Account credentials could not be saved safely. Reconnect before trying again.",
    entropy_unavailable = "Secure randomness is unavailable on this device. Sign-in cannot start safely.",
    invalid_code = "The authorization code is missing or malformed. Paste the full code#state value.",
    state_mismatch = "The authorization code does not belong to this sign-in. Start sign-in again.",
    invalid_grant = "Your Claude session has expired or was revoked. Reconnect your account.",
    missing_scope = "Claude did not grant inference access to this sign-in. Reconnect your account.",
    invalid_response = "Claude returned an unexpected authentication response.",
    network_error = "Unable to reach Claude securely. Check your connection and try again.",
    auth_failed = "Claude could not authorize this account. Start sign-in again.",
    cancelled = "Sign-in was cancelled.",
    expired = "The sign-in link expired. Start sign-in again.",
    tls_unavailable = "Verified TLS is unavailable. Update KOReader before signing in.",
    ca_unavailable = "A trusted CA bundle is unavailable. Update KOReader's certificates.",
    tls_failed = "The secure connection could not be verified. Check the reader's clock and certificates.",
    redirect_rejected = "Claude redirected authentication. No credentials were forwarded.",
}
local function fail(code)
    code = messages[code] and code or "auth_failed"
    return nil, code, messages[code]
end
local function clock(self) return (self.now or os.time)() end
local function text(value, limit)
    return type(value) == "string" and #value > 0 and #value <= (limit or 32768) and not value:find("[%c%s]")
end
local function finite(value)
    return type(value) == "number" and value == value and value > 0 and value < math.huge
end
local function valid(credential)
    return type(credential) == "table" and text(credential.access_token)
        and text(credential.refresh_token) and finite(credential.expires_at)
end
local function dependencies(self)
    local path = self.store_path
    if not path then
        local storage = require("datastorage")
        local settings = storage:getSettingsDir()
        if type(settings) == "string" and settings:sub(1, 1) ~= "/" then
            local root = storage:getFullDataDir()
            if type(root) ~= "string" or root:sub(1, 1) ~= "/" then error("invalid settings directory") end
            settings = root .. "/settings"
        end
        path = settings .. "/xray/anthropic_auth.json"
    end
    return self.store or require(prefix .. "xray_auth_store"), path
end
local function decode(raw)
    if type(raw) ~= "string" or #raw > 1024 * 1024 then return nil end
    local ok, result = pcall(require("json").decode, raw)
    if ok and type(result) == "table" then return result end
end

-- Cryptographic entropy only: /dev/urandom or an injected test hook. There is
-- deliberately NO math.random or time-based fallback. Short reads fail closed.
local function entropy(self, count)
    local ok, bytes = pcall(function()
        if self.random then return self.random(count) end
        local file = io.open("/dev/urandom", "rb")
        if not file then return nil end
        local data = file:read(count)
        file:close()
        return data
    end)
    if ok and type(bytes) == "string" and #bytes == count then return bytes end
end
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function base64url(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local chars = 2 + (b and 1 or 0) + (c and 1 or 0)
        for j = 1, chars do
            local shift = 2 ^ (6 * (4 - j))
            local index = math.floor(n / shift) % 64
            out[#out + 1] = B64:sub(index + 1, index + 1)
        end
    end
    return table.concat(out)
end
Auth._base64url = base64url
local function urlencode(value)
    return (value:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function urldecode(value)
    return (value:gsub("%+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
local function constantEqual(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        if a:byte(i) ~= b:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

local function request(self, value)
    local transport = self.http or require(prefix .. "xray_secure_http")
    local protected, ok, status, raw = pcall(transport.request, transport, TOKEN_URL, "POST", {
        ["Content-Type"] = "application/json", ["Accept"] = "application/json",
    }, require("json").encode(value), 15)
    if not protected then return nil, "network_error" end
    if not ok then return nil, messages[status] and status or "network_error" end
    return decode(raw), tonumber(status) or 0
end
local function errorCode(data)
    if type(data) ~= "table" then return nil end
    local err = data.error
    if type(err) == "table" then err = err.type or err.code end
    return type(err) == "string" and err or nil
end
local function scopesOf(value)
    local list = {}
    if type(value) == "string" then
        for scope in value:gmatch("%S+") do list[scope] = true end
    end
    return list
end
-- Returns credential or nil,error_code. Refresh responses may omit the
-- refresh_token (Jcode keeps the previous one). Scope, when present, must
-- include user:inference. Tokens never leave this module except via context.
local function credentialFrom(self, data, previous_refresh)
    if type(data) ~= "table" or not text(data.access_token) or not finite(data.expires_in)
        or data.expires_in > 10 * 365 * 86400 then return nil, "invalid_response" end
    local refresh = data.refresh_token
    if refresh == nil then refresh = previous_refresh end
    if not text(refresh) then return nil, "invalid_response" end
    if data.scope ~= nil then
        if type(data.scope) ~= "string" then return nil, "invalid_response" end
        if not scopesOf(data.scope)["user:inference"] then return nil, "missing_scope" end
    end
    return { access_token = data.access_token, refresh_token = refresh,
        expires_at = clock(self) + data.expires_in }
end
local function context(credential)
    return { access_token = credential.access_token, expires_at = credential.expires_at }
end
local function guarded(self, callback)
    if self._busy then return fail("auth_busy") end
    self._busy = true
    local release
    local ok, a, b, c = pcall(function()
        local store, path = dependencies(self)
        local code
        release, code = store:acquire(path)
        if not release then return fail(code) end
        return callback(store, path)
    end)
    if release then pcall(release) end
    self._busy = nil
    if not ok then return fail("store_unavailable") end
    return a, b, c
end
local function generation(store, path, advance)
    local metadata, code = store:load(path .. ".generation")
    if not metadata and code ~= "not_connected" then return nil, code end
    local current = metadata and metadata.generation or 0
    if type(current) ~= "number" or current < 0 or current >= 9007199254740991
        or current ~= math.floor(current) then return nil, "store_invalid" end
    if advance then
        current = current + 1
        local saved, save_code = store:save(path .. ".generation", { generation = current })
        if not saved then return nil, save_code end
    end
    return current
end
local function scrub(flow)
    if type(flow) == "table" then flow._verifier, flow._state = nil, nil end
end

-- Local presence only; does not prove subscription entitlement. No token data.
function Auth:getStatus()
    local ok, stored = pcall(function()
        local store, path = dependencies(self)
        return store:load(path)
    end)
    if not ok or not valid(stored) then return { connected = false } end
    return { connected = true, expires_at = stored.expires_at }
end

function Auth:startLogin()
    -- Entropy first: never advance the epoch or touch storage without it.
    local verifier_bytes, state_bytes = entropy(self, 32), entropy(self, 32)
    if not verifier_bytes or not state_bytes or verifier_bytes == state_bytes then
        return fail("entropy_unavailable")
    end
    local verifier, state = base64url(verifier_bytes), base64url(state_bytes)
    local ok_hash, digest = pcall(function()
        return require(prefix .. "xray_crypto"):sha256(verifier)
    end)
    if not ok_hash or type(digest) ~= "string" or #digest ~= 32 then return fail("auth_failed") end
    local challenge = base64url(digest)
    return guarded(self, function(store, path)
        -- Persisted non-secret epoch: logout or a newer login in any process
        -- invalidates older pending flows.
        local epoch, epoch_code = generation(store, path, true)
        if not epoch then return fail(epoch_code) end
        self._generation = epoch
        if self._flow then self._flow.cancelled = true scrub(self._flow) end
        local url = AUTHORIZE_URL .. "?code=true&client_id=" .. CLIENT
            .. "&response_type=code&redirect_uri=" .. urlencode(REDIRECT_URI)
            .. "&scope=" .. urlencode(SCOPES) .. "&code_challenge=" .. challenge
            .. "&code_challenge_method=S256&state=" .. state
        local flow = { authorization_url = url, expires_at = clock(self) + FLOW_LIFETIME,
            _verifier = verifier, _state = state, _generation = epoch }
        self._flow = flow
        return flow
    end)
end

-- Accepts `code#state`, or the full official callback URL / its query string.
-- State is mandatory. Returns code, state or nil.
local function parseInput(input)
    if type(input) ~= "string" or #input > 8192 then return nil end
    input = input:match("^%s*(.-)%s*$")
    local code, state
    if input:find("code=", 1, true) then
        local query
        if input:match("^[%a][%w+.-]*:") or input:find("/", 1, true) then
            -- Only the exact official callback URL is accepted as a URL.
            local base, rest = input:match("^([^?#]+)%?(.*)$")
            if base ~= REDIRECT_URI then return nil end
            query = rest
        else
            query = input:gsub("^%?", "")
        end
        local fragment_state
        query, fragment_state = query:match("^([^#]*)#?(.*)$")
        for pair in query:gmatch("[^&]+") do
            local key, value = pair:match("^([^=]+)=(.*)$")
            if key == "code" then
                if code then return nil end -- duplicate parameters are ambiguous
                code = urldecode(value)
            elseif key == "state" then
                if state then return nil end
                state = urldecode(value)
            end
        end
        if code and code:find("#", 1, true) then code, state = code:match("^([^#]*)#(.*)$") end
        if (not state or state == "") and fragment_state ~= "" then state = fragment_state end
    else
        code, state = input:match("^([^#]+)#(.+)$")
    end
    if not text(code, 4096) or not text(state, 512) then return nil end
    return code, state
end
Auth._parseInput = parseInput

local function flowState(self, flow)
    if type(flow) ~= "table" or flow.cancelled or flow._used or self._flow ~= flow
        or flow._generation ~= self._generation or not flow._verifier then return "cancelled" end
    if not finite(flow.expires_at) or clock(self) >= flow.expires_at then return "expired" end
end

function Auth:completeLogin(flow, code_text)
    local state = flowState(self, flow)
    if state then
        if state == "expired" then scrub(flow) end
        return fail(state)
    end
    local code, returned_state = parseInput(code_text)
    if not code then return fail("invalid_code") end
    if not constantEqual(returned_state, flow._state) then return fail("state_mismatch") end
    -- Single use from here on: a code is never exchanged twice, even on failure.
    flow._used = true
    local verifier, expected_state = flow._verifier, flow._state
    scrub(flow)
    return guarded(self, function(store, path)
        local epoch, epoch_code = generation(store, path)
        if not epoch then return fail(epoch_code) end
        if epoch ~= flow._generation then
            flow.cancelled = true
            return fail("cancelled")
        end
        local data, status = request(self, {
            grant_type = "authorization_code", code = code, redirect_uri = REDIRECT_URI,
            client_id = CLIENT, code_verifier = verifier, state = expected_state,
        })
        if flow.cancelled or self._flow ~= flow or flow._generation ~= self._generation then
            return fail("cancelled")
        end
        if type(status) == "string" then return fail(status) end
        if errorCode(data) == "invalid_grant" then return fail("invalid_grant") end
        if status ~= 200 then return fail("auth_failed") end
        local credential, credential_code = credentialFrom(self, data)
        if not credential then return fail(credential_code) end
        -- Re-check the epoch immediately before persisting (logout elsewhere).
        local latest = generation(store, path)
        if latest ~= flow._generation then return fail("cancelled") end
        local saved, save_code = store:save(path, credential)
        if not saved then return fail(save_code) end
        flow._complete = true
        self._flow = nil
        return true
    end)
end

-- Never deletes an already connected account.
function Auth:cancelLogin(flow)
    if type(flow) == "table" then
        flow.cancelled = true
        scrub(flow)
        if self._flow == flow then self._flow = nil end
    end
    return true
end

local function refresh(self, refresh_token, scope)
    return request(self, { grant_type = "refresh_token", refresh_token = refresh_token,
        client_id = CLIENT, scope = scope })
end

-- Parent process only, before any model-request fork. Refresh and the rotated
-- token save happen under the store lock and complete before returning,
-- regardless of whether the caller's request is later cancelled.
function Auth:getAccessContext(force_refresh)
    return guarded(self, function(store, path)
        local stored, load_code = store:load(path)
        if not stored then return fail(load_code) end
        if not valid(stored) then return fail("store_invalid") end
        if not force_refresh and stored.expires_at > clock(self) + 300 then return context(stored) end
        local tokens, status = refresh(self, stored.refresh_token, REFRESH_SCOPES)
        if type(status) == "string" then return fail(status) end
        -- Jcode retries once without scope for legacy tokens on invalid_scope.
        if status ~= 200 and errorCode(tokens) == "invalid_scope" then
            tokens, status = refresh(self, stored.refresh_token, nil)
            if type(status) == "string" then return fail(status) end
        end
        if errorCode(tokens) == "invalid_grant" then
            local cleared, clear_code = store:clear(path)
            if not cleared then return fail(clear_code) end
            return fail("invalid_grant")
        end
        if status ~= 200 then return fail("auth_failed") end
        local credential, credential_code = credentialFrom(self, tokens, stored.refresh_token)
        if not credential then return fail(credential_code) end
        local saved, save_code = store:save(path, credential)
        if not saved then return fail(save_code) end
        return context(credential)
    end)
end

-- Local sign-out only. No remote revocation is claimed or attempted.
function Auth:logout()
    self._generation = (self._generation or 0) + 1
    if self._flow then self._flow.cancelled = true scrub(self._flow) end
    self._flow = nil
    return guarded(self, function(store, path)
        local epoch, epoch_code = generation(store, path, true)
        local ok, code = store:clear(path)
        if not ok then return fail(code) end
        if not epoch then return fail(epoch_code) end
        return true
    end)
end

return Auth
