-- Tall-grass feet occlusion for visible wild Pokemon.
--
-- Classic Flat: Gen1Recomp OverworldController calls TileRenderer:drawCellBottom
-- after each entity — vanilla GB sprite-priority overdraw (bottom 8px of a
-- 16×16 cell). Keep that path pixel-identical.
--
-- True Size Flat: that fixed 8px tile overdraw covers too much of taller /
-- denser sprites. We wrap drawCellBottom so True Size entities queue a
-- clipped feet-band (cover from computeTrueSizeCover) instead. ABOVE mode
-- skips the overdraw entirely (no tuck needed).
--
-- Voxel / Dramatic Shape: untouched (native grass mesh / Classic geometry).
--
-- Modes (option pokemon_grass_render_mode):
--   above    — fully visible above grass
--   immersed — lower feet band hidden by foreground grass (default)
local V = ...
local Config = V.require("config")
local Surface = V.require("surface")
local Tile = V.require("tile")

local GrassOcclusion = {}

GrassOcclusion.MODE_ABOVE = "above"
GrassOcclusion.MODE_IMMERSED = "immersed"

-- Engine drawCellBottom paints the bottom 8px row of a 16px cell.
GrassOcclusion.ENGINE_BOTTOM_COVER_PX = 8
-- Soft readability caps (Classic tuck / computeOcclusionHeight).
GrassOcclusion.MAX_RATIO = 0.32
GrassOcclusion.MIN_VISIBLE_PX = 8
GrassOcclusion.SMALL_SPRITE_RATIO = 0.25
-- True Size feet-band: keep cover small so bodies stay readable.
GrassOcclusion.TRUE_SIZE_MAX_COVER_PX = 6
GrassOcclusion.TRUE_SIZE_MAX_RATIO = 0.22
GrassOcclusion.TRUE_SIZE_SMALL_RATIO = 0.20

local _queue = {}       -- "cx,cy" → { skip=bool, coverPx=n } for next drawCellBottom
local _lastAction = {}  -- same keys; remembered for markCellBottomRedraw pairing
local _wrapInstalled = false
local _origDrawCellBottom = nil
local _origMarkCellBottomRedraw = nil

local function cellKey(cx, cy)
  return tostring(cx) .. "," .. tostring(cy)
end

function GrassOcclusion.normalizeMode(value)
  if value == true then return GrassOcclusion.MODE_IMMERSED end
  if value == false then return GrassOcclusion.MODE_ABOVE end
  local key = tostring(value or ""):lower()
  if key == "above" or key == "above_grass" or key == "over" then
    return GrassOcclusion.MODE_ABOVE
  end
  if key == "immersed" or key == "partial" or key == "hidden"
     or key == "in_grass" or key == "partially_hidden" then
    return GrassOcclusion.MODE_IMMERSED
  end
  return GrassOcclusion.MODE_IMMERSED
end

-- Resolve mode with legacy show_pokemon_in_grass alias.
function GrassOcclusion.mode(mod)
  local raw
  if mod and mod.options and type(mod.options.get) == "function" then
    raw = mod.options:get("pokemon_grass_render_mode")
  end
  if raw ~= nil then
    return GrassOcclusion.normalizeMode(raw)
  end
  local legacy
  if mod and mod.options and type(mod.options.get) == "function" then
    legacy = mod.options:get("show_pokemon_in_grass")
  end
  if legacy == false then
    return GrassOcclusion.MODE_ABOVE
  end
  return GrassOcclusion.normalizeMode(
    Config.DEFAULTS.pokemon_grass_render_mode or GrassOcclusion.MODE_IMMERSED)
end

function GrassOcclusion.isImmersed(mod)
  return GrassOcclusion.mode(mod) == GrassOcclusion.MODE_IMMERSED
end

function GrassOcclusion.isOnGrassTile(map, cellX, cellY)
  if not map or not map.isGrassCell then return false end
  if cellX == nil or cellY == nil then return false end
  return map:isGrassCell(cellX, cellY) == true
end

