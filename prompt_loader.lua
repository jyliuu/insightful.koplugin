local PromptLoader = {}

local MAX_PROMPT_BYTES = 64 * 1024

local PromptSet = {}
PromptSet.__index = PromptSet

local function joinPath(directory, filename)
    local separator = directory:sub(-1) == "/" and "" or "/"
    return directory .. separator .. filename
end

local function readPrompt(path)
    local file, open_err = io.open(path, "rb")
    if not file then return nil, open_err end

    local text = file:read("*all")
    file:close()
    if not text then return nil, "could not read the file" end
    if #text > MAX_PROMPT_BYTES then
        return nil, string.format("prompt exceeds %d bytes", MAX_PROMPT_BYTES)
    end

    text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("%s+$", "")
    if text == "" then return nil, "prompt is empty" end
    return text
end

function PromptLoader.load(directory, manifest)
    if type(directory) ~= "string" or directory == "" then
        return nil, "prompt directory is required"
    end
    if type(manifest) ~= "table" then
        return nil, "prompt manifest is required"
    end

    local templates = {}
    for name, filename in pairs(manifest) do
        if type(name) ~= "string" or name == "" or type(filename) ~= "string" or filename == "" then
            return nil, "prompt manifest entries must have string names and filenames"
        end
        local text, read_err = readPrompt(joinPath(directory, filename))
        if not text then
            return nil, string.format("could not load %s (%s): %s", name, filename, tostring(read_err))
        end
        templates[name] = text
    end

    return setmetatable({ templates = templates }, PromptSet)
end

function PromptSet:get(name)
    local template = self.templates[name]
    if not template then return nil, "unknown prompt: " .. tostring(name) end
    return template
end

function PromptSet:render(name, values)
    local template, get_err = self:get(name)
    if not template then return nil, get_err end

    values = type(values) == "table" and values or {}
    local missing
    local rendered = template:gsub("<([a-z][a-z0-9_]*)>", function(tag)
        local value = values[tag]
        if value == nil then
            missing = missing or tag
            return "<" .. tag .. ">"
        end
        return tostring(value)
    end)
    if missing then return nil, "missing prompt value: <" .. missing .. ">" end
    return rendered
end

return PromptLoader
