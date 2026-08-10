-- Overworld catch modifiers: throw quality, facing (stealth), mild level scaling.
-- Native species catch rate + ball type remain authoritative via Catching.attempt.
-- Ball multipliers must NOT be applied here (Catching.attempt already uses ball).
local CatchMath = {}

CatchMath.MAX_RANGE = 6

--- Shared rounding for HUD marker, ground preview, and landCell.
-- 1.0–1.49 → 1 … 5.5–6.0 → 6
function CatchMath.roundedPower(power)
  local n = math.floor((tonumber(power) or 1) + 0.5)
  if n < 1 then return 1 end
  if n > CatchMath.MAX_RANGE then return CatchMath.MAX_RANGE end
  return n
end

CatchMath.QUALITY = {
  PERFECT = "perfect",
  GREAT = "great",
  HIT = "hit",
  MISS = "miss",
}

CatchMath.ANGLE = {
  BACK = "back",
  SIDE = "side",
  FRONT = "front",
}

-- Suggested windows (tile-power difference). Tunable constants.
CatchMath.QUALITY_WINDOWS = {
  perfect = 0.20,
  great = 0.50,
  hit = 0.90,
}

CatchMath.QUALITY_MODIFIERS = {
  perfect = 1.25,
  great = 1.10,
  hit = 1.00,
  -- miss: no catch attempt
}

CatchMath.FACING_MODIFIERS = {
  back = 1.35,
  side = 1.15,
  front = 1.00,
}

-- levelModifier = clamp(0.65, 1.15, 1.15 - level * 0.01)
CatchMath.LEVEL_MOD_MAX = 1.15
CatchMath.LEVEL_MOD_MIN = 0.65
CatchMath.LEVEL_MOD_PER_LEVEL = 0.01

local function clamp(lo, hi, v)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function CatchMath.throwQuality(power, distance)
  power = tonumber(power) or 0
  distance = tonumber(distance) or 0
  local diff = math.abs(power - distance)
  if diff <= CatchMath.QUALITY_WINDOWS.perfect then
    return CatchMath.QUALITY.PERFECT
  elseif diff <= CatchMath.QUALITY_WINDOWS.great then
    return CatchMath.QUALITY.GREAT
  elseif diff <= CatchMath.QUALITY_WINDOWS.hit then
    return CatchMath.QUALITY.HIT
  end
  return CatchMath.QUALITY.MISS
end

function CatchMath.qualityModifier(quality)
  return CatchMath.QUALITY_MODIFIERS[quality] or 1.0
end

--- Where the player stands relative to the Pokémon's facing.
-- Pokémon facing UP: player south → BACK, north → FRONT, east/west → SIDE.
-- If facing is unavailable → FRONT (neutral ×1.00). Do not guess.
function CatchMath.facingAngle(playerCellX, playerCellY, monCellX, monCellY, monFacing)
  if monFacing == nil or monFacing == "" then
    return CatchMath.ANGLE.FRONT
  end
  local facing = tostring(monFacing):lower()
  local dx = (playerCellX or 0) - (monCellX or 0)
  local dy = (playerCellY or 0) - (monCellY or 0)

  if facing == "up" then
    if dy > 0 then return CatchMath.ANGLE.BACK end
    if dy < 0 then return CatchMath.ANGLE.FRONT end
    return CatchMath.ANGLE.SIDE
  elseif facing == "down" then
    if dy < 0 then return CatchMath.ANGLE.BACK end
    if dy > 0 then return CatchMath.ANGLE.FRONT end
    return CatchMath.ANGLE.SIDE
  elseif facing == "left" then
    if dx > 0 then return CatchMath.ANGLE.BACK end
    if dx < 0 then return CatchMath.ANGLE.FRONT end
    return CatchMath.ANGLE.SIDE
  elseif facing == "right" then
    if dx < 0 then return CatchMath.ANGLE.BACK end
    if dx > 0 then return CatchMath.ANGLE.FRONT end
    return CatchMath.ANGLE.SIDE
  end
  return CatchMath.ANGLE.FRONT
end

function CatchMath.facingModifier(angle)
  return CatchMath.FACING_MODIFIERS[angle] or 1.0
end

function CatchMath.levelModifier(level)
  level = tonumber(level) or 1
  local raw = CatchMath.LEVEL_MOD_MAX - (level * CatchMath.LEVEL_MOD_PER_LEVEL)
  return clamp(CatchMath.LEVEL_MOD_MIN, CatchMath.LEVEL_MOD_MAX, raw)
end

--- Build rateOverride for Catching.attempt.
-- effectiveCatch = nativeCatch × levelModifier × throwQualityModifier × facingModifier
-- Clamped to 1..255. Ball bonus stays inside Catching.attempt.
function CatchMath.effectiveCatchRate(nativeCatchRate, level, quality, angle)
  local native = tonumber(nativeCatchRate) or 255
  local rate = native
    * CatchMath.levelModifier(level)
    * CatchMath.qualityModifier(quality)
    * CatchMath.facingModifier(angle)
  rate = math.floor(rate + 0.5)
  return clamp(1, 255, rate)
end

--- Feedback label for HUD (optional angle suffix on perfect).
function CatchMath.feedbackLabel(quality, angle)
  if quality == CatchMath.QUALITY.MISS then
    return "MISS!"
  end
  if quality == CatchMath.QUALITY.PERFECT then
    if angle == CatchMath.ANGLE.BACK then
      return "PERFECT BACK THROW!"
    end
    return "PERFECT!"
  end
  if quality == CatchMath.QUALITY.GREAT then
    return "GREAT!"
  end
  return nil
end

return CatchMath
