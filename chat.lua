local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Chat = {}
Chat.__index = Chat

local QUICK_LABELS = {
    explain = "Explain this passage",
    explain_terms = "Explain the terms in this passage",
    context_history = "Give context and history for this passage",
    people_characters = "Explain the people or characters in this passage",
}

local function toolDetail(call)
    local arguments = type(call) == "table" and call.arguments
    arguments = type(arguments) == "table" and arguments or {}
    if call.name == "search_book" then
        if type(arguments.query) == "string" then return "Query: " .. arguments.query end
        if type(arguments.queries) == "table" then return "Queries: " .. table.concat(arguments.queries, ", ") end
    elseif call.name == "read_around" then
        if arguments.hit_id then return "Search result: " .. tostring(arguments.hit_id) end
        if arguments.link_id then return "Link: " .. tostring(arguments.link_id) end
        if arguments.page then return "Page: " .. tostring(arguments.page) end
        if arguments.locator then return "Location: " .. tostring(arguments.locator) end
    elseif call.name == "list_links" then
        if arguments.hit_id then return "Links near search result: " .. tostring(arguments.hit_id) end
        if arguments.page then return "Links on page: " .. tostring(arguments.page) end
        if arguments.locator then return "Links at location: " .. tostring(arguments.locator) end
        return "Links on the current page"
    elseif call.name == "toc" then
        return "Reading the table of contents"
    elseif call.name == "current_position" then
        return "Checking the current reading position"
    end
end

local function toolStatus(call, state)
    return {
        kind = "tool",
        state = state or "calling",
        name = tostring(call and call.name or "book tool"),
        detail = toolDetail(call or {}),
    }
end

local function trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function Chat:new(options)
    local instance = setmetatable({}, self)
    instance.plugin = assert(options.plugin)
    instance.agent = assert(options.agent)
    instance.book_tools_class = assert(options.book_tools_class)
    instance.provider_registry = assert(options.provider_registry)
    instance.storage = assert(options.storage)
    instance.stats = assert(options.stats)
    instance.viewer_class = assert(options.answer_viewer_class)
    instance.streaming = assert(options.streaming)
    instance.conversation = assert(options.conversation)
    instance.context = assert(options.context)
    instance.configuration = options.configuration or {}
    instance.pending_selection = options.selection
    instance.busy = false
    instance.closed = false
    instance.viewer = nil
    instance.stream_control = nil
    instance.stream_text = ""
    instance.stream_status = nil
    instance.stream_pending = {}
    instance.stream_flush_task = nil
    return instance
end

function Chat:_save(make_active)
    local ok, err = self.storage:save(self.conversation, make_active)
    if not ok then logger.warn("Insightful: conversation save failed:", err) end
    return ok, err
end

function Chat:isConversation(conversation)
    return type(conversation) == "table"
        and type(conversation.book) == "table"
        and conversation.id == self.conversation.id
        and conversation.book.id == self.conversation.book.id
end

function Chat:_finishRun()
    self.busy = false
    if self.plugin and self.plugin.running_chat == self then
        self.plugin.running_chat = nil
    end
end

function Chat:_transport()
    return function(url, headers, body, timeout, verify_ssl)
        if type(self.streaming.httpPost) == "function" then
            return self.streaming.httpPost(
                url, headers, body, timeout, verify_ssl, nil, self.stream_control
            )
        end
        local completed, ok, code, response_body, status = Trapper:dismissableRunInSubprocess(function()
            local request_ok, request_code, request_body, request_status =
                self.agent.httpPost(url, headers, body, timeout, verify_ssl)
            return request_ok, request_code, request_body, request_status
        end, _("Waiting for model response… (tap to cancel)"))
        if not completed then return false, nil, "", _("Request canceled.") end
        return ok, code, response_body, status
    end
end

function Chat:_errorText(err)
    err = tostring(err or "")
    if err:find("API key is missing", 1, true) then
        return _("Insightful is not configured. Copy configuration.lua.sample to configuration.lua and set api_key.")
    elseif err:find("HTTP 401", 1, true) or err:find("HTTP 403", 1, true) then
        return _("The AI service rejected the API key.")
    elseif err:find("invalid JSON", 1, true) or err:find("invalid response", 1, true) then
        return _("The AI service returned an invalid response.")
    elseif err:find("AI service returned", 1, true) then
        return _("The AI service returned an invalid response.")
    elseif err:find("output limit", 1, true) then
        return _("The AI service reached its output limit before finishing.")
    elseif err:find("context window", 1, true) then
        return _("The conversation is too long for the AI service.")
    elseif err:find("content was filtered", 1, true) or err:find("request was refused", 1, true) then
        return _("The AI service did not complete this response.")
    elseif err:find("Unsupported AI provider", 1, true) then
        return err
    elseif err:find("canceled", 1, true) then
        return _("Request canceled.")
    end
    return _("Couldn't reach the AI service.")
