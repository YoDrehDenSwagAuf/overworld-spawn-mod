-- Dramatic Shape integration: wild Pokemon as depth-sorted world billboards.
--
-- Primary path (successful):
--   entity stays in ow.entities → posesOf → SpriteBillboards
--   pose() returns a native SpriteRenderer (frames=6, walker=true)
--   def.image is a static 16×96 follow-sprite runtime sheet
--   Same depth / object occlusion / native grass as player and trainers.
--
-- Emergency only:
--   SPATIAL_OVERLAY_EMERGENCY draws Entity:draw via ctx.drawFx (no depth).
--
-- Alert icons stay on the engine emote / drawFx path (not Pokemon bodies).
local V = ...
local DebugLog = V.require("debug_log")
local Movement = V.require("movement")
local Config = V.require("config")
local RenderDiagnostics = V.require("render_diagnostics")

local VoxelAdapter = {}
VoxelAdapter.__index = VoxelAdapter

VoxelAdapter.WORLD_RENDERER = "DRAMATIC_SHAPE"
VoxelAdapter.POKEMON_NATIVE = "NATIVE_SPRITE_RENDERER"
VoxelAdapter.POKEMON_WORLD_ENHANCED = "WORLD_BILLBOARD_ENHANCED" -- deprecated
VoxelAdapter.POKEMON_WORLD_LEGACY = "WORLD_BILLBOARD_LEGACY"
VoxelAdapter.POKEMON_WORLD_BLACK = "WORLD_BILLBOARD_BLACK_FALLBACK"
VoxelAdapter.POKEMON_OVERLAY_EMERGENCY = "SPATIAL_OVERLAY_EMERGENCY"
-- Alias for older call sites / tests.
VoxelAdapter.POKEMON_OVERLAY_FALLBACK = VoxelAdapter.POKEMON_OVERLAY_EMERGENCY

function VoxelAdapter.new(mod)
  local self = setmetatable({}, VoxelAdapter)
  self.mod = mod
  self.present = false
  self.hooksInstalled = false
  self.voxelActive = false
  self.logic = nil
  return self
end

function VoxelAdapter:attachLogic(logic)
  self.logic = logic
end

function VoxelAdapter:refreshPresence()
  local dramatic = self.mod.find and self.mod.find("DRAMATIC_SHAPE")
  self.present = dramatic ~= nil
  if self.present then
    self:ensureHooks()
    local WaterShadowRenderer = V.require("water_shadow_renderer")
    WaterShadowRenderer.installDrawHook(self)
  end
  self.voxelActive = self:_probeVoxelActive()
  return self.present
end

function VoxelAdapter:isPresent()
  if self.present then return true end
  return self:refreshPresence()
end

function VoxelAdapter:_probeVoxelActive()
  local ds = self.mod.find and self.mod.find("DRAMATIC_SHAPE")
  local lib = ds and ds.exports and ds.exports.lib
  if not lib or type(lib.require) ~= "function" then return false end
  local ok, Voxel = pcall(lib.require, "VoxelState")
  if not ok or not Voxel or type(Voxel.active) ~= "function" then
    return false
  end
  local okActive, active = pcall(Voxel.active)
  return okActive and active == true
end

function VoxelAdapter:isVoxelCameraActive()
  if not self.present then
    self:refreshPresence()
  end
  return self:_probeVoxelActive()
end

function VoxelAdapter.isWildEntity(entity)
  return entity ~= nil and entity.overworldWildSpawn == true
end

local function isWorldBillboard(renderer)
  return renderer == VoxelAdapter.POKEMON_NATIVE
    or renderer == VoxelAdapter.POKEMON_WORLD_ENHANCED
    or renderer == VoxelAdapter.POKEMON_WORLD_LEGACY
    or renderer == VoxelAdapter.POKEMON_WORLD_BLACK
end

local function isEmergencyOverlay(renderer)
  return renderer == VoxelAdapter.POKEMON_OVERLAY_EMERGENCY
    or renderer == "SPATIAL_OVERLAY_FALLBACK"
end

