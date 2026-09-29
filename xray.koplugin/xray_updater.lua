-- xray_updater.lua - X-Ray fork updater
-- Tracks one fixed GitHub branch (no releases needed). A check reads the
-- branch head commit SHA; an install downloads the archive of that exact SHA,
-- validates it, and installs ONLY the plugin subtree into this plugin dir.
-- Capability marker, checked in downloaded payloads (see docs):
-- XRAY_FORK_UPDATER_V1

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger      = require("logger")

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""

-- ---------------------------------------------------------------------------
-- Source identity (fixed; never derived from the network)
-- ---------------------------------------------------------------------------
local OWNER, REPO, BRANCH = "abs3ntdev", "xray.koplugin", "openai-subscription"
local SOURCE_ID    = "github:" .. OWNER .. "/" .. REPO .. "@" .. BRANCH
local CAPABILITY   = "XRAY_FORK_UPDATER_" .. "V1"
local MARKER_NAME  = ".xray_fork_commit"
local HEAD_URL     = "https://api.github.com/repos/" .. OWNER .. "/" .. REPO .. "/commits/" .. BRANCH
local ARCHIVE_URL  = "https://codeload.github.com/" .. OWNER .. "/" .. REPO .. "/zip/"
local PRESERVE     = { ["xray_config.lua"] = true }

-- Bounds
local MAX_ENTRIES      = 2000      -- all central directory entries
local MAX_SELECTED     = 1000      -- plugin files installed
local MAX_FILE_BYTES   = 8 * 1024 * 1024
local MAX_TOTAL_BYTES  = 32 * 1024 * 1024
local MAX_NAME         = 240
local CHUNK            = 65536

local M = {}
M.loc = nil

local _plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")
    or "/mnt/us/extensions/xray.koplugin"

local FALLBACKS = {
    updater_source_line = "Source: %s",
    updater_installed_unknown = "unknown",
    updater_status_unknown = "The installed build is unknown (it was not installed by this updater).\nLatest commit: %s",
    updater_status_available = "A new build is available.\nInstalled: %s\nLatest: %s",
    updater_status_current = "X-Ray is up to date (%s).",
    updater_err_unsupported = "The published build does not support the fork updater yet. Nothing was installed.",
    updater_checking = "Checking for updates...",
    updater_error_checking_detail = "Error checking for updates: %s",
    updater_btn_cancel = "Cancel",
    updater_btn_download = "Download and install",
    updater_downloading = "Downloading X-Ray %s...",
    updater_err_download = "Download error: %s",
    updater_err_extract = "Update error: %s. The previous version was kept.",
    updater_err_rollback = "Update error: %s. Restoring the previous version failed; backups were left as *.xray-bak files in the plugin folder. Reinstall X-Ray manually.",
    updater_success_restart = "X-Ray %s successfully installed.\n\nRestart KOReader to apply the update?",
    updater_btn_restart = "Restart",
    updater_btn_later = "Later",
    updater_cancelled_update = "Update cancelled.",
    updater_cancelled_check = "Update check cancelled.",
}

local function t(key, ...)
    if M.loc and M.loc.t then
        local val = M.loc:t(key, ...)
        if val and val ~= "" and val ~= key then return val end
    end
    local str = FALLBACKS[key] or key
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, str, ...)
        if ok then return formatted end
    end
    return str
end

local function _toast(msg, timeout)
    local w = InfoMessage:new{ text = msg, timeout = timeout or 4 }
    UIManager:show(w)
    return w
end

local function _closeWidget(w)
    if w then UIManager:close(w) end
end

local function _http()
    local ok, mod = pcall(require, plugin_path .. "xray_secure_http")
    if ok and type(mod) == "table" and type(mod.requestPublic) == "function" then return mod end
end

local function _settingsDir()
    local ok, DS = pcall(require, "datastorage")
    if ok and DS and DS.getSettingsDir then return DS:getSettingsDir() end
end

local function _lfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or type(lfs) ~= "table" then ok, lfs = pcall(require, "lfs") end
    if ok and type(lfs) == "table" and lfs.symlinkattributes and lfs.mkdir then return lfs end
end

local function _short(sha) return sha and sha:sub(1, 7) or t("updater_installed_unknown") end

