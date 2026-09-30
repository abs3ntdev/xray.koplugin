-- Receive a short authorization code from a phone through the deployed X-Ray
-- setup relay, used purely as an opaque end-to-end encrypted carrier.
--
-- Trust model: the 32-byte key lives only in the URL fragment shown in the QR
-- code and never reaches the relay. The relay operator serves the page's
-- JavaScript, so a malicious operator could exfiltrate what is typed on the
-- phone, and the relay can always deny service. The relay has no consume or
-- cancel API, so ciphertext stays there until its TTL. This client accepts at
-- most one result per session. Only the full raw 64-hex secret is ever used as
-- the key: no session-ID derived, default, padded or weak-RNG keys.
local name = ... or "xray_code_transfer"
local prefix = name:match("^(.*[/%.])") or ""

local RelayConfig = require(prefix .. "xray_relay_config")
local MAX_LIFETIME = 600
local MAX_RESPONSE = 16384
local MAX_B64 = 8192
local MAX_PLAIN = 4096
local MAX_CODE = 2048

local Transfer = {}

local messages = {
    entropy_unavailable = "A secure random key could not be generated on this device.",
    invalid_request = "The phone transfer could not be started.",
    invalid_relay = RelayConfig.ERROR,
    relay_error = "The phone transfer relay could not be reached. Check Wi-Fi and try again.",
    expired = "The phone transfer expired. Start again.",
    cancelled = "The phone transfer was cancelled.",
    consumed = "The phone transfer was already completed.",
}
local function failure(code)
    return nil, code, messages[code] or messages.relay_error
end

local function now(self)
    local ok, value = pcall(self.time or os.time)
    return ok and tonumber(value) or nil
end

local function randomBytes(self)
    if self.entropy then
        local ok, raw = pcall(self.entropy, 32)
        return ok and type(raw) == "string" and #raw == 32 and raw or nil
    end
    local ok, file = pcall(io.open, "/dev/urandom", "rb")
    if not ok or not file then return nil end
    local ok_read, raw = pcall(file.read, file, 32)
    pcall(file.close, file)
    return ok_read and type(raw) == "string" and #raw == 32 and raw or nil
end

local function toHex(bytes)
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function fromHex(hex)
    return (hex:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end))
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local lookup = {}
for i = 1, #B64 do lookup[B64:byte(i)] = i - 1 end

