-- Luminance-based shading: derive the 3-shade DMG ramp for the mod's
-- follower / wild / submerged sheets at LOAD time, so no separate
-- -grayscale asset files need to ship.
--
-- Derived sheets are cached in-memory (and optionally via ImageData:encode
-- into the LÖVE save namespace using the C encode API — never love.filesystem).
-- See lib/mod_fs.lua.
local V = ...
local WildsFs = V.require("mod_fs")

local LuminanceSheet = {}

local SHADE_LIGHT = 0.8
local SHADE_MID = 0.45
local SHADE_DARK = 0.1
local DEFAULT_LIGHT_FLOOR = 0.5
local MIN_BIN_COVERAGE = 0.02
local MIN_BIN_PIXELS = 3
local BLUE_PENALTY = 0.5

local function shadeValue(r, g, b)
  local luma = 0.299 * r + 0.587 * g + 0.114 * b
  local pen = BLUE_PENALTY * math.max(0, b - math.max(r, g))
  return luma - pen
end

-- Flat save-namespace filenames (no createDirectory / love.filesystem).
local CACHE_PREFIX = "wilds_luma_"

local lumaCache = {}
local siloCache = {}
local submergedCache = {}
local submergedLumaCache = {}

function LuminanceSheet.available()
  return love ~= nil
    and love.image ~= nil
    and type(love.image.newImageData) == "function"
    and love.graphics ~= nil
    and type(love.graphics.newImage) == "function"
end

local ALGO_VERSION = 3
local function cacheFileName(sourcePath)
  local key = tostring(sourcePath):gsub("[^%w%.%-_]", "_")
  if #key > 80 then key = key:sub(#key - 79) end
  return CACHE_PREFIX .. "v" .. ALGO_VERSION .. "_" .. key .. ".png"
end

local function shadeHistogram(id)
  local bins = {}
  local opaque = 0
  id:mapPixel(function(_, _, r, g, b, a)
    if a <= 0 then return r, g, b, a end
    opaque = opaque + 1
    local v = shadeValue(r, g, b)
    local bin = math.floor(v * 20 + 0.5) / 20
    bins[bin] = (bins[bin] or 0) + 1
    return r, g, b, a
  end)
  return bins, opaque
end

