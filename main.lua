local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local source = debug.getinfo(1, "S").source
local PLUGIN_DIR = source:match("^@(.*/)") or ""
local NEW_CHAT_ON_HIGHLIGHT_DEFAULT = "insightful_new_chat_on_highlight_default"

local function localRequire(name)
    local key = "insightful." .. name
    if package.loaded[key] then return package.loaded[key] end
    local chunk, err = loadfile(PLUGIN_DIR .. name .. ".lua")
    if not chunk then error(err) end
    local module = chunk()
    package.loaded[key] = module
    return module
end

local Agent = localRequire("agent")
local AnswerViewer = localRequire("answer_viewer")
local BookTools = localRequire("book_tools")
local Chat = localRequire("chat")
local ChatList = localRequire("chat_list")
local ProviderRegistry = localRequire("providers/registry"):new{
    compatible = localRequire("providers/openai_compatible"),
    anthropic = localRequire("providers/anthropic"),
    variants = {
        openai = localRequire("providers/openai"),
        deepseek = localRequire("providers/deepseek"),
        openrouter = localRequire("providers/openrouter"),
    },
}
local Storage = localRequire("storage")
local Stats = localRequire("stats")
local Streaming = localRequire("streaming")

local Insightful = WidgetContainer:extend{
    name = "insightful",
    is_doc_only = true,
}

local function loadConfiguration()
    local path = PLUGIN_DIR .. "configuration.lua"
    local ok, result = pcall(dofile, path)
    if ok and type(result) == "table" then return result end
    logger.info("Insightful: configuration.lua not loaded; chat remains available but requests require configuration")
    return {}
end

local function moveMenuItemToFront(menu_name, item_name)
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    local items = ok and order and order[menu_name]
    if type(items) ~= "table" then return end
    for index = #items, 1, -1 do
        if items[index] == item_name then table.remove(items, index) end
    end
    table.insert(items, 1, item_name)
end

function Insightful:init()
    self.configuration = loadConfiguration()
    self.storage = Storage.forUI({
        new_chat_on_send_default = function()
            return G_reader_settings:isTrue(NEW_CHAT_ON_HIGHLIGHT_DEFAULT)
        end,
    })
    self.stats = Stats.forUI()
    self:onDispatcherRegisterActions()
    moveMenuItemToFront("tools", self.name)
    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    if self.ui.highlight then
        -- Zen UI exposes this recognized slot when show_ai_assistant is enabled.
        self.ui.highlight:addToHighlightDialog("ai_assistant", function(reader_highlight)
            return {
                text = _("AI"),
                enabled = reader_highlight.selected_text ~= nil,
                callback = function()
                    local selection = self:captureSelection(reader_highlight)
                    if selection then self:showHighlightActions(selection) end
                end,
            }
        end)
    end
end

function Insightful:onDispatcherRegisterActions()
    Dispatcher:registerAction("insightful_show_chats", {
        category = "none",
        event = "ShowInsightfulChats",
        title = _("Insightful: show chats"),
        reader = true,
    })
end

function Insightful:captureSelection(reader_highlight)
    local selected = reader_highlight and reader_highlight.selected_text
    if not selected or type(selected.text) ~= "string" then return nil end
    local text = util.cleanupSelectedText(selected.text)
    if text == "" then return nil end
    local pos0 = selected.pos0
    local page
    if self.ui.paging and type(pos0) == "table" then
        page = tonumber(pos0.page)
    elseif pos0 and self.ui.document and type(self.ui.document.getPageFromXPointer) == "function" then
        local ok, result = pcall(self.ui.document.getPageFromXPointer, self.ui.document, pos0)
        if ok then page = tonumber(result) end
    end
    page = page or tonumber(self.ui.view and self.ui.view.state and self.ui.view.state.page)
    local section
    if page and self.ui.toc and type(self.ui.toc.getTocTitleByPage) == "function" then
        local ok, result = pcall(self.ui.toc.getTocTitleByPage, self.ui.toc, page)
        if ok then section = result end
    end
    return {
        text = text,
        page = page,
        section = section,
        locator = type(pos0) == "string" and pos0 or (page and tostring(page) or nil),
    }
end

function Insightful:_showStorageError(message, err)
    logger.warn("Insightful: storage error:", err)
    UIManager:show(InfoMessage:new{
        text = message,
        icon = "notice-warning",
    })
end