end

function Chat:_updateViewer()
    if self.closed or not self.viewer then return end
    self.viewer:update(
        self.conversation.messages,
        self.stream_text,
        self.stream_status,
        self.busy
    )
end

function Chat:_showConversation()
    if self.closed then return end
    if self.viewer then
        self:_updateViewer()
        return
    end
    local viewer
    viewer = self.viewer_class:new{
        title = _("Insightful — ") .. tostring(self.conversation.book.title or _("Book")),
        messages = self.conversation.messages,
        stream_text = self.stream_text,
        status = self.stream_status,
        busy = self.busy,
        on_send = function(question)
            self:send(question, self.pending_selection)
        end,
        on_stop = function() if self.busy then self:_cancelStream() end end,
        on_chats = function()
            local plugin = self.plugin
            self:close()
            UIManager:nextTick(function()
                if plugin then plugin:showChatList() end
            end)
        end,
        close_callback = function() self:_onViewerClosed(viewer) end,
    }
    self.viewer = viewer
    UIManager:show(viewer)
end

function Chat:reopen(selection, quick_action)
    self.closed = false
    if not self.busy then self.pending_selection = selection end
    if #self.stream_pending > 0 then self:_flushStream() end
    return self:show(nil, self.busy and nil or quick_action)
end

function Chat:_flushStream()
    self.stream_flush_task = nil
    if #self.stream_pending == 0 then return end
    self.stream_text = self.stream_text .. table.concat(self.stream_pending)
    self.stream_pending = {}
    self.stream_status = nil
    self:_updateViewer()
end

function Chat:_setStreamStatus(text)
    if self.stream_flush_task then
        UIManager:unschedule(self.stream_flush_task)
        self.stream_flush_task = nil
    end
    self.stream_pending = {}
    self.stream_text = ""
    self.stream_status = text
    self:_updateViewer()
end

function Chat:_streamDelta(delta)
    if type(delta) ~= "string" or delta == "" then return end
    table.insert(self.stream_pending, delta)
    if not self.stream_flush_task then
        self.stream_flush_task = function() self:_flushStream() end
        UIManager:scheduleIn(0.4, self.stream_flush_task)
    end
end

function Chat:_streamStart()
    if type(self.stream_status) == "table" and self.stream_status.kind == "tool" then
        self.stream_text = ""
        self.stream_status = {
            kind = "tool",
            state = "finished_waiting",
            name = self.stream_status.name,
            detail = self.stream_status.detail,
        }
        self:_updateViewer()
    else
        self:_setStreamStatus(_("Waiting for model response…"))
    end
end

function Chat:_streamToolDelta(call)
    if type(call) ~= "table" or trim(call.name) == "" then return end
    if type(self.stream_status) == "table"
        and self.stream_status.kind == "tool"
        and self.stream_status.name == call.name
        and self.stream_status.state == "calling" then
        return
    end
    self:_setStreamStatus(toolStatus(call, "calling"))
end

function Chat:_toolStart(call)
    self:_setStreamStatus(toolStatus(call, "calling"))
    if not self.closed then UIManager:forceRePaint() end
end

function Chat:_toolFinish(call)
    self.stream_text = ""
    self.stream_status = toolStatus(call, "finished")
    self:_updateViewer()
end

function Chat:_cancelStream()
    if not self.stream_control then return end
    self.stream_control.cancelled = true
    if type(self.stream_control.cancel) == "function" then self.stream_control.cancel() end
end

