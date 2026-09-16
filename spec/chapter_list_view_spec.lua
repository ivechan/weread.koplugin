-- Virtualized chapter catalog tests: a 4000-chapter book must materialize one
-- viewport of rows, resolve status lazily, and jump/window correctly for focus
-- paging and quick locate. Uses inert widget fakes; visual and memory
-- behaviour still needs verification on KOReader/e-ink hardware.

package.path = "./?.lua;" .. package.path

local Widget = {}
function Widget:extend(args) return setmetatable(args or {}, { __index = self }) end
function Widget:new(args)
    local widget = self:extend(args)
    if widget.init then widget:init() end
    return widget
end
function Widget:getSize()
    if self.dimen then return self.dimen end
    if self.kind == "text" then
        return { w = self.max_width or (#(self.text or "") * 8), h = 20 }
    end
    if self.kind == "button" then
        return { w = self.width, h = self.height or 40 }
    end
    if self.kind == "hspan" then return { w = self.width, h = 0 } end
    if self.kind == "vspan" then return { w = 0, h = self.width } end
    if self.kind == "line" then return { w = self.dimen.w, h = self.dimen.h } end
    if self.kind == "title" then return { w = self.width or 600, h = 80 } end
    local group = self.kind == "horizontal" or self.kind == "vertical"
    if group and self._size then return self._size end
    local w, h = 0, 0
    for _i, child in ipairs(self) do
        local size = child:getSize()
        if self.kind == "horizontal" then
            w, h = w + size.w, math.max(h, size.h)
        elseif self.kind == "vertical" then
            w, h = math.max(w, size.w), h + size.h
        else
            w, h = math.max(w, size.w), math.max(h, size.h)
        end
    end
    local padding = self.padding or 0
    local size = { w = w + 2 * padding, h = h + 2 * padding }
    if group then self._size = size end
    return size
end
function Widget:getHeight() return self:getSize().h end
function Widget:resetLayout() self._size, self._offsets = nil, {} end
function Widget:free()
    if self._freed then return end
    self._freed = true
    for _i, child in ipairs(self) do child:free() end
end

for name, kind in pairs({
    ["container/inputcontainer"] = "input",
    ["container/framecontainer"] = "frame",
    ["horizontalgroup"] = "horizontal",
    ["verticalgroup"] = "vertical",
    ["horizontalspan"] = "hspan",
    ["verticalspan"] = "vspan",
    ["linewidget"] = "line",
    ["textwidget"] = "text",
    ["titlebar"] = "title",
    ["button"] = "button",
}) do
    local module_kind = kind
    package.preload["ui/widget/" .. name] = function()
        return Widget:extend{ kind = module_kind }
    end
end

local ScrollableContainer = Widget:extend{ _scroll_offset_y = 0 }
function ScrollableContainer:init()
    self.ges_events, self.key_events = {}, {}
    self._scroll_offset_y = self._scroll_offset_y or 0
end
function ScrollableContainer:_scrollBy(_dx, dy)
    local content_h = self[1] and self[1]:getSize().h or 0
    local max = math.max(0, content_h - self.dimen.h)
    self._scroll_offset_y = math.max(0, math.min(self._scroll_offset_y + dy, max))
end
function ScrollableContainer:_updateScrollBars() end
function ScrollableContainer:onCloseWidget() end
package.preload["ui/widget/container/scrollablecontainer"] = function()
    return ScrollableContainer
end

local FocusManager = Widget:extend{
    FOCUS_ONLY_ON_NT = 0, NOT_UNFOCUS = 1, NOT_FOCUS = 2, FORCED_FOCUS = 4,
}
function FocusManager:onFocusMove(args)
    local y = self.selected.y + args[2]
    if y >= 1 and y <= #self.layout then self.selected.y = y end
    return true
end
function FocusManager:moveFocusTo(x, y)
    self.selected = { x = x, y = y }
end
function FocusManager:getFocusItem()
    local row = self.layout[self.selected.y]
    return row and row[self.selected.x] or nil
end
package.preload["ui/widget/focusmanager"] = function() return FocusManager end

package.preload["ui/event"] = function()
    return { new = function(_self, name) return { name = name } end }
end
package.preload["ui/gesturerange"] = function()
    return { new = function(args) return args end }
end
package.preload["ui/geometry"] = function()
    local Geom = {}
    function Geom:new(t)
        t = t or {}
        return setmetatable(t, { __index = Geom })
    end
    function Geom:copy() return Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h } end
    return Geom
end
package.preload["ui/font"] = function()
    return { getFace = function() return {} end }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1, COLOR_GRAY = 2,
        COLOR_LIGHT_GRAY = 3, COLOR_DARK_GRAY = 4 }
