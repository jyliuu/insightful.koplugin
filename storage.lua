local Storage = {}
Storage.__index = Storage

local VERSION = 2
local LEGACY_VERSION = 1
local CHAT_TITLE_LENGTH = 80

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

local function pathHash(text)
    local hash = 5381
    for i = 1, #(text or "") do
        hash = (hash * 33 + text:byte(i)) % 4294967296
    end
    return string.format("path-%08x", hash)
end

local function cleanId(value)
    value = tostring(value or "")
    value = value:gsub("[^%w%-_]", "")
    if value == "" then return nil end
    return value
end

local function authorText(value)
    if type(value) == "table" then
        return table.concat(value, ", ")
    end
    return tostring(value or "")
end

local function readSetting(settings, key)
    if settings and type(settings.readSetting) == "function" then
        local ok, value = pcall(settings.readSetting, settings, key)
        if ok then return value end
    end
end

local function trimAndCollapse(text)
    return tostring(text or "")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

local function utf8Prefix(text, max_characters)
    local index = 1
    local characters = 0
    while index <= #text and characters < max_characters do
        local byte = text:byte(index)
        local width = 1
        if byte >= 240 and byte <= 247 then
            width = 4
        elseif byte >= 224 and byte <= 239 then
            width = 3
        elseif byte >= 194 and byte <= 223 then
            width = 2
        end
        if index + width - 1 > #text then break end
        index = index + width
        characters = characters + 1
    end
    return text:sub(1, index - 1), index <= #text
end

local function boundedTitle(text)
    text = trimAndCollapse(text)
    if text == "" then return nil end
    local prefix, truncated = utf8Prefix(text, CHAT_TITLE_LENGTH)
    return truncated and (prefix .. "…") or prefix
end

local function titleFromMessages(messages)
    if type(messages) ~= "table" then return nil end
    for _, message in ipairs(messages) do
        if type(message) == "table" and message.role == "user" then
            local title = boundedTitle(message.display_content or message.content)
            if title then return title end
        end
    end
end

local function messageTimes(messages, fallback)
    local first
    local last
    for _, message in ipairs(type(messages) == "table" and messages or {}) do
        local timestamp = tonumber(type(message) == "table" and message.timestamp)
        if timestamp then
            first = first and math.min(first, timestamp) or timestamp
            last = last and math.max(last, timestamp) or timestamp
        end
    end
    return first or fallback, last or first or fallback
end

function Storage:new(options)
    options = options or {}
    local instance = setmetatable({}, self)
    instance.root = assert(options.root, "storage root is required")
    instance.settings_factory = options.settings_factory
    instance.make_path = options.make_path
    instance.partial_md5 = options.partial_md5
    instance.new_chat_on_send_default = options.new_chat_on_send_default
    instance.now = options.now or os.time
    return instance
end

function Storage.forUI(options)
    options = options or {}
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local util = require("util")
    local root = DataStorage:getSettingsDir() .. "/insightful/conversations"
    return Storage:new{
        root = root,
        settings_factory = function(path) return LuaSettings:open(path) end,
        make_path = util.makePath,
        partial_md5 = util.partialMD5,
        new_chat_on_send_default = options.new_chat_on_send_default,
    }
end

function Storage:_newChatOnSendDefault()
    if type(self.new_chat_on_send_default) ~= "function" then return false end
    local ok, enabled = pcall(self.new_chat_on_send_default)
    return ok and enabled == true
end

function Storage:getBook(ui)
    local document = ui and ui.document
    local path = document and document.file or ""
    local props = ui and ui.doc_props
    if type(props) ~= "table" then
        props = readSetting(ui and ui.doc_settings, "doc_props")
    end
    if type(props) ~= "table" and document and type(document.getProps) == "function" then
        local ok, result = pcall(document.getProps, document)
        if ok and type(result) == "table" then props = result end
    end
    props = type(props) == "table" and props or {}

    local id = cleanId(readSetting(ui and ui.doc_settings, "partial_md5_checksum"))
    if not id and self.partial_md5 and path ~= "" then
        local ok, digest = pcall(self.partial_md5, path)
        if ok then id = cleanId(digest) end
    end
    id = id or pathHash(path)

    local title = props.title
    if not title or title == "" then
        title = path:match("([^/]+)$") or "Untitled book"
    end

    return {
        id = id,
        title = tostring(title),
        authors = authorText(props.authors or props.author),
        path = path,
    }
end

function Storage:conversationPath(book_id)
    local id = assert(cleanId(book_id), "valid book id is required")
    return self.root .. "/" .. id .. ".lua"
