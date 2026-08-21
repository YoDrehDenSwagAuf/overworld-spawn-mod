-- Official OpenAI provider (user-supplied API key; never shipped).
local V = ...
local AiConfig = V.require("ai/config")
local Compat = V.require("ai/providers/openai_compatible")
local Transport = V.require("ai/transport")

local OpenAI = {}
OpenAI.id = "openai"
OpenAI.DEFAULT_URL = "https://api.openai.com/v1/chat/completions"

function OpenAI.isConfigured(mod)
  if not Transport.available(mod) and not Transport._mock then
    return false
  end
  local key = AiConfig.apiKeyForProvider(mod, "openai")
  return type(key) == "string" and key ~= ""
end

function OpenAI.startRequest(mod, context, message)
  if not OpenAI.isConfigured(mod) then
    return nil, "openai api key missing"
  end
  local model = AiConfig.model(mod)
  if model == "local" or model == "" then
    model = "gpt-4o-mini"
  end
  return Compat.startChat(mod, {
    context = context,
    message = message,
    model = model,
    url = OpenAI.DEFAULT_URL,
    apiKey = AiConfig.apiKeyForProvider(mod, "openai"),
  })
end

function OpenAI.poll(mod, handle)
  return Compat.pollChat(mod, handle)
end

function OpenAI.cancel(mod, handle)
  Compat.cancel(handle)
end

return OpenAI
