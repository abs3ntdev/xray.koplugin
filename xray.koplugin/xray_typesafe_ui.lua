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

function M:cancel()
    self.generation = self.generation + 1
    local r = self.receiver
    self.receiver = nil
    if r then
        r.stopped = true
        if r.timer and UIManager.unschedule then UIManager:unschedule(r.timer) end
        if r.session then pcall(self:transferService().cancel, self:transferService(), r.session) end
        r.session = nil
        if r.dialog then UIManager:close(r.dialog) end
    end
end

function M:showAccount()
    local h = self:helper()
    local has_key = h:getTypeSafeKey() ~= nil
    local enabled = h.settings and h.settings.typesafe_enabled == true
    local dialog
    local function close() UIManager:close(dialog) end
    local buttons = {
        {{ text = (enabled and "Turn off" or "Turn on") .. " TypeSafe Jev", enabled = has_key or enabled, callback = function()
            close(); h:setTypeSafeEnabled(not enabled); self:showAccount()
        end }},
        {{ text = "Enter key", callback = function() close(); self:showKeyInput() end }},
        {{ text = "Send key from phone", callback = function() close(); self:startPhone() end }},
    }
    if has_key then
        table.insert(buttons, {{ text = "Remove key", callback = function()
            close(); h:clearTypeSafeKey(); self:showMessage("TypeSafe key removed.")
        end }})
    end
    table.insert(buttons, {{ text = "Close", callback = close }})
    dialog = ButtonDialog:new{
        modal = true,
        title = "TypeSafe Jev (optional)\nKey: " .. (has_key and "saved" or "none")
            .. " | " .. (enabled and has_key and "On" or "Off")
            .. "\nSends book metadata and entity names to TypeSafe. Billed separately.",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function M:showKeyInput()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    local function scrub()
        if dialog and dialog.setInputText then pcall(dialog.setInputText, dialog, "", nil, false) end
        if dialog then dialog.input = "" end
    end
    dialog = InputDialog:new{
        title = "TypeSafe API key",
        input = "",
        text_type = "password",
        allow_newline = false,
        buttons = {{
            { text = "Cancel", callback = function() scrub(); UIManager:close(dialog) end },
            { text = "Save", is_enter_default = true, callback = function()
                local key = dialog:getInputText()
                scrub(); UIManager:close(dialog)
                self:saveKey(key)
                key = nil
            end },
        }},
    }
    dialog.xray_secret_input = true
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
    receiver.dialog = ButtonDialog:new{
        modal = true,
        _added_widgets = { VerticalGroup:new(children) },
        buttons = {{{ text = "Cancel", callback = function() self:cancel() end }}},
    }
    UIManager:show(receiver.dialog)
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
