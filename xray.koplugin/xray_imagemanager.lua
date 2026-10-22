-- xray_imagemanager.lua - Document Image and Map Extraction & Tracking for KOReader X-Ray
local logger = require("logger")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or type(lfs) ~= "table" then
    ok_lfs, lfs = pcall(require, "lfs")
end
if not ok_lfs or type(lfs) ~= "table" then lfs = nil end

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local utils = require(plugin_path .. "xray_utils")

pcall(require, "ffi/loadlib")
local ok_archiver, Archiver = pcall(require, "ffi/archiver")
if not ok_archiver or type(Archiver) ~= "table" then
    Archiver = nil
end

-- Fast binary header parser for PNG, JPEG, GIF, and WebP dimensions from in-memory string
local function parseImageDimensionsFromBytes(data)
    if not data or #data < 10 then return nil, nil end
    -- PNG: bytes 17-24 (width, height in big-endian)
    if data:sub(1, 8) == "\137PNG\r\n\26\n" and #data >= 24 then
        local w1, w2, w3, w4, h1, h2, h3, h4 = data:byte(17, 24)
        if w1 and h4 then
            local w = (w1 * 16777216) + (w2 * 65536) + (w3 * 256) + w4
            local h = (h1 * 16777216) + (h2 * 65536) + (h3 * 256) + h4
            return w, h
        end
    end
    -- GIF: bytes 7-10 (width, height in little-endian)
    if data:sub(1, 3) == "GIF" and #data >= 10 then
        local w1, w2, h1, h2 = data:byte(7, 10)
        if w1 and h2 then
            return w1 + (w2 * 256), h1 + (h2 * 256)
        end
    end
    -- JPEG: scan SOF markers
    if data:byte(1) == 0xFF and data:byte(2) == 0xD8 then
        local pos = 3
        local len_data = #data
        while pos + 3 <= len_data do
            local m1, m2 = data:byte(pos, pos + 1)
            if m1 ~= 0xFF then break end
            while m2 == 0xFF and pos + 2 <= len_data do
                pos = pos + 1
                m2 = data:byte(pos + 1)
            end
            local seg_len = data:byte(pos + 2) * 256 + data:byte(pos + 3)
            if (m2 >= 0xC0 and m2 <= 0xC3) or (m2 >= 0xC5 and m2 <= 0xC7) or (m2 >= 0xC9 and m2 <= 0xCB) or (m2 >= 0xCD and m2 <= 0xCF) then
                if pos + 8 <= len_data then
                    local h = data:byte(pos + 5) * 256 + data:byte(pos + 6)
                    local w = data:byte(pos + 7) * 256 + data:byte(pos + 8)
                    return w, h
                end
                break
            else
                if seg_len < 2 then break end
                pos = pos + 2 + seg_len
            end
        end
    end
    return nil, nil
end

local ImageManager = {}

