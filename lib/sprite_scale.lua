-- Species-aware / bounds-aware visual scale for overworld wild sprites.
-- Collision / cell occupancy stays 1 tile; only 2D drawing uses the scale.
-- Hard rule: rendered visible footprint ≤ one map tile (Gen1Recomp CELL=16).
-- Nearest-neighbor filtering is applied by the caller.
local V = ...
local Config = V.require("config")
local Tile = V.require("tile")

local SpriteScale = {}

-- Optional explicit overrides (species id -> preferred scale multiplier).
-- Always clamped by the one-tile maximum afterward.
local SPECIES_SCALE = {
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
  ONIX = 0.95,
  SNORLAX = 0.9,
  GYARADOS = 0.95,
}

-- Cache visible bounds per image identity (path or userdata tostring).
local boundsCache = {}

function SpriteScale.speciesOverride(speciesId)
  return SPECIES_SCALE[speciesId]
end

function SpriteScale.clearCache()
  boundsCache = {}
end

local function cacheKey(image)
  if not image then return "nil" end
  if type(image) == "table" and image._owwildBoundsKey then
    return image._owwildBoundsKey
  end
  if type(image) == "table" and image.getDimensions then
    local w, h = image:getDimensions()
    return string.format("dim:%dx%d:%s", w or 0, h or 0, tostring(image))
  end
  return tostring(image)
end

-- Probe non-transparent / non-near-white bounds from ImageData when available.
-- Returns contentW, contentH, offsetX, offsetY, imageW, imageH and a bounds table.
function SpriteScale.visibleBounds(image)
  local key = cacheKey(image)
  if boundsCache[key] then
    local b = boundsCache[key]
    return b.width, b.height, b.minX, b.minY, b.imageW, b.imageH, b
  end

  if not image then
    local tw, th = Tile.size()
    local b = {
      minX = 0, minY = 0, maxX = tw - 1, maxY = th - 1,
      width = tw, height = th, imageW = tw, imageH = th,
    }
    return tw, th, 0, 0, tw, th, b
  end

  local w, h = 0, 0
  if image.getDimensions then
    w, h = image:getDimensions()
  end
  if w < 1 or h < 1 then
    local tw, th = Tile.size()
    local b = {
      minX = 0, minY = 0, maxX = tw - 1, maxY = th - 1,
      width = tw, height = th, imageW = tw, imageH = th,
    }
    return tw, th, 0, 0, tw, th, b
  end

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
    local b = {
      minX = 0, minY = 0, maxX = w - 1, maxY = h - 1,
      width = w, height = h, imageW = w, imageH = h,
    }
    boundsCache[key] = b
    return w, h, 0, 0, w, h, b
  end

  local minX, minY = w, h
  local maxX, maxY = -1, -1
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local ok, r, g, b, a = pcall(idata.getPixel, idata, x, y)
      if ok then
        if a and a > 1 then a = a / 255 end
        if r and r > 1 then r, g, b = r / 255, g / 255, b / 255 end
        local opaque = (a == nil or a > 0.08)
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
    local b = {
      minX = 0, minY = 0, maxX = w - 1, maxY = h - 1,
      width = w, height = h, imageW = w, imageH = h,
    }
    boundsCache[key] = b
    return w, h, 0, 0, w, h, b
  end

  local cw = maxX - minX + 1
  local ch = maxY - minY + 1
  local b = {
    minX = minX, minY = minY, maxX = maxX, maxY = maxY,
    width = cw, height = ch, imageW = w, imageH = h,
  }
  boundsCache[key] = b
  return cw, ch, minX, minY, w, h, b
end

function SpriteScale.oneTileMaxScale(visibleW, visibleH, opts)
  opts = opts or {}
  local tileW = opts.tileWidth or Tile.WIDTH
  local tileH = opts.tileHeight or Tile.HEIGHT
  local usableW = opts.usableWidth or (tileW * (opts.usableWidthFrac or Tile.USABLE_WIDTH_FRAC))
  local usableH = opts.usableHeight or (tileH * (opts.usableHeightFrac or Tile.USABLE_HEIGHT_FRAC))
  visibleW = math.max(1, visibleW or 1)
  visibleH = math.max(1, visibleH or 1)
  local scaleX = usableW / visibleW
  local scaleY = usableH / visibleH
  return math.min(scaleX, scaleY)
