-- Virtualized vertical list built on top of ScrollableContainer.
--
-- A catalog with thousands of rows must not allocate a widget tree per row.
-- This container keeps the total content height correct (so the scrollbar and
-- scroll range stay accurate) but only materializes the rows inside the
-- current viewport plus a small overscan window. Scrolling past the window
-- frees the rows that left and builds the ones that entered, keeping memory
-- and per-frame paint work proportional to the viewport, not to the catalog.
--
-- Row heights are assumed uniform: the caller measures one row and passes the
-- height. That is what lets the window be computed directly from the scroll
-- offset without laying out every entry.

local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local VirtualList = ScrollableContainer:extend{
    entries = nil,          -- opaque row data, never widgets
    row_height = 1,         -- uniform height of one materialized row
    viewport_h = 1,         -- visible height
    overscan = 1,           -- extra rows kept above and below the viewport
    build_row = nil,        -- function(entry, index) -> widget
    on_window_changed = nil,-- called after a scroll rebuilds the window
    show_parent = nil,
}

function VirtualList:init()
    ScrollableContainer.init(self)
    self.entries = self.entries or {}
    self._rows = {}
    self._window_first = 1
    self._built_count = 0
    self._window_count = self:windowCount()
    self._top_spacer = VerticalSpan:new{ width = 0 }
    self._bottom_spacer = VerticalSpan:new{ width = 0 }
    self._group = VerticalGroup:new{ align = "left", self._top_spacer, self._bottom_spacer }
    self[1] = self._group
    self:updateWindow(true)
end

-- Rows that fit one viewport, ignoring overscan.
function VirtualList:pageRows()
    local viewport = (self.dimen and self.dimen.h) or self.viewport_h or self.row_height
    return math.max(1, math.floor(viewport / self.row_height))
end

-- Materialized rows, including overscan.
function VirtualList:windowCount()
    return math.max(1, self:pageRows() + 2 * self.overscan)
end

function VirtualList:windowFirst()
    return self._window_first
end

function VirtualList:windowLast()
    return self._window_first + self._built_count - 1
end

function VirtualList:materializedRows()
    return self._rows
end

function VirtualList:_freeRows()
    for _i, row in ipairs(self._rows or {}) do
        if row.free then row:free() end
    end
end

function VirtualList:_rebuildGroup(count)
    local group = self._group
    for index = #group, 1, -1 do group[index] = nil end
    local total = #self.entries
    self._top_spacer.width = (self._window_first - 1) * self.row_height
    self._bottom_spacer.width = math.max(0, (total - (self._window_first + count - 1)) * self.row_height)
    group[1] = self._top_spacer
    for slot = 1, count do
        group[#group + 1] = self._rows[slot]
    end
    group[#group + 1] = self._bottom_spacer
    group:resetLayout()
end

-- Recompute the materialized window from the current scroll offset. A window
-- whose first row and size did not change is left untouched, so small scrolls
-- only repaint.
function VirtualList:updateWindow(force)
    local total = #self.entries
    if total == 0 then
        if force or self._built_count ~= 0 then
            self:_freeRows()
            self._rows = {}
            self._built_count = 0
            self._window_first = 1
            self:_rebuildGroup(0)
        end
        return
    end
    self._window_count = self:windowCount()
    local max_first = math.max(1, total - self._window_count + 1)
    local first = math.floor((self._scroll_offset_y or 0) / self.row_height) + 1 - self.overscan
    first = math.max(1, math.min(first, max_first))
    local count = math.min(self._window_count, total - first + 1)
    if not force and first == self._window_first and count == self._built_count then
        return
    end
    self._window_first = first
    self:_freeRows()
    self._rows = {}
    for slot = 1, count do
        local index = first + slot - 1
        self._rows[slot] = self.build_row(self.entries[index], index)
    end
    self._built_count = count
    self:_rebuildGroup(count)
end

function VirtualList:_scrollBy(dx, dy, ensure_scroll_steps)
    ScrollableContainer._scrollBy(self, dx, dy, ensure_scroll_steps)
    self:updateWindow()
    if self.on_window_changed then self.on_window_changed() end
end

-- Move the scroll offset so `index` is visible, using the requested alignment.
function VirtualList:scrollToIndex(index, align)
    local total = #self.entries
    if total == 0 then return end
    index = math.max(1, math.min(index, total))
    local viewport = (self.dimen and self.dimen.h) or self.viewport_h or self.row_height
    local max_offset = math.max(0, total * self.row_height - viewport)
    local target
    if align == "center" then
        target = (index - 1) * self.row_height - math.floor((viewport - self.row_height) / 2)
    elseif align == "bottom" then
        target = (index - 1) * self.row_height - (viewport - self.row_height)
    else
        target = (index - 1) * self.row_height
    end
    self._scroll_offset_y = math.max(0, math.min(target, max_offset))
    self:updateWindow(true)
    self:_updateScrollBars()
    UIManager:setDirty(self.show_parent or self, "ui")
end

-- Scroll only when the index is outside the current window.
function VirtualList:ensureIndexVisible(index)
    if index < self._window_first then
        self:scrollToIndex(index, "top")
    elseif index > self:windowLast() then
        self:scrollToIndex(index, "bottom")
    end
end

function VirtualList:free()
    self:_freeRows()
    self._rows = {}
    self._built_count = 0
    if self._bb then
        self._bb:free()
        self._bb = nil
    end
end

function VirtualList:onCloseWidget()
    self:free()
end

return VirtualList