function VoxelAdapter.isPoseSafe(entity)
  if not entity then
    return false, "nil entity"
  end
  if entity.hiddenEncounter or entity.visibleSprite == false then
    return false, "hidden entity must not join ow.entities for Voxel"
  end
  local sprite = entity.getWorldSprite and entity:getWorldSprite() or entity.sprite
  if sprite == nil then
    return false, "sprite is nil"
  end
  if sprite.def == nil then
    return false, "sprite.def missing"
  end
  if type(sprite.resolveImage) ~= "function" then
    return false, "sprite:resolveImage missing"
  end
  if type(entity.pose) ~= "function" then
    return false, "entity:pose missing"
  end
  if entity.px == nil or entity.py == nil then
    return false, "px/py missing"
  end
  if entity.cellX == nil or entity.cellY == nil then
    return false, "cellX/cellY missing"
  end
  if type(entity.px) ~= "number" or type(entity.py) ~= "number" then
    return false, "px/py not numeric"
  end
  if type(entity.cellX) ~= "number" or type(entity.cellY) ~= "number" then
    return false, "cellX/cellY not numeric"
  end
  return true
end

function VoxelAdapter.probePose(entity)
  local okSafe, why = VoxelAdapter.isPoseSafe(entity)
  if not okSafe then return false, why end
  local ok, sprite, vx, vy = pcall(function()
    return entity:pose()
  end)
  if not ok then
    return false, "pose() threw: " .. tostring(sprite)
  end
  if sprite == nil then
    return false, "pose() returned nil sprite"
  end
  if sprite.def == nil then
    return false, "pose() sprite.def nil"
  end
  if type(sprite.resolveImage) ~= "function" then
    return false, "pose() sprite lacks resolveImage"
  end
  return true, {
    sprite = sprite,
    px = vx,
    py = entity.py,
    lift = entity.py - (vy or entity.py),
  }
end

function VoxelAdapter:markFallback(entity, err)
  if not entity then return end
  entity.voxelLastError = tostring(err)
  entity.pokemonRenderer = VoxelAdapter.POKEMON_OVERLAY_EMERGENCY
  entity.depthIntegration = "INACTIVE"
  entity.objectOcclusion = "INACTIVE"
  entity.dramaticBillboardSkipped = true
  entity.voxelDisabled = true
  entity.render2DFallback = true
  entity.worldBillboardReady = false
  entity.worldSpriteAdapterStatus = "EMERGENCY"
  entity.grassRenderer = "EMERGENCY_OVERLAY"
  -- Preserve the intended asset source label (do not invent a new one).
  entity.spriteSource2D = entity.spriteSource2D
    or entity.spriteSource
    or (entity.nativeSpriteRenderer and "FOLLOW_SPRITES")
    or (entity.usingEnhancedSprite and "FOLLOW_SPRITES")
    or (entity.usingFallback and "BLACK_FALLBACK")
    or "LEGACY_PNG"
  pcall(DebugLog.warn, self.mod,
    "World billboard failed for %s; spatial overlay emergency. (%s)",
    tostring(entity.id or entity.spawnId or "?"),
    tostring(err))
end