end

function SpriteScale.desiredScale(speciesId, visibleH, opts)
  opts = opts or {}
  local minH = opts.minVisibleHeight or Config.DEFAULTS.min_sprite_visible_height or 16
  local targetH = opts.targetVisibleHeight or Config.DEFAULTS.target_sprite_visible_height or 16
  local minOpt = opts.minSpriteSizeOption
  if minOpt and minOpt > minH then minH = minOpt end
  -- Preferred minimum readable size must never exceed one tile height.
  local tileH = opts.tileHeight or Tile.HEIGHT
  local usableH = opts.usableHeight or (tileH * Tile.USABLE_HEIGHT_FRAC)
  if minH > usableH then minH = usableH end
  if targetH > usableH then targetH = usableH end

  visibleH = math.max(1, visibleH or 1)
  local scale = 1.0
  if visibleH < minH then
    scale = minH / visibleH
  elseif visibleH < targetH then
    scale = targetH / visibleH
  end

  local override = SpriteScale.speciesOverride(speciesId)
  if override then
    scale = scale * override
  end
  if opts.requestedScale then
    scale = scale * opts.requestedScale
  end
  return scale
end

function SpriteScale.compute(speciesId, image, opts)
  opts = opts or {}
  local tileW = opts.tileWidth or Tile.WIDTH
  local tileH = opts.tileHeight or Tile.HEIGHT
  local usableW = tileW * (opts.usableWidthFrac or Tile.USABLE_WIDTH_FRAC)
  local usableH = tileH * (opts.usableHeightFrac or Tile.USABLE_HEIGHT_FRAC)

  local cw, ch, ox, oy, iw, ih, bounds = SpriteScale.visibleBounds(image)
  iw = iw or tileW
  ih = ih or tileH
  cw = math.max(1, cw or iw)
  ch = math.max(1, ch or ih)
  ox = ox or 0
  oy = oy or 0

  local desired = SpriteScale.desiredScale(speciesId, ch, {
    minVisibleHeight = opts.minVisibleHeight,
    targetVisibleHeight = opts.targetVisibleHeight,
    minSpriteSizeOption = opts.minSpriteSizeOption,
    tileHeight = tileH,
    usableHeight = usableH,
    requestedScale = opts.requestedScale,
  })
  local maximum = SpriteScale.oneTileMaxScale(cw, ch, {
    tileWidth = tileW,
    tileHeight = tileH,
    usableWidth = usableW,
    usableHeight = usableH,
  })
  local finalScale = math.min(desired, maximum)
  if finalScale <= 0 then finalScale = maximum end

  local renderedW = cw * finalScale
  local renderedH = ch * finalScale
  -- Final hard assert: never exceed a full tile even if usable frac is 1.
  if renderedW > tileW then
    finalScale = tileW / cw
    renderedW = cw * finalScale
    renderedH = ch * finalScale
  end
  if renderedH > tileH then
    finalScale = tileH / ch
    renderedW = cw * finalScale
    renderedH = ch * finalScale
  end

  -- Relative grass occlusion for immersed mode (feet under drawCellBottom).
  local GrassOcclusion = V.require("grass_occlusion")
  local grassOcclusionHeight = GrassOcclusion.computeOcclusionHeight(renderedH, {
    engineCover = opts.defaultGrassOcclusion or Config.DEFAULTS.grass_occlusion_px,
  })

  return {
    scale = finalScale,
    final2DScale = finalScale,
    desiredScale = desired,
    maximumOneTileScale = maximum,
    contentW = cw,
    contentH = ch,
    offsetX = ox,
    offsetY = oy,
    imageW = iw,
    imageH = ih,
    renderedW = renderedW,
    renderedH = renderedH,
    originalW = iw,
    originalH = ih,
    tileWidth = tileW,
    tileHeight = tileH,
    usableWidth = usableW,
    usableHeight = usableH,
    visibleBounds = bounds,
    grassOcclusionHeight = grassOcclusionHeight,
    logicalFootprintTiles = 1,
  }
end

function SpriteScale.fitsOneTile(info)
  if not info then return false end
  local tw = info.tileWidth or Tile.WIDTH
  local th = info.tileHeight or Tile.HEIGHT
  return (info.renderedW or 0) <= tw + 1e-6
     and (info.renderedH or 0) <= th + 1e-6
end

return SpriteScale