end

function Storage:newBookState(book)
    return {
        version = VERSION,
        book = copyTable(book),
        next_chat_number = 1,
        active_chat_id = nil,
        new_chat_on_send = self:_newChatOnSendDefault(),
        new_chat_on_send_override = false,
        chats = {},
    }
end

function Storage:_allocateChatId(state)
    local number = math.max(1, tonumber(state.next_chat_number) or 1)
    local used = {}
    for _, conversation in ipairs(state.chats or {}) do
        local existing_id = cleanId(conversation.id)
        if existing_id then used[existing_id] = true end
    end
    local id
    repeat
        id = "chat-" .. tostring(number)
        number = number + 1
    until not used[id]
    state.next_chat_number = number
    return id
end

function Storage:newConversation(book, id, timestamp)
    timestamp = tonumber(timestamp) or self.now()
    return {
        version = VERSION,
        id = cleanId(id),
        book = copyTable(book),
        title = nil,
        created_at = timestamp,
        updated_at = timestamp,
        messages = {},
    }
end

function Storage:_normaliseConversation(conversation, book, fallback_id)
    if type(conversation) ~= "table" then return nil end
    local messages = type(conversation.messages) == "table" and conversation.messages or {}
    local created_at, updated_at = messageTimes(messages, self.now())
    conversation.version = VERSION
    conversation.id = cleanId(conversation.id) or fallback_id
    conversation.book = copyTable(book)
    conversation.title = boundedTitle(conversation.title) or titleFromMessages(messages)
    conversation.created_at = tonumber(conversation.created_at) or created_at
    conversation.updated_at = tonumber(conversation.updated_at) or updated_at
    conversation.messages = messages
    return conversation
end

function Storage:_migrateLegacy(data, book)
    local state = self:newBookState(book)
    local conversation = self:_normaliseConversation(copyTable(data), book, "chat-1")
    state.next_chat_number = 2
    state.active_chat_id = conversation.id
    state.chats = { conversation }
    return state
end

function Storage:_normaliseState(data, book)
    if type(data) ~= "table" then return self:newBookState(book) end
    if data.version == LEGACY_VERSION and type(data.messages) == "table" then
        return self:_migrateLegacy(data, book), true
    end
    if next(data) == nil then return self:newBookState(book) end
    if data.version ~= VERSION or type(data.chats) ~= "table" then
        return nil, nil, "unsupported conversation storage version"
    end

    local state = copyTable(data)
    state.version = VERSION
    state.book = copyTable(book)
    state.next_chat_number = math.max(1, tonumber(state.next_chat_number) or 1)
    state.active_chat_id = cleanId(state.active_chat_id)
    state.new_chat_on_send = state.new_chat_on_send == true
    local setting_migrated = data.new_chat_on_send_override == nil
    if setting_migrated then
        -- Before global defaults existed, true meant the user had enabled the
        -- per-book setting. False was also the untouched initial value.
        state.new_chat_on_send_override = state.new_chat_on_send
    else
        state.new_chat_on_send_override = data.new_chat_on_send_override == true
    end
    state.chats = {}
    local seen = {}
    for index, stored in ipairs(data.chats) do
        local conversation = self:_normaliseConversation(copyTable(stored), book, "chat-" .. tostring(index))
        if conversation and not seen[conversation.id] then
            seen[conversation.id] = true
            table.insert(state.chats, conversation)
        end
    end
    if state.active_chat_id and not seen[state.active_chat_id] then
        state.active_chat_id = nil
    end
    return state, setting_migrated
end

function Storage:_open(path, create_root)
    if create_root and self.make_path then
        local ok, err = pcall(self.make_path, self.root)
        if not ok then return nil, tostring(err) end
    end
    if not self.settings_factory then
        return nil, "settings factory is unavailable"
    end
    local ok, settings = pcall(self.settings_factory, path)
    if not ok or not settings then
        return nil, ok and "could not open conversation" or tostring(settings)
    end
    return settings
end

function Storage:_flush(settings, state)
    local ok, flush_err = pcall(function()
        settings:reset(copyTable(state))
        settings:flush()
    end)
    if not ok then return nil, tostring(flush_err) end
    return true
end

function Storage:_loadState(book, create_root)
    local path = self:conversationPath(book.id)
    local settings, open_err = self:_open(path, create_root)
    if not settings then return nil, nil, open_err end
    local state, migrated, state_err = self:_normaliseState(settings.data, book)
    if not state then return nil, settings, state_err end
    if migrated then
        local ok, flush_err = self:_flush(settings, state)
        if not ok then return nil, settings, flush_err end
    end
    return state, settings
