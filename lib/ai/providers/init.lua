-- Provider registry.
local V = ...
local AiConfig = V.require("ai/config")

local Providers = {}

local function load(name)
  return V.require("ai/providers/" .. name)
end

function Providers.resolve(mod, overrideId)
  local id = overrideId or AiConfig.providerId(mod)
  if id == "openai" then return load("openai") end
  if id == "custom" then return load("custom") end
  if id == "mock" then return load("mock") end
  return load("local_openai")
end

function Providers.isReady(mod)
  local p = Providers.resolve(mod)
  local ok, ready = pcall(function() return p.isConfigured(mod) end)
  return ok and ready == true
end

return Providers
