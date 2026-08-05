-- Isolated Voxel water-shadow presentation for Hidden Silhouettes and
-- Silhouettes. Flat 2D presentation is unchanged (circle / tint paths).
--
-- Responsibility (Voxel camera only):
--   - horizontal world quad mesh + UV/frame cache
--   - water-surface height helper
--   - draw via Dramatic Shape Voxel3D.draw
--   - Hidden ellipse + species silhouette shadows
--
-- Not responsible for spawn / AI / movement / encounters / entity lifecycle.
-- Swimming Sprites stay on the native upright SpriteBillboard path.
local V = ...
local DebugLog = V.require("debug_log")

local VoxelWaterShadows = {}
VoxelWaterShadows.__index = VoxelWaterShadows

VoxelWaterShadows.PRESENTATION = {
  SWIMMING_CHARACTER = "SWIMMING_CHARACTER",
  HIDDEN_WORLD_QUAD = "HIDDEN_WORLD_QUAD",
  SPECIES_WORLD_QUAD = "SPECIES_WORLD_QUAD",
  FLAT_2D = "FLAT_2D",
}

VoxelWaterShadows.MODE = {
  HIDDEN_WORLD_QUAD = "hidden_world_quad",
  SPECIES_WORLD_QUAD = "species_world_quad",
  NONE = "none",
}

-- Hidden marker: single 16×16 oval (no '?' / no species detail).
VoxelWaterShadows.HIDDEN_RELATIVE =
  "assets/generated/water_hidden_runtime/water_hidden_shadow.png"
VoxelWaterShadows.HIDDEN_ID = "SPRITE_OW_WATER_HIDDEN_SHADOW"

-- World-quad sizes (world pixels). No user settings in this PR.
VoxelWaterShadows.HIDDEN_WIDTH = 10
VoxelWaterShadows.HIDDEN_DEPTH = 7
VoxelWaterShadows.SPECIES_WIDTH = 15
VoxelWaterShadows.SPECIES_DEPTH = 11

-- Keep shadows off the water mesh plane (avoid z-fighting / full occlusion).
-- Optical underwater look comes from colour/alpha + flat orientation.
VoxelWaterShadows.SURFACE_EPSILON = 0.08

-- When DS does not export a water-surface height, lift groundAt by this bias.
-- Matches the recessed-water character ground contract (floor ≈ 0, mesh above).
VoxelWaterShadows.WATER_SURFACE_FALLBACK_BIAS = 4.0

-- SpriteBillboards local mesh is a 16×16 XY card; we rotate it onto XZ.
VoxelWaterShadows.MESH_FRAME = 16

-- Optional pulse for Hidden only (scale / alpha), no vertical bobbing.
VoxelWaterShadows.HIDDEN_PULSE_AMP = 0.035

-- Def tags (also used when a sheet is still bound for frame/UV lookup).
VoxelWaterShadows.DEF_TAG = "voxelWaterShadow"
VoxelWaterShadows.DEF_KIND = "voxelWaterShadowKind" -- "hidden" | "silhouette"

-- Legacy aliases kept so older call sites / tests keep compiling.
VoxelWaterShadows.FLAT_WORLD = "flat_world"
VoxelWaterShadows.HIDDEN_SINK = VoxelWaterShadows.SURFACE_EPSILON
VoxelWaterShadows.SILHOUETTE_SINK = VoxelWaterShadows.SURFACE_EPSILON
VoxelWaterShadows.FLAT_TILT_RAD = math.pi / 2

local meshCache = {}
local hiddenTextureCache = nil
local assetsGeneration = 0

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function dsLib(mod)
  local ds = mod and mod.find and mod.find("DRAMATIC_SHAPE")
  local lib = ds and ds.exports and ds.exports.lib
  if lib and type(lib.require) == "function" then
    return lib
  end
  return nil
end

function VoxelWaterShadows.invalidateCache()
  meshCache = {}
  hiddenTextureCache = nil
  assetsGeneration = assetsGeneration + 1
end

