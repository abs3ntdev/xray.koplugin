-- xray_book_picker.lua — Custom Book Picker dialog for KOReader X-Ray
-- Provides an intuitive directory browser for adding books to series rosters.
-- Features pure List View, Feather icons, fixed dialog sizing/centering,
-- and duplicate book validation.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local theme = require(plugin_path .. "xray_theme")

local M = {}

local function sc(val)
    if Device and Device.screen and Device.screen.scaleBySize then
        return Device.screen:scaleBySize(val)
    end
    return val
end

local function getLfs()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        ok_lfs, lfs = pcall(require, "lfs")
    end
    if ok_lfs and lfs then
        return lfs
    end
    return nil
end

local _asset_path_cache = {}
local function getAssetPath(filename)
    if _asset_path_cache[filename] then
        return _asset_path_cache[filename]
    end
    local info = debug.getinfo(1, "S")
    local file_dir = (info and info.source and info.source:match("^@?(.*[/\\])")) or ""
    local candidates = {
        file_dir .. "assets/" .. filename,
        file_dir .. "../assets/" .. filename,
        "plugins/xray.koplugin/assets/" .. filename,
        "./plugins/xray.koplugin/assets/" .. filename,
    }
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            f:close()
            _asset_path_cache[filename] = path
            return path
        end
    end
    local fallback = file_dir .. "assets/" .. filename
    _asset_path_cache[filename] = fallback
    return fallback
end

local function getTextWidth(text, face, bold)
    if not text or text == "" then return 0 end
    local tw = TextWidget:new{ text = text, face = face, bold = bold }
    local sz = tw.getSize and tw:getSize()
    if sz and sz.w then
        return sz.w
    end
    return #text * 8
end

local function truncateToWidth(text, max_w, face, bold, ellipsis)
    ellipsis = ellipsis or "..."
    if getTextWidth(text, face, bold) <= max_w then
        return text
    end
    local ellip_w = getTextWidth(ellipsis, face, bold)
    local avail_w = max_w - ellip_w
    if avail_w <= 0 then
        return ellipsis
    end

    local chars = {}
    for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        table.insert(chars, c)
    end
    if #chars == 0 then return ellipsis end

    local low = 1
    local high = #chars
    local best = 0
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local sub = table.concat(chars, "", 1, mid)
        if getTextWidth(sub, face, bold) <= avail_w then
            best = mid
            low = mid + 1
        else
            high = mid - 1
        end
    end
    if best == 0 then
        return ellipsis
    end
    return table.concat(chars, "", 1, best) .. ellipsis
end

local function formatSize(bytes)
    if not bytes or bytes <= 0 then return "0 KB" end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%d KB", math.ceil(bytes / 1024))
    end
end

local function makeTapItem(frame, callback, fallback_w, fallback_h)
    local item = InputContainer:new{ frame }
    item.dimen = Geom:new{ w = fallback_w or sc(300), h = fallback_h or sc(38) }
    item.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    return item.dimen or (frame.getSize and frame:getSize()) or Geom:new{ w = fallback_w or sc(300), h = fallback_h or sc(38) }
                end
            }
        }
    }
    item.onTap = function()
        if callback then callback() end
        return true
    end
    item.onTapSelect = function()
        if callback then callback() end
        return true
    end
    return item
end

local function createCustomBtn(opts)
    opts = opts or {}
    local is_focused = opts.is_focused == true
    local is_enabled = opts.enabled ~= false
    local btn_w = opts.width or sc(80)
    local btn_h = opts.height or sc(34)

    local hg = HorizontalGroup:new{ align = "center" }
    if opts.icon then
        local icon_sz = opts.icon_size or sc(16)
        table.insert(hg, ImageWidget:new{
            file = getAssetPath(opts.icon),
            width = icon_sz,
            height = icon_sz,
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        })
    end
    if opts.icon and opts.text then
        table.insert(hg, HorizontalSpan:new{ width = opts.gap or sc(6) })
    end
    if opts.text then
        local fg = Blitbuffer.COLOR_BLACK
        if not is_enabled then
            fg = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY
        end
        table.insert(hg, TextWidget:new{
            text = opts.text,
            face = Font:getFace("cfont", opts.text_size or 13),
            bold = opts.bold ~= false,
            fgcolor = fg,
        })
    end

    local border_sz = is_focused and sc(3) or (opts.bordersize or sc(1))
    local border_col = is_focused and Blitbuffer.COLOR_BLACK or (opts.border_color or theme.color_section_rule or Blitbuffer.COLOR_GRAY_B)
    local bg_col = is_focused and (theme.color_focus_bg or Blitbuffer.Color8(215)) or (opts.background or Blitbuffer.COLOR_WHITE)

    local frame = FrameContainer:new{
        width = btn_w,
        height = btn_h,
        padding = 0,
        bordersize = border_sz,
        color = border_col,
        background = bg_col,
        radius = opts.radius or theme.radius_btn or sc(4),
        CenterContainer:new{
            dimen = Geom:new{ w = btn_w, h = btn_h },
            hg,
        }
    }

    local cb = is_enabled and opts.callback or nil
    return makeTapItem(frame, cb, btn_w, btn_h)
