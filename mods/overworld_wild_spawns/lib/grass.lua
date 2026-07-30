-- Grass-cell discovery and free-tile picking for the active runtime map.
local V = ...

local Grass = {}

function Grass.cells(map)
  local out = {}
  if not map or not map.isGrassCell then return out end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  for cy = 0, h - 1 do
    for cx = 0, w - 1 do
      if map:isGrassCell(cx, cy) then
        out[#out + 1] = { x = cx, y = cy }
      end
    end
  end
  return out
end

local function occupied(entities, x, y, ignore)
  for _, e in ipairs(entities or {}) do
    if e ~= ignore then
      if e.cellX == x and e.cellY == y then return true end
      if e.targetX == x and e.targetY == y then return true end
    end
  end
  return false
end

local function chebyshev(ax, ay, bx, by)
  local dx = ax - bx
  if dx < 0 then dx = -dx end
  local dy = ay - by
  if dy < 0 then dy = -dy end
  return dx > dy and dx or dy
end

function Grass.chebyshev(ax, ay, bx, by)
  return chebyshev(ax, ay, bx, by)
end

-- Valid grass tile: in bounds grass, not occupied, not a warp.
-- minDist/maxDist are optional Chebyshev constraints vs the player.
function Grass.isValidSpawnTile(map, entities, player, x, y, minDist, maxDist, ignore)
  if not map or not map.isGrassCell then return false end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  if x < 0 or y < 0 or x >= w or y >= h then return false end
  if not map:isGrassCell(x, y) then return false end
  if occupied(entities, x, y, ignore) then return false end
  if map.warpAtCell and map:warpAtCell(x, y) then return false end
  local px = player and player.cellX
  local py = player and player.cellY
  if px ~= nil and py ~= nil then
    local d = chebyshev(x, y, px, py)
    if minDist and d < minDist then return false end
    if maxDist and d > maxDist then return false end
  end
  return true
end

function Grass.pickFree(map, entities, player, minDist, rng, grassList, maxDist)
  grassList = grassList or Grass.cells(map)
  if #grassList == 0 then return nil end
  rng = rng or (love and love.math and love.math.random) or math.random
  minDist = minDist or 0

  local candidates = {}
  for _, cell in ipairs(grassList) do
    if Grass.isValidSpawnTile(map, entities, player, cell.x, cell.y,
                              minDist, maxDist, nil) then
      candidates[#candidates + 1] = cell
    end
  end
  if #candidates == 0 then return nil end
  local pick = candidates[rng(#candidates)]
  return pick.x, pick.y
end

-- Neighboring grass tile for simple wander (stays in encounter zone).
-- Uses maxDist vs player; does not enforce spawn minDist so mons can drift closer.
function Grass.pickNeighbor(map, entities, entity, player, maxDist, rng)
  local dirs = {
    { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 },
  }
  rng = rng or (love and love.math and love.math.random) or math.random
  for i = #dirs, 2, -1 do
    local j = rng(i)
    dirs[i], dirs[j] = dirs[j], dirs[i]
  end
  local fromX, fromY = entity.cellX, entity.cellY
  for _, d in ipairs(dirs) do
    local nx, ny = fromX + d[1], fromY + d[2]
    if Grass.isValidSpawnTile(map, entities, player, nx, ny, 0, maxDist, entity) then
      return nx, ny, d
    end
  end
  return nil
end

return Grass
