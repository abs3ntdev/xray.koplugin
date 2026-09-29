-- OAuth-only POSIX store, never included in legacy settings or backups.
-- flock serializes rotation and is released by the kernel after a crash.
-- fsync + same-directory rename makes writes atomic and crash-durable.
-- Permissions do NOT protect credentials on USB-accessible FAT filesystems.
local Store = {}
local MAX_BYTES = 1024 * 1024

-- Linux UAPI arch/{arm,arm64}/include/uapi/asm/fcntl.h overrides
-- asm-generic: x86 O_NOFOLLOW/O_DIRECTORY values are wrong on Kobo.
function Store:platformFlags(arch)
    if arch == "arm" or arch == "arm64" then
        return { nofollow = 32768, directory = 16384, cloexec = 524288 }
    elseif arch == "x64" or arch == "x86" then
        return { nofollow = 131072, directory = 65536, cloexec = 524288 }
    end
    error("unsupported storage architecture")
end
local function posix()
    local ffi = require("ffi")
    if ffi.os ~= "Linux" then error("unsupported storage platform") end
    ffi.cdef[[
        int open(const char *, int, ...);
        int openat(int, const char *, int, ...);
        int close(int);
        long read(int, void *, unsigned long);
        long write(int, const void *, unsigned long);
        int fsync(int);
        int flock(int, int);
        int mkdirat(int, const char *, unsigned int);
        int renameat(int, const char *, int, const char *);
        int unlinkat(int, const char *, int);
    ]]
    return ffi, ffi.C, Store:platformFlags(ffi.arch)
end
local function validPath(path)
    return type(path) == "string" and path:sub(1, 1) == "/" and path:sub(-1) ~= "/"
        and not path:find("%z") and not (path .. "/"):find("/%.%.?/")
end
-- Walk each parent through directory descriptors. O_NOFOLLOW on only the final
-- filename is insufficient: settings/xray itself might be a symlink.
local function parent(C, ffi, flags, path, create)
    local directory, leaf = path:match("^(.*)/([^/]+)$")
    local mode = flags.directory + flags.nofollow + flags.cloexec
    local fd = C.open("/", mode)
    if fd < 0 then return nil, "store_unavailable" end
    for part in directory:gmatch("[^/]+") do
        if create and C.mkdirat(fd, part, 448) ~= 0 and ffi.errno() ~= 17 then
            C.close(fd)
            return nil, "store_unavailable"
        end
        local nextfd = C.openat(fd, part, mode)
        local err = ffi.errno()
        C.close(fd)
        if nextfd < 0 then return nil, err == 2 and "not_connected" or "store_unavailable" end
        fd = nextfd
    end
    return fd, leaf
end

function Store:load(path)
    if not validPath(path) then return nil, "store_unavailable" end
    local ffi, C, flags = posix()
    local directory, leaf = parent(C, ffi, flags, path, false)
    if not directory then return nil, leaf end
    local fd = C.openat(directory, leaf, flags.nofollow + flags.cloexec)
    local err = ffi.errno()
    C.close(directory)
    if fd < 0 then return nil, err == 2 and "not_connected" or "store_unavailable" end
    local chunks, count, buffer = {}, 0, ffi.new("char[4096]")
    while true do
        local n = tonumber(C.read(fd, buffer, 4096))
        if n == 0 then break end
        if n < 0 or count + n > MAX_BYTES then
            C.close(fd)
            return nil, "store_invalid"
        end
        count = count + n
        chunks[#chunks + 1] = ffi.string(buffer, n)
    end
    C.close(fd)
    local ok, data = pcall(require("json").decode, table.concat(chunks))
    if not ok or type(data) ~= "table" then return nil, "store_invalid" end
    return data
end

function Store:acquire(path)
    if not validPath(path) then return nil, "store_unavailable" end
    local ffi, C, flags = posix()
    local directory, leaf = parent(C, ffi, flags, path, true)
    if not directory then return nil, leaf end
    local fd = C.openat(directory, leaf .. ".lock", 66 + flags.nofollow + flags.cloexec, ffi.new("int", 384))
    C.close(directory)
    if fd < 0 then return nil, "store_unavailable" end
    if C.flock(fd, 6) ~= 0 then -- LOCK_EX | LOCK_NB
        C.close(fd)
        return nil, "auth_busy"
    end
    local released = false
    return function()
        if not released then
            released = true
            C.flock(fd, 8)
            C.close(fd)
        end
    end
end

-- Caller holds acquire(path) for save/clear (including .generation metadata).
function Store:save(path, value)
    if not validPath(path) then return nil, "store_unavailable" end
    local ffi, C, flags = posix()
    local ok, encoded = pcall(require("json").encode, value)
    if not ok or type(encoded) ~= "string" or #encoded > MAX_BYTES then return nil, "store_write_failed" end
    local directory, leaf = parent(C, ffi, flags, path, false)
    if not directory then return nil, "store_write_failed" end
    local temporary = leaf .. ".tmp"
    C.unlinkat(directory, temporary, 0) -- Crash residue, safe under the lock.
    local fd = C.openat(directory, temporary, 193 + flags.nofollow + flags.cloexec, ffi.new("int", 384))
    if fd < 0 then C.close(directory) return nil, "store_write_failed" end
    local function failed()
        if fd then C.close(fd) end
        C.unlinkat(directory, temporary, 0)
        C.close(directory)
        return nil, "store_write_failed"
    end
    local offset = 0
    while offset < #encoded do
        local n = tonumber(C.write(fd, encoded:sub(offset + 1), #encoded - offset))
        if n <= 0 then return failed() end
        offset = offset + n
    end
    local synced = C.fsync(fd) == 0
    local closed = C.close(fd) == 0
    fd = nil
    if not synced or not closed or C.renameat(directory, temporary, directory, leaf) ~= 0 then
        return failed()
    end
    local durable = C.fsync(directory) == 0
    C.close(directory)
    if not durable then return nil, "store_write_failed" end
    return true
end

function Store:clear(path)
    if not validPath(path) then return nil, "store_unavailable" end
    local ffi, C, flags = posix()
    local directory, leaf = parent(C, ffi, flags, path, false)
    if not directory then return leaf == "not_connected" and true or nil, leaf end
    local removed = C.unlinkat(directory, leaf, 0) == 0 or ffi.errno() == 2
    C.unlinkat(directory, leaf .. ".tmp", 0)
    local durable = C.fsync(directory) == 0
    C.close(directory)
    if not removed or not durable then return nil, "store_write_failed" end
    return true
end
return Store