end

function M.getParentPath(path)
    if not path or path == "" or path == "/" then
        return nil
    end
    local clean = tostring(path):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    if clean == "" or clean == "/" then
        return nil
    end
    local parent = clean:match("^(.-)[/\\]+[^/\\]+$")
    if not parent or parent == "" then
        if clean:match("^/[^/]+$") then
            return "/"
        elseif clean:match("^[a-zA-Z]:$") then
            return nil
        end
        return "/"
    end
    return parent
end

local SUPPORTED_EXTS = {
    epub = true,
    mobi = true,
    azw3 = true,
    fb2 = true,
    pdf = true,
}

local function getBookExt(filename)
    filename = filename:lower()
    if filename:match("%.kepub%.epub$") then
        return "kepub.epub"
    end
    local ext = filename:match("%.([^%.]+)$")
    if ext and SUPPORTED_EXTS[ext] then
        return ext
    end
    return nil
end

function M.scanDirectory(path)
    local subdirs = {}
    local books = {}
    local lfs = getLfs()

    if not lfs or not lfs.dir then
        return subdirs, books
    end

    pcall(function()
        for entry in lfs.dir(path) do
            -- Ignore '.', '..', hidden entries (starting with .), and KOReader .sdr sidecar folders
            if entry ~= "." and entry ~= ".." and not entry:match("^%.") and not entry:match("%.sdr$") then
                local full_path = (path == "/" and "/" .. entry) or (path .. "/" .. entry)
                local ok_attr, attr = pcall(lfs.attributes, full_path)
                if ok_attr and attr then
                    if attr.mode == "directory" then
                        table.insert(subdirs, {
                            name = entry,
                            path = full_path,
                            mtime = attr.modification or 0,
                        })
                    elseif attr.mode == "file" then
                        local ext = getBookExt(entry)
                        if ext then
                            table.insert(books, {
                                name = entry,
                                path = full_path,
                                size = attr.size or 0,
                                mtime = attr.modification or 0,
                                ext = ext:upper(),
                            })
                        end
                    end
                end
            end
        end
    end)

    table.sort(subdirs, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    table.sort(books, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    return subdirs, books
end

function M.getBookCoverBlitBuffer(filepath, target_w, target_h)
    return nil
end

function M.show(options)
    options = options or {}
    local current_path = options.initial_path
    local on_confirm = options.on_confirm
    local on_cancel = options.on_cancel
    local loc = options.loc or { t = function(_, k) return k end }

    if not current_path or current_path == "" then
        local ok_ds, DataStorage = pcall(require, "datastorage")
        current_path = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "/sdcard/Books"
    end
    current_path = tostring(current_path):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    -- Strip accidental .sdr path if passed
    if current_path:match("%.sdr$") then
        current_path = current_path:gsub("[/\\]+[^/\\]+%.sdr$", "")
    end
    if current_path == "" then current_path = "/" end

    local lfs = getLfs()
    if lfs and lfs.attributes then
        local ok_attr, attr = pcall(lfs.attributes, current_path)
        if not ok_attr or not attr or attr.mode ~= "directory" then
            current_path = "/"
        end
    end

    local current_page = 1
    local overlay = nil
    local refresh = nil

    -- Non-touch focus navigation state
    local function isTouchDev()
        if Device then
            if Device.isTouchDevice then return Device:isTouchDevice()
            elseif Device.isTouch then return Device:isTouch() end
        end
        return false
    end
    local is_touch = isTouchDev()
    local focus_visible = not is_touch
    local focus_row = 2
    local focus_col = 1

    local function closePicker()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_cancel then
            on_cancel()
        end
    end

    local function confirmBook(chosen_path)
        if options.is_book_in_roster and options.is_book_in_roster(chosen_path) then
            UIManager:show(InfoMessage:new{
                text = loc:t("manage_series_already_added") or "This book is already in the series roster.",
                timeout = 3,
            })
            return
        end
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_confirm then
            on_confirm(chosen_path)
        end
    end

    refresh = function()
        -- Always close previous overlay before rebuilding (eliminates duplicate/ghost dialogs)
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end

        local sw = Device.screen:getWidth()
        local sh = Device.screen:getHeight()

        -- CONSTANT DIALOG DIMENSIONS (centered, fixed height, no jumping)
        local card_padding = sc(12)
        local card_border = theme.border_window or sc(2)
        local dialog_w = math.min(sw - sc(24), sc(460))
        local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

        -- VERTICAL SLICES (mathematically exact so dialog height is strictly constant)
        local header_h = sc(32)
        local gap_sm = sc(6)
        local rule_h = sc(1)
        local path_box_h = sc(40)
        local up_item_h = sc(34)
        local footer_btn_h = sc(34)

        local items_per_page = 6
        local row_h = sc(38)
        local row_gap = sc(4)
        local row_stride = row_h + row_gap
        local content_area_h = (items_per_page * row_h) + ((items_per_page - 1) * row_gap)

        local inner_h = header_h + gap_sm + rule_h + gap_sm + path_box_h + gap_sm + up_item_h + gap_sm + content_area_h + gap_sm + rule_h + gap_sm + footer_btn_h
        local dialog_h = inner_h + (card_padding * 2) + (card_border * 2)

        local subdirs, books = M.scanDirectory(current_path)
        local parent_path = M.getParentPath(current_path)

        -- Combine items for list view
        local all_items = {}
        for _, d in ipairs(subdirs) do
            table.insert(all_items, { type = "dir", data = d })
        end
        for _, b in ipairs(books) do
            table.insert(all_items, { type = "book", data = b })
        end

        local total_items = #all_items
        local total_pages = math.max(1, math.ceil(total_items / items_per_page))
        if current_page > total_pages then current_page = total_pages end
        if current_page < 1 then current_page = 1 end

        local start_idx = (current_page - 1) * items_per_page + 1
        local end_idx = math.min(total_items, current_page * items_per_page)
        local items_on_page = (total_items > 0) and (end_idx - start_idx + 1) or 0

        -- 2D Focus grid for keyboard/D-pad navigation
        local focus_grid = {}
        local function addFocusRow(row_items)
            table.insert(focus_grid, row_items)
            return #focus_grid
        end

        -- HEADER (Title + Close button with Feather x.svg)
        local close_btn_w = sc(32)
        local r_header = addFocusRow({
            { callback = closePicker },
        })
        local is_focused_close = focus_visible and (focus_row == r_header and focus_col == 1)

        local close_btn = createCustomBtn{
            icon = "x.svg",
            icon_size = sc(22),
            is_focused = is_focused_close,
            width = close_btn_w,
            height = header_h,
            bordersize = is_focused_close and sc(3) or 0,
            border_color = is_focused_close and Blitbuffer.COLOR_BLACK or nil,
            background = is_focused_close and (theme.color_focus_bg or Blitbuffer.Color8(215)) or nil,
            callback = closePicker,
        }

        local title_text = loc:t("manage_series_choose_book") or "Choose Book to Add"
        local title_avail_w = inner_w - close_btn_w - sc(16)
        local title_truncated = truncateToWidth(title_text, title_avail_w, Font:getFace("cfont", 17), true)
        local title_label = TextWidget:new{
            text = title_truncated,
            face = Font:getFace("cfont", 17),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local title_measured_w = getTextWidth(title_truncated, Font:getFace("cfont", 17), true)
        local header_span_w = math.max(sc(6), inner_w - title_measured_w - close_btn_w)

        local header_row = HorizontalGroup:new{
            align = "center",
            title_label,
            HorizontalSpan:new{ width = header_span_w },
            close_btn,
        }

        -- PATH & SUMMARY BAR
        local path_label = TextWidget:new{
            text = truncateToWidth(current_path, inner_w - sc(20), Font:getFace("cfont", 13), true),
            face = Font:getFace("cfont", 13),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local count_text = string.format(loc:t("picker_items_count") or "%d folders, %d books", #subdirs, #books)
        local count_label = TextWidget:new{
            text = count_text,
            face = Font:getFace("cfont", 11),
            fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
        }

        local path_box = FrameContainer:new{
            padding = 0,
            radius = theme.radius_btn or sc(4),
            bordersize = 0,
            width = inner_w,
            height = path_box_h,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = path_box_h },
                HorizontalGroup:new{
                    align = "center",
                    HorizontalSpan:new{ width = sc(10) },
                    VerticalGroup:new{
                        align = "left",
                        path_label,
                        VerticalSpan:new{ width = sc(2) },
                        count_label,
                    },
                },
            },
        }

        -- PARENT DIRECTORY BUTTON (arrow-up.svg Feather icon)
        local cb_up = function()
            if parent_path then
                current_path = parent_path
                current_page = 1
                refresh()
            end
        end

        local r_up = nil
        if parent_path then
            r_up = addFocusRow({ { callback = cb_up } })
        end
        local is_focused_up = focus_visible and r_up and (focus_row == r_up and focus_col == 1)
        local parent_display = parent_path and (parent_path:match("([^/\\]+)$") or "/") or nil

        local up_item = createCustomBtn{
            icon = "arrow-up.svg",
            icon_size = sc(16),
            text = parent_display and string.format("..  (%s)", parent_display) or "..  (root)",
            text_size = 13,
            bold = true,
            enabled = (parent_path ~= nil),
            is_focused = is_focused_up,
            width = inner_w,
            height = up_item_h,
            bordersize = is_focused_up and sc(3) or sc(1),
            border_color = is_focused_up and Blitbuffer.COLOR_BLACK or (theme.color_section_rule or Blitbuffer.COLOR_GRAY_B),
            callback = cb_up,
        }

        -- CONTENT ITEMS (List View)
        local content_list = VerticalGroup:new{ align = "left" }

        if total_items == 0 then
            local empty_label = TextWidget:new{
                text = loc:t("picker_no_books_found") or "No ebook files found in this folder.",
                face = Font:getFace("cfont", 14),
                fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
            }
            table.insert(content_list, CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = content_area_h },
                empty_label,
            })
        else
            for i = start_idx, end_idx do
                local it = all_items[i]
                local target_path = it.data.path
                local is_dir = (it.type == "dir")
                local is_already_added = not is_dir and options.is_book_in_roster and options.is_book_in_roster(target_path)

                local onSelect = function()
                    if is_dir then
                        current_path = target_path
                        current_page = 1
                        refresh()
                    elseif is_already_added then
                        UIManager:show(InfoMessage:new{
                            text = loc:t("manage_series_already_added") or "This book is already in the series roster.",
                            timeout = 3,
                        })
                    else
                        confirmBook(target_path)
                    end
                end

                local r_item = addFocusRow({ { callback = onSelect } })
                local is_row_focused = focus_visible and (focus_row == r_item and focus_col == 1)

                local row_content_hg
                if is_dir then
                    local icon_widget = ImageWidget:new{
                        file = getAssetPath("folder.svg"),
                        width = sc(18),
                        height = sc(18),
                        scale_factor = 0,
                        is_icon = true,
                        alpha = true,
                    }
                    local arrow_widget = ImageWidget:new{
                        file = getAssetPath("chevron-right.svg"),
                        width = sc(16),
                        height = sc(16),
                        scale_factor = 0,
                        is_icon = true,
                        alpha = true,
                    }
                    local max_name_w = inner_w - sc(80)
                    local dir_name = TextWidget:new{
                        text = truncateToWidth(it.data.name or "", max_name_w, Font:getFace("cfont", 14), true),
                        face = Font:getFace("cfont", 14),
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                    local name_w = dir_name:getSize().w
                    local flex_w = math.max(sc(8), inner_w - sc(18) - sc(10) - name_w - sc(16) - sc(30))
                    row_content_hg = HorizontalGroup:new{
                        align = "center",
                        HorizontalSpan:new{ width = sc(10) },
                        icon_widget,
                        HorizontalSpan:new{ width = sc(10) },
                        dir_name,
                        HorizontalSpan:new{ width = flex_w },
                        arrow_widget,
                        HorizontalSpan:new{ width = sc(10) },
                    }
                else
                    local icon_widget = ImageWidget:new{
                        file = getAssetPath("book.svg"),
                        width = sc(18),
                        height = sc(18),
                        scale_factor = 0,
                        is_icon = true,
                        alpha = true,
                    }
                    local clean_title = (it.data.name or ""):gsub("%.[^%.]+$", "")

                    local right_group = HorizontalGroup:new{ align = "center" }
                    if is_already_added then
                        local check_icon = ImageWidget:new{
                            file = getAssetPath("check.svg"),
                            width = sc(14),
                            height = sc(14),
                            scale_factor = 0,
                            is_icon = true,
                            alpha = true,
                        }
                        local added_lbl = TextWidget:new{
                            text = "[ADDED]",
                            face = Font:getFace("cfont", 11),
                            bold = true,
                            fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
                        }
                        table.insert(right_group, check_icon)
                        table.insert(right_group, HorizontalSpan:new{ width = sc(4) })
                        table.insert(right_group, added_lbl)
                    else
                        local ext_tag = TextWidget:new{
                            text = string.format("[%s]", it.data.ext or "BOOK"),
                            face = Font:getFace("cfont", 11),
                            bold = true,
                            fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
                        }
                        local size_tag = TextWidget:new{
                            text = formatSize(it.data.size),
                            face = Font:getFace("cfont", 11),
                            fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
                        }
                        table.insert(right_group, ext_tag)
                        table.insert(right_group, HorizontalSpan:new{ width = sc(6) })
                        table.insert(right_group, size_tag)
                    end

                    local right_w = right_group:getSize().w
                    local max_title_w = math.max(sc(100), inner_w - sc(18) - sc(10) - right_w - sc(36))
                    local book_title = TextWidget:new{
                        text = truncateToWidth(clean_title, max_title_w, Font:getFace("cfont", 14), false),
                        face = Font:getFace("cfont", 14),
                        fgcolor = is_already_added and (theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY) or Blitbuffer.COLOR_BLACK,
                    }
                    local title_w = book_title:getSize().w
                    local flex_w = math.max(sc(8), inner_w - sc(18) - sc(10) - title_w - right_w - sc(30))

                    row_content_hg = HorizontalGroup:new{
                        align = "center",
                        HorizontalSpan:new{ width = sc(10) },
                        icon_widget,
                        HorizontalSpan:new{ width = sc(10) },
                        book_title,
                        HorizontalSpan:new{ width = flex_w },
                        right_group,
                        HorizontalSpan:new{ width = sc(10) },
                    }
                end

                local border_sz = is_row_focused and sc(3) or sc(1)
                local border_col = is_row_focused and Blitbuffer.COLOR_BLACK or (theme.color_section_rule or Blitbuffer.COLOR_GRAY_B)
                local bg_col = is_row_focused and (theme.color_focus_bg or Blitbuffer.Color8(215)) or (is_already_added and Blitbuffer.Color8(245) or Blitbuffer.COLOR_WHITE)

                local row_frame = FrameContainer:new{
                    bordersize = border_sz,
                    color = border_col,
                    padding = 0,
                    radius = theme.radius_btn or sc(4),
                    background = bg_col,
                    width = inner_w,
                    height = row_h,
                    CenterContainer:new{
                        dimen = Geom:new{ w = inner_w, h = row_h },
                        row_content_hg,
                    }
                }

                local tap_row = makeTapItem(row_frame, onSelect, inner_w, row_h)
                table.insert(content_list, tap_row)
                if i < end_idx then
                    table.insert(content_list, VerticalSpan:new{ width = row_gap })
                end
            end

            -- Pad remaining height so content_list ALWAYS occupies content_area_h exactly
            local used_h = (items_on_page * row_h) + math.max(0, items_on_page - 1) * row_gap
            local remaining_h = content_area_h - used_h
            if remaining_h > 0 then
                table.insert(content_list, VerticalSpan:new{ width = remaining_h })
            end
        end

        -- FOOTER PAGINATION & ACTIONS (Feather chevron-left.svg, chevron-right.svg, x.svg)
        local cb_prev = function()
            if current_page > 1 then
                current_page = current_page - 1
                refresh()
            end
        end
        local cb_next = function()
            if current_page < total_pages then
                current_page = current_page + 1
                refresh()
            end
        end
        local cb_cancel = function()
            closePicker()
        end

        local r_footer = addFocusRow({
            { callback = cb_prev },
            { callback = cb_next },
            { callback = cb_cancel },
        })

        local is_focused_prev   = focus_visible and (focus_row == r_footer and focus_col == 1)
        local is_focused_next   = focus_visible and (focus_row == r_footer and focus_col == 2)
        local is_focused_cancel = focus_visible and (focus_row == r_footer and focus_col == 3)

        local prev_btn_w = sc(80)
        local next_btn_w = sc(80)
        local page_container_w = sc(64)
        local cancel_btn_w = sc(84)

        local prev_btn = createCustomBtn{
            icon = "chevron-left.svg",
            icon_size = sc(14),
            text = "Prev",
            text_size = 13,
            bold = true,
            enabled = (current_page > 1),
            is_focused = is_focused_prev,
            width = prev_btn_w,
            height = footer_btn_h,
            bordersize = is_focused_prev and sc(3) or sc(1),
            border_color = is_focused_prev and Blitbuffer.COLOR_BLACK or (theme.color_section_rule or Blitbuffer.COLOR_GRAY_B),
            callback = cb_prev,
        }

        local next_btn = createCustomBtn{
            text = "Next",
            icon = "chevron-right.svg",
            icon_size = sc(14),
            text_size = 13,
            bold = true,
            enabled = (current_page < total_pages),
            is_focused = is_focused_next,
            width = next_btn_w,
            height = footer_btn_h,
            bordersize = is_focused_next and sc(3) or sc(1),
            border_color = is_focused_next and Blitbuffer.COLOR_BLACK or (theme.color_section_rule or Blitbuffer.COLOR_GRAY_B),
            callback = cb_next,
        }

        local page_str = string.format("%d / %d", current_page, total_pages)
        local page_label = TextWidget:new{
            text = page_str,
            face = Font:getFace("cfont", 12),
            bold = true,
            fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
        }
        local page_container = CenterContainer:new{
            dimen = Geom:new{ w = page_container_w, h = footer_btn_h },
            page_label,
        }

        local cancel_btn = createCustomBtn{
            icon = "x.svg",
            icon_size = sc(14),
            text = loc:t("cancel") or "Cancel",
            text_size = 13,
            bold = true,
            is_focused = is_focused_cancel,
            width = cancel_btn_w,
            height = footer_btn_h,
            bordersize = is_focused_cancel and sc(3) or sc(1),
            border_color = is_focused_cancel and Blitbuffer.COLOR_BLACK or (theme.color_section_rule or Blitbuffer.COLOR_GRAY_B),
            callback = cb_cancel,
        }

        local footer_span_w = math.max(sc(8), inner_w - prev_btn_w - page_container_w - next_btn_w - cancel_btn_w - sc(16))
        local footer_row = HorizontalGroup:new{
            align = "center",
            prev_btn,
            HorizontalSpan:new{ width = sc(6) },
            page_container,
            HorizontalSpan:new{ width = sc(6) },
            next_btn,
            HorizontalSpan:new{ width = footer_span_w },
            cancel_btn,
        }

        -- ASSEMBLE DIALOG (Exact height match, perfectly centered)
        local main_vg = VerticalGroup:new{
            align = "left",
            header_row,
            VerticalSpan:new{ width = gap_sm },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = rule_h },
                background = theme.color_section_rule or Blitbuffer.COLOR_GRAY_B,
            },
            VerticalSpan:new{ width = gap_sm },
            path_box,
            VerticalSpan:new{ width = gap_sm },
            up_item,
            VerticalSpan:new{ width = gap_sm },
            content_list,
            VerticalSpan:new{ width = gap_sm },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = rule_h },
                background = theme.color_section_rule or Blitbuffer.COLOR_GRAY_B,
            },
            VerticalSpan:new{ width = gap_sm },
            footer_row,
        }

        local card = FrameContainer:new{
            bordersize = card_border,
            color = theme.color_border or Blitbuffer.COLOR_BLACK,
            radius = theme.radius_window or sc(4),
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            padding = card_padding,
            width = dialog_w,
            height = dialog_h,
            main_vg,
        }

        -- Clamp focus indices to valid ranges in newly constructed grid
        if focus_row > #focus_grid then focus_row = #focus_grid end
        if focus_row < 1 then focus_row = 1 end
        local max_c = (focus_grid[focus_row] and #focus_grid[focus_row]) or 1
        if focus_col > max_c then focus_col = max_c end
        if focus_col < 1 then focus_col = 1 end

        local key_events = {
            Close      = { { "Back" }, { "Escape" }, { "q" }, { "Q" } },
            FocusUp    = { { "Up" } },
            FocusDown  = { { "Down" } },
            FocusLeft  = { { "Left" } },
            FocusRight = { { "Right" } },
            Select     = { { "Return" }, { "KP_Enter" }, { "Select" }, { "Press" }, { "Space" } },
            PrevPage   = { { "PageUp" }, { "PgUp" }, { "Prev" }, { "LPgBack" }, { "RPgBack" } },
            NextPage   = { { "PageDown" }, { "PgDn" }, { "Next" }, { "LPgFwd" }, { "RPgFwd" } },
        }
        local Device_input = Device and Device.input
        if Device_input and Device_input.group then
            if Device_input.group.PgFwd  then table.insert(key_events.NextPage,  { Device_input.group.PgFwd  }) end
            if Device_input.group.PgBack then table.insert(key_events.PrevPage,  { Device_input.group.PgBack }) end
            if Device_input.group.Back   then table.insert(key_events.Close,     { Device_input.group.Back   }) end
            if Device_input.group.Up     then table.insert(key_events.FocusUp,   { Device_input.group.Up     }) end
            if Device_input.group.Down   then table.insert(key_events.FocusDown, { Device_input.group.Down   }) end
            if Device_input.group.Left   then table.insert(key_events.FocusLeft, { Device_input.group.Left   }) end
            if Device_input.group.Right  then table.insert(key_events.FocusRight,{ Device_input.group.Right  }) end
            if Device_input.group.Enter  then table.insert(key_events.Select,    { Device_input.group.Enter  }) end
            if Device_input.group.Press  then table.insert(key_events.Select,    { Device_input.group.Press  }) end
        end

        overlay = InputContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            key_events = key_events,
            ges_events = {
                Swipe = {
                    GestureRange:new{
                        ges = "swipe",
                        range = function() return Geom:new{ w = sw, h = sh } end,
                    }
                }
            },
            CenterContainer:new{
                dimen = Geom:new{ w = sw, h = sh },
                card,
            },
        }

        overlay.onClose = function()
            closePicker()
            return true
        end
        overlay.onNextPage = function()
            if current_page < total_pages then
                current_page = current_page + 1
                refresh()
                return true
            end
        end
        overlay.onPrevPage = function()
            if current_page > 1 then
                current_page = current_page - 1
                refresh()
                return true
            end
        end
        overlay.onSwipe = function(self, arg, ges)
            if ges and (ges.direction == "west" or ges.direction == "south") then
                if current_page < total_pages then
                    current_page = current_page + 1
                    refresh()
                    return true
                end
            elseif ges and (ges.direction == "east" or ges.direction == "north") then
                if current_page > 1 then
                    current_page = current_page - 1
                    refresh()
                    return true
                end
            end
        end
        overlay.onFocusUp = function()
            focus_visible = true
            if focus_row > 1 then
                focus_row = focus_row - 1
            else
                focus_row = #focus_grid
            end
            local mc = (focus_grid[focus_row] and #focus_grid[focus_row]) or 1
            if focus_col > mc then focus_col = mc end
            refresh()
            return true
        end
        overlay.onFocusDown = function()
            focus_visible = true
            if focus_row < #focus_grid then
                focus_row = focus_row + 1
            else
                focus_row = 1
            end
            local mc = (focus_grid[focus_row] and #focus_grid[focus_row]) or 1
            if focus_col > mc then focus_col = mc end
            refresh()
            return true
        end
        overlay.onFocusLeft = function()
            focus_visible = true
            if focus_col > 1 then
                focus_col = focus_col - 1
            else
                if current_page > 1 then
                    current_page = current_page - 1
                    refresh()
                    return true
                end
                focus_col = (focus_grid[focus_row] and #focus_grid[focus_row]) or 1
            end
            refresh()
            return true
        end
        overlay.onFocusRight = function()
            focus_visible = true
            local mc = (focus_grid[focus_row] and #focus_grid[focus_row]) or 1
            if focus_col < mc then
                focus_col = focus_col + 1
            else
                if current_page < total_pages then
                    current_page = current_page + 1
                    focus_col = 1
                    refresh()
                    return true
                end
                focus_col = 1
            end
            refresh()
            return true
        end
        overlay.onSelect = function()
            local item = focus_grid[focus_row] and focus_grid[focus_row][focus_col]
            if item and item.callback then
                item.callback()
            end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

return M
