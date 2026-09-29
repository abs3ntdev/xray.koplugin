local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
if plugin_path ~= "" then
    local path_to_dir = plugin_path:gsub("%.", "/")
    if not package.path:find(path_to_dir) then
        package.path = package.path .. ";" .. path_to_dir .. "?.lua"
    end
end

local socket = require("socket")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local logger = nil
pcall(function() logger = require(plugin_path .. "xray_logger") end)
if not logger then pcall(function() logger = require("logger") end) end

local function logInfo(msg)
    if logger and logger.info then logger.info(msg)
    elseif logger and logger.log then logger:log("[INFO] " .. tostring(msg)) end
end

local function logWarn(msg)
    if logger and logger.warn then logger.warn(msg)
    elseif logger and logger.log then logger:log("[WARN] " .. tostring(msg)) end
end

local function logErr(msg)
    if logger and logger.err then logger.err(msg)
    elseif logger and logger.log then logger:log("[ERR] " .. tostring(msg)) end
end

local Utils = require(plugin_path .. "xray_utils")
local Crypto = require(plugin_path .. "xray_crypto")

local ok_json, json = pcall(require, "json")
if not ok_json or not json then
    pcall(function() json = require(plugin_path .. "xray_json") end)
end

local DEFAULT_WORKER_URL = "https://xray-setup.ultimatejimmy.workers.dev"

local WebSetup = {
    server = nil,
    port = nil,
    dialog = nil,
    is_running = false,
    ai_helper = nil,
    loc = nil,
    ui_callback = nil,
    cloud_poll_timer = nil,
    session_id = nil,
    session_secret = nil,
    poll_start_time = nil,
    poll_count = 0,
}

-- Check if device supports inbound local HTTP server (Kindle OS iptables blocks inbound connections)
function WebSetup:isLocalServerSupported()
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and Device.isKindle and Device:isKindle() then
        return false
    end
    return true
end