function VoxelWaterShadows.hiddenDef(mod)
  local relative = VoxelWaterShadows.HIDDEN_RELATIVE
  local image = relative
  if mod and mod.assets and type(mod.assets.path) == "function" then
    local ok, p = pcall(mod.assets.path, mod.assets, relative)
    if ok and type(p) == "string" and p ~= "" then
      image = p
    end
  end
  return {
    image = image,
    frames = 1,
    walker = false,
    trueColor = true,
    id = VoxelWaterShadows.HIDDEN_ID,
    [VoxelWaterShadows.DEF_TAG] = true,
    [VoxelWaterShadows.DEF_KIND] = "hidden",
    -- Legacy tag so older drawEntity guards still recognise the def.
    waterFlatShadow = true,
    waterShadowKind = "hidden",
  }
end

function VoxelWaterShadows.isWaterShadowDef(def)
  return type(def) == "table"
    and (def[VoxelWaterShadows.DEF_TAG] == true or def.waterFlatShadow == true)
end

function VoxelWaterShadows.tagDef(def, kind)
  if type(def) ~= "table" then return def end
  def[VoxelWaterShadows.DEF_TAG] = true
  def[VoxelWaterShadows.DEF_KIND] = kind or def[VoxelWaterShadows.DEF_KIND] or "silhouette"
  def.waterFlatShadow = true
  def.waterShadowKind = def[VoxelWaterShadows.DEF_KIND]
  return def
end

function VoxelWaterShadows.kindFor(def)
  if not def then return nil end
  return def[VoxelWaterShadows.DEF_KIND] or def.waterShadowKind
end

function VoxelWaterShadows.shadowModeFor(mod, entity, voxelActive)
  local WaterDisplay = V.require("water_display")
  if not voxelActive or not WaterDisplay.isWaterEntity(entity) then
    return VoxelWaterShadows.MODE.NONE
  end
  if WaterDisplay.isHiddenSilhouettes(mod) then
    return VoxelWaterShadows.MODE.HIDDEN_WORLD_QUAD
  end
  if WaterDisplay.isSilhouettes(mod) then
    return VoxelWaterShadows.MODE.SPECIES_WORLD_QUAD
  end
  return VoxelWaterShadows.MODE.NONE
end

function VoxelWaterShadows.presentationFor(mod, entity, voxelActive)
  local WaterDisplay = V.require("water_display")
  if not WaterDisplay.isWaterEntity(entity) then
    return nil
  end
  if not voxelActive then
    return VoxelWaterShadows.PRESENTATION.FLAT_2D
  end
  if WaterDisplay.isHiddenSilhouettes(mod) then
    return VoxelWaterShadows.PRESENTATION.HIDDEN_WORLD_QUAD
  end
  if WaterDisplay.isSilhouettes(mod) then
    return VoxelWaterShadows.PRESENTATION.SPECIES_WORLD_QUAD
  end
  if WaterDisplay.isSwimmingSprites(mod) then
    return VoxelWaterShadows.PRESENTATION.SWIMMING_CHARACTER
  end
  return nil
end

-- Same height as the visible water mesh when DS exports it; otherwise a
-- single documented fallback (never scatter magic numbers at call sites).
function VoxelWaterShadows.waterSurfaceAt(map, cellX, cellY, opts)
  opts = opts or {}
  local lib = opts.lib
  local ground = opts.groundHeight

  -- 1) Prefer exported TileShape / Water surface helpers when present.
  if lib and type(lib.require) == "function" then
    local okW, Water = pcall(lib.require, "Water")
    if okW and Water then
      if type(Water.surfaceAt) == "function" then
        local ok, y = pcall(Water.surfaceAt, map, cellX, cellY)
        if ok and type(y) == "number" then return y, "Water.surfaceAt" end
      end
      if type(Water.heightAt) == "function" then
        local ok, y = pcall(Water.heightAt, map, cellX, cellY)
        if ok and type(y) == "number" then return y, "Water.heightAt" end
      end
    end
    local okT, TileShape = pcall(lib.require, "TileShape")
    if okT and TileShape then
      if type(TileShape.waterSurfaceAt) == "function" then
        local ok, y = pcall(TileShape.waterSurfaceAt, map, cellX, cellY)
        if ok and type(y) == "number" then return y, "TileShape.waterSurfaceAt" end
      end
      if type(TileShape.surfaceY) == "function" then
        local ok, y = pcall(TileShape.surfaceY, map, cellX, cellY, "water")
        if ok and type(y) == "number" then return y, "TileShape.surfaceY" end
      end
    end
    -- 2) Same ground helper Dramatic Shape uses for character feet.
    if type(ground) ~= "number" then
      local okG, Ground = pcall(lib.require, "Ground")
      if okG and Ground and type(Ground.at) == "function" then
        local ok, y = pcall(Ground.at, map, cellX, cellY)
        if ok and type(y) == "number" then ground = y end
      end
    end
  end

  if type(ground) ~= "number" then
    ground = 0
  end
  -- 3) Conservative documented fallback: recessed water floor + bias.
  return ground + VoxelWaterShadows.WATER_SURFACE_FALLBACK_BIAS, "fallback_ground_bias"
