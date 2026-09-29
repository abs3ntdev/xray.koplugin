-- Experimental Codex device OAuth adapter, modeled on Pi commit
-- cb7969d212836b8939001dce159fbd2ed6ad395f, openai-codex.ts.
-- No credential reads, network, or platform dependencies at module load time.
local name = ... or "xray_openai_auth"
local prefix = name:match("^(.*[/%.])") or ""
local Auth = {}
local BASE = "https://auth.openai.com"
local CLIENT = "app_EMoamEEZ73f0CkXaXp7hrann"
local messages = {
    not_connected = "Sign in with ChatGPT first.",
    auth_busy = "Another account operation is in progress. Try again shortly.",
    store_unavailable = "The private account store is unavailable.",
    store_invalid = "The saved account is invalid. Sign out and reconnect.",
    store_write_failed = "Account credentials could not be saved safely. Reconnect before trying again.",
    invalid_grant = "Your ChatGPT session has expired or was revoked. Reconnect your account.",
    invalid_response = "OpenAI returned an unexpected authentication response.",
    network_error = "Unable to reach OpenAI securely. Check your connection and try again.",
    auth_failed = "OpenAI could not authorize this account. Check device login permissions and try again.",
    cancelled = "Sign-in was cancelled.",
    expired = "The sign-in code expired. Start sign-in again.",
    denied = "Sign-in was declined. Start again if you wish to connect.",
    tls_unavailable = "Verified TLS is unavailable. Update KOReader before signing in.",
    ca_unavailable = "A trusted CA bundle is unavailable. Update KOReader's certificates.",
    tls_failed = "The secure connection could not be verified. Check the reader's clock and certificates.",
    redirect_rejected = "OpenAI redirected authentication. No credentials were forwarded.",
}
local function fail(code)
    code = messages[code] and code or "auth_failed"
    return nil, code, messages[code]
end
local function clock(self) return (self.now or os.time)() end
local function text(value, limit)
    return type(value) == "string" and #value > 0 and #value <= (limit or 32768) and not value:find("[%c]")
end
local function finite(value)
    return type(value) == "number" and value == value and value > 0 and value < math.huge
end
local function valid(credential)
    return type(credential) == "table" and text(credential.access_token)
        and text(credential.refresh_token) and text(credential.account_id, 256)
        and credential.account_id:match("^[%w_-]+$") and finite(credential.expires_at)
end
local function dependencies(self)
    local path = self.store_path
    if not path then
        local storage = require("datastorage")
        local settings = storage:getSettingsDir()
        -- E-readers normally return './settings'. getFullDataDir resolves the
        -- trusted KOReader root without weakening absolute-only test overrides.
        if type(settings) == "string" and settings:sub(1, 1) ~= "/" then
            local root = storage:getFullDataDir()
            if type(root) ~= "string" or root:sub(1, 1) ~= "/" then error("invalid settings directory") end
            settings = root .. "/settings"
        end
        path = settings .. "/xray/openai_auth.json"
    end
    return self.store or require(prefix .. "xray_auth_store"), path
end
local function decode(raw)
    if type(raw) ~= "string" or #raw > 1024 * 1024 then return nil end
    local ok, result = pcall(require("json").decode, raw)
    if ok and type(result) == "table" then return result end
