-- Non-blocking HTTP client tests with fake sockets and a manual UI-loop pump.

package.path = "./?.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    local function noop() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end

local sent
local current_socket
local select_calls = 0
local clock = 0

local function new_socket(response, options)
    options = options or {}
    local sock = {
        buf = response or "",
        pos = 1,
        timeouts_left = options.timeouts or 0,
        connect_ok = options.connect_ok ~= false,
        connect_calls = 0,
        closed = false,
    }
    function sock:settimeout() end
    function sock:sni() end
    function sock:connect(host, port)
        self.host, self.port = host, port
        self.connect_calls = self.connect_calls + 1
        if not self.connect_ok then return nil, "timeout" end
        if self.connect_calls == 1 then return nil, "timeout" end
        return 1
    end
    function sock:send(data, index)
        index = index or 1
        sent = (sent or "") .. data:sub(index)
        return #data - index + 1, nil
    end
    function sock:receive(pattern)
        if self.timeouts_left > 0 then
            self.timeouts_left = self.timeouts_left - 1
            return nil, "timeout", nil
        end
        if pattern == "*l" then
            local nl = self.buf:find("\n", self.pos, true)
            if not nl then return nil, "closed" end
            local line = self.buf:sub(self.pos, nl - 1)
            self.pos = nl + 1
            return (line:gsub("\r$", ""))
        elseif type(pattern) == "number" then
            if self.pos > #self.buf then return nil, "closed" end
            local chunk = self.buf:sub(self.pos, self.pos + pattern - 1)
            self.pos = self.pos + #chunk
            return chunk
        end
        local chunk = self.buf:sub(self.pos)
        self.pos = #self.buf + 1
        return chunk
    end
    function sock:close() self.closed = true end
    return sock
end

package.preload["socket"] = function()
    return {
        tcp = function() return current_socket end,
        select = function(recvt, sendt)
            select_calls = select_calls + 1
            return recvt or {}, sendt or {}
        end,
        gettime = function()
            clock = clock + 0.02
            return clock
        end,
    }
end
package.preload["socket.url"] = function()
    return {
        parse = function(url)
            local scheme, rest = url:match("^(%w+)://(.+)$")
            if not scheme then return nil end
            local authority, pathquery = rest:match("^([^/]+)(/.*)$")
            if not authority then authority, pathquery = rest, "/" end
            local host, port = authority:match("^([^:]+):?(%d*)$")
            local path, query = pathquery:match("^([^?]*)%??(.*)$")
            return {
                scheme = scheme, host = host,
                port = tonumber(port), path = path,
                query = (query ~= "" and query or nil),
            }
        end,
        absolute = function(_base, location) return location end,
    }
end
package.preload["ssl"] = function()
    return { wrap = function() error("ssl is not used in this spec") end }
end

local AsyncHttp = require("weread.lib.async_http")

local function pump_all()
    local guard = 0
    while #scheduled > 0 and guard < 100000 do
        table.remove(scheduled, 1)()
        guard = guard + 1
    end
end

-- GET: yields once on connect and once on receive, then parses status,
-- headers and a content-length body.
sent, select_calls, scheduled, clock = nil, 0, {}, 0
current_socket = new_socket(
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Test: yes\r\n\r\nhello",
    { timeouts = 1 })
local done
AsyncHttp.request({ url = "http://example.com/hello", method = "GET", timeout = 30 }, {
    on_done = function(status, headers, body) done = { status, headers, body } end,
    on_error = function(err) done = { error = err } end,
})
pump_all()
expect(done and done[1] == 200, "GET did not return HTTP 200")
expect(done[2]["content-length"] == "5" and done[2]["x-test"] == "yes",
    "response headers were not parsed")
expect(done[3] == "hello", "response body was not read")
expect(sent:find("GET /hello HTTP/1.1", 1, true) ~= nil
    and sent:find("Host: example.com", 1, true) ~= nil,
    "request line or Host header was wrong")
expect(select_calls >= 1, "the coroutine never yielded to the UI loop")
expect(current_socket.closed, "socket was not closed")

-- POST: method, Content-Length and body are sent.
sent, scheduled, clock = nil, {}, 0
current_socket = new_socket("HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok")
local posted
AsyncHttp.request({
    url = "http://example.com/api", method = "POST", body = "abc",
    headers = { ["Content-Type"] = "application/json" }, timeout = 30,
}, {
    on_done = function(status) posted = status end,
})
pump_all()
expect(posted == 201, "POST did not return HTTP 201")
expect(sent:find("POST /api HTTP/1.1", 1, true) ~= nil, "POST request line was wrong")
expect(sent:find("Content-Type: application/json", 1, true) ~= nil,
    "custom header was not sent")
expect(sent:find("Content-Length: 3", 1, true) ~= nil
    and sent:sub(-3) == "abc",
    "POST body was not sent with its length")

-- Timeout: a connection that never completes reports a timeout error.
sent, scheduled, clock = nil, {}, 0
current_socket = new_socket("", { connect_ok = false })
local timed_out
AsyncHttp.request({ url = "http://example.com/slow", timeout = 0.05 }, {
    on_done = function() timed_out = "done" end,
    on_error = function(err) timed_out = err end,
})
pump_all()
expect(timed_out == "timeout", "a stalled request should time out, got " .. tostring(timed_out))

-- Cancel: a handle can be cancelled before completion.
sent, scheduled, clock = nil, {}, 0
current_socket = new_socket("", { connect_ok = false })
local cancelled
local handle = AsyncHttp.request({ url = "http://example.com/x", timeout = 30 }, {
    on_error = function(err) cancelled = err end,
})
handle:cancel()
pump_all()
expect(cancelled == "cancelled", "cancel did not abort the request")

print(("async_http_spec: %d checks"):format(checks))
