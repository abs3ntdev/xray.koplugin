-- Keep CI progress visible even when stdout is redirected.
io.stdout:setvbuf("no")

-- Capture the standard assert before it is replaced below.
local lua_assert = assert
local squashfs_root = os.getenv("SQUASHFS_ROOT") or "/home/jimmy/squashfs-root"
package.path = package.path .. ";" .. squashfs_root .. "/usr/lib/koreader/common/?.lua;" .. squashfs_root .. "/usr/lib/koreader/?.lua;xray.koplugin/?.lua;?.lua"

local stats = { passed = 0, failed = 0, errors = {} }
local contexts = {} -- stack of { name, before_each, after_each, teardown, setup_failed }
local filter = nil

local function record_failure(name, err)
    stats.failed = stats.failed + 1
    table.insert(stats.errors, { name = name, err = err })
    print("[FAIL] " .. name)
    print("       " .. tostring(err))
end

local function context_name(extra)
    local parts = {}
    for _, c in ipairs(contexts) do parts[#parts + 1] = c.name end
    if extra then parts[#parts + 1] = extra end
    return table.concat(parts, " -> ")
end

local function current()
    local c = contexts[#contexts]
    if not c then error("hook registered outside describe", 3) end
    return c
end

_G.before_each = function(fn) table.insert(current().before_each, fn) end
_G.after_each = function(fn) table.insert(current().after_each, fn) end

-- setup runs immediately (tests run inline as they are declared);
-- a failure marks the block so later tests fail closed instead of running.
_G.setup = function(fn)
    local c = current()
    local ok, err = pcall(fn)
    if not ok then
        c.setup_failed = err
        record_failure(context_name("setup"), err)
    end
end

-- teardown is deferred until the enclosing describe finishes.
_G.teardown = function(fn) table.insert(current().teardown, fn) end

_G.describe = function(name, fn)
    table.insert(contexts, { name = name, before_each = {}, after_each = {}, teardown = {} })
    local ok, err = pcall(fn)
    if not ok then record_failure(context_name("describe"), err) end
    local c = contexts[#contexts]
    for _, td in ipairs(c.teardown) do
        local tok, terr = pcall(td)
        if not tok then record_failure(context_name("teardown"), terr) end
    end
    table.remove(contexts)
end

_G.it = function(name, fn)
    local full_name = context_name(name)
    if filter and not full_name:find(filter, 1, true) then return end
    if os.getenv("SPEC_VERBOSE") then print("[RUN ] " .. full_name) end

    local err
    for _, c in ipairs(contexts) do
        if c.setup_failed then err = "setup failed: " .. tostring(c.setup_failed) break end
    end

    if not err then
        for _, c in ipairs(contexts) do
            for _, before_fn in ipairs(c.before_each) do
                local ok, e = pcall(before_fn)
                if not ok then err = "before_each: " .. tostring(e) break end
            end
            if err then break end
        end
    end

    if not err then
        local ok, e = pcall(fn)
        if not ok then err = e end
    end

    -- after_each always runs (innermost first) and its errors are reported.
    for i = #contexts, 1, -1 do
        for _, after_fn in ipairs(contexts[i].after_each) do
            local ok, e = pcall(after_fn)
            if not ok and not err then err = "after_each: " .. tostring(e) end
        end
    end

    if err then
        record_failure(full_name, err)
    else
        stats.passed = stats.passed + 1
        if os.getenv("SPEC_VERBOSE") then print("[ OK ] " .. full_name) end
    end
end

local function deep_compare(t1, t2)
    if type(t1) ~= type(t2) then return false end
    if type(t1) ~= "table" then return t1 == t2 end
    for k, v in pairs(t1) do
        if not deep_compare(v, t2[k]) then return false end
    end
    for k, v in pairs(t2) do
        if not deep_compare(v, t1[k]) then return false end
    end
    return true
end

_G.assert = {
    is_true = function(val)
        if not val then error("Expected true, got " .. tostring(val), 2) end
    end,
    is_false = function(val)
        if val then error("Expected false, got " .. tostring(val), 2) end
    end,
    is_nil = function(val)
        if val ~= nil then error("Expected nil, got " .. tostring(val), 2) end
    end,
    is_not_nil = function(val)
        if val == nil then error("Expected not nil", 2) end
    end,
    is_table = function(val)
        if type(val) ~= "table" then error("Expected table, got " .. type(val), 2) end
    end,
    is_string = function(val)
        if type(val) ~= "string" then error("Expected string, got " .. type(val), 2) end
    end,
    is_number = function(val)
        if type(val) ~= "number" then error("Expected number, got " .. type(val), 2) end
    end,
    is_boolean = function(val)
        if type(val) ~= "boolean" then error("Expected boolean, got " .. type(val), 2) end
    end,
    truthy = function(val)
        if not val then error("Expected truthy, got " .. tostring(val), 2) end
    end,
    falsy = function(val)
        if val then error("Expected falsy, got " .. tostring(val), 2) end
    end,
    are = {
        equal = function(expected, actual)
            if expected ~= actual then
                error("Expected " .. tostring(expected) .. ", got " .. tostring(actual), 3)
            end
        end,
        same = function(expected, actual)
            if not deep_compare(expected, actual) then
                error("Expected identical values/tables", 3)
            end
        end
    },
    are_not = {
        equal = function(expected, actual)
            if expected == actual then
                error("Expected not equal to " .. tostring(expected), 3)
            end
        end
    }
}
-- Keep the standard assert callable: real modules call assert(v, msg).
setmetatable(_G.assert, { __call = function(_, ...) return lua_assert(...) end })
_G.assert.equals = _G.assert.are.equal
_G.assert.same = _G.assert.are.same
_G.assert.is_falsy = _G.assert.falsy
_G.assert.is_truthy = _G.assert.truthy

-- Deterministic dynamic discovery of spec/*_spec.lua.
local function discover_specs()
    local found = {}
    local ok_lfs, lfs = pcall(require, "lfs")
    if ok_lfs and lfs and lfs.dir then
        for f in lfs.dir("spec") do
            if f:match("_spec%.lua$") then found[#found + 1] = "spec/" .. f end
        end
    else
        local p = io.popen('ls -1 spec 2>/dev/null')
        if p then
            for f in p:lines() do
                if f:match("_spec%.lua$") then found[#found + 1] = "spec/" .. f end
            end
            p:close()
        end
    end
    table.sort(found)
    return found
end

-- Usage: spec_runner.lua [--filter TEXT] [spec files...]
local specs = {}
local args = arg or {}
local i = 1
while i <= #args do
    if args[i] == "--filter" then
        filter = args[i + 1]
        i = i + 2
    else
        specs[#specs + 1] = args[i]
        i = i + 1
    end
end
if #specs == 0 then specs = discover_specs() end
if #specs == 0 then
    print("No spec files found (run from repository root)")
    os.exit(1)
end

print("=== Running KOReader X-Ray Unit Tests ===")
for _, spec_path in ipairs(specs) do
    print("Loading " .. spec_path .. "...")
    -- Isolate module state per spec file so mocks do not leak forward.
    local loaded_snapshot = {}
    for k, v in pairs(package.loaded) do loaded_snapshot[k] = v end
    local fn, err = loadfile(spec_path)
    if fn then
        local ok, run_err = pcall(fn)
        if not ok then record_failure(spec_path .. " (top level)", run_err) end
        contexts = {}
    else
        record_failure(spec_path .. " (load)", err)
    end
    for k in pairs(package.loaded) do
        if loaded_snapshot[k] == nil then package.loaded[k] = nil end
    end
    for k, v in pairs(loaded_snapshot) do package.loaded[k] = v end
end

print("\n=== Test Results ===")
print("Passed: " .. stats.passed)
print("Failed: " .. stats.failed)

if stats.failed > 0 then
    print("\nFailures:")
    for _, item in ipairs(stats.errors) do
        print("  - " .. item.name .. "\n    " .. tostring(item.err))
    end
    os.exit(1)
else
    print("\nAll tests passed successfully!")
    os.exit(0)
end
