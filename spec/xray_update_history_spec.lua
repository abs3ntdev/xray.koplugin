-- xray_update_history_spec.lua: bounded, privacy-safe persistent update
-- history, its fetch integration and its settings-only viewer.
require("spec.spec_helper")

describe("xray_update_history", function()
    local History, json
    local path

    setup(function()
        History = require("xray_update_history")
        json = require("json")
    end)

    before_each(function()
        path = os.tmpname()
        os.remove(path)
    end)

    after_each(function()
        os.remove(path)
        os.remove(path .. ".tmp")
    end)

    local function readRaw()
        local f = io.open(path, "rb"); if not f then return nil end
        local s = f:read("*a"); f:close(); return s
    end

    it("persists entries across instances", function()
        local h = History.new(path)
        assert.is_true(h:record({ ts = 100, op = "fetch", outcome = "success", book = "Dune",
            provider = "openai_account", model = "gpt-6-luna", slot = "primary",
            counts = { characters = 3, locations = 2 }, cache_saved = true }))
        local list = History.new(path):load()
        assert.are.equal(1, #list)
        assert.are.equal("openai_account", list[1].provider)
        assert.are.equal("primary", list[1].slot)
        assert.are.equal(3, list[1].counts.characters)
        assert.is_true(list[1].cache_saved)
        assert.is_nil(io.open(path .. ".tmp", "rb"))
    end)

    it("persists cache_saved = false and formats it after reload", function()
        History.new(path):record({ ts = 100, op = "update", outcome = "failed", error_code = "error_save", cache_saved = false })
        local list = History.new(path):load()
        assert.are.equal(false, list[1].cache_saved)
        assert.is_truthy(History.format(list):find("cache not saved", 1, true))
    end)

    it("bounds the number of entries, keeping the newest", function()
        local h = History.new(path)
        for i = 1, History.MAX_ENTRIES + 15 do
            h:record({ ts = i, op = "fetch", outcome = "failed", error_code = "error_api" })
        end
        local list = h:load()
        assert.are.equal(History.MAX_ENTRIES, #list)
        assert.are.equal(16, list[1].ts)
        assert.are.equal(History.MAX_ENTRIES + 15, list[#list].ts)
    end)

    it("stores no free-text messages, prompts or tokens and clips strings", function()
        local h = History.new(path)
        h:record({ ts = 1, op = "fetch", outcome = "failed", error_code = "error_auth",
            message = "Bearer tok_SECRET_ACCESS", prompt = "PROMPT BODY", body = "{\"raw\":1}",
            access_token = "tok_SECRET", book = string.rep("é", 200),
            provider = "evil provider {x}", model = "gpt-6-luna" })
        local raw = readRaw()
        assert.is_nil(raw:find("tok_", 1, true))
        assert.is_nil(raw:find("PROMPT", 1, true))
        assert.is_nil(raw:find("raw", 1, true))
        local e = h:load()[1]
        assert.is_nil(e.message)
        assert.is_nil(e.provider)
        assert.is_true(#e.book <= History.MAX_STR + 3)
    end)

    it("maps USER_CANCELLED to a cancelled code and rejects odd codes", function()
        local h = History.new(path)
        h:record({ ts = 1, op = "fetch", outcome = "cancelled", error_code = "USER_CANCELLED" })
        h:record({ ts = 2, op = "fetch", outcome = "failed", error_code = "HTTP 500: secret body" })
        local list = h:load()
        assert.are.equal("cancelled", list[1].error_code)
        assert.is_nil(list[2].error_code)
    end)

    it("drops malformed entries and ignores corrupt or oversized files", function()
        local f = io.open(path, "wb")
        f:write(json.encode({ entries = { { ts = 5, op = "fetch", outcome = "success" }, "junk",
            { ts = "x", op = "fetch", outcome = "success" }, { ts = 6, op = "fetch", outcome = "weird" } } }))
        f:close()
        local list = History.new(path):load()
        assert.are.equal(1, #list)

        f = io.open(path, "wb"); f:write("{not json"); f:close()
        assert.are.same({}, History.new(path):load())

        f = io.open(path, "wb"); f:write(string.rep(" ", History.MAX_FILE_BYTES + 1)); f:close()
        assert.are.same({}, History.new(path):load())
        -- A new record after a corrupt file starts a clean, valid list.
        assert.is_true(History.new(path):record({ ts = 7, op = "fetch", outcome = "success" }))
        assert.are.equal(1, #History.new(path):load())
    end)

    it("coalesces repeated skips within the window", function()
        local h = History.new(path)
        h:record({ ts = 100, op = "background", outcome = "skipped", error_code = "offline" }, { coalesce_seconds = 3600 })
        h:record({ ts = 200, op = "background", outcome = "skipped", error_code = "offline" }, { coalesce_seconds = 3600 })
        assert.are.equal(1, #h:load())
        h:record({ ts = 5000, op = "background", outcome = "skipped", error_code = "offline" }, { coalesce_seconds = 3600 })
        assert.are.equal(2, #h:load())
    end)

    it("formats newest first and never raises on record failure", function()
        local text = History.format({
            { ts = 1, op = "fetch", outcome = "success", provider = "gemini", model = "m", slot = "secondary" },
            { ts = 2, op = "update", outcome = "failed", error_code = "error_save", cache_saved = false },
        })
        assert.is_truthy(text:find("Update.-failed.-Fetch.-secondary"))
        assert.is_truthy(text:find("cache not saved", 1, true))
        assert.is_false(History.new("/nonexistent_dir_xyz/h.json"):record({ ts = 1, op = "fetch", outcome = "success" }))
    end)
end)

describe("update history integration", function()
    local fetch, History, path, plugin, UIManager, old_schedule, scheduled

    setup(function()
        fetch = require("xray_fetch")
        History = require("xray_update_history")
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        path = os.tmpname(); os.remove(path)
        plugin = createMockPlugin()
        for k, v in pairs(fetch) do plugin[k] = v end
        plugin.update_history = History.new(path)
        scheduled = {}
        old_schedule = UIManager.scheduleIn
        UIManager.scheduleIn = function(_, _, cb) table.insert(scheduled, cb) end
        plugin.ui.getCurrentPage = function() return 10 end
        plugin.chapter_analyzer = {
            getEndPageForCurrentPage = function(_, _, p) return p end,
            getTextForAnalysis = function() return "enough extracted book text" end,
            getDetailedChapterSamples = function() return "samples", { "Ch 1" } end,
            getAnnotationsForAnalysis = function() return nil end,
        }
    end)

    after_each(function()
        UIManager.scheduleIn = old_schedule
        os.remove(path)
    end)

    local function helper(result)
        return {
            settings = { spoiler_setting = "spoiler_free" },
            buildComprehensiveRequest = function() return { { url = "x", provider = "chatgpt" } } end,
            makeRequestAsync = function(self) self._async_child_pid = 77; return 77 end,
            cancelAsyncChild = function(self) self._async_child_pid = nil; return true end,
            checkAsyncResult = function(self)
                self._async_child_pid = nil
                self.last_route = { provider = "chatgpt", model = "gpt-5.4-mini", slot = "secondary" }
                return result[1], result[2], result[3]
            end,
        }
    end

    local function drain()
        local n = 0
        while #scheduled > 0 and n < 20 do table.remove(scheduled, 1)(); n = n + 1 end
    end

    it("records the serving secondary route and persisted counts after a merged success", function()
        plugin.ai_helper = helper({ { characters = {} } })
        plugin.finalizeXRayData = function()
            return { outcome = "success", cache_saved = true, counts = { characters = 4 } }
        end
        local shown_before = #_G.ui_tracker.shown
        plugin:continueWithFetch(50, true, nil, true)
        drain()
        local e = History.new(path):load()[1]
        assert.are.equal("background", e.op)
        assert.are.equal("success", e.outcome)
        assert.are.equal("secondary", e.slot)
        assert.are.equal("chatgpt", e.provider)
        assert.are.equal(4, e.counts.characters)
        assert.are.equal("Test Title", e.book)
        -- Silent background run shows nothing, including no history UI.
        assert.are.equal(shown_before, #_G.ui_tracker.shown)
    end)

    it("does not record success when the cache was not saved", function()
        plugin.ai_helper = helper({ { characters = {} } })
        plugin.finalizeXRayData = function()
            return { outcome = "failed", error_code = "error_save", cache_saved = false, counts = { characters = 1 } }
        end
        plugin:continueWithFetch(50, true, nil, true)
        drain()
        local e = History.new(path):load()[1]
        assert.are.equal("failed", e.outcome)
        assert.are.equal("error_save", e.error_code)
        assert.are.equal(false, e.cache_saved)
    end)

    it("records a merge crash as a failure", function()
        plugin.ai_helper = helper({ { characters = {} } })
        plugin.finalizeXRayData = function() error("merge boom") end
        plugin:continueWithFetch(50, true, nil, true)
        drain()
        local e = History.new(path):load()[1]
        assert.are.equal("error_merge", e.error_code)
    end)

    it("records provider failures by code only", function()
        plugin.ai_helper = helper({ false, "error_quota", "Bearer tok_SECRET quota body" })
        plugin:continueWithFetch(50, true, nil, true)
        drain()
        local raw = io.open(path, "rb"):read("*a")
        assert.is_nil(raw:find("tok_", 1, true))
        local e = History.new(path):load()[1]
        assert.are.equal("failed", e.outcome)
        assert.are.equal("error_quota", e.error_code)
    end)

    it("records a user cancellation as cancelled without UI", function()
        plugin.ai_helper = helper({ nil })
        plugin:continueWithFetch(50, true, nil, true)
        table.remove(scheduled, 1)()
        table.remove(scheduled, 1)()
        plugin:cancelActiveAIRequest("user cancelled")
        local e = History.new(path):load()[1]
        assert.are.equal("cancelled", e.outcome)
    end)

    it("the viewer is only shown when explicitly opened", function()
        local ui = require("xray_ui")
        plugin.showUpdateHistory = ui.showUpdateHistory
        plugin.update_history:record({ ts = 1, op = "fetch", outcome = "success", provider = "gemini", slot = "primary" })
        local before = #_G.ui_tracker.shown
        plugin.ai_helper = helper({ { characters = {} } })
        plugin.finalizeXRayData = function() return { outcome = "success", cache_saved = true } end
        plugin:continueWithFetch(50, true, nil, true)
        drain()
        for i = before + 1, #_G.ui_tracker.shown do
            assert.are_not.equal("TextViewer", _G.ui_tracker.shown[i].type)
        end
        local viewer = plugin:showUpdateHistory()
        assert.are.equal("TextViewer", viewer.type)
        assert.are.equal(viewer, _G.ui_tracker.last_shown)
        assert.is_truthy(viewer.args.text:find("primary", 1, true))
    end)
end)