-- Simple HTTPS/HTTP Request Helper
local function httpRequest(url, method, headers, request_body, timeout)
    timeout = timeout or 10
    local is_https = url:match("^https://") ~= nil
    local ok_http, http_req = pcall(require, "socket.http")
    local ok_https, https_req = false, nil
    if is_https then
        ok_https, https_req = pcall(require, "ssl.https")
    end
    local ok_ltn12, ltn12_req = pcall(require, "ltn12")
    local ok_util, socketutil = pcall(require, "socketutil")

    if not ok_http or not http_req then
        return nil, "error_require", "socket.http module unavailable"
    end
    if is_https and (not ok_https or not https_req) then
        return nil, "error_require", "ssl.https module unavailable"
    end

    if https_req then https_req.cert_verify = false end
    if ok_util and socketutil and socketutil.set_timeout then
        pcall(function() socketutil:set_timeout(timeout, timeout * 2) end)
    end

    local req_headers = headers or {}
    if not req_headers["User-Agent"] and not req_headers["user-agent"] then
        req_headers["User-Agent"] = "Mozilla/5.0 (compatible; KOReader-XRay/1.0)"
    end

    local response_body = {}
    local sink = nil
    if ok_util and socketutil and socketutil.table_sink then
        sink = socketutil.table_sink(response_body)
    elseif ok_ltn12 and ltn12_req and ltn12_req.sink and ltn12_req.sink.table then
        sink = ltn12_req.sink.table(response_body)
    else
        sink = function(chunk)
            if chunk then table.insert(response_body, chunk) end
            return 1
        end
    end

    local req_table = {
        url = url,
        method = method or "GET",
        headers = req_headers,
        sink = sink,
    }

    if request_body and #request_body > 0 then
        if ok_ltn12 and ltn12_req and ltn12_req.source and ltn12_req.source.string then
            req_table.source = ltn12_req.source.string(request_body)
        end
        if not req_table.headers["content-length"] then
            req_table.headers["content-length"] = tostring(#request_body)
        end
    end

    local ok, code, resp_headers, status
    local pcall_ok, pcall_err = pcall(function()
        if is_https then
            ok, code, resp_headers, status = https_req.request(req_table)
        else
            ok, code, resp_headers, status = http_req.request(req_table)
        end
    end)

    if ok_util and socketutil and socketutil.reset_timeout then
        pcall(function() socketutil:reset_timeout() end)
    end

    if not pcall_ok then
        return nil, "error_crash", tostring(pcall_err)
    end

    local resp_text = table.concat(response_body)
    return ok, tonumber(code) or code, resp_text, resp_headers
end

function WebSetup:getProviderDisplayName(provider)
    local prov_name = provider
    if provider == "gemini" then prov_name = "Google Gemini"
    elseif provider == "chatgpt" then prov_name = "OpenAI ChatGPT"
    elseif provider == "deepseek" then prov_name = "DeepSeek"
    elseif provider == "claude" then prov_name = "Anthropic Claude"
    elseif provider and provider:find("custom") then prov_name = "Custom API"
    end
    return prov_name
end

function WebSetup:applyReceivedKey(data)
    if type(data) ~= "table" or not data.provider or not data.api_key then
        logErr("WebSetup: applyReceivedKey received invalid data structure: " .. tostring(data))
        return false, "Invalid payload"
    end

    local provider = data.provider
    local api_key = data.api_key:match("^%s*(.-)%s*$")
    logInfo("WebSetup: Applying received API key for provider: " .. tostring(provider))
    
    if self.ai_helper then
        if provider == "custom1" or provider == "custom2" then
            self.ai_helper:setCustomAPIConfig(provider, api_key, data.endpoint or "", data.model or "")
            self.ai_helper:updateConfigKey(provider .. "_api_key", api_key)
            if data.endpoint and #data.endpoint > 0 then self.ai_helper:updateConfigKey(provider .. "_endpoint", data.endpoint) end
            if data.model and #data.model > 0 then self.ai_helper:updateConfigKey(provider .. "_model", data.model) end
        else
            self.ai_helper:setAPIKey(provider, api_key)
            self.ai_helper:updateConfigKey(provider .. "_api_key", api_key)
        end

        local prov_name = self:getProviderDisplayName(provider)
        UIManager:show(InfoMessage:new{
            text = (self.loc and self.loc:t("web_setup_success", prov_name)) or ("[OK] API key for " .. prov_name .. " received and saved!"),
            timeout = 4
        })

        if self.ui_callback then
            pcall(self.ui_callback, provider)
        end
        return true
    end
    return false, "No AIHelper"
end

-- =========================================================================
-- 1. Cloud Relay Setup (Recommended)
-- =========================================================================

function WebSetup:startCloudRelay(ai_helper, loc, ui_callback)
    local ok_run, result = pcall(function()
        self.ai_helper = ai_helper
        self.loc = loc
        self.ui_callback = ui_callback

        -- Check Network
        local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
        if ok_net and NetworkMgr and NetworkMgr.isOnline then
            local ok, online = pcall(function() return NetworkMgr:isOnline() end)
            if ok and online == false then
                UIManager:show(InfoMessage:new{
                    text = (loc and loc:t("web_setup_no_wifi")) or "Wi-Fi is disconnected. Please connect to Wi-Fi first.",
                    timeout = 5
                })
                return false
            end
        end

        self:stop()

        local worker_url = DEFAULT_WORKER_URL
        if self.ai_helper and self.ai_helper.settings and self.ai_helper.settings.cloud_setup_worker_url then
            worker_url = self.ai_helper.settings.cloud_setup_worker_url
        end
        worker_url = worker_url:gsub("/+$", "")

        -- 1. Generate client secret (pure Lua)
        local secret_hex = Crypto:generateSecretHex()
        self.session_secret = secret_hex

        -- 2. Request new session from Cloudflare Worker
        local create_url = worker_url .. "/api/session/create"
        local ok, code, resp_text = httpRequest(create_url, "POST", { ["Content-Type"] = "application/json" }, "{}", 6)

        if not ok or code ~= 200 or not resp_text then
            logErr("WebSetup: Failed to create session on worker (" .. tostring(code) .. "), response " .. tostring(type(resp_text) == "string" and #resp_text or 0) .. " bytes")
            local msg = "Could not reach Cloud Relay (" .. tostring(code or "Network error") .. "). Check your Wi-Fi connection."
            if self:isLocalServerSupported() then
                msg = "Could not reach Cloud Relay (" .. tostring(code or "Network error") .. "). Check your Wi-Fi or try Local Wi-Fi mode."
            end
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 5
            })
            return false
        end

        local sess_data
        pcall(function() sess_data = json.decode(resp_text) end)
        if not sess_data or not sess_data.session_id then
            logErr("WebSetup: Invalid response payload from worker (" .. tostring(type(resp_text) == "string" and #resp_text or 0) .. " bytes)")
            UIManager:show(InfoMessage:new{ text = "Invalid response from Cloud Relay.", timeout = 4 })
            return false
        end

        local session_id = sess_data.session_id
        self.session_id = session_id
        self.is_running = true
        self.poll_start_time = os.time()
        self.poll_count = 0
        logInfo("WebSetup: Started Cloud Relay session " .. session_id .. " on worker " .. worker_url)

        local full_url = string.format("%s/?s=%s#%s", worker_url, session_id, secret_hex)
        local short_domain = worker_url:gsub("^https?://", "")

        -- 3. Render Modal Dialog using KOReader ButtonDialog
        local Device = require("device")
        local Screen = Device.screen
        local Size = require("ui/size")
        local Font = require("ui/font")
        local Geom = require("ui/geometry")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local VerticalSpan = require("ui/widget/verticalspan")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local Blitbuffer = require("ffi/blitbuffer")

        local dialog_width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
        local border_window = 1
        local padding_button = 10
        local padding_default = 10
        local margin_default = 5
        pcall(function()
            if Size and Size.border and Size.border.window then border_window = Size.border.window end
            if Size and Size.padding and Size.padding.button then padding_button = Size.padding.button end
            if Size and Size.padding and Size.padding.default then padding_default = Size.padding.default end
            if Size and Size.margin and Size.margin.default then margin_default = Size.margin.default end
        end)
        local buttontable_width = dialog_width - 2 * border_window - 2 * padding_button
        local content_width = buttontable_width - 2 * (padding_default + margin_default)

        local qr_size = math.max(120, math.min(math.floor(content_width * 0.42), 160))
        local base_fs = 16
        if G_reader_settings then
            local fs = G_reader_settings:readSetting("cre_font_size")
            if fs and type(fs) == "number" then
                base_fs = math.max(14, math.min(fs, 22))
            end
        end

        local vg_components = { align = "center" }

        -- Title
        table.insert(vg_components, TextBoxWidget:new{
            text = (loc and loc:t("cloud_setup_title")) or "Connect via Phone/PC",
            face = Font:getFace("cfont", base_fs + 4),
            bold = true,
            width = content_width,
            alignment = "center",
        })
        table.insert(vg_components, VerticalSpan:new{ width = 8 })

        -- QR Code
        local ok_qr, QRWidget = pcall(require, "ui/widget/qrwidget")
        if ok_qr and QRWidget then
            local ok_inst, qr_widget = pcall(function()
                return QRWidget:new{
                    text = full_url,
                    width = qr_size,
                    height = qr_size,
                }
            end)
            if ok_inst and qr_widget then
                local qr_frame = FrameContainer:new{
                    background = Blitbuffer.COLOR_WHITE,
                    padding = 6,
                    bordersize = 1,
                    margin = 0,
                    qr_widget,
                }
                local centered_qr = CenterContainer:new{
                    dimen = Geom:new{ w = content_width, h = qr_size + 14 },
                    qr_frame,
                }
                table.insert(vg_components, centered_qr)
                table.insert(vg_components, VerticalSpan:new{ width = 8 })
            end
        end

        -- URL and Pairing Code
        table.insert(vg_components, TextBoxWidget:new{
            text = short_domain .. "  •  Code: " .. session_id,
            face = Font:getFace("cfont", base_fs + 1),
            bold = true,
            width = content_width,
            alignment = "center",
        })
        table.insert(vg_components, VerticalSpan:new{ width = 10 })

        -- Instructions
        local step_instructions = "1. Scan the QR code or visit the link on your phone/PC.\n2. Paste your API key on the web page and tap Save."
        table.insert(vg_components, TextBoxWidget:new{
            text = step_instructions,
            face = Font:getFace("cfont", base_fs),
            width = content_width,
            alignment = "left",
        })

        local vg = VerticalGroup:new(vg_components)

        local action_buttons = {}
        if self:isLocalServerSupported() then
            table.insert(action_buttons, {
                text = (loc and loc:t("menu_setup_local")) or "Local Wi-Fi (Offline LAN)",
                callback = function()
                    self:stop()
                    self:startLocalServer(ai_helper, loc, ui_callback)
                end,
            })
        end
        table.insert(action_buttons, {
            text = (loc and loc:t("cancel")) or "Cancel",
            is_enter_default = true,
            callback = function()
                self:stop()
            end,
        })

        self.dialog = ButtonDialog:new{
            _added_widgets = { vg },
            buttons = {
                action_buttons
            }
        }

        UIManager:show(self.dialog)

        -- 4. Start Polling Loop
        self:pollCloudRelay(worker_url, session_id, secret_hex)
        return true
    end)

    if not ok_run then
        logErr("WebSetup: Exception in startCloudRelay: " .. tostring(result))
        UIManager:show(InfoMessage:new{
            text = "Error launching Web Setup: " .. tostring(result),
            timeout = 6
        })
        return false
    end
    return result
end

function WebSetup:pollCloudRelay(worker_url, session_id, secret_hex)
    if not self.is_running or self.session_id ~= session_id then return end

    -- Check session timeout (10 minutes max)
    if os.time() - (self.poll_start_time or os.time()) > 600 then
        self:stop()
        logInfo("WebSetup: Session timed out.")
        UIManager:show(InfoMessage:new{ text = "Pairing session timed out. Please try again.", timeout = 4 })
        return
    end

    local poll_url = string.format("%s/api/session/%s/poll", worker_url, session_id)
    self.poll_count = (self.poll_count or 0) + 1
    local current_poll = self.poll_count
    
    -- Schedule next poll asynchronously to avoid blocking UI
    local function doPoll()
        if not self.is_running or self.session_id ~= session_id then return end

        local ok, code, resp_text = httpRequest(poll_url, "GET", {}, nil, 4)
        if not self.is_running or self.session_id ~= session_id then return end

        if current_poll == 1 or current_poll % 5 == 0 then
            logInfo(string.format("WebSetup: Polling session %s (attempt #%d) -> HTTP %s", session_id, current_poll, tostring(code)))
        end

        if ok and code == 200 and resp_text then
            logInfo("WebSetup: Poll received 200 response: " .. tostring(#resp_text) .. " bytes")
            local data
            pcall(function() data = json.decode(resp_text) end)
            if data and data.status == "ready" and data.payload then
                logInfo("WebSetup: Found ready payload, attempting decryption...")
                local decrypted_json, err = Crypto:decryptPayload(data.payload, secret_hex, session_id)
                if decrypted_json then
                    logInfo("WebSetup: Decrypted JSON successfully: " .. tostring(#decrypted_json) .. " chars")
                    local payload_obj
                    pcall(function() payload_obj = json.decode(decrypted_json) end)
                    if payload_obj and payload_obj.api_key then
                        self:stop()
                        self:applyReceivedKey(payload_obj)
                        return
                    else
                        logErr("WebSetup: Decrypted payload invalid or missing api_key")
                    end
                else
                    logErr("WebSetup: Decryption failed: " .. tostring(err))
                end
            end
        elseif not ok or (code ~= 204 and code ~= 200) then
            logWarn("WebSetup: Poll non-success status: " .. tostring(code) .. ", response " .. tostring(type(resp_text) == "string" and #resp_text or 0) .. " bytes")
        end

        -- Schedule next poll
        if self.is_running and self.session_id == session_id then
            UIManager:scheduleIn(1.5, function()
                self:pollCloudRelay(worker_url, session_id, secret_hex)
            end)
        end
    end

    doPoll()
end

-- =========================================================================
-- 2. Local Wi-Fi Offline Server Mode
-- =========================================================================

local HTML_LOCAL_TEMPLATE = [[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>KOReader X-Ray — Local Setup</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
  body { background: #090d16; color: #f1f5f9; display: flex; justify-content: center; align-items: center; min-height: 100vh; padding: 16px; }
  .card { background: #131d2e; border-radius: 20px; box-shadow: 0 20px 40px -10px rgba(0,0,0,0.6); max-width: 500px; width: 100%; padding: 24px; border: 1px solid #223249; }
  .header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; }
  .header h1 { font-size: 1.35rem; font-weight: 800; color: #38bdf8; letter-spacing: -0.5px; }
  .header .badge-device { font-size: 0.72rem; font-weight: 700; color: #38bdf8; background: rgba(56, 189, 248, 0.12); border: 1px solid rgba(56, 189, 248, 0.3); padding: 4px 10px; border-radius: 9999px; }
  .security-box { background: rgba(16, 185, 129, 0.08); border: 1px solid rgba(16, 185, 129, 0.3); border-radius: 12px; padding: 12px 14px; margin-bottom: 20px; }
  .security-header { display: flex; align-items: center; gap: 8px; font-size: 0.85rem; font-weight: 700; color: #34d399; margin-bottom: 4px; }
  .security-text { font-size: 0.76rem; line-height: 1.45; color: #cbd5e1; }
  .section-label { display: block; font-size: 0.82rem; font-weight: 700; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 8px; }
  .provider-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 18px; }
  .provider-btn { background: #0b121e; color: #94a3b8; border: 1px solid #223249; padding: 10px 12px; border-radius: 10px; font-size: 0.82rem; font-weight: 700; cursor: pointer; text-align: left; display: flex; align-items: center; justify-content: space-between; transition: all 0.15s ease; }
  .provider-btn:hover { border-color: #38bdf8; color: #f1f5f9; }
  .provider-btn.active { background: rgba(56, 189, 248, 0.15); color: #38bdf8; border-color: #38bdf8; box-shadow: 0 0 0 1px #38bdf8; }
  .provider-btn.full-width { grid-column: span 2; }
  .tag-free { background: #10b981; color: #064e3b; font-size: 0.65rem; font-weight: 900; padding: 2px 6px; border-radius: 6px; }
  .form-group { margin-bottom: 16px; }
  label { display: flex; justify-content: space-between; align-items: center; font-size: 0.82rem; font-weight: 700; color: #e2e8f0; margin-bottom: 6px; }
  .input-wrap { position: relative; display: flex; gap: 8px; }
  input[type="text"], input[type="password"] { width: 100%; background: #0b121e; border: 1.5px solid #223249; color: #f8fafc; border-radius: 10px; padding: 12px 14px; font-size: 0.95rem; font-family: ui-monospace, monospace; }
  input:focus { outline: none; border-color: #38bdf8; background: #070c14; }
  .btn-paste { background: #1e293b; color: #e2e8f0; border: 1px solid #334155; border-radius: 10px; padding: 0 14px; font-size: 0.85rem; font-weight: 700; cursor: pointer; white-space: nowrap; display: flex; align-items: center; gap: 4px; }
  .btn-paste:hover { background: #334155; border-color: #475569; }
  .helper-link { font-size: 0.78rem; color: #38bdf8; text-decoration: none; display: inline-block; margin-top: 6px; font-weight: 600; }
  .helper-link:hover { text-decoration: underline; }
  .btn-submit { width: 100%; background: #38bdf8; color: #090d16; border: none; border-radius: 12px; padding: 14px; font-size: 1rem; font-weight: 800; cursor: pointer; margin-top: 6px; display: flex; align-items: center; justify-content: center; gap: 6px; }
  .btn-submit:hover { background: #7dd3fc; }
  .btn-submit:disabled { background: #1e293b; color: #64748b; cursor: not-allowed; }
  #msgBox { margin-top: 14px; padding: 12px 14px; border-radius: 10px; font-size: 0.85rem; display: none; line-height: 1.45; font-weight: 600; }
  #msgBox.success { background: rgba(16, 185, 129, 0.15); color: #6ee7b7; border: 1px solid #10b981; }
  #msgBox.error { background: rgba(239, 68, 68, 0.15); color: #fca5a5; border: 1px solid #ef4444; }
</style>
</head>
<body>
<div class="card">
  <div class="header">
    <h1>KOReader X-Ray</h1>
    <span class="badge-device">Local LAN</span>
  </div>
  <div class="security-box">
    <div class="security-header">
      <span>100% Local & Offline</span>
    </div>
    <div class="security-text">
      This page is served directly by your e-reader over your home Wi-Fi network. No cloud servers are involved.
    </div>
  </div>

  <span class="section-label">Select AI Provider</span>
  <div class="provider-grid">
    <button type="button" class="provider-btn active" onclick="switchProvider('gemini')">
      <span>Google Gemini</span>
      <span class="tag-free">FREE</span>
    </button>
    <button type="button" class="provider-btn" onclick="switchProvider('chatgpt')">
      <span>OpenAI</span>
    </button>
    <button type="button" class="provider-btn" onclick="switchProvider('deepseek')">
      <span>DeepSeek</span>
    </button>
    <button type="button" class="provider-btn" onclick="switchProvider('claude')">
      <span>Claude</span>
    </button>
    <button type="button" class="provider-btn full-width" onclick="switchProvider('custom1')">
      <span>Custom / OpenRouter</span>
    </button>
  </div>

  <div id="guideContent"></div>

  <form id="keyForm" onsubmit="event.preventDefault(); submitKey();">
    <div id="tabContent"></div>
    <button type="submit" id="submitBtn" class="btn-submit">
      Save to E-Reader
    </button>
  </form>

  <div id="msgBox"></div>
</div>

<script>
let currentProvider = 'gemini';

const providerDetails = {
  gemini: {
    guideTitle: 'Get a Free Google Gemini API Key',
    steps: [
      'Open Google AI Studio in a new tab.',
      'Sign in with your Google account.',
      'Click "Create API Key" and copy the key.'
    ],
    linkText: 'Open Google AI Studio ↗',
    linkUrl: 'https://aistudio.google.com/app/apikey',
    fields: [{ id: 'key', label: 'Gemini API Key', placeholder: 'AQ.Ab8RN6... or AIzaSy...', type: 'password' }]
  },
  chatgpt: {
    guideTitle: 'Get an OpenAI API Key',
    steps: [
      'Open OpenAI Platform.',
      'Go to API Keys section.',
      'Click "Create new secret key".'
    ],
    linkText: 'Open OpenAI Dashboard ↗',
    linkUrl: 'https://platform.openai.com/api-keys',
    fields: [{ id: 'key', label: 'OpenAI API Key', placeholder: 'sk-proj-...', type: 'password' }]
  },
  deepseek: {
    guideTitle: 'Get a DeepSeek API Key',
    steps: [
      'Open the DeepSeek Platform.',
      'Create an account or log in.',
      'Navigate to API Keys and create a new key.'
    ],
    linkText: 'Open DeepSeek Console ↗',
    linkUrl: 'https://platform.deepseek.com/api_keys',
    fields: [{ id: 'key', label: 'DeepSeek API Key', placeholder: 'sk-...', type: 'password' }]
  },
  claude: {
    guideTitle: 'Get an Anthropic Claude API Key',
    steps: [
      'Open Anthropic Console.',
      'Sign in and navigate to Settings → API Keys.',
      'Create and copy your key.'
    ],
    linkText: 'Open Anthropic Console ↗',
    linkUrl: 'https://console.anthropic.com/settings/keys',
    fields: [{ id: 'key', label: 'Claude API Key', placeholder: 'sk-ant-...', type: 'password' }]
  },
  custom1: {
    guideTitle: 'Custom API / OpenRouter',
    steps: [
      'Use any OpenAI-compatible API endpoint.',
      'For OpenRouter, obtain a key at openrouter.ai.',
      'Enter the full endpoint URL and model name below.'
    ],
    linkText: 'Get OpenRouter Key ↗',
    linkUrl: 'https://openrouter.ai/keys',
    fields: [
      { id: 'key', label: 'API Key', placeholder: 'sk-or-... or custom key', type: 'text' },
      { id: 'endpoint', label: 'Endpoint URL', placeholder: 'https://openrouter.ai/api/v1/chat/completions', type: 'text', def: 'https://openrouter.ai/api/v1/chat/completions' },
      { id: 'model', label: 'Default Model', placeholder: 'google/gemini-2.5-flash', type: 'text', def: 'google/gemini-2.5-flash' }
    ]
  }
};

function switchProvider(p) {
  currentProvider = p;
  document.querySelectorAll('.provider-btn').forEach(b => b.classList.remove('active'));
  const btn = Array.from(document.querySelectorAll('.provider-btn')).find(b => b.getAttribute('onclick').includes("'" + p + "'"));
  if (btn) btn.classList.add('active');
  const details = providerDetails[p];

  let guideHtml = '<div style="background:#0b121e; border:1px solid #1e293b; border-radius:12px; padding:12px 14px; margin-bottom:16px;">';
  guideHtml += '<div style="font-size:0.82rem; font-weight:700; color:#38bdf8; margin-bottom:6px;">' + details.guideTitle + '</div>';
  guideHtml += '<ol style="font-size:0.78rem; color:#cbd5e1; line-height:1.5; margin-bottom:8px; padding-left:16px;">';
  details.steps.forEach(function(s) { guideHtml += '<li>' + s + '</li>'; });
  guideHtml += '</ol>';
  guideHtml += '<a href="' + details.linkUrl + '" target="_blank" rel="noopener noreferrer" class="helper-link" style="background:#1e293b; color:#38bdf8; border:1px solid rgba(56,189,248,0.3); padding:6px 12px; border-radius:8px; text-decoration:none; display:inline-block; font-size:0.78rem; font-weight:700;">' + details.linkText + '</a>';
  guideHtml += '</div>';
  document.getElementById('guideContent').innerHTML = guideHtml;

  let h = '';
  details.fields.forEach(function(f) {
    h += '<div class="form-group"><label>' + f.label + '</label><div class="input-wrap">';
    h += '<input type="' + f.type + '" id="' + f.id + '" placeholder="' + f.placeholder + '" value="' + (f.def || '') + '">';
    if (f.id === 'key') h += '<button type="button" class="btn-paste" onclick="pasteClip(\'' + f.id + '\')">Paste</button>';
    h += '</div></div>';
  });
  document.getElementById('tabContent').innerHTML = h;
}

async function pasteClip(id) {
  try {
    const t = await navigator.clipboard.readText();
    const el = document.getElementById(id);
    if (el) el.value = t.trim();
  } catch(e) { alert('Please paste manually'); }
}

async function submitKey() {
  const k = (document.getElementById('key') || {}).value || '';
  if (!k.trim()) { showMsg('Please enter an API key', 'error'); return; }
  const payload = { provider: currentProvider, api_key: k.trim() };
  if (currentProvider === 'custom1') {
    payload.endpoint = (document.getElementById('endpoint') || {}).value || '';
    payload.model = (document.getElementById('model') || {}).value || '';
  }
  const btn = document.getElementById('submitBtn');
  btn.disabled = true;
  btn.textContent = 'Saving...';
  try {
    const r = await fetch('/api/save', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    const d = await r.json();
    if (r.ok && d.success) {
      showMsg('Saved to e-reader successfully!', 'success');
      btn.textContent = 'Saved!';
    } else {
      showMsg(d.error || 'Failed to save', 'error');
      btn.disabled = false;
      btn.textContent = 'Save to E-Reader';
    }
  } catch(e) {
    showMsg('Error: ' + e.message, 'error');
    btn.disabled = false;
    btn.textContent = 'Save to E-Reader';
  }
}

function showMsg(t, c) {
  const b = document.getElementById('msgBox');
  b.textContent = t;
  b.className = c;
  b.style.display = 'block';
}

switchProvider('gemini');
</script>
</body>
</html>]]

function WebSetup:handleLocalRequest(client)
    local line = client:receive("*l")
    if not line then client:close(); return end

    local method, path = line:match("^(%u+)%s+(%S+)")
    if not method or not path then client:close(); return end

    local headers = {}
    local content_length = 0
    while true do
        local h = client:receive("*l")
        if not h or h == "" then break end
        local k, v = h:match("^(.-):%s*(.*)$")
        if k and v then
            headers[k:lower()] = v
            if k:lower() == "content-length" then
                content_length = tonumber(v) or 0
            end
        end
    end

    if method == "GET" and (path == "/" or path:match("^/index")) then
        local body = HTML_LOCAL_TEMPLATE
        local resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " .. tostring(#body) .. "\r\nConnection: close\r\n\r\n" .. body
        client:send(resp)
        client:close()
        return
    end

    if method == "POST" and path == "/api/save" then
        local body = ""
        if content_length > 0 then
            body = client:receive(content_length) or ""
        end
        local ok, data = pcall(json.decode, body)
        if not ok or type(data) ~= "table" or not data.provider or not data.api_key then
            local resp_body = json.encode({ success = false, error = "Invalid data payload" })
            local resp = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: " .. tostring(#resp_body) .. "\r\nConnection: close\r\n\r\n" .. resp_body
            client:send(resp)
            client:close()
            return
        end

        local resp_body = json.encode({ success = true, provider = data.provider })
        local resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. tostring(#resp_body) .. "\r\nConnection: close\r\n\r\n" .. resp_body
        client:send(resp)
        client:close()

        self:stop()
        self:applyReceivedKey(data)
        return
    end

    local resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    client:send(resp)
    client:close()
end

function WebSetup:pollLocalServer()
    if not self.is_running or not self.server then return end
    local client = self.server:accept()
    if client then
        pcall(function() self:handleLocalRequest(client) end)
    end
    if self.is_running and self.server then
        UIManager:scheduleIn(0.2, function() self:pollLocalServer() end)
    end
end

function WebSetup:startLocalServer(ai_helper, loc, ui_callback)
    local ok_run, result = pcall(function()
        if not self:isLocalServerSupported() then
            UIManager:show(InfoMessage:new{
                text = (loc and loc:t("web_setup_local_unsupported")) or "Local Wi-Fi server is not supported on Kindle devices due to OS firewall restrictions. Please use Cloud Relay.",
                timeout = 5
            })
            return false
        end

        self.ai_helper = ai_helper
        self.loc = loc
        self.ui_callback = ui_callback

        -- Check Network
        local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
        if ok_net and NetworkMgr and NetworkMgr.isOnline then
            local ok, online = pcall(function() return NetworkMgr:isOnline() end)
            if ok and online == false then
                UIManager:show(InfoMessage:new{
                    text = (loc and loc:t("web_setup_no_wifi")) or "Wi-Fi is disconnected. Please connect to Wi-Fi first.",
                    timeout = 5
                })
                return false
            end
        end

        self:stop()

        local ip = Utils:getLocalIP()
        local port_start = 8088
        local bound_server = nil
        local active_port = nil

        for p = port_start, port_start + 7 do
            local s = socket.bind("*", p)
            if s then
                bound_server = s
                active_port = p
                break
            end
        end

        if not bound_server then
            UIManager:show(InfoMessage:new{
                text = "Could not start local server on port 8088–8095.",
                timeout = 5
            })
            return false
        end

        bound_server:settimeout(0)
        self.server = bound_server
        self.port = active_port
        self.is_running = true

        local url = string.format("http://%s:%d", ip, active_port)
        logInfo("XRayPlugin WebSetup: Local server running at " .. url)

        local Device = require("device")
        local Screen = Device.screen
        local Size = require("ui/size")
        local Font = require("ui/font")
        local Geom = require("ui/geometry")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local VerticalSpan = require("ui/widget/verticalspan")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local Blitbuffer = require("ffi/blitbuffer")

        local dialog_width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
        local border_window = 1
        local padding_button = 10
        local padding_default = 10
        local margin_default = 5
        pcall(function()
            if Size and Size.border and Size.border.window then border_window = Size.border.window end
            if Size and Size.padding and Size.padding.button then padding_button = Size.padding.button end
            if Size and Size.padding and Size.padding.default then padding_default = Size.padding.default end
            if Size and Size.margin and Size.margin.default then margin_default = Size.margin.default end
        end)
        local buttontable_width = dialog_width - 2 * border_window - 2 * padding_button
        local content_width = buttontable_width - 2 * (padding_default + margin_default)

        local qr_size = math.max(120, math.min(math.floor(content_width * 0.42), 160))
        local base_fs = 16
        if G_reader_settings then
            local fs = G_reader_settings:readSetting("cre_font_size")
            if fs and type(fs) == "number" then
                base_fs = math.max(14, math.min(fs, 22))
            end
        end

        local vg_components = { align = "center" }

        -- Title
        table.insert(vg_components, TextBoxWidget:new{
            text = (loc and loc:t("local_setup_title")) or "Connect via Local Wi-Fi",
            face = Font:getFace("cfont", base_fs + 4),
            bold = true,
            width = content_width,
            alignment = "center",
        })
        table.insert(vg_components, VerticalSpan:new{ width = 8 })

        -- QR Code Widget
        local ok_qr, QRWidget = pcall(require, "ui/widget/qrwidget")
        if ok_qr and QRWidget then
            local ok_inst, qr_widget = pcall(function()
                return QRWidget:new{
                    text = url,
                    width = qr_size,
                    height = qr_size,
                }
            end)
            if ok_inst and qr_widget then
                local qr_frame = FrameContainer:new{
                    background = Blitbuffer.COLOR_WHITE,
                    padding = 6,
                    bordersize = 1,
                    margin = 0,
                    qr_widget,
                }
                local centered_qr = CenterContainer:new{
                    dimen = Geom:new{ w = content_width, h = qr_size + 14 },
                    qr_frame,
                }
                table.insert(vg_components, centered_qr)
                table.insert(vg_components, VerticalSpan:new{ width = 8 })
            end
        end

        -- URL
        table.insert(vg_components, TextBoxWidget:new{
            text = url,
            face = Font:getFace("cfont", base_fs + 2),
            bold = true,
            width = content_width,
            alignment = "center",
        })
        table.insert(vg_components, VerticalSpan:new{ width = 10 })

        -- Instructions
        local step_instructions = "1. Connect phone/PC to the same Wi-Fi.\n2. Scan the QR code above or open the URL in your browser.\n3. Paste your API key on the web page and tap Save."

        table.insert(vg_components, TextBoxWidget:new{
            text = step_instructions,
            face = Font:getFace("cfont", base_fs),
            width = content_width,
            alignment = "left",
        })

        local vg = VerticalGroup:new(vg_components)

        self.dialog = ButtonDialog:new{
            _added_widgets = { vg },
            buttons = {
                {
                    {
                        text = (loc and loc:t("menu_setup_cloud")) or "Cloud Relay (Recommended)",
                        callback = function()
                            self:stop()
                            self:startCloudRelay(ai_helper, loc, ui_callback)
                        end,
                    },
                    {
                        text = (loc and loc:t("cancel")) or "Cancel",
                        is_enter_default = true,
                        callback = function()
                            self:stop()
                        end,
                    }
                }
            }
        }

        UIManager:show(self.dialog)
        self:pollLocalServer()
        return true
    end)

    if not ok_run then
        logErr("WebSetup: Exception in startLocalServer: " .. tostring(result))
        UIManager:show(InfoMessage:new{
            text = "Error launching Local Web Setup: " .. tostring(result),
            timeout = 6
        })
        return false
    end
    return result
end

-- Backward compatibility alias
function WebSetup:start(ai_helper, loc, ui_callback)
    return self:startCloudRelay(ai_helper, loc, ui_callback)
end

function WebSetup:stop()
    self.is_running = false
    self.session_id = nil
    self.session_secret = nil
    if self.server then
        pcall(function() self.server:close() end)
        self.server = nil
    end
    if self.dialog then
        local dlg = self.dialog
        self.dialog = nil
        pcall(function() UIManager:close(dlg) end)
    end
end

return WebSetup
