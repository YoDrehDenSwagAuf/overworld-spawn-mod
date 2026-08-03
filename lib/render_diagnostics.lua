-- Runtime render-path counters. Increment only at real call sites.
-- HUD must derive Actual body renderer from these, not from wishful status.
local V = ...
local Config = V.require("config")

local RenderDiagnostics = {}

function RenderDiagnostics.ensure(entity)
  if not entity then return nil end
  local d = entity.renderDiagnostics
  if type(d) ~= "table" then
    d = {
      poseCalls = 0,
      enhancedResolveImageCalls = 0,
      dramaticBillboardAccepted = 0,
      dramaticBillboardRejected = 0,
      dramaticBillboardDrawAttempts = 0,
      meshOkObservations = 0,
      meshFailObservations = 0,
      postVoxelBodyDrawCalls = 0,
      emergencyOverlayBodyDrawCalls = 0,
      entityDrawBodyCalls = 0,
      animatedSpriteDrawCalls = 0,
      legacySpriteDrawCalls = 0,
      lastResolvedImage = nil,
      lastResolvedW = nil,
      lastResolvedH = nil,
      lastResolvedType = nil,
      lastPoseSpriteType = nil,
      lastDefImage = nil,
      lastMeshKey = nil,
      lastMeshOk = nil,
      lastFailureReason = nil,
      lastActualRenderer = "UNKNOWN",
      lastFilterKept = nil,
      assetsImageOk = nil,
      assetsImageError = nil,
    }
    entity.renderDiagnostics = d
  end
  return d
end

function RenderDiagnostics.resetFrameCounters(entity)
  -- Keep cumulative totals; optional per-second sample fields live on entity.
  local d = RenderDiagnostics.ensure(entity)
  return d
end

function RenderDiagnostics.spriteTypeName(sprite)
  if sprite == nil then return "nil" end
  local mt = getmetatable(sprite)
  if mt and mt.__name then return tostring(mt.__name) end
  if sprite._owwildEnhancedWorldSprite then return "EnhancedWorldSprite" end
  if sprite.def and sprite.frames and sprite.resolveImage then
    return "SpriteRendererLike"
  end
  return type(sprite)
end

function RenderDiagnostics.describeImage(image)
  if image == nil then
    return { typeName = "nil", w = nil, h = nil }
  end
  local typeName = type(image)
  if type(image.type) == "function" then
    local ok, t = pcall(image.type, image)
    if ok then typeName = tostring(t) end
  end
  local w, h = nil, nil
  if type(image.getDimensions) == "function" then
    local ok, aw, ah = pcall(image.getDimensions, image)
    if ok then w, h = aw, ah end
  elseif type(image.getWidth) == "function" then
    local okw, aw = pcall(image.getWidth, image)
    local okh, ah = pcall(image.getHeight, image)
    if okw then w = aw end
    if okh then h = ah end
  end
  return { typeName = typeName, w = w, h = h, ref = image }
end

function RenderDiagnostics.probeAssetsImage(path)
  if type(path) ~= "string" or path == "" then
    return false, "empty def.image path"
  end
  local okAssets, Assets = pcall(require, "src.render.Assets")
  if not okAssets or not Assets or type(Assets.image) ~= "function" then
    return false, "Assets.image unavailable"
  end
  local ok, imgOrErr = pcall(Assets.image, path)
  if not ok then
    return false, "Assets.image error: " .. tostring(imgOrErr)
  end
  if not imgOrErr then
    return false, "Assets.image returned nil for " .. path
  end
  local dim = RenderDiagnostics.describeImage(imgOrErr)
  if dim.w ~= 16 or dim.h ~= 16 then
    -- Still usable for UV card if dimensions work; SpriteBillboards clamps.
    return true, nil, imgOrErr, dim
  end
  return true, nil, imgOrErr, dim
end

function RenderDiagnostics.probeMesh(def, frame)
  frame = frame or 0
  if not def or type(def.image) ~= "string" then
    return false, "def.image missing", nil
  end
  local key = def.image .. "#" .. tostring(frame)
  -- Prefer Dramatic Shape SpriteBillboards when the mod is loaded.
  local ds = nil
  if V.mod and type(V.mod.find) == "function" then
    ds = V.mod.find("DRAMATIC_SHAPE")
  end
  local lib = ds and ds.exports and ds.exports.lib
  if lib and type(lib.require) == "function" then
    local okSB, SpriteBillboards = pcall(lib.require, "SpriteBillboards")
    if okSB and SpriteBillboards and type(SpriteBillboards.mesh) == "function" then
      local okM, mesh = pcall(SpriteBillboards.mesh, def, frame)
      if okM and mesh then
        return true, nil, key, mesh
      end
      return false, "SpriteBillboards.mesh failed/nil", key, nil
    end
  end
  -- Without DS, still validate Assets.image for the carrier.
  local okA, errA = RenderDiagnostics.probeAssetsImage(def.image)
  if not okA then
    return false, errA or "Assets.image failed", key, nil
  end
  return true, "DS SpriteBillboards unavailable (Assets.image ok)", key, nil
end

