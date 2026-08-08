local Compatible = {}
Compatible.__index = Compatible

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function responseText(content)
    if type(content) == "string" then return content end
    if type(content) ~= "table" then return nil end
    local parts = {}
    for _, part in ipairs(content) do
        if type(part) == "table" and type(part.text) == "string" then
            table.insert(parts, part.text)
        end
    end
    return #parts > 0 and table.concat(parts) or nil
end

local function decodeArguments(json, value)
    if type(value) == "table" then return value end
    if type(value) ~= "string" or value == "" then return {} end
    local ok, decoded = pcall(json.decode, value)
    if not ok or type(decoded) ~= "table" then
        return nil, "The AI service returned malformed tool arguments."
    end
    return decoded
end

local function finishError(reason)
    if reason == "length" then
        return "The AI service stopped because its output limit was reached."
    elseif reason == "content_filter" then
        return "The AI service stopped because content was filtered."
    elseif reason == "insufficient_system_resource" then
        return "The AI service stopped because inference resources were unavailable."
    elseif reason == "error" then
        return "The AI service stopped because the upstream provider failed."
    end
end

local function providerError(decoded)
    local err = type(decoded) == "table" and decoded.error
    if type(err) ~= "table" then return nil end
    return tostring(err.message or err.type or err.code or "provider error")
end

function Compatible:new(configuration, transport, stream_transport, variant)
    local instance = setmetatable({}, self)
    instance.configuration = configuration or {}
    instance.transport = assert(transport)
    instance.stream_transport = stream_transport
    instance.variant = assert(variant)
    return instance
end

function Compatible:_wireMessages(json, request)
    local messages = {{ role = "system", content = request.system }}
    for _, message in ipairs(request.messages or {}) do
        if message.role == "assistant" and type(message.tool_calls) == "table" then
            local calls = {}
            for _, call in ipairs(message.tool_calls) do
                table.insert(calls, {
                    id = call.id,
                    type = "function",
                    ["function"] = {
                        name = call.name,
                        arguments = json.encode(call.arguments or {}),
                    },
                })
            end
            local assistant = {
                role = "assistant",
                content = message.content or "",
                tool_calls = calls,
            }
            local state = type(message.provider_state) == "table" and message.provider_state or {}
            for _, field in ipairs(self.variant.provider_state_fields or {}) do
                if state[field] ~= nil then assistant[field] = state[field] end
            end
            table.insert(messages, assistant)
        elseif message.role == "tool" then
            table.insert(messages, {
                role = "tool",
                tool_call_id = message.tool_call_id,
                content = type(message.content) == "string" and message.content or json.encode(message.content),
            })
        elseif message.role == "user" or message.role == "assistant" then
            table.insert(messages, { role = message.role, content = message.content })
        end
    end
    return messages
end

function Compatible:_providerState(source)
    local state
    for _, field in ipairs(self.variant.provider_state_fields or {}) do
        if type(source) == "table" and source[field] ~= nil then
            state = state or {}
            state[field] = source[field]
        end
    end
    return state
end