end

function VoxelWaterShadows.frameFor(def, facing, phase, flip)
  facing = facing or "down"
  phase = phase or 0
  flip = flip == true
  local kind = VoxelWaterShadows.kindFor(def)
  if kind == "hidden" or (def and (def.frames or 1) <= 1) then
    return 0, false
  end

  local SR = tryRequire("src.render.SpriteRenderer")
  local frame, mirror = 0, false
  if SR and SR.WALK and SR.STAND then
    frame = (def.walker and phase == 1) and SR.WALK[facing]
      or SR.STAND[facing]
    mirror = facing == "right"
      or ((facing == "down" or facing == "up") and phase == 1 and flip)
  else
    local STAND = { down = 0, up = 1, left = 2, right = 2 }
    local WALK = { down = 3, up = 4, left = 5, right = 5 }
    frame = (def.walker and phase == 1) and (WALK[facing] or 0)
      or (STAND[facing] or 0)
    mirror = facing == "right"
      or ((facing == "down" or facing == "up") and phase == 1 and flip)
  end
  return frame or 0, mirror
end

local function meshCacheKey(imagePath, frame, mirrorStrategy, fw, fh)
  return string.format("%s|%s|%s|%s|%s|g%s",
    tostring(imagePath), tostring(frame), tostring(mirrorStrategy),
    tostring(fw), tostring(fh), tostring(assetsGeneration))
end

function VoxelWaterShadows.meshFor(lib, def, frame)
  if not (lib and def and type(def.image) == "string") then
    return nil, "bad args"
  end
  frame = frame or 0
  local key = meshCacheKey(def.image, frame, "matrix", VoxelWaterShadows.MESH_FRAME,
    VoxelWaterShadows.MESH_FRAME)
  local hit = meshCache[key]
  if hit ~= nil then
    return hit, key
  end

  local okSB, SpriteBillboards = pcall(lib.require, "SpriteBillboards")
  if not (okSB and SpriteBillboards and type(SpriteBillboards.mesh) == "function") then
    return nil, "SpriteBillboards.mesh missing"
  end
  local okM, mesh = pcall(SpriteBillboards.mesh, def, frame)
  if not (okM and mesh) then
    return nil, "mesh nil"
  end
  meshCache[key] = mesh
  return mesh, key
end

-- Horizontal world transform. Pivot = cell centre. No billboard / FP yaw.
function VoxelWaterShadows.horizontalMatrix(Mat4, worldX, shadowY, worldZ, width, depth, mirror)
  local frame = VoxelWaterShadows.MESH_FRAME
  local sx = (mirror and -1 or 1) * ((width or frame) / frame)
  local sy = (depth or frame) / frame
  local m = Mat4.translate(worldX, shadowY, worldZ)
  m = Mat4.mul(m, Mat4.rotateX(-math.pi / 2))
  m = Mat4.mul(m, Mat4.scale(sx, sy, 1))
  -- Centre the 16×16 local XY card (not feet) so facing/mirror does not swing.
  return Mat4.mul(m, Mat4.translate(-frame * 0.5, -frame * 0.5, 0))
end

local function resolveTexture(lib, sprite, def, colors)
  local tex = sprite and sprite.resolveImage and sprite:resolveImage() or nil
  if colors and def and not def.trueColor then
    local okTA, TerrainAtlas = pcall(lib.require, "TerrainAtlas")
    if okTA and TerrainAtlas and type(TerrainAtlas.forSprite) == "function" then
      tex = TerrainAtlas.forSprite(def.image, colors) or tex
    end
  end
  if tex then return tex end
  -- Hidden single-image path: load via Assets.image when no SpriteRenderer.
  local okA, Assets = pcall(require, "src.Assets")
  if okA and Assets and type(Assets.image) == "function" and def and def.image then
    local okI, img = pcall(Assets.image, def.image)
    if okI and img then return img end
  end
  if lib then
    local okA2, Assets2 = pcall(lib.require, "Assets")
    if okA2 and Assets2 and type(Assets2.image) == "function" and def and def.image then
      local okI, img = pcall(Assets2.image, def.image)
      if okI and img then return img end
    end
  end
  return nil
