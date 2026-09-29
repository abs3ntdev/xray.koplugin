-- xray_updater_spec.lua
-- Drives the public updater entry points (checkForUpdates, the update dialog
-- buttons, checkSilentForUpdates) against a scratch plugin directory reached
-- through a RELATIVE path, with real ZIP archives built by the host `zip` and
-- extracted by the host `unzip`. Only the network (SecureHTTP.requestPublic)
-- and KOReader's lfs/Trapper/DataStorage bindings are substituted.
require("spec/spec_helper")

local SHA_A = string.rep("a", 40)
local SHA_B = string.rep("b", 40)
local SOURCE = "github:abs3ntdev/xray.koplugin@openai-subscription"
local BASE = "scratch/updater_spec"           -- relative on purpose (gitignored)
local PLUGIN = BASE .. "/plugins/xray.koplugin"
local SETTINGS = BASE .. "/settings"
local BUILD = BASE .. "/build"

local function sh(cmd) local r = os.execute(cmd); return r == 0 or r == true end
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function write(path, content)
    sh("mkdir -p " .. q(path:match("^(.*)/[^/]+$")))
    local f = assert(io.open(path, "wb")); f:write(content); f:close()
end
local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end
local function exists(path) return sh("test -e " .. q(path) .. " -o -L " .. q(path)) end

local updater_source = read("xray.koplugin/xray_updater.lua")

-- Builds codeload-shaped archive bytes: xray.koplugin-<sha>/{README.md,xray.koplugin/...}
local function archive(sha, opts)
    opts = opts or {}
    local root = "xray.koplugin-" .. sha
    sh("rm -rf " .. q(BUILD) .. " && mkdir -p " .. q(BUILD))
    local files = {
        ["README.md"] = "repo readme, outside the plugin",
        ["spec/x_spec.lua"] = "-- repo spec, outside the plugin",
        ["xray.koplugin/main.lua"] = "-- main " .. sha,
        ["xray.koplugin/_meta.lua"] = "return {}",
        ["xray.koplugin/xray_config.lua"] = "return { shipped_default = true }",
        ["xray.koplugin/prompts/en.lua"] = "-- prompts " .. sha,
        ["xray.koplugin/xray_updater.lua"] = opts.updater or updater_source,
    }
    for name, content in pairs(opts.extra or {}) do files[name] = content end
    for name, content in pairs(files) do write(BUILD .. "/" .. root .. "/" .. name, content) end
    if opts.prepare then opts.prepare(BUILD .. "/" .. root) end
    assert(sh("cd " .. q(BUILD) .. " && zip -q -r -y -X out.zip " .. q(root)))
    local bytes = read(BUILD .. "/out.zip")
    if opts.mutate then bytes = opts.mutate(bytes) end
    return bytes
end