-- ---------------------------------------------------------------------------
-- Installed marker: "source=<SOURCE_ID>\ncommit=<40 hex>\n". A marker for a
-- different source, or any malformed marker, reads as unknown.
-- ---------------------------------------------------------------------------
local function _markerPath() return _plugin_dir .. "/" .. MARKER_NAME end

local function _installedCommit()
    local fh = io.open(_markerPath(), "rb")
    if not fh then return nil end
    local raw = fh:read(512) or ""
    fh:close()
    local source, commit = raw:match("^source=([^\n]+)\ncommit=(%x+)\n$")
    if source ~= SOURCE_ID or not commit or #commit ~= 40 then return nil end
    return commit:lower()
end

-- ---------------------------------------------------------------------------
-- Remote head
-- ---------------------------------------------------------------------------
local function _fetchHead()
    local http = _http()
    if not http then return nil, "secure transport unavailable" end
    local ok, status, body = http:requestPublic(HEAD_URL, {
        Accept = "application/vnd.github.sha",
        ["User-Agent"] = "KOReader-XRay-Updater/2",
    }, 20)
    if not ok then return nil, tostring(status) end
    if status ~= 200 then return nil, "HTTP " .. tostring(status) end
    local sha = type(body) == "string" and body:match("^%s*(%x+)%s*$")
    if not sha or #sha ~= 40 then return nil, "unexpected commit response" end
    return sha:lower()
end

-- ---------------------------------------------------------------------------
-- ZIP validation (pure Lua; the archive is never extracted wholesale)
-- ---------------------------------------------------------------------------
local function u16(s, i) local a, b = s:byte(i, i + 1); return a + b * 256 end
local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function _safeName(name)
    if #name == 0 or #name > MAX_NAME then return false end
    if name:find("[^%w%._%-/]") or name:find("//", 1, true) or name:sub(1, 1) == "/" then return false end
    for seg in name:gmatch("[^/]+") do
        if seg == "." or seg == ".." then return false end
    end
    return true
end

