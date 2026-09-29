-- xray_anthropic_messages.lua
-- Pure request builder and SSE decoder for the EXPERIMENTAL, UNOFFICIAL
-- "Claude subscription" provider (provider id: anthropic_account).
--
-- Not endorsed by Anthropic. Anthropic may restrict subscription OAuth use by
-- third-party clients; this exists only as a personal, opt-in integration.
--
-- Wire provenance (source read only, no live traffic observed by this code):
--   jcode commit 02777ce1bea392f03af4eda48c5292bb48946646
--   * crates/jcode-provider-anthropic-runtime/src/lib.rs
--       API_URL_OAUTH = "https://api.anthropic.com/v1/messages?beta=true"
--       API_VERSION = "2023-06-01", Bearer auth, stream = true (SSE)
--   * crates/jcode-provider-core/src/anthropic.rs
--       ANTHROPIC_OAUTH_BETA_HEADERS, OAUTH_BILLING_HEADER (compat 2.1.280)
--   * crates/jcode-provider-anthropic/src/lib.rs
--       OAuth system blocks: billing-header block, then the Agent SDK identity
--   * crates/jcode-base/src/provider/anthropic.rs
--       apply_oauth_attribution_headers (x-app, session id, browser-access)
-- Deliberate differences: no tools, no thinking, no cache_control, no
-- x-stainless-* headers. The User-Agent is the pinned compatibility string
-- (protocol metadata only). Client rejections/challenges are surfaced as
-- safe errors and never bypassed.
--
-- This module performs no network I/O and never reads credentials itself.
-- Error strings produced here never contain tokens or raw response bodies.

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end
if not ok_json then
    ok_json, json = pcall(require, "dkjson")
end

local Messages = {}

Messages.PROVIDER_ID = "anthropic_account"
Messages.DEFAULT_MODEL = "claude-sonnet-5"
-- Real Claude IDs from jcode ALL_CLAUDE_MODELS (02777ce1) that X-Ray offers.
Messages.MODELS = { "claude-opus-5-5", "claude-sonnet-5", "claude-sonnet-5-5", "claude-haiku-4-5" }
-- Pinned endpoint. Never substituted by custom endpoint settings.
Messages.ENDPOINT = "https://api.anthropic.com/v1/messages?beta=true"
Messages.API_VERSION = "2023-06-01"
Messages.BETA_HEADERS = "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,context-management-2025-06-27,prompt-caching-scope-2026-01-05,advisor-tool-2026-03-01,advanced-tool-use-2025-11-20,effort-2025-11-24"
Messages.COMPAT_VERSION = "2.1.280"
Messages.USER_AGENT = "claude-cli/2.1.280 (external, sdk-cli)"
Messages.BILLING_BLOCK = "x-anthropic-billing-header: cc_version=2.1.280; cc_entrypoint=sdk-cli; cch=33f85;"
Messages.IDENTITY_BLOCK = "You are a Claude agent, built on Anthropic's Claude Agent SDK."
Messages.MAX_TOKENS = 32000
Messages.STREAM_FORMAT = "anthropic_messages"

local VALID_MODEL = {}
for _, m in ipairs(Messages.MODELS) do VALID_MODEL[m] = true end

function Messages.isSupportedModel(model)
    return VALID_MODEL[model] == true
end

local function validSessionId(s)
    return type(s) == "string" and s:match("^[%x%-]+$") ~= nil and #s >= 8 and #s <= 64
end

-- opts: { model, instructions, prompt, access_token, session_id }
-- Returns request table or nil, error_code, safe_message.
function Messages.buildRequest(opts)
    opts = opts or {}
    if type(opts.access_token) ~= "string" or opts.access_token == "" then
        return nil, "error_auth", "Claude subscription is not signed in."
    end
    if not validSessionId(opts.session_id) then
        return nil, "error_auth", "Claude session information is missing. Please retry."
    end
    local model = opts.model
    if not VALID_MODEL[model] then model = Messages.DEFAULT_MODEL end

    local body = {
        model = model,
        max_tokens = Messages.MAX_TOKENS,
        system = {
            { type = "text", text = Messages.BILLING_BLOCK },
            { type = "text", text = Messages.IDENTITY_BLOCK },
            { type = "text", text = opts.instructions or "Return valid JSON ONLY." },
        },
        messages = {
            { role = "user", content = { { type = "text", text = opts.prompt or "" } } },
        },
        metadata = {
            user_id = json.encode({
                device_id = (opts.session_id:gsub("%-", "")),
                account_uuid = "unknown-account",
                session_id = opts.session_id,
            }),
        },
        stream = true,
    }

    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "text/event-stream",
        ["Authorization"] = "Bearer " .. opts.access_token,
        ["anthropic-version"] = Messages.API_VERSION,
        ["anthropic-beta"] = Messages.BETA_HEADERS,
        ["x-app"] = "cli",
        ["X-Claude-Code-Session-Id"] = opts.session_id,
        ["anthropic-dangerous-direct-browser-access"] = "true",
        -- Protocol compatibility metadata pinned from jcode (CLAUDE_CLI_USER_AGENT,
        -- entrypoint sdk-cli, matching the billing block and Agent SDK identity).
        -- Not a claim of being, or being endorsed by, the official client.
        ["User-Agent"] = Messages.USER_AGENT,
    }

    return {
        url = Messages.ENDPOINT,
        method = "POST",
        headers = headers,
        body = json.encode(body),
        provider = Messages.PROVIDER_ID,
        model = model,
        stream_format = Messages.STREAM_FORMAT,
        secure = true,
    }
