local script = arg[0]:gsub("\\", "/")
local root = script:match("^(.*)/tests/run%.lua$") or "."

local Agent = dofile(root .. "/agent.lua")
local BookTools = dofile(root .. "/book_tools.lua")
local ConversationRenderer = dofile(root .. "/conversation_renderer.lua")
local ModelCatalog = dofile(root .. "/model_catalog.lua")
local ProviderProfiles = dofile(root .. "/provider_profiles.lua")
local ProviderRegistry = dofile(root .. "/providers/registry.lua"):new{
    compatible = dofile(root .. "/providers/openai_compatible.lua"),
    anthropic = dofile(root .. "/providers/anthropic.lua"),
    variants = {
        openai = dofile(root .. "/providers/openai.lua"),
        deepseek = dofile(root .. "/providers/deepseek.lua"),
        openrouter = dofile(root .. "/providers/openrouter.lua"),
    },
}
local Storage = dofile(root .. "/storage.lua")
local Stats = dofile(root .. "/stats.lua")
local Streaming = dofile(root .. "/streaming.lua")

local function loadChatController()
    local ui_manager = {
        forceRePaint = function() end,
        unschedule = function() end,
    }
    local modules = {
        ["ui/trapper"] = {},
        ["ui/uimanager"] = ui_manager,
        logger = { warn = function() end },
        gettext = function(text) return text end,
    }
    local previous = {}
    for name, module in pairs(modules) do
        previous[name] = package.loaded[name]
        package.loaded[name] = module
    end
    local Chat = dofile(root .. "/chat.lua")
    for name in pairs(modules) do package.loaded[name] = previous[name] end
    return Chat
end

local Chat = loadChatController()

local function loadChatList()
    local ui_manager = { shown = {}, closed = {} }
    function ui_manager:show(widget)
        table.insert(self.shown, widget)
    end
    function ui_manager:close(widget)
        table.insert(self.closed, widget)
    end
    function ui_manager:nextTick(callback)
        callback()
    end

    local function widgetStub()
        return {
            new = function(_, options) return options end,
        }
    end

    local modules = {
        ["ui/widget/confirmbox"] = widgetStub(),
        ["ui/widget/infomessage"] = widgetStub(),
        ["ui/widget/menu"] = widgetStub(),
        ["ui/uimanager"] = ui_manager,
        logger = { warn = function() end },
        gettext = function(text) return text end,
    }
    local previous = {}
    for name, module in pairs(modules) do
        previous[name] = package.loaded[name]
        package.loaded[name] = module
    end
    local ChatList = dofile(root .. "/chat_list.lua")
    for name in pairs(modules) do package.loaded[name] = previous[name] end
    return ChatList, ui_manager
end

local passed, failed = 0, 0

