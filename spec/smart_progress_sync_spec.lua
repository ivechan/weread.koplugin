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

local function count(pred)
    local n = 0
    for _i, handle in ipairs(requests) do
        if pred(handle) then n = n + 1 end
    end
    return n
end
local function is_read_request(body)
    return function(handle)
        return handle.req.url == "https://weread.qq.com/web/book/read"
            and handle.req.body == body
    end
end

-- Closing the document stops the sync and cancels the timer.
_G.__remote_percent = 48
sync = make_sync()
sync:onReaderReady()
unscheduled = 0
sync:onCloseDocument()
expect(sync.active == false, "closing the document should deactivate the sync")
expect(unscheduled >= 1, "closing the document should cancel the timer")

-- Missing cookie: only the gateway source is queried and no push happens.
_G.__local_position = { percent = 50, chapter_uid = 2, book_id = "book" }
_G.__remote_percent = 48
sync = make_sync({ cookie = false })
requests = {}
sync:runOnce()
expect(#requests == 1, "without a cookie only the gateway should be queried")
respond_to_pulls()
expect(count(is_read_request("J50")) == 0, "without a cookie the push must be skipped")

-- Missing API key: only the web source is queried.
sync = make_sync({ api_key = "" })
requests = {}
sync:runOnce()
expect(#requests == 1, "without an API key only the web source should be queried")

-- Push payload carries the local position (not the book's last known one).
_G.__local_position = { percent = 49, chapter_uid = 2, book_id = "book" }
_G.__remote_percent = 48
sync = make_sync()
requests = {}
sync:runOnce()
respond_to_pulls()
expect(count(is_read_request("J49")) == 1,
    "the pushed payload should carry the current local position")

-- The reader-enter handshake is sent once per book per session.
for _i, handle in ipairs(requests) do
    if handle.req.body == "Jtrue" then
        handle.callbacks.on_done(200, {}, "ok")
    end
end
expect(count(is_read_request("Jtrue")) == 1, "the enter handshake should be sent once")
sync:runOnce()
respond_to_pulls()
expect(count(is_read_request("Jtrue")) == 1,
    "the enter handshake must not repeat within a session")

-- stop() cancels requests that are still in flight.
_G.__local_position = { percent = 50, chapter_uid = 2, book_id = "book" }
_G.__remote_percent = 48
sync = make_sync()
requests = {}
sync:runOnce()
local inflight = sync.handles
expect(#inflight == 2, "the two pulls should be in flight")
sync:stop()
expect(inflight[1].cancelled and inflight[2].cancelled,
    "stop() should cancel in-flight requests")

-- runOnce no-ops when inactive, without a book, chapters or local position.
sync = make_sync()
sync.active = false
requests = {}
sync:runOnce()
expect(#requests == 0, "an inactive sync must not run")

sync = make_sync({ books = {} })
requests = {}
sync:runOnce()
expect(#requests == 0, "a missing book record must not run")

sync = make_sync()
sync.plugin.ensureChaptersLoaded = function() return {} end
requests = {}
sync:runOnce()
expect(#requests == 0, "a missing catalog must not run")

sync = make_sync()
_G.__local_position = nil
requests = {}
sync:runOnce()
expect(#requests == 0, "a missing local position must not run")

-- A reading update without a chapter uid does not schedule a run.
_G.__local_position = { percent = 10, book_id = "book" }
sync = make_sync()
sync.current_chapter_uid = nil
scheduled = {}
sync:onPageUpdate()
expect(#scheduled == 0, "a position without a chapter uid should not schedule a run")

-- Official-account articles and non-WeRead documents stop the sync.
_G.__local_position = { percent = 10, chapter_uid = 2, book_id = "book" }
sync = make_sync({ book_id = "MP_WXS_123" })
sync:onReaderReady()
expect(sync.active == false, "an MP article should stop the sync")

sync = make_sync()
sync.plugin.detectWeReadBook = function() return nil end
sync:onReaderReady()
expect(sync.active == false, "a non-WeRead document should stop the sync")

-- Set-Cookie values from responses are merged back into settings.
sync = make_sync()
local merged
sync.plugin.settings.merge_set_cookie = function(_self, value) merged = value end
sync:_mergeSetCookie({ ["set-cookie"] = "a=1" })
expect(merged == "a=1", "a single Set-Cookie header should be merged")
merged = nil
sync:_mergeSetCookie({ ["set-cookie"] = { "a=1", "b=2" } })
expect(merged == "a=1, b=2", "multiple Set-Cookie headers should be joined")
merged = nil
sync:_mergeSetCookie({})
expect(merged == nil, "a response without Set-Cookie should merge nothing")

-- A conflict between the two remote sources (choose_remote -> nil) must not push.
local PositionMapper = require("weread.lib.position_mapper")
local original_choose = PositionMapper.choose_remote
PositionMapper.choose_remote = function() return nil end
_G.__local_position = { percent = 50, chapter_uid = 2, book_id = "book" }
_G.__remote_percent = 48
sync = make_sync()
requests = {}
sync:runOnce()
respond_to_pulls()
expect(count(is_read_request("J50")) == 0, "a source conflict must not push")
PositionMapper.choose_remote = original_choose

-- Resume without an open document does nothing.
sync = make_sync()
sync.ui.document = nil
sync.active = false
scheduled = {}
sync:onResume()
expect(sync.active == false and #scheduled == 0,
    "resume without a document should do nothing")

print(("smart_progress_sync_spec: %d checks"):format(checks))
