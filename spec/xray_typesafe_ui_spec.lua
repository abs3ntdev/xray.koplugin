-- xray_typesafe_ui_spec.lua
-- UI-owner lifecycle for the optional TypeSafe helper.
-- Real entrypoints: TypeSafeUI:showAccount/showKeyInput/startPhone/cancel with
-- the real AIHelper key/opt-in API, and xray_ui walkDuplicatePairs /
-- closeAllMenus. Mocked: KOReader widgets (spec_helper), the phone transfer
-- carrier, the scheduler, and, for the duplicate review, the AIHelper async
-- boundary (its child pipeline is covered in xray_typesafe_spec.lua).
require("spec/spec_helper")
local UIManager = require("ui/uimanager")

local KEY = "ts_test_key_SECRET123"

describe("TypeSafe settings UI", function()
    local TypeSafeUI, AIHelper, ui, plugin, transfer, sched, saved, old
    local input_text

    local function run_next() local f = table.remove(sched, 1); if f then f() end end

    before_each(function()
        TypeSafeUI = require("xray_typesafe_ui")
        AIHelper = require("xray_aihelper")
        saved = { settings = AIHelper.settings, saveSettings = AIHelper.saveSettings }
        AIHelper.settings = {}
        AIHelper.saveSettings = function(self, u) for k, v in pairs(u or {}) do self.settings[k] = v end return true end
        _G.ui_tracker.shown, _G.ui_tracker.closed, _G.ui_tracker.last_shown = {}, {}, nil
        sched = {}
        input_text = KEY
        old = {
            sched = UIManager.scheduleIn, unsched = UIManager.unschedule, close = UIManager.close,
            inew = require("ui/widget/inputdialog").new,
        }
        UIManager.scheduleIn = function(_, _, f) table.insert(sched, f) end
        UIManager.unschedule = function(_, f)
            for i, g in ipairs(sched) do if g == f then table.remove(sched, i) break end end
        end
        UIManager.close = function(_, d)
            table.insert(_G.ui_tracker.closed, d)
            if type(d) ~= "table" then return end
            if d.handleEvent then d:handleEvent({ name = "CloseWidget" })
            elseif d.onCloseWidget then d:onCloseWidget() end
        end
        require("ui/widget/inputdialog").new = function(...)
            local d = old.inew(...)
            d.getInputText = function() return input_text end
            -- KOReader WidgetContainer: children freed first, then the parent handler.
            d.handleEvent = function(self, event)
                if event.name == "CloseWidget" then
                    self.children_freed = true
                    if self.onCloseWidget then self:onCloseWidget() end
                end
            end
            d.setInputText = function(self, text)
                assert.is_falsy(self.children_freed, "setInputText after children were freed")
                self.input = text
            end
            return d
        end
        transfer = {
            started = 0, cancelled = {}, polls = 0, results = {},
            start = function(self, expires_at, settings) self.started = self.started + 1
                self.settings = settings
                return { url = "https://xray-setup.ultimatejimmy.workers.dev/?s=ABCDEF#" .. string.rep("a", 64), secret = "s" } end,
            poll = function(self)
                self.polls = self.polls + 1
                local r = table.remove(self.results, 1) or { nil, "pending" }
                if type(r) == "function" then return r() end
                return (unpack or table.unpack)(r, 1, 3)
            end,
            cancel = function(self, s) table.insert(self.cancelled, s) end,
        }
        plugin = createMockPlugin()
        plugin.ai_helper = AIHelper
        ui = TypeSafeUI:new(plugin, transfer)
    end)

    after_each(function()
        UIManager.scheduleIn, UIManager.unschedule, UIManager.close = old.sched, old.unsched, old.close
        require("ui/widget/inputdialog").new = old.inew
        AIHelper.settings, AIHelper.saveSettings = saved.settings, saved.saveSettings
    end)

    local function button(dialog, label)
        for _, row in ipairs(dialog.args.buttons) do
            for _, b in ipairs(row) do if b.text:find(label, 1, true) then return b end end
        end
    end

    it("manual key save never enables; enabling needs a valid key; remove disables", function()
        ui:showAccount()
        local account = _G.ui_tracker.last_shown
        assert.truthy(account.args.title:find("Billed separately", 1, true))
        -- Turning on without a key is refused.
        button(account, "Turn on").callback()
        assert.is_nil(AIHelper.settings.typesafe_enabled)
        ui:showKeyInput()
        local input = ui.dialog
        assert.are.equal("password", input.args.text_type)
        input.args.buttons[1][2].callback()
        assert.are.equal(KEY, AIHelper.settings.typesafe_api_key)
        assert.is_nil(AIHelper.settings.typesafe_enabled)
        assert.is_false(AIHelper:isTypeSafeEnabled())
        assert.are.equal("", input.input)
        assert.is_nil(_G.ui_tracker.last_shown.args.text:find(KEY, 1, true))
        -- The TypeSafe key is not a generative provider key.
        local old_keys = {}
        for _, id in ipairs({ "gemini", "chatgpt", "deepseek", "claude", "custom1", "custom2" }) do
            old_keys[id] = AIHelper.providers[id].api_key; AIHelper.providers[id].api_key = nil
        end
        local oa, an = AIHelper._openai_auth, AIHelper._anthropic_auth
        AIHelper._openai_auth = { getStatus = function() return { connected = false } end }
        AIHelper._anthropic_auth = AIHelper._openai_auth
        assert.is_false(AIHelper:hasApiKey())
        AIHelper._openai_auth, AIHelper._anthropic_auth = oa, an
        for id, v in pairs(old_keys) do AIHelper.providers[id].api_key = v end
        ui:showAccount()
        button(_G.ui_tracker.last_shown, "Turn on").callback()
        assert.is_true(AIHelper:isTypeSafeEnabled())
        ui:showAccount()
        button(_G.ui_tracker.last_shown, "Remove key").callback()
        assert.is_false(AIHelper:isTypeSafeEnabled())
        assert.are.equal("", AIHelper.settings.typesafe_api_key)
    end)

    it("invalid pasted key is rejected with a safe message", function()
        input_text = "not a key\n"
        ui:showKeyInput()
        ui.dialog.args.buttons[1][2].callback()
        assert.is_nil(AIHelper.settings.typesafe_api_key)
        assert.truthy(_G.ui_tracker.last_shown.args.text:find("does not look like", 1, true))
    end)

    it("external child-first close scrubs input and blocks the stale Save", function()
        ui:showKeyInput()
        local d = ui.dialog
        d.input = "typed secret"
        local save = d.args.buttons[1][2].callback
        UIManager:close(d)
        assert.are.equal("", d.input)
        assert.is_nil(ui.dialog)
        save()
        assert.is_nil(AIHelper.settings.typesafe_api_key)
        d = (function() ui:showKeyInput(); return ui.dialog end)()
        d.input = "x"; d:handleEvent({ name = "FlushSettings" })
        assert.are.equal("", d.input)
    end)

    it("phone transfer saves only the TypeSafe key, ignoring carrier provider, and never enables", function()
        AIHelper.settings.cloud_setup_worker_url = "https://owned.example.com"
        package.loaded["xray_websetup"] = setmetatable({}, { __index = function() error("generic WebSetup must not be used") end })
        ui:startPhone()
        assert.are.equal(AIHelper.settings, transfer.settings)
        assert.are.equal("https://owned.example.com", transfer.settings.cloud_setup_worker_url)
        local session = ui.receiver.session
        local qr = ui.dialog
        local kids = qr.args._added_widgets[1].args
        assert.truthy(kids[#kids].args.text:find("Ignore the provider", 1, true))
        transfer.results = { { KEY } }
        run_next()
        package.loaded["xray_websetup"] = nil
        assert.are.equal(KEY, AIHelper.settings.typesafe_api_key)
        assert.is_nil(AIHelper.settings.typesafe_enabled)
        assert.is_nil(AIHelper.settings.gemini_api_key)
        assert.are.equal(session, transfer.cancelled[1])
        assert.is_nil(session.secret); assert.is_nil(session.url)
        assert.are.equal(0, #sched)
    end)

    it("cancel, external close and restart drop stale polls and late results", function()
        ui:startPhone()
        local tick = sched[1]
        ui:cancel()
        tick()
        assert.are.equal(0, transfer.polls)
        assert.are.equal(0, #sched)
        ui:startPhone()
        UIManager:close(ui.dialog)
        assert.are.equal(2, #transfer.cancelled); assert.are.equal(0, #sched)
        ui:startPhone()
        transfer.results = { function() ui:startPhone(); return KEY end }
        run_next()
        assert.is_nil(AIHelper.settings.typesafe_api_key)
        ui:cancel()
        ui:startPhone()
        transfer.results = { { nil, "expired", "The phone transfer expired. Start again." } }
        run_next()
        assert.truthy(_G.ui_tracker.last_shown.args.text:find("expired", 1, true))
        assert.are.equal(0, #sched)
    end)
end)

describe("TypeSafe duplicate review in xray_ui", function()
    local xray_ui = require("xray_ui")
    local plugin, helper, sched, old

    local function run_next() local f = table.remove(sched, 1); if f then f() end end

    before_each(function()
        _G.ui_tracker.shown, _G.ui_tracker.closed, _G.ui_tracker.last_shown = {}, {}, nil
        sched = {}
        old = { sched = UIManager.scheduleIn, unsched = UIManager.unschedule }
        UIManager.scheduleIn = function(_, _, f) table.insert(sched, f) end
        UIManager.unschedule = function(_, f)
            for i, g in ipairs(sched) do if g == f then table.remove(sched, i) break end end
        end
        plugin = createMockPlugin()
        for k, v in pairs(xray_ui) do plugin[k] = v end
        plugin.book_data = {}
        plugin.characters = {}
        for i = 1, 40 do plugin.characters[i] = { name = "C" .. i, description = "d" } end
        helper = plugin.ai_helper
        helper.started, helper.cancelled, helper.result = {}, {}, nil
        helper.isTypeSafeEnabled = function() return true end
        helper.annotateDuplicatePairsAsync = function(self, book, items, file)
            table.insert(self.started, { book = book, items = items, file = file }); return 77, math.min(#items, 36)
        end
        helper.checkAsyncResult = function(self) return (unpack or table.unpack)(self.result or {}, 1, 3) end
        helper.cancelAsyncChild = function(self, pid) table.insert(self.cancelled, pid); return true end
    end)
    after_each(function() UIManager.scheduleIn, UIManager.unschedule = old.sched, old.unsched end)

    local function candidates(n)
        local out = {}
        for i = 1, n do out[i] = { primary = "C" .. (2 * i - 1), secondary = "C" .. (2 * i), reason = "r" .. i } end
        return out
    end

    it("shows visible verdicts, keeps every candidate and labels uncapped pairs not assessed", function()
        local pairs_found = candidates(20)
        plugin:walkDuplicatePairs(plugin.characters, "characters", pairs_found)
        assert.are.equal(1, #helper.started)
        assert.are.equal(20, #helper.started[1].items)
        assert.are.equal("C1", helper.started[1].items[1][1].name)
        helper.result = { { typesafe_annotations = {
            ["1"] = { verdict = "same", confidence = 0.9 },
            ["2"] = { verdict = "different", confidence = 0.8 },
            ["3"] = { verdict = "bogus" },
        } } }
        run_next()
        assert.are.equal(20, #pairs_found)
        local dialog = _G.ui_tracker.last_shown
        assert.truthy(dialog.args.title:find("TypeSafe Jev: likely same (confidence 90%)", 1, true))
        assert.truthy(dialog.args.title:find("You decide", 1, true))
        -- Skip through: every pair is still offered, with honest labels.
        local seen = {}
        for i = 1, 20 do
            local d = _G.ui_tracker.last_shown
            seen[i] = d.args.title
            d.args.buttons[1][2].callback()
        end
        assert.truthy(seen[2]:find("likely different", 1, true))
        assert.truthy(seen[3]:find("not assessed", 1, true))
        assert.truthy(seen[20]:find("not assessed", 1, true))
        assert.are.equal(1, #helper.started)
    end)

    it("timeout cancels its own child and continues the review unannotated", function()
        local pairs_found = candidates(1)
        plugin:walkDuplicatePairs(plugin.characters, "characters", pairs_found)
        for _ = 1, 75 do run_next() end
        assert.are.same({ 77 }, helper.cancelled)
        assert.truthy(_G.ui_tracker.last_shown.args.title:find("not assessed", 1, true))
    end)

    it("closeAllMenus aborts the review: no poll, no reopened walk, child cancelled", function()
        plugin:walkDuplicatePairs(plugin.characters, "characters", candidates(2))
        local polls = 0
        helper.checkAsyncResult = function() polls = polls + 1; return { typesafe_annotations = {} } end
        local tick = sched[1]
        plugin:closeAllMenus()
        tick()
        for _ = 1, 5 do run_next() end
        assert.are.equal(0, polls)
        assert.are.same({ 77 }, helper.cancelled)
        assert.is_nil(plugin.typesafe_review)
        for _, w in ipairs(_G.ui_tracker.shown) do
            assert.is_falsy(w.type == "ButtonDialog" and w.args.title and w.args.title:find("TypeSafe Jev:", 1, true))
        end
    end)

    it("a stale result aborts instead of resuming, and a newer review supersedes the old poll", function()
        plugin:walkDuplicatePairs(plugin.characters, "characters", candidates(1))
        helper.result = { false, "error_stale", "stale" }
        run_next()
        assert.is_nil(plugin.typesafe_review)
        assert.are.equal("InfoMessage", _G.ui_tracker.last_shown.type)

        plugin:walkDuplicatePairs(plugin.characters, "characters", candidates(1))
        local first = sched[1]
        plugin:walkDuplicatePairs(plugin.characters, "characters", candidates(1))
        helper.result = { { typesafe_annotations = {} } }
        local walks = 0
        local real = plugin.walkDuplicatePairs
        plugin.walkDuplicatePairs = function(...) walks = walks + 1; return real(...) end
        first()
        assert.are.equal(0, walks)
        run_next()
        assert.are.equal(1, walks)
    end)

    it("opted out: no TypeSafe call and the original review is unchanged", function()
        helper.isTypeSafeEnabled = function() return false end
        plugin:walkDuplicatePairs(plugin.characters, "characters", candidates(1))
        assert.are.equal(0, #helper.started)
        assert.is_nil(_G.ui_tracker.last_shown.args.title:find("TypeSafe", 1, true))
    end)
end)

describe("saveSettings atomic persistence (scratch disk)", function()
    local AIHelper, root, old_ds, old_settings, old_open, old_rename

    local function read(path)
        local f = io.open(path, "r"); if not f then return nil end
        local c = f:read("*a"); f:close(); return c
    end

    before_each(function()
        AIHelper = require("xray_aihelper")
        root = os.tmpname(); os.remove(root)
        os.execute("mkdir -p '" .. root .. "/xray'")
        old_ds = package.loaded["datastorage"]
        package.loaded["datastorage"] = { getSettingsDir = function() return root end }
        old_settings = AIHelper.settings
        AIHelper.settings = { gemini_api_key = "g_prev" }
        assert.is_true(AIHelper:saveSettings())
        old_open, old_rename = io.open, os.rename
    end)
    after_each(function()
        io.open, os.rename = old_open, old_rename
        package.loaded["datastorage"] = old_ds
        AIHelper.settings = old_settings
        os.execute("rm -rf '" .. root .. "'")
    end)

    it("saves and reloads, preserving other keys and table identity", function()
        local tbl = AIHelper.settings
        assert.is_true(AIHelper:setTypeSafeKey("ts_test_key_SECRET123"))
        assert.are.equal(tbl, AIHelper.settings)
        local disk = require("json").decode(read(root .. "/xray/settings.json"))
        assert.are.equal("ts_test_key_SECRET123", disk.typesafe_api_key)
        assert.are.equal("g_prev", disk.gemini_api_key)
        assert.is_nil(disk.typesafe_enabled)
        assert.is_nil(read(root .. "/xray/settings.json.tmp"))
    end)

    local failures = {
        open = function() io.open = function(p, m) if p:find("%.tmp$") then return nil end return old_open(p, m) end end,
        write = function() io.open = function(p, m)
            local f = old_open(p, m)
            if f and p:find("%.tmp$") then
                return { write = function() return nil, "disk full" end, flush = function() return true end,
                    close = function() return f:close() end }
            end
            return f
        end end,
        close = function() io.open = function(p, m)
            local f = old_open(p, m)
            if f and p:find("%.tmp$") then
                return { write = function(_, s) return f:write(s) end, flush = function() return f:flush() end,
                    close = function() f:close(); return nil, "io error" end }
            end
            return f
        end end,
        rename = function() os.rename = function() return nil, "EXDEV" end end,
    }
    for name, inject in pairs(failures) do
        it("forced " .. name .. " failure keeps prior file and memory, and the UI shows an error", function()
            local before = read(root .. "/xray/settings.json")
            inject()
            local ok, err = AIHelper:setTypeSafeKey("ts_test_key_SECRET123")
            io.open, os.rename = old_open, old_rename
            assert.is_false(ok)
            assert.truthy(err:find("Could not save", 1, true))
            assert.is_nil(AIHelper.settings.typesafe_api_key)
            assert.are.equal("g_prev", AIHelper.settings.gemini_api_key)
            assert.are.equal(before, read(root .. "/xray/settings.json"))
            assert.is_nil(read(root .. "/xray/settings.json.tmp"))
            -- Through the real settings UI entrypoint.
            inject()
            local ui = require("xray_typesafe_ui"):new({ ai_helper = AIHelper }, {})
            ui:saveKey("ts_test_key_SECRET123")
            io.open, os.rename = old_open, old_rename
            assert.truthy(_G.ui_tracker.last_shown.args.text:find("Could not save", 1, true))
            assert.is_nil(AIHelper.settings.typesafe_api_key)
        end)
    end
end)
