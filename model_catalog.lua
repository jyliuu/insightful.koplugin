local Catalog = {}
Catalog.__index = Catalog

local DEFAULT_LIMIT = 50

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function urlEncode(value)
    return tostring(value or ""):gsub("([^%w%-_%.~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end)
end

local function origin(url)
    return trim(url):match("^(https?://[^/]+)")
end

function Catalog:new(options)
    options = options or {}
    local instance = setmetatable({}, self)
    instance.transport = assert(options.transport, "model catalog transport is required")
    instance.json = options.json
    instance.limit = math.max(1, tonumber(options.limit) or DEFAULT_LIMIT)
    return instance
end

function Catalog:supports(configuration)
    configuration = type(configuration) == "table" and configuration or {}
    if trim(configuration.models_url) ~= "" then return true end
    return configuration.provider == "deepseek" or configuration.provider == "openrouter"
end

function Catalog:_url(configuration, query)
    if trim(configuration.models_url) ~= "" then
        local url = trim(configuration.models_url)
        if trim(query) ~= "" then
            url = url .. (url:find("?", 1, true) and "&" or "?") .. "q=" .. urlEncode(trim(query))
        end
        return url
    end

    local base = origin(configuration.base_url)
    if not base then return nil end
    if configuration.provider == "deepseek" then
        return base .. "/models"
    elseif configuration.provider == "openrouter" then
        local url = base .. "/api/v1/models"
            .. "?output_modalities=text&supported_parameters=tools&sort=most-popular"
        if trim(query) ~= "" then url = url .. "&q=" .. urlEncode(trim(query)) end
        return url
    end
end

function Catalog:list(configuration, query)
    configuration = type(configuration) == "table" and configuration or {}
    if trim(configuration.api_key) == "" then return nil, nil, "API key is missing." end
    local url = self:_url(configuration, query)
    if not url then return nil, nil, "This provider does not expose a model list." end

    local ok, code, response_body, status = self.transport(
        url,
        {
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer " .. configuration.api_key,
        },
        tonumber(configuration.timeout) or 30,
        configuration.verify_ssl ~= false
    )
    if not ok then
        return nil, nil, "Could not load models: " .. tostring(status or code or "network error")
    end
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then
        return nil, nil, "Model service returned HTTP " .. tostring(code or "?") .. "."
    end

    local json = self.json or require("json")
    local decoded_ok, decoded = pcall(json.decode, response_body or "")
    if not decoded_ok or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
        return nil, nil, "Model service returned invalid JSON."
    end

    local models = {}
    local seen = {}
    local truncated = false
    local function add(id, name)
        id = trim(id)
        if id == "" or seen[id] then return end
        if #models >= self.limit then
            truncated = true
            return
        end
        seen[id] = true
        table.insert(models, {
            id = id,
            name = trim(name) ~= "" and trim(name) or id,
        })
    end

    add(configuration.model, configuration.model)
    for _, model in ipairs(decoded.data) do
        if type(model) == "table" then add(model.id, model.name) end
    end
    if #models == 0 then return nil, nil, "The provider returned no models." end
    return models, truncated
end

Catalog.default_limit = DEFAULT_LIMIT

return Catalog
