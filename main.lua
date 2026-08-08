local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local source = debug.getinfo(1, "S").source
local PLUGIN_DIR = source:match("^@(.*/)") or ""

local function localRequire(name)
    local key = "bookagent." .. name
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

local BookAgent = WidgetContainer:extend{
    name = "bookagent",
    is_doc_only = true,
}

local function loadConfiguration()
    local path = PLUGIN_DIR .. "configuration.lua"
    local ok, result = pcall(dofile, path)
    if ok and type(result) == "table" then return result end
    logger.info("BookAgent: configuration.lua not loaded; chat remains available but requests require configuration")
    return {}
end

function BookAgent:init()
    self.configuration = loadConfiguration()
    self.storage = Storage.forUI(self.ui)
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

function BookAgent:captureSelection(reader_highlight)
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

function BookAgent:openChat(selection, quick_action, focus_input)
    if self.active_chat then self.active_chat:close() end
    local book = self.storage:getBook(self.ui)
    local conversation, load_err = self.storage:load(book)
    if load_err then logger.warn("BookAgent: conversation load warning:", load_err) end
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
            book_id = book.id,
        },
    }
    self.active_chat = chat
    chat:show(focus_input, quick_action)
end

function BookAgent:showHighlightActions(selection)
    local action_dialog
    local function choose(action, focus_input)
        UIManager:close(action_dialog)
        UIManager:nextTick(function() self:openChat(selection, action, focus_input) end)
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

function BookAgent:addToMainMenu(menu_items)
    menu_items.bookagent = {
        text = _("BookAgent"),
        callback = function() self:openChat(nil, nil, true) end,
    }
end

function BookAgent:onClose()
    if self.active_chat then self.active_chat:close() end
end

BookAgent.onCloseWidget = BookAgent.onClose

return BookAgent
