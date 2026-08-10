-- Luminance-based shading: derive the 3-shade DMG ramp for the mod's
-- follower / wild / submerged sheets at LOAD time, so no separate
-- -grayscale asset files need to ship.
--
-- The engine's shade/zone pass colorizes a sprite out of the active COLORS
-- mode's palette by keying on the art's RED channel (r > 0.83 → c0,
-- > 0.5 → c1, > 0.17 → c2, else c3), after SpriteRenderer bakes rOBP0 = $D0
-- (which also keys every pixel with r > 0.83 TRANSPARENT).  Full-color art
-- has an arbitrary red channel, so it cannot go through that path.  This
-- module converts each colored sheet into the luminance ramp the engine
-- expects — r = g = b = one of shades chosen by pixel brightness — with
-- the lightest shade clamped under 0.83 so no interior pixel ever punches
-- through.  The result is cached as a PNG in love.filesystem's save
-- directory (one file per source sheet, regenerated only when missing), and
-- callers serve the cache path exactly like a normal asset.  The zone pass
-- then colors it per mode (SGB map tints, OG RED/BLUE object greens/pinks,
-- OG YELLOW CGB zones, CLASSIC/OG/OG INV ramps, SGB INV permuted).
--
-- Shade assignment is per-sheet adaptive, not a fixed ladder: the OBP0 bake
-- collapses EVERYTHING above r = 0.5 into a single zone (c0), so a fixed
-- light bucket turns light mons into one flat white blob (Snorlax's cream
-- ~0.79 and body ~0.52 both became c0).  For each sheet the lightest
-- high-coverage color keeps c0 and a second, distinctly darker light color
-- is pulled down to c1 so the mon keeps its tonal separation.
--
-- Luminance alone cannot separate colors of DIFFERENT HUE at the same
-- brightness (Blastoise's light-blue shell ~0.63 vs cream belly ~0.66
-- collapse to the same zone).  The shade metric therefore darkens
-- blue-dominant pixels: saturated blue reads as a mid shade while a
-- same-brightness warm/neutral color keeps the light zone, matching how
-- the GSC art renders blue shells against cream bodies.
--
-- Headless / no-LÖVE environments fall back to the original colored path
-- (callers then keep trueColor = true); derivation is a rendering nicety.
local V = ...

local LuminanceSheet = {}