describe("xray_updater (fork branch)", function()
    local updater, net, saved, UIManager

    local function install_mocks()
        saved = {
            http = package.loaded["xray_secure_http"], ds = package.loaded["datastorage"],
            lfs = package.loaded["libs/libkoreader-lfs"], trapper = package.loaded["ui/trapper"],
        }
        package.loaded["xray_secure_http"] = {
            requestPublic = function(_, url, headers)
                net.calls[#net.calls + 1] = { url = url, headers = headers }
                if net.fail then return nil, "network_error" end
                if url:find("^https://api%.github%.com/") then return true, 200, net.head .. "\n", {} end
                if url == "https://codeload.github.com/abs3ntdev/xray.koplugin/zip/" .. net.head then
                    return true, 200, net.zip, {}
                end
                return true, 404, "", {}
            end,
        }
        package.loaded["datastorage"] = { getSettingsDir = function() return SETTINGS end }
        -- Real filesystem answers for the lfs calls the installer makes.
        package.loaded["libs/libkoreader-lfs"] = {
            symlinkattributes = function(p)
                if sh("test -L " .. q(p)) then return { mode = "link" } end
                if sh("test -d " .. q(p)) then return { mode = "directory" } end
                if sh("test -f " .. q(p)) then return { mode = "file" } end
            end,
            mkdir = function(p) return sh("mkdir " .. q(p)) end,
            rmdir = function(p) return sh("rmdir " .. q(p) .. " 2>/dev/null") end,
            dir = function(p)
                local h = io.popen("ls -a1 " .. q(p)); local lines = {}
                for l in h:lines() do lines[#lines + 1] = l end
                h:close(); local i = 0
                return function() i = i + 1; return lines[i] end
            end,
        }
        -- KOReader signature: (task, trap_widget) -> completed, result
        package.loaded["ui/trapper"] = {
            dismissableRunInSubprocess = function(_, task) return true, task() end,
        }
    end

    before_each(function()
        UIManager = require("ui/uimanager")
        UIManager.restartKOReader = function() end
        _G.ui_tracker.shown = {}
        sh("rm -rf " .. q(BASE) .. " && mkdir -p " .. q(PLUGIN) .. " " .. q(SETTINGS))
        write(PLUGIN .. "/xray_updater.lua", updater_source)
        write(PLUGIN .. "/main.lua", "-- old main")
        write(PLUGIN .. "/xray_config.lua", "return { gemini_api_key = 'SENTINEL-KEY' }")
        write(PLUGIN .. "/user_notes.txt", "user data")
        net = { head = SHA_A, calls = {} }
        install_mocks()
        updater = dofile(PLUGIN .. "/xray_updater.lua")
    end)

    after_each(function()
        package.loaded["xray_secure_http"] = saved.http
        package.loaded["datastorage"] = saved.ds
        package.loaded["libs/libkoreader-lfs"] = saved.lfs
        package.loaded["ui/trapper"] = saved.trapper
        sh("rm -rf " .. q(BASE))
    end)

    local function last() return _G.ui_tracker.shown[#_G.ui_tracker.shown] end
    local function text(w) return w.title or (w.args and w.args.text) or "" end
    local function press_install()
        local dlg = last()
        assert.are.equal("ButtonDialog", dlg.type)
        dlg.buttons[1][2].callback()
    end
    local function unchanged()
        assert.are.equal("-- old main", read(PLUGIN .. "/main.lua"))
        assert.is_false(exists(PLUGIN .. "/.xray_fork_commit"))
        assert.is_false(exists(PLUGIN .. "/prompts"))
        assert.is_false(exists(SETTINGS .. "/xray_update_stage"))
    end

    it("installs the exact branch head plugin subtree and then reports up to date", function()
        net.zip = archive(SHA_A)
        updater.checkForUpdates(nil)
        local prompt = text(last())
        assert.truthy(prompt:find("unknown", 1, true))
        assert.truthy(prompt:find("abs3ntdev/xray.koplugin (openai-subscription)", 1, true))
        press_install()

        assert.are.equal("-- main " .. SHA_A, read(PLUGIN .. "/main.lua"))
        assert.are.equal("-- prompts " .. SHA_A, read(PLUGIN .. "/prompts/en.lua"))
        assert.are.equal("return { gemini_api_key = 'SENTINEL-KEY' }", read(PLUGIN .. "/xray_config.lua"))
        assert.are.equal("user data", read(PLUGIN .. "/user_notes.txt"))
        assert.is_false(exists(PLUGIN .. "/README.md"))
        assert.is_false(exists(PLUGIN .. "/main.lua.xray-bak"))
        assert.is_false(exists(SETTINGS .. "/xray_update_stage"))
        assert.are.equal("source=" .. SOURCE .. "\ncommit=" .. SHA_A .. "\n", read(PLUGIN .. "/.xray_fork_commit"))
        assert.are.equal("https://codeload.github.com/abs3ntdev/xray.koplugin/zip/" .. SHA_A, net.calls[2].url)
        for _, c in ipairs(net.calls) do
            for k in pairs(c.headers) do assert.are_not.equal("authorization", k:lower()) end
        end

        updater = dofile(PLUGIN .. "/xray_updater.lua")
        updater.checkForUpdates(nil)
        assert.are.equal("InfoMessage", last().type)
        assert.truthy(text(last()):find("up to date", 1, true))

        -- A newer head is offered with both commits named.
        net.head = SHA_B
        updater.checkForUpdates(nil)
        assert.truthy(text(last()):find("aaaaaaa", 1, true))
        assert.truthy(text(last()):find("bbbbbbb", 1, true))
    end)

    it("installs a GitHub-style archive with MS-DOS entry attributes", function()
        -- codeload.github.com writes host=0 (FAT) attributes; rewrite ours so.
        net.zip = archive(SHA_A, { mutate = function(b)
            local out, i = {}, 1
            while true do
                local j = b:find("PK\1\2", i, true)
                if not j then break end
                local nlen = b:byte(j + 28) + b:byte(j + 29) * 256
                local is_dir = b:sub(j + 45 + nlen, j + 45 + nlen) == "/"
                out[#out + 1] = b:sub(i, j + 4) .. "\0"                    -- version made by: host 0
                out[#out + 1] = b:sub(j + 6, j + 37)
                out[#out + 1] = (is_dir and "\16" or "\0") .. "\0\0\0"     -- external attributes
                i = j + 42
            end
            out[#out + 1] = b:sub(i)
            return table.concat(out)
        end })
        updater.checkForUpdates(nil)
        press_install()
        assert.are.equal("-- main " .. SHA_A, read(PLUGIN .. "/main.lua"))
        assert.are.equal("return { gemini_api_key = 'SENTINEL-KEY' }", read(PLUGIN .. "/xray_config.lua"))
        assert.truthy(read(PLUGIN .. "/.xray_fork_commit"))
    end)

    it("treats a marker from another source as unknown, never up to date", function()
        write(PLUGIN .. "/.xray_fork_commit", "source=github:ultimatejimmy/xray.koplugin@main\ncommit=" .. SHA_A .. "\n")
        updater.checkForUpdates(nil)
        assert.are.equal("ButtonDialog", last().type)
        assert.truthy(text(last()):find("unknown", 1, true))
    end)

    it("reports a failed check truthfully and changes nothing", function()
        net.fail = true
        updater.checkForUpdates(nil)
        assert.are.equal("InfoMessage", last().type)
        assert.truthy(text(last()):find("network_error", 1, true))
        unchanged()
    end)

    it("weekly check prompts only for a known older build and never installs", function()
        updater.checkSilentForUpdates(nil)          -- unknown installed build: silent
        assert.are.equal(0, #_G.ui_tracker.shown)
        write(PLUGIN .. "/.xray_fork_commit", "source=" .. SOURCE .. "\ncommit=" .. SHA_B .. "\n")
        updater.checkSilentForUpdates(nil)
        assert.are.equal("ButtonDialog", last().type)
        for _, c in ipairs(net.calls) do            -- metadata only, no archive download
            assert.truthy(c.url:find("^https://api%.github%.com/"))
        end
        assert.are.equal("-- old main", read(PLUGIN .. "/main.lua"))
    end)

    it("refuses a published build without the fork updater capability", function()
        net.zip = archive(SHA_A, { updater = "-- legacy release updater" })
        updater.checkForUpdates(nil)
        press_install()
        assert.truthy(text(last()):find("does not support the fork updater", 1, true))
        unchanged()
    end)

    -- Each archive is unsafe somewhere; none may touch the plugin directory.
    local unsafe = {
        { "symlink entry outside the plugin subtree", { prepare = function(root)
            sh("ln -s /etc/passwd " .. q(root .. "/docs_link"))
        end }, "non-regular archive entry" },
        { "symlink entry inside the plugin subtree", { prepare = function(root)
            sh("ln -s ../../../etc " .. q(root .. "/xray.koplugin/evil"))
        end }, "non-regular archive entry" },
        { "parent-directory traversal", { extra = { ["xray.koplugin/zz/x.lua"] = "x" },
            mutate = function(b) return (b:gsub("/zz/", "/../")) end }, "unsafe archive path" },
        { "glob and shell metacharacters in a name", { extra = { ["xray.koplugin/a*b$(x).lua"] = "x" } }, "unsafe archive path" },
        { "an unexpected archive root", { mutate = function(b)
            return (b:gsub("xray%.koplugin%-" .. SHA_A, "xray.koplugin-" .. SHA_B))
        end }, "unexpected archive root" },
        { "extracted bytes that do not match the declared CRC", { mutate = function(b)
            -- corrupt main.lua CRC in the central directory only
            local name = "xray.koplugin-" .. SHA_A .. "/xray.koplugin/main.lua"
            local i = b:find("PK\1\2", 1, true)
            while i do
                if b:sub(i + 46, i + 45 + #name) == name then
                    return b:sub(1, i + 15) .. "\0\0\0\0" .. b:sub(i + 20)
                end
                i = b:find("PK\1\2", i + 1, true)
            end
            error("entry not found")
        end }, "extracted data mismatch" },
    }
    for _, case in ipairs(unsafe) do
        it("rejects an archive with " .. case[1] .. " before touching the plugin", function()
            net.zip = archive(SHA_A, case[2])
            updater.checkForUpdates(nil)
            press_install()
            assert.truthy(text(last()):find(case[3], 1, true))
            unchanged()
        end)
    end

    it("rolls back every replaced file when a later file cannot be placed", function()
        write(PLUGIN .. "/_meta.lua", "-- old meta")
        local old_marker = "source=" .. SOURCE .. "\ncommit=" .. SHA_B .. "\n"
        write(PLUGIN .. "/.xray_fork_commit", old_marker)
        sh("mkdir -p " .. q(PLUGIN .. "/prompts/en.lua"))   -- directory where a file must go
        net.zip = archive(SHA_A)
        updater.checkForUpdates(nil)
        press_install()
        assert.truthy(text(last()):find("could not install", 1, true))
        assert.truthy(text(last()):find("previous version was kept", 1, true))
        assert.are.equal("-- old main", read(PLUGIN .. "/main.lua"))
        assert.are.equal("-- old meta", read(PLUGIN .. "/_meta.lua"))
        assert.are.equal(updater_source, read(PLUGIN .. "/xray_updater.lua"))
        assert.are.equal("return { gemini_api_key = 'SENTINEL-KEY' }", read(PLUGIN .. "/xray_config.lua"))
        assert.are.equal(old_marker, read(PLUGIN .. "/.xray_fork_commit"))
        assert.is_false(exists(PLUGIN .. "/main.lua.xray-bak"))
        assert.is_false(exists(PLUGIN .. "/.xray_fork_commit.xray-bak"))
    end)

    it("refuses to install through a symlinked plugin directory", function()
        sh("mv " .. q(PLUGIN) .. " " .. q(BASE .. "/real") .. " && ln -s ../real " .. q(PLUGIN))
        net.zip = archive(SHA_A)
        updater.checkForUpdates(nil)
        press_install()
        assert.truthy(text(last()):find("not a plain directory", 1, true))
        assert.are.equal("-- old main", read(BASE .. "/real/main.lua"))
    end)

    it("refuses to install below a symlinked grandparent directory", function()
        -- <BASE>/link -> real ; plugin loaded as <BASE>/link/plugins/xray.koplugin
        sh("mkdir -p " .. q(BASE .. "/real") .. " && mv " .. q(BASE .. "/plugins") .. " "
            .. q(BASE .. "/real/plugins") .. " && ln -s real " .. q(BASE .. "/link"))
        updater = dofile(BASE .. "/link/plugins/xray.koplugin/xray_updater.lua")
        net.zip = archive(SHA_A)
        updater.checkForUpdates(nil)
        press_install()
        assert.truthy(text(last()):find("not a plain directory", 1, true))
        assert.are.equal("-- old main", read(BASE .. "/real/plugins/xray.koplugin/main.lua"))
    end)

    it("keeps the dismissable phase read-only and leaves files alone when cancelled", function()
        net.zip = archive(SHA_A)
        updater.checkForUpdates(nil)
        local during
        package.loaded["ui/trapper"] = {
            dismissableRunInSubprocess = function(_, task)
                task()                       -- the work a user may kill at any point
                during = read(PLUGIN .. "/main.lua")
                return false                 -- user dismissed
            end,
        }
        press_install()
        assert.are.equal("-- old main", during)
        assert.truthy(text(last()):find("cancelled", 1, true))
        unchanged()
    end)

    it("does not install a staged file that differs from the archive", function()
        net.zip = archive(SHA_A)
        updater.checkForUpdates(nil)
        -- Download/stage runs, then the staged copy is truncated (e.g. disk
        -- full) before the swap; the swap must refuse it.
        package.loaded["ui/trapper"] = {
            dismissableRunInSubprocess = function(_, task)
                local res = task()
                local f = io.open(SETTINGS .. "/xray_update_stage/1", "wb"); f:close()
                return true, res
            end,
        }
        press_install()
        assert.truthy(text(last()):find("staged file changed", 1, true))
        unchanged()
    end)

    it("restores the previous marker when only the final marker write fails", function()
        local old_marker = "source=" .. SOURCE .. "\ncommit=" .. SHA_B .. "\n"
        write(PLUGIN .. "/.xray_fork_commit", old_marker)
        net.zip = archive(SHA_A)
        updater.checkForUpdates(nil)
        -- Fault injection: the final rename of the NEW marker into place fails
        -- (e.g. I/O error). Every other rename is real.
        local real_rename = os.rename
        os.rename = function(from, to)
            if from == PLUGIN .. "/.xray_fork_commit.xray-new" then return nil, "injected" end
            return real_rename(from, to)
        end
        local ok, err = pcall(press_install)
        os.rename = real_rename
        assert(ok, err)
        assert.truthy(text(last()):find("could not record installed commit", 1, true))
        assert.truthy(text(last()):find("previous version was kept", 1, true))
        assert.are.equal(old_marker, read(PLUGIN .. "/.xray_fork_commit"))
        assert.are.equal("-- old main", read(PLUGIN .. "/main.lua"))
        assert.is_false(exists(PLUGIN .. "/.xray_fork_commit.xray-old"))
    end)

    it("leaves the build unknown when restoring a replaced file fails", function()
        local old_marker = "source=" .. SOURCE .. "\ncommit=" .. SHA_B .. "\n"
        write(PLUGIN .. "/.xray_fork_commit", old_marker)
        net.zip = archive(SHA_A)
        updater.checkForUpdates(nil)
        local real_rename = os.rename
        os.rename = function(from, to)
            if from == PLUGIN .. "/.xray_fork_commit.xray-new" then return nil, "injected" end
            if from == PLUGIN .. "/main.lua.xray-bak" then return nil, "injected" end  -- restore fails
            return real_rename(from, to)
        end
        local ok, err = pcall(press_install)
        os.rename = real_rename
        assert(ok, err)
        assert.truthy(text(last()):find("Restoring the previous version failed", 1, true))
        assert.is_false(exists(PLUGIN .. "/.xray_fork_commit"))              -- unknown, not SHA_B
        assert.are.equal(old_marker, read(PLUGIN .. "/.xray_fork_commit.xray-old"))
        assert.are.equal("-- old main", read(PLUGIN .. "/main.lua.xray-bak")) -- kept for recovery
    end)
end)
