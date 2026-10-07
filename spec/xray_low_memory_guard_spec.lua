-- spec/xray_low_memory_guard_spec.lua
-- Unit tests for Low-Memory Detection and Safety Guards
require("spec.spec_helper")
local utils = require("xray_utils")

describe("Low-Memory Detection & Guards", function()
    it("parses modern Linux /proc/meminfo with MemAvailable", function()
        local tmp = "/tmp/test_meminfo_modern.txt"
        local f = io.open(tmp, "w")
        assert.is_not_nil(f)
        f:write([[
MemTotal:         512000 kB
MemFree:           10240 kB
MemAvailable:      45000 kB
Buffers:            4096 kB
Cached:            30000 kB
]])
        f:close()

        local mem = utils:getMemoryInfo(tmp)
        assert.is_not_nil(mem)
        assert.are.equal(512000, mem.total_kb)
        assert.are.equal(45000, mem.available_kb)
        assert.are.equal(10240, mem.free_kb)

        local is_low, avail = utils:isLowMemory(30 * 1024, tmp)
        assert.is_false(is_low)
        assert.are.equal(45000, avail)

        local is_low_strict = utils:isLowMemory(50 * 1024, tmp)
        assert.is_true(is_low_strict)

        os.remove(tmp)
    end)

    it("calculates fallback available memory on legacy Kindle Linux 3.0 kernels", function()
        local tmp = "/tmp/test_meminfo_kindle.txt"
        local f = io.open(tmp, "w")
        assert.is_not_nil(f)
        f:write([[
MemTotal:         247852 kB
MemFree:            3584 kB
Buffers:            1024 kB
Cached:            12288 kB
SwapTotal:             0 kB
SwapFree:              0 kB
]])
        f:close()

        local mem = utils:getMemoryInfo(tmp)
        assert.is_not_nil(mem)
        assert.are.equal(247852, mem.total_kb)
        -- Fallback: 3584 + floor(0.5 * (1024 + 12288)) = 3584 + 6656 = 10240 kB (~10 MB)
        assert.are.equal(10240, mem.available_kb)

        local is_low, avail, total = utils:isLowMemory(30 * 1024, tmp)
        assert.is_true(is_low)
        assert.are.equal(10240, avail)
        assert.are.equal(247852, total)

        os.remove(tmp)
    end)

    it("subtracts non-evictable Shmem from Cached on legacy Kindle kernels", function()
        local tmp = "/tmp/test_meminfo_kindle_shmem.txt"
        local f = io.open(tmp, "w")
        assert.is_not_nil(f)
        f:write([[
MemTotal:         496000 kB
MemFree:            8192 kB
Buffers:            2048 kB
Cached:            60000 kB
Shmem:             40000 kB
SwapTotal:             0 kB
SwapFree:              0 kB
]])
        f:close()

        local mem = utils:getMemoryInfo(tmp)
        assert.is_not_nil(mem)
        -- Reclaimable cache = 60000 - 40000 = 20000 kB
        -- Available = 8192 + floor(0.5 * (2048 + 20000)) = 8192 + 11024 = 19216 kB
        assert.are.equal(19216, mem.available_kb)

        -- Threshold 35 MB triggers low memory because true available is ~19 MB (not naive 70 MB)
        local is_low, avail = utils:isLowMemory(35 * 1024, tmp)
        assert.is_true(is_low)
        assert.are.equal(19216, avail)

        os.remove(tmp)
    end)

    it("uses 65MB default safety threshold on Kindle devices when no threshold is specified", function()
        local Device = require("device")
        local orig_isKindle = Device.isKindle
        Device.isKindle = function() return true end

        local tmp = "/tmp/test_meminfo_kindle_default.txt"
        local f = io.open(tmp, "w")
        assert.is_not_nil(f)
        f:write([[
MemTotal:         496000 kB
MemFree:           10240 kB
MemAvailable:      50000 kB
]])
        f:close()

        -- Without explicit threshold, Kindle default is 65MB, so 50MB available is considered low
        local is_low, avail = utils:isLowMemory(nil, tmp)
        assert.is_true(is_low)
        assert.are.equal(50000, avail)

        Device.isKindle = orig_isKindle
        os.remove(tmp)
    end)

    it("handles non-existent meminfo paths gracefully", function()
        local mem = utils:getMemoryInfo("/nonexistent_path_to_meminfo")
        assert.is_nil(mem)

        local is_low, avail = utils:isLowMemory(30 * 1024, "/nonexistent_path_to_meminfo")
        assert.is_false(is_low)
        assert.is_nil(avail)
    end)
end)
