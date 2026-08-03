-- Resolve pre-built Gen1Recomp SpriteRenderer sheets for follow-sprites.
-- Sheets live under assets/generated/followsprites_runtime/ (build-time).
-- Frame order matches SpriteRenderer.STAND / SpriteRenderer.WALK (verified).
local V = ...
local JsonDecode = V.require("json_decode")

local RuntimeSheets = {}
RuntimeSheets.__index = RuntimeSheets

RuntimeSheets.DIR_REL = "assets/generated/followsprites_runtime"
RuntimeSheets.MANIFEST_REL = RuntimeSheets.DIR_REL .. "/manifest.json"
RuntimeSheets.FRAMES = 6
RuntimeSheets.WALKER = true
RuntimeSheets.SHEET_W = 16
RuntimeSheets.SHEET_H = 96

-- Verified against Gen1Recomp src/render/SpriteRenderer.lua:
--   STAND = { down = 0, up = 1, left = 2, right = 2 }
--   WALK  = { down = 3, up = 4, left = 5, right = 5 }
RuntimeSheets.STAND = { down = 0, up = 1, left = 2, right = 2 }
RuntimeSheets.WALK = { down = 3, up = 4, left = 5, right = 5 }

function RuntimeSheets.sheetFileName(speciesId, variant)
  local n = tonumber(speciesId)
  if not n or n < 1 then return nil end
  local v = (variant == "shiny" or variant == "s" or variant == true) and "shiny" or "normal"
  return string.format("%03d-%s.png", math.floor(n), v)
end

function RuntimeSheets.sheetRelPath(speciesId, variant)
  local name = RuntimeSheets.sheetFileName(speciesId, variant)
  if not name then return nil end
  return RuntimeSheets.DIR_REL .. "/" .. name
end

local function fsExists(path)
  if type(path) ~= "string" or path == "" then return false end
  local fs = love and love.filesystem
  if fs and fs.getInfo then
    local ok, info = pcall(fs.getInfo, path)
    if ok and info then return true end
  end
  -- Headless / unit tests: fall back to mod.read or io.
  if V.mod and type(V.mod.read) == "function" then
    local data = V.mod.read(V.mod, path)
    if data ~= nil then return true end
  end
  local f = io.open(path, "rb")
  if f then f:close() return true end
  if V.path then
    local f2 = io.open((V.path or ".") .. "/" .. path, "rb")
    if f2 then f2:close() return true end
  end
  return false
end

function RuntimeSheets.new(mod)
  local self = setmetatable({}, RuntimeSheets)
  self.mod = mod
  self.manifest = nil
  self.ready = false
  self.sheetCount = 0
  self.loadError = nil
  return self
end

function RuntimeSheets:load()
  self.manifest = nil
  self.ready = false
  self.sheetCount = 0
  self.loadError = nil

  local raw = nil
  if self.mod and type(self.mod.read) == "function" then
    raw = self.mod.read(self.mod, RuntimeSheets.MANIFEST_REL)
  end
  if raw == nil then
    local path = RuntimeSheets.MANIFEST_REL
    local f = io.open(path, "rb")
    if not f and V.path then
      f = io.open((V.path or ".") .. "/" .. path, "rb")
    end
    if f then
      raw = f:read("*a")
      f:close()
    end
  end
  if type(raw) ~= "string" or raw == "" then
    self.loadError = "runtime sheet manifest missing"
    return false, self.loadError
  end
  local ok, data = pcall(JsonDecode.decode, raw)
  if not ok or type(data) ~= "table" then
    self.loadError = "runtime sheet manifest invalid JSON"
    return false, self.loadError
  end
  self.manifest = data
  local sheets = data.sheets or {}
  local n = 0
  for _ in pairs(sheets) do n = n + 1 end
  self.sheetCount = n
  self.ready = n > 0
  return self.ready, nil
end

function RuntimeSheets:isReady()
  return self.ready == true
end

function RuntimeSheets:hasSheet(speciesId, variant)
  local path = self:resolvePath(speciesId, variant)
  return path ~= nil
end

-- Resolve preferred variant, then normal. Returns mod-relative path or nil.
function RuntimeSheets:resolvePath(speciesId, variant)
  local n = tonumber(speciesId)
  if not n or n < 1 then return nil end
  n = math.floor(n)
  local wantShiny = (variant == "shiny" or variant == "s" or variant == true)
  local order = wantShiny and { "shiny", "normal" } or { "normal" }
  for _, v in ipairs(order) do
    local rel = RuntimeSheets.sheetRelPath(n, v)
    if rel and fsExists(rel) then
      return rel, v
    end
    -- Manifest may list a path even if getInfo is stubbed in tests.
    if self.manifest and self.manifest.sheets then
      local entry = self.manifest.sheets[tostring(n) .. ":" .. v]
      if entry and type(entry.path) == "string" and entry.path ~= "" then
        if fsExists(entry.path) then
          return entry.path, v
        end
      end
    end
  end
  return nil, nil
end

function RuntimeSheets:spriteDef(speciesId, variant, spriteId)
  local path, usedVariant = self:resolvePath(speciesId, variant)
  if not path then return nil end
  return {
    image = path,
    frames = RuntimeSheets.FRAMES,
    walker = true,
    trueColor = true,
    id = spriteId or ("SPRITE_OW_WILD_RT_" .. tostring(speciesId)),
  }, usedVariant, path
end

function RuntimeSheets:summary()
  return {
    ready = self.ready,
    sheetCount = self.sheetCount,
    dir = RuntimeSheets.DIR_REL,
    frames = RuntimeSheets.FRAMES,
    walker = RuntimeSheets.WALKER,
    loadError = self.loadError,
    rightFacing = self.manifest and self.manifest.rightFacing or "mirror_left",
  }
end

return RuntimeSheets