function VoxelAdapter:updateEntity(entity)
  if not entity or entity.state == "removed" then return false end
  if entity.hiddenEncounter or entity.visibleSprite == false then
    entity.voxelRegistered = false
    entity.dramaticBillboardSkipped = false
    entity.pokemonRenderer = "HIDDEN"
    entity.worldRenderer = "GEN1_FLAT"
    entity.depthIntegration = "N/A"
    entity.objectOcclusion = "N/A"
    entity.grassRenderer = "N/A"
    return false
  end

  local okMove, moveErr = pcall(Movement.syncLegacyFields, entity)
  if not okMove then
    self:markFallback(entity, moveErr)
    return false
  end

  local active = self:isVoxelCameraActive()
  self.voxelActive = active

  entity.spriteSource2D = entity.spriteSource
    or (entity.usingEnhancedSprite and "FOLLOW_SPRITES")
    or (entity.usingFallback and "BLACK_FALLBACK")
    or "LEGACY_PNG"
  entity.voxelScale = 1

  -- Voxel Hidden / Silhouettes: native SpriteRenderer sheets drawn as flat
  -- underwater shadows via WaterShadowRenderer (wraps VoxelScene.drawEntity).
  -- Flat 2D keeps the circle / tint paths untouched.
  local WaterDisplay = V.require("water_display")
  local WaterShadowRenderer = V.require("water_shadow_renderer")
  WaterShadowRenderer.installDrawHook(self)
  local waterShadow = WaterDisplay.needsWaterShadowPresentation(self.mod, entity)

  if not active then
    entity.worldRenderer = "GEN1_FLAT"
    entity.pokemonRenderer = "WILDS_2D"
    entity.dramaticBillboardSkipped = false
    entity.voxelRegistered = false
    entity.depthIntegration = "N/A"
    entity.objectOcclusion = "N/A"
    entity.grassRenderer = "ENGINE_2D"
    entity.voxelUpdateOk = true
    entity.voxelSource = entity.spriteSource2D
    entity.waterPresentationForced = nil
    entity.shadowRendererMode = WaterShadowRenderer.MODE.NONE
    -- Leaving Voxel: restore colour water sheet / drop hidden marker.
    if (entity.waterSilhouetteSheet == true or entity.waterHiddenShadow == true)
       and entity.render and entity.render.applyProviderSprite then
      local game = self.mod.world and self.mod.world.game
      pcall(entity.render.applyProviderSprite, entity.render, entity, game)
    end
    return true
  end

  entity.waterPresentationForced = nil

  -- Bind Hidden marker or Silhouette sheet once when entering Voxel / mode.
  -- No respawn; at most one targeted rebind per entity.
  if waterShadow then
    local needRebind = (entity.waterVoxelActive ~= true)
      or (WaterDisplay.isSilhouettes(self.mod) and entity.waterSilhouetteSheet ~= true)
      or (WaterDisplay.isHiddenSilhouettes(self.mod) and entity.waterHiddenShadow ~= true)
    if needRebind and entity.render and entity.render.applyProviderSprite then
      local game = self.mod.world and self.mod.world.game
      pcall(entity.render.applyProviderSprite, entity.render, entity, game)
    end
    entity.shadowRendererMode = self._waterShadowDrawOk
      and WaterShadowRenderer.MODE.FLAT_WORLD
      or WaterShadowRenderer.MODE.UPRIGHT_FALLBACK
  elseif (entity.waterSilhouetteSheet == true or entity.waterHiddenShadow == true)
     and entity.render and entity.render.applyProviderSprite then
    -- Left silhouettes / hidden mode while still in Voxel: restore colour sheet.
    local game = self.mod.world and self.mod.world.game
    pcall(entity.render.applyProviderSprite, entity.render, entity, game)
    entity.shadowRendererMode = WaterShadowRenderer.MODE.NONE
  else
    entity.shadowRendererMode = WaterShadowRenderer.MODE.NONE
  end

  entity.worldRenderer = VoxelAdapter.WORLD_RENDERER

  -- Bind / refresh native SpriteRenderer for DS SpriteBillboards.
  if entity.render and entity.render.bindWorldBillboard then
    local okBind, why = pcall(entity.render.bindWorldBillboard,
                              entity.render, entity, false)
    if not okBind then
      self:markFallback(entity, why)
      entity.voxelRegistered = true
      entity.voxelUpdateOk = false
      return false
    end
  end

  local okPose, detail = VoxelAdapter.probePose(entity)
  if not okPose then
    self:markFallback(entity, detail)
    entity.voxelRegistered = true
    entity.voxelUpdateOk = false
    return false
  end

  if not isWorldBillboard(entity.pokemonRenderer)
     and not isEmergencyOverlay(entity.pokemonRenderer) then
    entity.pokemonRenderer = entity.nativeSpriteRenderer
      and VoxelAdapter.POKEMON_NATIVE
      or (entity.usingFallback and VoxelAdapter.POKEMON_WORLD_BLACK
          or VoxelAdapter.POKEMON_WORLD_LEGACY)
  end

  if isWorldBillboard(entity.pokemonRenderer) then
    -- Promote UNVERIFIED → ACTIVE only when counters prove DS path.
    if RenderDiagnostics.honestDepthActive(entity) then
      entity.depthIntegration = "ACTIVE"
      entity.objectOcclusion = "ACTIVE"
      entity.grassRenderer = "DRAMATIC_SHAPE_NATIVE"
    elseif entity.depthIntegration ~= "INACTIVE" then
      entity.depthIntegration = entity.depthIntegration or "UNVERIFIED"
      entity.objectOcclusion = entity.objectOcclusion or "UNVERIFIED"
      entity.grassRenderer = entity.grassRenderer or "UNVERIFIED"
    end
    entity.dramaticBillboardSkipped = false
  else
    entity.depthIntegration = "INACTIVE"
    entity.objectOcclusion = "INACTIVE"
    entity.dramaticBillboardSkipped = true
    if isEmergencyOverlay(entity.pokemonRenderer) then
      entity.grassRenderer = "EMERGENCY_OVERLAY"
    end
  end

  entity.voxelRegistered = true
  entity.voxelUpdateOk = true
  entity.voxelDisabled = false
  entity.voxelSource = entity.spriteSource2D
  return true