end

function Messages.isPinnedRequest(req)
    return type(req) == "table" and req.url == Messages.ENDPOINT
        and req.provider == Messages.PROVIDER_ID
end

local function safeCode(v)
    if type(v) ~= "string" then return nil end
    local code = v:match("^[%w_%.%-]+$")
    if code and #code <= 64 then return code end
    return nil
end

function Messages.classifyHttpError(status, body)
    local code_num = tonumber(status)
    local detail
    if type(body) == "string" and body ~= "" and ok_json then
        local ok, data = pcall(json.decode, body)
        if ok and type(data) == "table" and type(data.error) == "table" then
            detail = safeCode(data.error.type)
        end
    end
    local suffix = detail and (" [" .. detail .. "]") or ""
    if code_num == 401 or code_num == 403 then
        return "error_auth", "Claude sign-in expired, was revoked or this client was refused (HTTP " .. code_num .. "). Reconnect the Claude subscription in X-Ray settings, then retry." .. suffix
    elseif code_num == 429 then
        return "error_quota", "Claude subscription usage limit reached (HTTP 429)." .. suffix
    elseif code_num and code_num >= 500 then
        return "error_api", "Claude service unavailable (HTTP " .. code_num .. "). Please retry later." .. suffix
    elseif code_num then
        return "error_api", "Claude subscription request failed (HTTP " .. code_num .. ")." .. suffix
    end
    return "error_network", "Claude subscription request failed: network error."
end

local function stripFences(s)
    s = s:gsub("^%s*```%w*%s*", ""):gsub("%s*```%s*$", "")
    return s
end

-- Decode a complete SSE body. Requires message_stop and stop_reason end_turn.
function Messages.decodeStream(response_text)
    if type(response_text) ~= "string" or response_text == "" then
        return nil, "error_incomplete", "Claude stream was empty."
    end
    local deltas = {}
    local stop_reason, stopped = nil, false
    local stream = response_text:gsub("\r\n", "\n"):gsub("\r", "\n")
    for block in (stream .. "\n\n"):gmatch("(.-)\n\n") do
        local data_lines = {}
        for line in (block .. "\n"):gmatch("(.-)\n") do
            local d = line:match("^data:(.*)$")
            if d then data_lines[#data_lines + 1] = (d:gsub("^ ", "")) end
        end
        local payload = table.concat(data_lines, "\n")
        if payload ~= "" then
            local ok, ev = pcall(json.decode, payload)
            if not ok or type(ev) ~= "table" then
                return nil, "error_parse", "Claude returned malformed stream data."
            end
            local t = ev.type
            if t == "content_block_start" then
                local cb = type(ev.content_block) == "table" and ev.content_block.type
                if cb ~= "text" and cb ~= "thinking" and cb ~= "redacted_thinking" then
                    return nil, "error_api", "Claude attempted a tool call; X-Ray does not allow tools."
                end
                if cb == "text" and type(ev.content_block.text) == "string" then
                    deltas[#deltas + 1] = ev.content_block.text
                end
            elseif t == "content_block_delta" then
                local d = ev.delta
                if type(d) == "table" and d.type == "text_delta" and type(d.text) == "string" then
                    deltas[#deltas + 1] = d.text
                elseif type(d) == "table" and d.type == "input_json_delta" then
                    return nil, "error_api", "Claude attempted a tool call; X-Ray does not allow tools."
                end
            elseif t == "message_delta" then
                if type(ev.delta) == "table" and ev.delta.stop_reason ~= nil then
                    stop_reason = ev.delta.stop_reason
                end
            elseif t == "message_stop" then
                stopped = true
            elseif t == "error" then
                local code = type(ev.error) == "table" and safeCode(ev.error.type) or nil
                if code == "rate_limit_error" then
                    return nil, "error_quota", "Claude subscription usage limit reached [" .. code .. "]."
                end
                return nil, "error_api", "Claude response failed" .. (code and (" [" .. code .. "]") or "") .. "."
            end
        end
    end
    if not stopped then
        return nil, "error_incomplete", "Claude stream ended before completion."
    end
    if stop_reason ~= "end_turn" and stop_reason ~= "stop_sequence" then
        return nil, "error_incomplete", "Claude response did not complete (" .. (safeCode(stop_reason) or "unknown") .. ")."
    end
    local text = table.concat(deltas)
    if text == "" then return nil, "error_parse", "Claude response contained no text." end
    return text
end

function Messages.validateXRayJSON(text)
    if type(text) ~= "string" then return nil, "error_parse", "Claude response contained no text." end
    local cleaned = stripFences(text)
    local first = cleaned:find("{", 1, true)
    if not first then return nil, "error_parse", "Claude response was not a JSON object." end
    cleaned = cleaned:sub(first)
    local ok, data = pcall(json.decode, cleaned)
    if not ok or type(data) ~= "table" or next(data) == nil then
        return nil, "error_parse", "Claude response was not valid X-Ray JSON."
    end
    return cleaned, data
end

function Messages.normalizeStream(response_text)
    local text, code, msg = Messages.decodeStream(response_text)
    if not text then return nil, code, msg end
    local cleaned, err_code, err_msg = Messages.validateXRayJSON(text)
    if not cleaned then return nil, err_code, err_msg end
    return json.encode({
        choices = { { finish_reason = "stop", message = { role = "assistant", content = cleaned } } },
    }), cleaned
end

function Messages.errorEnvelope(code, message)
    return json.encode({ error = { code = code, message = message } })
end

return Messages
