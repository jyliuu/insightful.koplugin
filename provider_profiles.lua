local Profiles = {}

local PROVIDER_ORDER = { "openai", "deepseek", "openrouter", "anthropic" }
local PROFILE_FIELDS = {
    api_key = true,
    base_url = true,
    headers = true,
    max_completion_tokens = true,
    max_tokens = true,
    model = true,
    parameters = true,
    temperature = true,
}

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

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

local function inferredProvider(configuration)
    local url = trim(configuration and configuration.base_url):lower()
    if url:find("api%.anthropic%.com") then return "anthropic" end
    if url:find("openrouter%.ai") then return "openrouter" end
    if url:find("api%.deepseek%.com") then return "deepseek" end
    return "openai"
end

local function configuredProvider(configuration)
    local provider = trim(configuration and configuration.provider):lower()
    return provider ~= "" and provider or inferredProvider(configuration)
end

local function hasKey(configuration)
    return type(configuration) == "table" and trim(configuration.api_key) ~= ""
end

local function profileFor(configuration, provider_id)
    local providers = type(configuration) == "table" and configuration.providers
    local profile = type(providers) == "table" and providers[provider_id]
    return type(profile) == "table" and profile or nil
end

function Profiles.available(configuration)
    configuration = type(configuration) == "table" and configuration or {}
    local default_provider = configuredProvider(configuration)
    local available = {}
    for _, provider_id in ipairs(PROVIDER_ORDER) do
        local profile = profileFor(configuration, provider_id)
        if hasKey(profile) or (not profile and provider_id == default_provider and hasKey(configuration)) then
            table.insert(available, provider_id)
        end
    end
    return available
end

function Profiles.isAvailable(configuration, provider_id)
    provider_id = trim(provider_id):lower()
    for _, available_id in ipairs(Profiles.available(configuration)) do
        if available_id == provider_id then return true end
    end
    return false
end

local function commonConfiguration(configuration)
    local result = {}
    for key, value in pairs(configuration) do
        if key ~= "providers" and key ~= "provider" and not PROFILE_FIELDS[key] then
            result[copyTable(key)] = copyTable(value)
        end
    end
    return result
end

function Profiles.resolve(configuration, requested_provider)
    configuration = type(configuration) == "table" and configuration or {}
    local available = Profiles.available(configuration)
    local available_set = {}
    for _, provider_id in ipairs(available) do available_set[provider_id] = true end

    local selected = trim(requested_provider):lower()
    local default_provider = configuredProvider(configuration)
    if not available_set[selected] then
        selected = available_set[default_provider] and default_provider or available[1]
    end

    if not selected then
        return copyTable(configuration), default_provider
    end

    local profile = profileFor(configuration, selected)
    if not profile then
        local legacy = copyTable(configuration)
        legacy.providers = nil
        legacy.provider = selected
        return legacy, selected
    end

    local resolved = commonConfiguration(configuration)
    for key, value in pairs(profile) do resolved[copyTable(key)] = copyTable(value) end
    resolved.provider = selected
    return resolved, selected
end

return Profiles