-- Source + target tiles during a step (matches OverworldController flat path).
function GrassOcclusion.grassTilesForEntity(entity, map)
  local tiles = {}
  if not entity or not map then return tiles end
  local cx, cy = entity.cellX, entity.cellY
  if GrassOcclusion.isOnGrassTile(map, cx, cy) then
    tiles[#tiles + 1] = { x = cx, y = cy }
  end
  local tx, ty = entity.targetX, entity.targetY
  if tx and ty and (tx ~= cx or ty ~= cy)
     and GrassOcclusion.isOnGrassTile(map, tx, ty) then
    tiles[#tiles + 1] = { x = tx, y = ty }
  end
  return tiles
end

function GrassOcclusion.updateInGrassFlag(entity, mod, map)
  if not entity then return false end
  local SpawnFx = V.require("spawn_fx")
  if not SpawnFx.bodyVisible(entity) then
    entity.inGrassOverlay = false
    entity.grassOcclusionActive = false
    return false
  end
  if not Surface.usesGrassOverlay(entity.surface) then
    entity.inGrassOverlay = false
    entity.grassOcclusionActive = false
    return false
  end
  local onGrass = false
  if map then
    onGrass = GrassOcclusion.isOnGrassTile(map, entity.cellX, entity.cellY)
    if not onGrass and entity.targetX then
      onGrass = GrassOcclusion.isOnGrassTile(map, entity.targetX, entity.targetY)
    end
  elseif entity.surface == Surface.GRASS then
    onGrass = true
  end
  entity.inGrassOverlay = onGrass == true
  entity.grassOcclusionActive = onGrass
    and GrassOcclusion.isImmersed(mod)
    and entity.visibleSprite ~= false
    and not entity.hiddenEncounter
  return entity.grassOcclusionActive
end

function GrassOcclusion.shouldOcclude(entity, mod)
  if not entity then return false end
  if entity.grassOcclusionActive ~= nil then
    return entity.grassOcclusionActive == true
  end
  return GrassOcclusion.isImmersed(mod)
    and entity.inGrassOverlay == true
    and entity.visibleSprite ~= false
    and not entity.hiddenEncounter
    and Surface.usesGrassOverlay(entity.surface)
end

--- Classic relative cover (also used by SpriteScale). Unchanged contract.
function GrassOcclusion.computeOcclusionHeight(renderedVisibleH, opts)
  opts = opts or {}
  local engine = opts.engineCover
    or Config.DEFAULTS.grass_occlusion_px
    or GrassOcclusion.ENGINE_BOTTOM_COVER_PX
  local h = math.max(1, tonumber(renderedVisibleH) or 16)
  local maxRatio = opts.maxRatio or GrassOcclusion.MAX_RATIO
  local minVisible = opts.minVisible or GrassOcclusion.MIN_VISIBLE_PX
  local cover
  if h <= 16 then
    cover = math.min(engine, math.floor(h * (opts.smallRatio or GrassOcclusion.SMALL_SPRITE_RATIO)))
  else
    cover = math.min(engine, math.floor(h * maxRatio))
  end
  cover = math.max(2, cover)
  local maxCover = math.max(0, h - minVisible)
  if cover > maxCover then cover = maxCover end
  return cover
end

--- True Size feet-band cover in pixels (what the clipped scissor actually paints).
-- Caps at TRUE_SIZE_MAX_COVER_PX so large sprites never lose half their body.
function GrassOcclusion.computeTrueSizeCover(renderedVisibleH, opts)
  opts = opts or {}
  return GrassOcclusion.computeOcclusionHeight(renderedVisibleH, {
    engineCover = opts.engineCover or GrassOcclusion.TRUE_SIZE_MAX_COVER_PX,
    maxRatio = opts.maxRatio or GrassOcclusion.TRUE_SIZE_MAX_RATIO,
    smallRatio = opts.smallRatio or GrassOcclusion.TRUE_SIZE_SMALL_RATIO,
    minVisible = opts.minVisible or GrassOcclusion.MIN_VISIBLE_PX,
  })
end

--- Whether this Flat entity should use the True Size feet-band path.
-- Voxel stays Classic (variableSizeApplied is false under effective Classic).
function GrassOcclusion.usesTrueSizeFeetBand(entity, mod)
  if not entity then return false end
  if entity.variableSizeApplied ~= true then return false end
  local ok, VariableSize = pcall(function() return V.require("variable_size") end)
  if not ok or not VariableSize or not VariableSize.canApplyTrueSize then
    return entity.variableSizeApplied == true
  end
  return VariableSize.canApplyTrueSize(mod or entity.mod) == true
end

function GrassOcclusion.frameHeightForEntity(entity)
  if not entity then return Tile.CELL end
  local def = entity.sprite and entity.sprite.def
  local fh = def and tonumber(def.frameHeight)
  if fh and fh > 0 then
    return fh * (entity.final2DScale or 1)
  end
  local scale = entity.scaleInfo or {}
  return scale.renderedH
    or ((scale.contentH or Tile.CELL) * (entity.final2DScale or 1))
end

-- Tuck delta applied to draw/pose Y.
-- Classic immersed: slight raise so small sprites stay readable under 8px overdraw
-- Classic above + flat engine overdraw: raise by full bottom cover
-- True Size Flat: wrap owns occlusion — tuck stays 0 (no compensate-for-8px)
function GrassOcclusion.tuckDelta(entity, opts)
  opts = opts or {}
  local base = entity and entity.tuck or 0
  if not entity then return base end

  if opts.trueSizeFeetBand or GrassOcclusion.usesTrueSizeFeetBand(entity, entity.mod) then
    return base
  end

  local mode = opts.mode
  if not mode and entity.mod then
    mode = GrassOcclusion.mode(entity.mod)
  end
  mode = mode or GrassOcclusion.MODE_IMMERSED

  if not entity.inGrassOverlay then
    return base
  end

  if mode == GrassOcclusion.MODE_ABOVE then
    if opts.engineOverdrawExpected then
      return base - (opts.engineCover or GrassOcclusion.ENGINE_BOTTOM_COVER_PX)
    end
    return base
  end

  local desired = entity.grassOcclusionHeight
    or Config.DEFAULTS.grass_occlusion_px
    or 6
  local defaultCover = opts.engineCover
    or Config.DEFAULTS.grass_occlusion_px
    or GrassOcclusion.ENGINE_BOTTOM_COVER_PX
  local lift = math.max(0, defaultCover - desired)
  return base - lift
end

local function pushScissor(x, y, w, h)
  if not (love and love.graphics and love.graphics.setScissor) then
    return nil
  end
  local prev
  if love.graphics.getScissor then
    local ok, sx, sy, sw, sh = pcall(love.graphics.getScissor)
    if ok and sx ~= nil then
      prev = { sx, sy, sw, sh }
    else
      prev = false
    end
  else
    prev = false
  end
  love.graphics.setScissor(x, y, w, h)
  return prev
end

local function popScissor(prev)
  if not (love and love.graphics and love.graphics.setScissor) then return end
  if prev == nil then return end
  if prev == false then
    love.graphics.setScissor()
  else
    love.graphics.setScissor(prev[1], prev[2], prev[3], prev[4])
  end
end

--- Draw only the bottom `coverPx` of the grass cell (world-canvas pixels).
-- Uses the same cam flooring contract as TileRenderer / RangePreview.
function GrassOcclusion.drawClippedCellBottom(renderer, cx, cy, camX, camY, coverPx)
  if not renderer then return false end
  coverPx = math.floor(tonumber(coverPx) or 4)
  if coverPx < 1 then return false end
  if coverPx > GrassOcclusion.ENGINE_BOTTOM_COVER_PX then
    coverPx = GrassOcclusion.ENGINE_BOTTOM_COVER_PX
  end
  local cell = Tile.CELL
  local sx = cx * cell - math.floor(camX or 0)
  local sy = cy * cell - math.floor(camY or 0)
  local feetY = sy + cell
  local prev = pushScissor(sx, feetY - coverPx, cell, coverPx)
  love.graphics.setColor(1, 1, 1, 1)
  -- Prefer the public drawCellBottom (color-0 key shader) when not wrapping;
  -- from inside the wrap we call the original / Raw+shader equivalent.
  if _origDrawCellBottom then
    _origDrawCellBottom(renderer, cx, cy, camX, camY)
  elseif type(renderer.drawCellBottom) == "function" then
    renderer:drawCellBottom(cx, cy, camX, camY)
  elseif type(renderer.drawCellBottomRaw) == "function" then
    renderer:drawCellBottomRaw(cx, cy, camX, camY)
  end
  popScissor(prev)
  return true
end

--- Called from Entity:draw BEFORE the engine's post-entity drawCellBottom.
-- Queues skip (Above) or clipped cover (Immersed) for this entity's grass cells.
function GrassOcclusion.queueTrueSizeFeetBand(entity, camX, camY, map)
  if not entity or not GrassOcclusion.usesTrueSizeFeetBand(entity, entity.mod) then
    return false
  end
  -- Above and Immersed both need the wrap while standing in grass:
  -- Immersed → clipped feet band; Above → skip vanilla 8px overdraw.
  if entity.inGrassOverlay ~= true then return false end

  local mode = GrassOcclusion.mode(entity.mod)
  local cover = entity.grassOcclusionHeight
  if not cover or cover < 1 then
    cover = GrassOcclusion.computeTrueSizeCover(GrassOcclusion.frameHeightForEntity(entity))
    entity.grassOcclusionHeight = cover
  end

  local tiles = GrassOcclusion.grassTilesForEntity(entity, map)
  if #tiles == 0 and map then
    -- Fallback: current cell only when map helpers unavailable mid-draw.
    if entity.cellX ~= nil then
      tiles[1] = { x = entity.cellX, y = entity.cellY }
    end
  elseif #tiles == 0 and entity.cellX ~= nil then
    tiles[1] = { x = entity.cellX, y = entity.cellY }
  end
  if #tiles == 0 then return false end

  local skip = (mode == GrassOcclusion.MODE_ABOVE)
  for _, t in ipairs(tiles) do
    local key = cellKey(t.x, t.y)
    _queue[key] = {
      skip = skip,
      coverPx = cover,
      camX = camX,
      camY = camY,
      entity = entity,
    }
  end
  entity.grassSourceTile = tiles[1]
  entity.grassRenderer = skip and "TRUE_SIZE_SKIP" or "TRUE_SIZE_FEET_BAND"
  entity.grassFeetCoverPx = skip and 0 or cover
  return true
end

function GrassOcclusion.takeQueuedBand(cx, cy)
  local key = cellKey(cx, cy)
  local q = _queue[key]
  _queue[key] = nil
  if q then
    _lastAction[key] = q
  end
  return q
end

function GrassOcclusion.clearQueues()
  _queue = {}
  _lastAction = {}
end

-- Emergency overlay path (voxel spatial fallback only).
function GrassOcclusion.drawForeground(entity, camX, camY, map)
  if not entity or not map or not map.renderer then return false end
  if not GrassOcclusion.shouldOcclude(entity, entity.mod) then return false end
  local renderer = map.renderer
  if type(renderer.drawCellBottom) ~= "function" then return false end
  local tiles = GrassOcclusion.grassTilesForEntity(entity, map)
  if #tiles == 0 then return false end
  love.graphics.setColor(1, 1, 1, 1)
  if GrassOcclusion.usesTrueSizeFeetBand(entity, entity.mod) then
    local cover = entity.grassOcclusionHeight
      or GrassOcclusion.computeTrueSizeCover(GrassOcclusion.frameHeightForEntity(entity))
    for _, t in ipairs(tiles) do
      GrassOcclusion.drawClippedCellBottom(renderer, t.x, t.y, camX, camY, cover)
    end
  else
    for _, t in ipairs(tiles) do
      pcall(renderer.drawCellBottom, renderer, t.x, t.y, camX, camY)
    end
  end
  entity.grassSourceTile = tiles[1]
  return true
end

function GrassOcclusion.refreshEntity(entity, mod, map)
  if not entity then return end
  GrassOcclusion.updateInGrassFlag(entity, mod, map)
  local renderedH = GrassOcclusion.frameHeightForEntity(entity)
  if entity.animation and entity.animation._lastFrameSize then
    local fh = entity.animation._lastFrameSize[2] or renderedH
    renderedH = fh * (entity.final2DScale or 1)
  end
  if GrassOcclusion.usesTrueSizeFeetBand(entity, mod) then
    entity.grassOcclusionHeight = GrassOcclusion.computeTrueSizeCover(renderedH)
  else
    entity.grassOcclusionHeight = GrassOcclusion.computeOcclusionHeight(renderedH)
  end
  entity.grassRenderMode = GrassOcclusion.mode(mod)
end

function GrassOcclusion.statusLines(entity)
  if not entity then return {} end
  local lines = {}
  local mode = tostring(entity.grassRenderMode
    or (entity.mod and GrassOcclusion.mode(entity.mod))
    or "?"):upper()
  lines[#lines + 1] = ("Grass mode: %s"):format(mode)
  lines[#lines + 1] = ("Grass renderer: %s"):format(
    tostring(entity.grassRenderer or "N/A"))
  lines[#lines + 1] = ("In grass: %s"):format(
    entity.inGrassOverlay and "YES" or "NO")
  lines[#lines + 1] = ("Grass occlusion active: %s"):format(
    entity.grassOcclusionActive and "YES" or "NO")
  if entity.grassSourceTile then
    lines[#lines + 1] = ("Grass source tile: %s,%s"):format(
      tostring(entity.grassSourceTile.x), tostring(entity.grassSourceTile.y))
  end
  if entity.grassOcclusionActive or entity.grassFeetCoverPx then
    lines[#lines + 1] = ("Occlusion height: %s px"):format(
      tostring(math.floor((entity.grassFeetCoverPx or entity.grassOcclusionHeight or 0) + 0.5)))
  end
  local def = entity.sprite and entity.sprite.def
  if def and def.frameHeight then
    lines[#lines + 1] = ("Frame HxA: %sx%s"):format(
      tostring(def.frameHeight), tostring(def.anchorY or "?"))
  end
  return lines
end

--- Install TileRenderer wraps so True Size can replace vanilla 8px overdraw.
-- Idempotent. Does not wrap drawCellBottomRaw (tilt/voxel billboard path).
function GrassOcclusion.installTileRendererWrap(mod)
  if _wrapInstalled then return true end
  local ok, TileRenderer = pcall(require, "src.render.TileRenderer")
  if not ok or type(TileRenderer) ~= "table"
     or type(TileRenderer.drawCellBottom) ~= "function" then
    return false
  end
  _origDrawCellBottom = TileRenderer.drawCellBottom
  _origMarkCellBottomRedraw = TileRenderer.markCellBottomRedraw

  function TileRenderer:drawCellBottom(cx, cy, camX, camY)
    local q = GrassOcclusion.takeQueuedBand(cx, cy)
    if q then
      if q.skip then
        return
      end
      GrassOcclusion.drawClippedCellBottom(self, cx, cy, camX, camY, q.coverPx)
      return
    end
    return _origDrawCellBottom(self, cx, cy, camX, camY)
  end

  if type(_origMarkCellBottomRedraw) == "function" then
    function TileRenderer:markCellBottomRedraw(cx, cy, camX, camY, colors)
      local key = cellKey(cx, cy)
      local q = _lastAction[key]
      -- True Size: clipped/skip already handled the visible pass. A full-tile
      -- OBP grass replay would undo the feet-band scissor — suppress it.
      if q then
        return
      end
      return _origMarkCellBottomRedraw(self, cx, cy, camX, camY, colors)
    end
  end

  _wrapInstalled = true
  local DebugLog = V.require("debug_log")
  if DebugLog and DebugLog.debug then
    DebugLog.debug(mod, "GrassOcclusion: TileRenderer feet-band wrap installed")
  end
  return true
end

function GrassOcclusion.isWrapInstalled()
  return _wrapInstalled == true
end

--- Test helper: restore originals.
function GrassOcclusion.uninstallTileRendererWrap()
  if not _wrapInstalled then return end
  local ok, TileRenderer = pcall(require, "src.render.TileRenderer")
  if ok and type(TileRenderer) == "table" then
    if _origDrawCellBottom then
      TileRenderer.drawCellBottom = _origDrawCellBottom
    end
    if _origMarkCellBottomRedraw then
      TileRenderer.markCellBottomRedraw = _origMarkCellBottomRedraw
    end
  end
  _origDrawCellBottom = nil
  _origMarkCellBottomRedraw = nil
  _wrapInstalled = false
  GrassOcclusion.clearQueues()
end

return GrassOcclusion
