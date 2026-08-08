local Anthropic = {}
Anthropic.__index = Anthropic

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function stopError(reason)
    if reason == "max_tokens" then
        return "The AI service stopped because its output limit was reached."
    elseif reason == "model_context_window_exceeded" then
        return "The AI service stopped because its context window was exceeded."
    elseif reason == "refusal" then
        return "The AI service stopped because the request was refused."
    end
end

local function apiError(decoded)
    local err = type(decoded) == "table" and decoded.error
    if type(err) ~= "table" then return nil end
    return tostring(err.message or err.type or "provider error")
end

function Anthropic:new(configuration, transport, stream_transport)
    local instance = setmetatable({}, self)
    instance.configuration = configuration or {}
    instance.transport = assert(transport)
    instance.stream_transport = stream_transport
    return instance
end

function Anthropic:_wireMessages(json, request)
    local messages = {}
    for _, message in ipairs(request.messages or {}) do
        if message.role == "assistant" and type(message.tool_calls) == "table" then
            local content = {}
            if type(message.content) == "string" and message.content ~= "" then
                table.insert(content, { type = "text", text = message.content })
            end
            for _, call in ipairs(message.tool_calls) do
                table.insert(content, {
                    type = "tool_use",
                    id = call.id,
                    name = call.name,
                    input = call.arguments or {},
                })
            end
            table.insert(messages, { role = "assistant", content = content })
        elseif message.role == "tool" then
            table.insert(messages, {
                role = "user",
                content = {{
                    type = "tool_result",
                    tool_use_id = message.tool_call_id,
                    content = type(message.content) == "string" and message.content or json.encode(message.content),
                }},
            })
        elseif message.role == "user" or message.role == "assistant" then
            table.insert(messages, { role = message.role, content = message.content })
        end
    end
    return messages
end

function Anthropic:_newStreamAccumulator(json, on_delta, on_activity, on_tool_delta)
    local accumulator = {
        buffer = "",
        event_data = {},
        text_parts = {},
        tool_calls = {},
        event_count = 0,
        stop_reason = nil,
        error = nil,
    }

    local function dispatchEvent()
        if #accumulator.event_data == 0 then return end
        local data = table.concat(accumulator.event_data, "\n")
        accumulator.event_data = {}
        local ok, decoded = pcall(json.decode, data)
        if not ok or type(decoded) ~= "table" then
            accumulator.error = "The AI service returned an invalid Anthropic stream."
            return
        end
        accumulator.event_count = accumulator.event_count + 1
        if decoded.type == "error" then
            accumulator.error = "AI provider error: " .. tostring(apiError(decoded) or "streaming request failed")
        elseif decoded.type == "content_block_start" then
            local block = decoded.content_block
            local index = tonumber(decoded.index) or 0
            if type(block) == "table" and block.type == "tool_use" then
                accumulator.tool_calls[index] = {
                    id = block.id,
                    name = block.name,
                    input = type(block.input) == "table" and block.input or {},
                    arguments_json = "",
                }
                if type(on_tool_delta) == "function" then
                    on_tool_delta({ index = index, id = block.id, name = block.name, arguments_json = "" })
                end
            elseif type(block) == "table" and block.type == "text" and type(block.text) == "string" and block.text ~= "" then
                table.insert(accumulator.text_parts, block.text)
                if type(on_delta) == "function" then on_delta(block.text) end
            elseif type(block) == "table" and block.type == "thinking" and type(on_activity) == "function" then
                on_activity("reasoning")
            end
        elseif decoded.type == "content_block_delta" then
            local delta = decoded.delta
            local index = tonumber(decoded.index) or 0
            if type(delta) == "table" and delta.type == "text_delta" and type(delta.text) == "string" then
                table.insert(accumulator.text_parts, delta.text)
                if type(on_delta) == "function" then on_delta(delta.text) end
            elseif type(delta) == "table" and delta.type == "input_json_delta" then
                local call = accumulator.tool_calls[index]
                if call then
                    call.arguments_json = call.arguments_json .. tostring(delta.partial_json or "")
                    if type(on_tool_delta) == "function" then
                        on_tool_delta({
                            index = index,
                            id = call.id,
                            name = call.name,
                            arguments_json = call.arguments_json,
                        })
                    end
                end
            elseif type(delta) == "table" and delta.type == "thinking_delta" and type(on_activity) == "function" then
                on_activity("reasoning")
            end
        elseif decoded.type == "message_delta" and type(decoded.delta) == "table" then
            accumulator.stop_reason = decoded.delta.stop_reason or accumulator.stop_reason
        end
    end

    function accumulator:feed(chunk)
        if self.error then return nil, self.error end
        self.buffer = self.buffer .. tostring(chunk or "")
        while true do
            local newline = self.buffer:find("\n", 1, true)
            if not newline then break end
            local line = self.buffer:sub(1, newline - 1)
            self.buffer = self.buffer:sub(newline + 1)
            if line:sub(-1) == "\r" then line = line:sub(1, -2) end
            if line == "" then
                dispatchEvent()
            elseif line:sub(1, 1) ~= ":" then
                local field, value = line:match("^([^:]+):?(.*)$")
                if field == "data" then
                    if value:sub(1, 1) == " " then value = value:sub(2) end
                    table.insert(self.event_data, value)
                end
            end
            if self.error then return nil, self.error end
        end
        return true
    end

    function accumulator:finish()
        if self.buffer ~= "" then
            local field, value = self.buffer:match("^([^:]+):?%s?(.*)$")
            if field == "data" then table.insert(self.event_data, value) end
            self.buffer = ""
        end
        dispatchEvent()
        if self.error then return nil, self.error end
        if self.event_count == 0 then return nil, "The AI service returned an invalid Anthropic stream." end
        local stop_error = stopError(self.stop_reason)
        if stop_error then return nil, stop_error end
        local calls, indexes = {}, {}
        for index in pairs(self.tool_calls) do table.insert(indexes, index) end
        table.sort(indexes)
        for _, index in ipairs(indexes) do
            local raw_call = self.tool_calls[index]
            local arguments = raw_call.input
            if raw_call.arguments_json ~= "" then
                local ok, decoded = pcall(json.decode, raw_call.arguments_json)
                if not ok or type(decoded) ~= "table" then
                    return nil, "The AI service returned malformed tool arguments."
                end
                arguments = decoded
            end
            table.insert(calls, { id = raw_call.id, name = raw_call.name, arguments = arguments })
        end
        return {
            text = #self.text_parts > 0 and table.concat(self.text_parts) or nil,
            tool_calls = calls,
        }
    end

    return accumulator
