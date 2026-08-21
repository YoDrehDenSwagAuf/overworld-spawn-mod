-- Shared OpenAI-compatible chat completions helpers.
local V = ...
local Transport = V.require("ai/transport")
local AiConfig = V.require("ai/config")
local Prompt = V.require("ai/prompt")
local JsonEncode = V.require("ai/json_encode")
local JsonDecode = V.require("json_decode")
local AiLog = V.require("ai/log")

local Compat = {}

local function headerList(headers)
  if type(headers) ~= "table" then return {} end
  if #headers > 0 then return headers end
  local out = {}
  for k, v in pairs(headers) do
    if type(k) == "string" then
      out[#out + 1] = k .. ": " .. tostring(v)
    end
  end
  return out
end

function Compat.buildMessages(context, userMessage)
  local messages = {
    { role = "system", content = Prompt.systemPrompt(context) },
  }
  if type(context) == "table" and type(context.priorTurns) == "table" then
    for _, turn in ipairs(context.priorTurns) do
      local role = turn.role == "assistant" and "assistant" or "user"
      local text = Prompt.clampUserText(turn.text)
      if text ~= "" then
        messages[#messages + 1] = { role = role, content = text }
      end
    end
  end
  messages[#messages + 1] = {
    role = "user",
    content = Prompt.clampUserText(userMessage),
  }
  return messages
end

function Compat.startChat(mod, opts)
  opts = opts or {}
  local url = opts.url or AiConfig.chatUrl(mod)
  local model = opts.model or AiConfig.model(mod)
  local bodyTable = {
    model = model,
    messages = Compat.buildMessages(opts.context, opts.message),
    temperature = opts.temperature or 0.7,
    max_tokens = opts.max_tokens or 120,
  }
  local body = JsonEncode.encode(bodyTable)
  local headers = {
    ["Content-Type"] = "application/json",
    Accept = "application/json",
  }
  if type(opts.apiKey) == "string" and opts.apiKey ~= "" then
    headers["Authorization"] = "Bearer " .. opts.apiKey
  end
  local handle, err = Transport.start(mod, {
    method = "POST",
    url = url,
    headers = headerList(headers),
    body = body,
    maxSeconds = opts.maxSeconds or 25,
  })
  if not handle then
    return nil, err or "transport failed"
  end
  return {
    transport = handle,
    startedAt = os.clock(),
    url = url,
    model = model,
  }, nil
end

local function extractContent(obj)
  if type(obj) ~= "table" then return nil end
  local choices = obj.choices
  if type(choices) == "table" and choices[1] then
    local c = choices[1]
    if type(c.message) == "table" and type(c.message.content) == "string" then
      return c.message.content
    end
    if type(c.text) == "string" then return c.text end
  end
  if type(obj.content) == "string" then return obj.content end
  return nil
end

function Compat.pollChat(mod, handle)
  if not handle or not handle.transport then
    return { status = "error", err = "bad handle" }
  end
  local st = Transport.poll(handle.transport)
  if st.status == "pending" then
    return { status = "pending" }
  end
  if st.status == "cancelled" then
    Transport.release(handle.transport)
    return { status = "error", err = "cancelled" }
  end
  if st.status ~= "ok" then
    local err = st.err or "request failed"
    AiLog.warn(mod, "provider http error: %s", tostring(err))
    Transport.release(handle.transport)
    return { status = "error", err = err }
  end
  local code = tonumber(st.code)
  if code and (code < 200 or code >= 300) then
    Transport.release(handle.transport)
    return { status = "error", err = "http " .. tostring(code) }
  end
  local body = st.body
  Transport.release(handle.transport)
  if type(body) ~= "string" or body == "" then
    return { status = "error", err = "empty body" }
  end
  local obj, decErr = JsonDecode.decode(body)
  if type(obj) ~= "table" then
    return { status = "error", err = "invalid json: " .. tostring(decErr) }
  end
  local content = extractContent(obj)
  local text, sanErr = Prompt.sanitizeReply(content)
  if not text then
    return { status = "error", err = "bad reply: " .. tostring(sanErr) }
  end
  return { status = "success", text = text }
end

function Compat.cancel(handle)
  if handle and handle.transport then
    Transport.cancel(handle.transport)
    Transport.release(handle.transport)
  end
end

return Compat
