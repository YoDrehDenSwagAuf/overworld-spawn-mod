-- Concise AI subsystem logging. Never logs secrets or full private config.
local V = ...

local AiLog = {}

local function emit(mod, level, fmt, ...)
  if not (mod and mod.log) then return end
  local msg = fmt
  if select("#", ...) > 0 then
    local ok, built = pcall(string.format, fmt, ...)
    msg = ok and built or tostring(fmt)
  end
  -- Scrub accidental secret-looking substrings.
  msg = tostring(msg)
  msg = msg:gsub("[Aa]uthorization:%s*%S+", "Authorization: ***")
  msg = msg:gsub("Bearer%s+%S+", "Bearer ***")
  msg = msg:gsub("sk%-[A-Za-z0-9%-%._]+", "sk-***")
  local line = ("[Wilds][AI] %s"):format(msg)
  if level == "error" and type(mod.log.error) == "function" then
    pcall(mod.log.error, mod.log, "%s", line)
  elseif level == "warn" and type(mod.log.warn) == "function" then
    pcall(mod.log.warn, mod.log, "%s", line)
  elseif type(mod.log.info) == "function" then
    pcall(mod.log.info, mod.log, "%s", line)
  end
end

function AiLog.info(mod, fmt, ...)
  emit(mod, "info", fmt, ...)
end

function AiLog.warn(mod, fmt, ...)
  emit(mod, "warn", fmt, ...)
end

function AiLog.error(mod, fmt, ...)
  emit(mod, "error", fmt, ...)
end

return AiLog