-- Canonical, bounded, strict base64. Rejects whitespace, bad characters,
-- misplaced padding and non-zero trailing bits.
function Transfer.strictBase64Decode(data)
    if type(data) ~= "string" or data == "" or #data > MAX_B64 or #data % 4 ~= 0 then return nil end
    local pad = data:match("(=*)$")
    if #pad > 2 or data:sub(1, #data - #pad):find("[^A-Za-z0-9+/]") then return nil end
    local out = {}
    for i = 1, #data, 4 do
        local a, b = lookup[data:byte(i)], lookup[data:byte(i + 1)]
        local c, d = lookup[data:byte(i + 2)], lookup[data:byte(i + 3)]
        if not a or not b then return nil end
        local last = i + 3 == #data
        if not c then
            if not last or pad ~= "==" or b % 16 ~= 0 then return nil end
            out[#out + 1] = string.char(a * 4 + math.floor(b / 16))
        elseif not d then
            if not last or pad ~= "=" or c % 4 ~= 0 then return nil end
            out[#out + 1] = string.char(a * 4 + math.floor(b / 16), (b % 16) * 16 + math.floor(c / 4))
        else
            out[#out + 1] = string.char(a * 4 + math.floor(b / 16), (b % 16) * 16 + math.floor(c / 4),
                (c % 4) * 64 + d)
        end
    end
    return table.concat(out)
end

-- Strict decryption: exactly 64 lowercase/uppercase hex characters of key,
-- "HMAC:" prefixed canonical base64, and the page's HMAC-SHA256 CTR + tag.
function Transfer:decrypt(payload, secret_hex)
    if type(secret_hex) ~= "string" or not secret_hex:match("^%x+$") or #secret_hex ~= 64 then return nil end
    if type(payload) ~= "string" or payload:sub(1, 5) ~= "HMAC:" then return nil end
    local raw = Transfer.strictBase64Decode(payload:sub(6))
    if not raw or #raw < 33 or #raw - 32 > MAX_PLAIN then return nil end
    local crypto = self.crypto or require(prefix .. "xray_crypto")
    local ok, plain = pcall(crypto.decryptHMACStream, crypto, raw, fromHex(secret_hex))
    if not ok or type(plain) ~= "string" then return nil end
    return plain
end

local function json()
    return require("json")
end

function Transfer:generateSecret()
    local raw = randomBytes(self)
    return raw and toHex(raw) or nil
end

function Transfer:start(expires_at, settings)
    local current = now(self)
    expires_at = tonumber(expires_at)
    if not current or not expires_at or expires_at ~= expires_at or expires_at <= current then
        return failure("expired")
    end
    if expires_at > current + MAX_LIFETIME then expires_at = current + MAX_LIFETIME end
    -- Entropy must be available before any network request is made.
    local relay = RelayConfig.resolve(settings or self.settings)
    if not relay then return failure("invalid_relay") end
    local secret = self:generateSecret()
    if not secret then return failure("entropy_unavailable") end
    local transport = self.http or require(prefix .. "xray_secure_http")
    local ok, status, body = transport:requestRelay(relay, "/api/session/create", "POST",
        { ["Content-Type"] = "application/json", ["Accept"] = "application/json" }, "{}", 10)
    if not ok or status ~= 200 or type(body) ~= "string" or #body > MAX_RESPONSE then
        return failure("relay_error")
    end
    local ok_json, data = pcall(json().decode, body)
    local id = ok_json and type(data) == "table" and data.session_id
    if type(id) ~= "string" or not id:match("^[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$") then
        return failure("relay_error")
    end
    local after = now(self)
    if not after or after >= expires_at then return failure("expired") end
    return {
        id = id, expires_at = expires_at, relay_url = relay,
        url = relay .. "/?s=" .. id .. "#" .. secret,
        secret = secret,
    }
end

function Transfer:poll(session)
    if type(session) ~= "table" then return failure("invalid_request") end
    if session.cancelled then return failure("cancelled") end
    if session.consumed then return failure("consumed") end
    local current = now(self)
    if not current or not session.expires_at or current >= session.expires_at then
        self:cancel(session)
        return failure("expired")
    end
    local secret, id = session.secret, session.id
    if type(secret) ~= "string" or type(id) ~= "string" or not id:match("^[A-Z0-9]+$") or #id ~= 6 then
        return failure("invalid_request")
    end
    local relay = RelayConfig.normalize(session.relay_url)
    if not relay then return failure("invalid_relay") end
    local transport = self.http or require(prefix .. "xray_secure_http")
    -- Short, deadline-capped timeout limits how long a poll can block the UI.
    local timeout = math.max(1, math.min(4, session.expires_at - current))
    local ok, status, body = transport:requestRelay(relay, "/api/session/" .. id .. "/poll", "GET",
        { ["Accept"] = "application/json" }, nil, timeout)
    -- The session may have been cancelled or expired while the request ran.
    if session.cancelled then return failure("cancelled") end
    if session.consumed then return failure("consumed") end
    local after = now(self)
    if not after or after >= session.expires_at then
        self:cancel(session)
        return failure("expired")
    end
    if not ok or status == 204 then return nil, "pending" end
    -- 404 can be transient (eventually consistent KV), so it stays pending
    -- until local expiry. Only 410 Gone is terminal.
    if status == 410 then
        self:cancel(session)
        return failure("expired")
    end
    if status ~= 200 or type(body) ~= "string" or #body > MAX_RESPONSE then return nil, "pending" end
    local ok_json, data = pcall(json().decode, body)
    if not ok_json or type(data) ~= "table" or data.status ~= "ready" then return nil, "pending" end
    local plain = self:decrypt(data.payload, secret)
    if not plain then return nil, "pending" end
    local ok_obj, obj = pcall(json().decode, plain)
    local code = ok_obj and type(obj) == "table" and obj.api_key
    if type(code) ~= "string" then return nil, "pending" end
    code = code:match("^%s*(.-)%s*$")
    if code == "" or #code > MAX_CODE or code:find("%c") then return nil, "pending" end
    -- Recheck after decryption so the module stands alone against late cancel.
    if session.cancelled then return failure("cancelled") end
    if session.consumed then return failure("consumed") end
    local final = now(self)
    if not final or final >= session.expires_at then
        self:cancel(session)
        return failure("expired")
    end
    session.consumed = true
    session.secret, session.url = nil, nil
    return code
end

function Transfer:cancel(session)
    if type(session) ~= "table" then return end
    session.cancelled = true
    session.secret, session.url = nil, nil
end

-- Factory for dependency injection (tests): http, crypto, entropy, time.
function Transfer.new(deps)
    local instance = setmetatable({}, { __index = Transfer })
    for k, v in pairs(deps or {}) do instance[k] = v end
    return instance
end

return Transfer