-- Returns list of { rel, name, size, crc } for the plugin subtree, or nil, err.
local function _inspectZip(data, sha)
    local n = #data
    if n < 22 then return nil, "archive too small" end
    local eocd
    for i = n - 21, math.max(1, n - 65557), -1 do
        if data:byte(i) == 0x50 and u32(data, i) == 0x06054b50 then eocd = i; break end
    end
    if not eocd then return nil, "archive directory not found" end
    local disk, cd_disk = u16(data, eocd + 4), u16(data, eocd + 6)
    local count_disk, count = u16(data, eocd + 8), u16(data, eocd + 10)
    local cd_size, cd_off = u32(data, eocd + 12), u32(data, eocd + 16)
    if disk ~= 0 or cd_disk ~= 0 or count_disk ~= count then return nil, "multi-part archive" end
    if count == 0xFFFF or cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF then return nil, "ZIP64 unsupported" end
    if count > MAX_ENTRIES then return nil, "too many archive entries" end
    if cd_off + cd_size > eocd - 1 then return nil, "archive directory out of bounds" end

    local root = REPO .. "-" .. sha .. "/"
    local prefix = root .. "xray.koplugin/"
    local seen, selected, total = {}, {}, 0
    local p = cd_off + 1
    for _ = 1, count do
        if p + 46 > eocd or u32(data, p) ~= 0x02014b50 then return nil, "corrupt archive directory" end
        local host = math.floor(u16(data, p + 4) / 256)
        local flags, method = u16(data, p + 8), u16(data, p + 10)
        local crc, csize, usize = u32(data, p + 16), u32(data, p + 20), u32(data, p + 24)
        local nlen, elen, clen = u16(data, p + 28), u16(data, p + 30), u16(data, p + 32)
        local start_disk = u16(data, p + 34)
        local mode = math.floor(u32(data, p + 38) / 65536)
        local dos_attr = data:byte(p + 38)
        local loff = u32(data, p + 42)
        local name = data:sub(p + 46, p + 45 + nlen)
        p = p + 46 + nlen + elen + clen
        if p > eocd then return nil, "corrupt archive directory" end
        if flags % 2 == 1 then return nil, "encrypted archive entry" end
        if csize == 0xFFFFFFFF or usize == 0xFFFFFFFF or loff == 0xFFFFFFFF then return nil, "ZIP64 unsupported" end
        if start_disk ~= 0 then return nil, "multi-part archive" end
        if method ~= 0 and method ~= 8 then return nil, "unsupported compression" end
        if not _safeName(name) then return nil, "unsafe archive path" end
        if seen[name] or seen[name .. "/"] or seen[name:gsub("/$", "")] then return nil, "duplicate archive path" end
        seen[name] = true
        if name:sub(1, #root) ~= root then return nil, "unexpected archive root" end
        local is_dir = name:sub(-1) == "/"
        if host == 3 then
            -- Unix attributes: only regular files and directories.
            local ftype = math.floor(mode / 4096)
            if is_dir then
                if ftype ~= 4 then return nil, "unexpected directory entry type" end
            elseif ftype ~= 8 then
                return nil, "non-regular archive entry"
            end
        elseif host == 0 then
            -- MS-DOS attributes (GitHub codeload): no link type exists; the
            -- directory bit must agree with the name.
            local dos_dir = math.floor(dos_attr / 16) % 2 == 1
            if dos_dir ~= is_dir or mode ~= 0 then return nil, "unexpected directory entry type" end
        else
            return nil, "unexpected archive host"
        end
        -- Local header must agree with the central directory.
        local lp = loff + 1
        if lp + 30 > cd_off + 1 or u32(data, lp) ~= 0x04034b50 then return nil, "corrupt local header" end
        local lnlen, lelen = u16(data, lp + 26), u16(data, lp + 28)
        if u16(data, lp + 6) ~= flags or u16(data, lp + 8) ~= method
            or data:sub(lp + 30, lp + 29 + lnlen) ~= name then
            return nil, "inconsistent local header"
        end
        if lp + 30 + lnlen + lelen + csize > cd_off + 1 then return nil, "entry data out of bounds" end
        if not is_dir and name:sub(1, #prefix) == prefix then
            if #selected >= MAX_SELECTED then return nil, "too many plugin files" end
            if usize > MAX_FILE_BYTES then return nil, "plugin file too large" end
            total = total + usize
            if total > MAX_TOTAL_BYTES then return nil, "plugin too large" end
            selected[#selected + 1] = { rel = name:sub(#prefix + 1), name = name, size = usize, crc = crc }
        end
    end
    local have = {}
    for _, e in ipairs(selected) do have[e.rel] = true end
    if not (have["main.lua"] and have["_meta.lua"] and have["xray_updater.lua"]) then
        return nil, "plugin files missing from archive"
    end
    return selected
end

-- CRC-32 (IEEE) over chunks.
local crc_table
local function _crc32(crc, s)
    local ok, bit = pcall(require, "bit")
    if not ok then return nil end
    if not crc_table then
        crc_table = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if bit.band(c, 1) == 1 then c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
                else c = bit.rshift(c, 1) end
            end
            crc_table[i] = c
        end
    end
    crc = bit.bnot(crc)
    for i = 1, #s do
        crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, s:byte(i)), 0xFF)])
    end
    return bit.bnot(crc)
end
local function _u32(x) if x < 0 then return x + 4294967296 end return x end

-- Extract one validated entry with `unzip -p` into a flat stage file.
-- Names are restricted to [A-Za-z0-9._/-], so no glob or shell metacharacter
-- can reach the command; the output is bounded while reading and verified.
-- Re-reads a file from disk and checks it against the central directory, so
-- a short or failed write (e.g. disk full) can never be installed.
local function _verifyFile(path, entry)
    local fh = io.open(path, "rb")
    if not fh then return nil, "cannot read staged file" end
    local size, crc = 0, 0
    while true do
        local chunk = fh:read(CHUNK)
        if not chunk then break end
        size = size + #chunk
        if size > entry.size then fh:close(); return nil, "extracted data mismatch" end
        crc = _crc32(crc, chunk)
        if not crc then fh:close(); return nil, "CRC support unavailable" end
    end
    fh:close()
    if size ~= entry.size or _u32(crc) ~= entry.crc then return nil, "extracted data mismatch" end
    return true
end

local function _shq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function _extractEntry(zip_path, entry, dest)
    local cmd = "unzip -p " .. _shq(zip_path) .. " " .. _shq(entry.name) .. " 2>/dev/null"
    local pipe = io.popen(cmd, "r")
    if not pipe then return nil, "unzip unavailable" end
    local out = io.open(dest, "wb")
    if not out then pipe:close(); return nil, "cannot write staging file" end
    local size = 0
    while true do
        local chunk = pipe:read(CHUNK)
        if not chunk then break end
        size = size + #chunk
        if size > entry.size then out:close(); pipe:close(); return nil, "entry larger than declared" end
        if not out:write(chunk) then out:close(); pipe:close(); return nil, "cannot write staging file" end
    end
    pipe:close()
    if not out:close() then return nil, "cannot write staging file" end
    return _verifyFile(dest, entry)
