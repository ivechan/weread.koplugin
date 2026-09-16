-- Chapter catalog styled consistently with the book detail page.
--
-- The catalog is virtualized: only the visible window of chapter rows is
-- materialized (see weread/ui/virtual_list.lua). A book with thousands of
-- chapters therefore allocates one screen of widgets, not thousands, and each
-- scroll repaints only that window. Quick locate (current chapter, chapter
-- number, title search) jumps the window directly without building the rows in
-- between.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen
local FocusNav = require("weread.ui.focus_nav")
local PluginUtil = require("weread.lib.plugin_util")
local VirtualList = require("weread.ui.virtual_list")
local _ = PluginUtil.tr
local T = PluginUtil.T

local ChapterRow = InputContainer:extend{
    text = "",
    status = "",
    width = nil,
    callback = nil,
    show_parent = nil,
}

function ChapterRow:init()
    local padding = Size.padding.large
    local inner_width = self.width - 2 * padding
    local face = Font:getFace("cfont", 20)
    local right = TextWidget:new{ text = self.status, face = face }
    local right_width = right:getSize().w
    local gap = Size.padding.large
    local left = TextWidget:new{
        text = self.text,
        face = face,
        max_width = math.max(1, inner_width - right_width - gap),
    }
    gap = math.max(gap, inner_width - left:getSize().w - right_width)
    self.frame = FrameContainer:new{
        bordersize = 0, radius = 0, margin = 0,
        padding_left = padding, padding_right = padding,
        padding_top = Size.padding.large,
        padding_bottom = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        HorizontalGroup:new{
            align = "center",
            left,
            HorizontalSpan:new{ width = gap },
            right,
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapChapterRow = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function ChapterRow:onTapChapterRow()
    if not self.callback then return true end
    self.frame.invert = true
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:forceRePaint()
    self.frame.invert = false
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:setDirty(nil, "fast", self.frame.dimen)
    self.callback()
    return true
end

function ChapterRow:onFocus()
    self.frame.invert = true
    return true
end

function ChapterRow:onUnfocus()
    self.frame.invert = false
    return true
end

local ChapterListView = FocusManager:extend{
    title = nil,
    chapters = nil,
    current_index = nil,
    status_of = nil,
    on_refresh = nil,
    on_select_download = nil,
    on_select = nil,
    on_close = nil,
}

function ChapterListView:toolbar()
    local third = math.floor(self.screen_w / 3)
    local refresh_button = Button:new{
        text = _("↻ Refresh"),
        width = third,
        radius = 0, margin = 0,
        bordersize = Size.border.thin,
        text_font_size = 18,
        text_font_bold = false,
        show_parent = self,
        callback = function() if self.on_refresh then self.on_refresh() end end,
    }
    local select_button = Button:new{
        text = _("✓ Select"),
        width = third,
        radius = 0, margin = 0,
        bordersize = Size.border.thin,
        text_font_size = 18,
        text_font_bold = false,
        show_parent = self,
        callback = function()
            if self.on_select_download then self.on_select_download() end
        end,
    }
    local locate_button = Button:new{
        text = _("⌖ Locate"),
        width = self.screen_w - third * 2,
        radius = 0, margin = 0,
        bordersize = Size.border.thin,
        text_font_size = 18,
        text_font_bold = false,
        show_parent = self,
        callback = function() self:locate() end,
    }
    self._toolbar_buttons = { refresh_button, select_button, locate_button }
    return HorizontalGroup:new{ refresh_button, select_button, locate_button }
end

-- Map a focus-layout row (1 = toolbar, 2.. = visible chapters) to a chapter.
function ChapterListView:globalFromLocal(y)
    return self.virtual:windowFirst() + (y - 2)
end

function ChapterListView:rebuildLayout(focus_global)
    local rows = { self._toolbar_buttons }
    for _i, row in ipairs(self.virtual:materializedRows()) do
        rows[#rows + 1] = { row }
    end
    self.layout = rows
    if focus_global and #rows > 1 then
        local local_y = focus_global - self.virtual:windowFirst() + 2
        local_y = math.max(2, math.min(local_y, #rows))
        self.selected = { x = 1, y = local_y }
        local item = rows[local_y][1]
        if item and item.handleEvent then item:handleEvent(Event:new("Focus")) end
    elseif not self.selected then
        self.selected = { x = 1, y = 1 }
    end
    UIManager:setDirty(self, "fast")
end

-- Rebuild the focus layout after a touch scroll changed the materialized
-- window, keeping the cursor on the same chapter when it is still visible.
function ChapterListView:syncLayout()
    local focus_global
    if self.selected and self.selected.y and self.selected.y >= 2 then
        focus_global = self:globalFromLocal(self.selected.y)
    end
    local rows = { self._toolbar_buttons }
    for _i, row in ipairs(self.virtual:materializedRows()) do
        rows[#rows + 1] = { row }
    end
    self.layout = rows
    local y = self.selected and self.selected.y or 1
    if focus_global then
        y = focus_global - self.virtual:windowFirst() + 2
    end
    self.selected = { x = 1, y = math.max(1, math.min(y, #rows)) }
end

function ChapterListView:onFocusMove(args)
    if not self.layout then return false end
    local dy = args[2]
    if dy == 0 or not self.selected or self.selected.y < 2 then
        return FocusManager.onFocusMove(self, args)
    end
    local total = #self.entries
    if total == 0 then return true end
    local global = self:globalFromLocal(self.selected.y)
    -- Top of the list: hand off to the toolbar above.
    if dy < 0 and global <= 1 then
        return FocusManager.onFocusMove(self, args)
    end
    -- Bottom of the list: stop instead of wrapping back to the toolbar.
    if dy > 0 and global >= total then
        return true
    end
    local target = global + dy
    if target >= self.virtual:windowFirst() and target <= self.virtual:windowLast() then
        return FocusManager.onFocusMove(self, args)
    end
    self.virtual:scrollToIndex(target, dy > 0 and "bottom" or "top")
    self:rebuildLayout(target)
    return true
end

function ChapterListView:onNextPage()
    if #self.entries == 0 then return true end
    local step = self.virtual:pageRows()
    local global = (self.selected and self.selected.y >= 2)
        and self:globalFromLocal(self.selected.y) or self.virtual:windowFirst()
    local target = math.min(#self.entries, global + step)
    self.virtual:scrollToIndex(target, "top")
    self:rebuildLayout(target)
    return true
end

function ChapterListView:onPrevPage()
    if #self.entries == 0 then return true end
    local step = self.virtual:pageRows()
    local global = (self.selected and self.selected.y >= 2)
        and self:globalFromLocal(self.selected.y) or self.virtual:windowFirst()
    local target = math.max(1, global - step)
    self.virtual:scrollToIndex(target, "top")
    self:rebuildLayout(target)
    return true
end

function ChapterListView:jumpTo(index)
    local total = #self.entries
    if total == 0 then return end
    index = math.max(1, math.min(index, total))
    self.virtual:scrollToIndex(index, "center")
    self:rebuildLayout(index)
    return index
end

function ChapterListView:promptChapterNumber()
    local dialog
    dialog = InputDialog:new{
        title = T(_("Go to chapter (1-%1)"), tostring(#self.entries)),
        input = "",
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Go"),
                    is_enter_default = true,
                    callback = function()
                        local value = tonumber(dialog:getInputText())
                        UIManager:close(dialog)
                        if value then self:jumpTo(math.floor(value)) end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function ChapterListView:showSearchResults(keyword)
    if not keyword or keyword == "" then return end
    local needle = keyword:lower()
    local items = {}
    local menu
    for _i, entry in ipairs(self.entries) do
        local title = entry.title or ""
        if title:lower():find(needle, 1, true) then
            items[#items + 1] = {
                text = title,
                mandatory = tostring(entry.index),
                callback = function()
                    if menu then UIManager:close(menu) end
                    self:jumpTo(entry.index)
                end,
            }
        end
    end
    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No matching chapters.") })
        return
    end
    menu = Menu:new{
        title = T(_("Search: %1"), keyword),
        item_table = items,
        is_borderless = true,
        title_bar_fm_style = true,
    }
    UIManager:show(menu)
end

function ChapterListView:promptChapterSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Search chapter title"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local keyword = dialog:getInputText()
                        UIManager:close(dialog)
                        self:showSearchResults(keyword)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function ChapterListView:locate()
    local dialog
    local buttons = {}
    if self.current_index then
        buttons[#buttons + 1] = {
            {
                text = _("Jump to current chapter"),
                callback = function()
                    UIManager:close(dialog)
                    self:jumpTo(self.current_index)
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = _("Go to chapter number"),
            callback = function()
                UIManager:close(dialog)
                self:promptChapterNumber()
            end,
        },
    }
    buttons[#buttons + 1] = {
        {
            text = _("Search chapter title"),
            callback = function()
                UIManager:close(dialog)
                self:promptChapterSearch()
            end,
        },
    }
    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            id = "close",
            callback = function() UIManager:close(dialog) end,
        },
    }
    dialog = ButtonDialog:new{
        title = _("Locate chapter"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function ChapterListView:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.list_width = self.screen_w - 3 * Screen:scaleBySize(6)
    self.covers_fullscreen = true
    self.entries = self.chapters or {}
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = self.title or _("Chapter list"),
        title_face = Font:getFace("tfont", 28),
        title_multilines = true,
        align = "center",
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local toolbar = self:toolbar()
    local probe = ChapterRow:new{ text = "", status = "", width = self.list_width }
    local row_height = math.max(1, probe.dimen.h)
    probe:free()
    local scroll_h = self.screen_h - self.title_bar:getHeight() - toolbar:getSize().h
    self.virtual = VirtualList:new{
        entries = self.entries,
        row_height = row_height,
        viewport_h = scroll_h,
        overscan = 2,
        dimen = Geom:new{ w = self.screen_w, h = scroll_h },
        show_parent = self,
        build_row = function(entry, index)
            return ChapterRow:new{
                text = entry.title,
                status = self.status_of and self.status_of(entry) or entry.status or "",
                width = self.list_width,
                show_parent = self,
                callback = function()
                    if self.on_select then self.on_select(entry.source) end
                end,
            }
        end,
    }
    self.virtual.on_window_changed = function() self:syncLayout() end
    local initial_global = self.current_index
    if initial_global then
        self.virtual:scrollToIndex(initial_global, "center")
    end
    self:rebuildLayout(initial_global or 1)
    FocusNav.apply(self, self.layout, { scroll = self.virtual })
    -- FocusNav's wrapper calls its own scroll-into-view math, which assumes
    -- every row is materialized; the virtual list owns scrolling instead.
    self.onFocusMove = ChapterListView.onFocusMove
    self.onNextPage = ChapterListView.onNextPage
    self.onPrevPage = ChapterListView.onPrevPage
    FocusNav.initialFocus(self, 1, self.selected and self.selected.y or 1)
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{ align = "left", self.title_bar, toolbar, self.virtual },
    }
end

function ChapterListView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function ChapterListView:onCloseWidget()
    if self.virtual then self.virtual:free() end
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function ChapterListView:onClose()
    UIManager:close(self)
    if self.on_close then
        UIManager:scheduleIn(0.1, self.on_close)
    end
    return true
end

local M = {}
function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = ChapterListView:new{
        title = data.title,
        chapters = data.chapters,
        current_index = data.current_index,
        status_of = data.status_of,
        on_refresh = callbacks.on_refresh,
        on_select_download = callbacks.on_select_download,
        on_select = callbacks.on_select,
        on_close = callbacks.on_close,
    }
    UIManager:show(view)
    return view
end

return M