function Insightful:_openConversation(conversation, selection, quick_action)
    local running_chat = self.running_chat
    if running_chat and running_chat.busy and running_chat:isConversation(conversation) then
        if self.active_chat and self.active_chat ~= running_chat then self.active_chat:close() end
        self.active_chat = running_chat
        running_chat:reopen(selection, quick_action)
        return running_chat
    end
    if self.active_chat then self.active_chat:close() end
    local chat = Chat:new{
        plugin = self,
        agent = Agent,
        answer_viewer_class = AnswerViewer,
        book_tools_class = BookTools,
        provider_registry = ProviderRegistry,
        storage = self.storage,
        stats = self.stats,
        streaming = Streaming,
        conversation = conversation,
        configuration = self.configuration,
        selection = selection,
        context = {
            ui = self.ui,
            document = self.ui.document,
        },
    }
    self.active_chat = chat
    chat:show(quick_action)
    return chat
end

local function formatCount(value)
    local digits = tostring(math.max(0, math.floor(tonumber(value) or 0)))
    local formatted = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return formatted:gsub("^,", "")
end

local function formatCost(value)
    return string.format("$%.8f", math.max(0, tonumber(value) or 0))
end

local function statisticsText(title, totals)
    totals = type(totals) == "table" and totals or {}
    local missing = math.max(0,
        (tonumber(totals.requests) or 0) - (tonumber(totals.measured_requests) or 0))
    local missing_cost = math.max(0,
        (tonumber(totals.requests) or 0) - (tonumber(totals.costed_requests) or 0))
    local lines = {
        title,
        "",
        _("Model requests: ") .. formatCount(totals.requests),
        _("Input tokens: ") .. formatCount(totals.input_tokens),
        _("Output tokens: ") .. formatCount(totals.output_tokens),
        _("Total tokens: ") .. formatCount(totals.total_tokens),
    }
    if (tonumber(totals.costed_requests) or 0) > 0 then
        table.insert(lines, _("Provider reported cost: ") .. formatCost(totals.cost_usd))
    else
        table.insert(lines, _("Provider reported cost: Not available"))
    end
    if missing > 0 then
        table.insert(lines, "")
        table.insert(lines, _("Requests without token counts: ") .. formatCount(missing))
    end
    if missing_cost > 0 and (tonumber(totals.costed_requests) or 0) > 0 then
        table.insert(lines, _("Requests without reported cost: ") .. formatCount(missing_cost))
    end
    return table.concat(lines, "\n")
end

local PROVIDER_NAMES = {
    anthropic = "Anthropic",
    deepseek = "DeepSeek",
    openai = "OpenAI",
    openrouter = "OpenRouter",
}

function Insightful:showGeneralStatistics()
    local provider_id = ProviderRegistry:providerId(self.configuration)
    local parameters = type(self.configuration.parameters) == "table"
        and self.configuration.parameters or {}
    local model = tostring(parameters.model or self.configuration.model or "")
    if model == "" then model = _("Not set") end
    local output_limit = tonumber(parameters.max_completion_tokens or parameters.max_tokens
        or self.configuration.max_completion_tokens or self.configuration.max_tokens)
    if not output_limit and provider_id == "anthropic" then output_limit = 8192 end
    local output_limit_text = output_limit and formatCount(output_limit) or _("Provider default")
    UIManager:show(InfoMessage:new{
        text = table.concat({
            _("General"),
            "",
            _("Provider: ") .. tostring(PROVIDER_NAMES[provider_id] or provider_id),
            _("Configured model: ") .. model,
            _("Streaming: ") .. (self.configuration.stream == false and _("Off") or _("On")),
            _("Output token limit: ") .. output_limit_text,
        }, "\n"),
        show_icon = false,
    })
end

function Insightful:_showStatistics(title, totals, err)
    if not totals then
        self:_showStorageError(_("The statistics could not be opened."), err)
        return
    end
    UIManager:show(InfoMessage:new{
        text = statisticsText(title, totals),
        show_icon = false,
    })
end

function Insightful:showBookStatistics()
    local book = self.storage:getBook(self.ui)
    local totals, err = self.stats:getBook(book)
    self:_showStatistics(_("Current book") .. "\n" .. tostring(book.title), totals, err)
end

function Insightful:showGlobalStatistics()
    local totals, err = self.stats:getGlobal()
    self:_showStatistics(_("All books"), totals, err)
end

function Insightful:openChat(selection, quick_action, chat_id)
    local book = self.storage:getBook(self.ui)
    local conversation, load_err = self.storage:load(book, chat_id)
    if not conversation then
        self:_showStorageError(_("The chat could not be opened."), load_err)
        return
    end
    if load_err then logger.warn("Insightful: conversation load warning:", load_err) end
    self:_openConversation(conversation, selection, quick_action)
end

