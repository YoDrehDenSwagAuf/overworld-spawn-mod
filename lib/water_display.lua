-- Water Pokémon display modes (presentation only).
-- Spawn / AI / collision / sprite providers stay unchanged; this module
-- decides how already-spawned water entities are drawn.
local V = ...
local Config = V.require("config")

local WaterDisplay = {}

WaterDisplay.MODE = {
  SWIMMING_SPRITES = "swimming_sprites",
  HIDDEN_SILHOUETTES = "hidden_silhouettes",
  SILHOUETTES = "silhouettes",
  CLASSIC_ENCOUNTERS = "classic_encounters",
  DISABLED = "disabled",
}

-- Dark blue-teal silhouette (not pure black). ~10–15% brightness base.
WaterDisplay.SILHOUETTE = {
  r = 0.04,
  g = 0.11,
  b = 0.14,
  alpha = 0.82,
  -- Extra sit offset under the water surface (pixels; +Y = lower on screen).
  sinkPx = 3,
  -- Fully dark beyond this Chebyshev distance (tiles).
  farTiles = 3,
  -- Start brightening within this distance (tiles).
  nearTiles = 2,
  -- Brightness multiplier at 0 tiles (still detail-free).
  nearBright = 1.85,
}

-- Hidden silhouette circle (dark surface marker).
WaterDisplay.HIDDEN = {
  r = 0.05,
  g = 0.08,
  b = 0.10,
  alphaFar = 0.55,
  alphaNear = 0.78,
  radius = 3.5,
  bobAmp = 0.8,
}

local VALID = {
  swimming_sprites = true,
  hidden_silhouettes = true,
  silhouettes = true,
  classic_encounters = true,
  disabled = true,
}

WaterDisplay.VALID = VALID

function WaterDisplay.normalize(value)
  if value == true or value == "true" or value == "on" or value == "ON" then
    return WaterDisplay.MODE.SWIMMING_SPRITES
  end
  if value == false or value == "false" or value == "off" or value == "OFF" then
    -- Legacy Water Mons OFF ≈ no visible water mons; classic rolls still
    -- followed Random Enc. Map to classic_encounters (closest preserve).
    return WaterDisplay.MODE.CLASSIC_ENCOUNTERS
  end
  if type(value) == "string" and VALID[value] then
    return value
  end
  return nil
end

function WaterDisplay.mode(mod)
  return Config.waterDisplayMode(mod)
end

function WaterDisplay.spawnsEnabled(mod)
  local m = WaterDisplay.mode(mod)
  return m == WaterDisplay.MODE.SWIMMING_SPRITES
    or m == WaterDisplay.MODE.HIDDEN_SILHOUETTES
    or m == WaterDisplay.MODE.SILHOUETTES
end

function WaterDisplay.isSwimmingSprites(mod)
  return WaterDisplay.mode(mod) == WaterDisplay.MODE.SWIMMING_SPRITES
end

function WaterDisplay.isSilhouettes(mod)
  return WaterDisplay.mode(mod) == WaterDisplay.MODE.SILHOUETTES
end

function WaterDisplay.isHiddenSilhouettes(mod)
  return WaterDisplay.mode(mod) == WaterDisplay.MODE.HIDDEN_SILHOUETTES
end

function WaterDisplay.isClassicEncounters(mod)
  return WaterDisplay.mode(mod) == WaterDisplay.MODE.CLASSIC_ENCOUNTERS
end

function WaterDisplay.isDisabled(mod)
  return WaterDisplay.mode(mod) == WaterDisplay.MODE.DISABLED
end

-- Water / fishing classic roll terrains (Gen1 encounter.roll ctx.terrain).
function WaterDisplay.isWaterTerrain(ctx)
  if type(ctx) ~= "table" then return false end
  local t = ctx.terrain or ctx.encounterKind or ctx.kind
  if type(t) ~= "string" then return false end
  t = string.lower(t)
  return t == "water" or t == "surfing" or t == "surf"
    or t == "fishing" or t == "old_rod" or t == "good_rod"
    or t == "super_rod" or t == "rod"
end

function WaterDisplay.isWaterEntity(entity)
  if not entity then return false end
  if entity.surface == "WATER" or entity.surface == "water" then
    return true
  end
  local Behavior = V.require("behavior")
  if entity.behavior and Behavior.isWater(entity.behavior) then
    return true
  end
  return entity.originSurface == "WATER" or entity.spriteState == "water"
end

-- Legacy name: previously forced the emergency 2D overlay for Hidden in Voxel.
-- Hidden now uses a native flat water-shadow SpriteRenderer in Voxel, so this
-- returns false. Kept for call-site / test compatibility.
function WaterDisplay.needsOverlayPresentation(mod, entity)
  return false
end

-- True when Voxel should bind a native silhouette water sheet (not tint).
function WaterDisplay.needsNativeSilhouetteSheet(mod, entity)
  return WaterDisplay.isWaterEntity(entity)
    and WaterDisplay.isSilhouettes(mod)
end

-- True when Voxel should bind the generic Hidden underwater shadow marker.
function WaterDisplay.needsNativeHiddenShadow(mod, entity)
  return WaterDisplay.isWaterEntity(entity)
    and WaterDisplay.isHiddenSilhouettes(mod)
end

-- Either Voxel water-shadow mode (Hidden marker or Silhouette sheet).
function WaterDisplay.needsWaterShadowPresentation(mod, entity)
  return WaterDisplay.needsNativeSilhouetteSheet(mod, entity)
    or WaterDisplay.needsNativeHiddenShadow(mod, entity)
end

