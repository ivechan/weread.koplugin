-- Non-blocking HTTP(S) client driven by KOReader's UI loop (no fork).
--
-- A request runs inside a coroutine that drives a LuaSocket/LuaSec socket in
-- non-blocking mode. Whenever an operation would block it yields (sock, "r"/"w");
-- the driver waits for that socket with socket.select() and then resumes the
-- coroutine, scheduling itself back onto UIManager between steps so the UI keeps
-- responding. This mirrors KOReader's httpasync.lua, but also supports POST and
-- returns the status code and response headers.

local socket = require("socket")
local socket_url = require("socket.url")
local ssl = require("ssl")
local UIManager = require("ui/uimanager")
local logger = require("weread.lib.logger")

local AsyncHttp = {}

local START_DELAY = 0.01
local PUMP_DELAY = 0.01
local SELECT_SLICE = 0.05
local DEFAULT_TIMEOUT = 20
local MAX_REDIRECTS = 5
local MAX_BODY_BYTES = 4 * 1024 * 1024

local function async_connect(sock, host, port)
    sock:settimeout(0)
    while true do
        local res, err = sock:connect(host, port)
        if res or err == "already connected" then
            return true
        elseif err == "timeout" or err == "Operation already in progress" then
            coroutine.yield(sock, "w")
        else
            return false, err
        end
    end
end

local function async_send(sock, data)
    local index = 1
    while index <= #data do
        local res, err, last = sock:send(data, index)
        if err == "timeout" or err == "wantwrite" then
            coroutine.yield(sock, "w")
            if last then index = last + 1 end
        elseif err == "wantread" then
            coroutine.yield(sock, "r")
        elseif err then
            return false, err
        else
            index = res + 1
        end
    end
    return true
end

-- LuaSocket's receive(pattern, prefix) prepends `prefix` to the buffer it reads
-- into, so partial data already pulled on a previous (timed-out) call must be
-- handed back as the prefix on the next call.
local function async_receive(sock, pattern)
    local accumulated = ""
    while true do
        local res, err, partial = sock:receive(pattern, accumulated)
        if err == "timeout" or err == "wantread" then
            accumulated = partial or accumulated
            coroutine.yield(sock, "r")
        elseif err == "wantwrite" then
            coroutine.yield(sock, "w")
        else
            return res, err, partial
        end
    end
end

local function async_handshake(sock)
    while true do
        local res, err = sock:dohandshake()
        if res then
            return true
        elseif err == "wantread" then
            coroutine.yield(sock, "r")
        elseif err == "wantwrite" then
            coroutine.yield(sock, "w")
        else
            return false, err
        end
    end
end

