-- Minimal JSON decoder for animated overworld mapping files.
local V = ...

local JsonDecode = {}

local function fail(msg, i)
  return nil, string.format("%s at %d", tostring(msg), tonumber(i) or 0)
end

local parseValue

local function skipWs(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return (j or (i - 1)) + 1
end

local function parseString(s, i)
  if s:sub(i, i) ~= '"' then return fail("expected string", i) end
  i = i + 1
  local out = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local n = s:sub(i + 1, i + 1)
      local map = {
        ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
        b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
      }
      if map[n] then
        out[#out + 1] = map[n]
        i = i + 2
      elseif n == "u" then
        local hex = s:sub(i + 2, i + 5)
        local code = tonumber(hex, 16)
        if not code then return fail("bad unicode escape", i) end
        if code < 128 then
          out[#out + 1] = string.char(code)
        elseif code < 0x800 then
          out[#out + 1] = string.char(0xC0 + math.floor(code / 64),
                                      0x80 + (code % 64))
        else
          out[#out + 1] = string.char(0xE0 + math.floor(code / 4096),
                                      0x80 + (math.floor(code / 64) % 64),
                                      0x80 + (code % 64))
        end
        i = i + 6
      else
        return fail("bad escape", i)
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return fail("unterminated string", i)
end

local function parseArray(s, i)
  if s:sub(i, i) ~= "[" then return fail("expected [", i) end
  i = skipWs(s, i + 1)
  local arr = {}
  if s:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    local v, nextI = parseValue(s, i)
    if type(nextI) ~= "number" then return nil, v end
    arr[#arr + 1] = v
    i = skipWs(s, nextI)
    local c = s:sub(i, i)
    if c == "]" then return arr, i + 1 end
    if c ~= "," then return fail("expected , or ]", i) end
    i = skipWs(s, i + 1)
  end
end

local function parseObject(s, i)
  if s:sub(i, i) ~= "{" then return fail("expected {", i) end
  i = skipWs(s, i + 1)
  local obj = {}
  if s:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    local key, nextI = parseString(s, i)
    if type(nextI) ~= "number" then return nil, key end
    i = skipWs(s, nextI)
    if s:sub(i, i) ~= ":" then return fail("expected :", i) end
    i = skipWs(s, i + 1)
    local val
    val, nextI = parseValue(s, i)
    if type(nextI) ~= "number" then return nil, val end
    obj[key] = val
    i = skipWs(s, nextI)
    local c = s:sub(i, i)
    if c == "}" then return obj, i + 1 end
    if c ~= "," then return fail("expected , or }", i) end
    i = skipWs(s, i + 1)
  end
end

parseValue = function(s, i)
  i = skipWs(s, i)
  local c = s:sub(i, i)
  if c == '"' then
    return parseString(s, i)
  elseif c == "{" then
    return parseObject(s, i)
  elseif c == "[" then
    return parseArray(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  elseif c == "-" or c:match("%d") then
    local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    if not num then return fail("bad number", i) end
    return tonumber(num), i + #num
  end
  return fail("unexpected token", i)
end

function JsonDecode.decode(text)
  if type(text) ~= "string" then
    return nil, "json text must be a string"
  end
  local value, nextOrErr = parseValue(text, 1)
  if type(nextOrErr) ~= "number" then
    return nil, tostring(value or nextOrErr or "decode failed")
  end
  return value
end

return JsonDecode
