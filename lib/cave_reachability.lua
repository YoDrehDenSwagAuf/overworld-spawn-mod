-- Cave reachability: flood-fill / BFS from the player cell over walkable
-- cave floor tiles. Computed once per map build (and on collision refresh),
-- never per frame or per spawn.
--
-- A cell is reachable only when the player could actually walk there through
-- consecutive passable cave tiles. Warps are never treated as bridges into
-- cut-off map pockets.
local V = ...

local CaveReachability = {}

local DIRS = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }

function CaveReachability.cellKey(x, y)
  return tostring(x) .. ":" .. tostring(y)
end

-- Prefer engine passability when available; otherwise isWalkableCell.
-- Warps / doors / stairs (when exposed as warps) are never traversable seeds.
function CaveReachability.isPassableCaveCell(map, x, y)
  if not map then return false end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  if x < 0 or y < 0 or x >= w or y >= h then return false end
  if map.inBounds and not map:inBounds(x, y) then return false end
  if map.warpAtCell and map:warpAtCell(x, y) then return false end
  if map.isWaterCell and map:isWaterCell(x, y) then return false end
  -- Prefer a player-passability helper when the engine exposes one.
  if type(map.isPlayerPassableCell) == "function" then
    return map:isPlayerPassableCell(x, y) == true
  end
  if type(map.canPlayerWalk) == "function" then
    return map:canPlayerWalk(x, y) == true
  end
  if type(map.isPassableCell) == "function" then
    return map:isPassableCell(x, y) == true
  end
  if map.isWalkableCell then
    return map:isWalkableCell(x, y) == true
  end
  return true
end

-- True when a cell is a valid cave encounter/spawn candidate (walkable floor,
-- not warp, not water). Reachability is checked separately.
function CaveReachability.isCaveFloorCell(map, x, y)
  if not CaveReachability.isPassableCaveCell(map, x, y) then
    return false
  end
  return true
end

local function resolveStart(map, player, opts)
  opts = opts or {}
  if opts.startX and opts.startY then
    return tonumber(opts.startX), tonumber(opts.startY), "opts"
  end
  if player and player.cellX ~= nil and player.cellY ~= nil then
    return tonumber(player.cellX), tonumber(player.cellY), "player"
  end
  if opts.fallbackX and opts.fallbackY then
    return tonumber(opts.fallbackX), tonumber(opts.fallbackY), "fallback"
  end
  return nil, nil, nil
end

-- Build reachableCaveCells["x:y"] = true via BFS from the player start cell.
-- Returns a result table used by spawn/movement and the Dev Overlay HUD.
function CaveReachability.build(map, player, opts)
  opts = opts or {}
  local result = {
    status = "FAILED", -- READY | FALLBACK | FAILED
    reachable = {},
    reachableCount = 0,
    rejectedUnreachable = 0,
    startX = nil,
    startY = nil,
    startSource = nil,
    reason = nil,
  }

  if not map then
    result.reason = "no map"
    return result
  end

  local sx, sy, source = resolveStart(map, player, opts)
  result.startX, result.startY, result.startSource = sx, sy, source
  if sx == nil or sy == nil then
    result.reason = "no player cell"
    result.status = "FAILED"
    return result
  end

  -- If the player stands on a warp/door, seed from orthogonal passable neighbors.
  local seeds = {}
  if CaveReachability.isPassableCaveCell(map, sx, sy) then
    seeds[#seeds + 1] = { x = sx, y = sy }
  else
    for _, d in ipairs(DIRS) do
      local nx, ny = sx + d[1], sy + d[2]
      if CaveReachability.isPassableCaveCell(map, nx, ny) then
        seeds[#seeds + 1] = { x = nx, y = ny }
      end
    end
    if #seeds == 0 then
      result.reason = "player cell not passable"
      result.status = "FAILED"
      return result
    end
    result.status = "FALLBACK"
    result.reason = "seeded from player neighbors"
  end

  local reachable = {}
  local queue = {}
  for _, s in ipairs(seeds) do
    local k = CaveReachability.cellKey(s.x, s.y)
    if not reachable[k] then
      reachable[k] = true
      queue[#queue + 1] = s
    end
  end

  local qi = 1
  while qi <= #queue do
    local c = queue[qi]
    qi = qi + 1
    for _, d in ipairs(DIRS) do
      local nx, ny = c.x + d[1], c.y + d[2]
      local nk = CaveReachability.cellKey(nx, ny)
      if not reachable[nk] and CaveReachability.isPassableCaveCell(map, nx, ny) then
        reachable[nk] = true
        queue[#queue + 1] = { x = nx, y = ny }
      end
    end
  end

  local count = 0
  for _ in pairs(reachable) do count = count + 1 end
  result.reachable = reachable
  result.reachableCount = count
  if result.status ~= "FALLBACK" then
    result.status = count > 0 and "READY" or "FAILED"
  elseif count == 0 then
    result.status = "FAILED"
  end
  if count == 0 and not result.reason then
    result.reason = "empty reachable set"
  end
  return result
end

function CaveReachability.isReachable(data, x, y)
  if not data or not data.reachable then return false end
  return data.reachable[CaveReachability.cellKey(x, y)] == true
end

-- Filter a cave cell list to reachable cells. Counts rejected unreachable.
function CaveReachability.filterCells(cells, data)
  local out = {}
  local rejected = 0
  if not data or data.status == "FAILED" or not data.reachable then
    return out, #(cells or {}), "FAILED"
  end
  for _, c in ipairs(cells or {}) do
    if CaveReachability.isReachable(data, c.x, c.y) then
      out[#out + 1] = c
    else
      rejected = rejected + 1
    end
  end
  data.rejectedUnreachable = rejected
  return out, rejected, data.status
end

-- Conservative nearby walkable cells when BFS failed (never unfiltered cave).
function CaveReachability.conservativeNearPlayer(map, player, maxDist)
  local out = {}
  if not map or not player then return out end
  local px, py = tonumber(player.cellX), tonumber(player.cellY)
  if px == nil or py == nil then return out end
  maxDist = tonumber(maxDist) or 4
  for dy = -maxDist, maxDist do
    for dx = -maxDist, maxDist do
      local x, y = px + dx, py + dy
      local man = (dx < 0 and -dx or dx) + (dy < 0 and -dy or dy)
      if man <= maxDist and CaveReachability.isPassableCaveCell(map, x, y) then
        out[#out + 1] = { x = x, y = y }
      end
    end
  end
  return out
end

function CaveReachability.hudLines(data)
  data = data or {}
  local lines = {}
  lines[#lines + 1] = ("Cave reachability: %s"):format(tostring(data.status or "FAILED"))
  lines[#lines + 1] = ("Reachable cave cells: %d"):format(
    tonumber(data.reachableCount) or 0)
  lines[#lines + 1] = ("Rejected unreachable cells: %d"):format(
    tonumber(data.rejectedUnreachable) or 0)
  if data.reason then
    lines[#lines + 1] = ("Cave reach reason: %s"):format(tostring(data.reason))
  end
  return lines
end

return CaveReachability