function ImageManager:new(plugin)
    local o = {
        plugin = plugin,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Generate a safe unique ID for an image entry
function ImageManager:generateImageId(href, index)
    if not href or href == "" then
        return "img_" .. tostring(index or os.time())
    end
    local clean = href:gsub("[^%w%._%-]", "_")
    return clean .. "_" .. tostring(index or 1)
end

-- Ensure sidecar image directory exists
function ImageManager:getImageDir(book_path)
    if not book_path then return nil end
    local sidecar_dir = DocSettings:getSidecarDir(book_path)
    local image_dir = sidecar_dir .. "/xray/images"
    pcall(function()
        local util = require("util")
        if util and util.makePath then
            util.makePath(image_dir)
        end
    end)
    if lfs then
        pcall(function()
            lfs.mkdir(sidecar_dir)
            lfs.mkdir(sidecar_dir .. "/xray")
            lfs.mkdir(image_dir)
        end)
    end
    return image_dir
end

-- Check if an image title or filename suggests it is a map or diagram
function ImageManager:classifyImage(title, href)
    local text = (tostring(title or "") .. " " .. tostring(href or "")):lower()
    if text:find("map") or text:find("karte") or text:find("carte") or text:find("mapa") or text:find("plano") then
        return "map"
    elseif text:find("diagram") or text:find("chart") or text:find("tree") or text:find("genealog") or text:find("lineage") or text:find("schema") then
        return "diagram"
    elseif text:find("plan") or text:find("layout") or text:find("floor") then
        return "diagram"
    elseif text:find("illus") or text:find("plate") or text:find("figure") or text:find("fig") then
        return "illustration"
    end
    return "general"
end

-- Check if an image is purely ornamental / decorative noise
function ImageManager:isOrnamental(image, filter_mode)
    if filter_mode == "all" then
        return false
    end
    
    local text = (tostring(image.title or "") .. " " .. tostring(image.href or "") .. " " .. tostring(image.id or "")):lower()
    
    -- Blacklisted decorative filenames and IDs
    local ornamental_patterns = {
        "ornament", "divider", "decoration", "bullet", "flourish",
        "vignette", "border", "dropcap", "drop_cap", "line_break",
        "colophon", "publisher_logo", "logo_small", "sep_line",
        "header_icon", "footer_icon", "star_sep", "fleuron", "orn_",
        "separator", "dingbat", "spacer", "tailpiece", "headpiece"
    }
    for _, pat in ipairs(ornamental_patterns) do
        if text:find(pat) then
            return true
        end
    end
    
    if not image then return true end
    
    if filter_mode == "maps_only" or filter_mode == "large_only" then
        local cat = (image.category or "image"):lower()
        if cat == "map" or cat == "diagram" then
            return false
        end
        local w = tonumber(image.width) or 0
        local h = tonumber(image.height) or 0
        if w >= 500 or h >= 500 then
            return false
        end
        return true
    end
    
    -- "all" mode includes all illustrations and maps
    return false
end

-- Extract archive entry to target file path using Archiver.Reader with unzip fallback
function ImageManager:extractArchiveEntry(book_path, entry_name, target_path)
    if not book_path or not entry_name or not target_path then return false end

    -- Strategy 1: In-process libarchive via ffi/archiver (works on WSL, Kindle, Android, Linux)
    if Archiver and Archiver.Reader then
        local ok, success = pcall(function()
            local r = Archiver.Reader:new()
            if not r:open(book_path) then return false end

            local target_entry = nil
            local lower_entry = entry_name:lower()
            local base_entry = (entry_name:match("([^/]+)$") or entry_name):lower()

            for entry in r:iterate() do
                if entry.mode == "file" then
                    if entry.path == entry_name then
                        target_entry = entry
                        break
                    elseif entry.path:lower() == lower_entry then
                        target_entry = entry
                    elseif not target_entry and (entry.path:match("([^/]+)$") or ""):lower() == base_entry then
                        target_entry = entry
                    end
                end
            end

            local ok_extract = false
            if target_entry then
                ok_extract = r:extractToPath(target_entry.index, target_path)
            end
            r:close()
            return ok_extract
        end)

        if ok and success then
            local attr = lfs and lfs.attributes(target_path)
            if attr and attr.size and attr.size > 0 then
                return true
            end
            local f = io.open(target_path, "rb")
            if f then
                local sz = f:seek("end")
                f:close()
                if sz and sz > 0 then return true end
            end
        end
    end

    -- Strategy 2: External unzip CLI fallback (for Kindle BusyBox or environments without libarchive)
    local escaped_book = book_path:gsub("'", "'\\''")
    local escaped_entry = entry_name:gsub("'", "'\\''")
    local escaped_target = target_path:gsub("'", "'\\''")

    local cmd = string.format("unzip -p '%s' '%s' > '%s'", escaped_book, escaped_entry, escaped_target)
    local rc = os.execute(cmd)
    if rc == 0 or rc == true then
        local attr = lfs and lfs.attributes(target_path)
        if attr and attr.size and attr.size > 0 then return true end
        local f = io.open(target_path, "rb")
        if f then
            local sz = f:seek("end")
            f:close()
            if sz and sz > 0 then return true end
        end
    end

    -- Strategy 3: Unzip wildcard fallback on base filename
    local base_name = entry_name:match("([^/]+)$") or entry_name
    local fallback_cmd = string.format("unzip -p '%s' '*%s' > '%s'", escaped_book, base_name:gsub("'", "'\\''"), escaped_target)
    local rc2 = os.execute(fallback_cmd)
    if rc2 == 0 or rc2 == true then
        local attr = lfs and lfs.attributes(target_path)
        if attr and attr.size and attr.size > 0 then return true end
        local f = io.open(target_path, "rb")
        if f then
            local sz = f:seek("end")
            f:close()
            if sz and sz > 0 then return true end
        end
    end

    pcall(os.remove, target_path)
    return false
end

-- Extract image file from an EPUB / archive to the sidecar images directory
function ImageManager:extractImageToFile(book_path, image)
    if not image then return nil end
    if image.cached_file then
        local f = io.open(image.cached_file, "rb")
        if f then
            local sz = f:seek("end")
            f:close()
            if sz and sz > 0 then
                return image.cached_file
            end
        end
    end
    if not book_path or not image.href then return nil end
    local image_dir = self:getImageDir(book_path)
    if not image_dir then return nil end
    
    -- Target extracted file path
    local ext = image.href:match("%.([%w]+)$") or "jpg"
    local safe_id = image.id or self:generateImageId(image.href, image.page)
    local target_path = image_dir .. "/" .. safe_id .. "." .. ext
    
    -- Check if already extracted
    if lfs then
        local attr = lfs.attributes(target_path)
        if attr and attr.size and attr.size > 0 then
            image.cached_file = target_path
            return target_path
        end
    else
        local f = io.open(target_path, "rb")
        if f then
            local sz = f:seek("end")
            f:close()
            if sz and sz > 0 then
                image.cached_file = target_path
                return target_path
            end
        end
    end
    
    if self:extractArchiveEntry(book_path, image.href, target_path) then
        image.cached_file = target_path
        return target_path
    end

    return nil
end

-- Filter images based on selected tab and reading progress
function ImageManager:getFilteredImages(images, tab, current_page, filter_mode, series_images)
    images = images or {}
    series_images = series_images or {}
    filter_mode = filter_mode or "standard"
    
    local results = {}
    
    -- 1. Handle Series Tab specifically
    if tab == "series" then
        for _, img in ipairs(series_images) do
            local item = {}
            for k, v in pairs(img) do item[k] = v end
            item.is_series = true
            table.insert(results, item)
        end
        return results
    end
    
    -- 2. Process current book images
    for _, img in ipairs(images) do
        local is_hidden = (img.is_hidden == true)
        local is_fav = (img.is_favorite == true)
        
        local include = false
        if tab == "hidden" then
            include = is_hidden
        elseif tab == "favorites" then
            -- Favorites are explicitly curated: ALWAYS show all favorites
            include = is_fav and not is_hidden
        else -- "all" tab: filter according to active filter_mode
            local is_ornamental = self:isOrnamental(img, filter_mode)
            include = not is_hidden and not is_ornamental
        end
        
        if include then
            local item = {}
            for k, v in pairs(img) do item[k] = v end
            
            -- Spoiler calculation: if image appears after current_page
            if img.spoiler_revealed == true then
                item.is_spoiler = false
                item.spoiler_revealed = true
            elseif current_page and item.page and tonumber(item.page) then
                item.is_spoiler = tonumber(item.page) > tonumber(current_page)
            else
                item.is_spoiler = false
            end
            
            table.insert(results, item)
        end
    end
    
    -- Sort: Favorites first, then strictly by book page order
    table.sort(results, function(a, b)
        if (a.is_favorite and true or false) ~= (b.is_favorite and true or false) then
            return a.is_favorite == true
        end
        local pA = tonumber(a.page) or 0
        local pB = tonumber(b.page) or 0
        if pA ~= pB then
            return pA < pB
        end
        return (a.title or "") < (b.title or "")
    end)
    
    return results
end

local function matchesImageKey(img, key)
    if not img or not key then return false end
    return (img.id and img.id == key)
        or (img.href and img.href == key)
        or (img.src and img.src == key)
        or (img.title and img.title == key)
        or (img.cached_file and img.cached_file == key)
        or (img.local_file and img.local_file == key)
end

-- Toggle favorite status for an image
function ImageManager:toggleFavorite(book_data, image_id)
    if not book_data or not book_data.images or not image_id then return false end
    for _, img in ipairs(book_data.images) do
        if matchesImageKey(img, image_id) then
            img.is_favorite = not (img.is_favorite == true)
            return img.is_favorite
        end
    end
    return false
end

-- Rename image title
function ImageManager:renameImage(book_data, image_id, new_title)
    if not book_data or not book_data.images or not image_id or not new_title then return false end
    for _, img in ipairs(book_data.images) do
        if matchesImageKey(img, image_id) then
            img.title = new_title
            img.custom_title = true
            return true
        end
    end
    return false
end

-- Set rotation angle for an image
function ImageManager:setImageRotation(book_data, image_id, rotation)
    if not book_data or not book_data.images or not image_id then return false end
    for _, img in ipairs(book_data.images) do
        if matchesImageKey(img, image_id) then
            img.rotation = rotation
            return true
        end
    end
    return false
end

-- Set zoom level and pan position for an image
function ImageManager:setImageZoom(book_data, image_id, zoom_level, pan_x, pan_y)
    if not book_data or not book_data.images or not image_id then return false end
    for _, img in ipairs(book_data.images) do
        if matchesImageKey(img, image_id) then
            img.zoom_level = zoom_level
            img.pan_x = pan_x
            img.pan_y = pan_y
            return true
        end
    end
    return false
end

-- Toggle hidden status for an image
function ImageManager:toggleHideImage(book_data, image_id)
    if not book_data or not book_data.images or not image_id then return false end
    for _, img in ipairs(book_data.images) do
        if matchesImageKey(img, image_id) then
            img.is_hidden = not (img.is_hidden == true)
            return img.is_hidden
        end
    end
    return false
end

-- Extract sequential TOC order of XHTML files from NCX (EPUB 2) or Nav (EPUB 3)
function ImageManager:getTocFileMapping(book_path, ncx_path, nav_path, preloaded_content)
    local file_to_toc_idx = {}
    local content = preloaded_content
    local target_path = ncx_path or nav_path
    if not target_path and not content then return file_to_toc_idx end

    if not content and book_path and target_path then
        local raw_book = book_path:gsub("^'", ""):gsub("'$", ""):gsub("'\\'''", "'")
        if Archiver and Archiver.Reader then
            pcall(function()
                local r = Archiver.Reader:new()
                if r:open(raw_book) then
                    for entry in r:iterate() do
                        if entry.path == target_path or entry.path:lower() == target_path:lower() then
                            content = r:extractToMemory(entry.index)
                            break
                        end
                    end
                    r:close()
                end
            end)
        end
        if not content then
            local escaped_book = raw_book:gsub("'", "'\\''")
            local cmd = string.format("unzip -p '%s' '%s'", escaped_book, target_path:gsub("'", "'\\''"))
            local p = io.popen(cmd)
            if p then
                content = p:read("*a") or ""
                p:close()
            end
        end
    end

    content = content or ""
    local idx = 0
    if ncx_path and (content:find("<ncx") or content:find("<navMap")) then
        for src in content:gmatch('<content%s+src=["\']([^"\']+)["\']') do
            idx = idx + 1
            local clean = src:match("([^#]+)") or src
            local base = clean:match("([^/]+)$") or clean
            if not file_to_toc_idx[base] then
                file_to_toc_idx[base] = idx
            end
        end
    elseif nav_path or content:find("<nav") then
        for href in content:gmatch('<a%s+[^>]*href=["\']([^"\']+)["\']') do
            idx = idx + 1
            local clean = href:match("([^#]+)") or href
            local base = clean:match("([^/]+)$") or clean
            if not file_to_toc_idx[base] then
                file_to_toc_idx[base] = idx
            end
        end
    end
    return file_to_toc_idx
end

-- Builds a verified mapping from spine index (1..#spine_items) to KOReader rendered page number
function ImageManager:buildSpinePageMap(ui, spine_items, manifest_id_to_spine, total_pages, file_to_toc_idx)
    local spine_to_page = {}
    local num_spine = #spine_items
    if num_spine == 0 then return spine_to_page, {} end
    total_pages = math.max(1, tonumber(total_pages) or 1)

    -- Spine 1 is always Page 1
    spine_to_page[1] = 1

    local toc_entries = {}
    if ui and ui.document and type(ui.document.getToc) == "function" then
        local raw_toc = ui.document:getToc() or {}
        local utils_ok, utils = pcall(require, plugin_path .. "xray_utils")
        local flat_toc = (utils_ok and utils and utils.flattenTOC and utils:flattenTOC(raw_toc)) or raw_toc

        for idx, entry in ipairs(flat_toc) do
            local pg = tonumber(entry.page)
            -- Only resolve if page is missing or invalid; never overwrite a valid TOC page with 1
            if (not pg or pg <= 0) and entry.xpointer and type(ui.document.getPageFromXPointer) == "function" then
                local resolved = ui.document:getPageFromXPointer(entry.xpointer)
                if resolved and resolved > 0 then pg = resolved end
            end
            if pg and pg > 0 then
                table.insert(toc_entries, {
                    title = entry.title or "",
                    page = pg,
                    xpointer = entry.xpointer,
                })

                -- 1. Direct TOC file mapping (from NCX/Nav order)
                if file_to_toc_idx then
                    for s_idx, s_href in ipairs(spine_items) do
                        local base_s = s_href:match("([^/]+)$") or s_href
                        if file_to_toc_idx[base_s] == idx and not spine_to_page[s_idx] then
                            spine_to_page[s_idx] = pg
                        end
                    end
                end

                if entry.xpointer then
                    -- Pattern 1: CFI spine element: /6/(%d+) -> s_idx = n / 2
                    local cfi_idx = entry.xpointer:match("/6/(%d+)")
                    if cfi_idx then
                        local s_idx = math.floor(tonumber(cfi_idx) / 2)
                        if s_idx >= 1 and s_idx <= num_spine and not spine_to_page[s_idx] then
                            spine_to_page[s_idx] = pg
                        end
                    end

                    -- Pattern 2: Manifest item ID in brackets: e.g. [item_id]
                    local item_id = entry.xpointer:match("%[([^%]]+)%]")
                    if item_id and manifest_id_to_spine and manifest_id_to_spine[item_id] then
                        local s_idx = manifest_id_to_spine[item_id]
                        if s_idx >= 1 and s_idx <= num_spine and not spine_to_page[s_idx] then
                            spine_to_page[s_idx] = pg
                        end
                    end
                end
            end
        end
    end

    -- Always anchor last spine item to total_pages if unanchored
    if not spine_to_page[num_spine] or spine_to_page[num_spine] <= 1 then
        spine_to_page[num_spine] = total_pages
    end

    -- Collect sorted anchor points
    local anchors = {}
    for idx, pg in pairs(spine_to_page) do
        table.insert(anchors, { idx = idx, page = pg })
    end
    table.sort(anchors, function(a, b) return a.idx < b.idx end)

    -- Interpolate between adjacent anchors (strictly localized between chapters)
    local final_map = {}
    for i = 1, #anchors - 1 do
        local a1 = anchors[i]
        local a2 = anchors[i + 1]
        final_map[a1.idx] = a1.page
        local idx_diff = a2.idx - a1.idx
        local page_diff = a2.page - a1.page
        for s = a1.idx + 1, a2.idx - 1 do
            local ratio = (s - a1.idx) / math.max(1, idx_diff)
            final_map[s] = math.max(1, math.min(total_pages, a1.page + math.floor(ratio * page_diff)))
        end
    end
    if #anchors > 0 then
        final_map[anchors[#anchors].idx] = anchors[#anchors].page
    end

    return final_map, toc_entries
end

-- Dynamically resolve accurate page for an image.
-- Reads TOC mapping from NCX/Nav to pair the image's containing spine XHTML file
-- directly to KOReader's rendered page for that section.
function ImageManager:resolveImagePage(ui, image_entry, force)
    if not image_entry then return 1 end

    local href = image_entry.href or ""
    local title = (image_entry.title or ""):lower()
    local lower_href = href:lower()
    local base_href = (href:match("([^/]+)$") or href):lower()

    -- 1. Cover images are always Page 1
    if lower_href:find("cover") or title:find("cover") or (image_entry.id and tostring(image_entry.id):find("cover")) then
        image_entry.page = 1
        image_entry.page_resolved = true
        return 1
    end

    -- 2. Fast path: If the image page was already accurately resolved, return it immediately without disk/process overhead
    local existing = tonumber(image_entry.page)
    if not force and image_entry.page_resolved and existing and existing > 0 then
        return existing
    end

    if not ui or not ui.document or not ui.document.file then
        return existing or 1
    end

    local book_path = ui.document.file
    if not book_path:lower():match("%.epub$") then
        return existing or 1
    end

    local escaped_book = book_path:gsub("'", "'\\''")
    local total_pages = (type(ui.document.getPageCount) == "function" and ui.document:getPageCount()) 
                     or (type(ui.document.getTotalPages) == "function" and ui.document:getTotalPages()) 
                     or 1

    -- 3. Retrieve or build cached EPUB spine structure
    self._epub_spine_cache = self._epub_spine_cache or {}
    local meta = self._epub_spine_cache[book_path]

    if not meta then
        local opf_path, ncx_path, nav_path = nil, nil, nil
        local opf_content = nil
        local ncx_content = nil
        local nav_content = nil

        if Archiver and Archiver.Reader then
            pcall(function()
                local r = Archiver.Reader:new()
                if r:open(book_path) then
                    for entry in r:iterate() do
                        if entry.mode == "file" then
                            local f_lower = entry.path:lower()
                            if f_lower:match("%.opf$") then opf_path = entry.path
                            elseif f_lower:match("%.ncx$") then ncx_path = entry.path
                            elseif f_lower:match("nav%.xhtml$") or f_lower:match("nav%.html$") then nav_path = entry.path end
                        end
                    end
                    if opf_path then opf_content = r:extractToMemory(opf_path) end
                    if ncx_path then ncx_content = r:extractToMemory(ncx_path) end
                    if nav_path then nav_content = r:extractToMemory(nav_path) end
                    r:close()
                end
            end)
        end

        if not opf_path then
            local list_pipe = io.popen(string.format("unzip -l '%s'", escaped_book))
            if list_pipe then
                for line in list_pipe:lines() do
                    local fname = line:match("^%s*%d+%s+[%d%-%s:]+%s+(.+)%s*$")
                    if fname then
                        local f_lower = fname:lower()
                        if f_lower:match("%.opf$") then opf_path = fname
                        elseif f_lower:match("%.ncx$") then ncx_path = fname
                        elseif f_lower:match("nav%.xhtml$") or f_lower:match("nav%.html$") then nav_path = fname end
                    end
                end
                list_pipe:close()
            end
        end
        if not opf_path then return existing or 1 end

        if not opf_content then
            local opf_pipe = io.popen(string.format("unzip -p '%s' '%s'", escaped_book, opf_path:gsub("'", "'\\''")))
            if opf_pipe then opf_content = opf_pipe:read("*a") or ""; opf_pipe:close() end
        end
        if not opf_content or opf_content == "" then return existing or 1 end

        local opf_dir = opf_path:match("^(.*/)") or ""
        local manifest = {}
        local manifest_id_to_spine = {}
        for item_tag in opf_content:gmatch("<item%s+[^>]+>") do
            local id = item_tag:match('id=["\']([^"\']+)["\']')
            local item_href = item_tag:match('href=["\']([^"\']+)["\']')
            if id and item_href then
                local full = (opf_dir .. item_href):gsub("[^/]+/%.%./", ""):gsub("%./", "")
                manifest[id] = full
            end
        end

        local spine_items = {}
        for itemref in opf_content:gmatch("<itemref%s+[^>]+>") do
            local idref = itemref:match('idref=["\']([^"\']+)["\']')
            if idref and manifest[idref] then
                table.insert(spine_items, manifest[idref])
                manifest_id_to_spine[idref] = #spine_items
            end
        end

        local file_to_toc_idx = self:getTocFileMapping(book_path, ncx_path, nav_path, ncx_content or nav_content)

        local flat_toc = {}
        if ui.document.getToc then
            local ok_toc, raw_toc = pcall(function() return ui.document:getToc() or {} end)
            if ok_toc and raw_toc then
                local utils_ok, utils = pcall(require, plugin_path .. "xray_utils")
                flat_toc = (utils_ok and utils and utils.flattenTOC and utils:flattenTOC(raw_toc)) or raw_toc
            end
        end

        local spine_page_map = self:buildSpinePageMap(ui, spine_items, manifest_id_to_spine, total_pages, file_to_toc_idx)

        meta = {
            spine_items = spine_items,
            manifest_id_to_spine = manifest_id_to_spine,
            file_to_toc_idx = file_to_toc_idx,
            flat_toc = flat_toc,
            spine_page_map = spine_page_map,
            spine_contents = {},
            _spine_keys = {},
            image_to_spine = {},
        }
        self._epub_spine_cache[book_path] = meta
    end

    local spine_items = meta.spine_items or {}
    local file_to_toc_idx = meta.file_to_toc_idx or {}
    local flat_toc = meta.flat_toc or {}
    local spine_page_map = meta.spine_page_map or {}

    -- 4. Find which spine XHTML file references this image (cached per image base href)
    local best = meta.image_to_spine[base_href]
    if not best then
        local matches = {}
        for s_idx, s_href in ipairs(spine_items) do
            local s_lower = s_href:lower()
            if s_lower:match("%.xhtml$") or s_lower:match("%.html$") or s_lower:match("%.htm$") then
                local content = meta.spine_contents[s_href]
                if not content then
                    if Archiver and Archiver.Reader then
                        pcall(function()
                            local r = Archiver.Reader:new()
                            if r:open(book_path) then
                                content = r:extractToMemory(s_href)
                                r:close()
                            end
                        end)
                    end
                    if not content then
                        local cmd = string.format("unzip -p '%s' '%s'", escaped_book, s_href:gsub("'", "'\\''"))
                        local sp = io.popen(cmd)
                        if sp then
                            content = sp:read("*a") or ""
                            sp:close()
                        end
                    end
                    if content and #content > 0 then
                        -- FIFO eviction: keep at most 20 spine files in RAM
                        meta._spine_keys = meta._spine_keys or {}
                        if #meta._spine_keys >= 20 then
                            local oldest = table.remove(meta._spine_keys, 1)
                            if oldest then meta.spine_contents[oldest] = nil end
                        end
                        table.insert(meta._spine_keys, s_href)
                        meta.spine_contents[s_href] = content
                    end
                end
                if content then
                    local pos = content:find(base_href, 1, true) or (href ~= "" and content:find(href, 1, true))
                    if pos then
                        local score = 0
                        local spine_name = s_lower:match("([^/]+)$") or s_lower
                        if spine_name:find("map") or spine_name:find("illus") or spine_name:find("image") or spine_name:find("plate") or spine_name:find("figure") then
                            score = score + 100
                        end
                        local size = #content
                        if size < 2500 then score = score + 50
                        elseif size < 5000 then score = score + 20
                        elseif size > 20000 then score = score - 20 end
                        table.insert(matches, { s_idx = s_idx, href = s_href, score = score, rel_pos = pos / math.max(1, #content) })
                        if score >= 100 then
                            break
                        end
                    end
                end
            end
        end

        if #matches > 0 then
            table.sort(matches, function(a, b)
                if a.score ~= b.score then return a.score > b.score end
                return a.s_idx > b.s_idx
            end)
            best = matches[1]
            meta.image_to_spine[base_href] = best
        end
    end

    -- 5. If best spine match is found, resolve directly through file_to_toc_idx -> flat_toc
    if best then
        local base_file = best.href:match("([^/]+)$") or best.href
        local t_idx = file_to_toc_idx[base_file]
        if t_idx and flat_toc[t_idx] and flat_toc[t_idx].page and flat_toc[t_idx].page > 0 then
            local start_pg = flat_toc[t_idx].page
            local next_toc = flat_toc[t_idx + 1]
            local end_pg = next_toc and next_toc.page and next_toc.page >= start_pg and next_toc.page or start_pg
            local resolved = start_pg
            if end_pg > start_pg and best.rel_pos and best.rel_pos > 0 then
                resolved = start_pg + math.floor(best.rel_pos * (end_pg - start_pg))
            end
            resolved = math.max(1, math.min(total_pages, resolved))
            image_entry.page = resolved
            image_entry.page_resolved = true
            return resolved
        end
    end

    -- 6. Fallback: use verified spine page map and interpolate
    if best and spine_page_map[best.s_idx] and spine_page_map[best.s_idx] > 1 then
        local base_pg = spine_page_map[best.s_idx]
        local next_pg = spine_page_map[best.s_idx + 1] or base_pg
        local span = math.max(0, next_pg - base_pg)
        local resolved = base_pg + math.floor((best.rel_pos or 0) * span)
        resolved = math.max(1, math.min(total_pages, resolved))
        image_entry.page = resolved
        image_entry.page_resolved = true
        return resolved
    end

    local existing = tonumber(image_entry.page)
    return (existing and existing > 1) and existing or (existing or 1)
end

-- Scan document images from EPUB OPF / spine
function ImageManager:scanDocumentImages(ui, on_progress_cb)
    if not ui or not ui.document then return {} end
    local book_path = ui.document.file
    if not book_path then return {} end
    
    logger.info("ImageManager: Starting image scan for: " .. tostring(book_path))
    local images = {}
    local total_pages = (type(ui.document.getPageCount) == "function" and ui.document:getPageCount()) 
                     or (type(ui.document.getTotalPages) == "function" and ui.document:getTotalPages()) 
                     or 1
    
    -- Format check
    local is_epub = book_path:lower():match("%.epub$") ~= nil
    local is_cbz = book_path:lower():match("%.cbz$") ~= nil
    
    if is_epub then
        images = self:scanEpubImages(book_path, total_pages, ui)
    elseif is_cbz then
        images = self:scanCbzImages(book_path, total_pages)
    else
        -- Fallback: Check document cover and pages
        local cover = {
            id = "img_cover",
            title = "Cover Image",
            page = 1,
            category = "illustration",
            href = "cover.jpg"
        }
        table.insert(images, cover)
    end
    
    logger.info(string.format("ImageManager: Scan complete, found %d images", #images))
    return images
end

-- Scan images in an EPUB file by reading OPF manifest, spine, and document TOC
function ImageManager:scanEpubImages(book_path, total_pages, ui)
    local images = {}
    total_pages = total_pages or 1
    
    local all_files = {}
    local opf_path = nil
    local ncx_path = nil
    local nav_path = nil
    local opf_content = nil
    local toc_content = nil
    local image_dimensions = {}

    -- 1. In-process streaming reader via libarchive (zero process forks, ~170ms)
    if Archiver and Archiver.Reader then
        pcall(function()
            local r = Archiver.Reader:new()
            if not r:open(book_path) then return end

            local image_entries_to_probe = {}

            -- Pass 1: Stream through archive in a single forward pass
            for entry in r:iterate() do
                if entry.mode == "file" then
                    local f_name = entry.path
                    local f_lower = f_name:lower()
                    table.insert(all_files, { size = entry.size or 0, name = f_name, arc_idx = entry.index })

                    if f_lower:match("%.opf$") then
                        opf_path = f_name
                    elseif f_lower:match("%.ncx$") then
                        ncx_path = f_name
                    elseif f_lower:match("nav%.xhtml$") or f_lower:match("nav%.html$") then
                        nav_path = f_name
                    elseif f_lower:match("%.jpe?g$") or f_lower:match("%.png$") or f_lower:match("%.webp$") or f_lower:match("%.gif$") then
                        table.insert(image_entries_to_probe, { path = f_name, size = entry.size or 0, index = entry.index })
                    end
                end
            end

            -- Extract OPF and TOC in-memory
            if opf_path then
                opf_content = r:extractToMemory(opf_path)
            end
            if ncx_path then
                toc_content = r:extractToMemory(ncx_path)
            elseif nav_path then
                toc_content = r:extractToMemory(nav_path)
            end

            -- Extract image dimensions from binary headers
            table.sort(image_entries_to_probe, function(a, b) return a.index < b.index end)
            for _, img_probe in ipairs(image_entries_to_probe) do
                if img_probe.size and img_probe.size > 0 and img_probe.size <= 4194304 then
                    local data = r:extractToMemory(img_probe.index)
                    if data then
                        local w, h = parseImageDimensionsFromBytes(data)
                        if w and h then
                            image_dimensions[img_probe.path] = { w = w, h = h }
                        end
                    end
                end
            end

            r:close()
        end)
    end

    -- Fallback to unzip -l / unzip -p if Archiver was unavailable or found no files
    if not opf_path and not all_files[1] then
        local escaped_book = book_path:gsub("'", "'\\''")
        local list_cmd = string.format("unzip -l '%s'", escaped_book)
        local p = io.popen(list_cmd)
        if p then
            for line in p:lines() do
                local size_str, fname = line:match("^%s*(%d+)%s+[%d%-%s:]+%s+(.+)%s*$")
                if size_str and fname then
                    table.insert(all_files, { size = tonumber(size_str) or 0, name = fname })
                    local f_lower = fname:lower()
                    if f_lower:match("%.opf$") then
                        opf_path = fname
                    elseif f_lower:match("%.ncx$") then
                        ncx_path = fname
                    elseif f_lower:match("nav%.xhtml$") or f_lower:match("nav%.html$") then
                        nav_path = fname
                    end
                end
            end
            p:close()
        end

        if opf_path and not opf_content then
            local opf_cmd = string.format("unzip -p '%s' '%s'", escaped_book, opf_path:gsub("'", "'\\''"))
            local opf_p = io.popen(opf_cmd)
            if opf_p then
                opf_content = opf_p:read("*a") or ""
                opf_p:close()
            end
        end
    end

    if not opf_content then return images end

    -- 2. Read and parse OPF manifest, spine, and cover metadata
    local manifest = {} -- id -> full_href
    local manifest_by_href = {}
    local manifest_id_to_spine = {}
    local spine_items = {} -- list of spine file full_hrefs in reading order
    local cover_img_href = nil

    local opf_dir = (opf_path and opf_path:match("^(.*/)")) or ""

    -- Extract cover image ID from meta name="cover"
    local cover_id = opf_content:match('<meta[^>]+name=["\']cover["\'][^>]+content=["\']([^"\']+)["\']')
        or opf_content:match('<meta[^>]+content=["\']([^"\']+)["\'][^>]+name=["\']cover["\']')

    -- Parse <item id="..." href="..." media-type="..."/>
    for item_tag in opf_content:gmatch("<item%s+[^>]+>") do
        local id = item_tag:match('id=["\']([^"\']+)["\']')
        local href = item_tag:match('href=["\']([^"\']+)["\']')
        local media_type = item_tag:match('media%-type=["\']([^"\']+)["\']') or ""
        local properties = item_tag:match('properties=["\']([^"\']+)["\']') or ""

        if id and href then
            local full_href = opf_dir .. href
            full_href = full_href:gsub("[^/]+/%.%./", ""):gsub("%./", "")
            manifest[id] = full_href
            manifest_by_href[full_href] = { id = id, href = full_href, media_type = media_type, properties = properties }
            manifest_by_href[href] = manifest_by_href[full_href]

            if properties:find("cover-image") or id == cover_id or id:lower() == "cover-image" or id:lower() == "cover_img" then
                cover_img_href = full_href
            end
        end
    end

    -- Parse <spine> <itemref idref="..."/> in order
    for itemref in opf_content:gmatch("<itemref%s+[^>]+>") do
        local idref = itemref:match('idref=["\']([^"\']+)["\']')
        if idref and manifest[idref] then
            table.insert(spine_items, manifest[idref])
            manifest_id_to_spine[idref] = #spine_items
        end
    end

    -- 3. Extract TOC mapping from NCX / Nav and build verified spine page map
    local file_to_toc_idx = self:getTocFileMapping(book_path, ncx_path, nav_path, toc_content)
    local spine_page_map, toc_entries = self:buildSpinePageMap(ui, spine_items, manifest_id_to_spine, total_pages, file_to_toc_idx)

    -- 4. Collect all image files
    local image_files = {}
    for _, f in ipairs(all_files) do
        local lower_f = f.name:lower()
        if lower_f:match("%.jpe?g$") or lower_f:match("%.png$") or lower_f:match("%.webp$") or lower_f:match("%.svg$") or lower_f:match("%.gif$") then
            table.insert(image_files, f)
        end
    end

    -- 5. Find which spine XHTML file references each image
    local image_to_spine_idx = {}
    local image_to_pos_ratio = {}
    local remaining_unmatched = #image_files

    if remaining_unmatched > 0 then
        local spine_contents = {}
        if Archiver and Archiver.Reader then
            pcall(function()
                local r = Archiver.Reader:new()
                if r:open(book_path) then
                    local spine_entry_map = {}
                    for entry in r:iterate() do
                        if entry.mode == "file" then
                            spine_entry_map[entry.path] = entry.index
                            spine_entry_map[entry.path:lower()] = entry.index
                        end
                    end
                    local spine_to_read = {}
                    for s_idx, s_href in ipairs(spine_items) do
                        local arc_idx = spine_entry_map[s_href] or spine_entry_map[s_href:lower()]
                        if arc_idx then
                            table.insert(spine_to_read, { s_idx = s_idx, s_href = s_href, arc_idx = arc_idx })
                        end
                    end
                    table.sort(spine_to_read, function(a, b) return a.arc_idx < b.arc_idx end)
                    for _, s_item in ipairs(spine_to_read) do
                        local s_lower = s_item.s_href:lower()
                        if s_lower:match("%.xhtml$") or s_lower:match("%.html$") or s_lower:match("%.htm$") or s_lower:match("%.xml$") then
                            local content = r:extractToMemory(s_item.arc_idx)
                            if content then
                                spine_contents[s_item.s_idx] = content
                            end
                        end
                    end
                    r:close()
                end
            end)
        end

        for s_idx, s_href in ipairs(spine_items) do
            if remaining_unmatched <= 0 then break end
            local s_lower = s_href:lower()
            if s_lower:match("%.xhtml$") or s_lower:match("%.html$") or s_lower:match("%.htm$") or s_lower:match("%.xml$") then
                local content = spine_contents[s_idx]
                if not content then
                    local escaped_book = book_path:gsub("'", "'\\''")
                    local cmd = string.format("unzip -p '%s' '%s'", escaped_book, s_href:gsub("'", "'\\''"))
                    local sp_pipe = io.popen(cmd)
                    if sp_pipe then
                        content = sp_pipe:read("*a") or ""
                        sp_pipe:close()
                    end
                end
                if content and #content > 0 then
                    for _, img_f in ipairs(image_files) do
                        local base_img = img_f.name:match("([^/]+)$") or img_f.name
                        if not image_to_spine_idx[img_f.name] then
                            local pos = content:find(base_img, 1, true) or content:find(img_f.name, 1, true)
                            if pos then
                                image_to_spine_idx[img_f.name] = s_idx
                                image_to_pos_ratio[img_f.name] = pos / math.max(1, #content)
                                remaining_unmatched = remaining_unmatched - 1
                                if remaining_unmatched <= 0 then break end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 6. Construct Image Objects with accurate page numbers
    for i, img_f in ipairs(image_files) do
        local fname = img_f.name
        local base_fname = (fname:match("([^/]+)$") or fname):lower()
        local title = self:generateTitleFromFilename(fname)
        local cat = self:classifyImage(title, fname)

        local s_idx = image_to_spine_idx[fname]
        local page_num = nil
        local is_resolved = false

        if fname == cover_img_href or base_fname:find("cover") or (s_idx and s_idx == 1) then
            page_num = 1
            is_resolved = true
            if not title:lower():find("cover") then title = "Cover" end
        elseif s_idx and spine_items[s_idx] then
            local s_href = spine_items[s_idx]
            local base_s = s_href:match("([^/]+)$") or s_href
            local t_idx = file_to_toc_idx[base_s]
            if t_idx and toc_entries and toc_entries[t_idx] and toc_entries[t_idx].page and toc_entries[t_idx].page > 0 then
                local start_pg = toc_entries[t_idx].page
                local next_te = toc_entries[t_idx + 1]
                local end_pg = next_te and next_te.page and next_te.page >= start_pg and next_te.page or start_pg
                local ratio = image_to_pos_ratio[fname] or 0
                page_num = start_pg + math.floor(ratio * math.max(0, end_pg - start_pg))
                page_num = math.max(1, math.min(total_pages, page_num))
                is_resolved = true
            end
        end

        if not page_num and s_idx and spine_page_map[s_idx] and spine_page_map[s_idx] > 1 then
            local base_pg = spine_page_map[s_idx]
            local next_pg = spine_page_map[s_idx + 1] or base_pg
            local span = math.max(0, next_pg - base_pg)
            page_num = base_pg + math.floor((image_to_pos_ratio[fname] or 0) * span)
            page_num = math.max(1, math.min(total_pages, page_num))
            is_resolved = true
        elseif not page_num and (cat == "map" or title:lower():find("map")) then
            -- Direct TOC match fallback for Map
            for _, te in ipairs(toc_entries) do
                local te_lower = te.title:lower()
                if (te_lower:find("map") or te_lower:find("karte") or te_lower:find("plano")) and te.page and te.page > 1 then
                    page_num = te.page
                    is_resolved = true
                    break
                end
            end
        end

        if not page_num or page_num < 1 then
            page_num = math.max(1, math.min(total_pages, math.floor(((i - 1) / math.max(1, #image_files)) * total_pages) + 1))
            is_resolved = false
        end

        local dims = image_dimensions[fname]
        local aspect_ratio = nil
        if dims and dims.w and dims.h and dims.w > 0 then
            aspect_ratio = dims.h / dims.w
        end

        table.insert(images, {
            id = self:generateImageId(fname, i),
            href = fname,
            file_size = img_f.size,
            title = title,
            category = cat,
            page = page_num,
            page_resolved = is_resolved,
            width = dims and dims.w or nil,
            height = dims and dims.h or nil,
            aspect_ratio = aspect_ratio,
        })
    end

    return images
end

-- Scan comic CBZ archive images
function ImageManager:scanCbzImages(book_path, total_pages)
    local images = {}
    local page_idx = 1

    if Archiver and Archiver.Reader then
        local ok = pcall(function()
            local r = Archiver.Reader:new()
            if not r:open(book_path) then return end
            for entry in r:iterate() do
                if entry.mode == "file" then
                    local lower_f = entry.path:lower()
                    if lower_f:match("%.jpe?g$") or lower_f:match("%.png$") or lower_f:match("%.webp$") then
                        local title = string.format("Page %d", page_idx)
                        table.insert(images, {
                            id = "cbz_" .. tostring(page_idx),
                            href = entry.path,
                            file_size = entry.size or 0,
                            title = title,
                            category = (page_idx == 1 and "illustration" or "general"),
                            page = page_idx,
                        })
                        page_idx = page_idx + 1
                    end
                end
            end
            r:close()
        end)
        if ok and #images > 0 then return images end
    end

    local escaped_book = book_path:gsub("'", "'\\''")
    local list_cmd = string.format("unzip -l '%s'", escaped_book)
    local p = io.popen(list_cmd)
    if not p then return images end
    
    page_idx = 1
    for line in p:lines() do
        local size_str, fname = line:match("^%s*(%d+)%s+[%d%-%s:]+%s+(.+)%s*$")
        if size_str and fname then
            local lower_f = fname:lower()
            if lower_f:match("%.jpe?g$") or lower_f:match("%.png$") or lower_f:match("%.webp$") then
                local title = string.format("Page %d", page_idx)
                table.insert(images, {
                    id = "cbz_" .. tostring(page_idx),
                    href = fname,
                    file_size = tonumber(size_str) or 0,
                    title = title,
                    category = (page_idx == 1 and "illustration" or "general"),
                    page = page_idx,
                })
                page_idx = page_idx + 1
            end
        end
    end
    p:close()
    return images
end

-- Convert raw filename into clean human-readable title
function ImageManager:generateTitleFromFilename(fname)
    if not fname then return "Image" end
    local base = fname:match("([^/]+)%.[%w]+$") or fname
    -- Replace underscores and hyphens with spaces
    local clean = base:gsub("[_%-]+", " ")
    -- Capitalize words
    clean = clean:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
    return clean
end

-- Clear all cached spine structures and temporary content
function ImageManager:clearSpineCache()
    self._epub_spine_cache = {}
end

return ImageManager
