-- Device authorization UI. No credentials are read here or passed to the setup relay.
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local M = {}

local function trackClose(owner, dialog)
    local base = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget, ...)
        if base then base(widget, ...) end
        if owner.dialog == dialog then
            owner.dialog = nil
            owner:cancel()
        end
    end
end

local function label(loc, key, fallback)
    local value = loc and loc:t(key)
    return value and value ~= key and value or fallback
end

local function safe_message(message)
    -- Auth supplies safe messages, but never display arbitrary HTTP response bodies.
    if type(message) ~= "string" or #message > 180 or message:find("[\r\n]") then
        return "Sign-in failed. Please retry or reconnect."
    end
    return message
end

function M:new(plugin, auth)
    return setmetatable({ plugin = plugin, auth = auth, generation = 0 }, { __index = self })
end

function M:service()
    if not self.auth then self.auth = require(plugin_path .. "xray_openai_auth") end
    return self.auth
end

function M:cancel()
    self.generation = self.generation + 1
    if self.flow then self.flow.cancelled = true end
    self.flow = nil
    if self.timer then
        if UIManager.unschedule then UIManager:unschedule(self.timer) end
        self.timer = nil
    end
    if self.dialog then local dialog = self.dialog; self.dialog = nil; UIManager:close(dialog) end
end

function M:showMessage(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 6 })
end

function M:showAccount()
    self:cancel()
    local loc = self.plugin.loc
    local status = self:service():getStatus() or {}
    local connected = status.connected == true
    local title = connected and "ChatGPT subscription: connected" or "ChatGPT subscription: not connected"
    if connected and status.account_id then title = title .. "\nAccount: " .. tostring(status.account_id) end
    local dialog
    local buttons = {
        {{ text = connected and "Reconnect" or "Sign in with ChatGPT", callback = function()
            self.dialog = nil
            UIManager:close(dialog)
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
    dialog = ButtonDialog:new{
        modal = true, title = title,
        buttons = buttons,
    }
    trackClose(self, dialog)
    self.dialog = dialog
    UIManager:show(dialog)
end

function M:showWarning()
    self:cancel()
    local dialog
    dialog = ButtonDialog:new{
        modal = true,
        title = "Experimental ChatGPT subscription sign-in\n\nThis uses an undocumented service integration, not a guaranteed official third-party API. Subscription usage has plan quotas. Tokens are stored locally on this reader; on VFAT/USB-accessible storage physical access may expose them. Subscription requests NEVER fall back to paid API calls automatically. Continue only if you accept these limitations.",
        buttons = {
            {{ text = "Continue to sign in", callback = function()
                self.dialog = nil
                UIManager:close(dialog)
                self:start()
            end }},
            {{ text = label(self.plugin.loc, "cancel", "Cancel"), callback = function() self:cancel() end }},
        },
    }
    trackClose(self, dialog)
    self.dialog = dialog
    UIManager:show(dialog)
end

function M:start()
    self:cancel()
    local flow, _, message = self:service():startDeviceLogin()
    if not flow then self:showMessage(safe_message(message)); return end
    if type(flow.verification_uri) ~= "string" or not flow.verification_uri:match("^https://auth%.openai%.com/")
        or type(flow.user_code) ~= "string" or #flow.user_code > 40 then
        flow.cancelled = true
        self:showMessage("Invalid verification address. Sign-in stopped.")
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
    -- Only the official URL goes into the QR, not the code or any credential.
    local ok_qr, QRWidget = pcall(require, "ui/widget/qrwidget")
    if ok_qr and QRWidget then
        local size = math.min(160, math.floor(width * 0.65))
        local ok_widget, qr = pcall(function()
            return QRWidget:new{ text = flow.verification_uri, width = size, height = size }
        end)
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
        text = "On your phone, open:\n" .. flow.verification_uri .. "\n\nEnter code: " .. flow.user_code
            .. "\n\nSign in on OpenAI's page, not on this reader. Keep this dialog open while waiting.",
        face = Font:getFace("cfont", 17), width = width, alignment = "center",
    }
    local dialog
    dialog = ButtonDialog:new{
        modal = true,
        _added_widgets = { VerticalGroup:new(children) },
        buttons = {{{ text = label(self.plugin.loc, "cancel", "Cancel"), callback = function() self:cancel() end }}},
    }
    trackClose(self, dialog)
    self.dialog = dialog
    UIManager:show(dialog)
    self:schedulePoll(generation)
end

function M:schedulePoll(generation)
    local flow = self.flow
    if not flow or self.generation ~= generation or flow.cancelled then return end
    local remaining = (tonumber(flow.expires_at) or 0) - os.time()
    if remaining <= 0 then self:cancel(); self:showMessage("Sign-in code expired. Try again."); return end
    local interval = math.max(1, tonumber(flow.interval) or 5)
    local delay = math.min(interval, remaining)
    local function poll()
        self.timer = nil
        if self.generation ~= generation or self.flow ~= flow or flow.cancelled then return end
        if (tonumber(flow.expires_at) or 0) <= os.time() then
            self:cancel(); self:showMessage("Sign-in code expired. Try again."); return
        end
        local status, message = self:service():pollDeviceLogin(flow)
        if self.generation ~= generation or self.flow ~= flow or flow.cancelled then return end
        if status == "pending" or status == "slow_down" then
            self:schedulePoll(generation)
        elseif status == "complete" then
            self:cancel()
            self:showMessage("ChatGPT account connected. Choose the experimental subscription model to use it.")
        else
            self:cancel()
            self:showMessage(status == "expired" and "Sign-in code expired. Try again."
                or status == "denied" and "Sign-in was denied. Try again if you wish."
                or safe_message(message))
        end
    end
    self.timer = poll
    UIManager:scheduleIn(delay, poll)
end

return M
