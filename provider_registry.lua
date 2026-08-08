local Registry = {}
Registry.__index = Registry

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function inferredProvider(configuration)
    local url = trim(configuration and configuration.base_url):lower()
    if url:find("api%.anthropic%.com") then return "anthropic" end
    if url:find("openrouter%.ai") then return "openrouter" end
    if url:find("api%.deepseek%.com") then return "deepseek" end
    return "openai"
end

function Registry:new(options)
    local instance = setmetatable({}, self)
    instance.compatible = assert(options.compatible)
    instance.anthropic = assert(options.anthropic)
    instance.variants = assert(options.variants)
    return instance
end

function Registry:providerId(configuration)
    local configured = trim(configuration and configuration.provider):lower()
    if configured == "" then return inferredProvider(configuration) end
    return configured
end

function Registry:newProvider(configuration, transport, stream_transport)
    local provider_id = self:providerId(configuration)
    if provider_id == "anthropic" then
        return self.anthropic:new(configuration, transport, stream_transport)
    end
    local variant = self.variants[provider_id]
    if not variant then
        return nil, "Unsupported AI provider: " .. tostring(provider_id)
    end
    return self.compatible:new(configuration, transport, stream_transport, variant)
end

return Registry
