-- Wilds-owned presentation adapters for SpriteRenderer draw quirks.
--
-- 1) disableVerticalStepFlip — Gen1Recomp mirrors the entire up/down walk
--    frame when walkPhase==1 and stepFlip. That approximates a second gait
--    pose for symmetrical humans but makes asymmetric Pokémon (Squirtle)
--    jump left/right. RIGHT facing still uses horizontal mirror when no
--    dedicated right frames are selected via frameOverride.
--
-- 2) forceRawTrueColor — Gen1 PaletteFX.honorsTrueColor() is only true in
--    ADVANCED (redpp). PMDCollab PNGs are already authored RGBA; feeding them
--    through dmgObj / SGB shade remap destroys their colors.
--    Flat: draw raw image + markTrueColor (and clear active palette shader).
--    Voxel/DS: wrap resolveImage so billboards never getObpImage the sheet.
local V = ...

local SpritePresentation = {}

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function defOf(sprite)
  return sprite and sprite.def
end

local function wantsNoVerticalFlip(sprite)
  local def = defOf(sprite)
  return def and def.disableVerticalStepFlip == true
end

local function wantsRawTrueColor(sprite)
  local def = defOf(sprite)
  return def and def.forceRawTrueColor == true
end

local function blitRaw(sprite, px, py, camX, camY, facing, walkPhase, stepFlip, topHalf, forceFlip, frameOverride)
  if not (sprite and type(sprite.getScreenOrigin) == "function") then
    return false
  end
  local love = rawget(_G, "love")
  if not (love and love.graphics and love.graphics.draw) then
    return false
  end
  local image = sprite.image
  if not image then return false end

  local fw = tonumber(sprite.frameWidth) or 16
  local fh = tonumber(sprite.frameHeight) or 16
  local frame = 0
  local flip = false

  if frameOverride ~= nil and sprite.frames and sprite.frames[frameOverride] then
    frame = frameOverride
    flip = false
  elseif type(sprite.getPoseGeometry) == "function" then
    local geo = sprite:getPoseGeometry(facing, walkPhase, stepFlip)
    if geo then
      frame = geo.frame or 0
      flip = geo.mirror == true
    end
  end
  if forceFlip then flip = true end

  local quad = sprite.frames and sprite.frames[frame]
  if not quad then return false end

  local x, y = sprite:getScreenOrigin(px, py, camX, camY)
  local drawH = fh
  if topHalf and (tonumber(sprite.frameCount) or 1) > 1 then
    local topHeight = math.max(1, fh - math.min(8, fh))
    sprite.halfFrames = sprite.halfFrames or {}
    if not sprite.halfFrames[frame] then
      local iw, ih = image:getDimensions()
      sprite.halfFrames[frame] = love.graphics.newQuad(
        0, frame * fh, fw, topHeight, iw, ih)
    end
    quad = sprite.halfFrames[frame]
    drawH = topHeight
  end

  local prevShader = nil
  if love.graphics.getShader then
    prevShader = love.graphics.getShader()
  end
  if love.graphics.setShader then
    love.graphics.setShader()
  end

  love.graphics.setColor(1, 1, 1, 1)
  if flip then
    love.graphics.draw(image, quad, x + fw, y, 0, -1, 1)
  else
    love.graphics.draw(image, quad, x, y, 0, 1, 1)
  end

  if love.graphics.setShader and prevShader then
    love.graphics.setShader(prevShader)
  end

  local PaletteFX = tryRequire("src.render.PaletteFX")
  if PaletteFX and type(PaletteFX.markTrueColor) == "function" then
    pcall(PaletteFX.markTrueColor, x, y, fw, drawH)
  end
  return true
end

local function wrapResolveImage(sprite)
  if type(sprite.resolveImage) ~= "function" then
    return false
  end
  if sprite._wildsPresResolveWrapped then
    return true
  end
  local orig = sprite.resolveImage
  sprite._wildsPresResolveOrig = orig
  sprite._wildsPresResolveWrapped = true
  function sprite:resolveImage(...)
    if wantsRawTrueColor(self) and self.image then
      -- Voxel / Dramatic Shape textures come from resolveImage. Never bake
      -- authored RGBA through getObpImage / dmgObj for PMDCollab.
      return self.image
    end
    return orig(self, ...)
  end
  return true
end

--- Attach presentation wraps once. Safe to call repeatedly (idempotent).
function SpritePresentation.attach(sprite, entity)
  if type(sprite) ~= "table" or type(sprite.draw) ~= "function" then
    return false
  end
  if entity then
    sprite._wildsPresEntity = entity
  end
  local needFlip = wantsNoVerticalFlip(sprite)
  local needRaw = wantsRawTrueColor(sprite)
  if not needFlip and not needRaw then
    return false
  end
  if needRaw then
    wrapResolveImage(sprite)
  end
  if sprite._wildsPresWrapped then
    return true
  end
  local orig = sprite.draw
  sprite._wildsPresOrigDraw = orig
  sprite._wildsPresWrapped = true
  function sprite:draw(px, py, camX, camY, facing, walkPhase, stepFlip, topHalf, forceFlip, frameOverride)
    local sf = stepFlip
    if wantsNoVerticalFlip(self) then
      sf = false
    end
    if wantsRawTrueColor(self) then
      if blitRaw(self, px, py, camX, camY, facing, walkPhase, sf, topHalf, forceFlip, frameOverride) then
        return
      end
    end
    return orig(self, px, py, camX, camY, facing, walkPhase, sf, topHalf, forceFlip, frameOverride)
  end
  return true
end

--- Effective stepFlip for pose()/draw call sites that do not go through wrap.
function SpritePresentation.effectiveStepFlip(spriteOrDef, stepFlip)
  local def = spriteOrDef
  if type(spriteOrDef) == "table" and spriteOrDef.def then
    def = spriteOrDef.def
  end
  if def and def.disableVerticalStepFlip == true then
    return false
  end
  return stepFlip == true
end

return SpritePresentation
