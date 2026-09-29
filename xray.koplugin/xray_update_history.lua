-- xray_update_history.lua: bounded, privacy-safe, persistent history of X-Ray
-- update attempts. Settings-only: nothing here shows UI during reading.
--
-- Stored in its own file (never settings.json, which holds API keys), written
-- atomically (tmp + rename) from the PARENT process only. Entries contain only
-- metadata: timestamp, operation, a truncated book label, provider id, model,
-- failover slot, outcome, counts and a short error code. No free-text error
-- messages (provider messages can echo request data), prompts, book text,
-- tokens or provider bodies.

local M = {
    MAX_ENTRIES = 50,
    MAX_FILE_BYTES = 64 * 1024,
    MAX_STR = 80,
    MAX_MSG = 120,
}

local OUTCOMES = { success = true, failed = true, skipped = true, cancelled = true }
local SLOTS = { primary = true, secondary = true }
local COUNT_KEYS = { "characters", "locations", "terms", "timeline", "historical_figures" }

local function getJSON()
    local ok, json = pcall(require, "json")
    if ok and type(json) == "table" then return json end
    return nil
end

-- Truncate a string on a UTF-8 boundary and strip control characters.
local function clip(v, limit)
    if type(v) ~= "string" then return nil end
    v = v:gsub("[%c]", " ")
    if #v > limit then
        local cut = limit
        while cut > 0 do
            local b = v:byte(cut + 1)
            if not b or b < 0x80 or b >= 0xC0 then break end
            cut = cut - 1
        end
        v = v:sub(1, cut) .. "…"
    end
    if v == "" then return nil end
    return v
end

local function sanitizeCode(code)
    if type(code) ~= "string" then return nil end
    if code == "USER_CANCELLED" then return "cancelled" end
    local c = code:match("^[%w_]+$")
    return c and clip(c, 40) or nil
end

-- Normalise one entry; returns nil if it is not a valid entry.
function M.sanitizeEntry(e)
    if type(e) ~= "table" then return nil end
    local ts = tonumber(e.ts)
    if not ts or ts < 0 then return nil end
    local op = type(e.op) == "string" and e.op:match("^[%w_]+$")
    if not op then return nil end
    local outcome = OUTCOMES[e.outcome] and e.outcome or nil
    if not outcome then return nil end
    local out = {
        ts = math.floor(ts),
        op = clip(op, 40),
        outcome = outcome,
        book = clip(e.book, M.MAX_STR),
        provider = type(e.provider) == "string" and clip(e.provider:match("^[%w_%-]+$"), 40) or nil,
        model = type(e.model) == "string" and clip(e.model:match("^[%w_%.%-/:]+$"), M.MAX_STR) or nil,
        slot = SLOTS[e.slot] and e.slot or nil,
        error_code = sanitizeCode(e.error_code),
        cache_saved = (type(e.cache_saved) == "boolean") and e.cache_saved or nil,
    }
    if type(e.counts) == "table" then
        local counts = {}
        local any = false
        for _, k in ipairs(COUNT_KEYS) do
            local n = tonumber(e.counts[k])
            if n and n >= 0 then counts[k] = math.floor(math.min(n, 1e6)); any = true end
        end
        if any then out.counts = counts end
    end
    return out
end

function M.new(path)
    return setmetatable({ path = path }, { __index = M })
end

function M:_defaultPath()
    if self.path then return self.path end
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage or not DataStorage.getSettingsDir then return nil end
    return DataStorage:getSettingsDir() .. "/xray/update_history.json"
end

function M:load()
    local path = self:_defaultPath()
    if not path then return {} end
    local f = io.open(path, "rb")
    if not f then return {} end
    local size = f:seek("end") or 0
    if size > self.MAX_FILE_BYTES then f:close(); return {} end
    f:seek("set", 0)
    local content = f:read(self.MAX_FILE_BYTES) or ""
    f:close()
    local json = getJSON()
    if not json then return {} end
    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then return {} end
    local list = type(data.entries) == "table" and data.entries or data
    local out = {}
    for i = 1, math.min(#list, self.MAX_ENTRIES * 2) do
        local e = self.sanitizeEntry(list[i])
        if e then table.insert(out, e) end
    end
    while #out > self.MAX_ENTRIES do table.remove(out, 1) end
    return out
end

function M:save(entries)
    local path = self:_defaultPath()
    local json = getJSON()
    if not path or not json then return false end
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs or type(lfs) ~= "table" then ok_lfs, lfs = pcall(require, "lfs") end
        if ok_lfs and type(lfs) == "table" and lfs.attributes and lfs.mkdir and not lfs.attributes(dir, "mode") then
            pcall(lfs.mkdir, dir)
        end
    end
    local ok, encoded = pcall(json.encode, { version = 1, entries = entries })
    if not ok or type(encoded) ~= "string" then return false end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local wrote = f:write(encoded)
    f:close()
    if not wrote then os.remove(tmp); return false end
    local renamed = os.rename(tmp, path)
    if not renamed then os.remove(tmp); return false end
    return true
end

-- Append one entry (sanitised, bounded). Never raises.
-- opts.coalesce_seconds: if the newest entry has the same op/outcome/
-- error_code/book within that window, refresh its timestamp instead of adding
-- a duplicate (keeps repeated offline skips from flooding the history).
function M:record(entry, opts)
    local ok, res = pcall(function()
        if type(entry) ~= "table" then return false end
        entry.ts = entry.ts or os.time()
        local e = self.sanitizeEntry(entry)
        if not e then return false end
        local list = self:load()
        local last = list[#list]
        local window = opts and tonumber(opts.coalesce_seconds)
        if window and last and last.op == e.op and last.outcome == e.outcome
            and last.error_code == e.error_code and last.book == e.book
            and e.ts - last.ts >= 0 and e.ts - last.ts < window then
            return true
        end
        table.insert(list, e)
        while #list > self.MAX_ENTRIES do table.remove(list, 1) end
        return self:save(list)
    end)
    return ok and res == true
end

function M:clear()
    return self:save({})
end

local OP_LABELS = {
    fetch = "Fetch", update = "Update", background = "Background update",
    more_characters = "More characters", more_terms = "More terms",
    author = "Author info", lookup = "Word lookup",
}

-- Plain text rendering (newest first) for the settings viewer.
function M.format(entries)
    if type(entries) ~= "table" or #entries == 0 then
        return "No update history yet."
    end
    local lines = {}
    for i = #entries, 1, -1 do
        local e = entries[i]
        local parts = { os.date("%Y-%m-%d %H:%M", e.ts), OP_LABELS[e.op] or e.op, e.outcome }
        local line = table.concat(parts, "  ")
        if e.book then line = line .. "\n  " .. e.book end
        if e.provider then
            line = line .. "\n  " .. e.provider .. (e.model and (" / " .. e.model) or "")
                .. (e.slot and (" (" .. e.slot .. ")") or "")
        end
        if e.counts then
            local c = {}
            for _, k in ipairs(COUNT_KEYS) do
                if e.counts[k] then table.insert(c, k .. " " .. e.counts[k]) end
            end
            if #c > 0 then line = line .. "\n  " .. table.concat(c, ", ") end
        end
        if e.cache_saved == false then line = line .. "\n  cache not saved" end
        if e.error_code then line = line .. "\n  " .. e.error_code end
        table.insert(lines, line)
    end
    return table.concat(lines, "\n\n")
end

return M
