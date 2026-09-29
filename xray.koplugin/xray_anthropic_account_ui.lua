-- Claude subscription account UI (experimental, unofficial). PKCE manual code flow.
-- The pasted authorization code is passed straight to the auth module. It is never logged or stored here.
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local M = {}

local function label(loc, key, fallback)
    local value = loc and loc:t(key)
    return value and value ~= key and value or fallback
end

local function safe_message(message)
    if type(message) ~= "string" or #message > 180 or message:find("[\r\n]") then
        return "Sign-in failed. Please retry or reconnect."
    end
    return message
end

function M:new(plugin, auth, transfer)
    return setmetatable({ plugin = plugin, auth = auth, transfer = transfer, generation = 0 }, { __index = self })
end

function M:transferService()
    if not self.transfer then self.transfer = require(plugin_path .. "xray_code_transfer") end
    return self.transfer
end

local POLL_INTERVAL = 3

-- Stop the phone receiver: unschedule the timer, cancel the session, drop URL and secret references.
function M:stopReceiver()
    local receiver = self.receiver
    self.receiver = nil
    if not receiver then return end
    receiver.stopped = true
    if receiver.timer and UIManager.unschedule then UIManager:unschedule(receiver.timer) end
    receiver.timer = nil
    local session = receiver.session
    receiver.session = nil
    if session then
        local ok, svc = pcall(self.transferService, self)
        if ok and svc and svc.cancel then pcall(svc.cancel, svc, session) end
        if type(session) == "table" then session.url = nil; session.secret = nil end
    end
end

function M:service()
    if not self.auth then self.auth = require(plugin_path .. "xray_anthropic_auth") end
    return self.auth
end

-- Drop the secret from a code dialog. Before the widget is freed we use setInputText (not delAll, so
-- undo keeps nothing). Once child widgets are freed (real WidgetContainer:handleEvent sends CloseWidget
-- to children first) the setter would rebuild them, so only the raw field is cleared.
local function scrubDialog(dialog)
    if type(dialog) ~= "table" or not dialog.xray_secret_input then return end
    if not dialog.xray_freed and dialog.setInputText then
        pcall(dialog.setInputText, dialog, "", nil, false)
    end
    dialog.input = ""
end

-- Scrub before CloseWidget/FlushSettings reach the children.
local function guardEvents(dialog)
    local base = dialog.handleEvent
    dialog.handleEvent = function(widget, event, ...)
        local name = type(event) == "table" and (event.name or event.handler) or nil
        if name == "CloseWidget" or name == "onCloseWidget" or name == "FlushSettings" or name == "onFlushSettings" then
            scrubDialog(dialog)
        end
        if base then return base(widget, event, ...) end
    end
end

-- Any close of the tracked dialog that we did not initiate invalidates the flow.
function M:track(dialog)
    local base = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget, ...)
        dialog.xray_freed = true
        scrubDialog(dialog)
        if base then base(widget, ...) end
        if self.dialog == dialog then
            self.dialog = nil
            self:cancel()
        end
    end
    self.dialog = dialog
end

-- Hand over from one dialog to the next while keeping the flow alive.
function M:release(dialog)
    scrubDialog(dialog)
    if self.dialog == dialog then self.dialog = nil end
    UIManager:close(dialog)
end

function M:cancel()
    self.generation = self.generation + 1
    self:stopReceiver()
    local flow = self.flow
    self.flow = nil
    if flow then
        flow.cancelled = true
        local ok, svc = pcall(self.service, self)
        if ok and svc and svc.cancelLogin then pcall(svc.cancelLogin, svc, flow) end
    end
    if self.dialog then local dialog = self.dialog; self.dialog = nil; scrubDialog(dialog); UIManager:close(dialog) end
end

function M:showMessage(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 6 })
end

function M:showAccount()
    self:cancel()
    local loc = self.plugin.loc
    local status = self:service():getStatus() or {}
    local connected = status.connected == true
    local title = "Claude subscription (experimental): " .. (connected and "connected" or "not connected")
    local dialog
    local buttons = {
        {{ text = connected and "Reconnect" or "Sign in with Claude", callback = function()
            self:release(dialog)
            self:showWarning()
        end }},
    }
    if connected then table.insert(buttons, {{ text = "Sign out", callback = function()
        self:cancel()
        local ok, _, message = self:service():logout()
        if not ok then self:showMessage(safe_message(message)) end
        self:showAccount()
    end }}) end
    table.insert(buttons, {{ text = label(loc, "cancel", "Close"), callback = function() self:cancel() end }})
    dialog = ButtonDialog:new{ modal = true, title = title, buttons = buttons }
    self:track(dialog)
    UIManager:show(dialog)
