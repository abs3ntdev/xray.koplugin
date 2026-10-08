-- tools/benchmark_memory.lua
-- Memory benchmark runner for KOReader X-Ray
local squashfs_root = os.getenv("SQUASHFS_ROOT") or "/home/jimmy/squashfs-root"
package.path = package.path .. ";" .. squashfs_root .. "/usr/lib/koreader/common/?.lua;" .. squashfs_root .. "/usr/lib/koreader/?.lua;xray.koplugin/?.lua;spec/?.lua;?.lua"

require("spec_helper")

local json = require("json")
local utils = require("xray_utils")
local AIHelper = require("xray_aihelper")
local xray_unitscanner = require("xray_unitscanner")
local xray_units = require("xray_units")

local function getProcessMemory()
    local f = io.open("/proc/self/status", "r")
    if not f then return nil end
    local res = {}
    for line in f:lines() do
        local k, v = line:match("^(Vm%w+):%s+(%d+)%s+kB")
        if k and v then
            res[k] = tonumber(v)
        end
    end
    f:close()
    return res
end

local function formatKB(kb)
    return string.format("%.1f KB (%.2f MB)", kb, kb / 1024)
end

print("=======================================================")
print("         KOReader X-Ray Memory Benchmark               ")
print("=======================================================")

local results = {}

-- ----------------------------------------------------
-- Benchmark 1: Unit Scanner Ingestion & Deduplication
-- ----------------------------------------------------
print("\n--- Running Benchmark 1: Unit Scanner Ingestion (4,000 hits) ---")
collectgarbage("collect")
collectgarbage("collect")

local mem_proc_start1 = getProcessMemory()
local gc_start1 = collectgarbage("count")

-- Generate 4,000 realistic hits matching doc:findAllText output
local hits1 = {}
local hits2 = {}
for i = 1, 2500 do
    table.insert(hits1, {
        ["start"] = "/body/div[1]/p[" .. i .. "]/text().0",
        ["end"] = "/body/div[1]/p[" .. i .. "]/text()." .. (10 + (i % 20)),
        matched_text = tostring(i % 100) .. " miles",
        prev_text = "The horse traveled about "
    })
end
for i = 1, 1500 do
    table.insert(hits2, {
        ["start"] = "/body/div[1]/p[" .. (i + 2500) .. "]/text().0",
        ["end"] = "/body/div[1]/p[" .. (i + 2500) .. "]/text()." .. (8 + (i % 15)),
        matched_text = tostring(15 + (i % 80)) .. " pounds",
        prev_text = "The package weighed nearly "
    })
end

-- Simulate unit scanner merging & deduplication pipeline with improved staged nulling
local hits = {}
for _, h in ipairs(hits1) do table.insert(hits, h) end
hits1 = nil
for _, h in ipairs(hits2) do table.insert(hits, h) end
hits2 = nil

local unique_hits = {}
for _, hit in ipairs(hits) do
    local end_xp = hit["end"]
    if not unique_hits[end_xp] or #hit.matched_text > #unique_hits[end_xp].matched_text then
        unique_hits[end_xp] = hit
    end
end
hits = nil

local deduped_hits = {}
for _, hit in pairs(unique_hits) do
    table.insert(deduped_hits, hit)
end
unique_hits = nil
collectgarbage("step", 200)

-- Simulate XP match extraction
local xp_matches = {}
for idx, hit in ipairs(deduped_hits) do
    table.insert(xp_matches, {
        start_xp = hit["start"],
        end_xp = hit["end"],
        original = hit.matched_text,
        converted = tostring(idx) .. " km",
        category = "length"
    })
end
deduped_hits = nil

local gc_peak1 = collectgarbage("count")
local mem_proc_peak1 = getProcessMemory()

-- Cleanup step
xp_matches = nil

collectgarbage("collect")
collectgarbage("collect")
local gc_end1 = collectgarbage("count")

results.unit_scanner = {
    gc_start = gc_start1,
    gc_peak = gc_peak1,
    gc_allocated = gc_peak1 - gc_start1,
    gc_end = gc_end1,
    gc_retained = gc_end1 - gc_start1,
    vm_rss_start = mem_proc_start1 and mem_proc_start1.VmRSS or 0,
    vm_rss_peak = mem_proc_peak1 and mem_proc_peak1.VmRSS or 0,
    vm_hwm = mem_proc_peak1 and mem_proc_peak1.VmHWM or 0,
}

