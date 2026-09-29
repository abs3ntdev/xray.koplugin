-- xray_openai_responses.lua
-- Pure request builder and SSE decoder for the experimental
-- "ChatGPT subscription" provider (provider id: openai_account).
--
-- The request shape follows the observed Codex subscription adapters
-- (Pi cb7969d2, OpenCode 7945de20): Responses-style `instructions` + `input`,
-- `store = false`, `stream = true`, bearer token plus chatgpt-account-id.
-- Chat Completions only fields (max_tokens, max_completion_tokens,
-- response_format, messages) are deliberately NOT sent. No tools are offered.
--
-- This module performs no network I/O and never reads credentials itself.
-- Error strings produced here never contain tokens or raw response bodies.

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local Responses = {}

Responses.PROVIDER_ID = "openai_account"
Responses.DEFAULT_MODEL = "gpt-6-luna"
-- Pinned endpoint. Never substituted by custom endpoint settings.
Responses.ENDPOINT = "https://chatgpt.com/backend-api/codex/responses"
-- Truthful client identity (not impersonating the Codex CLI).
Responses.ORIGINATOR = "xray_koplugin"
Responses.USER_AGENT = "KOReader-XRay-Plugin"
Responses.STREAM_FORMAT = "openai_responses"

local VALID_EFFORTS = { minimal = true, low = true, medium = true, high = true, xhigh = true }

-- Build the request table consumed by AIHelper (sync and async paths).
-- opts: { model, instructions, prompt, reasoning_effort, access_token, account_id }
-- Returns request table or nil, error_code, safe_message.
function Responses.buildRequest(opts)
    opts = opts or {}
    if type(opts.access_token) ~= "string" or opts.access_token == "" then
        return nil, "error_auth", "ChatGPT subscription is not signed in."
    end
    if type(opts.account_id) ~= "string" or opts.account_id == "" then
        return nil, "error_auth", "ChatGPT account information is missing. Please reconnect."
    end
    local model = opts.model
    if type(model) ~= "string" or model == "" then model = Responses.DEFAULT_MODEL end

    local body = {
        model = model,
        store = false,
        stream = true,
        instructions = opts.instructions or "Return valid JSON ONLY.",
        input = {
            {
                role = "user",
                content = { { type = "input_text", text = opts.prompt or "" } },
            },
        },
        text = { verbosity = "medium" },
    }
    if opts.reasoning_effort and VALID_EFFORTS[opts.reasoning_effort] then
        body.reasoning = { effort = opts.reasoning_effort, summary = "auto" }
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "text/event-stream",
        ["Authorization"] = "Bearer " .. opts.access_token,
        ["chatgpt-account-id"] = opts.account_id,
        ["OpenAI-Beta"] = "responses=experimental",
        ["originator"] = Responses.ORIGINATOR,
        -- User-Agent is set by SecureHTTP to its own truthful X-Ray identity.
    }

    return {
        url = Responses.ENDPOINT,
        method = "POST",
        headers = headers,
        body = json.encode(body),
        provider = Responses.PROVIDER_ID,
        model = model,
        stream_format = Responses.STREAM_FORMAT,
        secure = true,       -- must use verified SecureHTTP, even in forked children
        no_fallback = true,  -- subscription-primary never falls through to paid providers
    }
end

function Responses.isPinnedRequest(req)
    return type(req) == "table" and req.url == Responses.ENDPOINT
end

local function safeCode(v)
    if type(v) ~= "string" then return nil end
    -- Only keep short identifier-like codes (e.g. "rate_limit_exceeded").
    local code = v:match("^[%w_%.%-]+$")
    if code and #code <= 64 then return code end
    return nil
end

-- Map a non-200 HTTP status to (error_code, safe_message). Never echoes body.
function Responses.classifyHttpError(status, body)
    local code_num = tonumber(status)
    local detail
    if type(body) == "string" and body ~= "" and ok_json then
        local ok, data = pcall(json.decode, body)
        if ok and type(data) == "table" then
            local err = data.error or data.detail
            if type(err) == "table" then detail = safeCode(err.code) or safeCode(err.type) end
        end
    end
    local suffix = detail and (" [" .. detail .. "]") or ""
    if code_num == 401 or code_num == 403 then
        return "error_auth", "ChatGPT sign-in expired or was revoked (HTTP " .. code_num .. "). Reconnect the ChatGPT subscription in X-Ray settings, then retry." .. suffix
    elseif code_num == 429 then
        return "error_quota", "ChatGPT subscription usage limit reached (HTTP 429). No paid API fallback was used." .. suffix
    elseif code_num and code_num >= 500 then
        return "error_api", "ChatGPT service unavailable (HTTP " .. code_num .. "). Please retry later." .. suffix
    elseif code_num then
        return "error_api", "ChatGPT subscription request failed (HTTP " .. code_num .. ")." .. suffix
    end
    return "error_network", "ChatGPT subscription request failed: network error."
end

local function stripFences(s)
    s = s:gsub("^%s*```%w*%s*", ""):gsub("%s*```%s*$", "")
    return s
end

local function outputTextFromResponse(resp)
    if type(resp) ~= "table" or type(resp.output) ~= "table" then return nil end
    local parts = {}
    for _, item in ipairs(resp.output) do
        if type(item) == "table" and item.type == "message" and type(item.content) == "table" then
            for _, c in ipairs(item.content) do
                if type(c) == "table" and c.type == "output_text" and type(c.text) == "string" then
                    parts[#parts + 1] = c.text
                end
            end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts)
