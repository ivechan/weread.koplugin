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
local select_calls = 0
local clock = 0

local function new_socket(response, options)
    options = options or {}
    local sock = {
        buf = response or "",
        pos = 1,
        timeouts_left = options.timeouts or 0,
        connect_ok = options.connect_ok ~= false,
        connect_err = options.connect_err,
        connect_calls = 0,
        closed = false,
        tls = options.tls == true,
    }
    function sock:settimeout() end
    function sock:sni() end
    function sock:connect(host, port)
        self.host, self.port = host, port
        self.connect_calls = self.connect_calls + 1
        if not self.connect_ok then return nil, self.connect_err or "timeout" end
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
    function sock:dohandshake() return true end
    function sock:close() self.closed = true end
    return sock
end

local socket_factory
package.preload["socket"] = function()
    return {
        tcp = function() return socket_factory() end,
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
    return {
        wrap = function(sock)
            sock.tls = true
            return sock
        end,
    }
end

local AsyncHttp = require("weread.lib.async_http")

local function pump_all()
    local guard = 0
    while #scheduled > 0 and guard < 100000 do
        table.remove(scheduled, 1)()
        guard = guard + 1
    end
end

local function run(req)
    sent, scheduled, select_calls, clock = nil, {}, 0, 0
    local result
    AsyncHttp.request(req, {
        on_done = function(status, headers, body) result = { status, headers, body } end,
        on_error = function(err) result = { error = err } end,
    })
    pump_all()
    return result
end

-- GET: yields once on connect and once on receive, then parses status,
-- headers and a content-length body.
local socket = new_socket(
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Test: yes\r\n\r\nhello",
    { timeouts = 1 })
socket_factory = function() return socket end
local result = run({ url = "http://example.com/hello", method = "GET", timeout = 30 })
expect(result[1] == 200, "GET did not return HTTP 200")
expect(result[2]["content-length"] == "5" and result[2]["x-test"] == "yes",
    "response headers were not parsed")
expect(result[3] == "hello", "response body was not read")
expect(sent:find("GET /hello HTTP/1.1", 1, true) ~= nil
    and sent:find("Host: example.com", 1, true) ~= nil,
    "request line or Host header was wrong")
expect(select_calls >= 1, "the coroutine never yielded to the UI loop")
expect(socket.closed, "socket was not closed")

-- POST: method, Content-Length and body are sent.
socket = new_socket("HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok")
socket_factory = function() return socket end
result = run({
    url = "http://example.com/api", method = "POST", body = "abc",
    headers = { ["Content-Type"] = "application/json" }, timeout = 30,
})
expect(result[1] == 201, "POST did not return HTTP 201")
expect(sent:find("POST /api HTTP/1.1", 1, true) ~= nil, "POST request line was wrong")
expect(sent:find("Content-Type: application/json", 1, true) ~= nil,
    "custom header was not sent")
expect(sent:find("Content-Length: 3", 1, true) ~= nil and sent:sub(-3) == "abc",
    "POST body was not sent with its length")

-- Chunked transfer-encoding is reassembled.
socket = new_socket(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    .. "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
socket_factory = function() return socket end
result = run({ url = "http://example.com/chunked" })
expect(result[3] == "hello world", "chunked body was not reassembled")

-- Body without Content-Length is read until the connection closes.
socket = new_socket("HTTP/1.1 200 OK\r\n\r\nno-length-body")
socket_factory = function() return socket end
result = run({ url = "http://example.com/stream" })
expect(result[3] == "no-length-body", "until-close body was not read")

-- Multiple Set-Cookie headers are collected.
socket = new_socket(
    "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 0\r\n\r\n")
socket_factory = function() return socket end
result = run({ url = "http://example.com/cookies" })
expect(type(result[2]["set-cookie"]) == "table"
    and result[2]["set-cookie"][1] == "a=1"
    and result[2]["set-cookie"][2] == "b=2",
    "multiple Set-Cookie headers were not collected")

-- Redirect: a 302 is followed to a fresh connection.
local responses = {
    "HTTP/1.1 302 Found\r\nLocation: http://example.com/final\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
}
local redirect_index = 0
socket_factory = function()
    redirect_index = redirect_index + 1
    return new_socket(responses[redirect_index])
end
result = run({ url = "http://example.com/start" })
expect(result[1] == 200 and result[3] == "ok", "a redirect was not followed")
expect(sent:find("GET /final HTTP/1.1", 1, true) ~= nil,
    "the redirect target was not requested")

-- Too many redirects are rejected.
socket_factory = function()
    return new_socket("HTTP/1.1 302 Found\r\nLocation: http://example.com/loop\r\n\r\n")
end
result = run({ url = "http://example.com/loop" })
expect(result.error == "too many redirects",
    "a redirect loop should stop, got " .. tostring(result.error))

-- HTTPS goes through the TLS wrap/handshake path.
socket = new_socket("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
socket_factory = function() return socket end
result = run({ url = "https://example.com/secure" })
expect(result[1] == 200 and result[3] == "hi" and socket.tls,
    "the HTTPS/TLS path did not complete")
expect(sent:find("GET /secure HTTP/1.1", 1, true) ~= nil, "HTTPS request line was wrong")

-- Connection failure is reported.
socket = new_socket("", { connect_ok = false, connect_err = "connection refused" })
socket_factory = function() return socket end
result = run({ url = "http://example.com/refused", timeout = 30 })
expect(type(result.error) == "string"
    and result.error:find("connection refused", 1, true) ~= nil,
    "a connection error should surface, got " .. tostring(result.error))

-- Invalid URL is rejected.
socket_factory = function() return new_socket("") end
result = run({ url = "not-a-url" })
expect(result.error == "invalid url", "an invalid url should be rejected")

-- Timeout: a connection that never completes reports a timeout error.
socket = new_socket("", { connect_ok = false })
socket_factory = function() return socket end
result = run({ url = "http://example.com/slow", timeout = 0.05 })
expect(result.error == "timeout", "a stalled request should time out")

-- Cancel: a handle can be cancelled before completion.
socket = new_socket("", { connect_ok = false })
socket_factory = function() return socket end
scheduled, clock = {}, 0
local cancelled
local handle = AsyncHttp.request({ url = "http://example.com/x", timeout = 30 }, {
    on_error = function(err) cancelled = err end,
})
handle:cancel()
pump_all()
expect(cancelled == "cancelled", "cancel did not abort the request")

print(("async_http_spec: %d checks"):format(checks))
