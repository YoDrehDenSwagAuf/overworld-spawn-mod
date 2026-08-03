-- DEPRECATED for Pokemon body rendering (0.7.0+).
-- Kept for unit tests / emergency reference only.
-- Primary path: native SpriteRenderer + assets/generated/followsprites_runtime.
--
-- Historical note: Dramatic Shape reads sprite.def + sprite:resolveImage().
-- This adapter swapped per-frame 16×16 card Images; that path is no longer used.
local V = ...
local RenderDiagnostics = V.require("render_diagnostics")

local EnhancedWorldSprite = {}
EnhancedWorldSprite.__index = EnhancedWorldSprite
EnhancedWorldSprite.__name = "EnhancedWorldSprite"
EnhancedWorldSprite.DEPRECATED = true

-- Real UV carrier path MUST be set on def.image (Assets.image loads a file).
-- Never leave the synthetic key in production binds.
EnhancedWorldSprite.DEF_IMAGE_KEY = "__wilds_dynamic_billboard_16x16__"
EnhancedWorldSprite.BASE_ASSET_REL = "assets/runtime/dynamic_billboard_base.png"
EnhancedWorldSprite.CARD = 16

local magentaProbeImage = nil

local function ensureMagentaProbe()
  if magentaProbeImage then return magentaProbeImage end
  if not (love and love.graphics and love.image and love.image.newImageData) then
    return nil
  end
  local ok, img = pcall(function()
    local data = love.image.newImageData(16, 16)
    for y = 0, 15 do
      for x = 0, 15 do
        local cross = (x == y) or (x + y == 15) or x == 7 or y == 7
        if cross then
          data:setPixel(x, y, 0, 0, 0, 1)
        else
          data:setPixel(x, y, 1, 0, 1, 1)
        end
      end
    end
    local image = love.graphics.newImage(data)
    if image.setFilter then image:setFilter("nearest", "nearest") end
    return image
  end)
  if ok and img then
    magentaProbeImage = img
    return img
  end
  return nil
end

function EnhancedWorldSprite.new(opts)
  opts = opts or {}
  local self = setmetatable({}, EnhancedWorldSprite)
  self._owwildEnhancedWorldSprite = true
  self.entity = opts.entity
  self.animatedSprites = opts.animatedSprites
  self.legacySprite = opts.legacySprite
  self.baseImagePath = opts.baseImagePath
  if type(opts.baseImagePath) ~= "string" or opts.baseImagePath == "" then
    error("EnhancedWorldSprite requires a loadable baseImagePath for def.image", 2)
  end
  self.def = {
    image = opts.baseImagePath,
    frames = 1,
    trueColor = true,
    walker = nil,
    id = opts.id or "SPRITE_OW_WILD_ENHANCED",
  }
  self.seed = opts.seed or (opts.entity and opts.entity.id)
  self.image = nil
  self._adapterStatus = "READY"
  self._lastKey = nil
  self._lastCacheHit = false
  return self
end

function EnhancedWorldSprite:status()
  return self._adapterStatus or "READY"
end

function EnhancedWorldSprite:lastKey()
  return self._lastKey
end

function EnhancedWorldSprite:lastCacheHit()
  return self._lastCacheHit == true
end

function EnhancedWorldSprite:setBaseImagePath(path)
  if type(path) ~= "string" or path == "" then return false end
  self.baseImagePath = path
  self.def.image = path
  return true
end

