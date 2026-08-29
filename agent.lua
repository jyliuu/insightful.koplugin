local Agent = {}

local source = debug.getinfo(1, "S").source
local PLUGIN_DIR = source:match("^@(.*/)") or ""
local PromptLoader = dofile(PLUGIN_DIR .. "prompt_loader.lua")
local prompts, prompt_err = PromptLoader.load(PLUGIN_DIR .. "prompts", {
    system = "system.md",
    highlighted_question = "highlighted_question.md",
    explain = "explain.md",
    explain_terms = "give_examples.md",
    context_history = "context_history.md",
    people_characters = "people_characters.md",
})
if not prompts then error("Insightful prompts could not be loaded: " .. tostring(prompt_err)) end

Agent.quick_actions = {
    explain = assert(prompts:get("explain")),
    explain_terms = assert(prompts:get("explain_terms")),
    context_history = assert(prompts:get("context_history")),
    people_characters = assert(prompts:get("people_characters")),
}

Agent.tool_schemas = {
    {
        name = "search_book",
        description = "Search the full text of the currently open book for names, phrases, terms, or textual details. Returns compact matching snippets and hit identifiers. Use read_around when more context is needed.",
        parameters = {
            type = "object",
            properties = {
                query = { type = "string", description = "One phrase or term to search for." },
                queries = {
                    type = "array",
                    items = { type = "string" },
                    description = "Optional batch of phrases or terms to search for in one call.",
                },
            },
        },
    },
    {
        name = "read_around",
        description = "Read a bounded amount of surrounding text near a search hit, internal link, or page/location in the currently open book. Use this to inspect evidence instead of relying only on a search snippet or link target.",
        parameters = {
            type = "object",
            properties = {
                hit_id = { type = "string", description = "A hit identifier returned by search_book in this tool run." },
                link_id = { type = "string", description = "An internal link identifier returned by list_links in this tool run." },
                page = { type = "integer", description = "A document page or virtual page." },
                locator = { type = "string", description = "A KOReader XPointer locator when available." },
                before_pages = { type = "integer", minimum = 0, maximum = 2 },
                after_pages = { type = "integer", minimum = 0, maximum = 2 },
            },
        },
    },
    {
        name = "list_links",
        description = "List bounded hyperlinks on the current page or on a page/location found with another book tool. Returns internal link IDs that read_around can follow, plus external URLs for reference. This does not open a URL or leave the reader at another location.",
        parameters = {
            type = "object",
            properties = {
                hit_id = { type = "string", description = "A hit identifier returned by search_book in this tool run." },
                page = { type = "integer", description = "A document page or virtual page. Defaults to the current page." },
                locator = { type = "string", description = "A KOReader XPointer locator when available." },
                include_external = { type = "boolean", description = "Include external URLs. Defaults to true." },
            },
        },
    },
    {
        name = "toc",
        description = "Inspect the currently open book's table of contents and document structure.",
        parameters = { type = "object", properties = {} },
    },
    {
        name = "current_position",
        description = "Return the user's current reading location in the open book.",
        parameters = { type = "object", properties = {} },
    },
}

local function trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function renderPrompt(name, values)
    local rendered, render_err = prompts:render(name, values)
    if not rendered then error("Insightful prompt could not be rendered: " .. tostring(render_err)) end
    return rendered
end

local function selectionLocation(selection)
    local lines = {}
    if selection.section and selection.section ~= "" then
        table.insert(lines, "Section: " .. tostring(selection.section))
    end
    if selection.page then
        table.insert(lines, "Page/location: " .. tostring(selection.page))
    elseif selection.locator then
        table.insert(lines, "Location: " .. tostring(selection.locator))
    end
    if #lines == 0 then return "" end
    return table.concat(lines, "\n") .. "\n"
end

function Agent.makeUserMessage(content, selection, timestamp)
    return {
        role = "user",
        content = trim(content),
        selection = selection,
        timestamp = timestamp or os.time(),
    }
end

function Agent.renderUserMessage(message)
    local content = trim(message and message.content)
    local selection = message and message.selection
    if type(selection) ~= "table" or trim(selection.text) == "" then return content end
    return renderPrompt("highlighted_question", {
        selection_location = selectionLocation(selection),
        passage = selection.text,
        question = content,
    })
end