local function realLevels(bins, opaque)
  local out = {}
  local threshold = math.max(MIN_BIN_PIXELS, opaque * MIN_BIN_COVERAGE)
  for bin, count in pairs(bins) do
    if count >= threshold then out[#out + 1] = bin end
  end
  table.sort(out, function(a, b) return a > b end)
  return out
end

local function lightFloorFor(levels)
  local l1 = levels[1]
  if not l1 or l1 <= DEFAULT_LIGHT_FLOOR then return DEFAULT_LIGHT_FLOOR end
  local l2 = levels[2]
  if not l2 or l2 < DEFAULT_LIGHT_FLOOR then return DEFAULT_LIGHT_FLOOR end
  if l1 - l2 < 0.08 then return DEFAULT_LIGHT_FLOOR end
  return (l1 + l2) / 2
end

local function shadeFor(luma, lightFloor)
  if luma > lightFloor then return SHADE_LIGHT end
  if luma > 0.17 then return SHADE_MID end
  return SHADE_DARK
end

--- Load source ImageData from a virtual path (mods/... or derived).
local function loadSourceImageData(path)
  if WildsFs.getDerivedImage(path) then
    -- Prefer re-decoding from path after encode; else clone via getData.
    local img = WildsFs.getDerivedImage(path)
    if img and type(img.getData) == "function" then
      local ok, data = pcall(img.getData, img)
      if ok and data then return data end
    end
  end
  local ok, id = pcall(love.image.newImageData, path)
  if ok and id then return id end
  return nil
end

--- Commit derived ImageData under `out` (memory + optional disk encode).
local function commitDerived(out, idata)
  -- Memory registration is the primary cache (fast, sandbox-safe).
  local okMem = WildsFs.registerFromImageData(out, idata)
  -- Best-effort durable encode via C API (no love.filesystem). Flat name.
  pcall(WildsFs.encodePngToPath, idata, out)
  return okMem == true or WildsFs.pathExists(out)
end

local function cacheHit(out)
  if WildsFs.getDerivedImage(out) then return true end
  return WildsFs.pathExists(out)
end

--- Derive (once) an engine-safe luminance copy of `coloredPath`.
function LuminanceSheet.pathFor(coloredPath)
  if type(coloredPath) ~= "string" or coloredPath == "" then return nil end
  if not LuminanceSheet.available() then return nil end
  if lumaCache[coloredPath] then return lumaCache[coloredPath] end

  local ok, result = pcall(function()
    local out = cacheFileName(coloredPath)
    if cacheHit(out) then return out end
    local id = loadSourceImageData(coloredPath)
    if not id then return nil end
    local bins, opaque = shadeHistogram(id)
    local levels = realLevels(bins, opaque)
    local lightFloor = lightFloorFor(levels)
    id:mapPixel(function(_, _, r, g, b, a)
      if a <= 0 then return r, g, b, a end
      local v = shadeValue(r, g, b)
      local s = shadeFor(v, lightFloor)
      return s, s, s, a
    end)
    if not commitDerived(out, id) then return nil end
    return out
  end)

  if not ok or type(result) ~= "string" or result == "" then
    return nil
  end
  lumaCache[coloredPath] = result
  return result
end

local SILO_ALGO_VERSION = 1
local function siloCacheFileName(sourcePath)
  local key = tostring(sourcePath):gsub("[^%w%.%-_]", "_")
  if #key > 80 then key = key:sub(#key - 79) end
  return CACHE_PREFIX .. "silo_v" .. SILO_ALGO_VERSION .. "_" .. key .. ".png"
end

function LuminanceSheet.silhouetteFor(coloredPath)
  if type(coloredPath) ~= "string" or coloredPath == "" then return nil end
  if not LuminanceSheet.available() then return nil end
  if siloCache[coloredPath] then return siloCache[coloredPath] end

  local ok, result = pcall(function()
    local out = siloCacheFileName(coloredPath)
    if cacheHit(out) then return out end
    local id = loadSourceImageData(coloredPath)
    if not id then return nil end
    id:mapPixel(function(_, _, r, g, b, a)
      if a <= 0 then return r, g, b, a end
      return SHADE_DARK, SHADE_DARK, SHADE_DARK, a
    end)
    if not commitDerived(out, id) then return nil end
    return out
  end)

  if not ok or type(result) ~= "string" or result == "" then
    return nil
  end
  siloCache[coloredPath] = result
  return result
end

local SUBMERGED_ALGO_VERSION = 15
local function submergedCacheFileName(sourcePath)
  local key = tostring(sourcePath):gsub("[^%w%.%-_]", "_")
  if #key > 80 then key = key:sub(#key - 79) end
  return CACHE_PREFIX .. "sub_v" .. SUBMERGED_ALGO_VERSION .. "_" .. key .. ".png"
end

local WATERLINE_FRAC = 0.88
local WAVE_AMP = 1
local FOAM_R, FOAM_G, FOAM_B = 0.90, 0.94, 1.0
local WATER_R, WATER_G, WATER_B = 0.30, 0.55, 0.85

function LuminanceSheet.submergedFor(coloredPath)
  if type(coloredPath) ~= "string" or coloredPath == "" then return nil end
  if not LuminanceSheet.available() then return nil end
  if submergedCache[coloredPath] then return submergedCache[coloredPath] end

  local ok, result = pcall(function()
    local out = submergedCacheFileName(coloredPath)
    if cacheHit(out) then return out end
    local id = loadSourceImageData(coloredPath)
    if not id then return nil end
    local iw, ih = id:getWidth(), id:getHeight()
    local frameWidth = iw
    local frameHeight = math.floor(ih / 6)
    local baseWl = math.max(2, math.min(frameHeight - 2,
      math.floor(frameHeight * WATERLINE_FRAC + 0.5)))
    id:mapPixel(function(x, y, r, g, b, a)
      if a <= 0 then return r, g, b, a end
      local yInFrame = y % frameHeight
      local wave = math.sin((x / math.max(1, frameWidth - 1)) * math.pi * 2)
      local wl = math.max(2, math.min(frameHeight - 2,
        baseWl + math.floor(WAVE_AMP * wave + 0.5)))
      if yInFrame > wl then
        return r, g, b, 0
      end
      if yInFrame == wl - 1 then
        return FOAM_R, FOAM_G, FOAM_B, a
      end
      if yInFrame == wl then
        return WATER_R, WATER_G, WATER_B, a
      end
      return r, g, b, a
    end)
    if not commitDerived(out, id) then return nil end
    return out
  end)

  if not ok or type(result) ~= "string" or result == "" then
    return nil
  end
  submergedCache[coloredPath] = result
  return result
end

local SUBMERGED_LUMA_VERSION = 1
local function submergedLumaCacheFileName(sourcePath)
  local key = tostring(sourcePath):gsub("[^%w%.%-_]", "_")
  if #key > 80 then key = key:sub(#key - 79) end
  return CACHE_PREFIX .. "subluma_v" .. SUBMERGED_LUMA_VERSION .. "_" .. key .. ".png"
end

local FOAM_LUMA = 0.8
local WATER_LUMA = 0.45

function LuminanceSheet.submergedFromLuma(lumaPath)
  if type(lumaPath) ~= "string" or lumaPath == "" then return nil end
  if not LuminanceSheet.available() then return nil end
  if submergedLumaCache[lumaPath] then return submergedLumaCache[lumaPath] end

  local ok, result = pcall(function()
    local out = submergedLumaCacheFileName(lumaPath)
    if cacheHit(out) then return out end
    local id = loadSourceImageData(lumaPath)
    if not id then return nil end
    local iw, ih = id:getWidth(), id:getHeight()
    local frameWidth = iw
    local frameHeight = math.floor(ih / 6)
    local baseWl = math.max(2, math.min(frameHeight - 2,
      math.floor(frameHeight * WATERLINE_FRAC + 0.5)))
    id:mapPixel(function(x, y, r, g, b, a)
      if a <= 0 then return r, g, b, a end
      local yInFrame = y % frameHeight
      local wave = math.sin((x / math.max(1, frameWidth - 1)) * math.pi * 2)
      local wl = math.max(2, math.min(frameHeight - 2,
        baseWl + math.floor(WAVE_AMP * wave + 0.5)))
      if yInFrame > wl then
        return r, g, b, 0
      end
      if yInFrame == wl - 1 then
        return FOAM_LUMA, FOAM_LUMA, FOAM_LUMA, a
      end
      if yInFrame == wl then
        return WATER_LUMA, WATER_LUMA, WATER_LUMA, a
      end
      return r, g, b, a
    end)
    if not commitDerived(out, id) then return nil end
    return out
  end)

  if not ok or type(result) ~= "string" or result == "" then
    return nil
  end
  submergedLumaCache[lumaPath] = result
  return result
end

return LuminanceSheet
