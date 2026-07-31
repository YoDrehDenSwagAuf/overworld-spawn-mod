-- Species-aware / bounds-aware visual scale for overworld wild sprites.
-- Collision / cell occupancy stays 1 tile; only drawing uses the scale.
-- Nearest-neighbor filtering is applied by the caller.
local V = ...
local Config = V.require("config")

local SpriteScale = {}

-- Optional explicit overrides (species id -> scale multiplier).
local SPECIES_SCALE = {
  -- Very small / hard-to-see when tucked in grass
  CATERPIE = 1.35,
  WEEDLE = 1.35,
  METAPOD = 1.25,
  KAKUNA = 1.25,
  PIDGEY = 1.3,
  RATTATA = 1.25,
  SPEAROW = 1.25,
  ZUBAT = 1.3,
  MAGIKARP = 1.2,
  DIGLETT = 1.15,
  -- Large / bulky — keep closer to 1
  ONIX = 0.95,
  SNORLAX = 0.9,
  GYARADOS = 0.95,
}

function SpriteScale.speciesOverride(speciesId)
  return SPECIES_SCALE[speciesId]
end

-- Probe non-transparent / non-near-white bounds from ImageData when available.
-- Returns contentW, contentH, offsetX, offsetY or nils.
function SpriteScale.visibleBounds(image)
  if not image then return nil end
  local w, h = 0, 0
  if image.getDimensions then
    w, h = image:getDimensions()
  end
  if w < 1 or h < 1 then return nil end

  -- Prefer ImageData sampling when LÖVE exposes it.
  local idata = nil
  if image.getData then
    local ok, data = pcall(image.getData, image)
    if ok then idata = data end
  end
  if not idata and love and love.image and image.typeOf
     and image:typeOf("ImageData") then
    idata = image
  end

  if not idata or not idata.getPixel then
    -- Headless / no pixel access: assume the full frame is content.
    return w, h, 0, 0, w, h
  end

  local minX, minY = w, h
  local maxX, maxY = -1, -1
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local ok, r, g, b, a = pcall(idata.getPixel, idata, x, y)
      if ok then
        -- LÖVE 11 returns 0..1 floats; some stubs return 0..255.
        if a and a > 1 then a = a / 255 end
        if r and r > 1 then r, g, b = r / 255, g / 255, b / 255 end
        local opaque = (a == nil or a > 0.08)
        -- Key near-white (OBJ color 0 style) as empty when alpha missing.
        local nearWhite = r and g and b and r > 0.83 and g > 0.83 and b > 0.83
        if opaque and not nearWhite then
          if x < minX then minX = x end
          if y < minY then minY = y end
          if x > maxX then maxX = x end
          if y > maxY then maxY = y end
        end
      end
    end
  end

  if maxX < minX or maxY < minY then
    return w, h, 0, 0, w, h
  end
  local cw = maxX - minX + 1
  local ch = maxY - minY + 1
  return cw, ch, minX, minY, w, h
end

function SpriteScale.compute(speciesId, image, opts)
  opts = opts or {}
  local minH = opts.minVisibleHeight or Config.DEFAULTS.min_sprite_visible_height or 16
  local targetH = opts.targetVisibleHeight or Config.DEFAULTS.target_sprite_visible_height or 22
  local maxH = opts.maxVisibleHeight or Config.DEFAULTS.max_sprite_visible_height or 28
  local minOpt = opts.minSpriteSizeOption
  if minOpt and minOpt > minH then minH = minOpt end

  local cw, ch, ox, oy, iw, ih = SpriteScale.visibleBounds(image)
  iw = iw or 16
  ih = ih or 16
  cw = cw or iw
  ch = ch or ih
  ox = ox or 0
  oy = oy or 0

  local scale = 1.0
  if ch < minH then
    scale = minH / ch
  elseif ch < targetH then
    scale = targetH / ch
  elseif ch > maxH then
    scale = maxH / ch
  end

  local override = SpriteScale.speciesOverride(speciesId)
  if override then
    scale = scale * override
  end

  -- Hard clamps so a route is never covered by a giant mon.
  local absMin = 1.0
  local absMax = 2.0
  if scale < absMin then scale = absMin end
  if scale > absMax then scale = absMax end

  -- After scale, re-clamp rendered content height.
  local renderedH = ch * scale
  if renderedH > maxH * 1.15 then
    scale = (maxH * 1.15) / ch
  end
  if renderedH < minH then
    scale = minH / math.max(ch, 1)
  end

  return {
    scale = scale,
    contentW = cw,
    contentH = ch,
    offsetX = ox,
    offsetY = oy,
    imageW = iw,
    imageH = ih,
    renderedW = cw * scale,
    renderedH = ch * scale,
    originalW = iw,
    originalH = ih,
  }
end

return SpriteScale