end

function VoxelWaterShadows.quadSizeFor(kind)
  if kind == "hidden" then
    return VoxelWaterShadows.HIDDEN_WIDTH, VoxelWaterShadows.HIDDEN_DEPTH
  end
  return VoxelWaterShadows.SPECIES_WIDTH, VoxelWaterShadows.SPECIES_DEPTH
end

function VoxelWaterShadows.drawEntityShadow(lib, entity, opts)
  opts = opts or {}
  if not (lib and entity) then return false, "bad args" end
  local okV3, Voxel3D = pcall(lib.require, "Voxel3D")
  local okM4, Mat4 = pcall(lib.require, "Mat4")
  if not (okV3 and Voxel3D and type(Voxel3D.draw) == "function") then
    return false, "Voxel3D.draw missing"
  end
  if not (okM4 and Mat4 and type(Mat4.translate) == "function") then
    return false, "Mat4 missing"
  end

  local sprite = entity.getWorldSprite and entity:getWorldSprite() or entity.sprite
  local def = sprite and sprite.def
  if not VoxelWaterShadows.isWaterShadowDef(def) and entity.voxelWaterShadowPresentation then
    -- Presentation flag set but def not tagged yet — still try sprite def.
    def = def or entity._voxelWaterShadowDef
  end
  if not def then
    return false, "no def"
  end

  local facing = entity.facing or "down"
  local phase = 0
  local flip = entity.stepFlip == true
  if type(entity.pose) == "function" then
    local okP, poseSprite, _vx, _vy, pFacing, pPhase, pFlip = pcall(entity.pose, entity)
    if okP and poseSprite then
      sprite = poseSprite
      def = poseSprite.def or def
      facing = pFacing or facing
      phase = pPhase or phase
      flip = pFlip == true
    end
  else
    local Movement = V.require("movement")
    if Movement and type(Movement.walkPhase) == "function" then
      phase = Movement.walkPhase(entity) or 0
    end
  end

  local frame, mirror = VoxelWaterShadows.frameFor(def, facing, phase, flip)
  local mesh, meshKey = VoxelWaterShadows.meshFor(lib, def, frame)
  if not mesh then
    return false, meshKey or "mesh failed"
  end

  local tex = resolveTexture(lib, sprite, def, opts.colors)
  if not tex then
    return false, "texture nil"
  end

  local kind = VoxelWaterShadows.kindFor(def) or "silhouette"
  local width, depth = VoxelWaterShadows.quadSizeFor(kind)
  if kind == "hidden" and VoxelWaterShadows.HIDDEN_PULSE_AMP > 0 then
    local t = 0
    if love and love.timer and love.timer.getTime then
      t = love.timer.getTime()
    end
    local pulse = 1 + math.sin(t * 2.4 + (entity.cellX or 0) * 0.7)
      * VoxelWaterShadows.HIDDEN_PULSE_AMP
    width = width * pulse
    depth = depth * pulse
  end

  local worldX = (entity.px or 0) + 8
  local worldZ = (entity.py or 0) + 8
  local surfaceY, surfaceSrc = VoxelWaterShadows.waterSurfaceAt(
    opts.map, entity.cellX, entity.cellY, {
      lib = lib,
      groundHeight = opts.groundHeight,
    })
  local shadowY = surfaceY + VoxelWaterShadows.SURFACE_EPSILON

  local model = VoxelWaterShadows.horizontalMatrix(
    Mat4, worldX, shadowY, worldZ, width, depth, mirror)

  -- No character pull distance, no sun/drop shadow (already a shadow form).
  local pull = 0
  local sunModel = nil
  local okDraw, err = pcall(Voxel3D.draw, mesh, tex, model, pull, sunModel)
  if not okDraw then
    return false, err
  end

  entity._voxelWaterShadowDiag = {
    presentation = kind == "hidden"
      and VoxelWaterShadows.PRESENTATION.HIDDEN_WORLD_QUAD
      or VoxelWaterShadows.PRESENTATION.SPECIES_WORLD_QUAD,
    texture = def.image,
    frame = frame,
    mirror = mirror,
    waterSurfaceY = surfaceY,
    waterSurfaceSource = surfaceSrc,
    shadowY = shadowY,
    width = width,
    depth = depth,
    meshKey = meshKey,
    depthPass = "VOXEL3D_DEPTH",
    characterBodyFiltered = entity.voxelWaterShadowPresentation == true,
  }
  return true
