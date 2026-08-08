local Storage = {}
Storage.__index = Storage

local VERSION = 1

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

function Storage:new(options)
    options = options or {}
    local instance = setmetatable({}, self)
    instance.root = assert(options.root, "storage root is required")
    instance.settings_factory = options.settings_factory
    instance.make_path = options.make_path
    instance.partial_md5 = options.partial_md5
    return instance
end

function Storage.forUI(ui)
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local util = require("util")
    local root = DataStorage:getSettingsDir() .. "/insightful/conversations"
    return Storage:new{
        root = root,
        settings_factory = function(path) return LuaSettings:open(path) end,
        make_path = util.makePath,
        partial_md5 = util.partialMD5,
        ui = ui,
    }
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

function Storage:newConversation(book)
    return {
        version = VERSION,
        book = copyTable(book),
        summary = nil,
        compacted_until = 0,
        messages = {},
    }
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

function Storage:_read(path, create_root)
    local settings, err = self:_open(path, create_root)
    if not settings then return nil, err end
    local data = settings.data
    if type(data) ~= "table" or data.version ~= VERSION or type(data.messages) ~= "table" then
        return nil
    end
    return data
end

function Storage:load(book)
    local path = self:conversationPath(book.id)
    local data, err = self:_read(path, true)
    if not data then return self:newConversation(book), err end
    data.book = copyTable(book)
    data.summary = data.summary or nil
    data.compacted_until = tonumber(data.compacted_until) or 0
    return data
end

function Storage:save(conversation)
    if type(conversation) ~= "table" or type(conversation.book) ~= "table" then
        return nil, "invalid conversation"
    end
    local path = self:conversationPath(conversation.book.id)
    local settings, err = self:_open(path, true)
    if not settings then return nil, err end
    local ok, flush_err = pcall(function()
        settings:reset(copyTable(conversation))
        settings:flush()
    end)
    if not ok then return nil, tostring(flush_err) end
    return true
end

Storage.copyTable = copyTable
Storage.VERSION = VERSION

return Storage
