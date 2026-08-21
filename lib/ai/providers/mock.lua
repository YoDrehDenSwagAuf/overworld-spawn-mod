-- Deterministic mock provider for CI / DEV helpers.
local V = ...
local Prompt = V.require("ai/prompt")

local Mock = {}
Mock.id = "mock"

function Mock.isConfigured()
  return true
end

function Mock.startRequest(mod, context, message)
  local sys = Prompt.systemPrompt(context)
  local user = Prompt.clampUserText(message)
  local reply
  if sys:find("Reply with exactly: Wilds AI OK", 1, true)
     or (context and context._testExact == "Wilds AI OK") then
    reply = "Wilds AI OK"
  elseif user == "test" and (context and context._devProbe) then
    reply = "Wilds AI OK"
  else
    reply = "Hello, trainer!"
  end
  return {
    mock = true,
    reply = reply,
    pendingTicks = 1,
  }, nil
end

function Mock.poll(mod, handle)
  if not handle then return { status = "error", err = "bad handle" } end
  if (handle.pendingTicks or 0) > 0 then
    handle.pendingTicks = handle.pendingTicks - 1
    return { status = "pending" }
  end
  local text, err = Prompt.sanitizeReply(handle.reply)
  if not text then return { status = "error", err = err } end
  return { status = "success", text = text }
end

function Mock.cancel()
end

return Mock
