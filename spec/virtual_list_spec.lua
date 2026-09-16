-- VirtualList windowing tests: a catalog of thousands of rows must materialize
-- one viewport of widgets, keep the total content height exact, and free the
-- rows that leave the window. Uses inert widget fakes; visual behaviour still
-- needs verification on KOReader/e-ink hardware.

package.path = "./?.lua;" .. package.path

local ROW_H = 30
local Widget = {}
function Widget:extend(args) return setmetatable(args or {}, { __index = self }) end
function Widget:new(args)
    local widget = self:extend(args)
    if widget.init then widget:init() end
    return widget
end
function Widget:getSize()
    if self.kind == "vspan" then return { w = 0, h = self.width } end
    if self.kind == "row" then return { w = 100, h = ROW_H } end
    if self.kind == "vertical" then
        if self._size then return self._size end
        local w, h = 0, 0
        for _i, child in ipairs(self) do
            local size = child:getSize()
            w = math.max(w, size.w)
            h = h + size.h
        end
        self._size = { w = w, h = h }
        return self._size
    end
    return self._size or { w = 0, h = 0 }
end
function Widget:resetLayout() self._size, self._offsets = nil, {} end

package.preload["ui/widget/verticalgroup"] = function()
    return Widget:extend{ kind = "vertical" }
end
package.preload["ui/widget/verticalspan"] = function()
    return Widget:extend{ kind = "vspan" }
end

local ScrollableContainer = Widget:extend{
    _scroll_offset_y = 0,
    _max_scroll_offset_y = 0,
}
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
package.preload["ui/uimanager"] = function()
    return { setDirty = function() end }
end

local VirtualList = require("weread.ui.virtual_list")

local live_rows, max_live, built_total, freed_total = 0, 0, 0, 0
local function make_row(entry, index)
    built_total = built_total + 1
    live_rows = live_rows + 1
    max_live = math.max(max_live, live_rows)
    local row = Widget:extend{ kind = "row", entry = entry, index = index }
    function row:free()
        if not self._freed then
            self._freed = true
            live_rows = live_rows - 1
            freed_total = freed_total + 1
        end
    end
    return row
end

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
    entries[index] = { title = "Chapter " .. index, index = index }
end

local window_changed = 0
local list = VirtualList:new{
    entries = entries,
    row_height = ROW_H,
    viewport_h = 300,
    overscan = 2,
    dimen = { w = 600, h = 300 },
    build_row = make_row,
    on_window_changed = function() window_changed = window_changed + 1 end,
}

-- pageRows = floor(300/30) = 10, windowCount = 10 + 2*2 = 14
expect(list:pageRows() == 10, "pageRows counts the viewport rows")
expect(list:windowCount() == 14, "windowCount adds the overscan")
expect(list:windowFirst() == 1 and list:windowLast() == 14,
    "the initial window starts at the first entry")
expect(#list:materializedRows() == 14, "only the window is materialized")
expect(live_rows == 14 and built_total == 14, "initial build is bounded by the window")
expect(list[1]:getSize().h == TOTAL * ROW_H,
    "content height spans the whole catalog so scrolling stays accurate")

-- Scrolling to the middle frees the old window and builds exactly one new one.
local before_built = built_total
list:scrollToIndex(2000, "center")
expect(live_rows == 14, "middle scroll keeps the live row count bounded")
expect(built_total - before_built == 14, "middle scroll builds only one window")
expect(list:windowFirst() <= 2000 and list:windowLast() >= 2000,
    "scrollToIndex centers the requested entry")
expect(list[1]:getSize().h == TOTAL * ROW_H, "content height is invariant under scrolling")

-- The last window is shorter than a full one, and the height stays exact.
list:scrollToIndex(TOTAL, "bottom")
expect(list:windowLast() == TOTAL, "bottom scroll reaches the last entry")
expect(list:windowFirst() > TOTAL - 20, "bottom window sits at the end")
expect(live_rows == list:windowLast() - list:windowFirst() + 1,
    "live rows match the materialized range at the end")
expect(list[1]:getSize().h == TOTAL * ROW_H, "content height is exact at the end")

list:scrollToIndex(1, "top")
expect(list:windowFirst() == 1 and list:windowLast() == 14, "top scroll restores the first window")
expect(live_rows == 14, "top scroll rebuilds a full window")

-- ensureIndexVisible only scrolls when the index is outside the window.
local built_before = built_total
list:ensureIndexVisible(5)
expect(built_total == built_before, "ensureIndexVisible is a no-op inside the window")
list:ensureIndexVisible(1000)
expect(list:windowFirst() <= 1000 and list:windowLast() >= 1000,
    "ensureIndexVisible scrolls an outside index into view")

-- Touch scrolling rebuilds the window and notifies the owner.
window_changed = 0
local first_before = list:windowFirst()
list:_scrollBy(0, 300)
expect(window_changed == 1, "touch scroll notifies the owner once")
expect(list:windowFirst() > first_before, "touch scroll advances the window")
expect(live_rows <= 14, "touch scroll keeps the live row count bounded")

-- A long random walk never materializes more than one window.
for step = 1, 200 do
    local dy = ((step * 37) % 21 - 10) * ROW_H
    list:_scrollBy(0, dy)
    list:scrollToIndex(((step * 977) % TOTAL) + 1, "top")
    if live_rows > 14 then
        expect(false, "window overflowed at step " .. step)
        break
    end
end
expect(max_live <= 14, "peak live rows never exceed one window")

list:free()
expect(live_rows == 0, "free releases every materialized row")
expect(freed_total == built_total, "every built row is freed exactly once")

print(string.format(
    "virtual_list_spec: %d checks, %d failure(s); peak=%d built=%d",
    checks, failures, max_live, built_total))
os.exit(failures == 0 and 0 or 1)
