-- TypeSafe Jev (optional decision helper) settings UI.
-- Key entry: manual paste, or the hardened phone transfer carrier
-- (xray_code_transfer: pinned relay, fragment key, one result per session).
-- The received text is only ever saved as the TypeSafe key. Saving a key
-- never enables TypeSafe; the user toggles it separately. Keys are never
-- logged or shown.
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local M = {}

local POLL_INTERVAL = 3
local TRANSFER_LIFETIME = 600

function M:new(plugin, transfer)
    return setmetatable({ plugin = plugin, transfer = transfer, generation = 0 }, { __index = self })
end

function M:transferService()
    if not self.transfer then self.transfer = require(plugin_path .. "xray_code_transfer") end
    return self.transfer
end

function M:helper() return self.plugin.ai_helper end

function M:showMessage(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end

-- Save a received/pasted key. Never toggles opt-in.
function M:saveKey(key)
    local ok, err = self:helper():setTypeSafeKey(key)
    key = nil
    if ok then
        self:showMessage("TypeSafe key saved. Turn on TypeSafe Jev to use it.")
    else
        self:showMessage(err or "That does not look like a TypeSafe API key.")
    end
    return ok
end

-- Scrub a key input before KOReader frees its children (child-first
-- CloseWidget), and never call the setter after they are freed.
local function scrub(dialog)
    if type(dialog) ~= "table" or not dialog.xray_secret_input then return end
    if not dialog.xray_freed and dialog.setInputText then pcall(dialog.setInputText, dialog, "", nil, false) end
    dialog.input = ""
end

local function guard(dialog)
    local base = dialog.handleEvent
    dialog.handleEvent = function(widget, event, ...)
        local name = type(event) == "table" and (event.name or event.handler) or nil
        if name == "CloseWidget" or name == "onCloseWidget" or name == "FlushSettings" or name == "onFlushSettings" then
            scrub(dialog)
        end
        if base then return base(widget, event, ...) end
    end
end

-- Any close we did not initiate invalidates the current flow.
function M:track(dialog)
    local base = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget, ...)
        dialog.xray_freed = true
        scrub(dialog)
        if base then base(widget, ...) end
        if self.dialog == dialog then
            self.dialog = nil
            self:cancel()
        end
    end
    self.dialog = dialog
end

function M:cancel()
    self.generation = self.generation + 1
    local r = self.receiver
    self.receiver = nil
    if r then
        r.stopped = true
        if r.timer and UIManager.unschedule then UIManager:unschedule(r.timer) end
        r.timer = nil
        local session = r.session
        r.session = nil
        if session then
            local ok, svc = pcall(self.transferService, self)
            if ok and svc and svc.cancel then pcall(svc.cancel, svc, session) end
            if type(session) == "table" then session.url, session.secret = nil, nil end
        end
    end
    local d = self.dialog
    self.dialog = nil
    if d then scrub(d); UIManager:close(d) end
end

function M:showAccount()
    local h = self:helper()
    local has_key = h:getTypeSafeKey() ~= nil
    local enabled = h.settings and h.settings.typesafe_enabled == true
    local dialog
    local function close() UIManager:close(dialog) end
    local buttons = {
        {{ text = (enabled and "Turn off" or "Turn on") .. " TypeSafe Jev", enabled = has_key or enabled, callback = function()
            close()
            local ok, err = h:setTypeSafeEnabled(not enabled)
            if not ok then self:showMessage(err or "Could not save TypeSafe settings.") return end
            self:showAccount()
        end }},
        {{ text = "Enter key", callback = function() close(); self:showKeyInput() end }},
        {{ text = "Send key from phone", callback = function() close(); self:startPhone() end }},
    }
    if has_key then
        table.insert(buttons, {{ text = "Remove key", callback = function()
            close()
            local ok, err = h:clearTypeSafeKey()
            self:showMessage(ok and "TypeSafe key removed." or (err or "Could not save TypeSafe settings."))
        end }})
    end
    table.insert(buttons, {{ text = "Close", callback = close }})
    dialog = ButtonDialog:new{
        modal = true,
        title = "TypeSafe Jev (optional)\nKey: " .. (has_key and "saved" or "none")
            .. " | " .. (enabled and has_key and "On" or "Off")
            .. "\nSends book metadata and entity details to TypeSafe. Billed separately.",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function M:showKeyInput()
    self:cancel()
    local generation = self.generation
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = "TypeSafe API key",
        input = "",
        text_type = "password",
        allow_newline = false,
        buttons = {{
            { text = "Cancel", callback = function() self:cancel() end },
            { text = "Save", is_enter_default = true, callback = function()
                if self.generation ~= generation or self.dialog ~= dialog then return end
                local key = dialog:getInputText()
                self:cancel()
                self:saveKey(key)
                key = nil
            end },
        }},
    }
    dialog.xray_secret_input = true
    guard(dialog)
    self:track(dialog)
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

function M:startPhone()
    self:cancel()
    local generation = self.generation
    local session, _, message = self:transferService():start(os.time() + TRANSFER_LIFETIME)
    if generation ~= self.generation then
        if session then pcall(self:transferService().cancel, self:transferService(), session) end
        return
    end
    if type(session) ~= "table" or type(session.url) ~= "string" or not session.url:match("^https://") then
        if session then pcall(self:transferService().cancel, self:transferService(), session) end
        self:showMessage(type(message) == "string" and #message < 180 and message or "Phone transfer unavailable. Use Enter key.")
        return
    end
    local receiver = { session = session }
    self.receiver = receiver
    local Screen = require("device").screen
    local Font = require("ui/font")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.75)
    local children = { align = "center" }
    local ok_qr, QRWidget = pcall(require, "ui/widget/qrwidget")
    if ok_qr and QRWidget then
        local size = math.min(200, math.floor(width * 0.8))
        local ok_w, qr = pcall(function() return QRWidget:new{ text = session.url, width = size, height = size } end)
        if ok_w and qr then children[#children + 1] = qr end
    end
    children[#children + 1] = TextBoxWidget:new{
        text = "Scan, paste your TypeSafe key, tap Send.\nIgnore the provider buttons on the page.",
        face = Font:getFace("cfont", 15), width = width, alignment = "center",
    }
    local dialog = ButtonDialog:new{
        modal = true,
        _added_widgets = { VerticalGroup:new(children) },
        buttons = {{{ text = "Cancel", callback = function() self:cancel() end }}},
    }
    self:track(dialog)
    UIManager:show(dialog)
    self:schedule(generation, receiver)
end

function M:schedule(generation, receiver)
    local function stale() return receiver.stopped or self.receiver ~= receiver or self.generation ~= generation end
    local function tick()
        receiver.timer = nil
        if stale() then return end
        local key, err, msg = self:transferService():poll(receiver.session)
        if stale() then return end
        if type(key) == "string" and key ~= "" then
            self:cancel()
            self:saveKey(key)
            key = nil
        elseif err == "pending" then
            self:schedule(generation, receiver)
        else
            self:cancel()
            self:showMessage(type(msg) == "string" and #msg < 180 and msg or "Phone transfer failed.")
        end
    end
    receiver.timer = tick
    UIManager:scheduleIn(POLL_INTERVAL, tick)
end

return M
