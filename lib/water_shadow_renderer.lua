-- Compatibility facade for the Voxel water-shadow presentation.
-- Implementation lives in lib/voxel_water_shadows.lua (horizontal world quads).
-- Flat 2D presentation remains in water_display.lua and is unchanged.
local V = ...
local VoxelWaterShadows = V.require("voxel_water_shadows")

local WaterShadowRenderer = {}
WaterShadowRenderer.__index = WaterShadowRenderer

WaterShadowRenderer.MODE = {
  FLAT_WORLD = VoxelWaterShadows.FLAT_WORLD,
  HIDDEN_WORLD_QUAD = VoxelWaterShadows.MODE.HIDDEN_WORLD_QUAD,
  SPECIES_WORLD_QUAD = VoxelWaterShadows.MODE.SPECIES_WORLD_QUAD,
  UPRIGHT_FALLBACK = "upright_fallback", -- legacy label; no longer used
  NONE = VoxelWaterShadows.MODE.NONE,
}

WaterShadowRenderer.PRESENTATION = VoxelWaterShadows.PRESENTATION
WaterShadowRenderer.HIDDEN_RELATIVE = VoxelWaterShadows.HIDDEN_RELATIVE
WaterShadowRenderer.HIDDEN_ID = VoxelWaterShadows.HIDDEN_ID
WaterShadowRenderer.HIDDEN_WIDTH = VoxelWaterShadows.HIDDEN_WIDTH
WaterShadowRenderer.HIDDEN_DEPTH = VoxelWaterShadows.HIDDEN_DEPTH
WaterShadowRenderer.SPECIES_WIDTH = VoxelWaterShadows.SPECIES_WIDTH
WaterShadowRenderer.SPECIES_DEPTH = VoxelWaterShadows.SPECIES_DEPTH
WaterShadowRenderer.SURFACE_EPSILON = VoxelWaterShadows.SURFACE_EPSILON
WaterShadowRenderer.HIDDEN_SINK = VoxelWaterShadows.HIDDEN_SINK
WaterShadowRenderer.SILHOUETTE_SINK = VoxelWaterShadows.SILHOUETTE_SINK
WaterShadowRenderer.FLAT_TILT_RAD = VoxelWaterShadows.FLAT_TILT_RAD
WaterShadowRenderer.DEF_TAG = VoxelWaterShadows.DEF_TAG
WaterShadowRenderer.DEF_KIND = VoxelWaterShadows.DEF_KIND

WaterShadowRenderer.hiddenDef = VoxelWaterShadows.hiddenDef
WaterShadowRenderer.isWaterShadowDef = VoxelWaterShadows.isWaterShadowDef
WaterShadowRenderer.tagDef = VoxelWaterShadows.tagDef
WaterShadowRenderer.waterSurfaceAt = VoxelWaterShadows.waterSurfaceAt
WaterShadowRenderer.frameFor = VoxelWaterShadows.frameFor
WaterShadowRenderer.horizontalMatrix = VoxelWaterShadows.horizontalMatrix
WaterShadowRenderer.invalidateCache = VoxelWaterShadows.invalidateCache
WaterShadowRenderer.statusLines = VoxelWaterShadows.statusLines
WaterShadowRenderer.shouldFilterCharacterBody = VoxelWaterShadows.shouldFilterCharacterBody
WaterShadowRenderer.markPresentation = VoxelWaterShadows.markPresentation
WaterShadowRenderer.collectEntities = VoxelWaterShadows.collectEntities
WaterShadowRenderer.drawPass = VoxelWaterShadows.drawPass
WaterShadowRenderer.drawEntityShadow = VoxelWaterShadows.drawEntityShadow

function WaterShadowRenderer.sinkFor(def)
  return VoxelWaterShadows.SURFACE_EPSILON
end

function WaterShadowRenderer.shadowModeFor(mod, entity, voxelActive)
  local mode = VoxelWaterShadows.shadowModeFor(mod, entity, voxelActive)
  if mode == VoxelWaterShadows.MODE.NONE then
    return WaterShadowRenderer.MODE.NONE
  end
  -- Cache keys / older tests expect the flat_world token.
  return WaterShadowRenderer.MODE.FLAT_WORLD
end

function WaterShadowRenderer.installDrawHook(adapter)
  local ok = VoxelWaterShadows.installHooks(adapter)
  if adapter then
    adapter._waterShadowDrawOk = adapter._voxelWaterShadowsOk == true
    adapter._waterShadowMode = adapter._voxelWaterShadowsOk
      and WaterShadowRenderer.MODE.FLAT_WORLD
      or WaterShadowRenderer.MODE.NONE
  end
  return ok
end

-- Legacy name used by older unit tests.
function WaterShadowRenderer.drawFlat(dsLib, sprite, px, py, facing, phase, flip, gh, colors, lift)
  local entity = {
    sprite = sprite,
    px = px,
    py = py,
    facing = facing,
    stepFlip = flip == true,
    cellX = math.floor(((px or 0) + 8) / 16),
    cellY = math.floor(((py or 0) + 8) / 16),
    voxelWaterShadowPresentation = true,
    pose = function()
      return sprite, px, py, facing, phase, flip
    end,
  }
  return VoxelWaterShadows.drawEntityShadow(dsLib, entity, {
    groundHeight = gh,
    colors = colors,
  })
end

return WaterShadowRenderer
