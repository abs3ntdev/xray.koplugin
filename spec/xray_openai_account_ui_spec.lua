require("spec/spec_helper")
local AccountUI = require("xray_openai_account_ui")
local UIManager = require("ui/uimanager")

describe("ChatGPT account UI", function()
    local ui, auth, scheduled, old_schedule, old_unschedule, old_close, old_new, base_closes
    before_each(function()
        _G.ui_tracker.shown = {}
        _G.ui_tracker.last_shown = nil
        scheduled = {}
        old_schedule, old_unschedule = UIManager.scheduleIn, UIManager.unschedule
        old_close = UIManager.close
        old_new = require("ui/widget/buttondialog").new
        base_closes = 0
        require("ui/widget/buttondialog").new = function(...)
            local dialog = old_new(...)
            dialog.onCloseWidget = function() base_closes = base_closes + 1 end
            return dialog
        end
        UIManager.close = function(_, dialog)
            table.insert(_G.ui_tracker.closed, dialog)
            if dialog.onCloseWidget then dialog:onCloseWidget() end
        end
        UIManager.scheduleIn = function(_, delay, fn) table.insert(scheduled, { delay = delay, fn = fn }) end
        UIManager.unschedule = function(_, fn) for _, task in ipairs(scheduled) do if task.fn == fn then task.cancelled = true end end end
        auth = {
            connected = false, polls = 0,
            getStatus = function(self) return { connected = self.connected, account_id = self.connected and "account-1" or nil } end,
            startDeviceLogin = function() return { verification_uri = "https://auth.openai.com/codex/device", user_code = "ABCD-EFGH", interval = 7, expires_at = os.time() + 120 } end,
            pollDeviceLogin = function(self) self.polls = self.polls + 1; return "pending" end,
            logout = function(self) self.connected = false; return true end,
        }
        ui = AccountUI:new(createMockPlugin(), auth)
    end)
    after_each(function()
        UIManager.scheduleIn, UIManager.unschedule, UIManager.close = old_schedule, old_unschedule, old_close
        require("ui/widget/buttondialog").new = old_new
    end)

    it("shows connection status, separate sign-in and logout without API key", function()
        ui:showAccount()
        local dialog = _G.ui_tracker.last_shown
        assert.truthy(dialog.args.title:find("not connected"))
        dialog.buttons[1][1].callback()
        local warning = _G.ui_tracker.last_shown
        assert.truthy(warning.args.title:find("undocumented"))
        assert.truthy(warning.args.title:find("VFAT"))
        assert.truthy(warning.args.title:find("NEVER fall back"))
        warning.buttons[1][1].callback()
        local children = ui.dialog._added_widgets[1].args
        local text = children[#children].args.text
        assert.truthy(text:find("auth.openai.com/codex/device"))
        assert.truthy(text:find("ABCD%-EFGH"))
        assert.is_nil(ui.qr)
        assert.are.equal(2, base_closes)
        assert.are.equal(7, scheduled[1].delay)
        ui:cancel()
        auth.connected = true
        ui:showAccount()
        assert.truthy(ui.dialog.args.title:find("account%-1"))
        ui.dialog.buttons[2][1].callback()
        assert.is_false(auth.connected)
        assert.truthy(ui.dialog.args.title:find("not connected"))
    end)

    it("honors slowdown interval and rejects late cancelled callbacks", function()
        ui:start()
        local first = scheduled[1]
        auth.pollDeviceLogin = function(self, flow) self.polls = self.polls + 1; flow.interval = 12; return "slow_down" end
        first.fn()
        assert.are.equal(12, scheduled[2].delay)
        local second = scheduled[2]
        ui:cancel()
        second.fn()
        assert.are.equal(1, auth.polls)
        assert.is_true(second.cancelled)
    end)

    it("cancels polling on external widget close and retains base cleanup", function()
        ui:start()
        local flow, pending = ui.flow, scheduled[1]
        UIManager:close(ui.dialog)
        assert.is_true(flow.cancelled)
        assert.is_nil(ui.dialog)
        assert.is_true(pending.cancelled)
        pending.fn()
        assert.are.equal(0, auth.polls)
        assert.are.equal(1, base_closes)
    end)

    it("rejects late callback after restart, displays safe errors and expiry", function()
        ui:start()
        local stale = scheduled[1].fn
        ui:start()
        stale()
        assert.are.equal(0, auth.polls)
        auth.pollDeviceLogin = function() return "denied" end
        scheduled[2].fn()
        assert.truthy(_G.ui_tracker.last_shown.args.text:find("denied"))
        auth.startDeviceLogin = function() return nil, "failure", "Temporary network issue" end
        ui:start()
        assert.truthy(_G.ui_tracker.last_shown.args.text:find("Temporary network issue"))
        auth.startDeviceLogin = function() return { verification_uri = "https://auth.openai.com/codex/device", user_code = "ABC", expires_at = os.time() - 1 } end
        ui:start()
        assert.truthy(_G.ui_tracker.last_shown.args.text:find("expired"))
    end)
end)