function Chat:_send(question, selection, display_content)
    question = trim(question)
    if question == "" or self.busy or self.closed then return end
    local running_chat = self.plugin and self.plugin.running_chat
    if running_chat and running_chat ~= self and running_chat.busy then
        self.stream_text = ""
        self.stream_status = _("Another chat is still working on a response. Reopen it or wait for it to finish.")
        self:_showConversation()
        self:_updateViewer()
        return
    end
    if not self.context.ui or self.context.ui.document ~= self.context.document then
        self.stream_text = ""
        self.stream_status = _("The open document changed. Reopen Insightful from the current book.")
        self:_showConversation()
        self:_updateViewer()
        return
    end
    self.busy = true
    if self.plugin then self.plugin.running_chat = self end
    self.pending_selection = nil
    local user_message = self.agent.makeUserMessage(question, selection)
    user_message.display_content = display_content
    table.insert(self.conversation.messages, user_message)
    self:_save(true)
    self.stream_text = ""
    self.stream_status = _("Waiting for model response…")
    self:_showConversation()
    self:_updateViewer()
    UIManager:forceRePaint()

    local book_tools = self.book_tools_class:new(self.context)
    local position = book_tools:currentPosition()
    local background_transport = type(self.streaming.httpPost) == "function"
    local stream_enabled = self.configuration.stream ~= false and background_transport
    self.stream_control = background_transport and {} or nil
    local provider, provider_err = self.provider_registry:newProvider(
        self.configuration,
        self:_transport(),
        stream_enabled and self.streaming.httpPost or nil
    )
    if not provider then
        self.stream_control = nil
        self.stream_status = tostring(provider_err or _("Unsupported AI provider."))
        self:_finishRun()
        self:_updateViewer()
        return
    end
    local answer, err, provenance, usage = self.agent.run(self.conversation, {
        provider = provider,
        book_tools = book_tools,
        position = position,
        stream_control = self.stream_control,
        on_stream_start = stream_enabled and function()
            self:_streamStart()
        end or nil,
        on_tool_delta = stream_enabled and function(call) self:_streamToolDelta(call) end or nil,
        on_delta = stream_enabled and function(delta)
            self:_streamDelta(delta)
        end or nil,
        on_tools = function(calls)
            if type(calls) == "table" and calls[1] then
                self:_setStreamStatus(toolStatus(calls[1], "calling"))
            end
        end,
        on_tool_start = function(call) self:_toolStart(call) end,
        on_tool_finish = function(call) self:_toolFinish(call) end,
    })
    local stats_saved, stats_err = self.stats:record(self.conversation.book, usage)
    if not stats_saved then logger.warn("Insightful: statistics save failed:", stats_err) end
    if self.stream_flush_task then
        UIManager:unschedule(self.stream_flush_task)
        self:_flushStream()
    end
    self.stream_control = nil

    if answer then
        table.insert(self.conversation.messages, {
            role = "assistant",
            content = answer,
            timestamp = os.time(),
            provenance = provenance and provenance.trace or nil,
        })
        local saved, save_err = self:_save(not self.closed)
        self.stream_text = ""
        if saved then
            self.stream_status = nil
        else
            self.stream_status = _("Answer received, but saving failed: ") .. tostring(save_err or _("unknown error"))
        end
    else
        logger.warn("Insightful: request failed:", err)
        self.stream_text = ""
        self.stream_status = self:_errorText(err)
    end
    self:_finishRun()
    self:_updateViewer()
end

function Chat:send(question, selection, display_content)
    if Trapper:isWrapped() then return self:_send(question, selection, display_content) end
    return Trapper:wrap(function() self:_send(question, selection, display_content) end)
end

function Chat:sendQuickAction(action_key)
    local prompt = self.agent.quick_actions[action_key]
    if not prompt then return end
    self:send(prompt, self.pending_selection, QUICK_LABELS[action_key])
end

function Chat:show(_, quick_action)
    if quick_action then
        self:_showConversation()
        UIManager:nextTick(function()
            if not self.closed then self:sendQuickAction(quick_action) end
        end)
    else
        self:_showConversation()
    end
    return self
end

function Chat:_onViewerClosed(viewer)
    if self.viewer ~= viewer then return end
    self.viewer = nil
    self.closed = true
    -- Closing the screen only detaches it. The running coroutine keeps this
    -- controller alive until it saves the complete answer.
    if self.plugin and self.plugin.active_chat == self then self.plugin.active_chat = nil end
end

function Chat:close()
    if self.closed then return end
    self.closed = true
    if self.stream_flush_task then
        UIManager:unschedule(self.stream_flush_task)
        self.stream_flush_task = nil
    end
    if self.viewer then
        local viewer = self.viewer
        self.viewer = nil
        viewer.closed = true
        viewer.close_callback = nil
        UIManager:close(viewer)
    end
    if self.plugin and self.plugin.active_chat == self then self.plugin.active_chat = nil end
end

function Chat:shutdown()
    self:close()
    self:_cancelStream()
end

return Chat
