-- Tall-grass feet occlusion for visible wild Pokemon.
--
-- Flat Gen1Recomp already redraws the cell's bottom tile row after each
-- entity via TileRenderer:drawCellBottom (GB sprite-priority feet overdraw).
--
-- Dramatic Shape world billboards: tall grass is a late 3D mesh after the
-- cast — immersed needs NO custom grass draw. above uses a small pose lift
-- (visualY) only. Custom drawForeground is emergency-overlay only.
--
-- Modes (option pokemon_grass_render_mode):
--   above    — fully visible (clear engine overdraw with a lift on flat path;
--              world-billboard path uses grass_above_lift_px on visualY)
--   immersed — lower portion hidden by foreground grass (default)
local V = ...
local Config = V.require("config")
local Surface = V.require("surface")
local Tile = V.require("tile")

local GrassOcclusion = {}

GrassOcclusion.MODE_ABOVE = "above"
GrassOcclusion.MODE_IMMERSED = "immersed"

-- Engine drawCellBottom paints the bottom 8px row of a 16px cell.
GrassOcclusion.ENGINE_BOTTOM_COVER_PX = 8
-- Soft readability caps (also used when computing relative lift).
GrassOcclusion.MAX_RATIO = 0.32
GrassOcclusion.MIN_VISIBLE_PX = 8
GrassOcclusion.SMALL_SPRITE_RATIO = 0.25

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
  -- Defaults / Config fallback.
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

-- Desired cover height for immersed mode (px of the rendered sprite).
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

-- Tuck delta applied to draw/pose Y.
-- immersed: slight raise so small sprites stay readable under ~6–8px overdraw
-- above + flat engine overdraw: raise by full bottom cover so feet clear it
-- above + voxel overlay: 0 (no engine overdraw after us)
function GrassOcclusion.tuckDelta(entity, opts)
  opts = opts or {}
  local base = entity and entity.tuck or 0
  if not entity then return base end
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
      -- Clear flat-path drawCellBottom.
      return base - (opts.engineCover or GrassOcclusion.ENGINE_BOTTOM_COVER_PX)
    end
    return base
  end

  -- immersed: relative lift vs engine cover
  local desired = entity.grassOcclusionHeight
    or Config.DEFAULTS.grass_occlusion_px
    or 6
  local defaultCover = opts.engineCover
    or Config.DEFAULTS.grass_occlusion_px
    or GrassOcclusion.ENGINE_BOTTOM_COVER_PX
  local lift = math.max(0, defaultCover - desired)
  return base - lift
end

-- Draw engine grass feet-overdraw for one entity (voxel overlay / manual).
function GrassOcclusion.drawForeground(entity, camX, camY, map)
  if not entity or not map or not map.renderer then return false end
  if not GrassOcclusion.shouldOcclude(entity, entity.mod) then return false end
  local renderer = map.renderer
  if type(renderer.drawCellBottom) ~= "function" then return false end
  local tiles = GrassOcclusion.grassTilesForEntity(entity, map)
  if #tiles == 0 then return false end
  love.graphics.setColor(1, 1, 1, 1)
  for _, t in ipairs(tiles) do
    pcall(renderer.drawCellBottom, renderer, t.x, t.y, camX, camY)
  end
  entity.grassSourceTile = tiles[1]
  return true
end

function GrassOcclusion.refreshEntity(entity, mod, map)
  if not entity then return end
  GrassOcclusion.updateInGrassFlag(entity, mod, map)
  local scale = entity.scaleInfo or {}
  local renderedH = scale.renderedH
    or ((scale.contentH or Tile.CELL) * (entity.final2DScale or 1))
  if entity.animation and entity.animation._lastFrameSize then
    local fh = entity.animation._lastFrameSize[2] or renderedH
    renderedH = fh * (entity.final2DScale or 1)
  end
  entity.grassOcclusionHeight = GrassOcclusion.computeOcclusionHeight(renderedH)
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
  if entity.grassOcclusionActive then
    lines[#lines + 1] = ("Occlusion height: %s px"):format(
      tostring(math.floor((entity.grassOcclusionHeight or 0) + 0.5)))
  end
  return lines
end

return GrassOcclusion
