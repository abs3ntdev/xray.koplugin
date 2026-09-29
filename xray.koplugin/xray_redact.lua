-- xray_redact.lua: best-effort redaction of KNOWN secret shapes in log text.
-- This cannot detect arbitrary unknown secrets. Callers must still avoid
-- passing raw credentials or raw auth/model response bodies to logs, and
-- should prefer fixed safe error messages.
--
-- API:
--   Redact.redact(value)         -> string (non-strings are tostring()'d first)
--   Redact.register(secret)      -> registers an exact secret value (>= 8 chars)
--   Redact.unregister(secret)
--   Redact.clear_registered()

local Redact = { _registered = {} }

local MASK = "[REDACTED]"

local function escape_pattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- Ordered list of {pattern, replacement}. Lua patterns only.
local RULES = {
    -- Authorization headers / bearer tokens
    { "([Bb][Ee][Aa][Rr][Ee][Rr]%s+)[%w%-%._~%+/=]+", "%1" .. MASK },
    -- JWT (three base64url segments, header starting with eyJ)
    { "eyJ[%w%-_]+%.[%w%-_]+%.[%w%-_]*", MASK },
    -- OpenAI / Anthropic / OpenRouter style keys
    { "sk%-[%w%-_]+", MASK },
    -- Google API keys
    { "AIza[%w%-_]+", MASK },
    { "AQ%.[%w%-_%.]+", MASK },
    -- JSON fields holding credentials: "access_token":"..." etc.
    { "(\"[%w_]*[Tt][Oo][Kk][Ee][Nn]\"%s*:%s*\")[^\"]*\"", "%1" .. MASK .. "\"" },
    { "(\"[%w_]*[Aa][Pp][Ii]_?[Kk][Ee][Yy]\"%s*:%s*\")[^\"]*\"", "%1" .. MASK .. "\"" },
    { "(\"[%w_]*[Ss][Ee][Cc][Rr][Ee][Tt]\"%s*:%s*\")[^\"]*\"", "%1" .. MASK .. "\"" },
    { "(\"[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]\"%s*:%s*\")[^\"]*\"", "%1" .. MASK .. "\"" },
    -- Query/form parameters: token=..., api_key=..., key=...
    { "([%?&%s][%w_]*token=)[^&%s\"]+", "%1" .. MASK },
    { "([%?&%s]api_?key=)[^&%s\"]+", "%1" .. MASK },
    { "([%?&]key=)[^&%s\"]+", "%1" .. MASK },
    -- Header-style key lines
    { "([Xx]%-[Aa][Pp][Ii]%-[Kk][Ee][Yy]%s*:%s*)%S+", "%1" .. MASK },
}

function Redact.register(secret)
    if type(secret) == "string" and #secret >= 8 then
        Redact._registered[secret] = true
    end
end

function Redact.unregister(secret)
    if type(secret) == "string" then Redact._registered[secret] = nil end
end

function Redact.clear_registered()
    Redact._registered = {}
end

function Redact.redact(value)
    local ok, s = pcall(tostring, value)
    if not ok or type(s) ~= "string" then return "[unprintable]" end
    -- Registered exact secrets first (longest first to avoid partial leaks)
    local list = {}
    for secret in pairs(Redact._registered) do list[#list + 1] = secret end
    table.sort(list, function(a, b) return #a > #b end)
    for _, secret in ipairs(list) do
        s = s:gsub(escape_pattern(secret), MASK)
    end
    for _, rule in ipairs(RULES) do
        s = s:gsub(rule[1], rule[2])
    end
    return s
end

Redact.MASK = MASK

return Redact