function RenderDiagnostics.deriveActualBodyRenderer(entity)
  local d = RenderDiagnostics.ensure(entity)
  local emergency = (d.emergencyOverlayBodyDrawCalls or 0) > 0
  local entityDraw = (d.entityDrawBodyCalls or 0) > 0
    or (d.postVoxelBodyDrawCalls or 0) > 0
    or (d.animatedSpriteDrawCalls or 0) > 0
  local dsAttempt = (d.enhancedResolveImageCalls or 0) > 0
    or (d.dramaticBillboardDrawAttempts or 0) > 0
  local meshOk = (d.meshOkObservations or 0) > 0 and (d.lastMeshOk == true)
  local poseOk = (d.poseCalls or 0) > 0
  local kept = d.lastFilterKept == true
  local native = entity.pokemonRenderer == "NATIVE_SPRITE_RENDERER"
    or entity.nativeSpriteRenderer == true

  if emergency or (entityDraw and not meshOk and not native) then
    if (entity.pokemonRenderer == "SPATIAL_OVERLAY_EMERGENCY"
        or entity.pokemonRenderer == "SPATIAL_OVERLAY_FALLBACK")
       or (d.emergencyOverlayBodyDrawCalls or 0) > 0 then
      d.lastActualRenderer = "SPATIAL_OVERLAY_EMERGENCY"
      return d.lastActualRenderer
    end
    d.lastActualRenderer = "ENTITY_DRAW_OVERLAY"
    return d.lastActualRenderer
  end

  if poseOk and kept and not entityDraw and not emergency
     and (native or (dsAttempt and meshOk)) then
    d.lastActualRenderer = "DRAMATIC_SPRITE_BILLBOARD"
    return d.lastActualRenderer
  end

  if poseOk and kept and dsAttempt and meshOk and not entityDraw and not emergency then
    d.lastActualRenderer = "DRAMATIC_SPRITE_BILLBOARD"
    return d.lastActualRenderer
  end

  if poseOk and kept and dsAttempt and not meshOk then
    d.lastActualRenderer = "DRAMATIC_POSE_MESH_FAILED"
    d.lastFailureReason = d.lastFailureReason or "mesh failed after resolveImage"
    return d.lastActualRenderer
  end

  if poseOk and kept and not dsAttempt and not native then
    d.lastActualRenderer = "DRAMATIC_POSED_NOT_DRAWN"
    d.lastFailureReason = d.lastFailureReason or "pose kept but resolveImage not called"
    return d.lastActualRenderer
  end

  if d.lastFilterKept == false then
    d.lastActualRenderer = "FILTERED_FROM_POSESOF"
    return d.lastActualRenderer
  end

  if entity.pokemonRenderer == "WILDS_2D" or entity.worldRenderer == "GEN1_FLAT" then
    d.lastActualRenderer = "WILDS_2D"
    return d.lastActualRenderer
  end

  if native then
    d.lastActualRenderer = "NATIVE_SPRITE_RENDERER"
    return d.lastActualRenderer
  end

  d.lastActualRenderer = "UNKNOWN"
  return d.lastActualRenderer
end

function RenderDiagnostics.honestDepthActive(entity)
  local actual = RenderDiagnostics.deriveActualBodyRenderer(entity)
  return actual == "DRAMATIC_SPRITE_BILLBOARD"
end

function RenderDiagnostics.statusLines(entity)
  local d = RenderDiagnostics.ensure(entity)
  local actual = RenderDiagnostics.deriveActualBodyRenderer(entity)
  local lines = {
    ("Requested renderer: %s"):format(tostring(entity.pokemonRenderer or "?")),
    ("Actual body renderer: %s"):format(tostring(actual)),
    ("Pose calls: %s"):format(tostring(d.poseCalls or 0)),
    ("Enhanced resolveImage calls: %s"):format(
      tostring(d.enhancedResolveImageCalls or 0)),
    ("Dramatic billboard accepted: %s"):format(
      d.lastFilterKept == true and "YES"
        or (d.lastFilterKept == false and "NO" or "?")),
    ("Dramatic billboard draw attempts: %s"):format(
      tostring(d.dramaticBillboardDrawAttempts or 0)),
    ("Mesh OK observations: %s"):format(tostring(d.meshOkObservations or 0)),
    ("Post-voxel body draw calls: %s"):format(
      tostring(d.postVoxelBodyDrawCalls or 0)),
    ("Emergency overlay body draw calls: %s"):format(
      tostring(d.emergencyOverlayBodyDrawCalls or 0)),
    ("Entity:draw body calls: %s"):format(tostring(d.entityDrawBodyCalls or 0)),
    ("Animated sprite draw calls: %s"):format(
      tostring(d.animatedSpriteDrawCalls or 0)),
    ("Pose sprite type: %s"):format(tostring(d.lastPoseSpriteType or "?")),
    ("def.image: %s"):format(tostring(d.lastDefImage or "?")),
    ("Assets.image(def.image): %s"):format(
      d.assetsImageOk == true and "OK"
        or (d.assetsImageOk == false and ("FAIL " .. tostring(d.assetsImageError or ""))
            or "?")),
    ("Mesh key: %s"):format(tostring(d.lastMeshKey or "?")),
    ("Mesh OK: %s"):format(
      d.lastMeshOk == true and "YES"
        or (d.lastMeshOk == false and "NO" or "?")),
    ("Resolved image type: %s"):format(tostring(d.lastResolvedType or "?")),
    ("Resolved image size: %sx%s"):format(
      tostring(d.lastResolvedW or "?"), tostring(d.lastResolvedH or "?")),
  }
  if d.lastFailureReason then
    lines[#lines + 1] = ("Failure reason: %s"):format(
      tostring(d.lastFailureReason):sub(1, 72))
  end
  return lines
end

function RenderDiagnostics.strictEnabled(mod)
  local dev = false
  if type(Config.devMode) == "function" then
    local ok, v = pcall(Config.devMode, mod)
    dev = ok and v == true
  elseif mod and mod.options and type(mod.options.get) == "function" then
    dev = mod.options:get("dev_mode") == true
  end
  return dev and Config.get(mod, "strict_world_billboard_debug") == true
end

function RenderDiagnostics.magentaProbeEnabled(mod)
  return RenderDiagnostics.strictEnabled(mod)
     and Config.get(mod, "strict_magenta_billboard_probe") == true
end

return RenderDiagnostics