end

local function hasToolCall(resp_or_item)
    if type(resp_or_item) ~= "table" then return false end
    local t = resp_or_item.type
    if type(t) == "string" and (t:find("call", 1, true) or t:find("tool", 1, true)) then return true end
    if type(resp_or_item.output) == "table" then
        for _, item in ipairs(resp_or_item.output) do
            if hasToolCall(item) then return true end
        end
    end
    return false
end

-- Decode a complete SSE body. Returns text or nil, error_code, safe_message.
-- Requires a terminal response.completed/response.done with status completed.
function Responses.decodeStream(response_text)
    if type(response_text) ~= "string" or response_text == "" then
        return nil, "error_incomplete", "ChatGPT stream was empty."
    end
    local deltas = {}
    local completed_resp = nil
    local completed = false
    local stream = response_text:gsub("\r\n", "\n"):gsub("\r", "\n")
    for block in (stream .. "\n\n"):gmatch("(.-)\n\n") do
        local data_lines = {}
        for line in (block .. "\n"):gmatch("(.-)\n") do
            local d = line:match("^data:(.*)$")
            if d then data_lines[#data_lines + 1] = (d:gsub("^ ", "")) end
        end
        local payload = table.concat(data_lines, "\n")
        if payload ~= "" and payload ~= "[DONE]" then
            local ok, ev = pcall(json.decode, payload)
            if not ok or type(ev) ~= "table" then
                return nil, "error_parse", "ChatGPT returned malformed stream data."
            end
            local t = ev.type
            if t == "response.output_text.delta" then
                if type(ev.delta) == "string" then deltas[#deltas + 1] = ev.delta end
            elseif t == "response.output_item.added" or t == "response.output_item.done" then
                if hasToolCall(ev.item) then
                    return nil, "error_api", "ChatGPT attempted a tool call; X-Ray does not allow tools."
                end
            elseif t == "response.completed" or t == "response.done" then
                local resp = ev.response
                local status = type(resp) == "table" and resp.status or nil
                if status ~= nil and status ~= "completed" then
                    return nil, "error_incomplete", "ChatGPT response did not complete (" .. (safeCode(status) or "unknown") .. ")."
                end
                if hasToolCall(resp) then
                    return nil, "error_api", "ChatGPT attempted a tool call; X-Ray does not allow tools."
                end
                completed_resp = resp
                completed = true
            elseif t == "response.incomplete" then
                local reason = type(ev.response) == "table" and type(ev.response.incomplete_details) == "table"
                    and safeCode(ev.response.incomplete_details.reason)
                return nil, "error_incomplete", "ChatGPT response was incomplete (" .. (reason or "unknown") .. ")."
            elseif t == "response.failed" or t == "error" then
                local err = ev.error or (type(ev.response) == "table" and ev.response.error) or {}
                local code = type(err) == "table" and (safeCode(err.code) or safeCode(err.type)) or safeCode(ev.code)
                if code and (code:find("rate_limit", 1, true) or code:find("usage_limit", 1, true) or code:find("quota", 1, true)) then
                    return nil, "error_quota", "ChatGPT subscription usage limit reached [" .. code .. "]. No paid API fallback was used."
                end
                return nil, "error_api", "ChatGPT response failed" .. (code and (" [" .. code .. "]") or "") .. "."
            end
        end
    end
    if not completed then
        return nil, "error_incomplete", "ChatGPT stream ended before completion."
    end
    local text = table.concat(deltas)
    if text == "" then text = outputTextFromResponse(completed_resp) or "" end
    if text == "" then
        return nil, "error_parse", "ChatGPT response contained no text."
    end
    return text
end

-- Validate the final X-Ray JSON strictly (no truncation repair for this route).
function Responses.validateXRayJSON(text)
    if type(text) ~= "string" then return nil, "error_parse", "ChatGPT response contained no text." end
    local cleaned = stripFences(text)
    local first = cleaned:find("{", 1, true)
    if not first then return nil, "error_parse", "ChatGPT response was not a JSON object." end
    cleaned = cleaned:sub(first)
    local ok, data = pcall(json.decode, cleaned)
    if not ok or type(data) ~= "table" or next(data) == nil then
        return nil, "error_parse", "ChatGPT response was not valid X-Ray JSON."
    end
    return cleaned, data
end

-- Full normalization: SSE -> existing Chat Completions style result envelope
-- ({choices = {{finish_reason, message = {role, content}}}}) consumed by
-- checkAsyncResult. Returns normalized_json or nil, error_code, safe_message.
function Responses.normalizeStream(response_text)
    local text, code, msg = Responses.decodeStream(response_text)
    if not text then return nil, code, msg end
    local cleaned, err_code, err_msg = Responses.validateXRayJSON(text)
    if not cleaned then return nil, err_code, err_msg end
    return json.encode({
        choices = { {
            finish_reason = "stop",
            message = { role = "assistant", content = cleaned },
        } },
    }), cleaned
end

-- Safe JSON error envelope for result files (checkAsyncResult reads error.message).
function Responses.errorEnvelope(code, message)
    return json.encode({ error = { code = code, message = message } })
end

return Responses
