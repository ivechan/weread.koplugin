-- Chapter-change and periodic reading-progress sync (non-blocking, no fork).
--
-- Runs entirely on top of the existing pull/push helpers without modifying
-- them: the local position comes from progress_sync, the remote position is
-- fetched through the new non-blocking async_http client, and the push reuses
-- the pure WeRead payload builders. Nothing here blocks the UI.
--
-- Trigger: when the reader moves to another chapter, and every 5 minutes while
-- reading (cancelled on suspend/close). Action: pull remote progress, compare
-- with the local position, and only push when the two are within 3% and the
-- local position is ahead.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local logger = require("weread.lib.logger")
local AsyncHttp = require("weread.lib.async_http")
local Cookie = require("weread.lib.cookie")
local WeRead = require("weread.lib.protocol")
local PositionMapper = require("weread.lib.position_mapper")

local SmartProgressSync = WidgetContainer:extend{
    name = "weread_smart_progress_sync",
}

local INTERVAL_SECONDS = 5 * 60
local DIFF_PERCENT = 3
local SOURCE_CONFLICT_PERCENT = 2
local OPEN_RUN_DELAY = 0.8
local CHAPTER_RUN_DELAY = 0.5
local REQUEST_TIMEOUT = 20

function SmartProgressSync:init()
    self.active = false
    self.running = false
    self.timer = nil
    self.run_scheduled = nil
    self.current_chapter_uid = nil
    self.book_id = nil
    self.entered = {}
    self.handles = {}
end