end
local function form(values)
    local function escape(value)
        return (value:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
    end
    local result = {}
    for key, value in pairs(values) do result[#result + 1] = escape(key) .. "=" .. escape(value) end
    table.sort(result)
    return table.concat(result, "&")
end
local function request(self, endpoint, value, as_form)
    local body = as_form and form(value) or require("json").encode(value)
    local transport = self.http or require(prefix .. "xray_secure_http")
    local protected, ok, status, raw = pcall(transport.request, transport, BASE .. endpoint, "POST", {
        ["Content-Type"] = as_form and "application/x-www-form-urlencoded" or "application/json",
        ["Accept"] = "application/json",
    }, body, 15)
    if not protected then return nil, "network_error" end
    if not ok then return nil, messages[status] and status or "network_error" end
    return decode(raw), tonumber(status) or 0
end
local function errorCode(data)
    if type(data) ~= "table" then return nil end
    return type(data.error) == "table" and data.error.code or data.error
end

-- JWT payload is used only as metadata from the verified token endpoint, not
-- as independent proof of authentication. No JWT/token is exposed in status.
local function accountId(token)
    local payload = token:match("^[^.]+%.([A-Za-z0-9_%-=]+)%.[^.]+$")
    if not payload then return nil end
    payload = payload:gsub("-", "+"):gsub("_", "/"):gsub("=+$", "")
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local result, bits, count = {}, 0, 0
    for i = 1, #payload do
        local position = alphabet:find(payload:sub(i, i), 1, true)
        if not position then return nil end
        bits, count = bits * 64 + position - 1, count + 6
        if count >= 8 then
            count = count - 8
            local power = 2 ^ count
            result[#result + 1] = string.char(math.floor(bits / power))
            bits = bits % power
        end
    end
    local claims = decode(table.concat(result))
    local auth = claims and claims["https://api.openai.com/auth"]
    local id = type(auth) == "table" and auth.chatgpt_account_id
    if text(id, 256) and id:match("^[%w_-]+$") then return id end
end
local function credentialFrom(self, data)
    if type(data) ~= "table" or not text(data.access_token) or not text(data.refresh_token)
        or not finite(data.expires_in) then return nil end
    local id = accountId(data.access_token)
    if not id then return nil end
    return { access_token = data.access_token, refresh_token = data.refresh_token,
        account_id = id, expires_at = clock(self) + data.expires_in }
end
local function context(credential)
    return { access_token = credential.access_token, account_id = credential.account_id,
        expires_at = credential.expires_at }
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

function Auth:getStatus()
    local ok, stored = pcall(function()
        local store, path = dependencies(self)
        return store:load(path)
    end)
    if not ok or not valid(stored) then return { connected = false } end
    return { connected = true, account_id = stored.account_id, expires_at = stored.expires_at }
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

function Auth:startDeviceLogin()
    return guarded(self, function(store, path)
        -- Persist a non-secret epoch under the same lock as token writes. A
        -- logout/new login in another process invalidates older pending flows.
        local epoch, epoch_code = generation(store, path, true)
        if not epoch then return fail(epoch_code) end
        self._generation = epoch
        if self._flow then self._flow.cancelled = true end
        local data, status = request(self, "/api/accounts/deviceauth/usercode", { client_id = CLIENT })
        if type(status) == "string" then return fail(status) end
        if status ~= 200 then return fail("auth_failed") end
        local interval = data and tonumber(data.interval)
        if not data or not text(data.device_auth_id, 1024) or not text(data.user_code, 128)
            or not interval or interval ~= interval or interval < 0 or interval > 900 then
            return fail("invalid_response")
        end
        local flow = { device_auth_id = data.device_auth_id, user_code = data.user_code,
            verification_uri = BASE .. "/codex/device", interval = math.max(1, interval),
            expires_at = clock(self) + 900, _generation = epoch }
        self._flow = flow
        return flow
    end)
end

local function flowState(self, flow)
    if type(flow) ~= "table" or flow.cancelled or self._flow ~= flow
        or flow._generation ~= self._generation then return "cancelled" end
    if not finite(flow.expires_at) or clock(self) >= flow.expires_at then return "expired" end
end
function Auth:pollDeviceLogin(flow)
    local state = flowState(self, flow)
    if state then return state == "expired" and "expired" or "error", messages[state] end
    if flow._complete then return "complete" end
    if flow._terminal then return flow._terminal, messages[flow._terminal] end
    if flow._next_poll and clock(self) < flow._next_poll then return "pending" end
    local result, code, message = guarded(self, function(store, path)
        local epoch, epoch_code = generation(store, path)
        if not epoch then return fail(epoch_code) end
        if epoch ~= flow._generation then
            flow.cancelled = true
            return fail("cancelled")
        end
        local data, status = request(self, "/api/accounts/deviceauth/token", {
            device_auth_id = flow.device_auth_id, user_code = flow.user_code,
        })
        local interrupted = flowState(self, flow)
        if interrupted then return fail(interrupted) end
        flow._next_poll = clock(self) + flow.interval
        if type(status) == "string" then return fail(status) end
        local err = errorCode(data)
        if err == "slow_down" or status == 429 then
            flow.interval = flow.interval + 5
            flow._next_poll = clock(self) + flow.interval
            return "slow_down"
        end
        if err == "expired_token" or err == "deviceauth_expired" then return fail("expired") end
        if err == "access_denied" or err == "authorization_declined" then return fail("denied") end
        -- Pi's pinned protocol treats 403/404 as pending, not denial.
        if status == 403 or status == 404 or err == "authorization_pending"
            or err == "deviceauth_authorization_pending" then return "pending" end
        if status ~= 200 then return fail("auth_failed") end
        if not data or not text(data.authorization_code) or not text(data.code_verifier) then
            return fail("invalid_response")
        end
        local tokens, token_status = request(self, "/oauth/token", {
            grant_type = "authorization_code", client_id = CLIENT,
            code = data.authorization_code, code_verifier = data.code_verifier,
            redirect_uri = BASE .. "/deviceauth/callback",
        }, true)
        interrupted = flowState(self, flow)
        if interrupted then return fail(interrupted) end
        if type(token_status) == "string" then return fail(token_status) end
        if token_status ~= 200 then return fail("auth_failed") end
        local credential = credentialFrom(self, tokens)
        if not credential then return fail("invalid_response") end
        local saved, save_code = store:save(path, credential)
        if not saved then return fail(save_code) end
        flow._complete = true
        return "complete"
    end)
    if result then return result end
    if code == "expired" or code == "denied" then
        flow._terminal = code
        return code, message
    end
    return "error", message
end

-- Called only in the parent before model-request fork. Never rotate in a
-- cancellable request child. A successful refresh is persisted before return,
-- independently of the original UI request's cancellation state.
function Auth:getAccessContext(force_refresh)
    return guarded(self, function(store, path)
        local stored, load_code = store:load(path)
        if not stored then return fail(load_code) end
        if not valid(stored) then return fail("store_invalid") end
        if not force_refresh and stored.expires_at > clock(self) + 60 then return context(stored) end
        local tokens, status = request(self, "/oauth/token", {
            grant_type = "refresh_token", client_id = CLIENT, refresh_token = stored.refresh_token,
        }, true)
        if type(status) == "string" then return fail(status) end
        if errorCode(tokens) == "invalid_grant" then
            local cleared, clear_code = store:clear(path)
            if not cleared then return fail(clear_code) end
            return fail("invalid_grant")
        end
        if status ~= 200 then return fail("auth_failed") end
        local credential = credentialFrom(self, tokens)
        if not credential then return fail("invalid_response") end
        local saved, save_code = store:save(path, credential)
        if not saved then return fail(save_code) end
        return context(credential)
    end)
end

function Auth:logout()
    self._generation = (self._generation or 0) + 1
    if self._flow then self._flow.cancelled = true end
    self._flow = nil
    return guarded(self, function(store, path)
        local epoch, epoch_code = generation(store, path, true)
        -- Even corrupt/unwritable metadata must not prevent local secret removal.
        local ok, code = store:clear(path)
        if not ok then return fail(code) end
        if not epoch then return fail(epoch_code) end
        return true
    end)
end

return Auth
