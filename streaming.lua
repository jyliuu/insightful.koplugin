local Streaming = {}

local MAX_ERROR_BODY = 65536

function Streaming.newFrameDecoder(on_data)
    return {
        buffer = "",
        on_data = on_data,
        status_code = nil,
        status_text = nil,
    }
end

function Streaming.feedFrames(decoder, bytes)
    decoder.buffer = decoder.buffer .. tostring(bytes or "")
    while true do
        local newline = decoder.buffer:find("\n", 1, true)
        if not newline then return true end
        local header = decoder.buffer:sub(1, newline - 1)
        local kind, length = header:match("^([DS])(%d+)$")
        length = tonumber(length)
        if not kind or not length then
            return nil, "Malformed stream frame header."
        end
        local payload_start = newline + 1
        local payload_end = payload_start + length - 1
        if #decoder.buffer < payload_end then return true end
        local payload = decoder.buffer:sub(payload_start, payload_end)
        decoder.buffer = decoder.buffer:sub(payload_end + 1)
        if kind == "D" then
            if decoder.on_data then
                local ok, err = pcall(decoder.on_data, payload)
                if not ok then return nil, tostring(err) end
            end
        else
            local code, status = payload:match("^([^\n]*)\n?(.*)$")
            decoder.status_code = tonumber(code)
            decoder.status_text = status ~= "" and status or code
        end
    end
end

function Streaming.finishFrames(decoder)
    if decoder.buffer ~= "" then
        return nil, "Incomplete stream frame."
    end
    return true
end

local function scheduleCollection(ffiutil, UIManager, pid, parent_read_fd)
    local function collect()
        if ffiutil.isSubProcessDone(pid) then
            if parent_read_fd then ffiutil.readAllFromFD(parent_read_fd) end
            return
        end
        if parent_read_fd and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0 then
            ffiutil.readAllFromFD(parent_read_fd)
            parent_read_fd = nil
        end
        UIManager:scheduleIn(1, collect)
    end
    UIManager:scheduleIn(1, collect)
end

function Streaming.httpPost(url, headers, body, timeout, verify_ssl, on_chunk, control)
    local running = coroutine.running()
    if not running then
        return false, nil, "", "Streaming request is not running in a coroutine."
    end

    local ffi = require("ffi")
    local ffiutil = require("ffi/util")
    local UIManager = require("ui/uimanager")
    local logger = require("logger")
    control = type(control) == "table" and control or {}

    local function writeFrame(fd, kind, payload)
        payload = tostring(payload or "")
        ffiutil.writeToFD(fd, kind .. tostring(#payload) .. "\n" .. payload)
    end

    local pid, parent_read_fd = ffiutil.runInSubProcess(function(_, child_write_fd)
        local ok, request_error = pcall(function()
            local ltn12 = require("ltn12")
            local socketutil_ok, socketutil = pcall(require, "socketutil")
            if socketutil_ok and socketutil and type(socketutil.set_timeout) == "function" then
                socketutil:set_timeout(timeout or 60, timeout or 60)
            end
            local client
            if tostring(url):match("^https://") then
                client = require("ssl.https")
                client.cert_verify = verify_ssl ~= false
            else
                client = require("socket.http")
            end
            local _, code, _, status = client.request{
                url = url,
                method = "POST",
                headers = headers,
                source = ltn12.source.string(body),
                sink = function(chunk)
                    if type(chunk) == "string" and chunk ~= "" then
                        writeFrame(child_write_fd, "D", chunk)
                    end
                    return 1
                end,
            }
            writeFrame(child_write_fd, "S", tostring(code or "") .. "\n" .. tostring(status or ""))
        end)
        if not ok then
            writeFrame(child_write_fd, "S", "\n" .. tostring(request_error))
        end
        ffi.C.close(child_write_fd)
    end, true)
    if not pid then
        return false, nil, "", "Could not start the streaming request."
    end

    local raw_parts, raw_size = {}, 0
    local decoder = Streaming.newFrameDecoder(function(chunk)
        if not on_chunk then
            raw_size = raw_size + #chunk
            table.insert(raw_parts, chunk)
        elseif raw_size < MAX_ERROR_BODY then
            local remaining = MAX_ERROR_BODY - raw_size
            local kept = chunk:sub(1, remaining)
            raw_size = raw_size + #kept
            table.insert(raw_parts, kept)
        end
        if on_chunk then on_chunk(chunk) end
    end)
    local cancelled = false
    local resume_task
    control.cancel = function()
        control.cancelled = true
        if resume_task and coroutine.status(running) == "suspended" then
            pcall(coroutine.resume, running, false)
        end
    end

    local read_buffer = ffi.new("uint8_t[?]", 16384)
    local stream_error
    while true do
        resume_task = function() coroutine.resume(running, true) end
        UIManager:scheduleIn(0.125, resume_task)
        local go_on = coroutine.yield()
        if not go_on or control.cancelled then
            UIManager:unschedule(resume_task)
            cancelled = true
            ffiutil.terminateSubProcess(pid)
            scheduleCollection(ffiutil, UIManager, pid, parent_read_fd)
            break
        end

        local available = ffiutil.getNonBlockingReadSize(parent_read_fd)
        while available and available > 0 do
            local wanted = math.min(available, 16384)
            local count = tonumber(ffi.C.read(parent_read_fd, read_buffer, wanted))
            if not count or count <= 0 then break end
            local ok, err = Streaming.feedFrames(decoder, ffi.string(read_buffer, count))
            if not ok then stream_error = err; break end
            available = ffiutil.getNonBlockingReadSize(parent_read_fd)
        end
        if stream_error then
            ffiutil.terminateSubProcess(pid)
            scheduleCollection(ffiutil, UIManager, pid, parent_read_fd)
            break
        end
        if ffiutil.isSubProcessDone(pid) then
            local tail = parent_read_fd and ffiutil.readAllFromFD(parent_read_fd) or ""
            if tail and tail ~= "" then
                local ok, err = Streaming.feedFrames(decoder, tail)
                if not ok then stream_error = err end
            end
            break
        end
    end
    control.cancel = nil
    resume_task = nil

    local raw_body = table.concat(raw_parts)
    if cancelled then return false, nil, raw_body, "Request canceled." end
    if stream_error then
        logger.warn("Insightful stream framing failed:", stream_error)
        return false, decoder.status_code, raw_body, stream_error
    end
    local finished, finish_error = Streaming.finishFrames(decoder)
    if not finished then return false, decoder.status_code, raw_body, finish_error end
    if not decoder.status_code then
        return false, nil, raw_body, decoder.status_text or "Streaming request failed."
    end
    return true, decoder.status_code, raw_body, decoder.status_text
end

return Streaming