end
package.preload["ui/size"] = function()
    return { padding = { large = 10, small = 5 }, border = { thin = 1 } }
end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_, n) return n end,
        },
        hasKeys = function() return false end,
        input = { group = { Back = "Back", PgFwd = "PgFwd", PgBack = "PgBack" } },
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(args) return args end }
end
package.preload["ui/widget/inputdialog"] = function()
    local InputDialog = {}
    function InputDialog:new(args)
        args = args or {}
        args.getInputText = function() return args._input or "" end
        _G.__last_inputdialog = args
        return args
    end
    return InputDialog
end
package.preload["ui/widget/buttondialog"] = function()
    local ButtonDialog = {}
    function ButtonDialog:new(args) _G.__last_buttondialog = args; return args end
    return ButtonDialog
end
package.preload["ui/widget/menu"] = function()
    local Menu = {}
    function Menu:new(args) _G.__last_menu = args; return args end
    return Menu
end
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function() end,
        show = function(_, widget) return widget end,
        close = function() end,
        scheduleIn = function(_, _delay, callback) callback() end,
        widgetRepaint = function() end,
        forceRePaint = function() end,
    }
end
package.preload["weread.ui.focus_nav"] = function()
    return {
        apply = function(view, rows)
            view.layout = rows
            view.key_events = view.key_events or {}
            view.key_events.NextPage = { { "PgFwd" } }
            view.key_events.PrevPage = { { "PgBack" } }
            view.onFocusMove = function() return "focusnav-wrapper" end
        end,
        initialFocus = function(view, x, y)
            y = math.max(1, math.min(y or 1, #view.layout))
            view.selected = { x = x or 1, y = y }
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end

local ChapterListView = require("weread.ui.chapter_list_view")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local TOTAL = 4000
local entries = {}
for index = 1, TOTAL do
    entries[index] = {
        title = "Chapter " .. index,
        source = { chapterUid = index, title = "Chapter " .. index, wordCount = index },
        index = index,
    }
end

local function make_view(current_index, callbacks)
    local calls = 0
    local view = ChapterListView.show({
        title = "Fixture",
        chapters = entries,
        current_index = current_index,
        status_of = function(entry) calls = calls + 1; return entry.index .. " words" end,
    }, callbacks or {})
    return view, function() return calls end
end

-- A 4000-chapter catalog materializes one window of rows.
local view, status_calls = make_view()
local window_count = view.virtual:windowCount()
expect(#view.entries == TOTAL, "all chapters are available to the view")
expect(#view.virtual:materializedRows() == window_count,
    "only one window of rows is materialized")
expect(window_count < 60, "the window is a small constant")
expect(status_calls() == window_count,
    "status is resolved only for materialized rows")
expect(#view.layout == window_count + 1,
    "the focus layout holds the toolbar plus the visible rows")
expect(view.selected and view.selected.y >= 1, "an initial focus position is set")

-- Selecting a row forwards the underlying chapter.
local selected_chapter
local select_view = make_view(nil, {
    on_select = function(chapter) selected_chapter = chapter end,
})
select_view.virtual:materializedRows()[1].callback()
expect(selected_chapter == entries[1].source, "a row callback forwards its chapter")

-- Jumping to the middle rebuilds at most one window and resolves no more status
-- than the window needs.
view, status_calls = make_view()
local calls_after_open = status_calls()
view:jumpTo(2000)
expect(view.virtual:windowFirst() <= 2000 and view.virtual:windowLast() >= 2000,
    "jumpTo brings the requested chapter into view")
expect(#view.virtual:materializedRows() <= window_count,
    "jumpTo keeps the materialized rows bounded")
expect(status_calls() - calls_after_open <= window_count,
    "jumpTo resolves status for at most one more window")
expect(status_calls() < TOTAL, "status is never resolved for the whole catalog")

-- Opening at the current chapter centers it.
view, status_calls = make_view(3000)
expect(view.virtual:windowFirst() <= 3000 and view.virtual:windowLast() >= 3000,
    "the catalog opens at the current chapter")
expect(status_calls() < TOTAL, "opening at the current chapter stays lazy")

-- Focus paging moves the window by one viewport.
view = make_view()
local first_before = view.virtual:windowFirst()
view.selected = { x = 1, y = 2 }
view:onNextPage()
expect(view.virtual:windowFirst() > first_before, "onNextPage advances the window")
view:onPrevPage()
expect(view.virtual:windowFirst() <= first_before, "onPrevPage moves the window back")

-- Focus at a window edge scrolls instead of losing the cursor.
view = make_view()
view:jumpTo(2000)
local wf = view.virtual:windowFirst()
view.selected = { x = 1, y = 2 }
view:onFocusMove({ 0, -1 })
expect(view.virtual:windowFirst() < wf, "focus above the window edge scrolls up")
local wl = view.virtual:windowLast()
view.selected = { x = 1, y = #view.layout }
view:onFocusMove({ 0, 1 })
expect(view.virtual:windowLast() > wl, "focus below the window edge scrolls down")

-- The cursor stops at the last chapter instead of wrapping to the toolbar.
view = make_view()
view:jumpTo(TOTAL)
view.selected = { x = 1, y = #view.layout }
local stop_first = view.virtual:windowFirst()
expect(view:onFocusMove({ 0, 1 }) == true, "bottom edge move is handled")
expect(view.virtual:windowFirst() == stop_first, "the cursor stops at the last chapter")

-- Quick locate: current chapter, chapter number and title search.
view = make_view(2500)
_G.__last_buttondialog = nil
view:locate()
local locate_dialog = _G.__last_buttondialog
local current_button
for _i, row in ipairs(locate_dialog.buttons) do
    if row[1].text == "Jump to current chapter" then current_button = row[1] end
end
expect(current_button ~= nil, "locate offers the current chapter")
current_button.callback()
expect(view.virtual:windowFirst() <= 2500 and view.virtual:windowLast() >= 2500,
    "jump to current chapter locates it")

view = make_view()
_G.__last_inputdialog = nil
view:promptChapterNumber()
_G.__last_inputdialog._input = "1500"
_G.__last_inputdialog.buttons[1][2].callback()
expect(view.virtual:windowFirst() <= 1500 and view.virtual:windowLast() >= 1500,
    "chapter-number jump locates the chapter")

view = make_view()
_G.__last_menu = nil
view:showSearchResults("Chapter 2000")
local menu = _G.__last_menu
expect(menu and #menu.item_table == 1 and menu.item_table[1].mandatory == "2000",
    "title search returns the matching chapter")
menu.item_table[1].callback()
expect(view.virtual:windowFirst() <= 2000 and view.virtual:windowLast() >= 2000,
    "a search result locates the chapter")

print(string.format(
    "chapter_list_view_spec: %d checks, %d failure(s); window=%d",
    checks, failures, window_count))
os.exit(failures == 0 and 0 or 1)
