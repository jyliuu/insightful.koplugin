local Stats = {}
Stats.__index = Stats

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

local function count(value)
    value = tonumber(value)
    if not value or value < 0 then return 0 end
    return math.floor(value)
end

local function amount(value)
    value = tonumber(value)
    if not value or value < 0 then return 0 end
    return value
end

local function emptyTotals()
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

local function normaliseTotals(value)
    value = type(value) == "table" and value or {}
    local totals = emptyTotals()
    for _, key in ipairs({
        "requests", "measured_requests", "costed_requests",
        "input_tokens", "output_tokens", "total_tokens",
    }) do
        totals[key] = count(value[key])
    end
    totals.cost_usd = amount(value.cost_usd)
    totals.measured_requests = math.min(totals.measured_requests, totals.requests)
    totals.costed_requests = math.min(totals.costed_requests, totals.requests)
    return totals
end

local function addTotals(target, usage)
    for _, key in ipairs({
        "requests", "measured_requests", "costed_requests",
        "input_tokens", "output_tokens", "total_tokens",
    }) do
        target[key] = count(target[key]) + count(usage[key])
    end
    target.cost_usd = amount(target.cost_usd) + amount(usage.cost_usd)
    target.measured_requests = math.min(target.measured_requests, target.requests)
    target.costed_requests = math.min(target.costed_requests, target.requests)
end

function Stats:new(options)
    options = options or {}
    local instance = setmetatable({}, self)
    instance.path = assert(options.path, "statistics path is required")
    instance.directory = assert(options.directory, "statistics directory is required")
    instance.settings_factory = assert(options.settings_factory, "settings factory is required")
    instance.make_path = options.make_path
    return instance
end

function Stats.forUI()
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local util = require("util")
    local directory = DataStorage:getSettingsDir() .. "/insightful"
    return Stats:new{
        path = directory .. "/statistics.lua",
        directory = directory,
        settings_factory = function(path) return LuaSettings:open(path) end,
        make_path = util.makePath,
    }
end

function Stats:newState()
    return {
        version = VERSION,
        global = emptyTotals(),
        books = {},
    }
end

function Stats:_normaliseState(data)
    if type(data) ~= "table" or next(data) == nil then return self:newState() end
    if data.version ~= VERSION or type(data.books) ~= "table" then
        return nil, "unsupported statistics storage version"
    end

    local state = {
        version = VERSION,
        global = normaliseTotals(data.global),
        books = {},
    }
    for book_id, stored in pairs(data.books) do
        if type(book_id) == "string" and book_id ~= "" and type(stored) == "table" then
            state.books[book_id] = normaliseTotals(stored)
        end
    end
    return state
end

function Stats:_open()
    if self.make_path then
        local ok, err = pcall(self.make_path, self.directory)
        if not ok then return nil, tostring(err) end
    end
    local ok, settings = pcall(self.settings_factory, self.path)
    if not ok or not settings then
        return nil, ok and "could not open statistics" or tostring(settings)
    end
    return settings
end

function Stats:_load()
    local settings, open_err = self:_open()
    if not settings then return nil, nil, open_err end
    local state, state_err = self:_normaliseState(settings.data)
    if not state then return nil, settings, state_err end
    return state, settings
end

function Stats:_flush(settings, state)
    local ok, err = pcall(function()
        settings:reset(copyTable(state))
        settings:flush()
    end)
    if not ok then return nil, tostring(err) end
    return true
end

function Stats:record(book, usage)
    if type(book) ~= "table" or type(book.id) ~= "string" or book.id == "" then
        return nil, "invalid book"
    end
    usage = normaliseTotals(usage)
    if usage.requests == 0 then return true end

    local state, settings, err = self:_load()
    if not state then return nil, err end
    local stored = normaliseTotals(state.books[book.id])
    state.books[book.id] = stored
    addTotals(stored, usage)
    addTotals(state.global, usage)
    return self:_flush(settings, state)
end

function Stats:getBook(book)
    if type(book) ~= "table" or type(book.id) ~= "string" or book.id == "" then
        return nil, "invalid book"
    end
    local state, _, err = self:_load()
    if not state then return nil, err end
    local stored = state.books[book.id]
    return copyTable(stored or emptyTotals())
end

function Stats:getGlobal()
    local state, _, err = self:_load()
    if not state then return nil, err end
    return copyTable(state.global)
end

Stats.VERSION = VERSION
Stats.copyTable = copyTable

return Stats
