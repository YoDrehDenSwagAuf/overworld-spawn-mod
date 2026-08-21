-- Custom OpenAI-compatible endpoint + optional API key.
local V = ...
local AiConfig = V.require("ai/config")
local Compat = V.require("ai/providers/openai_compatible")
local Transport = V.require("ai/transport")

local Custom = {}
Custom.id = "custom"

function Custom.isConfigured(mod)
  if not Transport.available(mod) and not Transport._mock then
    return false
  end
  local endpoint = AiConfig.endpoint(mod)
  return type(endpoint) == "string" and endpoint:find("^https?://") ~= nil
end

function Custom.startRequest(mod, context, message)
  if not Custom.isConfigured(mod) then
    return nil, "custom endpoint not configured"
  end
  local key = AiConfig.apiKeyForProvider(mod, "custom")
  return Compat.startChat(mod, {
    context = context,
    message = message,
    model = AiConfig.model(mod),
    url = AiConfig.chatUrl(mod),
    apiKey = (key ~= "" and key) or nil,
  })
end

function Custom.poll(mod, handle)
  return Compat.pollChat(mod, handle)
end

function Custom.cancel(mod, handle)
  Compat.cancel(handle)
end

return Custom