-- Cheap: key lookup + return cached Image. May lazy-prepare once.
-- Dramatic Shape may call this multiple times per frame.
function EnhancedWorldSprite:resolveImage()
  local entity = self.entity
  local d = RenderDiagnostics.ensure(entity)
  d.enhancedResolveImageCalls = (d.enhancedResolveImageCalls or 0) + 1
  d.dramaticBillboardDrawAttempts = (d.dramaticBillboardDrawAttempts or 0) + 1
  d.lastDefImage = self.def and self.def.image

  -- Mesh probe (once-ish per resolve is ok; SpriteBillboards caches meshes).
  local meshOk, meshErr, meshKey = RenderDiagnostics.probeMesh(self.def, 0)
  d.lastMeshKey = meshKey
  d.lastMeshOk = meshOk == true
  if meshOk then
    d.meshOkObservations = (d.meshOkObservations or 0) + 1
  else
    d.meshFailObservations = (d.meshFailObservations or 0) + 1
    d.lastFailureReason = meshErr or "mesh probe failed"
  end

  local okA, errA = RenderDiagnostics.probeAssetsImage(self.def and self.def.image)
  d.assetsImageOk = okA == true
  d.assetsImageError = errA

  if entity and RenderDiagnostics.magentaProbeEnabled(entity.mod) then
    local probe = ensureMagentaProbe()
    if probe then
      local dim = RenderDiagnostics.describeImage(probe)
      d.lastResolvedImage = probe
      d.lastResolvedType = dim.typeName
      d.lastResolvedW = dim.w
      d.lastResolvedH = dim.h
      self._adapterStatus = "READY"
      self.image = probe
      return probe
    end
  end

  local anim = self.animatedSprites
  if not entity or not anim then
    self._adapterStatus = "TEMPORARILY_UNAVAILABLE"
    d.lastFailureReason = "adapter missing entity/animatedSprites"
    if self.legacySprite and type(self.legacySprite.resolveImage) == "function" then
      return self.legacySprite:resolveImage()
    end
    return self.legacySprite and self.legacySprite.image
  end

  local key = anim:getCurrentBillboardKey(entity)
  self._lastKey = key

  local cached = anim:peekBillboardImage(key)
  if cached then
    self._lastCacheHit = true
    self._adapterStatus = "READY"
    self.image = cached
    local dim = RenderDiagnostics.describeImage(cached)
    d.lastResolvedImage = cached
    d.lastResolvedType = dim.typeName
    d.lastResolvedW = dim.w
    d.lastResolvedH = dim.h
    return cached
  end

  self._lastCacheHit = false
  local result = anim:prepareBillboardImage(entity, key)
  if type(result) == "table" and result.status == "READY" and result.image then
    self._adapterStatus = "READY"
    self.image = result.image
    local dim = RenderDiagnostics.describeImage(result.image)
    d.lastResolvedImage = result.image
    d.lastResolvedType = dim.typeName
    d.lastResolvedW = dim.w
    d.lastResolvedH = dim.h
    return result.image
  end

  if type(result) == "table" then
    if result.status == "TEMPORARILY_UNAVAILABLE"
       or result.status == "VOXEL_CARD_BUILD_ERROR" then
      self._adapterStatus = "TEMPORARILY_UNAVAILABLE"
    elseif result.status == "FRAME_MISSING" or result.status == "PERMANENT_INVALID" then
      self._adapterStatus = "PERMANENT_INVALID"
    else
      self._adapterStatus = tostring(result.status)
    end
    d.lastFailureReason = tostring(result.reason or result.status)
  else
    self._adapterStatus = "TEMPORARILY_UNAVAILABLE"
    d.lastFailureReason = "prepareBillboardImage non-table"
  end

  if self.image then
    local dim = RenderDiagnostics.describeImage(self.image)
    d.lastResolvedImage = self.image
    d.lastResolvedType = dim.typeName
    d.lastResolvedW = dim.w
    d.lastResolvedH = dim.h
    return self.image
  end
  if self.legacySprite and type(self.legacySprite.resolveImage) == "function" then
    return self.legacySprite:resolveImage()
  end
  return self.legacySprite and self.legacySprite.image
end

function EnhancedWorldSprite:draw(px, py, camX, camY, facing, walkPhase, stepFlip, topHalf)
  local img = self:resolveImage()
  if not img or not (love and love.graphics) then return end
  local x = math.floor((px or 0) - (camX or 0))
  local y = math.floor((py or 0) - (camY or 0)) - 4
  love.graphics.draw(img, x, y)
end

return EnhancedWorldSprite