end

function Storage:_findChat(state, chat_id)
    chat_id = cleanId(chat_id)
    if not chat_id then return nil end
    for index, conversation in ipairs(state.chats) do
        if conversation.id == chat_id then return conversation, index end
    end
end

function Storage:_newestChat(state)
    local newest
    for _, conversation in ipairs(state.chats) do
        if not newest
            or conversation.updated_at > newest.updated_at
            or (conversation.updated_at == newest.updated_at
                and conversation.created_at > newest.created_at)
            or (conversation.updated_at == newest.updated_at
                and conversation.created_at == newest.created_at
                and conversation.id > newest.id) then
            newest = conversation
        end
    end
    return newest
end

function Storage:create(book)
    local state, settings, err = self:_loadState(book, true)
    if not state then return nil, err end
    local conversation = self:newConversation(book, self:_allocateChatId(state))
    table.insert(state.chats, conversation)
    state.active_chat_id = conversation.id
    local ok, flush_err = self:_flush(settings, state)
    if not ok then return nil, flush_err end
    return copyTable(conversation)
end

function Storage:load(book, chat_id)
    local state, settings, err = self:_loadState(book, true)
    if not state then return self:newConversation(book), err end

    local conversation
    if chat_id then
        conversation = self:_findChat(state, chat_id)
        if not conversation then return nil, "chat was not found" end
    else
        conversation = self:_findChat(state, state.active_chat_id)
        if not conversation then conversation = self:_newestChat(state) end
    end

    if not conversation then
        conversation = self:newConversation(book, self:_allocateChatId(state))
        table.insert(state.chats, conversation)
    end
    if state.active_chat_id ~= conversation.id then
        state.active_chat_id = conversation.id
    end
    local ok, flush_err = self:_flush(settings, state)
    if not ok then return copyTable(conversation), flush_err end
    return copyTable(conversation)
end

function Storage:save(conversation, make_active)
    if type(conversation) ~= "table" or type(conversation.book) ~= "table" then
        return nil, "invalid conversation"
    end
    local state, settings, err = self:_loadState(conversation.book, true)
    if not state then return nil, err end

    conversation.id = cleanId(conversation.id) or self:_allocateChatId(state)
    conversation.updated_at = self.now()
    conversation.title = boundedTitle(conversation.title) or titleFromMessages(conversation.messages)
    local normalised = self:_normaliseConversation(conversation, conversation.book, conversation.id)
    local _, index = self:_findChat(state, normalised.id)
    if index then
        state.chats[index] = normalised
    else
        table.insert(state.chats, normalised)
    end
    if make_active ~= false then state.active_chat_id = normalised.id end
    local ok, flush_err = self:_flush(settings, state)
    if not ok then return nil, flush_err end
    return true
end

function Storage:list(book)
    local state, _, err = self:_loadState(book, true)
    if not state then return {}, err end
    local chats = {}
    for _, conversation in ipairs(state.chats) do
        table.insert(chats, {
            id = conversation.id,
            title = conversation.title or titleFromMessages(conversation.messages),
            created_at = conversation.created_at,
            updated_at = conversation.updated_at,
            message_count = #conversation.messages,
            active = conversation.id == state.active_chat_id,
        })
    end
    table.sort(chats, function(left, right)
        if left.updated_at ~= right.updated_at then return left.updated_at > right.updated_at end
        if left.created_at ~= right.created_at then return left.created_at > right.created_at end
        return left.id > right.id
    end)
    return chats
end

function Storage:delete(book, chat_id)
    local state, settings, err = self:_loadState(book, true)
    if not state then return nil, err end
    local _, index = self:_findChat(state, chat_id)
    if not index then return nil, "chat was not found" end
    table.remove(state.chats, index)
    if state.active_chat_id == cleanId(chat_id) then
        local newest = self:_newestChat(state)
        state.active_chat_id = newest and newest.id or nil
    end
    return self:_flush(settings, state)
end

function Storage:getNewChatOnSend(book)
    local state, _, err = self:_loadState(book, true)
    if not state then return false, err end
    if not state.new_chat_on_send_override then
        return self:_newChatOnSendDefault()
    end
    return state.new_chat_on_send == true
end

function Storage:setNewChatOnSend(book, enabled)
    local state, settings, err = self:_loadState(book, true)
    if not state then return nil, err end
    state.new_chat_on_send = enabled == true
    state.new_chat_on_send_override = true
    return self:_flush(settings, state)
end

return Storage