-- Native sheets only while Dramatic Shape / Voxel camera is actually active.
-- Flat 2D keeps the existing runtime tint / circle paths.
function WaterDisplay.useNativeSilhouetteSheet(mod, entity, voxelActive)
  return voxelActive == true
    and WaterDisplay.needsNativeSilhouetteSheet(mod, entity)
end

function WaterDisplay.useNativeHiddenShadow(mod, entity, voxelActive)
  return voxelActive == true
    and WaterDisplay.needsNativeHiddenShadow(mod, entity)
end

function WaterDisplay.useWaterShadowPresentation(mod, entity, voxelActive)
  return voxelActive == true
    and WaterDisplay.needsWaterShadowPresentation(mod, entity)
end

function WaterDisplay.isVoxelCameraActive(mod)
  local world = mod and mod.world
  local ow = world and world.overworld and world:overworld()
  if not ow then return false end
  -- Prefer VoxelAdapter when attached to logic exports.
  local logic = mod.exports and mod.exports.logic
  local voxel = logic and logic.voxel
  if voxel and type(voxel.isVoxelCameraActive) == "function" then
    local ok, active = pcall(voxel.isVoxelCameraActive, voxel)
    if ok then return active == true end
  end
  if ow.cameraMode == "VOXEL" or ow.cameraMode == "voxel" then
    return true
  end
  if ow.renderer == "DRAMATIC_SHAPE" or ow.worldRenderer == "DRAMATIC_SHAPE" then
    return true
  end
  return false
end

local function chebyshevTiles(entity, player)
  if not entity or not player then return 99 end
  local ex = entity.cellX or entity.x
  local ey = entity.cellY or entity.y
  local px = player.cellX or player.x
  local py = player.cellY or player.y
  if ex == nil or ey == nil or px == nil or py == nil then return 99 end
  local dx = math.abs(ex - px)
  local dy = math.abs(ey - py)
  if dx > dy then return dx end
  return dy
end

-- Returns brightness multiplier in [1, nearBright] for silhouette tint.
function WaterDisplay.proximityBrightness(entity, player)
  local S = WaterDisplay.SILHOUETTE
  local dist = chebyshevTiles(entity, player)
  if dist >= (S.farTiles or 3) then
    return 1
  end
  local near = S.nearTiles or 2
  if dist > near then
    -- Soft falloff between near and far.
    local t = (dist - near) / math.max(1, (S.farTiles or 3) - near)
    local bright = S.nearBright or 1.85
    return bright + (1 - bright) * t
  end
  -- Within 0–near tiles: ramp from nearBright at 0 toward slightly less at near.
  local bright = S.nearBright or 1.85
  local t = dist / math.max(1, near)
  return bright + (1.35 - bright) * t
end

function WaterDisplay.silhouetteColor(entity, player)
  local S = WaterDisplay.SILHOUETTE
  local b = WaterDisplay.proximityBrightness(entity, player)
  local r = math.min(0.35, (S.r or 0.04) * b)
  local g = math.min(0.40, (S.g or 0.11) * b)
  local bl = math.min(0.42, (S.b or 0.14) * b)
  return r, g, bl, S.alpha or 0.82
end

function WaterDisplay.silhouetteSink(mod, entity)
  if not WaterDisplay.isSilhouettes(mod) then return 0 end
  if entity and not WaterDisplay.isWaterEntity(entity) then return 0 end
  -- Native voxel silhouette sheets already bake the under-water sink.
  if entity and entity.waterSilhouetteSheet == true then return 0 end
  -- Flat 2D tint path: runtime sink. Tests without entity use mode alone.
  return tonumber(WaterDisplay.SILHOUETTE.sinkPx) or 3
end

function WaterDisplay.resolvePlayer(mod)
  local world = mod and mod.world
  local ow = world and world.overworld and world:overworld()
  return ow and ow.player or nil
end

-- Draw a small dark animated circle at the entity's water surface position.
function WaterDisplay.drawHiddenCircle(entity, camX, camY, opts)
  if not (love and love.graphics) then return end
  if not entity then return end
  opts = opts or {}
  local H = WaterDisplay.HIDDEN
  local player = opts.player
  local dist = chebyshevTiles(entity, player)
  local near = dist <= 2
  local a = near and (H.alphaNear or 0.78) or (H.alphaFar or 0.55)

  local t = love.timer and love.timer.getTime and love.timer.getTime() or 0
  local bob = math.sin(t * 3.1 + (entity.cellX or 0) * 0.7) * (H.bobAmp or 0.8)
  -- Slight horizontal drift so the marker feels like it drifts with the water.
  local drift = math.sin(t * 1.7 + (entity.cellY or 0) * 0.5) * 0.6

  local x = math.floor((entity.px or 0) - (camX or 0) + 8 + drift)
  local y = math.floor((entity.py or 0) - (camY or 0) + 11 + bob
    + (tonumber(entity.surfaceVisualOffset) or entity.waterSink or 2))
  local r = H.radius or 3.5

  love.graphics.push("all")
  love.graphics.setColor(H.r or 0.05, H.g or 0.08, H.b or 0.10, a)
  love.graphics.circle("fill", x, y, r)
  love.graphics.setColor(H.r or 0.05, H.g or 0.08, H.b or 0.10, a * 0.45)
  love.graphics.circle("fill", x, y, r * 0.55)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.pop()
end

-- Apply temporary silhouette tint; always restores white afterward.
function WaterDisplay.withSilhouetteTint(entity, player, drawFn)
  if not (love and love.graphics and love.graphics.setColor) then
    drawFn()
    return
  end
  local r, g, b, a = WaterDisplay.silhouetteColor(entity, player)
  love.graphics.push("all")
  love.graphics.setColor(r, g, b, a)
  local ok, err = pcall(drawFn)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.pop()
  if not ok then error(err, 0) end
end

return WaterDisplay