end

function Anthropic:chat(request, on_delta, stream_control, on_activity, on_tool_delta)
    local config = self.configuration
    if trim(config.api_key) == "" then return nil, "BookAgent is not configured: API key is missing." end
    if trim(config.base_url) == "" or trim(config.model) == "" then
        return nil, "BookAgent is not configured: base_url or model is missing."
    end
    local json = require("json")
    local body = {
        model = config.model,
        system = request.system,
        messages = self:_wireMessages(json, request),
        tools = {},
        -- Anthropic's Messages API requires this field; it has no omitted default.
        max_tokens = tonumber(config.max_tokens) or 8192,
    }
    if config.temperature ~= nil then body.temperature = config.temperature end
    for key, value in pairs(config.parameters or {}) do body[key] = value end
    for _, tool in ipairs(request.tools or {}) do
        table.insert(body.tools, {
            name = tool.name,
            description = tool.description,
            input_schema = tool.parameters,
        })
    end
    local use_stream = config.stream ~= false
        and type(self.stream_transport) == "function"
        and type(on_delta) == "function"
    if use_stream then body.stream = true end
    local encoded = json.encode(body)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = use_stream and "text/event-stream" or "application/json",
        ["x-api-key"] = config.api_key,
        ["anthropic-version"] = config.anthropic_version or "2023-06-01",
        ["Content-Length"] = tostring(#encoded),
    }
    for key, value in pairs(config.headers or {}) do headers[key] = value end

    local accumulator
    local ok, code, response_body, status
    if use_stream then
        accumulator = self:_newStreamAccumulator(json, on_delta, on_activity, on_tool_delta)
        ok, code, response_body, status = self.stream_transport(
            config.base_url, headers, encoded, tonumber(config.timeout) or 60,
            config.verify_ssl ~= false,
            function(chunk)
                local chunk_ok, chunk_err = accumulator:feed(chunk)
                if not chunk_ok then error(chunk_err) end
            end,
            stream_control
        )
    else
        ok, code, response_body, status = self.transport(
            config.base_url, headers, encoded, tonumber(config.timeout) or 60,
            config.verify_ssl ~= false
        )
    end
    if not ok then return nil, "Couldn't reach the AI service: " .. tostring(status or code or "network error") end
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then
        local decoded_ok, decoded = pcall(json.decode, response_body or "")
        local message = decoded_ok and apiError(decoded)
        return nil, string.format("AI service HTTP %s: %s", tostring(code or "?"), tostring(message or "request failed"))
    end
    if use_stream then return accumulator:finish() end

    local decoded_ok, decoded = pcall(json.decode, response_body or "")
    if not decoded_ok or type(decoded) ~= "table" then return nil, "The AI service returned invalid JSON." end
    local upstream_error = apiError(decoded)
    if upstream_error then return nil, "AI provider error: " .. upstream_error end
    local stop_error = stopError(decoded.stop_reason)
    if stop_error then return nil, stop_error end
    local text_parts, calls = {}, {}
    for _, block in ipairs(decoded.content or {}) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            table.insert(text_parts, block.text)
        elseif type(block) == "table" and block.type == "tool_use" then
            table.insert(calls, {
                id = block.id,
                name = block.name,
                arguments = type(block.input) == "table" and block.input or {},
            })
        end
    end
    return {
        text = #text_parts > 0 and table.concat(text_parts) or nil,
        tool_calls = calls,
    }
end

return Anthropic
