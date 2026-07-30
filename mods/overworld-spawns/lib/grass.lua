-- Grass-cell discovery for the active runtime map.
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

local function occupied(entities, x, y)
  for _, e in ipairs(entities or {}) do
    if e.cellX == x and e.cellY == y then return true end
    if e.targetX == x and e.targetY == y then return true end
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

function Grass.pickFree(map, entities, player, minDist, rng, grassList)
  grassList = grassList or Grass.cells(map)
  if #grassList == 0 then return nil end
  rng = rng or (love and love.math and love.math.random) or math.random
  minDist = minDist or 0
  local px = player and player.cellX
  local py = player and player.cellY

  local candidates = {}
  for _, cell in ipairs(grassList) do
    if not occupied(entities, cell.x, cell.y) then
      if px == nil or chebyshev(cell.x, cell.y, px, py) >= minDist then
        candidates[#candidates + 1] = cell
      end
    end
  end
  if #candidates == 0 then return nil end
  local pick = candidates[rng(#candidates)]
  return pick.x, pick.y
end

return Grass
