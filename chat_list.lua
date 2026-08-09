local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local ChatList = {}

local function dateText(timestamp)
    timestamp = tonumber(timestamp)
    if not timestamp then return "" end
    return os.date("%Y-%m-%d %H:%M", timestamp)
end

local function showError(message)
    UIManager:show(InfoMessage:new{
        text = message,
        icon = "notice-warning",
    })
end

function ChatList.show(options)
    options = options or {}
    local storage = assert(options.storage)
    local book = assert(options.book)
    local chats, load_err = storage:list(book)
    if load_err then
        logger.warn("Insightful: chat list load failed:", load_err)
        showError(_("The chat list could not be loaded."))
        return
    end

    local menu
    local item_table = {
        {
            text = _("Start new chat"),
            bold = true,
            callback = function()
                UIManager:nextTick(function()
                    if options.on_new then options.on_new() end
                end)
            end,
        },
    }

    for chat_index, chat in ipairs(chats) do
        local chat_id = chat.id
        table.insert(item_table, {
            text = chat.title or _("New chat"),
            mandatory = dateText(chat.updated_at),
            bold = chat.active,
            chat_id = chat_id,
            callback = function()
                UIManager:nextTick(function()
                    if options.on_open then options.on_open(chat_id) end
                end)
            end,
        })
    end

    menu = Menu:new{
        title = _("Insightful chats"),
        subtitle = tostring(book.title or _("Book")),
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        single_line = true,
        title_bar_fm_style = true,
        close_callback = function() UIManager:close(menu) end,
    }

    function menu:onMenuHold(item)
        if not item.chat_id then return true end
        UIManager:show(ConfirmBox:new{
            text = _("Delete this chat?") .. "\n\n" .. tostring(item.text)
                .. "\n\n" .. _("The deleted chat cannot be recovered."),
            ok_text = _("Delete"),
            ok_callback = function()
                local ok, delete_err = storage:delete(book, item.chat_id)
                if not ok then
                    logger.warn("Insightful: chat delete failed:", delete_err)
                    showError(_("The chat could not be deleted."))
                    return
                end
                UIManager:close(menu)
                UIManager:nextTick(function()
                    ChatList.show(options)
                end)
            end,
        })
        return true
    end

    UIManager:show(menu)
    return menu
end

return ChatList