function Insightful:startNewChat(selection, quick_action)
    local book = self.storage:getBook(self.ui)
    local conversation, create_err = self.storage:create(book)
    if not conversation then
        self:_showStorageError(_("A new chat could not be started."), create_err)
        return
    end
    self:_openConversation(conversation, selection, quick_action)
end

function Insightful:openFromHighlight(selection, quick_action)
    local book = self.storage:getBook(self.ui)
    local enabled, setting_err = self.storage:getNewChatOnSend(book)
    if setting_err then
        logger.warn("Insightful: highlighted-action chat setting could not be read:", setting_err)
    end
    if enabled then
        return self:startNewChat(selection, quick_action)
    end
    return self:openChat(selection, quick_action)
end

function Insightful:showChatList()
    if self.active_chat then self.active_chat:close() end
    local book = self.storage:getBook(self.ui)
    return ChatList.show{
        storage = self.storage,
        book = book,
        on_new = function() self:startNewChat() end,
        on_open = function(chat_id) self:openChat(nil, nil, chat_id) end,
    }
end

function Insightful:onShowInsightfulChats()
    self:showChatList()
    return true
end

function Insightful:showHighlightActions(selection)
    local action_dialog
    local function choose(action)
        UIManager:close(action_dialog)
        UIManager:nextTick(function() self:openFromHighlight(selection, action) end)
    end
    action_dialog = ButtonDialog:new{
        title = _("Insightful actions"),
        buttons = {
            {
                { text = _("Explain"), callback = function() choose("explain") end },
                { text = _("Explain terms"), callback = function() choose("explain_terms") end },
            },
            {
                { text = _("Context / history"), callback = function() choose("context_history") end },
                { text = _("People / characters"), callback = function() choose("people_characters") end },
            },
            {
                { text = _("Ask AI…"), callback = function() choose() end },
            },
        },
    }
    UIManager:show(action_dialog)
end

function Insightful:addToMainMenu(menu_items)
    local book = self.storage:getBook(self.ui)
    menu_items.insightful = {
        text = _("Insightful"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Continue current chat"),
                callback = function() self:openChat() end,
            },
            {
                text = _("Chats"),
                callback = function() self:showChatList() end,
            },
            {
                text = _("Start new chat"),
                callback = function() self:startNewChat() end,
                separator = true,
            },
            {
                text_func = function()
                    local text = _("New chat for highlighted actions")
                    local enabled = self.storage:getNewChatOnSend(book)
                    local default_enabled = G_reader_settings:isTrue(NEW_CHAT_ON_HIGHLIGHT_DEFAULT)
                    return enabled == default_enabled and (text .. "   ★") or text
                end,
                checked_func = function()
                    return self.storage:getNewChatOnSend(book)
                end,
                callback = function(touchmenu_instance)
                    local enabled = self.storage:getNewChatOnSend(book)
                    local ok, save_err = self.storage:setNewChatOnSend(book, not enabled)
                    if not ok then
                        self:_showStorageError(_("The chat setting could not be saved."), save_err)
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                hold_callback = function(touchmenu_instance)
                    local enabled = self.storage:getNewChatOnSend(book)
                    UIManager:show(ConfirmBox:new{
                        text = enabled
                            and _("Use a new chat for highlighted actions by default in other books?")
                            or _("Continue the current chat for highlighted actions by default in other books?"),
                        ok_callback = function()
                            G_reader_settings:saveSetting(NEW_CHAT_ON_HIGHLIGHT_DEFAULT, enabled)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
                keep_menu_open = true,
                help_text = _("Tap to change this book. Hold to use its current value as the default for other books."),
            },
            {
                text = _("Statistics"),
                sub_item_table = {
                    {
                        text = _("General"),
                        callback = function() self:showGeneralStatistics() end,
                    },
                    {
                        text = _("Current book"),
                        callback = function() self:showBookStatistics() end,
                    },
                    {
                        text = _("All books"),
                        callback = function() self:showGlobalStatistics() end,
                    },
                },
                separator = true,
            },
            {
                text = _("Gesture shortcut"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Open Taps and gestures, then Gesture manager. Assign Insightful: show chats to a corner, swipe, or multiswipe gesture."),
                    })
                end,
                help_text = _("The gesture opens the chat list without selecting text."),
            },
        },
    }
end

function Insightful:onClose()
    local active_chat = self.active_chat
    local running_chat = self.running_chat
    if active_chat then active_chat:close() end
    if running_chat then running_chat:shutdown() end
    self.running_chat = nil
end

Insightful.onCloseWidget = Insightful.onClose

return Insightful
