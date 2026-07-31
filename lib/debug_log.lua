-- Structured, rate-limited debug logging for Wilds of Kanto.
-- Format: [WildsOfKanto][LEVEL] message
--
-- Never logs every frame: callers should log on state transitions or use
-- onceKey / throttle helpers.
local V = ...
local Config = V.require("config")

local DebugLog = {}
DebugLog._last = {}
DebugLog._throttleAt = {}

local function emit(mod, level, fmt, ...)
  local msg = fmt
  if select("#", ...) > 0 then
    msg = string.format(fmt, ...)
  end
  local line = ("[WildsOfKanto][%s] %s"):format(level, msg)
  if level == "ERROR" then
    mod.log:error("%s", line)
  elseif level == "WARN" then
    mod.log:warn("%s", line)
  else
    mod.log:info("%s", line)
  end
end

function DebugLog.enabled(mod)
  return Config.debug(mod)
end

function DebugLog.info(mod, fmt, ...)
  if not DebugLog.enabled(mod) then return end
  emit(mod, "INFO", fmt, ...)
end

function DebugLog.debug(mod, fmt, ...)
  if not DebugLog.enabled(mod) then return end
  emit(mod, "DEBUG", fmt, ...)
end

function DebugLog.warn(mod, fmt, ...)
  -- Warnings always surface; still tagged for grep.
  emit(mod, "WARN", fmt, ...)
end

function DebugLog.error(mod, fmt, ...)
  emit(mod, "ERROR", fmt, ...)
end

-- Log only when the value for key changes.
function DebugLog.onceKey(mod, key, level, fmt, ...)
  local msg = fmt
  if select("#", ...) > 0 then
    msg = string.format(fmt, ...)
  end
  if DebugLog._last[key] == msg then return false end
  DebugLog._last[key] = msg
  if level == "ERROR" then
    DebugLog.error(mod, "%s", msg)
  elseif level == "WARN" then
    DebugLog.warn(mod, "%s", msg)
  elseif level == "DEBUG" then
    DebugLog.debug(mod, "%s", msg)
  else
    DebugLog.info(mod, "%s", msg)
  end
  return true
end

-- Throttle identical keys to at most once per `seconds` (wall clock via love.timer
-- when available, else os.clock).
function DebugLog.throttle(mod, key, seconds, level, fmt, ...)
  local now = 0
  if love and love.timer and love.timer.getTime then
    now = love.timer.getTime()
  else
    now = os.clock()
  end
  local prev = DebugLog._throttleAt[key] or 0
  if now - prev < (seconds or 2) then return false end
  DebugLog._throttleAt[key] = now
  local msg = fmt
  if select("#", ...) > 0 then
    msg = string.format(fmt, ...)
  end
  if level == "ERROR" then
    DebugLog.error(mod, "%s", msg)
  elseif level == "WARN" then
    DebugLog.warn(mod, "%s", msg)
  elseif level == "DEBUG" then
    DebugLog.debug(mod, "%s", msg)
  else
    DebugLog.info(mod, "%s", msg)
  end
  return true
end

function DebugLog.reset()
  DebugLog._last = {}
  DebugLog._throttleAt = {}
end

return DebugLog