function SmartProgressSync:_track(handle)
    if handle then self.handles[#self.handles + 1] = handle end
    return handle
end

function SmartProgressSync:_cancelActive()
    for _i, handle in ipairs(self.handles) do
        if handle and handle.cancel then handle:cancel() end
    end
    self.handles = {}
end

function SmartProgressSync:_clearTimer()
    if self.timer then
        UIManager:unschedule(self.timer)
        self.timer = nil
    end
end

function SmartProgressSync:_scheduleTimer()
    self:_clearTimer()
    self.timer = UIManager:scheduleIn(INTERVAL_SECONDS, function()
        self.timer = nil
        if not self.active then return end
        self:runOnce()
        self:_scheduleTimer()
    end)
end

function SmartProgressSync:stop()
    self.active = false
    self:_clearTimer()
    self:_cancelActive()
    self.current_chapter_uid = nil
    self.book_id = nil
    self.entered = {}
end

function SmartProgressSync:start()
    if not (self.ui and self.ui.document) then return end
    self.active = true
    self:_scheduleTimer()
end

function SmartProgressSync:_scheduleRun(delay)
    if self.run_scheduled then return end
    self.run_scheduled = true
    UIManager:scheduleIn(delay, function()
        self.run_scheduled = nil
        if self.active then self:runOnce() end
    end)
end

function SmartProgressSync:_book()
    local book_id = self.book_id
    if not book_id then return nil, nil end
    local books = self.plugin.settings:get("books", {})
    local book = books[tostring(book_id)] or books[book_id]
    if type(book) ~= "table" then return nil, book_id end
    return book, book_id
end

function SmartProgressSync:_localPosition()
    if not (self.plugin.progress_sync and self.plugin.progress_sync.capture_local) then
        return nil
    end
    local ok, position = pcall(self.plugin.progress_sync.capture_local, self.plugin.progress_sync)
    if not ok or type(position) ~= "table" then return nil end
    return position
end

function SmartProgressSync:_detectChapterChange()
    local position = self:_localPosition()
    if not position then return end
    local uid = position.chapter_uid and tostring(position.chapter_uid) or nil
    if uid and uid ~= self.current_chapter_uid then
        self.current_chapter_uid = uid
        self:_scheduleRun(CHAPTER_RUN_DELAY)
    end
end

function SmartProgressSync:onReaderReady()
    local book_id = self.plugin:detectWeReadBook()
    if not book_id or WeRead.is_mp_book(book_id) then
        self:stop()
        return
    end
    self.book_id = tostring(book_id)
    self.active = true
    self.current_chapter_uid = nil
    self:_scheduleTimer()
    local position = self:_localPosition()
    if position and position.chapter_uid then
        self.current_chapter_uid = tostring(position.chapter_uid)
    end
    self:_scheduleRun(OPEN_RUN_DELAY)
end

function SmartProgressSync:onPageUpdate()
    if not self.active then return end
    self:_detectChapterChange()
end

function SmartProgressSync:onPosUpdate()
    if not self.active then return end
    self:_detectChapterChange()
end

function SmartProgressSync:onSuspend()
    self:stop()
end

function SmartProgressSync:onCloseDocument()
    self:stop()
end

function SmartProgressSync:onResume()
    if self.ui and self.ui.document then
        self.book_id = self.book_id or self.plugin:detectWeReadBook()
        self:start()
    end
end

function SmartProgressSync:_cookies()
    return self.plugin.settings:get("cookies", {})
end

function SmartProgressSync:_mergeSetCookie(headers)
    if type(headers) ~= "table" then return end
    local value = headers["set-cookie"]
    if not value then return end
    if type(value) == "table" then value = table.concat(value, ", ") end
    pcall(function()
        self.plugin.settings:merge_set_cookie(value)
    end)
end

function SmartProgressSync:_decode(body)
    local client = self.plugin.client
    local ok, data = pcall(client.json_decode, client, body)
    if ok and type(data) == "table" then return data end
    return nil
end

function SmartProgressSync:_gatewayProgress(book_id, chapters, state)
    local api_key = self.plugin.settings:get("api_key", "")
    if api_key == "" then return end
    state.pending = state.pending + 1
    local body = self.plugin.client:json_encode({
        api_name = "/book/getprogress",
        skill_version = WeRead.SKILL_VERSION,
        bookId = book_id,
    })
    self:_track(AsyncHttp.request({
        url = "https://i.weread.qq.com/api/agent/gateway",
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Accept"] = "application/json, text/plain, */*",
            ["User-Agent"] = WeRead.USER_AGENT,
        },
        body = body,
        user_agent = WeRead.USER_AGENT,
        timeout = REQUEST_TIMEOUT,
    }, {
        on_done = function(status, _headers, response)
            if status and status >= 200 and status < 300 then
                local data = self:_decode(response)
                if data then
                    state.gateway = PositionMapper.normalize_remote(
                        data, book_id, "gateway", chapters)
                end
            end
            state:pending_done()
        end,
        on_error = function(err)
            logger.dbg("smart sync gateway pull failed:", tostring(err))
            state:pending_done()
        end,
    }))
end

function SmartProgressSync:_webProgress(book_id, chapters, state)
    if not self.plugin.settings:is_cookie_configured() then return end
    state.pending = state.pending + 1
    local url = "https://weread.qq.com/web/book/getProgress?bookId="
        .. WeRead.urlencode(book_id) .. "&_=" .. tostring(os.time() * 1000)
    self:_track(AsyncHttp.request({
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = "application/json, text/plain, */*",
            ["Referer"] = WeRead.reader_url(book_id),
            ["User-Agent"] = WeRead.USER_AGENT,
            ["Cookie"] = Cookie.to_header(self:_cookies()),
        },
        user_agent = WeRead.USER_AGENT,
        timeout = REQUEST_TIMEOUT,
    }, {
        on_done = function(status, headers, response)
            self:_mergeSetCookie(headers)
            if status and status >= 200 and status < 300 then
                local data = self:_decode(response)
                if data then
                    state.web = PositionMapper.normalize_remote(
                        data, book_id, "web", chapters)
                end
            end
            state:pending_done()
        end,
        on_error = function(err)
            logger.dbg("smart sync web pull failed:", tostring(err))
            state:pending_done()
        end,
    }))
end

function SmartProgressSync:_fetchRemote(book_id, chapters, callback)
    local state = { pending = 0, gateway = nil, web = nil, done = false }
    state.finish = function(st)
        if st.done then return end
        st.done = true
        callback(PositionMapper.choose_remote(
            st.web, st.gateway, SOURCE_CONFLICT_PERCENT))
    end
    state.pending_done = function(st)
        st.pending = st.pending - 1
        if st.pending <= 0 then st.finish(st) end
    end
    self:_gatewayProgress(book_id, chapters, state)
    self:_webProgress(book_id, chapters, state)
    if state.pending == 0 then state.finish(state) end
end