local function add_header(headers, key, value)
    key = key:lower()
    local existing = headers[key]
    if existing == nil then
        headers[key] = value
    elseif type(existing) == "table" then
        existing[#existing + 1] = value
    else
        headers[key] = { existing, value }
    end
end

local function read_headers(sock)
    local headers = {}
    local status_line
    while true do
        local line, err = async_receive(sock, "*l")
        if not line then return nil, nil, err end
        if line == "" then break end
        if not status_line then
            status_line = line
        else
            local key, value = line:match("^(.-):%s*(.*)")
            if key then add_header(headers, key, value) end
        end
    end
    return status_line, headers
end

local function read_body(sock, headers)
    local chunks = {}
    local total = 0
    local function push(chunk)
        if chunk and #chunk > 0 then
            total = total + #chunk
            if total > MAX_BODY_BYTES then return false end
            chunks[#chunks + 1] = chunk
        end
        return true
    end

    local transfer = headers["transfer-encoding"]
    if transfer and tostring(transfer):lower():find("chunked", 1, true) then
        while true do
            local size_line = async_receive(sock, "*l")
            if not size_line then break end
            local hex = size_line:match("^%x+")
            if not hex then break end
            local size = tonumber(hex, 16)
            if not size or size == 0 then break end
            local data = async_receive(sock, size)
            if not push(data) then return nil, "response too large" end
            async_receive(sock, 2)
        end
    else
        local length = tonumber(headers["content-length"])
        if length then
            local remaining = length
            while remaining > 0 do
                local chunk = async_receive(sock, remaining)
                if not chunk or #chunk == 0 then break end
                if not push(chunk) then return nil, "response too large" end
                remaining = remaining - #chunk
            end
        else
            while true do
                local chunk, err, partial = async_receive(sock, 8192)
                if chunk then
                    if not push(chunk) then return nil, "response too large" end
                else
                    if partial and #partial > 0 then
                        if not push(partial) then return nil, "response too large" end
                    end
                    if err == "closed" then break end
                    if err ~= "timeout" and err ~= "wantread" then break end
                end
            end
        end
    end
    return table.concat(chunks)
end

local function run_request(req)
    local redirects = tonumber(req.redirects) or 0
    if redirects > MAX_REDIRECTS then return false, "too many redirects" end

    local url = req.url
    local parsed = socket_url.parse(url)
    if not parsed or not parsed.host then return false, "invalid url" end
    local host = parsed.host
    local port = parsed.port or (parsed.scheme == "https" and 443 or 80)
    local path = parsed.path or "/"
    if parsed.query then path = path .. "?" .. parsed.query end

    local sock = socket.tcp()
    if not sock then return false, "cannot create socket" end
    local connected, connect_err = async_connect(sock, host, port)
    if not connected then
        sock:close()
        return false, "connect error: " .. tostring(connect_err)
    end

    if parsed.scheme == "https" then
        local ssl_sock, wrap_err = ssl.wrap(sock, {
            mode = "client",
            protocol = "any",
            verify = "none",
            options = { "all", "no_sslv2", "no_sslv3" },
        })
        if not ssl_sock then
            sock:close()
            return false, "ssl wrap error: " .. tostring(wrap_err)
        end
        sock = ssl_sock
        sock:settimeout(0)
        if sock.sni then sock:sni(host) end
        local handshook, handshake_err = async_handshake(sock)
        if not handshook then
            sock:close()
            return false, "ssl handshake error: " .. tostring(handshake_err)
        end
    end

    local method = (req.method or "GET"):upper()
    local body = req.body
    local lines = {
        method .. " " .. path .. " HTTP/1.1",
        "Host: " .. host,
        "User-Agent: " .. tostring(req.user_agent or "KOReader"),
    }
    for key, value in pairs(req.headers or {}) do
        lines[#lines + 1] = tostring(key) .. ": " .. tostring(value)
    end
    if body then
        lines[#lines + 1] = "Content-Length: " .. tostring(#body)
    end
    lines[#lines + 1] = "Connection: close"
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""

    local sent, send_err = async_send(sock, table.concat(lines, "\r\n") .. (body or ""))
    if not sent then
        sock:close()
        return false, "send error: " .. tostring(send_err)
    end

    local status_line, headers, header_err = read_headers(sock)
    if not status_line then
        sock:close()
        return false, "no status line: " .. tostring(header_err)
    end
    local code = tonumber(status_line:match("HTTP/%d%.%d%s+(%d%d%d)"))

    if code and code >= 300 and code < 400 and headers["location"] then
        local location = tostring(headers["location"]):gsub("\r$", "")
        sock:close()
        local keep = (code == 307 or code == 308)
        return run_request{
            url = socket_url.absolute(url, location),
            method = keep and method or "GET",
            headers = keep and req.headers or nil,
            body = keep and body or nil,
            redirects = redirects + 1,
            user_agent = req.user_agent,
            timeout = req.timeout,
        }
    end

    local content, body_err = read_body(sock, headers)
    sock:close()
    if not code then return false, "invalid status line" end
    if not content then return false, body_err or "read error" end
    return true, code, headers, content
end

-- Start a request. Returns a handle with :cancel().
-- callbacks.on_done(status, headers, body) / callbacks.on_error(err)
function AsyncHttp.request(req, callbacks)
    callbacks = callbacks or {}
    local handle = { cancelled = false, dead = false, sock = nil, mode = nil }
    local co = coroutine.create(function() return run_request(req) end)
    local now = socket.gettime or os.time
    local started_at = now()
    local timeout = tonumber(req.timeout) or DEFAULT_TIMEOUT

    local function close_socket()
        if handle.sock then
            pcall(function() handle.sock:close() end)
            handle.sock = nil
        end
    end

    local function finish(ok, a, b, c)
        if handle.dead then return end
        handle.dead = true
        close_socket()
        if ok then
            if callbacks.on_done then
                local called, err = pcall(callbacks.on_done, a, b, c)
                if not called then logger.warn("async_http on_done failed:", tostring(err)) end
            end
        elseif callbacks.on_error then
            local called, err = pcall(callbacks.on_error, a)
            if not called then logger.warn("async_http on_error failed:", tostring(err)) end
        end
    end

    local function pump()
        if handle.dead then return end
        if handle.cancelled then return finish(false, "cancelled") end
        if now() - started_at > timeout then
            close_socket()
            return finish(false, "timeout")
        end

        local sock, mode = handle.sock, handle.mode
        if sock then
            local recvt, sendt = {}, {}
            if mode == "r" then recvt[1] = sock else sendt[1] = sock end
            pcall(socket.select, recvt, sendt, SELECT_SLICE)
            handle.sock, handle.mode = nil, nil
        end

        local ok, a, b, c, d = coroutine.resume(co)
        if not ok then
            return finish(false, tostring(a))
        end
        if coroutine.status(co) == "dead" then
            if a then
                return finish(true, b, c, d)
            end
            return finish(false, b)
        end
        handle.sock, handle.mode = a, b
        UIManager:scheduleIn(PUMP_DELAY, pump)
    end

    UIManager:scheduleIn(START_DELAY, pump)
    return {
        cancel = function()
            handle.cancelled = true
            close_socket()
        end,
    }
end

return AsyncHttp