end

-- ---------------------------------------------------------------------------
-- Filesystem helpers
-- ---------------------------------------------------------------------------
local function _mode(lfs, path)
    local a = lfs.symlinkattributes(path)
    return a and a.mode
end

-- Every existing path component (from "/" or "." down to the path itself)
-- must be a real directory: no symlinked ancestors, no "..".
local function _plainDirChain(lfs, path)
    if type(path) ~= "string" or path == "" then return false end
    for seg in path:gmatch("[^/]+") do
        if seg == ".." then return false end
    end
    local cur = path:sub(1, 1) == "/" and "" or "."
    if _mode(lfs, cur == "" and "/" or cur) ~= "directory" then return false end
    for seg in path:gmatch("[^/]+") do
        if seg ~= "." then
            cur = cur .. "/" .. seg
            if _mode(lfs, cur) ~= "directory" then return false end
        end
    end
    return true
end

local function _copyFile(src, dst)
    local i = io.open(src, "rb"); if not i then return false end
    local o = io.open(dst, "wb"); if not o then i:close(); return false end
    while true do
        local c = i:read(CHUNK)
        if not c then break end
        if not o:write(c) then i:close(); o:close(); return false end
    end
    i:close()
    return o:close() and true or false
end

local function _writeFile(path, content)
    local o = io.open(path, "wb"); if not o then return false end
    local ok = o:write(content)
    local closed = o:close()
    return (ok and closed) and true or false
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------
local function _stageDir() return (_settingsDir() or "") .. "/xray_update_stage" end

local function _cleanupStage(lfs)
    local stage = _stageDir()
    if _mode(lfs, stage) ~= "directory" then return end
    -- Only our own flat entries (archive.zip and numbered files) live there.
    for f in lfs.dir(stage) do
        if f ~= "." and f ~= ".." then os.remove(stage .. "/" .. f) end
    end
    pcall(lfs.rmdir, stage)
end

local function _checkPaths(lfs)
    if not _plainDirChain(lfs, _plugin_dir) then
        return "plugin directory is not a plain directory"
    end
    local settings = _settingsDir()
    if not settings or not _plainDirChain(lfs, settings) then
        return "settings directory unavailable"
    end
end

-- Phase 1 (cancellable, may run in a subprocess): download, validate, and
-- stage verified plugin files. Touches nothing in the plugin directory.
local function _prepare(sha)
    local lfs = _lfs()
    if not lfs then return { success = false, err = "filesystem support unavailable" } end
    local perr = _checkPaths(lfs)
    if perr then return { success = false, err = perr } end
    local http = _http()
    if not http then return { success = false, err = "secure transport unavailable" } end

    local ok, status, body = http:requestPublic(ARCHIVE_URL .. sha, {
        ["User-Agent"] = "KOReader-XRay-Updater/2",
    }, 180)
    if not ok then return { success = false, stage = "download", err = tostring(status) } end
    if status ~= 200 then return { success = false, stage = "download", err = "HTTP " .. tostring(status) } end

    local entries, zerr = _inspectZip(body, sha)
    if not entries then return { success = false, err = zerr } end

    local stage = _stageDir()
    local function cleanupStage() _cleanupStage(lfs) end
    cleanupStage()
    if _mode(lfs, stage) ~= nil or not lfs.mkdir(stage) or _mode(lfs, stage) ~= "directory" then
        return { success = false, err = "cannot create staging directory" }
    end
    local zip_path = stage .. "/archive.zip"
    if not _writeFile(zip_path, body) then cleanupStage(); return { success = false, err = "cannot stage archive" } end
    body = nil

    for i, e in ipairs(entries) do
        e.staged = stage .. "/" .. i
        local xok, xerr = _extractEntry(zip_path, e, e.staged)
        if not xok then cleanupStage(); return { success = false, err = xerr } end
        if e.rel == "xray_updater.lua" then
            local fh = io.open(e.staged, "rb")
            local src = fh and fh:read("*a") or ""
            if fh then fh:close() end
            if not src:find(CAPABILITY, 1, true) then
                cleanupStage()
                return { success = false, unsupported = true, err = "unsupported" }
            end
        end
    end
    os.remove(zip_path)
    return { success = true, sha = sha, entries = entries }
