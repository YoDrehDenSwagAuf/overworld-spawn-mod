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
-- through.  The result is transformed once in memory and persisted through
-- the Love ImageData:encode API as a SpriteRenderer save-dir path (not
-- the blocked sandbox filesystem module, and not playthrough storage).
-- Callers serve that path exactly like a normal asset.  The zone pass
-- then colors it per mode
-- (SGB map tints, OG RED/BLUE object greens/pinks, OG YELLOW CGB zones,
-- CLASSIC/OG/OG INV ramps, SGB INV permuted).
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
local WildsFs = V.require("wilds_fs")

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

-- Save-directory prefix for derived PNGs (ImageData:encode, not a FS API).
local CACHE_PREFIX = "wilds_luma_"

-- source path → derived runtime path (stable across calls).  Two
-- namespaces: luma ramps (pathFor) and silhouettes (silhouetteFor) — the
-- same colored sheet can legitimately be served both ways in one session
-- (a wild mon silhouetted while its follower twin uses the luma ramp).
local lumaCache = {}
local siloCache = {}

function LuminanceSheet.available()
  return love and love.image and love.image.newImageData
    and love.graphics and love.graphics.newImage
end

local function deriveAndPersist(sourcePath, fileName, mapFn)
  local id = love.image.newImageData(sourcePath)
  mapFn(id)
  local out = CACHE_PREFIX .. fileName
  return WildsFs.persistImageData(id, out)
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

--- Derive (once) an engine-safe luminance copy of `coloredPath` and return
--- its runtime path.  Returns nil when derivation is unavailable or fails
--- — the caller then keeps the colored path.
function LuminanceSheet.pathFor(coloredPath)
  if type(coloredPath) ~= "string" or coloredPath == "" then return nil end
  if not LuminanceSheet.available() then return nil end
  if lumaCache[coloredPath] then return lumaCache[coloredPath] end

  local ok, result = pcall(function()
    return deriveAndPersist(coloredPath, cacheFileName(coloredPath), function(id)
      local bins, opaque = shadeHistogram(id)
      local levels = realLevels(bins, opaque)
      local lightFloor = lightFloorFor(levels)
      id:mapPixel(function(_, _, r, g, b, a)
        if a <= 0 then return r, g, b, a end
        local v = shadeValue(r, g, b)
        local s = shadeFor(v, lightFloor)
        return s, s, s, a
      end)
    end)
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
-- outline).  Same derived-path cache as pathFor, in its own silo_vN
-- namespace so silhouette files never collide with the luma ramps.
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
    return deriveAndPersist(coloredPath, siloCacheFileName(coloredPath), function(id)
      id:mapPixel(function(_, _, r, g, b, a)
        if a <= 0 then return r, g, b, a end
        return SHADE_DARK, SHADE_DARK, SHADE_DARK, a
      end)
    end)
  end)

  if not ok or type(result) ~= "string" or result == "" then
    return nil
  end
  siloCache[coloredPath] = result
  return result
end

-- Submerged derivation: keep original colours unchanged — the sprite
-- stays fully coloured.  Only the lower portion of each frame is made
-- transparent below a flat horizontal waterline, giving the illusion of
-- the Pokémon wading / swimming half-submerged (like the surf sprite).
-- The waterline height bobs up and down across the 6 animation frames
-- in a staggered pattern (~12 px total range on a 16 px classic frame)
-- so the sprite appears to rise and sink as it animates.  The waterline
-- is horizontal — the same height for every column in a frame — so the
-- submerged region is a clean horizontal band.  No pre-made
-- _submerged.png files needed.  Same derived-path cache as the others.
local SUBMERGED_ALGO_VERSION = 15 -- v15: foam + blue water line, moved up 1px
local function submergedCacheFileName(sourcePath)
  local key = tostring(sourcePath):gsub("[^%w%.%-_]", "_")
  if #key > 80 then key = key:sub(#key - 79) end
  return "submerged_v" .. SUBMERGED_ALGO_VERSION .. "_" .. key .. ".png"
end

local submergedCache = {}

-- Waterline is a subtle sine wave (surf-sprite style) with a small
-- ±1 px amplitude — barely noticeable, just enough to avoid looking
-- like a sterile straight line.
local WATERLINE_FRAC = 0.88  -- only bottom ~2 rows hidden
local WAVE_AMP = 1           -- ±1 px, very subtle

-- Surf-style water surface: white foam crest + blue water line.
local FOAM_R = 0.90
local FOAM_G = 0.94
local FOAM_B = 1.0
local WATER_R = 0.30
local WATER_G = 0.55
local WATER_B = 0.85

function LuminanceSheet.submergedFor(coloredPath)
  if type(coloredPath) ~= "string" or coloredPath == "" then return nil end
  if not LuminanceSheet.available() then return nil end
  if submergedCache[coloredPath] then return submergedCache[coloredPath] end

  local ok, result = pcall(function()
    return deriveAndPersist(coloredPath, submergedCacheFileName(coloredPath), function(id)
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
          return r, g, b, 0   -- below water → hidden
        end
        if yInFrame == wl - 1 then
          return FOAM_R, FOAM_G, FOAM_B, a  -- white foam crest
        end
        if yInFrame == wl then
          return WATER_R, WATER_G, WATER_B, a  -- blue water line
        end
        return r, g, b, a     -- above water → original colour
      end)
    end)
  end)

  if not ok or type(result) ~= "string" or result == "" then
    return nil
  end
  submergedCache[coloredPath] = result
  return result
end

--- Apply the submerged waterline mask to an already-derived luminance
--- sheet.  Used in non-ADVANCED colour modes where the coloured sprite
--- has already been converted to the 3-shade luminance ramp.  The
--- waterline (foam crest + blue line) uses fixed luminance shade values
--- so the zone pass colours them consistently regardless of mode.
local SUBMERGED_LUMA_VERSION = 1
local function submergedLumaCacheFileName(sourcePath)
  local key = tostring(sourcePath):gsub("[^%w%.%-_]", "_")
  if #key > 80 then key = key:sub(#key - 79) end
  return "subluma_v" .. SUBMERGED_LUMA_VERSION .. "_" .. key .. ".png"
end

local submergedLumaCache = {}

-- Luminance shade values for the foam crest and water line.
-- These are the same shades used by pathFor: SHADE_LIGHT, SHADE_MID,
-- SHADE_DARK.  Foam = lightest, water = mid.
local FOAM_LUMA = 0.8
local WATER_LUMA = 0.45

function LuminanceSheet.submergedFromLuma(lumaPath)
  if type(lumaPath) ~= "string" or lumaPath == "" then return nil end
  if not LuminanceSheet.available() then return nil end
  if submergedLumaCache[lumaPath] then return submergedLumaCache[lumaPath] end

  local ok, result = pcall(function()
    return deriveAndPersist(lumaPath, submergedLumaCacheFileName(lumaPath), function(id)
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
    end)
  end)

  if not ok or type(result) ~= "string" or result == "" then
    return nil
  end
  submergedLumaCache[lumaPath] = result
  return result
end

return LuminanceSheet