function Compatible:_newStreamAccumulator(json, on_delta, on_activity, on_tool_delta)
    local accumulator = {
        buffer = "",
        event_data = {},
        text_parts = {},
        provider_state = {},
        tool_calls = {},
        event_count = 0,
        finish_reason = nil,
        error = nil,
    }

    local function appendState(field, value)
        if type(value) == "string" then
            accumulator.provider_state[field] = tostring(accumulator.provider_state[field] or "") .. value
        elseif type(value) == "table" then
            local target = accumulator.provider_state[field]
            if type(target) ~= "table" then target = {}; accumulator.provider_state[field] = target end
            for _, item in ipairs(value) do table.insert(target, item) end
        end
    end

    local function dispatchEvent()
        if #accumulator.event_data == 0 then return end
        local data = table.concat(accumulator.event_data, "\n")
        accumulator.event_data = {}
        if data == "[DONE]" then return end
        local ok, decoded = pcall(json.decode, data)
        if not ok or type(decoded) ~= "table" then
            accumulator.error = "The AI service returned an invalid streaming response."
            return
        end
        local upstream_error = providerError(decoded)
        if upstream_error then accumulator.error = "AI provider error: " .. upstream_error; return end
        accumulator.event_count = accumulator.event_count + 1
        local choice = decoded.choices and decoded.choices[1]
        if type(choice) ~= "table" then return end
        if type(choice.finish_reason) == "string" then accumulator.finish_reason = choice.finish_reason end
        local delta = choice.delta
        if type(delta) ~= "table" then return end
        for _, field in ipairs(self.variant.provider_state_fields or {}) do
            if delta[field] ~= nil then
                appendState(field, delta[field])
                if type(on_activity) == "function" then on_activity("reasoning") end
            end
        end
        if type(delta.content) == "string" and delta.content ~= "" then
            table.insert(accumulator.text_parts, delta.content)
            if type(on_delta) == "function" then on_delta(delta.content) end
        end
        if type(delta.tool_calls) == "table" then
            for sequence, raw_call in ipairs(delta.tool_calls) do
                if type(raw_call) == "table" then
                    local index = tonumber(raw_call.index) or (sequence - 1)
                    local call = accumulator.tool_calls[index]
                    if not call then
                        call = { id = "", name = "", arguments_json = "" }
                        accumulator.tool_calls[index] = call
                    end
                    if type(raw_call.id) == "string" then call.id = call.id .. raw_call.id end
                    local fn = raw_call["function"]
                    if type(fn) == "table" then
                        if type(fn.name) == "string" then call.name = call.name .. fn.name end
                        if type(fn.arguments) == "string" then
                            call.arguments_json = call.arguments_json .. fn.arguments
                        end
                    end
                    if type(on_tool_delta) == "function" then
                        on_tool_delta({
                            index = index,
                            id = call.id,
                            name = call.name,
                            arguments_json = call.arguments_json,
                        })
                    end
                end
            end
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
            local line = self.buffer
            self.buffer = ""
            if line:sub(-1) == "\r" then line = line:sub(1, -2) end
            local field, value = line:match("^([^:]+):?(.*)$")
            if field == "data" then
                if value:sub(1, 1) == " " then value = value:sub(2) end
                table.insert(self.event_data, value)
            end
        end
        dispatchEvent()
        if self.error then return nil, self.error end
        if self.event_count == 0 then return nil, "The AI service returned an invalid streaming response." end
        local finish_error = finishError(self.finish_reason)
        if finish_error then return nil, finish_error end
        local calls, indexes = {}, {}
        for index in pairs(self.tool_calls) do table.insert(indexes, index) end
        table.sort(indexes)
        for _, index in ipairs(indexes) do
            local raw_call = self.tool_calls[index]
            if raw_call.name == "" then return nil, "The AI service returned an invalid tool call." end
            local args, args_err = decodeArguments(json, raw_call.arguments_json)
            if not args then return nil, args_err end
            table.insert(calls, {
                id = raw_call.id ~= "" and raw_call.id or nil,
                name = raw_call.name,
                arguments = args,
            })
        end
        local state = next(self.provider_state) and self.provider_state or nil
        return {
            text = #self.text_parts > 0 and table.concat(self.text_parts) or nil,
            provider_state = state,
            tool_calls = calls,
        }
    end

    return accumulator
end


function Compatible:chat(request, on_delta, stream_control, on_activity, on_tool_delta)
    local config = self.configuration
    if trim(config.api_key) == "" then return nil, "BookAgent is not configured: API key is missing." end
    if trim(config.base_url) == "" or trim(config.model) == "" then
        return nil, "BookAgent is not configured: base_url or model is missing."
    end

    local json = require("json")
    local body = {
        model = config.model,
        messages = self:_wireMessages(json, request),
        tools = {},
    }
    local max_tokens = tonumber(config.max_completion_tokens or config.max_tokens)
    if max_tokens then body[self.variant.max_tokens_field] = max_tokens end
    if config.temperature ~= nil then body.temperature = config.temperature end
    for key, value in pairs(config.parameters or {}) do body[key] = value end
    for _, tool in ipairs(request.tools or {}) do
        table.insert(body.tools, {
            type = "function",
            ["function"] = {
                name = tool.name,
                description = tool.description,
                parameters = tool.parameters,
            },
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
        ["Authorization"] = "Bearer " .. config.api_key,
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
        local message = decoded_ok and providerError(decoded)
        return nil, string.format("AI service HTTP %s: %s", tostring(code or "?"), tostring(message or "request failed"))
    end
    if use_stream then return accumulator:finish() end

    local decoded_ok, decoded = pcall(json.decode, response_body or "")
    if not decoded_ok or type(decoded) ~= "table" then return nil, "The AI service returned invalid JSON." end
    local upstream_error = providerError(decoded)
    if upstream_error then return nil, "AI provider error: " .. upstream_error end
    local choice = decoded.choices and decoded.choices[1]
    local message = type(choice) == "table" and choice.message
    if type(message) ~= "table" then return nil, "The AI service returned an invalid response." end
    local finish_error = finishError(choice.finish_reason)
    if finish_error then return nil, finish_error end
    local calls = {}
    if type(message.tool_calls) == "table" then
        for _, raw_call in ipairs(message.tool_calls) do
            local fn = type(raw_call) == "table" and raw_call["function"]
            if type(fn) ~= "table" or type(fn.name) ~= "string" then
                return nil, "The AI service returned an invalid tool call."
            end
            local args, args_err = decodeArguments(json, fn.arguments)
            if not args then return nil, args_err end
            table.insert(calls, { id = raw_call.id, name = fn.name, arguments = args })
        end
    end
    return {
        text = responseText(message.content),
        provider_state = self:_providerState(message),
        tool_calls = calls,
    }
end

return Compatible