-- Engine-safe shade ramp.  After the OBP0 bake these land on:
--   0.8  → bake white → zone c0 (lightest)
--   0.45 → bake 170   → zone c1 (mid)
--   0.1  → bake black → zone c3 (darkest)
-- Lightest must stay < 0.83 (the bake's transparency key) and > 0.5.
local SHADE_LIGHT = 0.8
local SHADE_MID = 0.45
local SHADE_DARK = 0.1

-- The bake maps any r > 0.5 to the same zone, so the light bucket is
-- split by rank: lightest color → c0, a second light color → c1.  This
-- floor decides where that split happens; default 0.5 (single light
-- bucket) unless the sheet has two clearly separated light colors.
local DEFAULT_LIGHT_FLOOR = 0.5

-- Luma bins are 0.05 wide; a bin is a "real" color when it covers at
-- least this share of the opaque pixels (AA and dither noise stay below).
local MIN_BIN_COVERAGE = 0.02
local MIN_BIN_PIXELS = 3

-- Hue-aware shade value: Rec. 601 luma minus a penalty for blue-dominant
-- pixels (b clearly above the max of r/g).  Breaks the luma tie between
-- same-brightness blue shells and cream/warm bodies (Blastoise, Squirtle,
-- Lapras ...) so the two land in different zones.
local BLUE_PENALTY = 0.5
local function shadeValue(r, g, b)
  local luma = 0.299 * r + 0.587 * g + 0.114 * b
  local pen = BLUE_PENALTY * math.max(0, b - math.max(r, g))
  return luma - pen
end

-- Cache dir name inside the save directory.
local CACHE_DIR = "wilds_luma"

-- source path → derived runtime path (stable across calls).  Two
-- namespaces: luma ramps (pathFor) and silhouettes (silhouetteFor) — the
-- same colored sheet can legitimately be served both ways in one session
-- (a wild mon silhouetted while its follower twin uses the luma ramp).
local lumaCache = {}
local siloCache = {}

function LuminanceSheet.available()
  return love and love.image and love.image.newImageData
    and love.graphics and love.graphics.newImage
    and love.filesystem and love.filesystem.getInfo
    and love.filesystem.createDirectory
end

-- Derived PNG filename for a source path: sanitized, truncated (absolute
-- mod paths can be long; the tail carries the disambiguating suffix).
-- The version tag forces regeneration when the derivation algorithm
-- changes (older cached ramps are stale).
local ALGO_VERSION = 3
local function cacheFileName(sourcePath)
  local key = tostring(sourcePath):gsub("[^%w%.%-_]", "_")
  if #key > 80 then key = key:sub(#key - 79) end
  return "luma_v" .. ALGO_VERSION .. "_" .. key .. ".png"
end

-- Coverage-weighted shade histogram of the opaque pixels (blue-penalized
-- luma, see shadeValue).
local function shadeHistogram(id)
  local bins = {}
  local opaque = 0
  id:mapPixel(function(_, _, r, g, b, a)
    if a <= 0 then return r, g, b, a end
    opaque = opaque + 1
    local v = shadeValue(r, g, b)
    local bin = math.floor(v * 20 + 0.5) / 20 -- 0.05 buckets
    bins[bin] = (bins[bin] or 0) + 1
    return r, g, b, a
  end)
  return bins, opaque
end

-- Real (high-coverage) luma levels, sorted descending.
local function realLevels(bins, opaque)
  local out = {}
  local threshold = math.max(MIN_BIN_PIXELS, opaque * MIN_BIN_COVERAGE)
  for bin, count in pairs(bins) do
    if count >= threshold then out[#out + 1] = bin end
  end
  table.sort(out, function(a, b) return a > b end)
  return out
end

-- Per-sheet light-zone floor: split the light bucket only when the sheet
-- has two clearly separated light colors (e.g. Snorlax cream vs body);
-- otherwise keep the standard 0.5 floor so nothing light goes dark.
local function lightFloorFor(levels)
  local l1 = levels[1]
  if not l1 or l1 <= DEFAULT_LIGHT_FLOOR then return DEFAULT_LIGHT_FLOOR end
  local l2 = levels[2]
  -- The 0.5 bin holds luma in [0.475, 0.525], i.e. genuinely light colors
  -- (Snorlax's body sits at ~0.52 and must be pulled off the light shade).
  if not l2 or l2 < DEFAULT_LIGHT_FLOOR then return DEFAULT_LIGHT_FLOOR end
  if l1 - l2 < 0.08 then return DEFAULT_LIGHT_FLOOR end
  return (l1 + l2) / 2
end

local function shadeFor(luma, lightFloor)
  if luma > lightFloor then return SHADE_LIGHT end
  if luma > 0.17 then return SHADE_MID end
  return SHADE_DARK
end

--- Derive (once) an engine-safe luminance copy of `coloredPath` in the save
--- dir and return its runtime path.  Returns nil when derivation is
--- unavailable or fails — the caller then keeps the colored path.
function LuminanceSheet.pathFor(coloredPath)
  if type(coloredPath) ~= "string" or coloredPath == "" then return nil end
  if not LuminanceSheet.available() then return nil end
  if lumaCache[coloredPath] then return lumaCache[coloredPath] end

  local ok, result = pcall(function()
    if not love.filesystem.getInfo(CACHE_DIR) then
      love.filesystem.createDirectory(CACHE_DIR)
    end
    local out = CACHE_DIR .. "/" .. cacheFileName(coloredPath)
    if not love.filesystem.getInfo(out) then
      local id = love.image.newImageData(coloredPath)
      local bins, opaque = shadeHistogram(id)
      local levels = realLevels(bins, opaque)
      local lightFloor = lightFloorFor(levels)
      id:mapPixel(function(_, _, r, g, b, a)
        if a <= 0 then return r, g, b, a end
        local v = shadeValue(r, g, b)
        local s = shadeFor(v, lightFloor)
        return s, s, s, a
      end)
      id:encode("png", out)
    end
    return out
  end)

  if not ok or type(result) ~= "string" or result == "" then
    return nil
  end
  lumaCache[coloredPath] = result
  return result
end

-- Silhouette derivation: every opaque pixel becomes the darkest shade so the
-- engine's OBP0 bake maps the whole sheet to the darkest zone color — a
-- solid black-out that keeps the sprite's shape (alpha still carries the
-- outline).  Same save-dir cache as pathFor, in its own silo_vN namespace so
-- silhouette files never collide with (or overwrite) the luma ramps.
local SILO_ALGO_VERSION = 1
local function siloCacheFileName(sourcePath)
  local key = tostring(sourcePath):gsub("[^%w%.%-_]", "_")
  if #key > 80 then key = key:sub(#key - 79) end
  return "silo_v" .. SILO_ALGO_VERSION .. "_" .. key .. ".png"
end

function LuminanceSheet.silhouetteFor(coloredPath)
  if type(coloredPath) ~= "string" or coloredPath == "" then return nil end
  if not LuminanceSheet.available() then return nil end
  if siloCache[coloredPath] then return siloCache[coloredPath] end

  local ok, result = pcall(function()
    if not love.filesystem.getInfo(CACHE_DIR) then
      love.filesystem.createDirectory(CACHE_DIR)
    end
    local out = CACHE_DIR .. "/" .. siloCacheFileName(coloredPath)
    if not love.filesystem.getInfo(out) then
      local id = love.image.newImageData(coloredPath)
      id:mapPixel(function(_, _, r, g, b, a)
        if a <= 0 then return r, g, b, a end
        return SHADE_DARK, SHADE_DARK, SHADE_DARK, a
      end)
      id:encode("png", out)
    end
    return out
  end)

  if not ok or type(result) ~= "string" or result == "" then
    return nil
  end
  siloCache[coloredPath] = result
  return result
end

return LuminanceSheet
