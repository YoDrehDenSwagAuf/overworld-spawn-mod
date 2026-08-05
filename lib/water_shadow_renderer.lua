-- Isolated Voxel water-shadow presentation for Hidden Silhouettes and
-- Silhouettes. Flat 2D presentation is unchanged (circle / tint paths).
--
-- Preferred path: keep the native SpriteRenderer + DS SpriteBillboards mesh,
-- but wrap VoxelScene.drawEntity so water-shadow entities use a nearly
-- horizontal world matrix (lie flat under the water surface) instead of the
-- default upright trainer lean. No DramaticShapeVoxelMod repo patch.
local V = ...
local DebugLog = V.require("debug_log")

local WaterShadowRenderer = {}
WaterShadowRenderer.__index = WaterShadowRenderer

WaterShadowRenderer.MODE = {
  FLAT_WORLD = "flat_world",
  UPRIGHT_FALLBACK = "upright_fallback",
  NONE = "none",
}

-- Hidden marker asset (16×96, 6 identical/minimally animated ovals).
WaterShadowRenderer.HIDDEN_RELATIVE =
  "assets/generated/water_hidden_runtime/hidden-water-shadow.png"
WaterShadowRenderer.HIDDEN_ID = "SPRITE_OW_WATER_HIDDEN_SHADOW"

-- Tilt onto the water plane (radians). π/2 = fully horizontal.
-- ~80° reads as a flat underwater shadow without vanishing edge-on in FP.
WaterShadowRenderer.FLAT_TILT_RAD = math.rad(82)

-- World-Y sink below the character ground plane (water surface sits recessed).
WaterShadowRenderer.HIDDEN_SINK = 1.5
WaterShadowRenderer.SILHOUETTE_SINK = 2.5

-- Tag written onto sprite.def so the drawEntity wrap can identify us without
-- needing the entity pointer (posesOf only forwards pose fields).
WaterShadowRenderer.DEF_TAG = "waterFlatShadow"
WaterShadowRenderer.DEF_KIND = "waterShadowKind" -- "hidden" | "silhouette"

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

function WaterShadowRenderer.hiddenDef(mod)
  local relative = WaterShadowRenderer.HIDDEN_RELATIVE
  local image = relative
  if mod and mod.assets and type(mod.assets.path) == "function" then
    local ok, p = pcall(mod.assets.path, mod.assets, relative)
    if ok and type(p) == "string" and p ~= "" then
      image = p
    end
  end
  return {
    image = image,
    frames = 6,
    walker = true,
    trueColor = true,
    id = WaterShadowRenderer.HIDDEN_ID,
    [WaterShadowRenderer.DEF_TAG] = true,
    [WaterShadowRenderer.DEF_KIND] = "hidden",
  }
end

function WaterShadowRenderer.isWaterShadowDef(def)
  return type(def) == "table" and def[WaterShadowRenderer.DEF_TAG] == true
end

function WaterShadowRenderer.tagDef(def, kind)
  if type(def) ~= "table" then return def end
  def[WaterShadowRenderer.DEF_TAG] = true
  def[WaterShadowRenderer.DEF_KIND] = kind or def[WaterShadowRenderer.DEF_KIND] or "silhouette"
  return def
end

function WaterShadowRenderer.sinkFor(def)
  local kind = def and def[WaterShadowRenderer.DEF_KIND]
  if kind == "hidden" then
    return WaterShadowRenderer.HIDDEN_SINK
  end
  return WaterShadowRenderer.SILHOUETTE_SINK
end

function WaterShadowRenderer.shadowModeFor(mod, entity, voxelActive)
  local WaterDisplay = V.require("water_display")
  if not voxelActive or not WaterDisplay.isWaterEntity(entity) then
    return WaterShadowRenderer.MODE.NONE
  end
  if WaterDisplay.isHiddenSilhouettes(mod) or WaterDisplay.isSilhouettes(mod) then
    return WaterShadowRenderer.MODE.FLAT_WORLD
  end
  return WaterShadowRenderer.MODE.NONE
end

-- Build a nearly-horizontal card matrix: cell-centered pivot, tip onto XZ.
-- Coordinate convention matches Dramatic Shape (Y up, Z = world py).
local function flatMatrix(Mat4, px, py, y, mirror, tilt)
  tilt = tilt or WaterShadowRenderer.FLAT_TILT_RAD
  -- Full horizontal would be rotateX(-π/2); we stop a few degrees short.
  local rot = -tilt
  local m = Mat4.translate((px or 0) + 8, y, (py or 0) + 8)
  m = Mat4.mul(m, Mat4.rotateX(rot))
  if mirror then
    m = Mat4.mul(m, Mat4.scale(-1, 1, 1))
  end
  -- Center pivot (not feet): avoid lateral swing on facing/mirror changes.
  return Mat4.mul(m, Mat4.translate(-8, -8, 0))
end