end

-- Phase 2 (NOT cancellable; runs in the UI process): journaled swap.
local function _commit(prep)
    local lfs = _lfs()
    if not lfs then return { success = false, err = "filesystem support unavailable" } end
    local function cleanupStage() _cleanupStage(lfs) end
    local perr = _checkPaths(lfs)
    if perr then cleanupStage(); return { success = false, err = perr } end
    local plugin, sha, entries = _plugin_dir, prep.sha, prep.entries
    for _, e in ipairs(entries) do
        local vok = _verifyFile(e.staged, e)
        if not vok then cleanupStage(); return { success = false, err = "staged file changed" } end
    end

    -- Transaction: journal every rename so any failure (including the marker
    -- write) restores the previous plugin files exactly.
    local journal = {}
    -- Returns true only if every journaled change was reverted. On failure
    -- the remaining *.xray-bak files are left in place for manual recovery.
    local function rollback()
        local clean = true
        for i = #journal, 1, -1 do
            local j = journal[i]
            if j.placed then
                if j.backup then
                    if _mode(lfs, j.target) == "file" then os.remove(j.target) end
                    if not os.rename(j.backup, j.target) then clean = false end
                elseif not os.remove(j.target) then
                    clean = false
                end
            elseif j.backup then
                if not os.rename(j.backup, j.target) then clean = false end
            end
        end
        return clean
    end
    local function fail(msg)
        local clean = rollback()
        cleanupStage()
        if not clean then
            return { success = false, rollback_failed = true, err = msg }
        end
        return { success = false, err = msg }
    end
    local function place(target, src_path, content, entry_meta)
        local tmode = _mode(lfs, target)
        if tmode ~= nil and tmode ~= "file" then return false end
        local new, bak = target .. ".xray-new", target .. ".xray-bak"
        for _, side in ipairs({ new, bak }) do
            local m = _mode(lfs, side)
            if m == "file" then os.remove(side) elseif m ~= nil then return false end
        end
        local wrote = src_path and _copyFile(src_path, new) or (content and _writeFile(new, content))
        if not wrote or (entry_meta and not _verifyFile(new, entry_meta)) then
            os.remove(new); return false
        end
        local entry = { target = target }
        if tmode == "file" then
            if not os.rename(target, bak) then os.remove(new); return false end
            entry.backup = bak
        end
        journal[#journal + 1] = entry
        if not os.rename(new, target) then os.remove(new); return false end
        entry.placed = true
        return true
    end
    local function ensureDirs(rel)
        local path = plugin
        local dirs = {}
        for seg in rel:gmatch("([^/]+)/") do dirs[#dirs + 1] = seg end
        for _, seg in ipairs(dirs) do
            path = path .. "/" .. seg
            local m = _mode(lfs, path)
            if m == nil then
                if not lfs.mkdir(path) or _mode(lfs, path) ~= "directory" then return false end
            elseif m ~= "directory" then
                return false
            end
        end
        return true
    end

    -- Retire the old marker first, so an interrupted swap (power loss) reads
    -- as "unknown", never as the previous commit.
    local marker = _markerPath()
    local mmode = _mode(lfs, marker)
    if mmode ~= nil then
        if mmode ~= "file" then cleanupStage(); return { success = false, err = "unexpected marker type" } end
        local mbak = marker .. ".xray-bak"
        if _mode(lfs, mbak) == "file" then os.remove(mbak) end
        if _mode(lfs, mbak) ~= nil or not os.rename(marker, mbak) then
            cleanupStage(); return { success = false, err = "could not retire installed commit" }
        end
        journal[#journal + 1] = { target = marker, backup = mbak, placed = false }
    end
    for _, e in ipairs(entries) do
        local target = plugin .. "/" .. e.rel
        local skip = PRESERVE[e.rel] and _mode(lfs, target) ~= nil
        if not skip then
            if not ensureDirs(e.rel) or not place(target, e.staged, nil, e) then
                return fail("could not install " .. e.rel)
            end
        end
    end
    if not place(marker, nil, "source=" .. SOURCE_ID .. "\ncommit=" .. sha .. "\n") then
        return fail("could not record installed commit")
    end
    -- The old marker backup is dropped too: the new marker is authoritative.
    for _, j in ipairs(journal) do if j.backup then os.remove(j.backup) end end
    cleanupStage()
    return { success = true }
end

-- ---------------------------------------------------------------------------
-- UI flow
-- ---------------------------------------------------------------------------
local function _runTask(fn, msg, on_result, cancelled_key, on_cancel)
    local ok_tr, Trapper = pcall(require, "ui/trapper")
    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(fn, msg)
        if completed then
            UIManager:scheduleIn(0.2, function() on_result(result) end)
        else
            _closeWidget(msg)
            if on_cancel then pcall(on_cancel) end
            _toast(t(cancelled_key))
        end
    else
        UIManager:scheduleIn(0.3, function() on_result(fn()) end)
    end
end

local function _applyUpdate(sha)
    local progress = _toast(t("updater_downloading", _short(sha)), 180)
    _runTask(function() return _prepare(sha) end, progress, function(prep)
        _closeWidget(progress)
        local result = prep
        if type(prep) == "table" and prep.success then
            -- Short, non-dismissable swap in this process; the user cannot
            -- cancel between moving old files aside and restoring them.
            result = _commit(prep)
        end
        if type(result) ~= "table" or not result.success then
            local err = type(result) == "table" and result.err or "unknown error"
            logger.err("xray updater: install failed:", err)
            if type(result) == "table" and result.rollback_failed then
                _toast(t("updater_err_rollback", tostring(err)), 15)
            elseif type(result) == "table" and result.unsupported then
                _toast(t("updater_err_unsupported"), 8)
            elseif type(result) == "table" and result.stage == "download" then
                _toast(t("updater_err_download", tostring(err)))
            else
                _toast(t("updater_err_extract", tostring(err)))
            end
            return
        end
        local ButtonDialog = require("ui/widget/buttondialog")
        local dlg
        dlg = ButtonDialog:new{
            title = t("updater_success_restart", _short(sha)),
            buttons = {{
                { text = t("updater_btn_later"), callback = function() UIManager:close(dlg) end },
                { text = t("updater_btn_restart"), is_enter_default = true, callback = function()
                    UIManager:close(dlg)
                    UIManager:restartKOReader()
                end },
            }},
        }
        UIManager:show(dlg)
    end, "updater_cancelled_update", function()
        local lfs = _lfs()
        if lfs then _cleanupStage(lfs) end
    end)
end

-- quiet: weekly background check; only speaks when a newer build exists.
local function _showResult(latest, installed, quiet)
    if installed == latest then
        if not quiet then _toast(t("updater_status_current", _short(latest))) end
        return
    end
    local text = installed
        and t("updater_status_available", _short(installed), _short(latest))
        or t("updater_status_unknown", _short(latest))
    text = text .. "\n" .. t("updater_source_line", OWNER .. "/" .. REPO .. " (" .. BRANCH .. ")")
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    dlg = ButtonDialog:new{
        title = text,
        buttons = {{
            { text = t("updater_btn_cancel"), callback = function() UIManager:close(dlg) end },
            { text = t("updater_btn_download"), is_enter_default = true, callback = function()
                UIManager:close(dlg)
                _applyUpdate(latest)
            end },
        }},
    }
    UIManager:show(dlg)
end

local function _check(quiet)
    local installed = _installedCommit()
    if quiet then
        local latest = _fetchHead()
        if latest and latest ~= installed and installed then _showResult(latest, installed, true) end
        return
    end
    local msg = _toast(t("updater_checking"), 30)
    _runTask(function()
        local sha, err = _fetchHead()
        return { sha = sha, err = err }
    end, msg, function(res)
        _closeWidget(msg)
        if type(res) ~= "table" or not res.sha then
            local err = type(res) == "table" and res.err or "unknown error"
            logger.err("xray updater: check failed:", err)
            _toast(t("updater_error_checking_detail", tostring(err)))
            return
        end
        _showResult(res.sha, installed, false)
    end, "updater_cancelled_check")
end

-- The second argument (legacy release channel) is ignored: the fork updater
-- always follows OWNER/REPO@BRANCH.
function M.checkForUpdates(loc)
    M.loc = loc
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(function() _check(false) end)
        return
    end
    _check(false)
end

-- Weekly background check: prompts only, never installs on its own. With an
-- unknown installed build it stays silent (use Check for Updates manually).
function M.checkSilentForUpdates(loc)
    M.loc = loc
    _check(true)
end

return M
