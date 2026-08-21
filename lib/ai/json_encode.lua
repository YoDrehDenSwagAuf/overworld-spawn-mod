-- Minimal JSON encode for AI request bodies (pairs with lib/json_decode.lua).
local V = ...

local JsonEncode = {}

local function esc(s)
  s = tostring(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  s = s:gsub("\b", "\\b")
  s = s:gsub("\f", "\\f")
  return s
end

local encodeValue

local function encodeArray(t)
  local parts = {}
  for i = 1, #t do
    parts[i] = encodeValue(t[i])
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      return false
    end
    if k > n then n = k end
  end
  return n == #t
end

encodeValue = function(v)
  local tv = type(v)
  if v == nil then return "null" end
  if tv == "boolean" then return v and "true" or "false" end
  if tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return tostring(v)
  end
  if tv == "string" then return '"' .. esc(v) .. '"' end
  if tv == "table" then
    if isArray(v) then return encodeArray(v) end
    local parts = {}
    for k, val in pairs(v) do
      if type(k) == "string" then
        parts[#parts + 1] = '"' .. esc(k) .. '":' .. encodeValue(val)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

function JsonEncode.encode(value)
  return encodeValue(value)
end

return JsonEncode