print(string.format("  Initial Lua Heap   : %s", formatKB(gc_start1)))
print(string.format("  Peak Lua Heap      : %s", formatKB(gc_peak1)))
print(string.format("  Allocated During   : %s", formatKB(gc_peak1 - gc_start1)))
print(string.format("  Post-GC Heap       : %s", formatKB(gc_end1)))
if mem_proc_peak1 and mem_proc_peak1.VmRSS then
    print(string.format("  OS Peak VmRSS      : %s", formatKB(mem_proc_peak1.VmRSS)))
    print(string.format("  OS VmHWM (Peak RAM): %s", formatKB(mem_proc_peak1.VmHWM)))
end

-- ----------------------------------------------------
-- Benchmark 2: AI Large Async Result Parsing
-- ----------------------------------------------------
print("\n--- Running Benchmark 2: AI Async Result Ingestion (~350 KB payload) ---")
collectgarbage("collect")
collectgarbage("collect")

local mem_proc_start2 = getProcessMemory()
local gc_start2 = collectgarbage("count")

-- Build a ~350KB realistic AI response structure
local large_ai_data = {
    characters = {},
    locations = {},
    terms = {},
    timeline = {}
}
for i = 1, 200 do
    table.insert(large_ai_data.characters, {
        name = "Character " .. i,
        role = "Major Protagonist",
        description = "A complex character navigating the political intrigue of the imperial court across several key chapters in the series with full backstory and extended notes. " .. string.rep("Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ", 8),
        aliases = { "Char " .. i, "C" .. i, "Lord " .. i, "Vance " .. i },
        first_chapter = "Chapter " .. (i % 20 + 1)
    })
end
for i = 1, 80 do
    table.insert(large_ai_data.locations, {
        name = "Location " .. i,
        description = "A fortified settlement in the northern provinces renowned for its ancient archives and granite fortifications. " .. string.rep("Praesent tristique magna vel risus cursus. ", 6)
    })
end
for i = 1, 100 do
    table.insert(large_ai_data.terms, {
        name = "Term " .. i,
        category = "Worldbuilding",
        description = "A specialized concept referring to the regional governance and arcane philosophy of the realm."
    })
end

local inner_ai_text = json.encode(large_ai_data)
local ai_response_envelope = {
    candidates = {{
        content = { parts = {{ text = inner_ai_text }} },
        finishReason = "STOP"
    }}
}
local full_response_str = json.encode(ai_response_envelope)
local tmp_result_file = "/tmp/test_xray_async_result_bench.json"
local f_tmp = io.open(tmp_result_file, "w")
f_tmp:write("200\ngemini\n" .. full_response_str)
f_tmp:close()

print(string.format("  Generated payload size: %d bytes (%.1f KB)", #full_response_str, #full_response_str / 1024))

local helper = AIHelper
helper:init("xray.koplugin/")
local parsed_result = helper:checkAsyncResult(tmp_result_file)

local gc_peak2 = collectgarbage("count")
local mem_proc_peak2 = getProcessMemory()

-- Cleanup
parsed_result = nil
large_ai_data = nil
inner_ai_text = nil
ai_response_envelope = nil
full_response_str = nil
pcall(os.remove, tmp_result_file)

collectgarbage("collect")
collectgarbage("collect")
local gc_end2 = collectgarbage("count")

results.ai_ingestion = {
    gc_start = gc_start2,
    gc_peak = gc_peak2,
    gc_allocated = gc_peak2 - gc_start2,
    gc_end = gc_end2,
    gc_retained = gc_end2 - gc_start2,
    vm_rss_start = mem_proc_start2 and mem_proc_start2.VmRSS or 0,
    vm_rss_peak = mem_proc_peak2 and mem_proc_peak2.VmRSS or 0,
    vm_hwm = mem_proc_peak2 and mem_proc_peak2.VmHWM or 0,
}

print(string.format("  Initial Lua Heap   : %s", formatKB(gc_start2)))
print(string.format("  Peak Lua Heap      : %s", formatKB(gc_peak2)))
print(string.format("  Allocated During   : %s", formatKB(gc_peak2 - gc_start2)))
print(string.format("  Post-GC Heap       : %s", formatKB(gc_end2)))
if mem_proc_peak2 and mem_proc_peak2.VmRSS then
    print(string.format("  OS Peak VmRSS      : %s", formatKB(mem_proc_peak2.VmRSS)))
    print(string.format("  OS VmHWM (Peak RAM): %s", formatKB(mem_proc_peak2.VmHWM)))
end

-- ----------------------------------------------------
-- Output JSON Summary for comparison
-- ----------------------------------------------------
local out_path = arg[1] or "tools/benchmark_results.json"
local out_f = io.open(out_path, "w")
if out_f then
    out_f:write(json.encode(results))
    out_f:close()
    print(string.format("\nBenchmark metrics written to %s", out_path))
end