function Agent.systemPrompt(book, position)
    book = type(book) == "table" and book or {}
    position = type(position) == "table" and position or {}
    local where = position.section or position.page or position.locator or "unknown"
    return renderPrompt("system", {
        title = book.title or "Unknown",
        author = book.authors or "Unknown",
        position = where,
    })
end

function Agent.buildMessages(conversation)
    local messages = {}
    for _, message in ipairs(conversation.messages or {}) do
        if message.role == "user" then
            table.insert(messages, { role = "user", content = Agent.renderUserMessage(message) })
        elseif message.role == "assistant" and type(message.content) == "string" then
            table.insert(messages, { role = "assistant", content = message.content })
        end
    end
    return messages
end

local function safeToolResult(book_tools, call)
    local ok, result = pcall(book_tools.execute, book_tools, call.name, call.arguments or {})
    if not ok then
        return { ok = false, error = "Book tool failed: " .. tostring(result) }
    end
    if type(result) ~= "table" then
        return { ok = false, error = "Book tool returned an invalid result." }
    end
    return result
end

local function emptyUsage()
    return {
        requests = 0,
        measured_requests = 0,
        costed_requests = 0,
        input_tokens = 0,
        output_tokens = 0,
        total_tokens = 0,
        cost_usd = 0,
    }
end

local function addResponseUsage(total, usage)
    total.requests = total.requests + 1
    if type(usage) ~= "table" then return end
    if tonumber(usage.input_tokens) or tonumber(usage.output_tokens) or tonumber(usage.total_tokens) then
        total.measured_requests = total.measured_requests + 1
    end
    for _, key in ipairs({ "input_tokens", "output_tokens", "total_tokens" }) do
        local value = tonumber(usage[key])
        if value and value > 0 then total[key] = total[key] + math.floor(value) end
    end
    local cost_usd = tonumber(usage.cost_usd)
    if cost_usd then
        total.costed_requests = total.costed_requests + 1
        total.cost_usd = total.cost_usd + math.max(0, cost_usd)
    end
end

function Agent.run(conversation, options)
    options = options or {}
    local provider = assert(options.provider, "provider is required")
    local book_tools = assert(options.book_tools, "book_tools is required")
    local messages = Agent.buildMessages(conversation)
    local tool_turns = 0
    local usage = emptyUsage()

    while true do
        if type(options.on_stream_start) == "function" then
            pcall(options.on_stream_start)
        end
        local ok, response, provider_err, provider_usage = pcall(provider.chat, provider, {
            system = Agent.systemPrompt(conversation.book, options.position),
            messages = messages,
            tools = Agent.tool_schemas,
        }, options.on_delta, options.stream_control, options.on_stream_activity, options.on_tool_delta)
        if not ok then
            return nil, "Couldn't reach the AI service: " .. tostring(response), usage
        end
        if not response then
            if type(provider_usage) == "table" then addResponseUsage(usage, provider_usage) end
            return nil, provider_err or "The AI service returned no response.", usage
        end
        addResponseUsage(usage, response.usage)
        local calls = type(response.tool_calls) == "table" and response.tool_calls or {}
        if #calls == 0 then
            if type(response.text) == "string" and trim(response.text) ~= "" then
                return response.text, nil, usage
            end
            return nil, "The AI service returned neither text nor tool calls.", usage
        end

        if type(options.on_tools) == "function" then
            pcall(options.on_tools, calls)
        end
        tool_turns = tool_turns + 1

        local assistant_turn = {
            role = "assistant",
            content = response.text or "",
            provider_state = response.provider_state,
            tool_calls = {},
        }
        for index, call in ipairs(calls) do
            local call_id = call.id or string.format("insightful-%d-%d", tool_turns, index)
            table.insert(assistant_turn.tool_calls, {
                id = call_id,
                name = call.name,
                arguments = type(call.arguments) == "table" and call.arguments or {},
            })
        end
        table.insert(messages, assistant_turn)

        -- Execute every call from this model turn before making another request.
        for _, call in ipairs(assistant_turn.tool_calls) do
            if type(options.on_tool_start) == "function" then
                pcall(options.on_tool_start, call)
            end
            local result = safeToolResult(book_tools, call)
            if type(options.on_tool_finish) == "function" then
                pcall(options.on_tool_finish, call, result)
            end
            table.insert(messages, {
                role = "tool",
                tool_call_id = call.id,
                name = call.name,
                content = result,
            })
        end
    end
end

return Agent
