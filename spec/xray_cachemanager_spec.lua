-- xray_cachemanager_spec.lua
require("spec.spec_helper")
local cache_manager = require("xray_cachemanager"):new()

describe("xray_cachemanager", function()
    local test_book = "/tmp/test_book.epub"
    local test_cache = test_book .. ".sdr/xray_cache.lua"

    before_each(function()
        -- Ensure clean state
        os.execute("rm -rf /tmp/test_book.epub.sdr")
        os.execute("mkdir -p /tmp/test_book.epub.sdr")
    end)

    describe("getCachePath", function()
        it("returns correct sidecar path", function()
            local path = cache_manager:getCachePath(test_book)
            assert.are.equal(test_cache, path)
        end)
    end)

    describe("Serialization and Saving", function()
        it("saves and loads data correctly", function()
            local data = {
                characters = {
                    { name = "Alice", role = "Protagonist" }
                },
                last_fetch_page = 42
            }

            local success = cache_manager:saveCache(test_book, data)
            assert.is_true(success)

            local loaded = cache_manager:loadCache(test_book)
            assert.is_not_nil(loaded)
            assert.are.equal("Alice", loaded.characters[1].name)
            assert.are.equal(42, loaded.last_fetch_page)
            assert.are.equal("6.0", loaded.cache_version)
        end)

        it("saves and loads data correctly using asyncSaveCache fallback", function()
            local data = {
                characters = {
                    { name = "Bob", role = "Deuteragonist" }
                },
                last_fetch_page = 101
            }

            local done_called = false
            local success = cache_manager:asyncSaveCache(test_book, data, function(res)
                done_called = true
                assert.is_true(res)
            end)
            assert.is_true(success)
            assert.is_true(done_called)

            -- Allow any forked child process time to finish writing before reading
            os.execute("sleep 0.2")

            local loaded = cache_manager:loadCache(test_book)
            assert.is_not_nil(loaded)
            assert.are.equal("Bob", loaded.characters[1].name)
            assert.are.equal(101, loaded.last_fetch_page)
        end)

        it("reports false from the cooperative save when the final rename fails", function()
            local UIManager = require("ui/uimanager")
            local old_sched, old_rename = UIManager.scheduleIn, os.rename
            UIManager.scheduleIn = function(_, _, cb) cb() end
            os.rename = function() return nil, "EXDEV" end
            local result
            local started = cache_manager:asyncSaveCache(test_book, { characters = {} }, function(res) result = res end)
            UIManager.scheduleIn, os.rename = old_sched, old_rename
            assert.is_true(started)
            assert.is_false(result)
        end)

        it("keeps the previous cache when the final rename fails", function()
            assert.is_true(cache_manager:saveCache(test_book, { characters = { { name = "Old" } } }))
            local UIManager = require("ui/uimanager")
            local old_sched, old_rename = UIManager.scheduleIn, os.rename
            UIManager.scheduleIn = function(_, _, cb) cb() end
            os.rename = function() return nil, "EIO" end
            local result
            cache_manager:asyncSaveCache(test_book, { characters = { { name = "New" } } }, function(res) result = res end)
            UIManager.scheduleIn, os.rename = old_sched, old_rename
            assert.is_false(result)
            local loaded = cache_manager:loadCache(test_book)
            assert.are.equal("Old", loaded.characters[1].name)
        end)

        it("atomically replaces the previous cache on success", function()
            assert.is_true(cache_manager:saveCache(test_book, { characters = { { name = "Old" } } }))
            local UIManager = require("ui/uimanager")
            local old_sched = UIManager.scheduleIn
            UIManager.scheduleIn = function(_, _, cb) cb() end
            local result
            cache_manager:asyncSaveCache(test_book, { characters = { { name = "New" } } }, function(res) result = res end)
            UIManager.scheduleIn = old_sched
            assert.is_true(result)
            assert.are.equal("New", cache_manager:loadCache(test_book).characters[1].name)
        end)

        for _, failure in ipairs({ "close", "rename" }) do
            it("preserves the old cache and drains pending callbacks after " .. failure .. " failure", function()
                assert.is_true(cache_manager:saveCache(test_book, { name = "Old" }))
                local UIManager = require("ui/uimanager")
                local old_sched, old_open, old_rename = UIManager.scheduleIn, io.open, os.rename
                local queue, results = {}, {}
                UIManager.scheduleIn = function(_, _, cb) table.insert(queue, cb) end
                if failure == "close" then
                    io.open = function(path, mode)
                        local f, err = old_open(path, mode)
                        if f and path == test_cache .. ".tmp" and mode == "w" then
                            return {
                                write = function(_, ...) return f:write(...) end,
                                close = function() f:close(); return nil, "EIO" end,
                            }
                        end
                        return f, err
                    end
                else
                    os.rename = function() return nil, "EIO" end
                end
                local ok, err = pcall(function()
                    cache_manager:asyncSaveCache(test_book, { name = "Failed" }, function(res)
                        table.insert(results, { "active", res })
                    end)
                    cache_manager:asyncSaveCache(test_book, { name = "Pending" }, function(res)
                        table.insert(results, { "pending", res })
                        error("callback failure must not block other callbacks")
                    end)
                    cache_manager:asyncSaveCache(test_book, { name = "Latest" }, function(res)
                        table.insert(results, { "latest", res })
                    end)
                    -- Complete the first write, then restore I/O for the queued write.
                    if failure == "close" then io.open = old_open end
                    table.remove(queue, 1)()
                    os.rename = old_rename
                    assert.are.equal("Old", cache_manager:loadCache(test_book).name)
                    while #queue > 0 do table.remove(queue, 1)() end
                end)
                UIManager.scheduleIn, io.open, os.rename = old_sched, old_open, old_rename
                assert.is_true(ok, tostring(err))
                assert.are.equal(3, #results)
                assert.are.equal("active", results[1][1])
                assert.is_false(results[1][2])
                assert.is_true(results[2][2])
                assert.is_true(results[3][2])
                assert.are.equal("Latest", cache_manager:loadCache(test_book).name)
                assert.are.equal(0, #cache_manager._active_saves)
                assert.is_nil(cache_manager._active_by_file[test_cache])
                assert.is_nil(cache_manager._pending_by_file[test_cache])
            end)
        end

        it("reports failed flush persistence to every callback", function()
            assert.is_true(cache_manager:saveCache(test_book, { name = "Old" }))
            local UIManager = require("ui/uimanager")
            local old_sched, old_rename = UIManager.scheduleIn, os.rename
            local queue, results = {}, {}
            UIManager.scheduleIn = function(_, _, cb) table.insert(queue, cb) end
            cache_manager:asyncSaveCache(test_book, { name = "Active" }, function(res) table.insert(results, res) end)
            cache_manager:asyncSaveCache(test_book, { name = "Pending" }, function(res) table.insert(results, res) end)
            os.rename = function() return nil, "EIO" end
            cache_manager:flushAsyncSaves()
            os.rename = old_rename
            while #queue > 0 do table.remove(queue, 1)() end
            UIManager.scheduleIn = old_sched
            assert.are.equal(2, #results)
            assert.is_false(results[1])
            assert.is_false(results[2])
            assert.are.equal("Old", cache_manager:loadCache(test_book).name)
        end)

        for _, action in ipairs({ "cancel", "flush", "sync" }) do
            it("does not let a stale " .. action .. " coroutine remove a newer save", function()
                local UIManager = require("ui/uimanager")
                local old_sched = UIManager.scheduleIn
                local queue, results = {}, {}
                UIManager.scheduleIn = function(_, _, cb) table.insert(queue, cb) end
                cache_manager:asyncSaveCache(test_book, { name = "Active" }, function(res)
                    table.insert(results, { "old", res })
                end)
                if action == "cancel" then
                    cache_manager:cancelAsyncSaves()
                elseif action == "flush" then
                    cache_manager:flushAsyncSaves()
                else
                    cache_manager:saveCache(test_book, { name = "Sync" })
                end
                cache_manager:asyncSaveCache(test_book, { name = "New" }, function(res)
                    table.insert(results, { "new", res })
                end)
                while #queue > 0 do table.remove(queue, 1)() end
                UIManager.scheduleIn = old_sched
                assert.are.equal(2, #results)
                assert.are.equal(action == "flush", results[1][2])
                assert.is_true(results[2][2])
                assert.are.equal("New", cache_manager:loadCache(test_book).name)
            end)
        end

        it("handles circular references gracefully", function()
            local data = { name = "Alice" }
            data.self = data -- Circular reference

            local success = cache_manager:saveCache(test_book, data)
            assert.is_true(success)

            local loaded = cache_manager:loadCache(test_book)
            -- The circular reference is serialized as an empty table with a comment marker
            assert.is_table(loaded.self)
            assert.are.equal(0, #loaded.self)
        end)

        it("cancels active async saves cleanly", function()
            local cm = require("xray_cachemanager"):new()
            assert.is_table(cm._active_saves)
            cm:cancelAsyncSaves()
            assert.are.equal(0, #cm._active_saves)
        end)

        it("safely handles truncated or corrupted cache files with syntax error", function()
            -- Write a corrupted cache file that only has 'return ' (as from an interrupted save)
            local f = io.open(test_cache, "w")
            f:write("-- X-Ray Cache v6.0\n-- Generated: 2026-09-08 12:00:00\n\nreturn \n")
            f:close()

            local loaded = cache_manager:loadCache(test_book)
            assert.is_nil(loaded)
        end)

        it("performs atomic writes so temp files are cleaned up", function()
            local data = { characters = { { name = "Charlie" } } }
            local success = cache_manager:saveCache(test_book, data)
            assert.is_true(success)

            local tmp_file = test_cache .. ".tmp"
            local f_tmp = io.open(tmp_file, "r")
            assert.is_nil(f_tmp) -- tmp file should not linger after successful save

            local loaded = cache_manager:loadCache(test_book)
            assert.is_not_nil(loaded)
            assert.are.equal("Charlie", loaded.characters[1].name)
        end)

        it("serializes and coalesces overlapping async saves cleanly without data loss", function()
            local UIManager = require("ui/uimanager")
            local orig_scheduleIn = UIManager.scheduleIn
            local queue = {}
            UIManager.scheduleIn = function(self_or_delay, delay_or_fn, maybe_fn)
                local fn = type(maybe_fn) == "function" and maybe_fn or (type(delay_or_fn) == "function" and delay_or_fn or self_or_delay)
                table.insert(queue, fn)
            end

            local data1 = { characters = { { name = "FirstSave" } } }
            local data2 = { characters = { { name = "SecondSave" } } }
            local data3 = { characters = { { name = "ThirdSave" } } }

            local cb1_called, cb2_called, cb3_called = false, false, false

            -- First async save starts
            local s1 = cache_manager:asyncSaveCache(test_book, data1, function(res)
                cb1_called = res
            end)
            assert.is_true(s1)
            -- Coroutine is scheduled in queue, file is open
            assert.are.equal(1, #queue)

            -- Second async save is requested while first is active -> gets queued as pending
            local s2 = cache_manager:asyncSaveCache(test_book, data2, function(res)
                cb2_called = res
            end)
            assert.is_true(s2)

            -- Third async save is requested while first is still active -> coalesces pending with data3
            local s3 = cache_manager:asyncSaveCache(test_book, data3, function(res)
                cb3_called = res
            end)
            assert.is_true(s3)

            -- Drive the scheduled queue to completion
            local iterations = 0
            while #queue > 0 and iterations < 1000 do
                iterations = iterations + 1
                local step = table.remove(queue, 1)
                step()
            end

            UIManager.scheduleIn = orig_scheduleIn

            assert.is_true(cb1_called)
            assert.is_true(cb2_called)
            assert.is_true(cb3_called)

            -- Cache file should exist and have data3 (the latest coalesced data)
            local loaded = cache_manager:loadCache(test_book)
            assert.is_not_nil(loaded)
            assert.are.equal("ThirdSave", loaded.characters[1].name)

            -- Temp file should be cleaned up
            local f_tmp = io.open(test_cache .. ".tmp", "r")
            assert.is_nil(f_tmp)
        end)

        it("handles synchronous saveCache while an async save is active", function()
            local UIManager = require("ui/uimanager")
            local orig_scheduleIn = UIManager.scheduleIn
            local queue = {}
            UIManager.scheduleIn = function(self_or_delay, delay_or_fn, maybe_fn)
                local fn = type(maybe_fn) == "function" and maybe_fn or (type(delay_or_fn) == "function" and delay_or_fn or self_or_delay)
                table.insert(queue, fn)
            end

            local async_data = { characters = { { name = "AsyncInFlight" } } }
            local async_cb_called = nil
            local s1 = cache_manager:asyncSaveCache(test_book, async_data, function(res)
                async_cb_called = res
            end)
            assert.is_true(s1)

            -- Save synchronously while async is in flight
            local sync_data = { characters = { { name = "SyncOverride" } } }
            local s2 = cache_manager:saveCache(test_book, sync_data)
            assert.is_true(s2)

            -- In-flight async callback was notified of cancellation
            assert.is_false(async_cb_called)

            UIManager.scheduleIn = orig_scheduleIn

            -- Cache file has sync data
            local loaded = cache_manager:loadCache(test_book)
            assert.is_not_nil(loaded)
            assert.are.equal("SyncOverride", loaded.characters[1].name)
        end)

        it("flushes in-flight and pending async saves synchronously with flushAsyncSaves", function()
            local UIManager = require("ui/uimanager")
            local orig_scheduleIn = UIManager.scheduleIn
            local queue = {}
            UIManager.scheduleIn = function(self_or_delay, delay_or_fn, maybe_fn)
                local fn = type(maybe_fn) == "function" and maybe_fn or (type(delay_or_fn) == "function" and delay_or_fn or self_or_delay)
                table.insert(queue, fn)
            end

            local data1 = { characters = { { name = "ActiveSave" } } }
            local data2 = { characters = { { name = "PendingSave" } } }
            local cb1_called, cb2_called = nil, nil

            cache_manager:asyncSaveCache(test_book, data1, function(res) cb1_called = res end)
            cache_manager:asyncSaveCache(test_book, data2, function(res) cb2_called = res end)

            -- Flush all saves synchronously
            cache_manager:flushAsyncSaves()

            UIManager.scheduleIn = orig_scheduleIn

            assert.is_true(cb1_called)
            assert.is_true(cb2_called)

            -- The loaded cache must contain data2 (the newest pending data)
            local loaded = cache_manager:loadCache(test_book)
            assert.is_not_nil(loaded)
            assert.are.equal("PendingSave", loaded.characters[1].name)
        end)

        it("does not serialize private underscore fields like _norm_name and _norm_aliases", function()
            local data = {
                characters = {
                    {
                        name = "Sherlock Holmes",
                        _norm_name = "sherlock holmes",
                        aliases = { "Sherlock" },
                        _norm_aliases = { "sherlock" }
                    }
                }
            }
            local success = cache_manager:saveCache(test_book, data)
            assert.is_true(success)

            local f = io.open(test_cache, "r")
            assert.is_not_nil(f)
            local content = f:read("*all")
            f:close()

            assert.is_nil(content:find("_norm_name"))
            assert.is_nil(content:find("_norm_aliases"))

            local loaded = cache_manager:loadCache(test_book)
            assert.is_not_nil(loaded)
            assert.are.equal("Sherlock Holmes", loaded.characters[1].name)
            assert.is_nil(loaded.characters[1]._norm_name)
            assert.is_nil(loaded.characters[1]._norm_aliases)
        end)
    end)
end)