function SmartProgressSync:_buildReadPayload(book_id, book, position, psvts, pclts)
    return WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = position.chapter_uid or book.chapter_uid,
        chapter_idx = tonumber(position.chapter_idx)
            or tonumber(book.chapter_idx) or 0,
        chapter_offset = tonumber(position.chapter_offset)
            or tonumber(book.chapter_offset) or 0,
        progress = tonumber(position.percent) or tonumber(book.progress) or 0,
        summary = position.summary or book.summary or "",
        elapsed_seconds = 0,
        app_id = book.app_id or WeRead.web_app_id(),
        psvts = psvts,
        pclts = pclts,
        token = book.token,
    }
end

function SmartProgressSync:_buildEnterPayload(book_id, book, psvts, pclts)
    return WeRead.make_enter_read_payload{
        book_id = book_id,
        chapter_uid = book.chapter_uid,
        chapter_idx = tonumber(book.chapter_idx) or 0,
        chapter_offset = tonumber(book.chapter_offset) or 0,
        progress = tonumber(book.progress) or 0,
        summary = book.summary or "",
        app_id = book.app_id or WeRead.web_app_id(),
        psvts = psvts,
        pclts = pclts,
    }
end

function SmartProgressSync:_postRead(book_id, payload, callback)
    local referer = WeRead.reader_url(book_id)
    self:_track(AsyncHttp.request({
        url = "https://weread.qq.com/web/book/read",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = "https://weread.qq.com",
            ["Referer"] = referer,
            ["Accept"] = "application/json, text/plain, */*",
            ["User-Agent"] = WeRead.USER_AGENT,
            ["Cookie"] = Cookie.to_header(self:_cookies()),
        },
        body = self.plugin.client:json_encode(payload),
        user_agent = WeRead.USER_AGENT,
        timeout = REQUEST_TIMEOUT,
    }, {
        on_done = function(status, headers, _body)
            self:_mergeSetCookie(headers)
            local ok = status and status >= 200 and status < 300
            if callback then callback(ok == true, status) end
        end,
        on_error = function(err)
            logger.dbg("smart sync push failed:", tostring(err))
            if callback then callback(false, nil) end
        end,
    }))
end

function SmartProgressSync:_pushProgress(book_id, book, position)
    if not self.plugin.settings:is_cookie_configured() then return end
    local psvts = tostring(book.psvts or "")
    -- The read endpoint needs the Web reader session state (psvts). If it has
    -- not been loaded yet we skip rather than doing a blocking reader-state
    -- fetch on the UI thread; the existing pull-on-open will populate it.
    if psvts == "" then return end

    local pclts = book.pclts
    if pclts == nil or pclts == "" or tonumber(pclts) == 0 then
        pclts = WeRead.e(self.plugin.read_report.now())
    end

    local key = tostring(book_id)
    if not self.entered[key] then
        local enter = self:_buildEnterPayload(book_id, book, psvts, pclts)
        self:_postRead(book_id, enter, function(ok)
            if ok then self.entered[key] = true end
        end)
    end
    local payload = self:_buildReadPayload(book_id, book, position, psvts, pclts)
    self:_postRead(book_id, payload)
end

-- Push only when the two positions are close (< DIFF_PERCENT apart) and the
-- local position is ahead, so a behind server is nudged forward without
-- fighting another device that is genuinely ahead.
function SmartProgressSync.should_push(local_percent, remote_percent)
    local diff = (tonumber(local_percent) or 0) - (tonumber(remote_percent) or 0)
    return math.abs(diff) < DIFF_PERCENT and diff > 0
end

function SmartProgressSync:runOnce()
    if self.running or not self.active then return end
    local book, book_id = self:_book()
    if not book then return end
    local chapters = self.plugin:ensureChaptersLoaded(book)
    if type(chapters) ~= "table" or #chapters == 0 then return end
    local position = self:_localPosition()
    if not position then return end

    self.running = true
    self:_fetchRemote(book_id, chapters, function(remote)
        self.running = false
        if not remote then return end
        logger.dbg("smart sync compare:",
            "book=", tostring(book_id),
            "local=", tostring(position.percent),
            "remote=", tostring(remote.percent))
        if self.should_push(position.percent, remote.percent) then
            self:_pushProgress(book_id, book, position)
        end
    end)
end

return SmartProgressSync