local function frameFor(def, facing, phase, flip)
  local SR = tryRequire("src.render.SpriteRenderer")
  local frame, mirror = 0, false
  if (def.frames or 1) > 1 then
    if SR and SR.WALK and SR.STAND then
      frame = (def.walker and phase == 1) and SR.WALK[facing]
        or SR.STAND[facing]
      mirror = facing == "right"
        or ((facing == "down" or facing == "up") and phase == 1 and flip)
    else
      -- Gen1Recomp STAND/WALK tables (same as docs/ARCHITECTURE.md).
      local STAND = { down = 0, up = 1, left = 2, right = 2 }
      local WALK = { down = 3, up = 4, left = 5, right = 5 }
      frame = (def.walker and phase == 1) and (WALK[facing] or 0)
        or (STAND[facing] or 0)
      mirror = facing == "right"
        or ((facing == "down" or facing == "up") and phase == 1 and flip)
    end
  end
  -- Hidden marker: ignore facing (all frames are the same oval).
  if def[WaterShadowRenderer.DEF_KIND] == "hidden" then
    frame = 0
    mirror = false
  end
  return frame or 0, mirror
end

function WaterShadowRenderer.drawFlat(dsLib, sprite, px, py, facing, phase, flip, gh, colors, lift)
  if not (dsLib and type(dsLib.require) == "function") then
    return false, "no ds lib"
  end
  local def = sprite and sprite.def
  if not WaterShadowRenderer.isWaterShadowDef(def) then
    return false, "not a water shadow def"
  end

  local okSB, SpriteBillboards = pcall(dsLib.require, "SpriteBillboards")
  local okV3, Voxel3D = pcall(dsLib.require, "Voxel3D")
  local okM4, Mat4 = pcall(dsLib.require, "Mat4")
  if not (okSB and SpriteBillboards and type(SpriteBillboards.mesh) == "function") then
    return false, "SpriteBillboards.mesh missing"
  end
  if not (okV3 and Voxel3D and type(Voxel3D.draw) == "function") then
    return false, "Voxel3D.draw missing"
  end
  if not (okM4 and Mat4 and type(Mat4.translate) == "function") then
    return false, "Mat4 missing"
  end

  local frame, mirror = frameFor(def, facing or "down", phase or 0, flip == true)
  local mesh = SpriteBillboards.mesh(def, frame)
  if not mesh then
    return false, "mesh nil"
  end

  local tex = sprite.resolveImage and sprite:resolveImage() or nil
  if colors and not def.trueColor then
    local okTA, TerrainAtlas = pcall(dsLib.require, "TerrainAtlas")
    if okTA and TerrainAtlas and type(TerrainAtlas.forSprite) == "function" then
      tex = TerrainAtlas.forSprite(def.image, colors) or tex
    end
  end
  if not tex then
    return false, "texture nil"
  end

  local sink = WaterShadowRenderer.sinkFor(def)
  local y = (gh or 0) + (lift or 0) - sink
  local model = flatMatrix(Mat4, px, py, y, mirror, WaterShadowRenderer.FLAT_TILT_RAD)

  -- Small camera-ward pull so the flat card clears water surface z-fighting.
  local pull = 2
  local sunModel = nil
  if type(Voxel3D.casterMatrix) == "function" then
    local okSM, ShadowMap = pcall(dsLib.require, "ShadowMap")
    local caster = Voxel3D.casterMatrix(px, py, y, mirror)
    if okSM and ShadowMap and type(ShadowMap.snug) == "function" then
      sunModel = ShadowMap.snug(caster)
    else
      sunModel = caster
    end
  end

  local okDraw, err = pcall(Voxel3D.draw, mesh, tex, model, pull, sunModel)
  if not okDraw then
    return false, err
  end
  return true
end

function WaterShadowRenderer.installDrawHook(adapter)
  if not adapter or adapter._waterShadowDrawHooked then
    return adapter and adapter._waterShadowDrawOk == true
  end
  adapter._waterShadowDrawHooked = true
  adapter._waterShadowDrawOk = false
  adapter._waterShadowMode = WaterShadowRenderer.MODE.UPRIGHT_FALLBACK

  local ds = adapter.mod and adapter.mod.find and adapter.mod.find("DRAMATIC_SHAPE")
  local lib = ds and ds.exports and ds.exports.lib
  if not (lib and type(lib.require) == "function") then
    return false
  end
  local okScene, VoxelScene = pcall(lib.require, "VoxelScene")
  if not (okScene and VoxelScene and type(VoxelScene.drawEntity) == "function") then
    return false
  end
  if VoxelScene._owwildWaterShadowWrapped then
    adapter._waterShadowDrawOk = true
    adapter._waterShadowMode = WaterShadowRenderer.MODE.FLAT_WORLD
    return true
  end

  local orig = VoxelScene.drawEntity
  VoxelScene.drawEntity = function(sprite, px, py, facing, phase, flip, gh, colors, lift)
    local def = sprite and sprite.def
    if WaterShadowRenderer.isWaterShadowDef(def) then
      local ok = select(1, WaterShadowRenderer.drawFlat(
        lib, sprite, px, py, facing, phase, flip, gh, colors, lift))
      if ok then
        return true
      end
      -- Last resort: upright native billboard (still visible, documented).
      return orig(sprite, px, py, facing, phase, flip, gh, colors, lift)
    end
    return orig(sprite, px, py, facing, phase, flip, gh, colors, lift)
  end
  VoxelScene._owwildWaterShadowWrapped = true
  adapter._waterShadowDrawOk = true
  adapter._waterShadowMode = WaterShadowRenderer.MODE.FLAT_WORLD
  if adapter.mod then
    pcall(DebugLog.info, adapter.mod,
      "WaterShadowRenderer: VoxelScene.drawEntity wrap installed (flat underwater)")
  end
  return true
end

return WaterShadowRenderer