local function same(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message or "values differ", tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(value, message)
    if not value then error(message or "expected a truthy value", 2) end
end

local function contains(text, fragment, message)
    if not tostring(text):find(fragment, 1, true) then
        error((message or "missing text") .. ": " .. tostring(fragment), 2)
    end
end

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("ok - ", name, "\n")
    else
        failed = failed + 1
        io.write("not ok - ", name, "\n  ", tostring(err), "\n")
    end
end

local function copyTable(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[copyTable(key, seen)] = copyTable(item, seen)
    end
    return result
end

local function conversation()
    return {
        version = 1,
        book = { id = "book-a", title = "The Book", authors = "A. Writer", path = "/books/a.epub" },
        messages = { Agent.makeUserMessage("Where is Mentor discussed?", nil, 1) },
    }
end

local function scriptedProvider(responses)
    return {
        index = 0,
        requests = {},
        chat = function(self, request)
            self.index = self.index + 1
            table.insert(self.requests, request)
            local response = responses[self.index]
            if type(response) == "function" then return response(request, self.index) end
            return response
        end,
    }
end

test("legacy provider configuration remains available", function()
    local configuration = {
        provider = "deepseek",
        base_url = "https://api.deepseek.test/chat/completions",
        model = "deepseek-test",
        api_key = "legacy-secret",
        timeout = 45,
    }
    local available = ProviderProfiles.available(configuration)
    same(#available, 1, "legacy provider count")
    same(available[1], "deepseek", "legacy provider ID")
    local resolved, selected = ProviderProfiles.resolve(configuration, "openrouter")
    same(selected, "deepseek", "legacy fallback provider")
    same(resolved.api_key, "legacy-secret", "legacy API key")
    same(resolved.timeout, 45, "legacy timeout")
end)

test("provider profiles list keys and merge shared settings", function()
    local configuration = {
        provider = "deepseek",
        timeout = 60,
        stream = true,
        verify_ssl = true,
        providers = {
            openai = { api_key = "" },
            deepseek = {
                api_key = "deepseek-secret",
                base_url = "https://api.deepseek.test/chat/completions",
                model = "deepseek-test",
            },
            openrouter = {
                api_key = "openrouter-secret",
                base_url = "https://openrouter.test/api/v1/chat/completions",
                model = "openrouter/auto",
                parameters = { reasoning = { effort = "low" } },
            },
        },
    }
    local available = ProviderProfiles.available(configuration)
    same(#available, 2, "profile count")
    same(available[1], "deepseek", "first configured profile")
    same(available[2], "openrouter", "second configured profile")

    local resolved, selected = ProviderProfiles.resolve(configuration, "openrouter")
    same(selected, "openrouter", "selected provider")
    same(resolved.provider, "openrouter", "resolved provider")
    same(resolved.api_key, "openrouter-secret", "resolved API key")
    same(resolved.base_url, "https://openrouter.test/api/v1/chat/completions", "resolved endpoint")
    same(resolved.model, "openrouter/auto", "resolved model")
    same(resolved.timeout, 60, "shared timeout")
    same(resolved.stream, true, "shared streaming setting")
    same(resolved.parameters.reasoning.effort, "low", "profile parameters")
    same(resolved.providers, nil, "profiles are not sent to provider adapters")

    local chosen = ProviderProfiles.resolve(configuration, "openrouter", "vendor/chosen-model")
    same(chosen.model, "vendor/chosen-model", "saved model overrides profile model")

    local fallback, fallback_id = ProviderProfiles.resolve(configuration, "anthropic")
    same(fallback_id, "deepseek", "missing key falls back to default")
    same(fallback.api_key, "deepseek-secret", "default profile key")
end)

test("model catalog uses provider endpoints and stays bounded", function()
    local captured = {}
    local decoded = {
        data = {
            { id = "vendor/one", name = "One" },
            { id = "vendor/two", name = "Two" },
            { id = "vendor/three", name = "Three" },
        },
    }
    local catalog = ModelCatalog:new{
        limit = 3,
        json = { decode = function() return decoded end },
        transport = function(url, headers, timeout, verify_ssl)
            captured = {
                url = url,
                authorization = headers.Authorization,
                timeout = timeout,
                verify_ssl = verify_ssl,
            }
            return true, 200, "models", "OK"
        end,
    }
    local models, truncated = catalog:list({
        provider = "openrouter",
        base_url = "https://openrouter.test/api/v1/chat/completions",
        model = "openrouter/auto",
        api_key = "secret",
        timeout = 12,
        verify_ssl = true,
    }, "Claude Sonnet")
    same(#models, 3, "bounded model count")
    same(models[1].id, "openrouter/auto", "configured model first")
    same(models[2].id, "vendor/one", "first returned model")
    same(models[2].name, "One", "model display name")
    same(truncated, true, "truncated model list")
    contains(captured.url, "/api/v1/models?", "OpenRouter model endpoint")
    contains(captured.url, "supported_parameters=tools", "tool-capable model filter")
    contains(captured.url, "q=Claude%20Sonnet", "encoded model search")
    same(captured.authorization, "Bearer secret", "model authorization")
    same(captured.timeout, 12, "model request timeout")
    same(captured.verify_ssl, true, "model certificate check")

    decoded.data = {{ id = "deepseek-v4-flash" }, { id = "deepseek-v4-pro" }}
    catalog:list({
        provider = "deepseek",
        base_url = "https://api.deepseek.test/chat/completions",
        model = "deepseek-v4-flash",
        api_key = "secret",
    })
    same(captured.url, "https://api.deepseek.test/models", "DeepSeek model endpoint")
end)

test("model catalog controls missing keys and invalid responses", function()
    local catalog = ModelCatalog:new{
        json = { decode = function() error("bad JSON") end },
        transport = function() return true, 200, "bad", "OK" end,
    }
    local models, _, err = catalog:list({ provider = "deepseek", base_url = "https://api.deepseek.test" })
    same(models, nil, "missing key model result")
    contains(err, "API key", "missing model API key")
    models, _, err = catalog:list({
        provider = "deepseek",
        base_url = "https://api.deepseek.test",
        api_key = "secret",
    })
    same(models, nil, "invalid JSON model result")
    contains(err, "invalid JSON", "invalid model JSON")
end)

test("agent executes search then read and returns final text", function()
    local provider = scriptedProvider({
        {
            provider_state = { reasoning_content = "Find the first passage." },
            tool_calls = {{ id = "c1", name = "search_book", arguments = { query = "Mentor" } }},
        },
        { tool_calls = {{ id = "c2", name = "read_around", arguments = { hit_id = "h1" } }} },
        { text = "Mentor appears in the opening section." },
    })
    local calls = {}
    local tools = {
        execute = function(_, name, args)
            table.insert(calls, { name = name, args = args })
            if name == "search_book" then return { ok = true, hits = {{ id = "h1", page = 2 }} } end
            return { ok = true, text = "surrounding passage" }
        end,
    }
    local answer, err = Agent.run(conversation(), { provider = provider, book_tools = tools })
    same(err, nil, "agent error")
    same(answer, "Mentor appears in the opening section.", "final answer")
    same(#calls, 2, "tool count")
    same(calls[1].name, "search_book", "first tool")
    same(calls[2].name, "read_around", "second tool")
    same(#provider.requests[3].messages, 5, "working message count")
    same(provider.requests[2].messages[2].provider_state.reasoning_content, "Find the first passage.", "provider state replay")
end)

test("multiple tool calls execute before the next provider turn", function()
    local provider = scriptedProvider({
        { tool_calls = {
            { id = "a", name = "search_book", arguments = { query = "Athena" } },
            { id = "m", name = "search_book", arguments = { query = "Mentor" } },
        } },
        function(request)
            local tool_messages = 0
            for _, message in ipairs(request.messages) do
                if message.role == "tool" then tool_messages = tool_messages + 1 end
            end
            same(tool_messages, 2, "tool results before second request")
            return { text = "Both searches completed." }
        end,
    })
    local names = {}
    local tools = { execute = function(_, name) table.insert(names, name); return { ok = true } end }
    local answer, err = Agent.run(conversation(), { provider = provider, book_tools = tools })
    same(err, nil, "agent error")
    same(answer, "Both searches completed.", "answer")
    same(#names, 2, "executed calls")
end)

test("agent adds token use across tool-call requests", function()
    local provider = scriptedProvider({
        {
            tool_calls = {{ id = "a", name = "toc", arguments = {} }},
            usage = { input_tokens = 100, output_tokens = 20, total_tokens = 120 },
        },
        {
            text = "Finished.",
            usage = {
                input_tokens = 150,
                output_tokens = 30,
                total_tokens = 180,
                cost_usd = 0.0015,
            },
        },
    })
    local answer, err, usage = Agent.run(conversation(), {
        provider = provider,
        book_tools = { execute = function() return { ok = true } end },
    })
    same(err, nil, "agent error")
    same(answer, "Finished.", "answer")
    same(usage.requests, 2, "model requests")
    same(usage.measured_requests, 2, "measured model requests")
    same(usage.input_tokens, 250, "input tokens")
    same(usage.output_tokens, 50, "output tokens")
    same(usage.total_tokens, 300, "total tokens")
    same(usage.costed_requests, 1, "costed model requests")
    same(usage.cost_usd, 0.0015, "reported cost")
end)

test("agent keeps reported token use when a later request fails", function()
    local provider = scriptedProvider({
        {
            tool_calls = {{ id = "a", name = "toc", arguments = {} }},
            usage = { input_tokens = 100, output_tokens = 20, total_tokens = 120 },
        },
        function()
            return nil, "The AI service stopped because its output limit was reached.", {
                input_tokens = 150,
                output_tokens = 30,
                total_tokens = 180,
            }
        end,
    })
    local answer, err, usage = Agent.run(conversation(), {
        provider = provider,
        book_tools = { execute = function() return { ok = true } end },
    })
    same(answer, nil, "failed answer")
    contains(err, "output limit", "provider error")
    same(usage.requests, 2, "completed model requests")
    same(usage.measured_requests, 2, "measured failed request")
    same(usage.total_tokens, 300, "failed request token total")
end)

test("malformed provider response is controlled", function()
    local answer, err = Agent.run(conversation(), {
        provider = scriptedProvider({ { unexpected = true } }),
        book_tools = { execute = function() return { ok = true } end },
    })
    same(answer, nil, "answer should be absent")
    contains(err, "neither text nor tool calls", "malformed response error")
end)

test("failed book tool is returned to the model as a failure", function()
    local provider = scriptedProvider({
        { tool_calls = {{ id = "bad", name = "search_book", arguments = { query = "x" } }} },
        function(request)
            local result
            for _, message in ipairs(request.messages) do
                if message.role == "tool" then result = message.content end
            end
            same(result.ok, false, "tool failure flag")
            contains(result.error, "not available", "tool failure message")
            return { text = "The book could not be searched." }
        end,
    })
    local tools = { execute = function() return { ok = false, error = "Search is not available." } end }
    local answer, err = Agent.run(conversation(), { provider = provider, book_tools = tools })
    same(err, nil, "agent error")
    same(answer, "The book could not be searched.", "answer after tool failure")
end)

test("DeepSeek adapter returns neutral tool calls and preserves reasoning state", function()
    local previous_json = package.loaded.json
    local encoded_body
    package.loaded.json = {
        encode = function(value) encoded_body = value; return "encoded-request" end,
        decode = function(text)
            if text == "provider-response" then
                return {
                    usage = { prompt_tokens = 40, completion_tokens = 8, total_tokens = 48 },
                    choices = {{
                        message = {
                            content = nil,
                            reasoning_content = "Use the book search tool.",
                            tool_calls = {{
                                id = "call-1",
                                ["function"] = { name = "search_book", arguments = "tool-arguments" },
                            }},
                        },
                    }},
                }
            elseif text == "tool-arguments" then
                return { query = "Mentor" }
            end
            error("unexpected JSON input")
        end,
    }
    local captured
    local provider = ProviderRegistry:newProvider({
        provider = "deepseek",
        base_url = "https://example.test/v1/chat/completions",
        model = "test-model",
        api_key = "secret",
    }, function(url, headers, body)
        captured = { url = url, headers = headers, body = body }
        return true, 200, "provider-response", "OK"
    end)
    local response, err = provider:chat{
        system = "system",
        messages = {{ role = "user", content = "question" }},
        tools = Agent.tool_schemas,
    }
    package.loaded.json = previous_json
    same(err, nil, "provider error")
    same(response.tool_calls[1].name, "search_book", "neutral tool name")
    same(response.tool_calls[1].arguments.query, "Mentor", "decoded tool arguments")
    same(response.provider_state.reasoning_content, "Use the book search tool.", "provider reasoning state")
    same(response.usage.input_tokens, 40, "provider input tokens")
    same(response.usage.output_tokens, 8, "provider output tokens")
    same(response.usage.total_tokens, 48, "provider total tokens")
    same(captured.url, "https://example.test/v1/chat/completions", "request URL")
    same(captured.body, "encoded-request", "encoded body")
    same(encoded_body.max_tokens, nil, "default request has no output-token cap")
    same(encoded_body.temperature, nil, "default request has no temperature override")
    same(encoded_body.tool_choice, nil, "provider chooses its default tool behavior")
    contains(captured.headers.Authorization, "Bearer", "authorization header")
end)

test("OpenAI and OpenRouter adapters use their own token field", function()
    local previous_json = package.loaded.json
    local encoded_body
    package.loaded.json = {
        encode = function(value) encoded_body = value; return "request" end,
        decode = function(value)
            if value == "response" then
                return {
                    choices = {{ finish_reason = "stop", message = { content = "Done." } }},
                    usage = {
                        prompt_tokens = 25,
                        completion_tokens = 10,
                        total_tokens = 35,
                        cost = 0.0007,
                    },
                }
            end
            error("unexpected JSON: " .. tostring(value))
        end,
    }
    for _, provider_id in ipairs({ "openai", "openrouter" }) do
        local provider = ProviderRegistry:newProvider({
            provider = provider_id,
            base_url = "https://example.test/v1/chat/completions",
            model = "test-model",
            api_key = "secret",
            max_tokens = 2500,
            stream = false,
        }, function() return true, 200, "response", "OK" end)
        local response, err = provider:chat{ system = "system", messages = {}, tools = {} }
        same(err, nil, provider_id .. " error")
        same(response.text, "Done.", provider_id .. " text")
        same(response.usage.total_tokens, 35, provider_id .. " token use")
        same(encoded_body.max_completion_tokens, 2500, provider_id .. " token field")
        same(encoded_body.max_tokens, nil, provider_id .. " legacy token field absent")
        if provider_id == "openrouter" then
            same(response.usage.cost_usd, 0.0007, "OpenRouter reported cost")
        else
            same(response.usage.cost_usd, nil, "OpenAI has no response cost")
        end
    end
    package.loaded.json = previous_json
end)

test("Anthropic adapter uses Messages headers, body, stream, and tool blocks", function()
    local previous_json = package.loaded.json
    local encoded_body
    local decoded = {
        start = {
            type = "message_start",
            message = { usage = {
                input_tokens = 90,
                cache_creation_input_tokens = 10,
                cache_read_input_tokens = 20,
                output_tokens = 1,
            } },
        },
        tool = {
            type = "content_block_start",
            index = 0,
            content_block = { type = "tool_use", id = "call-a", name = "toc", input = {} },
        },
        args = {
            type = "content_block_delta",
            index = 0,
            delta = { type = "input_json_delta", partial_json = "{}" },
        },
        stop = {
            type = "message_delta",
            delta = { stop_reason = "tool_use" },
            usage = { output_tokens = 9 },
        },
    }
    package.loaded.json = {
        encode = function(value) encoded_body = value; return "anthropic-request" end,
        decode = function(value)
            if decoded[value] then return decoded[value] end
            if value == "{}" then return {} end
            error("unexpected JSON: " .. tostring(value))
        end,
    }
    local captured_headers
    local provider = ProviderRegistry:newProvider({
        provider = "anthropic",
        base_url = "https://api.anthropic.com/v1/messages",
        model = "claude-test",
        api_key = "secret",
    }, function() error("blocking transport should not run") end, function(_, headers, body, _, _, on_chunk)
        captured_headers = headers
        same(body, "anthropic-request", "Anthropic request body")
        on_chunk("event: message_start\ndata: start\n\nevent: content_block_start\ndata: tool\n\n")
        on_chunk("event: content_block_delta\ndata: args\n\nevent: message_delta\ndata: stop\n\n")
        return true, 200, "", "OK"
    end)
    local response, err = provider:chat({
        system = "system",
        messages = {{ role = "user", content = "question" }},
        tools = Agent.tool_schemas,
    }, function() end, {})
    package.loaded.json = previous_json
    same(err, nil, "Anthropic stream error")
    same(response.tool_calls[1].name, "toc", "Anthropic neutral tool name")
    same(response.usage.input_tokens, 120, "Anthropic input tokens include cache use")
    same(response.usage.output_tokens, 9, "Anthropic output tokens")
    same(response.usage.total_tokens, 129, "Anthropic total tokens")
    same(captured_headers["x-api-key"], "secret", "Anthropic API key header")
    same(captured_headers["anthropic-version"], "2023-06-01", "Anthropic version header")
    same(captured_headers.Authorization, nil, "Anthropic bearer header absent")
    same(encoded_body.system, "system", "Anthropic top-level system prompt")
    same(encoded_body.max_tokens, 8192, "Anthropic required token limit")
    same(encoded_body.tools[1].input_schema.type, "object", "Anthropic tool schema")
end)

test("stream frame decoder preserves split payloads and status", function()
    local chunks = {}
    local decoder = Streaming.newFrameDecoder(function(chunk) table.insert(chunks, chunk) end)
    truthy(Streaming.feedFrames(decoder, "D3\nab"), "first split frame")
    truthy(Streaming.feedFrames(decoder, "cD4\ndefgS6\n200\nOK"), "remaining frames")
    truthy(Streaming.finishFrames(decoder), "complete frame stream")
    same(table.concat(chunks), "abcdefg", "decoded data")
    same(decoder.status_code, 200, "decoded status code")
    same(decoder.status_text, "OK", "decoded status text")
end)

test("SSE accumulator joins split text without exposing reasoning", function()
    local decoded = {
        first = { choices = {{ delta = { reasoning_content = "private ", content = "Hello" } }} },
        thought = { choices = {{ delta = { reasoning_content = "reasoning" } }} },
        second = { choices = {{ delta = { content = " world" } }} },
    }
    local deltas = {}
    local activity = {}
    local provider = ProviderRegistry:newProvider({ provider = "deepseek", api_key = "x", base_url = "x", model = "x" }, function() end)
    local accumulator = provider:_newStreamAccumulator(
        { decode = function(value) return assert(decoded[value]) end },
        function(delta) table.insert(deltas, delta) end,
        function(kind) table.insert(activity, kind) end
    )
    truthy(accumulator:feed("data: fir"), "first partial SSE chunk")
    truthy(accumulator:feed("st\r\n\r\ndata: thought\n\ndata: second\n\ndata: [DONE]\n\n"), "second SSE chunk")
    local response, err = accumulator:finish()
    same(err, nil, "stream accumulator error")
    same(response.text, "Hello world", "joined streamed text")
    same(response.provider_state.reasoning_content, "private reasoning", "hidden reasoning retained for tool replay")
    same(table.concat(deltas), "Hello world", "live deltas")
    same(activity[1], "reasoning", "hidden reasoning activity")
    truthy(not response.text:find("private", 1, true), "reasoning is not returned")
end)

test("stream output-limit stop is not accepted as a complete answer", function()
    local decoded = {
        text = { choices = {{ delta = { content = "Partial answer" } }} },
        limit = {
            choices = {{ delta = {}, finish_reason = "length" }},
            usage = { prompt_tokens = 50, completion_tokens = 10, total_tokens = 60 },
        },
    }
    local provider = ProviderRegistry:newProvider({ provider = "deepseek", api_key = "x", base_url = "x", model = "x" }, function() end)
    local accumulator = provider:_newStreamAccumulator({ decode = function(value) return assert(decoded[value]) end })
    truthy(accumulator:feed("data: text\n\ndata: limit\n\ndata: [DONE]\n\n"), "limited stream feed")
    local response, err, usage = accumulator:finish()
    same(response, nil, "limited stream response")
    contains(err, "output limit", "limited stream error")
    same(usage.total_tokens, 60, "limited stream token use")
end)

test("SSE accumulator rebuilds fragmented native tool calls", function()
    local decoded = {
        tool1 = { choices = {{ delta = { tool_calls = {{
            index = 0,
            id = "call-",
            ["function"] = { name = "search_", arguments = '{"query":"' },
        }} } }} },
        tool2 = { choices = {{ delta = { tool_calls = {{
            index = 0,
            id = "1",
            ["function"] = { name = "book", arguments = 'Mentor"}' },
        }} } }} },
    }
    local json = {
        decode = function(value)
            if decoded[value] then return decoded[value] end
            if value == '{"query":"Mentor"}' then return { query = "Mentor" } end
            error("unexpected JSON: " .. value)
        end,
    }
    local tool_deltas = {}
    local provider = ProviderRegistry:newProvider({ provider = "openai", api_key = "x", base_url = "x", model = "x" }, function() end)
    local accumulator = provider:_newStreamAccumulator(json, nil, nil, function(call)
        table.insert(tool_deltas, call)
    end)
    truthy(accumulator:feed("data: tool1\n\ndata: tool2\n\n"), "tool SSE")
    local response, err = accumulator:finish()
    same(err, nil, "tool stream error")
    same(response.tool_calls[1].id, "call-1", "fragmented call ID")
    same(response.tool_calls[1].name, "search_book", "fragmented function name")
    same(response.tool_calls[1].arguments.query, "Mentor", "fragmented arguments")
    same(tool_deltas[#tool_deltas].name, "search_book", "live function name")
    same(tool_deltas[#tool_deltas].arguments_json, '{"query":"Mentor"}', "live argument fragments")
end)

test("provider requests SSE and emits text deltas", function()
    local previous_json = package.loaded.json
    local encoded_body
    package.loaded.json = {
        encode = function(value) encoded_body = value; return "encoded-stream-request" end,
        decode = function(value)
            if value == "one" then return { choices = {{ delta = { content = "Live " } }} } end
            if value == "two" then return { choices = {{ delta = { content = "answer" } }} } end
            if value == "usage" then return {
                choices = {},
                usage = { prompt_tokens = 70, completion_tokens = 12, total_tokens = 82 },
            } end
            error("unexpected JSON: " .. tostring(value))
        end,
    }
    local request_headers
    local provider = ProviderRegistry:newProvider({
        provider = "deepseek",
        base_url = "https://example.test/v1/chat/completions",
        model = "test-model",
        api_key = "secret",
        max_tokens = 2400,
        temperature = 0.2,
    }, function() error("blocking transport should not run") end, function(_, headers, body, _, _, on_chunk)
        request_headers = headers
        same(body, "encoded-stream-request", "stream request body")
        on_chunk("data: one\n\nda")
        on_chunk("ta: two\n\ndata: usage\n\ndata: [DONE]\n\n")
        return true, 200, "", "OK"
    end)
    local deltas = {}
    local response, err = provider:chat({
        system = "system",
        messages = {{ role = "user", content = "question" }},
        tools = Agent.tool_schemas,
    }, function(delta) table.insert(deltas, delta) end, {})
    package.loaded.json = previous_json
    same(err, nil, "stream provider error")
    same(response.text, "Live answer", "stream provider text")
    same(table.concat(deltas), "Live answer", "stream provider deltas")
    same(encoded_body.stream, true, "stream request flag")
    same(encoded_body.stream_options.include_usage, true, "stream usage request flag")
    same(encoded_body.max_tokens, 2400, "configured output-token cap")
    same(encoded_body.temperature, 0.2, "configured temperature override")
    same(request_headers.Accept, "text/event-stream", "stream accept header")
    same(response.usage.input_tokens, 70, "stream input tokens")
    same(response.usage.output_tokens, 12, "stream output tokens")
    same(response.usage.total_tokens, 82, "stream total tokens")
end)

test("agent reports stream turns and book lookup phase", function()
    local starts, lookups, tool_starts, tool_finishes, deltas = 0, 0, 0, 0, {}
    local provider = scriptedProvider({
        { tool_calls = {{ id = "c1", name = "toc", arguments = {} }} },
        { text = "Finished." },
    })
    local original_chat = provider.chat
    provider.chat = function(self, request, on_delta)
        local response = original_chat(self, request)
        if response.text and on_delta then on_delta(response.text) end
        return response
    end
    local answer, err = Agent.run(conversation(), {
        provider = provider,
        book_tools = { execute = function() return { ok = true } end },
        on_stream_start = function() starts = starts + 1 end,
        on_delta = function(delta) table.insert(deltas, delta) end,
        on_tools = function() lookups = lookups + 1 end,
        on_tool_start = function(call)
            same(call.name, "toc", "started tool name")
            tool_starts = tool_starts + 1
        end,
        on_tool_finish = function(call, result)
            same(call.name, "toc", "finished tool name")
            truthy(result.ok, "finished tool result")
            tool_finishes = tool_finishes + 1
        end,
    })
    same(err, nil, "agent callback error")
    same(answer, "Finished.", "callback answer")
    same(starts, 2, "provider turn starts")
    same(lookups, 1, "tool phase count")
    same(tool_starts, 1, "tool start count")
    same(tool_finishes, 1, "tool finish count")
    same(table.concat(deltas), "Finished.", "callback delta")
end)

test("quick action keeps selection text and location structured", function()
    local selection = { text = "Some highlighted text", page = 42, section = "Chapter 7", locator = "xp-42" }
    local message = Agent.makeUserMessage(Agent.quick_actions.explain_terms, selection, 2)
    same(message.selection, selection, "selection table")
    local rendered = Agent.renderUserMessage(message)
    contains(rendered, "Give clear, concrete examples", "quick action instruction")
    contains(rendered, "Some highlighted text", "selection text")
    contains(rendered, "Chapter 7", "selection section")
    contains(rendered, "42", "selection page")
end)

local function memorySettingsFactory()
    local files = {}
    local function factory(path)
        local object = { data = copyTable(files[path] or {}) }
        function object:reset(value) self.data = copyTable(value) end
        function object:flush() files[path] = copyTable(self.data) end
        return object
    end
    return factory, files
end

test("statistics keep current-book and all-book token totals", function()
    local factory = memorySettingsFactory()
    local stats = Stats:new{
        path = "/virtual/insightful/statistics.lua",
        directory = "/virtual/insightful",
        settings_factory = factory,
        make_path = function() end,
    }
    local book_a = { id = "book-a", title = "Book A", authors = "Author A" }
    local book_b = { id = "book-b", title = "Book B", authors = "Author B" }
    truthy(stats:record(book_a, {
        requests = 2,
        measured_requests = 2,
        costed_requests = 2,
        input_tokens = 250,
        output_tokens = 50,
        total_tokens = 300,
        cost_usd = 0.0012,
    }), "record Book A")
    truthy(stats:record(book_b, {
        requests = 2,
        measured_requests = 1,
        input_tokens = 80,
        output_tokens = 20,
        total_tokens = 100,
    }), "record Book B")

    local current = stats:getBook(book_a)
    same(current.requests, 2, "Book A requests")
    same(current.input_tokens, 250, "Book A input tokens")
    same(current.output_tokens, 50, "Book A output tokens")
    same(current.total_tokens, 300, "Book A total tokens")

    local global = stats:getGlobal()
    same(global.requests, 4, "all-book requests")
    same(global.measured_requests, 3, "all-book measured requests")
    same(global.costed_requests, 2, "all-book costed requests")
    same(global.input_tokens, 330, "all-book input tokens")
    same(global.output_tokens, 70, "all-book output tokens")
    same(global.total_tokens, 400, "all-book total tokens")
    same(global.cost_usd, 0.0012, "all-book reported cost")
end)

local function fakeUI(id, path, title)
    return {
        document = { file = path },
        doc_props = { title = title, authors = "Author" },
        doc_settings = {
            readSetting = function(_, key)
                if key == "partial_md5_checksum" then return id end
            end,
        },
    }
end

test("multiple chats stay isolated by book and persist messages", function()
    local clock = 100
    local factory = memorySettingsFactory()
    local storage = Storage:new{
        root = "/virtual/insightful/conversations",
        settings_factory = factory,
        make_path = function() end,
        now = function() return clock end,
    }
    local book_a = storage:getBook(fakeUI("aaa", "/books/a.epub", "Book A"))
    local book_b = storage:getBook(fakeUI("bbb", "/books/b.epub", "Book B"))
    local a = storage:load(book_a)
    table.insert(a.messages, {
        role = "user",
        content = "Explain this",
        selection = { text = "passage", page = 3, locator = "xp-3" },
        timestamp = 10,
    })
    table.insert(a.messages, { role = "assistant", content = "Explanation", timestamp = 11 })
    truthy(storage:save(a), "save A")
    local first_id = a.id

    clock = 200
    local second = assert(storage:create(book_a))
    table.insert(second.messages, { role = "user", content = "Who is Socrates?", timestamp = 20 })
    truthy(storage:save(second), "save second chat")

    local chats = storage:list(book_a)
    same(#chats, 2, "two chats for Book A")
    same(chats[1].id, second.id, "latest chat first")
    same(chats[1].title, "Who is Socrates?", "chat title from first user message")
    same(#storage:list(book_b), 0, "Book B has no chats")

    local reloaded = storage:load(book_a, first_id)
    same(reloaded.book.title, "Book A", "book metadata")
    same(#reloaded.messages, 2, "message count")
    same(reloaded.messages[1].selection.text, "passage", "selection text")
    same(reloaded.messages[1].selection.locator, "xp-3", "selection locator")

    truthy(storage:setNewChatOnSend(book_a, true), "save per-book send setting")
    same(storage:getNewChatOnSend(book_a), true, "Book A send setting")
    same(storage:getNewChatOnSend(book_b), false, "Book B send setting remains off")
    truthy(storage:delete(book_a, first_id), "delete first chat")
    same(#storage:list(book_a), 1, "one chat remains")
    same(storage:load(book_a).id, second.id, "remaining chat becomes active")
end)

test("highlighted-action chat setting supports a global default and per-book overrides", function()
    local global_default = false
    local factory = memorySettingsFactory()
    local storage = Storage:new{
        root = "/virtual/insightful/conversations",
        settings_factory = factory,
        make_path = function() end,
        new_chat_on_send_default = function() return global_default end,
    }
    local book_a = storage:getBook(fakeUI("global-a", "/books/global-a.epub", "Global A"))
    local book_b = storage:getBook(fakeUI("global-b", "/books/global-b.epub", "Global B"))

    same(storage:getNewChatOnSend(book_a), false, "Book A starts with the global default")
    truthy(storage:load(book_b), "Book B persists its untouched book state")
    same(storage:getNewChatOnSend(book_b), false, "Book B starts with the global default")
    truthy(storage:setNewChatOnSend(book_a, true), "Book A saves an override")
    global_default = true
    same(storage:getNewChatOnSend(book_a), true, "Book A keeps its matching override")
    same(storage:getNewChatOnSend(book_b), true, "Book B inherits the changed global default")

    truthy(storage:setNewChatOnSend(book_b, false), "Book B saves a different override")
    same(storage:getNewChatOnSend(book_b), false, "Book B override wins over the global default")
end)

test("version 1 conversation migrates into the first chat", function()
    local factory, files = memorySettingsFactory()
    local storage = Storage:new{
        root = "/virtual/insightful/conversations",
        settings_factory = factory,
        make_path = function() end,
        now = function() return 500 end,
    }
    local book = storage:getBook(fakeUI("legacy", "/books/legacy.epub", "Legacy Book"))
    local path = storage:conversationPath(book.id)
    files[path] = {
        version = 1,
        book = { id = book.id, title = "Old title" },
        messages = {
            { role = "user", content = "Earlier question", timestamp = 30 },
            { role = "assistant", content = "Earlier answer", timestamp = 31 },
        },
    }

    local migrated = storage:load(book)
    same(migrated.id, "chat-1", "legacy chat ID")
    same(migrated.book.title, "Legacy Book", "current book metadata wins")
    same(#migrated.messages, 2, "legacy messages")
    same(#files[path].chats, 1, "legacy data wrapped in chat list")
    same(storage:list(book)[1].title, "Earlier question", "legacy chat title")
end)

test("sending a follow-up appends to the open chat", function()
    local document = {}
    local conversation = {
        id = "chat-1",
        book = { id = "book-a", title = "Book A" },
        messages = {{ role = "user", content = "Earlier question" }},
    }
    local recorded_usage
    local plugin = { configuration = { provider = "openrouter", stream = false } }
    local chat = Chat:new{
        plugin = plugin,
        agent = {
            makeUserMessage = function(question)
                return { role = "user", content = question }
            end,
            run = function()
                return "New answer", nil, {
                    requests = 1,
                    measured_requests = 1,
                    input_tokens = 40,
                    output_tokens = 8,
                    total_tokens = 48,
                }
            end,
        },
        answer_viewer_class = {},
        book_tools_class = {
            new = function()
                return { currentPosition = function() end }
            end,
        },
        provider_registry = {
            newProvider = function(_, configuration)
                same(configuration.provider, "openrouter", "current plugin provider")
                return {}
            end,
        },
        storage = { save = function() return true end },
        stats = {
            record = function(_, book, usage)
                same(book.id, "book-a", "statistics book")
                recorded_usage = usage
                return true
            end,
        },
        streaming = { httpPost = function() end },
        conversation = conversation,
        configuration = { provider = "deepseek", stream = true },
        context = { ui = { document = document }, document = document },
    }
    chat.viewer = { update = function() end }

    chat:_send("Follow-up question")
    same(chat.conversation, conversation, "existing conversation kept")
    same(#conversation.messages, 3, "question and answer added to existing chat")
    same(recorded_usage.total_tokens, 48, "chat records model token use")
end)

test("closing a chat keeps its answer running and saves the result", function()
    local document = {}
    local conversation = {
        id = "chat-1",
        book = { id = "book-a", title = "Book A" },
        messages = {},
    }
    local plugin = {}
    local saved_active = {}
    local cancel_count = 0
    local chat
    chat = Chat:new{
        plugin = plugin,
        agent = {
            makeUserMessage = function(question)
                return { role = "user", content = question }
            end,
            run = function(_, options)
                options.stream_control.cancel = function()
                    cancel_count = cancel_count + 1
                end
                same(plugin.running_chat, chat, "plugin owns running chat")
                chat:_onViewerClosed(chat.viewer)
                same(plugin.running_chat, chat, "closed chat remains owned while running")
                options.on_tool_start({ name = "search_book", arguments = { query = "history" } })
                same(chat.stream_status.state, "calling", "detached chat tracks running action")
                options.on_tool_finish({ name = "search_book", arguments = { query = "history" } })
                same(chat.stream_status.state, "finished", "detached chat tracks finished action")
                return "The full answer after book actions.", nil, {
                    requests = 2,
                    measured_requests = 2,
                    input_tokens = 80,
                    output_tokens = 20,
                    total_tokens = 100,
                }
            end,
        },
        answer_viewer_class = {},
        book_tools_class = {
            new = function()
                return { currentPosition = function() end }
            end,
        },
        provider_registry = {
            newProvider = function() return {} end,
        },
        storage = {
            save = function(_, _, make_active)
                table.insert(saved_active, make_active)
                return true
            end,
        },
        stats = { record = function() return true end },
        streaming = { httpPost = function() end },
        conversation = conversation,
        context = { ui = { document = document }, document = document },
    }
    plugin.active_chat = chat
    chat.viewer = { update = function() end }

    chat:_send("Keep working after I leave")

    same(cancel_count, 0, "closing viewer does not cancel stream")
    same(plugin.running_chat, nil, "completed chat releases background ownership")
    same(chat.busy, false, "chat is no longer busy")
    same(chat.closed, true, "chat stays detached after completion")
    same(#conversation.messages, 2, "question and complete answer saved")
    same(conversation.messages[2].content, "The full answer after book actions.", "complete answer")
    same(saved_active[1], true, "sending chat remains active")
    same(saved_active[2], false, "detached completion does not change active chat")
end)

test("non-streaming request uses the background transport", function()
    local document = {}
    local conversation = {
        id = "chat-1",
        book = { id = "book-a", title = "Book A" },
        messages = {},
    }
    local used_background_transport = false
    local chat = Chat:new{
        plugin = {},
        agent = Agent,
        answer_viewer_class = {},
        book_tools_class = {
            new = function()
                return { currentPosition = function() end }
            end,
        },
        provider_registry = {
            newProvider = function(_, _, transport, stream_transport)
                same(stream_transport, nil, "SSE transport disabled")
                return {
                    chat = function()
                        local ok, code, body = transport("https://example.test", {}, "{}", 60, true)
                        truthy(ok, "background request")
                        same(code, 200, "background status")
                        return { text = body }
                    end,
                }
            end,
        },
        storage = { save = function() return true end },
        stats = { record = function() return true end },
        streaming = {
            httpPost = function(_, _, _, _, _, on_chunk, control)
                used_background_transport = true
                same(on_chunk, nil, "complete response mode")
                truthy(control, "request can be stopped")
                return true, 200, "Complete background answer.", "OK"
            end,
        },
        conversation = conversation,
        configuration = { stream = false },
        context = { ui = { document = document }, document = document },
    }
    chat.viewer = { update = function() end }

    chat:_send("Use one complete response")

    truthy(used_background_transport, "background transport used")
    same(conversation.messages[2].content, "Complete background answer.", "complete response saved")
end)

test("a failed request offers a retry that resends the same question", function()
    local document = {}
    local conversation = {
        id = "chat-1",
        book = { id = "book-a", title = "Book A" },
        messages = {},
    }
    local attempts = 0
    local chat = Chat:new{
        plugin = {},
        agent = Agent,
        answer_viewer_class = {},
        book_tools_class = {
            new = function() return { currentPosition = function() end } end,
        },
        provider_registry = {
            newProvider = function()
                return {
                    chat = function()
                        attempts = attempts + 1
                        if attempts == 1 then
                            return nil, "Couldn't reach the AI service: timeout"
                        end
                        return { text = "Answer after the retry." }
                    end,
                }
            end,
        },
        storage = { save = function() return true end },
        stats = { record = function() return true end },
        streaming = { httpPost = function() return true, 200, "", "OK" end },
        conversation = conversation,
        configuration = { stream = false, model = "gpt-4.1-mini" },
        context = { ui = { document = document }, document = document },
    }
    chat.viewer = { update = function() end }

    chat:_send("Why did this fail?")
    same(attempts, 1, "the first attempt ran")
    truthy(chat.can_retry, "an unreachable service offers a retry")
    same(#conversation.messages, 1, "only the question is stored after a failure")

    chat:_retry()
    same(attempts, 2, "the retry ran a second attempt")
    same(#conversation.messages, 2, "the retry did not repeat the question")
    same(conversation.messages[1].role, "user", "the question is kept")
    same(conversation.messages[2].content, "Answer after the retry.", "the retry answer is saved")
    same(conversation.messages[2].model, "gpt-4.1-mini", "the answer records its model")
    truthy(not chat.can_retry, "a successful retry clears the retry offer")
end)

test("retrying a highlighted action keeps the selected passage", function()
    local document = {}
    local conversation = {
        id = "chat-1",
        book = { id = "book-a", title = "Book A" },
        messages = {},
    }
    local attempts = 0
    local last_messages
    local chat = Chat:new{
        plugin = {},
        agent = Agent,
        answer_viewer_class = {},
        book_tools_class = {
            new = function() return { currentPosition = function() end } end,
        },
        provider_registry = {
            newProvider = function()
                return {
                    chat = function(_, request)
                        attempts = attempts + 1
                        last_messages = request.messages
                        if attempts == 1 then
                            return nil, "Couldn't reach the AI service: timeout"
                        end
                        return { text = "Explained after the retry." }
                    end,
                }
            end,
        },
        storage = { save = function() return true end },
        stats = { record = function() return true end },
        streaming = { httpPost = function() return true, 200, "", "OK" end },
        conversation = conversation,
        configuration = { stream = false },
        context = { ui = { document = document }, document = document },
    }
    chat.viewer = { update = function() end }
    chat.pending_selection = { text = "The selected passage text", section = "Chapter 3" }

    chat:_send(Agent.quick_actions.explain, chat.pending_selection)
    same(attempts, 1, "the highlighted action was attempted")
    contains(last_messages[1].content, "The selected passage text", "the first attempt sent the passage")

    chat:_retry()
    same(attempts, 2, "the retry ran")
    contains(last_messages[1].content, "The selected passage text", "the retry still sends the passage")
    contains(last_messages[1].content, "Chapter 3", "the retry keeps the passage location")
    same(#conversation.messages, 2, "the retry did not repeat the question")
end)

test("a rate limited request explains itself and offers a retry", function()
    local document = {}
    local conversation = {
        id = "chat-1",
        book = { id = "book-a", title = "Book A" },
        messages = {},
    }
    local chat = Chat:new{
        plugin = {},
        agent = Agent,
        answer_viewer_class = {},
        book_tools_class = {
            new = function() return { currentPosition = function() end } end,
        },
        provider_registry = {
            newProvider = function()
                return {
                    chat = function()
                        -- The wording the device logged when this happened.
                        return nil, "AI service HTTP 429: Provider returned error"
                    end,
                }
            end,
        },
        storage = { save = function() return true end },
        stats = { record = function() return true end },
        streaming = { httpPost = function() return true, 429, "", "" end },
        conversation = conversation,
        configuration = { stream = false },
        context = { ui = { document = document }, document = document },
    }
    chat.viewer = { update = function() end }

    chat:_send("Anything")
    truthy(chat.can_retry, "a rate limit is worth retrying")
    contains(chat.stream_status, "rate limiting", "the reader is told it was rate limited")
end)

local function reopenedChat(messages)
    local document = {}
    return Chat:new{
        plugin = {},
        agent = Agent,
        answer_viewer_class = {},
        book_tools_class = { new = function() return { currentPosition = function() end } end },
        provider_registry = { newProvider = function() return { chat = function() end } end },
        storage = { save = function() return true end },
        stats = { record = function() return true end },
        streaming = { httpPost = function() return true, 200, "", "OK" end },
        conversation = {
            id = "chat-1",
            book = { id = "book-a", title = "Book A" },
            messages = messages,
        },
        configuration = { stream = false },
        context = { ui = { document = document }, document = document },
    }
end

test("a chat reopened after a failure still offers a retry", function()
    -- What storage holds after a failed request: the question, and no answer.
    local chat = reopenedChat({ Agent.makeUserMessage("Why did this fail?", nil, 1) })
    truthy(chat.can_retry, "an unanswered question can still be retried")
    contains(chat.stream_status, "not answered", "the reader is told why Retry is offered")
end)

test("a chat reopened after an answer does not offer a retry", function()
    local chat = reopenedChat({
        Agent.makeUserMessage("What is this?", nil, 1),
        { role = "assistant", content = "An answer.", timestamp = 2 },
    })
    truthy(not chat.can_retry, "an answered question is not retried")
    same(chat.stream_status, nil, "an answered chat shows no banner")
end)

test("a new empty chat does not offer a retry", function()
    local chat = reopenedChat({})
    truthy(not chat.can_retry, "an empty chat has nothing to retry")
    same(chat.stream_status, nil, "an empty chat shows no banner")
end)

test("a rejected API key does not offer a retry", function()
    local document = {}
    local conversation = {
        id = "chat-1",
        book = { id = "book-a", title = "Book A" },
        messages = {},
    }
    local attempts = 0
    local chat = Chat:new{
        plugin = {},
        agent = Agent,
        answer_viewer_class = {},
        book_tools_class = {
            new = function() return { currentPosition = function() end } end,
        },
        provider_registry = {
            newProvider = function()
                return {
                    chat = function()
                        attempts = attempts + 1
                        return nil, "HTTP 401 unauthorized"
                    end,
                }
            end,
        },
        storage = { save = function() return true end },
        stats = { record = function() return true end },
        streaming = { httpPost = function() return true, 401, "", "" end },
        conversation = conversation,
        configuration = { stream = false },
        context = { ui = { document = document }, document = document },
    }
    chat.viewer = { update = function() end }

    chat:_send("Anything")
    same(attempts, 1, "the request was attempted")
    truthy(not chat.can_retry, "a rejected key needs a configuration change, not a retry")

    chat:_retry()
    same(attempts, 1, "retrying a rejected key does nothing")
end)

test("background save does not replace another active chat", function()
    local factory = memorySettingsFactory()
    local storage = Storage:new{
        root = "/virtual/insightful/conversations",
        settings_factory = factory,
        make_path = function() end,
        now = function() return 100 end,
    }
    local book = storage:getBook(fakeUI("active", "/books/active.epub", "Active Book"))
    local first = storage:load(book)
    table.insert(first.messages, { role = "user", content = "First question" })
    truthy(storage:save(first), "save first chat")
    local second = assert(storage:create(book))

    table.insert(first.messages, { role = "assistant", content = "Background answer" })
    truthy(storage:save(first, false), "save detached answer")

    same(storage:load(book).id, second.id, "second chat remains active")
end)

test("book tools expose bounded search, read, links, toc, and position", function()
    local document = {
        info = { number_of_pages = 20, has_pages = false },
        file = "/books/a.epub",
        current_xpointer = "xp:5",
    }
    function document:findAllText(query)
        return {
            { start = "xp:4", prev_text = "before", matched_text = query, next_text = "after" },
            { start = "xp:9", prev_text = "earlier", matched_text = query, next_text = "later" },
        }
    end
    function document:getPageFromXPointer(xp) return tonumber(xp:match("(%d+)$")) end
    function document:getPageXPointer(page) return "xp:" .. tostring(page) end
    function document:getTextFromXPointers(first, last)
        return first .. " to " .. last .. " " .. string.rep("x", 9000)
    end
    function document:getXPointer() return self.current_xpointer end
    function document:gotoXPointer(xp) self.current_xpointer = xp end
    function document:getPageLinks(internal_only)
        local links = {
            { section = "xp:9", a_xpointer = "xp:4:anchor", text = "Footnote 1" },
            { uri = "https://example.test/source", a_xpointer = "xp:4:source" },
        }
        if internal_only then return { links[1] } end
        return links
    end
    function document:getTextFromXPointer(xp) return "anchor at " .. xp end
    function document:isXPointerInDocument(xp) return xp:match("^xp:") ~= nil end

    local toc = {
        toc = {
            { title = "One", page = 1, depth = 1, xpointer = "xp:1" },
            { title = "Two", page = 8, depth = 1, xpointer = "xp:8" },
        },
        fillToc = function() end,
        getTocTitleByPage = function(_, page) return page < 8 and "One" or "Two" end,
    }
    local ui = {
        document = document,
        toc = toc,
        view = { state = { page = 5 } },
        getCurrentPage = function() return 5 end,
    }
    local tools = BookTools:new{ ui = ui, document = document }
    local search = tools:execute("search_book", { query = "Mentor" })
    truthy(search.ok, "search ok")
    same(#search.hits, 2, "search hits")
    same(search.hits[1].section, "One", "search section")
    local around = tools:execute("read_around", { hit_id = search.hits[1].id })
    truthy(around.ok, "read ok")
    truthy(#around.text <= BookTools.limits.read_chars, "read is bounded")
    local links = tools:execute("list_links", { hit_id = search.hits[1].id })
    truthy(links.ok, "links ok")
    same(links.page, 4, "link source page")
    same(#links.links, 2, "internal and external links")
    same(links.links[1].kind, "internal", "internal link kind")
    same(links.links[1].target_page, 9, "internal target page")
    same(links.links[1].label, "Footnote 1", "link label")
    same(links.links[2].target_uri, "https://example.test/source", "external URI")
    same(document.current_xpointer, "xp:5", "reader position restored")
    local linked = tools:execute("read_around", {
        link_id = links.links[1].id,
        before_pages = 0,
        after_pages = 0,
    })
    truthy(linked.ok, "linked read ok")
    same(linked.page, 9, "linked read target page")
    same(linked.locator, "xp:9", "linked read target locator")
    local internal_links = tools:execute("list_links", {
        hit_id = search.hits[1].id,
        include_external = false,
    })
    same(#internal_links.links, 1, "external links filtered")
    same(internal_links.total_links, 1, "filtered link total")
    same(internal_links.truncated, false, "filtered list not truncated")
    truthy(internal_links.links[1].id ~= links.links[1].id, "link IDs do not collide")
    same(document.current_xpointer, "xp:5", "reader position restored after filtering")
    local first_link_again = tools:execute("read_around", {
        link_id = links.links[1].id,
        before_pages = 0,
        after_pages = 0,
    })
    same(first_link_again.page, 9, "earlier link ID remains usable")
    local structure = tools:execute("toc", {})
    same(#structure.entries, 2, "toc entries")
    local position = tools:execute("current_position", {})
    same(position.page, 5, "current page")
    same(position.pages, 20, "total pages")
    same(position.locator, "xp:5", "current locator")
end)

test("page-based hyperlinks normalize zero-based targets and stay bounded", function()
    local document = { info = { number_of_pages = 100, has_pages = true } }
    function document:getPageLinks(page)
        same(page, 3, "requested link page")
        local links = {
            { page = 0, text = "Front matter" },
            { uri = "https://example.test/bibliography" },
        }
        for target = 1, 45 do table.insert(links, { page = target }) end
        return links
    end
    local ui = { document = document, getCurrentPage = function() return 3 end }
    local tools = BookTools:new{ ui = ui, document = document }
    local result = tools:execute("list_links", { page = 3 })
    truthy(result.ok, "page links ok")
    same(#result.links, BookTools.limits.links, "returned link cap")
    same(result.links[1].target_page, 1, "zero-based page converted")
    same(result.links[2].kind, "external", "page external link")
    same(result.links[2].target_uri, "https://example.test/bibliography", "page external URI")
    truthy(result.truncated, "page links truncated")

    local internal_only = tools:execute("list_links", { page = 3, include_external = false })
    truthy(internal_only.ok, "internal-only links ok")
    for _, link in ipairs(internal_only.links) do
        same(link.kind, "internal", "external links filtered")
    end
end)

test("agent exposes exactly the five current book tools", function()
    local names, schemas = {}, {}
    for _, schema in ipairs(Agent.tool_schemas) do
        table.insert(names, schema.name)
        schemas[schema.name] = schema
    end
    same(table.concat(names, ","), "search_book,read_around,list_links,toc,current_position", "book tool names")
    truthy(schemas.list_links, "list_links schema")
    truthy(schemas.read_around.parameters.properties.link_id, "read_around link_id")
    contains(Agent.systemPrompt({}, {}), "footnotes", "hyperlink prompt")
end)

test("conversation renderer separates user and Markdown AI messages", function()
    local html = ConversationRenderer.render({
        {
            role = "user",
            content = Agent.quick_actions.explain_terms,
            selection = { text = "Selected <text>", section = "Chapter 2" },
        },
        { role = "assistant", content = "# Finished answer" },
    }, "**Live answer**", nil, function(text) return "<md>" .. text .. "</md>" end)
    contains(html, 'class="user-message"', "gray user message block")
    contains(html, "YOU", "user label")
    contains(html, Agent.quick_actions.explain_terms, "displayed prompt")
    contains(html, "Selected &lt;text&gt;", "selection is escaped")
    contains(html, "Chapter 2", "selection location")
    contains(html, '<md># Finished answer</md>', "saved AI Markdown")
    contains(html, '<md>**Live answer**</md>', "streaming AI Markdown")
    contains(html, 'class="message-separator"', "message separator")
end)

test("conversation renderer shows the exact quick-action prompt", function()
    local html = ConversationRenderer.render({
        {
            role = "user",
            content = Agent.quick_actions.explain_terms,
            display_content = "Give examples for this passage",
        },
    })
    contains(html, Agent.quick_actions.explain_terms, "quick-action prompt")
    truthy(not html:find("Give examples for this passage", 1, true), "short label is ignored")
end)

test("conversation renderer names the model beside the AI label", function()
    local markdown = function(text) return "<md>" .. text .. "</md>" end
    local html = ConversationRenderer.render({
        { role = "assistant", content = "Saved answer", model = "gpt-4.1-mini" },
    }, nil, nil, markdown)
    contains(html, "AI — gpt-4.1-mini", "saved answer names its own model")

    html = ConversationRenderer.render({}, "Live answer", nil, markdown, "deepseek-chat")
    contains(html, "AI — deepseek-chat", "streaming answer names the active model")

    html = ConversationRenderer.render({}, "", "Waiting for model response…", markdown, "claude-sonnet-4")
    contains(html, "AI — claude-sonnet-4", "status line names the active model")

    html = ConversationRenderer.render({}, "Live answer", nil, markdown, "<b>x</b>")
    contains(html, "AI — &lt;b&gt;x&lt;/b&gt;", "model name is escaped")

    html = ConversationRenderer.render({
        { role = "assistant", content = "Answer from an older chat" },
    }, nil, nil, markdown)
    contains(html, '"role-label">AI<', "an answer saved without a model still says AI")
end)

test("conversation renderer accepts KOReader's callable Markdown table", function()
    local module_name = "apps/filemanager/lib/md"
    local previous_markdown = package.loaded[module_name]
    package.loaded[module_name] = setmetatable({}, {
        __call = function(_, text) return "<h1>" .. text .. "</h1>" end,
    })
    local html = ConversationRenderer.render({
        { role = "assistant", content = "Rendered" },
    })
    package.loaded[module_name] = previous_markdown
    contains(html, "<h1>Rendered</h1>", "callable Markdown output")
end)

test("conversation renderer shows factual harness actions", function()
    local html = ConversationRenderer.render({}, "", {
        kind = "tool",
        state = "calling",
        name = "search_book",
        detail = "Query: Mentor",
    })
    contains(html, "AGENT ACTION", "tool activity label")
    contains(html, "Calling", "tool activity state")
    contains(html, "search_book", "tool function name")
    contains(html, "Query: Mentor", "safe tool arguments")
end)

test("chat list opens when a saved chat has no title", function()
    local ChatList, ui_manager = loadChatList()
    local opened_chat_id
    local menu = ChatList.show{
        storage = {
            list = function()
                return {{ id = "chat-1", updated_at = 1, active = true }}
            end,
        },
        book = { title = "The Book" },
        on_open = function(chat_id) opened_chat_id = chat_id end,
    }

    truthy(menu, "chat list menu")
    same(menu.item_table[2].text, "New chat", "untitled chat fallback")
    same(ui_manager.shown[1], menu, "chat list shown")
    menu.item_table[2].callback()
    same(opened_chat_id, "chat-1", "saved chat opens")
end)

test("batched search never returns more than the global hit cap", function()
    local document = { info = { number_of_pages = 30, has_pages = false } }
    function document:findAllText(query)
        local results = {}
        for index = 1, 20 do
            table.insert(results, { start = query .. ":" .. index, matched_text = query })
        end
        return results
    end
    function document:getPageFromXPointer(xp) return tonumber(xp:match("(%d+)$")) end
    function document:getPageXPointer(page) return "xp:" .. tostring(page) end
    local ui = { document = document }
    local tools = BookTools:new{ ui = ui, document = document }
    local result = tools:execute("search_book", { queries = { "Athena", "Mentor" } })
    truthy(result.ok, "batched search ok")
    same(#result.hits, BookTools.limits.returned_hits, "global returned hit cap")
end)

io.write(string.format("%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