end

function M:showWarning()
    self:cancel()
    local dialog
    dialog = ButtonDialog:new{
        modal = true,
        title = "Experimental Claude subscription sign-in\n\nThis is an unofficial integration with an interface Anthropic may restrict for third-party apps. It is not endorsed by Anthropic and may stop working or affect your account. Usage counts against your plan quota. If you configure a billed API model as the Secondary AI, failed subscription requests fall back to it and can incur API charges. Tokens are stored locally on this reader (VFAT/USB-accessible storage may expose them). The sign-in grants broad scopes (create API keys, profile, Claude Code sessions, MCP servers, file upload, inference). X-Ray only uses inference, but anyone who obtains the stored token could technically use all of them. Sign-in needs a long authorization code that you copy from the sign-in page. You can send it to this reader from your phone by QR code, or type or paste it here.",
        buttons = {
            {{ text = "Continue to sign in", callback = function()
                self:release(dialog)
                self:start()
            end }},
            {{ text = label(self.plugin.loc, "cancel", "Cancel"), callback = function() self:cancel() end }},
        },
    }
    self:track(dialog)
    UIManager:show(dialog)
end

function M:start()
    self:cancel()
    local flow, _, message = self:service():startLogin()
    if not flow then self:showMessage(safe_message(message)); return end
    local url = flow.authorization_url
    if type(url) ~= "string" or not (url:match("^https://claude%.com/") or url:match("^https://platform%.claude%.com/")) or #url > 2000 then
        flow.cancelled = true
        pcall(function() self:service():cancelLogin(flow) end)
        self:showMessage("Invalid authorization address. Sign-in stopped.")
        return
    end
    self.flow = flow
    local generation = self.generation
    local Screen = require("device").screen
    local Font = require("ui/font")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.75)
    local children = { align = "center" }
    local ok_qr, QRWidget = pcall(require, "ui/widget/qrwidget")
    if ok_qr and QRWidget then
        local size = math.min(200, math.floor(width * 0.8))
        local ok_widget, qr = pcall(function() return QRWidget:new{ text = url, width = size, height = size } end)
        if ok_widget and qr then
            local CenterContainer = require("ui/widget/container/centercontainer")
            local FrameContainer = require("ui/widget/container/framecontainer")
            local Geom = require("ui/geometry")
            local Blitbuffer = require("ffi/blitbuffer")
            children[#children + 1] = CenterContainer:new{
                dimen = Geom:new{ w = width, h = size + 14 },
                FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, padding = 6, bordersize = 1, margin = 0, qr },
            }
            children[#children + 1] = VerticalSpan:new{ width = 8 }
        end
    end
    children[#children + 1] = TextBoxWidget:new{
        text = "On your phone or computer, open:\n" .. url
            .. "\n\nSign in, approve, then copy the long code shown (it contains a # sign). Then tap Receive code from phone below (recommended) and send it from your phone, or tap Enter code to type or paste it here. Sign in on Claude's page, not on this reader.",
        face = Font:getFace("cfont", 15), width = width, alignment = "center",
    }
    local dialog
    dialog = ButtonDialog:new{
        modal = true,
        _added_widgets = { VerticalGroup:new(children) },
        buttons = {
            {{ text = "Receive code from phone", callback = function()
                if self.generation ~= generation or self.flow ~= flow or flow.cancelled then return end
                self:startReceiver(generation, flow, dialog)
            end }},
            {{ text = "Enter code", callback = function()
                if self.generation ~= generation or self.flow ~= flow or flow.cancelled then return end
                self:release(dialog)
                self:showCodeInput(generation, flow)
            end }},
            {{ text = label(self.plugin.loc, "cancel", "Cancel"), callback = function() self:cancel() end }},
        },
    }
    self:track(dialog)
    UIManager:show(dialog)
end

-- Shared completion. Callers must have stopped any receiver and checked staleness first.
function M:finish(flow, code)
    local generation = self.generation
    local ok, _, message = self:service():completeLogin(flow, code)
    if self.generation ~= generation or self.flow ~= flow or flow.cancelled then return end
    self:cancel()
    if ok then
        self:showMessage("Claude account connected. Choose the experimental Claude subscription model to use it.")
    else
        self:showMessage(safe_message(message))
    end
end

function M:startReceiver(generation, flow, qr_dialog)
    local function stale() return self.generation ~= generation or self.flow ~= flow or flow.cancelled end
    local session, _, message = self:transferService():start(flow.expires_at)
    if stale() then
        if session then pcall(self.transferService(self).cancel, self.transfer, session) end
        return
    end
    local url = type(session) == "table" and session.url
    if type(url) ~= "string" or not url:match("^https://") or #url > 2000 then
        if session then pcall(self.transferService(self).cancel, self.transfer, session) end
        self:showMessage(session and "Phone transfer unavailable. Use Enter code instead." or safe_message(message))
        return
    end
    local receiver = { session = session }
    self.receiver = receiver
    self:release(qr_dialog)
    local Screen = require("device").screen
    local Font = require("ui/font")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.75)
    local children = { align = "center" }
    local ok_qr, QRWidget = pcall(require, "ui/widget/qrwidget")
    if ok_qr and QRWidget then
        local size = math.min(200, math.floor(width * 0.8))
        local ok_widget, qr = pcall(function() return QRWidget:new{ text = url, width = size, height = size } end)
        if ok_widget and qr then
            local CenterContainer = require("ui/widget/container/centercontainer")
            local FrameContainer = require("ui/widget/container/framecontainer")
            local Geom = require("ui/geometry")
            local Blitbuffer = require("ffi/blitbuffer")
            children[#children + 1] = CenterContainer:new{
                dimen = Geom:new{ w = width, h = size + 14 },
                FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, padding = 6, bordersize = 1, margin = 0, qr },
            }
            children[#children + 1] = VerticalSpan:new{ width = 8 }
        end
    end
    children[#children + 1] = TextBoxWidget:new{
        text = "Scan this QR code with your phone. It opens a transfer page.\n\n"
            .. "On that page, paste the Claude authorization code into the field labelled \"API key\", then tap Send on the page. Pasting alone does not send it. "
            .. "This is only a transfer box. Do NOT enter a real API key. Any provider choice on the page is ignored.\n\n"
            .. "This reader will continue automatically once the code arrives.",
        face = Font:getFace("cfont", 15), width = width, alignment = "center",
    }
    local dialog
    dialog = ButtonDialog:new{
        modal = true,
        _added_widgets = { VerticalGroup:new(children) },
        buttons = {
            {{ text = "Enter code manually", callback = function()
                if stale() then return end
                self:stopReceiver()
                self:release(dialog)
                self:showCodeInput(generation, flow)
            end }},
            {{ text = label(self.plugin.loc, "cancel", "Cancel"), callback = function() self:cancel() end }},
        },
    }
    self:track(dialog)
    UIManager:show(dialog)
    self:scheduleReceive(generation, flow, receiver, dialog)
end

function M:scheduleReceive(generation, flow, receiver, dialog)
    local function stale()
        return receiver.stopped or self.receiver ~= receiver or self.generation ~= generation
            or self.flow ~= flow or flow.cancelled
    end
    local function tick()
        receiver.timer = nil
        if stale() then return end
        if (tonumber(flow.expires_at) or 0) <= os.time() then
            self:cancel(); self:showMessage("Sign-in code expired. Try again."); return
        end
        local code, err, msg = self:transferService():poll(receiver.session)
        if stale() then code = nil; return end
        if type(code) == "string" and code ~= "" then
            self:stopReceiver()
            self:release(dialog)
            self:finish(flow, code)
            code = nil
        elseif err == "pending" then
            self:scheduleReceive(generation, flow, receiver, dialog)
        else
            self:cancel()
            self:showMessage(safe_message(msg))
        end
    end
    receiver.timer = tick
    UIManager:scheduleIn(POLL_INTERVAL, tick)
end

function M:showCodeInput(generation, flow)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    local function scrub() scrubDialog(dialog) end
    local function stale() return self.generation ~= generation or self.flow ~= flow or flow.cancelled end
    dialog = InputDialog:new{
        title = "Authorization code (code#state)",
        input = "",
        input_hint = "code#state",
        text_type = "password",
        input_type = "text",
        allow_newline = false,
        buttons = {{
            { text = label(self.plugin.loc, "cancel", "Cancel"), callback = function() scrub(); self:cancel() end },
            { text = "Connect", is_enter_default = true, callback = function()
                if stale() then return end
                local code = dialog:getInputText()
                scrub()
                self:release(dialog)
                if type(code) ~= "string" or code:gsub("%s", "") == "" then
                    self:cancel()
                    self:showMessage("No code entered. Sign-in stopped.")
                    return
                end
                self:finish(flow, code)
                code = nil
            end },
        }},
    }
    dialog.xray_secret_input = true
    guardEvents(dialog)
    self:track(dialog)
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

return M