end

function VoxelAdapter:unregister(entity)
  if not entity then return end
  entity.voxelRegistered = false
  entity.voxelUpdateOk = false
end

-- ------------------------------------------------------------------ hooks

local function filterOverlayEmergencyEntities(entities)
  local kept = {}
  for _, e in ipairs(entities or {}) do
    local d = RenderDiagnostics.ensure(e)
    local isEmerg = VoxelAdapter.isWildEntity(e) and isEmergencyOverlay(e.pokemonRenderer)
    if isEmerg then
      d.dramaticBillboardRejected = (d.dramaticBillboardRejected or 0) + 1
      d.lastFilterKept = false
      d.lastFailureReason = d.lastFailureReason
        or ("filtered from posesOf: " .. tostring(e.pokemonRenderer))
    else
      if VoxelAdapter.isWildEntity(e) then
        d.dramaticBillboardAccepted = (d.dramaticBillboardAccepted or 0) + 1
        d.lastFilterKept = true
      end
      kept[#kept + 1] = e
    end
  end
  return kept
end

function VoxelAdapter:ensureHooks()
  if self.hooksInstalled then return true end

  local ds = self.mod.find and self.mod.find("DRAMATIC_SHAPE")
  local lib = ds and ds.exports and ds.exports.lib
  if lib and type(lib.require) == "function" then
    local okScene, VoxelScene = pcall(lib.require, "VoxelScene")
    if okScene and VoxelScene and type(VoxelScene.render) == "function"
       and not VoxelScene._owwildRenderWrapped then
      local origRender = VoxelScene.render
      VoxelScene.render = function(state, w, h, vw, vh, paletteFor)
        local prev = state and state.entities
        if state and prev then
          state.entities = filterOverlayEmergencyEntities(prev)
        end
        local ok, canvasOrErr = pcall(origRender, state, w, h, vw, vh, paletteFor)
        if state then state.entities = prev end
        if not ok then error(canvasOrErr, 0) end
        return canvasOrErr
      end
      VoxelScene._owwildRenderWrapped = true
    end
  end

  local okPipe, Pipelines = pcall(require, "src.render.Pipelines")
  if not okPipe or not Pipelines or type(Pipelines.get) ~= "function" then
    return false
  end
  local def = Pipelines.get("voxel")
  if not def or type(def.drawWorld) ~= "function" then
    return false
  end
  if def._owwildDrawWrapped then
    self.hooksInstalled = true
    return true
  end

  local adapter = self
  local origDrawWorld = def.drawWorld
  def.drawWorld = function(ctx)
    local origDrawFx = ctx and ctx.drawFx
    if ctx then
      ctx.drawFx = function(project, scale)
        if type(origDrawFx) == "function" then
          origDrawFx(project, scale)
        end
        adapter:drawOverlayFallbackBodies(ctx, project, scale)
      end
    end
    return origDrawWorld(ctx)
  end
  def._owwildDrawWrapped = true

  self.hooksInstalled = true
  DebugLog.info(self.mod,
    "Voxel hooks: NATIVE_SPRITE_RENDERER in posesOf; overlay body only as emergency")
  return true
end

-- Draw Pokemon body ONLY when depth billboard failed for that entity.
-- Strict world-billboard debug disables this entirely.
function VoxelAdapter:drawOverlayFallbackBodies(ctx, project, scale)
  if RenderDiagnostics.strictEnabled(self.mod) then
    return
  end
  if type(project) ~= "function" then return end
  if not (love and love.graphics) then return end

  local state = ctx and ctx.state
  local cam = (ctx and ctx.cam) or (state and state.camera)
  if not cam then return end

  local list = {}
  local function consider(e)
    if VoxelAdapter.isWildEntity(e)
       and not e.hiddenEncounter
       and e.visibleSprite ~= false
       and e.state ~= "removed"
       and isEmergencyOverlay(e.pokemonRenderer) then
      list[#list + 1] = e
    end
  end

  if type(state and state.entities) == "table" then
    for _, e in ipairs(state.entities) do consider(e) end
  elseif self.logic and self.logic.entities then
    for _, e in pairs(self.logic.entities) do
      if e.registeredInWorld then consider(e) end
    end
  end

  table.sort(list, function(a, b)
    local ay, by = a.py or 0, b.py or 0
    if ay == by then return (a.px or 0) < (b.px or 0) end
    return ay < by
  end)

  scale = scale or (ctx and ctx.scale) or 1
  local camX, camY = cam.x or 0, cam.y or 0

  for _, entity in ipairs(list) do
    local d = RenderDiagnostics.ensure(entity)
    d.emergencyOverlayBodyDrawCalls = (d.emergencyOverlayBodyDrawCalls or 0) + 1
    local wx = (entity.px or 0) + 8
    local wy = (entity.py or 0) + 16
    local sx, sy, depthScale = project(wx, wy)
    if sx then
      entity._overlayScreenX = sx
      entity._overlayScreenY = sy
      entity._overlayDepth = depthScale
      local fx, fy = wx - camX, wy - camY
      love.graphics.push()
      love.graphics.scale(scale, scale)
      love.graphics.translate(sx / scale - fx, sy / scale - fy)
      pcall(function() entity:draw(camX, camY) end)
      love.graphics.pop()
    end
  end
end

function VoxelAdapter.statusLines(entity)
  if not entity then return {} end
  local lines = {}
  local sprite = entity.getWorldSprite and entity:getWorldSprite() or entity.sprite
  local def = sprite and sprite.def
  lines[#lines + 1] = ("Body renderer: %s"):format(
    tostring(entity.pokemonRenderer or "?"))
  if def then
    lines[#lines + 1] = ("Sprite sheet: %s"):format(tostring(def.image or "?"))
    lines[#lines + 1] = ("Sprite frames: %s"):format(tostring(def.frames or "?"))
    lines[#lines + 1] = ("Walker: %s"):format(def.walker and "true" or "false")
  end
  lines[#lines + 1] = ("Facing: %s"):format(tostring(entity.facing or "?"))
  lines[#lines + 1] = ("Phase: %s"):format(tostring(entity.phase or Movement.walkPhase(entity)))
  lines[#lines + 1] = ("Flip: %s"):format(tostring(entity.stepFlip == true))
  lines[#lines + 1] = ("In ow.entities: %s"):format(
    entity.registeredInWorld and "YES" or "NO")
  lines[#lines + 1] = ("Dramatic Shape pose accepted: %s"):format(
    entity.renderDiagnostics and entity.renderDiagnostics.lastFilterKept == true
      and "YES"
      or (entity.renderDiagnostics and entity.renderDiagnostics.lastFilterKept == false
          and "NO" or "?"))
  lines[#lines + 1] = ("Overlay body draw: %s"):format(
    (entity.pokemonRenderer == VoxelAdapter.POKEMON_OVERLAY_EMERGENCY
      or entity.pokemonRenderer == "SPATIAL_OVERLAY_FALLBACK") and "YES" or "NO")
  lines[#lines + 1] = ("First person compatible: %s"):format(
    entity.nativeSpriteRenderer and "NATIVE" or "LEGACY")
  for _, line in ipairs(RenderDiagnostics.statusLines(entity)) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = ("World renderer: %s"):format(
    tostring(entity.worldRenderer or "GEN1_FLAT"))
  lines[#lines + 1] = ("World sprite adapter: %s"):format(
    tostring(entity.worldSpriteAdapterStatus or "N/A"))
  lines[#lines + 1] = ("Dramatic Shape entity registered: %s"):format(
    entity.voxelRegistered and "YES" or "NO")
  lines[#lines + 1] = ("Depth integration: %s"):format(
    tostring(entity.depthIntegration or "N/A"))
  lines[#lines + 1] = ("Object occlusion: %s"):format(
    tostring(entity.objectOcclusion or "N/A"))
  lines[#lines + 1] = ("Grass renderer: %s"):format(
    tostring(entity.grassRenderer or "N/A"))
  lines[#lines + 1] = ("Dramatic billboard skipped: %s"):format(
    entity.dramaticBillboardSkipped and "YES" or "NO")
  lines[#lines + 1] = ("Sprite source: %s"):format(
    tostring(entity.spriteSource2D or entity.spriteSource or "?"))
  if entity._lastLift ~= nil then
    lines[#lines + 1] = ("Lift: %s"):format(tostring(entity._lastLift))
  end
  if entity._lastVisualY ~= nil then
    lines[#lines + 1] = ("Visual Y: %s"):format(tostring(entity._lastVisualY))
  end
  return lines
end

return VoxelAdapter
