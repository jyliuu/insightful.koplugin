local script = arg[0]:gsub("\\", "/")
local root = script:match("^(.*)/tests/run%.lua$") or "."

local Agent = dofile(root .. "/agent.lua")
local BookTools = dofile(root .. "/book_tools.lua")
local ConversationRenderer = dofile(root .. "/conversation_renderer.lua")
local Storage = dofile(root .. "/storage.lua")
local Streaming = dofile(root .. "/streaming.lua")

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

test("agent executes search then read and returns final text", function()
    local provider = scriptedProvider({
        { tool_calls = {{ id = "c1", name = "search_book", arguments = { query = "Mentor" } }} },
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
    local answer, err, provenance = Agent.run(conversation(), { provider = provider, book_tools = tools })
    same(err, nil, "agent error")
    same(answer, "Mentor appears in the opening section.", "final answer")
    same(#calls, 2, "tool count")
    same(calls[1].name, "search_book", "first tool")
    same(calls[2].name, "read_around", "second tool")
    same(provenance.tool_turns, 2, "tool turns")
    same(#provider.requests[3].messages, 5, "working message count")
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

test("tool turn budget stops a repeated lookup loop", function()
    local provider = {
        count = 0,
        chat = function(self)
            self.count = self.count + 1
            return { tool_calls = {{ id = tostring(self.count), name = "toc", arguments = {} }} }
        end,
    }
    local count = 0
    local tools = { execute = function() count = count + 1; return { ok = true } end }
    local answer, err = Agent.run(conversation(), {
        provider = provider,
        book_tools = tools,
        max_tool_turns = 2,
    })
    same(answer, nil, "answer should be absent")
    contains(err, "limit", "budget error")
    same(count, 2, "executed calls before limit")
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

test("OpenAI-compatible provider returns neutral native tool calls", function()
    local previous_json = package.loaded.json
    package.loaded.json = {
        encode = function() return "encoded-request" end,
        decode = function(text)
            if text == "provider-response" then
                return {
                    choices = {{
                        message = {
                            content = nil,
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
    local provider = Agent.newProvider({
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
    same(captured.url, "https://example.test/v1/chat/completions", "request URL")
    same(captured.body, "encoded-request", "encoded body")
    contains(captured.headers.Authorization, "Bearer", "authorization header")
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
        first = { choices = {{ delta = { reasoning_content = "private", content = "Hello" } }} },
        second = { choices = {{ delta = { content = " world" } }} },
    }
    local deltas = {}
    local activity = {}
    local accumulator = Agent.newStreamAccumulator(
        { decode = function(value) return assert(decoded[value]) end },
        function(delta) table.insert(deltas, delta) end,
        function(kind) table.insert(activity, kind) end
    )
    truthy(accumulator:feed("data: fir"), "first partial SSE chunk")
    truthy(accumulator:feed("st\r\n\r\ndata: second\n\ndata: [DONE]\n\n"), "second SSE chunk")
    local response, err = accumulator:finish()
    same(err, nil, "stream accumulator error")
    same(response.text, "Hello world", "joined streamed text")
    same(table.concat(deltas), "Hello world", "live deltas")
    same(activity[1], "reasoning", "hidden reasoning activity")
    truthy(not response.text:find("private", 1, true), "reasoning is not returned")
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
    local accumulator = Agent.newStreamAccumulator(json, nil, nil, function(call)
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
            error("unexpected JSON: " .. tostring(value))
        end,
    }
    local request_headers
    local provider = Agent.newProvider({
        base_url = "https://example.test/v1/chat/completions",
        model = "test-model",
        api_key = "secret",
    }, function() error("blocking transport should not run") end, function(_, headers, body, _, _, on_chunk)
        request_headers = headers
        same(body, "encoded-stream-request", "stream request body")
        on_chunk("data: one\n\nda")
        on_chunk("ta: two\n\ndata: [DONE]\n\n")
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
    same(request_headers.Accept, "text/event-stream", "stream accept header")
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
    contains(rendered, "Explain the important terms", "quick action instruction")
    contains(rendered, "Some highlighted text", "selection text")
    contains(rendered, "Chapter 7", "selection section")
    contains(rendered, "42", "selection page")
end)

local function memorySettingsFactory()
    local files = {}
    local function factory(path)
        local object = { data = Storage.copyTable(files[path] or {}) }
        function object:reset(value) self.data = Storage.copyTable(value) end
        function object:flush() files[path] = Storage.copyTable(self.data) end
        return object
    end
    return factory, files
end

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

test("conversations are isolated by book and persist all fields", function()
    local factory = memorySettingsFactory()
    local storage = Storage:new{
        root = "/virtual/bookagent/conversations",
        settings_factory = factory,
        make_path = function() end,
    }
    local book_a = storage:getBook(fakeUI("aaa", "/books/a.epub", "Book A"))
    local book_b = storage:getBook(fakeUI("bbb", "/books/b.epub", "Book B"))
    local a = storage:load(book_a)
    a.summary = "Earlier discussion"
    table.insert(a.messages, {
        role = "user",
        content = "Explain this",
        selection = { text = "passage", page = 3, locator = "xp-3" },
        timestamp = 10,
    })
    table.insert(a.messages, { role = "assistant", content = "Explanation", timestamp = 11 })
    truthy(storage:save(a), "save A")

    local b = storage:load(book_b)
    same(#b.messages, 0, "Book B starts empty")

    local reloaded = storage:load(book_a)
    same(reloaded.book.title, "Book A", "book metadata")
    same(reloaded.summary, "Earlier discussion", "summary")
    same(#reloaded.messages, 2, "message count")
    same(reloaded.messages[1].selection.text, "passage", "selection text")
    same(reloaded.messages[1].selection.locator, "xp-3", "selection locator")
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

test("agent exposes the hyperlink tool and link handoff", function()
    local schemas = {}
    for _, schema in ipairs(Agent.tool_schemas) do schemas[schema.name] = schema end
    truthy(schemas.list_links, "list_links schema")
    truthy(schemas.read_around.parameters.properties.link_id, "read_around link_id")
    contains(Agent.systemPrompt({}, {}), "footnotes", "hyperlink prompt")
end)

test("highlight action uses the Zen UI AI slot", function()
    local file = assert(io.open(root .. "/main.lua", "r"))
    local source = file:read("*a")
    file:close()
    contains(source, 'addToHighlightDialog("ai_assistant"', "Zen UI highlight key")
end)

test("conversation renderer separates user and Markdown AI messages", function()
    local html = ConversationRenderer.render({
        {
            role = "user",
            content = "internal quick-action prompt",
            display_content = "Explain this passage",
            selection = { text = "Selected <text>", section = "Chapter 2" },
        },
        { role = "assistant", content = "# Finished answer" },
    }, "**Live answer**", nil, function(text) return "<md>" .. text .. "</md>" end)
    contains(html, 'class="user-message"', "gray user message block")
    contains(html, "YOU", "user label")
    contains(html, "Explain this passage", "displayed quick action")
    truthy(not html:find("internal quick-action prompt", 1, true), "internal prompt is hidden")
    contains(html, "Selected &lt;text&gt;", "selection is escaped")
    contains(html, "Chapter 2", "selection location")
    contains(html, '<md># Finished answer</md>', "saved AI Markdown")
    contains(html, '<md>**Live answer**</md>', "streaming AI Markdown")
    contains(html, 'class="message-separator"', "message separator")
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
    truthy(not html:find("Thinking", 1, true), "no generic thinking label")
end)

test("conversation screen uses the Markdown HTML viewer and embedded composer", function()
    local viewer_file = assert(io.open(root .. "/answer_viewer.lua", "r"))
    local viewer_source = viewer_file:read("*a")
    viewer_file:close()
    contains(viewer_source, "ScrollHtmlWidget:new", "HTML viewer")
    contains(viewer_source, "InputText:new", "embedded chat input")
    contains(viewer_source, "HalfPageScrollHtmlWidget:new", "overlapping half-page chat navigation")
    contains(viewer_source, 'id = "send"', "Send button")
    contains(viewer_source, "Message BookAgent", "chat input hint")
    contains(viewer_source, "self:_hideKeyboard()", "conversation tap dismisses keyboard")
    contains(viewer_source, "isKeyboardVisible", "keyboard dismissal checks visibility")
    contains(viewer_source, "is_always_active = true", "chat receives events below modal keyboard")
    contains(viewer_source, "ges.pos:notIntersectWith(keyboard.dimen)", "outside-keyboard tap guard")
    truthy(not viewer_source:find("focus_input", 1, true), "conversation does not auto-open keyboard")
    contains(viewer_source, 'id = "stop"', "Stop button")
    local pager_file = assert(io.open(root .. "/half_page_scroll_html_widget.lua", "r"))
    local pager_source = pager_file:read("*a")
    pager_file:close()
    contains(pager_source, "self.half_height", "half-height HTML layout")
    contains(pager_source, "page_number + 1", "consecutive page pairing")
    contains(pager_source, "self.max_start_page", "bounded half-page position")
    local renderer_file = assert(io.open(root .. "/conversation_renderer.lua", "r"))
    local renderer_source = renderer_file:read("*a")
    renderer_file:close()
    contains(renderer_source, '"apps/filemanager/lib/md"', "Markdown renderer")
    contains(renderer_source, 'class="user-message"', "user message box")
    local chat_file = assert(io.open(root .. "/chat.lua", "r"))
    local chat_source = chat_file:read("*a")
    chat_file:close()
    contains(chat_source, "on_send", "embedded composer callback")
    contains(chat_source, "self:_showConversation()", "Ask AI opens full conversation")
    truthy(not chat_source:find("InputDialog", 1, true), "separate Ask dialog removed")
    truthy(not chat_source:find("showAskDialog", 1, true), "Ask popup path removed")
    contains(chat_source, "on_tool_delta", "live streamed function call")
    contains(chat_source, "on_tool_start", "tool execution start")
    contains(chat_source, "Waiting for model response", "direct response waiting state")
    truthy(not chat_source:find('_("Thinking")', 1, true), "generic thinking animation removed")
    truthy(not chat_source:find("saved and nil or", 1, true), "save success cannot select failure text")
    local main_file = assert(io.open(root .. "/main.lua", "r"))
    local main_source = main_file:read("*a")
    main_file:close()
    contains(main_source, 'localRequire("streaming")', "stream transport loaded")
    contains(main_source, 'localRequire("answer_viewer")', "answer viewer loaded")
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
