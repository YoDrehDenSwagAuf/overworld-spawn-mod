-- Cave reachability: flood-fill / BFS from verified player-entry seeds over
-- walkable cave floor tiles. Computed once per map build (and when the player
-- warps into a new component), never per frame or per spawn.
--
-- A cell is REACHABLE only when the player could actually walk there through
-- consecutive passable cave tiles. Warps are never treated as bridges into
-- cut-off map pockets. Temporary NPC occupancy does not change this mask.
local V = ...

local CaveReachability = {}

CaveReachability.CLASS = {
  REACHABLE = "REACHABLE",
  UNREACHABLE_VALID = "UNREACHABLE_VALID",
  INVALID = "INVALID",
}

local DIRS = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }

function CaveReachability.cellKey(x, y)
  return tostring(x) .. ":" .. tostring(y)
end

-- Prefer engine player-passability when available; otherwise isWalkableCell.
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
  return CaveReachability.isPassableCaveCell(map, x, y)
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

-- Collect BFS seeds: player cell (or neighbors if on warp) plus optional
-- verified entry cells. Does NOT seed every warp neighbor (that would bridge
-- unreachable rooms). Extra seeds must be explicitly provided as player-entry
-- cells (map.entryCells / opts.entrySeeds).
function CaveReachability.collectSeeds(map, player, opts)
  opts = opts or {}
  local seeds = {}
  local seen = {}

  local function addSeed(x, y, source)
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then return end
    if not CaveReachability.isPassableCaveCell(map, x, y) then return end
    local k = CaveReachability.cellKey(x, y)
    if seen[k] then return end
    seen[k] = true
    seeds[#seeds + 1] = { x = x, y = y, source = source or "seed" }
  end

  local sx, sy, source = resolveStart(map, player, opts)
  if sx ~= nil and sy ~= nil then
    if CaveReachability.isPassableCaveCell(map, sx, sy) then
      addSeed(sx, sy, source or "player")
    else
      -- Player on warp/door: seed orthogonal passable neighbors only.
      for _, d in ipairs(DIRS) do
        addSeed(sx + d[1], sy + d[2], "player_neighbor")
      end
    end
  end

  local extras = opts.entrySeeds or (map and map.entryCells) or (map and map.playerEntryCells)
  if type(extras) == "table" then
    for _, s in ipairs(extras) do
      if type(s) == "table" then
        addSeed(s.x or s[1], s.y or s[2], "entry")
      end
    end
  end

  return seeds, sx, sy, source
end

local function bfsFromSeeds(map, seeds)
  local reachable = {}
  local queue = {}
  for _, s in ipairs(seeds or {}) do
    local k = CaveReachability.cellKey(s.x, s.y)
    if not reachable[k] then
      reachable[k] = true
      queue[#queue + 1] = { x = s.x, y = s.y }
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
  return reachable
end

-- Label connected components among passable cells that are NOT player-reachable.
-- Used so scenery Pokémon stay inside their pocket.
function CaveReachability.buildUnreachableComponents(map, reachable)
  local components = {} -- key → componentId
  local cellsByComponent = {} -- componentId → { [key]=true, list={...} }
  local nextId = 0
  if not map then return components, cellsByComponent end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  reachable = reachable or {}

  local function flood(sx, sy, id)
    local q = { { x = sx, y = sy } }
    local qi = 1
    local bag = { list = {} }
    cellsByComponent[id] = bag
    while qi <= #q do
      local c = q[qi]
      qi = qi + 1
      local k = CaveReachability.cellKey(c.x, c.y)
      if not components[k] then
        components[k] = id
        bag[k] = true
        bag.list[#bag.list + 1] = { x = c.x, y = c.y }
        for _, d in ipairs(DIRS) do
          local nx, ny = c.x + d[1], c.y + d[2]
          local nk = CaveReachability.cellKey(nx, ny)
          if not components[nk] and not reachable[nk]
             and CaveReachability.isPassableCaveCell(map, nx, ny) then
            q[#q + 1] = { x = nx, y = ny }
          end
        end
      end
    end
  end

  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local k = CaveReachability.cellKey(x, y)
      if not reachable[k] and not components[k]
         and CaveReachability.isPassableCaveCell(map, x, y) then
        nextId = nextId + 1
        flood(x, y, nextId)
      end
    end
  end
  return components, cellsByComponent
end

-- Build reachableCaveCells["x:y"] = true via BFS from verified player seeds.
function CaveReachability.build(map, player, opts)
  opts = opts or {}
  local result = {
    status = "FAILED", -- READY | FALLBACK | FAILED
    reachable = {},
    reachableCount = 0,
    rejectedUnreachable = 0,
    unreachableValid = {},
    unreachableValidCount = 0,
    unreachableComponents = {},
    cellsByComponent = {},
    startX = nil,
    startY = nil,
    startSource = nil,
    seedCount = 0,
    reason = nil,
    mapId = map and map.id or nil,
  }

  if not map then
    result.reason = "no map"
    return result
  end

  local seeds, sx, sy, source = CaveReachability.collectSeeds(map, player, opts)
  result.startX, result.startY, result.startSource = sx, sy, source
  result.seedCount = #seeds

  if #seeds == 0 then
    result.reason = (sx == nil) and "no player cell" or "player cell not passable"
    result.status = "FAILED"
    return result
  end

  local usedNeighborSeed = false
  for _, s in ipairs(seeds) do
    if s.source == "player_neighbor" then usedNeighborSeed = true end
  end
  if usedNeighborSeed and (not sx or not CaveReachability.isPassableCaveCell(map, sx, sy)) then
    result.status = "FALLBACK"
    result.reason = "seeded from player neighbors"
  end

  local reachable = bfsFromSeeds(map, seeds)
  local count = 0
  for _ in pairs(reachable) do count = count + 1 end
  result.reachable = reachable
  result.reachableCount = count

  local components, byComp = CaveReachability.buildUnreachableComponents(map, reachable)
  result.unreachableComponents = components
  result.cellsByComponent = byComp
  local unreach = {}
  local unreachCount = 0
  for k, _ in pairs(components) do
    unreach[k] = true
    unreachCount = unreachCount + 1
  end
  result.unreachableValid = unreach
  result.unreachableValidCount = unreachCount

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

-- Rebuild when the player stands on a passable cell outside the current mask
-- (typical same-map warp into another room).
function CaveReachability.needsRebuild(data, map, player)
  if not data or data.status == "FAILED" then return true end
  if not map or not player then return false end
  local px, py = tonumber(player.cellX), tonumber(player.cellY)
  if px == nil or py == nil then return false end
  if not CaveReachability.isPassableCaveCell(map, px, py) then return false end
  return not CaveReachability.isReachable(data, px, py)
end

function CaveReachability.isReachable(data, x, y)
  if not data or not data.reachable then return false end
  return data.reachable[CaveReachability.cellKey(x, y)] == true
end

function CaveReachability.classifyCell(map, data, x, y)
  if not CaveReachability.isPassableCaveCell(map, x, y) then
    return CaveReachability.CLASS.INVALID
  end
  if CaveReachability.isReachable(data, x, y) then
    return CaveReachability.CLASS.REACHABLE
  end
  return CaveReachability.CLASS.UNREACHABLE_VALID
end

-- Split a cave cell list into reachable / unreachable-valid pools.
function CaveReachability.partitionCells(cells, map, data)
  local reachable = {}
  local unreachable = {}
  local invalid = 0
  for _, c in ipairs(cells or {}) do
    local cls = CaveReachability.classifyCell(map, data, c.x, c.y)
    if cls == CaveReachability.CLASS.REACHABLE then
      reachable[#reachable + 1] = c
    elseif cls == CaveReachability.CLASS.UNREACHABLE_VALID then
      unreachable[#unreachable + 1] = c
    else
      invalid = invalid + 1
    end
  end
  if data then
    data.rejectedUnreachable = #(unreachable)
    data.rejectedInvalid = invalid
  end
  return reachable, unreachable, invalid
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

-- Mixed quota: ~20% scenery (unreachable valid), never forced above that.
-- Targets below 3 → 0 scenery so a lone spawn is never unreachable.
function CaveReachability.mixedTargets(totalTarget)
  totalTarget = math.max(0, math.floor(tonumber(totalTarget) or 0))
  if totalTarget < 3 then
    return totalTarget, 0
  end
  local scenery = math.floor(totalTarget * 0.20 + 0.5)
  if scenery < 1 then scenery = 1 end
  if scenery > totalTarget then scenery = totalTarget end
  local reachable = totalTarget - scenery
  return reachable, scenery
end

function CaveReachability.componentCells(data, x, y)
  if not data then return nil end
  local k = CaveReachability.cellKey(x, y)
  local id = data.unreachableComponents and data.unreachableComponents[k]
  if not id then
    -- Reachable cells share the player-reachable mask.
    if data.reachable and data.reachable[k] then
      return data.reachable
    end
    return nil
  end
  local bag = data.cellsByComponent and data.cellsByComponent[id]
  return bag
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

function CaveReachability.hudLines(data, opts)
  data = data or {}
  opts = opts or {}
  local lines = {}
  lines[#lines + 1] = ("Cave reachability: %s"):format(tostring(data.status or "FAILED"))
  lines[#lines + 1] = ("Cave mode: %s"):format(tostring(opts.caveMode or "reachable"))
  lines[#lines + 1] = ("Reachable cave cells: %d"):format(
    tonumber(data.reachableCount) or 0)
  lines[#lines + 1] = ("Unreachable valid cells: %d"):format(
    tonumber(data.unreachableValidCount) or 0)
  lines[#lines + 1] = ("Rejected unreachable cells: %d"):format(
    tonumber(data.rejectedUnreachable) or 0)
  if opts.reachableTarget ~= nil or opts.sceneryTarget ~= nil then
    lines[#lines + 1] = ("Map target: %s"):format(tostring(opts.mapTarget or "?"))
    lines[#lines + 1] = ("Reachable target: %s"):format(tostring(opts.reachableTarget or 0))
    lines[#lines + 1] = ("Scenery target: %s"):format(tostring(opts.sceneryTarget or 0))
  end
  if data.reason then
    lines[#lines + 1] = ("Cave reach reason: %s"):format(tostring(data.reason))
  end
  return lines
end

return CaveReachability
