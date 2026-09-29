require("spec/spec_helper")
local AccountUI = require("xray_anthropic_account_ui")
local UIManager = require("ui/uimanager")

describe("Claude account UI", function()
    local ui, auth, old_close, old_bnew, old_inew, base_closes, input_text
    before_each(function()
        _G.ui_tracker.shown = {}
        _G.ui_tracker.last_shown = nil
        base_closes = 0
        input_text = "code123#state456"
        old_close = UIManager.close
        old_bnew = require("ui/widget/buttondialog").new
        old_inew = require("ui/widget/inputdialog").new
        require("ui/widget/buttondialog").new = function(...)
            local d = old_bnew(...)
            d.onCloseWidget = function() base_closes = base_closes + 1 end
            return d
        end
        require("ui/widget/inputdialog").new = function(...)
            local d = old_inew(...)
            d.getInputText = function() return input_text end
            -- Emulate WidgetContainer:handleEvent: children are freed first, then the parent handler runs.
            d.handleEvent = function(self, event)
                if event.name == "CloseWidget" then
                    self.children_freed = true
                    if self.onCloseWidget then self:onCloseWidget() end
                end
            end
            d.setInputText = function(self, text)
                assert.is_falsy(self.children_freed, "setInputText after children were freed")
                self.setter_calls = (self.setter_calls or 0) + 1
                self.input = text
            end
            return d
        end
        UIManager.close = function(_, dialog)
            table.insert(_G.ui_tracker.closed, dialog)
            if dialog.handleEvent then dialog:handleEvent({ name = "CloseWidget" })
            elseif dialog.onCloseWidget then dialog:onCloseWidget() end
        end
        auth = {
            connected = false, completed = {}, cancelled = 0, result = { true },
            getStatus = function(self) return { connected = self.connected } end,
            startLogin = function() return { authorization_url = "https://claude.com/cai/oauth/authorize?x=1", expires_at = os.time() + 600 } end,
            completeLogin = function(self, flow, code) table.insert(self.completed, { flow = flow, code = code }); return (unpack or table.unpack)(self.result, 1, 3) end,
            cancelLogin = function(self) self.cancelled = self.cancelled + 1 end,
            logout = function(self) self.connected = false; return true end,
        }
        ui = AccountUI:new(createMockPlugin(), auth)
    end)
    after_each(function()
        UIManager.close = old_close
        require("ui/widget/buttondialog").new = old_bnew
        require("ui/widget/inputdialog").new = old_inew
    end)

    local function toCode()
        ui:showAccount()
        ui.dialog.buttons[1][1].callback()
        local warning = _G.ui_tracker.last_shown
        warning.buttons[1][1].callback()
        ui.dialog.buttons[2][1].callback()
        return ui.dialog
    end

    it("warns, shows URL, keeps flow across QR to code input, completes privately", function()
        ui:showAccount()
        assert.truthy(ui.dialog.args.title:find("not connected"))
        ui.dialog.buttons[1][1].callback()
        local t = _G.ui_tracker.last_shown.args.title
        for _, s in ipairs({ "unofficial", "NEVER", "VFAT", "quota", "not endorsed", "only uses inference", "MCP" }) do assert.truthy(t:find(s)) end
        _G.ui_tracker.last_shown.buttons[1][1].callback()
        local children = ui.dialog._added_widgets[1].args
        assert.truthy(children[#children].args.text:find("claude.com/cai/oauth/authorize", 1, true))
        local flow = ui.flow
        ui.dialog.buttons[2][1].callback()
        assert.are.equal(flow, ui.flow)
        assert.is_false(flow.cancelled == true)
        local input = ui.dialog
        assert.are.equal("InputDialog", input.type)
        assert.are.equal("password", input.args.text_type)
        input.args.buttons[1][2].callback()
        assert.are.equal(1, #auth.completed)
        assert.are.equal("code123#state456", auth.completed[1].code)
        assert.is_nil(ui.flow)
        assert.is_nil(ui.dialog)
        assert.truthy(_G.ui_tracker.last_shown.args.text:find("connected"))
        assert.is_nil(ui.code)
    end)

    it("external close of QR or input dialog cancels flow and blocks stale callbacks", function()
        local qr_btn
        ui:showAccount(); ui.dialog.buttons[1][1].callback(); _G.ui_tracker.last_shown.buttons[1][1].callback()
        local flow, qr = ui.flow, ui.dialog
        qr_btn = qr.args.buttons[1][1].callback
        UIManager:close(qr)
        assert.is_true(flow.cancelled)
        assert.is_nil(ui.flow)
        qr_btn()
        assert.are.equal("ButtonDialog", (_G.ui_tracker.last_shown or {}).type)
        assert.are.equal(0, #auth.completed)

        local input = toCode()
        local submit = input.args.buttons[1][2].callback
        local flow2 = ui.flow
        UIManager:close(input)
        assert.is_true(flow2.cancelled)
        submit()
        assert.are.equal(0, #auth.completed)
        assert.is_true(auth.cancelled >= 2)
    end)

    it("cancel button, restart, stale submit and errors are safe", function()
        local input = toCode()
        local stale = input.args.buttons[1][2].callback
        input.args.buttons[1][1].callback()
        assert.is_nil(ui.flow)
        stale()
        assert.are.equal(0, #auth.completed)
        input = toCode()
        local old = input.args.buttons[1][2].callback
        ui:start()
        old()
        assert.are.equal(0, #auth.completed)
        ui:cancel()
        input = toCode()
        auth.result = { nil, "bad", "Wrong code" }
        input.args.buttons[1][2].callback()
        assert.truthy(_G.ui_tracker.last_shown.args.text:find("Wrong code"))
        input = toCode()
        auth.result = { nil, "bad", "secret\nbody" }
        input.args.buttons[1][2].callback()
        assert.is_nil(_G.ui_tracker.last_shown.args.text:find("secret"))
        input = toCode()
        input_text = "   "
        input.args.buttons[1][2].callback()
        assert.truthy(_G.ui_tracker.last_shown.args.text:find("No code"))
    end)

    it("scrubs input before child-first CloseWidget on every path, never via setter after free", function()
        local function fresh()
            local d = toCode()
            d.input = "secret#raw"
            return d
        end
        local d = fresh(); UIManager:close(d)
        assert.are.equal("", d.input); assert.are.equal(1, d.setter_calls); assert.is_true(d.children_freed)
        d = fresh(); ui:cancel()
        assert.are.equal("", d.input); assert.is_true(d.setter_calls >= 1)
        d = fresh(); ui:start()
        assert.are.equal("", d.input); assert.is_true(d.setter_calls >= 1)
        ui:cancel()
        d = fresh(); d.args.buttons[1][2].callback()
        assert.are.equal("", d.input); assert.is_true(d.setter_calls >= 1)
        assert.are.equal("code123#state456", auth.completed[#auth.completed].code)
        -- Late parent-only close after children were freed must not call the setter.
        d = fresh(); d.children_freed = true; d.xray_freed = nil
        local calls = d.setter_calls or 0
        d.xray_freed = true; d.input = "late#secret"
        d:onCloseWidget()
        assert.are.equal("", d.input); assert.are.equal(calls, d.setter_calls or 0)
        -- FlushSettings also scrubs before propagation.
        d = fresh(); d.input = "x#y"; d:handleEvent({ name = "FlushSettings" })
        assert.are.equal("", d.input)
    end)

    it("rejects bad URL, shows start error, and signs out", function()
        auth.startLogin = function() return { authorization_url = "https://evil.example/x" } end
        ui:start()
        assert.truthy(_G.ui_tracker.last_shown.args.text:find("Invalid"))
        assert.is_nil(ui.flow)
        auth.startLogin = function() return nil, "e", "Entropy unavailable" end
        ui:start()
        assert.truthy(_G.ui_tracker.last_shown.args.text:find("Entropy"))
        auth.connected = true
        ui:showAccount()
        assert.truthy(ui.dialog.args.title:find(": connected"))
        ui.dialog.buttons[2][1].callback()
        assert.is_false(auth.connected)
        assert.truthy(ui.dialog.args.title:find("not connected"))
    end)

    describe("phone receiver", function()
        local transfer, sched, old_sched, old_unsched, unscheduled
        local function run_next()
            local f = table.remove(sched, 1)
            if f then f() end
        end
        before_each(function()
            sched, unscheduled = {}, 0
            old_sched, old_unsched = UIManager.scheduleIn, UIManager.unschedule
            UIManager.scheduleIn = function(_, _, f) table.insert(sched, f) end
            UIManager.unschedule = function(_, f)
                unscheduled = unscheduled + 1
                for i, g in ipairs(sched) do if g == f then table.remove(sched, i) break end end
            end
            transfer = {
                started = {}, cancelled = {}, polls = 0, results = {},
                start = function(self, exp)
                    table.insert(self.started, exp)
                    return { url = "https://relay.example/?s=ID#" .. string.rep("a", 64), secret = "s" }
                end,
                poll = function(self, session)
                    self.polls = self.polls + 1
                    local r = table.remove(self.results, 1) or { nil, "pending" }
                    if type(r) == "function" then return r() end
                    return (unpack or table.unpack)(r, 1, 3)
                end,
                cancel = function(self, session) table.insert(self.cancelled, session) end,
            }
            ui = AccountUI:new(createMockPlugin(), auth, transfer)
        end)
        after_each(function() UIManager.scheduleIn, UIManager.unschedule = old_sched, old_unsched end)

        local function toReceiver()
            ui:showAccount(); ui.dialog.buttons[1][1].callback()
            _G.ui_tracker.last_shown.buttons[1][1].callback()
            local qr = ui.dialog
            assert.are.equal("Receive code from phone", qr.args.buttons[1][1].text)
            assert.are.equal("Enter code", qr.args.buttons[2][1].text)
            qr.args.buttons[1][1].callback()
            return ui.dialog
        end

        it("shows second QR with unmistakable directions and polls without blocking", function()
            local flow_exp
            local d = toReceiver()
            assert.are.equal(ui.flow.expires_at, transfer.started[1])
            local kids = d.args._added_widgets[1].args
            local text = kids[#kids].args.text
            assert.truthy(text:find("API key", 1, true)); assert.truthy(text:find("Do NOT enter a real API key", 1, true))
            assert.truthy(text:find("ignored", 1, true)); assert.truthy(text:find("tap Send", 1, true))
            assert.is_nil(text:find("https://relay", 1, true))
            assert.are.equal(1, #sched)
            assert.are.equal(0, transfer.polls)
            run_next(); assert.are.equal(1, transfer.polls); assert.are.equal(1, #sched)
            assert.are.equal(0, #auth.completed)
        end)

        it("stops and cancels before completeLogin and hands code to auth", function()
            local d = toReceiver()
            local session = ui.receiver.session
            transfer.results = {{ "code123#state456" }}
            auth.completeLogin = function(self, flow, code)
                assert.are.equal(1, #transfer.cancelled)
                assert.is_nil(ui.receiver)
                assert.are.equal(0, #sched)
                table.insert(self.completed, { flow = flow, code = code }); return true
            end
            run_next()
            assert.are.equal(1, #auth.completed)
            assert.are.equal("code123#state456", auth.completed[1].code)
            assert.are.equal(session, transfer.cancelled[1])
            assert.is_nil(session.url); assert.is_nil(session.secret)
            assert.is_nil(ui.flow)
            assert.truthy(_G.ui_tracker.last_shown.args.text:find("connected"))
            assert.are.equal(1, transfer.polls)
        end)

        it("auth rejection of a wrong code is a safe message with no retry loop", function()
            toReceiver()
            transfer.results = {{ "sk-ant-actual-key" }}
            auth.result = { nil, "bad", "Wrong code" }
            run_next()
            assert.truthy(_G.ui_tracker.last_shown.args.text:find("Wrong code"))
            assert.are.equal(0, #sched); assert.are.equal(1, transfer.polls)
        end)

        it("cancel, close, new flow and expiry unschedule and cancel the session", function()
            local d = toReceiver()
            ui:cancel()
            assert.are.equal(1, #transfer.cancelled); assert.are.equal(0, #sched); assert.is_nil(ui.receiver)
            d = toReceiver(); UIManager:close(d)
            assert.are.equal(2, #transfer.cancelled); assert.are.equal(0, #sched)
            toReceiver(); ui:start()
            assert.are.equal(3, #transfer.cancelled); assert.are.equal(0, #sched)
            ui:cancel()
            toReceiver(); ui.flow.expires_at = os.time() - 1
            run_next()
            assert.are.equal(0, transfer.polls)
            assert.are.equal(4, #transfer.cancelled)
            assert.truthy(_G.ui_tracker.last_shown.args.text:find("expired"))
            assert.is_nil(ui.flow)
        end)

        it("late results after cancel, newflow or during poll are dropped", function()
            toReceiver()
            local tick = sched[1]
            ui:cancel()
            tick()
            assert.are.equal(0, transfer.polls)
            toReceiver()
            transfer.results = {function() ui:start(); return "code#late" end}
            run_next()
            assert.are.equal(0, #auth.completed)
            ui:cancel()
        end)

        it("terminal transfer errors stop and show safe message; manual entry keeps flow", function()
            toReceiver()
            transfer.results = {{ nil, "expired", "Transfer expired" }}
            run_next()
            assert.truthy(_G.ui_tracker.last_shown.args.text:find("Transfer expired"))
            assert.are.equal(1, #transfer.cancelled); assert.are.equal(0, #sched)
            local d = toReceiver()
            local flow = ui.flow
            d.args.buttons[1][1].callback()
            assert.are.equal(flow, ui.flow); assert.is_nil(ui.receiver)
            assert.are.equal("InputDialog", ui.dialog.type)
            assert.are.equal(0, #sched)
        end)

        it("start failure keeps QR flow for manual entry; bad url is cancelled", function()
            transfer.start = function() return nil, "e", "Entropy unavailable" end
            ui:showAccount(); ui.dialog.buttons[1][1].callback()
            _G.ui_tracker.last_shown.buttons[1][1].callback()
            local flow, qr = ui.flow, ui.dialog
            qr.args.buttons[1][1].callback()
            assert.truthy(_G.ui_tracker.last_shown.args.text:find("Entropy"))
            assert.are.equal(flow, ui.flow); assert.is_nil(ui.receiver)
            local bad = { url = "http://x" }
            transfer.start = function() return bad end
            qr.args.buttons[1][1].callback()
            assert.are.equal(bad, transfer.cancelled[1]); assert.is_nil(ui.receiver)
        end)
    end)
end)