end

function VoxelWaterShadows.collectEntities(state, logic, mod)
  local WaterDisplay = V.require("water_display")
  local list = {}
  local seen = {}

  local function consider(e)
    if not e or seen[e] then return end
    if e.overworldWildSpawn ~= true then return end
    if e.state == "removed" then return end
    if e.hiddenEncounter or e.visibleSprite == false then return end
    if not WaterDisplay.isWaterEntity(e) then return end
    local mode = WaterDisplay.mode(mod)
    if mode ~= WaterDisplay.MODE.HIDDEN_SILHOUETTES
       and mode ~= WaterDisplay.MODE.SILHOUETTES then
      return
    end
    seen[e] = true
    list[#list + 1] = e
  end

  if type(state and state.entities) == "table" then
    for _, e in ipairs(state.entities) do consider(e) end
  end
  -- Fallback only when the DS state list is unavailable.
  if #list == 0 and logic and logic.entities then
    for _, e in pairs(logic.entities) do
      if e.registeredInWorld then consider(e) end
    end
  end

  -- Stable back-to-front by world Z for alpha blending (depth still primary).
  table.sort(list, function(a, b)
    local az, bz = a.py or 0, b.py or 0
    if az == bz then return (a.px or 0) < (b.px or 0) end
    return az > bz
  end)
  return list
end

function VoxelWaterShadows.shouldFilterCharacterBody(entity, mod)
  if not entity or entity.overworldWildSpawn ~= true then return false end
  -- Prefer the explicit render flag (no AI / visibility side effects).
  if entity.voxelWaterShadowPresentation == true then return true end
  -- Without a mod handle, do not infer from Water Mons mode.
  if not mod then return false end
  local WaterDisplay = V.require("water_display")
  if not WaterDisplay.isWaterEntity(entity) then return false end
  return WaterDisplay.isHiddenSilhouettes(mod) or WaterDisplay.isSilhouettes(mod)
end

function VoxelWaterShadows.markPresentation(entity, mod, voxelActive)
  if not entity then return end
  local WaterDisplay = V.require("water_display")
  local shadow = voxelActive == true
    and WaterDisplay.needsWaterShadowPresentation(mod, entity)
  entity.voxelWaterShadowPresentation = shadow == true
  entity.voxelWaterPresentation = VoxelWaterShadows.presentationFor(mod, entity, voxelActive)
  if shadow then
    entity.shadowRendererMode = WaterDisplay.isHiddenSilhouettes(mod)
      and VoxelWaterShadows.MODE.HIDDEN_WORLD_QUAD
      or VoxelWaterShadows.MODE.SPECIES_WORLD_QUAD
    -- Compat with prior flat_world label in cache keys / HUD.
    entity.shadowRendererModeLegacy = VoxelWaterShadows.FLAT_WORLD
  else
    entity.shadowRendererMode = VoxelWaterShadows.MODE.NONE
    if WaterDisplay.isWaterEntity(entity) and WaterDisplay.isSwimmingSprites(mod)
       and voxelActive then
      entity.voxelWaterPresentation = VoxelWaterShadows.PRESENTATION.SWIMMING_CHARACTER
    end
  end
end

function VoxelWaterShadows.drawPass(adapter, state)
  if not adapter or not adapter._voxelWaterShadowsOk then return 0 end
  local lib = dsLib(adapter.mod)
  if not lib then return 0 end

  local entities = VoxelWaterShadows.collectEntities(state, adapter.logic, adapter.mod)
  local drawn = 0
  local map = state and state.map
  local groundFn = nil
  if state and type(state.groundAt) == "function" then
    groundFn = state.groundAt
  end

  for _, entity in ipairs(entities) do
    local gh = nil
    if groundFn and entity.cellX and entity.cellY then
      local ok, y = pcall(groundFn, map, entity.cellX, entity.cellY)
      if ok and type(y) == "number" then gh = y end
    end
    local ok = select(1, VoxelWaterShadows.drawEntityShadow(lib, entity, {
      map = map,
      groundHeight = gh,
      colors = state and state.colors,
    }))
    if ok then
      drawn = drawn + 1
      local d = entity.renderDiagnostics
      if type(d) == "table" then
        d.voxelWaterShadowDraws = (d.voxelWaterShadowDraws or 0) + 1
      end
    end
  end
  return drawn
end

-- Install drawEntity safety + asset invalidation. The VoxelScene.render wrap
-- (character-body filter + shadow pass) lives in VoxelAdapter:ensureHooks so
-- we never double-wrap the same function.
function VoxelWaterShadows.installHooks(adapter)
  if not adapter or adapter._voxelWaterShadowsHooked then
    return adapter and adapter._voxelWaterShadowsOk == true
  end
  adapter._voxelWaterShadowsHooked = true
  adapter._voxelWaterShadowsOk = false

  local lib = dsLib(adapter.mod)
  if not lib then return false end

  local okScene, VoxelScene = pcall(lib.require, "VoxelScene")
  if not (okScene and VoxelScene) then
    return false
  end

  -- Asset reload hook when DS exports one.
  local okAssets, Assets = pcall(lib.require, "Assets")
  if okAssets and Assets and type(Assets.onInvalidate) == "function"
     and not Assets._owwildWaterShadowInvalidate then
    Assets._owwildWaterShadowInvalidate = true
    pcall(Assets.onInvalidate, function()
      VoxelWaterShadows.invalidateCache()
    end)
  end

  -- Safety: if a tagged def still reaches drawEntity, draw the horizontal
  -- world quad — never fall back to an upright character billboard.
  if type(VoxelScene.drawEntity) == "function"
     and not VoxelScene._owwildWaterShadowDrawWrapped then
    local origDraw = VoxelScene.drawEntity
    VoxelScene.drawEntity = function(sprite, px, py, facing, phase, flip, gh, colors, lift)
      local def = sprite and sprite.def
      if VoxelWaterShadows.isWaterShadowDef(def) then
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
        local ok = select(1, VoxelWaterShadows.drawEntityShadow(lib, entity, {
          groundHeight = gh,
          colors = colors,
        }))
        if ok then return true end
        -- Do not draw upright. Skip rather than show a standing silhouette.
        return false
      end
      return origDraw(sprite, px, py, facing, phase, flip, gh, colors, lift)
    end
    VoxelScene._owwildWaterShadowDrawWrapped = true
  end

  adapter._voxelWaterShadowsOk = true
  if adapter.mod then
    pcall(DebugLog.info, adapter.mod,
      "VoxelWaterShadows: hooks ready (filter+pass via VoxelAdapter.render wrap)")
  end
  return true
end

-- ------------------------------------------------------------------ diagnostics

function VoxelWaterShadows.statusLines(entity)
  if not entity then return {} end
  local lines = {}
  local diag = entity._voxelWaterShadowDiag
  local presentation = entity.voxelWaterPresentation
    or (diag and diag.presentation)
    or "?"
  lines[#lines + 1] = ("Water display mode: %s"):format(
    tostring(entity.waterDisplayMode or "?"))
  lines[#lines + 1] = ("Voxel water presentation: %s"):format(tostring(presentation))
  lines[#lines + 1] = ("Character body filtered: %s"):format(
    entity.voxelWaterShadowPresentation == true and "YES" or "NO")
  if diag then
    lines[#lines + 1] = ("Shadow texture: %s"):format(tostring(diag.texture or "?"))
    lines[#lines + 1] = ("Shadow frame: %s"):format(tostring(diag.frame or "?"))
    lines[#lines + 1] = ("Shadow mirror: %s"):format(
      diag.mirror and "YES" or "NO")
    lines[#lines + 1] = ("Water surface Y: %s (%s)"):format(
      tostring(diag.waterSurfaceY), tostring(diag.waterSurfaceSource or "?"))
    lines[#lines + 1] = ("Shadow Y: %s"):format(tostring(diag.shadowY))
    lines[#lines + 1] = ("World quad size: %sx%s"):format(
      tostring(diag.width), tostring(diag.depth))
    lines[#lines + 1] = ("Depth pass: %s"):format(tostring(diag.depthPass or "?"))
  elseif entity.voxelWaterShadowPresentation then
    lines[#lines + 1] = "Depth pass: PENDING"
  end
  return lines
end

return VoxelWaterShadows
