-- Smart chapter/periodic progress sync tests. The async HTTP client, KOReader
-- widgets and the WeRead pure helpers are replaced with fakes; the decision
-- logic and lifecycle wiring of the feature module stay real.

package.path = "./?.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Widget = {}
function Widget:extend(args) return setmetatable(args or {}, { __index = self }) end
function Widget:new(args)
    local widget = self:extend(args)
    if widget.init then widget:init() end
    return widget
end
package.preload["ui/widget/container/widgetcontainer"] = function() return Widget end

local scheduled, unscheduled = {}, 0
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, delay, callback)
            local id = {}
            scheduled[#scheduled + 1] = { delay = delay, callback = callback, id = id }
            return id
        end,
        unschedule = function() unscheduled = unscheduled + 1 end,
    }
end
package.preload["weread.lib.logger"] = function()
    local function noop() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end

local requests = {}
package.preload["weread.lib.async_http"] = function()
    return {
        request = function(req, callbacks)
            local handle = {
                req = req, callbacks = callbacks,
                cancel = function(self) self.cancelled = true end,
            }
            requests[#requests + 1] = handle
            return handle
        end,
    }
end
package.preload["weread.lib.cookie"] = function()
    return { to_header = function() return "cookie" end }
end
package.preload["weread.lib.protocol"] = function()
    return {
        USER_AGENT = "UA",
        SKILL_VERSION = "1.0.5",
        is_mp_book = function(id) return tostring(id):sub(1, 7) == "MP_WXS_" end,
        urlencode = function(v) return tostring(v) end,
        reader_url = function(book_id) return "https://weread.qq.com/web/reader/" .. tostring(book_id) end,
        web_app_id = function() return "APP" end,
        e = function(v) return tostring(v) end,
        make_read_payload = function(opts) return { pr = opts.progress, b = opts.book_id } end,
        make_enter_read_payload = function(opts) return { enter = true, b = opts.book_id } end,
    }
end
package.preload["weread.lib.position_mapper"] = function()
    return {
        normalize_remote = function(_value, book_id, source)
            return { book_id = book_id, percent = _G.__remote_percent, source = source }
        end,
        choose_remote = function(web, gateway)
            return web or gateway
        end,
    }
end

local SmartSync = require("weread.lib.smart_progress_sync")

local function make_plugin(opts)
    opts = opts or {}
    local books = opts.books or {
        book = {
            book_id = "book", psvts = "PS", pclts = "PC", token = "TOK",
            chapter_uid = 2, chapter_idx = 2, chapter_offset = 10,
            progress = 50, app_id = "APP", summary = "sm",
        },
    }
    return {
        settings = {
            get = function(_self, key)
                if key == "books" then return books end
                if key == "api_key" then return opts.api_key or "KEY" end
                if key == "cookies" then return { wr_skey = "x" } end
            end,
            is_cookie_configured = function() return opts.cookie ~= false end,
            merge_set_cookie = function() end,
        },
        client = {
            json_encode = function(_self, value)
                return "J" .. tostring(value.pr or value.enter or "")
            end,
            json_decode = function() return {} end,
        },
        progress_sync = {
            capture_local = function() return _G.__local_position end,
        },
        read_report = { now = function() return 1000 end },
        detectWeReadBook = function() return opts.book_id or "book" end,
        ensureChaptersLoaded = function() return { { chapterUid = 1 }, { chapterUid = 2 } } end,
    }
end

local function make_sync(opts)
    local sync = SmartSync:new{ plugin = make_plugin(opts) }
    sync.ui = { document = { file = "/cache/book.epub" } }
    sync.active = true
    sync.book_id = "book"
    return sync
end

-- Respond to every request queued so far (the two progress pulls). The push,
-- if any, is queued by the last response and is intentionally left pending.
local function respond_to_pulls()
    local pulls = {}
    for _i, handle in ipairs(requests) do pulls[#pulls + 1] = handle end
    for _i, handle in ipairs(pulls) do
        handle.callbacks.on_done(200, {}, "body")
    end
end

local function read_request_body()
    for _i, handle in ipairs(requests) do
        if handle.req.url == "https://weread.qq.com/web/book/read"
            and handle.req.body == "J50" then
            return handle.req.body
        end
    end
end

-- Decision rule: within 3% and local ahead.
expect(SmartSync.should_push(50, 48) == true, "close and ahead should push")
expect(SmartSync.should_push(50, 47.5) == true, "2.5% ahead should push")
expect(SmartSync.should_push(50, 47) == false, "exactly 3% apart should not push")
expect(SmartSync.should_push(50, 45) == false, "far ahead should not push")
expect(SmartSync.should_push(45, 50) == false, "local behind should not push")
expect(SmartSync.should_push(50, 50) == false, "equal positions should not push")

-- Chapter-change run: local 50, remote 48 -> push.
_G.__local_position = { percent = 50, chapter_uid = 2, chapter_idx = 2,
    chapter_offset = 10, book_id = "book" }
_G.__remote_percent = 48
local sync = make_sync()
requests = {}
sync:runOnce()
expect(#requests == 2, "both progress sources should be queried")
respond_to_pulls()
expect(read_request_body() ~= nil,
    "a close, ahead local position should be pushed")

-- Remote further ahead inside 3% window but local behind: no push.
_G.__local_position = { percent = 45, chapter_uid = 2, book_id = "book" }
_G.__remote_percent = 47
sync = make_sync()
requests = {}
sync:runOnce()
respond_to_pulls()
expect(read_request_body() == nil, "a behind local position must not be pushed")

-- Difference >= 3%: no push.
_G.__local_position = { percent = 50, chapter_uid = 2, book_id = "book" }
_G.__remote_percent = 45
sync = make_sync()
requests = {}
sync:runOnce()
respond_to_pulls()
expect(read_request_body() == nil, "a far-ahead local position must not be pushed")

-- Missing reader session (psvts) skips the push instead of blocking to fetch it.
_G.__local_position = { percent = 50, chapter_uid = 2, book_id = "book" }
_G.__remote_percent = 48
sync = make_sync({ books = { book = {
    book_id = "book", psvts = "", chapter_uid = 2, progress = 50,
} } })
requests = {}
sync:runOnce()
respond_to_pulls()
expect(read_request_body() == nil,
    "a missing reader session must skip the push")

-- Timer: reader ready schedules the 5-minute timer and an immediate run;
-- suspend clears it; resume restarts it.
_G.__remote_percent = 48
sync = make_sync()
scheduled, unscheduled = {}, 0
sync:onReaderReady()
local has_timer, has_open_run = false, false
for _i, entry in ipairs(scheduled) do
    if entry.delay == 300 then has_timer = true end
    if entry.delay == 0.8 then has_open_run = true end
end
expect(has_timer, "onReaderReady should start the 5-minute timer")
expect(has_open_run, "onReaderReady should schedule an immediate run")
expect(sync.active == true, "reading should mark the sync active")

sync:onSuspend()
expect(sync.active == false, "suspend should deactivate the sync")
expect(unscheduled >= 1, "suspend should cancel the timer")

unscheduled = 0
sync:onResume()
expect(sync.active == true and unscheduled >= 0, "resume should reactivate the sync")
local resumed_timer = false
for _i, entry in ipairs(scheduled) do
    if entry.delay == 300 then resumed_timer = true end
end
expect(resumed_timer, "resume should reschedule the 5-minute timer")

-- Chapter change detection schedules a run.
sync = make_sync()
sync.current_chapter_uid = "1"
_G.__local_position = { percent = 10, chapter_uid = 2, book_id = "book" }
scheduled = {}
sync:onPageUpdate()
local chapter_run = false
for _i, entry in ipairs(scheduled) do
    if entry.delay == 0.5 then chapter_run = true end
end
expect(chapter_run, "moving to another chapter should schedule a sync run")

-- Same chapter does not schedule another run.
scheduled = {}
sync.current_chapter_uid = "2"
sync:onPageUpdate()
expect(#scheduled == 0, "staying in the same chapter should not schedule a run")

print(("smart_progress_sync_spec: %d checks"):format(checks))
