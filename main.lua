local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local source = debug.getinfo(1, "S").source
local PLUGIN_DIR = source:match("^@(.*/)") or ""

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
local ProviderRegistry = localRequire("provider_registry"):new{
    compatible = localRequire("provider_openai_compatible"),
    anthropic = localRequire("provider_anthropic"),
    variants = {
        openai = localRequire("provider_openai"),
        deepseek = localRequire("provider_deepseek"),
        openrouter = localRequire("provider_openrouter"),
    },
}
local Storage = localRequire("storage")
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

function Insightful:init()
    self.configuration = loadConfiguration()
    self.storage = Storage.forUI(self.ui)
    self:onDispatcherRegisterActions()
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

function Insightful:_openConversation(conversation, selection, quick_action, focus_input)
    if self.active_chat then self.active_chat:close() end
    local chat = Chat:new{
        plugin = self,
        agent = Agent,
        answer_viewer_class = AnswerViewer,
        book_tools_class = BookTools,
        provider_registry = ProviderRegistry,
        storage = self.storage,
        streaming = Streaming,
        conversation = conversation,
        configuration = self.configuration,
        selection = selection,
        context = {
            ui = self.ui,
            document = self.ui.document,
            book_id = conversation.book.id,
        },
    }
    self.active_chat = chat
    chat:show(focus_input, quick_action)
end

function Insightful:openChat(selection, quick_action, focus_input, chat_id)
    local book = self.storage:getBook(self.ui)
    local conversation, load_err = self.storage:load(book, chat_id)
    if not conversation then
        self:_showStorageError(_("The chat could not be opened."), load_err)
        return
    end
    if load_err then logger.warn("Insightful: conversation load warning:", load_err) end
    self:_openConversation(conversation, selection, quick_action, focus_input)
end

function Insightful:startNewChat(selection, quick_action, focus_input)
    local book = self.storage:getBook(self.ui)
    local conversation, create_err = self.storage:create(book)
    if not conversation then
        self:_showStorageError(_("A new chat could not be started."), create_err)
        return
    end
    self:_openConversation(conversation, selection, quick_action, focus_input)
end

function Insightful:openFromHighlight(selection, quick_action, focus_input)
    local book = self.storage:getBook(self.ui)
    local enabled, setting_err = self.storage:getNewChatOnSend(book)
    if setting_err then
        logger.warn("Insightful: highlighted-action chat setting could not be read:", setting_err)
    end
    if enabled then
        return self:startNewChat(selection, quick_action, focus_input)
    end
    return self:openChat(selection, quick_action, focus_input)
end

function Insightful:showChatList()
    if self.active_chat then self.active_chat:close() end
    local book = self.storage:getBook(self.ui)
    return ChatList.show{
        storage = self.storage,
        book = book,
        on_new = function() self:startNewChat(nil, nil, true) end,
        on_open = function(chat_id) self:openChat(nil, nil, true, chat_id) end,
    }
end

function Insightful:onShowInsightfulChats()
    self:showChatList()
    return true
end

function Insightful:showHighlightActions(selection)
    local action_dialog
    local function choose(action, focus_input)
        UIManager:close(action_dialog)
        UIManager:nextTick(function() self:openFromHighlight(selection, action, focus_input) end)
    end
    action_dialog = ButtonDialog:new{
        title = _("AI"),
        buttons = {
            {
                { text = _("Explain"), callback = function() choose("explain", false) end },
                { text = _("Explain terms"), callback = function() choose("explain_terms", false) end },
            },
            {
                { text = _("Context / history"), callback = function() choose("context_history", false) end },
                { text = _("People / characters"), callback = function() choose("people_characters", false) end },
            },
            {
                { text = _("Ask AI…"), callback = function() choose(nil, true) end },
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
                callback = function() self:openChat(nil, nil, true) end,
            },
            {
                text = _("Chats"),
                callback = function() self:showChatList() end,
            },
            {
                text = _("Start new chat"),
                callback = function() self:startNewChat(nil, nil, true) end,
                separator = true,
            },
            {
                text = _("New chat for highlighted actions"),
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
                keep_menu_open = true,
                help_text = _("When this is on, each button chosen for a highlighted passage starts a separate chat. Later messages continue that chat."),
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
    if self.active_chat then self.active_chat:close() end
end

Insightful.onCloseWidget = Insightful.onClose

return Insightful
