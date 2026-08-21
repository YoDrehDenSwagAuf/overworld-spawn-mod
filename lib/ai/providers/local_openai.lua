-- Default: local OpenAI-compatible endpoint (LM Studio, etc.).
local V = ...
local AiConfig = V.require("ai/config")
local Compat = V.require("ai/providers/openai_compatible")
local Transport = V.require("ai/transport")

local LocalOpenAI = {}
LocalOpenAI.id = "local"

function LocalOpenAI.isConfigured(mod)
  if not Transport.available(mod) and not Transport._mock then
    return false
  end
  local endpoint = AiConfig.endpoint(mod)
  return type(endpoint) == "string" and endpoint:find("^https?://") ~= nil
end

function LocalOpenAI.startRequest(mod, context, message)
  if not LocalOpenAI.isConfigured(mod) then
    return nil, "local provider not configured"
  end
  local key = AiConfig.apiKeyForProvider(mod, "local")
  return Compat.startChat(mod, {
    context = context,
    message = message,
    model = AiConfig.model(mod),
    url = AiConfig.chatUrl(mod),
    apiKey = (key ~= "" and key) or nil,
  })
end

function LocalOpenAI.poll(mod, handle)
  return Compat.pollChat(mod, handle)
end

function LocalOpenAI.cancel(mod, handle)
  Compat.cancel(handle)
end

return LocalOpenAI
