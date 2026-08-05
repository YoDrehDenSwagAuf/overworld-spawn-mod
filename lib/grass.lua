-- Encounter-tile discovery using the same logical tests as Gen1Recomp:
-- Map:isGrassCell / isWaterCell / isWalkableCell. Rejection reasons are
-- returned for diagnostics. Region-aware helpers keep wanderers homebound.
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

function Grass.waterCells(map)
  local out = {}
  if not map or not map.isWaterCell then return out end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  for cy = 0, h - 1 do
    for cx = 0, w - 1 do
      if map:isWaterCell(cx, cy) then
        out[#out + 1] = { x = cx, y = cy }
      end
    end
  end
  return out
end

-- Cave / indoor encounter floors: player-passable floor, non-warp, non-water.
-- Uses the same passability rules as CaveReachability (not a looser walkable scan).
function Grass.caveCells(map)
  local out = {}
  if not map then return out end
  local CaveReachability = V.require("cave_reachability")
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  for cy = 0, h - 1 do
    for cx = 0, w - 1 do
      if CaveReachability.isPassableCaveCell(map, cx, cy) then
        out[#out + 1] = { x = cx, y = cy }
      end
    end
  end
  return out
end

local function occupiedNonPassable(entities, x, y, ignore)
  for _, e in ipairs(entities or {}) do
    if e ~= ignore and not e.passable then
      if e.cellX == x and e.cellY == y then return true end
      if e.targetX == x and e.targetY == y then return true end
    end
  end
  return false
end

local function occupiedByWildSpawn(entities, x, y, ignore)
  for _, e in ipairs(entities or {}) do
    if e ~= ignore and e.overworldWildSpawn then
      if e.cellX == x and e.cellY == y then return true end
      if e.targetX == x and e.targetY == y then return true end
    end
  end
  return false
end

-- Followers EX trailers / Yellow Pikachu follower are passable=true but still
-- block wild spawns and steps. Matches CellOccupancy.isFollowerEntity markers.
local function isFollowerMarker(entity)
  if not entity then return false end
  if entity.pokepcTrailer == true or entity.pikachuFollower == true then
    return true
  end
  if entity.isFollower == true or entity.follower == true then return true end
  local def = entity.sprite and entity.sprite.def
  local sid = def and def.id
  return sid == "SPRITE_POKEPC_MON" or sid == "SPRITE_PLAYER_POKEMON"
end

local function occupiedByFollower(entities, x, y, ignore)
  for _, e in ipairs(entities or {}) do
    if e ~= ignore and isFollowerMarker(e) then
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

local function manhattan(ax, ay, bx, by)
  local dx = ax - bx
  if dx < 0 then dx = -dx end
  local dy = ay - by
  if dy < 0 then dy = -dy end
  return dx + dy
end

function Grass.chebyshev(ax, ay, bx, by)
  return chebyshev(ax, ay, bx, by)
end

function Grass.manhattan(ax, ay, bx, by)
  return manhattan(ax, ay, bx, by)
end

-- Returns ok, reason. Reasons match the fail-safe diagnostics contract.
function Grass.validateSpawnTile(map, entities, player, x, y, minDist, maxDist, ignore)
  if not map then
    return false, "rejected: outside map"
  end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  if x == nil or y == nil or x < 0 or y < 0 or x >= w or y >= h then
    return false, "rejected: outside map"
  end
  if map.inBounds and not map:inBounds(x, y) then
    return false, "rejected: outside map"
  end
  if not map.isGrassCell or not map:isGrassCell(x, y) then
    return false, "rejected: not encounter tile"
  end
  if map.isWalkableCell and not map:isWalkableCell(x, y) then
    return false, "rejected: blocked tile"
  end
  if map.warpAtCell and map:warpAtCell(x, y) then
    return false, "rejected: warp tile"
  end
  if occupiedNonPassable(entities, x, y, ignore) then
    return false, "rejected: occupied by NPC"
  end
  if occupiedByWildSpawn(entities, x, y, ignore) then
    return false, "rejected: occupied by NPC"
  end
  if occupiedByFollower(entities, x, y, ignore) then
    return false, "rejected: occupied by NPC"
  end
  local px = player and player.cellX
  local py = player and player.cellY
  if px ~= nil and py ~= nil then
    if x == px and y == py then
      return false, "rejected: occupied by player"
    end
    local d = chebyshev(x, y, px, py)
    if minDist and d < minDist then
      return false, "rejected: too close to player"
    end
    if maxDist and d > maxDist then
      return false, "rejected: outside search radius"
    end
  end
  return true, nil
end

-- Optional central occupancy rejection used by land + water pickers.
local function occupancyBlocks(occupancy, x, y, ignore)
  if not occupancy then return false end
  if occupancy.isOccupied and occupancy:isOccupied(x, y, ignore) then
    return true
  end
  if occupancy.isReserved and occupancy:isReserved(x, y, ignore) then
    return true
  end
  return false
end

function Grass.isValidSpawnTile(map, entities, player, x, y, minDist, maxDist, ignore)
  local ok = Grass.validateSpawnTile(map, entities, player, x, y, minDist, maxDist, ignore)
  return ok
end

-- Validate against an optional membership predicate (home region / surface).
function Grass.validateEligibleTile(map, entities, player, x, y, minDist, maxDist,
                                    ignore, membership, mode, occupancy)
  mode = mode or "grass"
  if membership and not membership[x .. "," .. y] then
    return false, "rejected: outside region"
  end
  if occupancyBlocks(occupancy, x, y, ignore) then
    return false, "rejected: occupied by NPC"
  end
  if mode == "grass" then
    return Grass.validateSpawnTile(map, entities, player, x, y, minDist, maxDist, ignore)
  end
  if mode == "water" then
    if not map or not map.isWaterCell or not map:isWaterCell(x, y) then
      return false, "rejected: not encounter tile"
    end
    if map.warpAtCell and map:warpAtCell(x, y) then
      return false, "rejected: warp tile"
    end
    if occupiedNonPassable(entities, x, y, ignore)
       or occupiedByWildSpawn(entities, x, y, ignore)
       or occupiedByFollower(entities, x, y, ignore) then
      return false, "rejected: occupied by NPC"
    end
    local px = player and player.cellX
    local py = player and player.cellY
    if px ~= nil and py ~= nil then
      if x == px and y == py then
        return false, "rejected: occupied by player"
      end
      local d = chebyshev(x, y, px, py)
      if minDist and d < minDist then
        return false, "rejected: too close to player"
      end
      if maxDist and d > maxDist then
        return false, "rejected: outside search radius"
      end
    end
    return true, nil
  end
  -- walkable / cave
  return Grass.validateWalkableTile(map, entities, player, x, y, minDist, maxDist, ignore)
end

local function tooCloseToSpawns(x, y, occupiedSpawns, minSep, metric)
  if not occupiedSpawns or not minSep or minSep <= 0 then return false end
  local distFn = (metric == "manhattan") and manhattan or chebyshev
  for _, s in ipairs(occupiedSpawns) do
    if distFn(x, y, s.x, s.y) < minSep then return true end
  end
  return false
end

-- Progressive search: prefer configured min/max, then relax minDist down to 1,
-- then expand maxDist so small maps are not left with zero candidates.
-- opts: { membership, mode, occupiedSpawns, minSeparation, preferFar,
--         strictSeparation, separationMetric ("chebyshev"|"manhattan") }
function Grass.pickFree(map, entities, player, minDist, rng, grassList, maxDist, onReject, opts)
  opts = opts or {}
  grassList = grassList or Grass.cells(map)
  if #grassList == 0 then
    if onReject then onReject("rejected: not encounter tile") end
    return nil, nil, "rejected: not encounter tile"
  end
  rng = rng or (love and love.math and love.math.random) or math.random
  minDist = minDist or 0
  maxDist = maxDist or 12
  local mode = opts.mode or "grass"
  local membership = opts.membership
  local occupiedSpawns = opts.occupiedSpawns
  local minSep = opts.minSeparation or 0
  local occupancy = opts.occupancy
  local strictSep = opts.strictSeparation == true
  local sepMetric = opts.separationMetric or "chebyshev"

  local function collect(useMin, useMax, enforceSep)
    local candidates = {}
    for _, cell in ipairs(grassList) do
      local ok, reason = Grass.validateEligibleTile(
        map, entities, player, cell.x, cell.y, useMin, useMax, nil,
        membership, mode, occupancy)
      if ok and enforceSep
         and tooCloseToSpawns(cell.x, cell.y, occupiedSpawns, minSep, sepMetric) then
        ok = false
        reason = "rejected: too close to spawn"
      end
      if ok then
        candidates[#candidates + 1] = cell
      elseif onReject and reason then
        onReject(reason)
      end
    end
    return candidates
  end

  local candidates = collect(minDist, maxDist, true)

  -- Soft separation: may drop spacing when nothing fits.
  -- Strict (water): never fully ignore spacing — caller reduces target instead.
  if #candidates == 0 and not strictSep then
    candidates = collect(minDist, maxDist, false)
  end

  if #candidates == 0 then
    for relax = minDist - 1, 1, -1 do
      candidates = collect(relax, maxDist, true)
      if #candidates == 0 and not strictSep then
        candidates = collect(relax, maxDist, false)
      end
      if #candidates > 0 then
        minDist = relax
        break
      end
    end
  end

  if #candidates == 0 then
    local expand = maxDist
    local mapSpan = 0
    if map then
      mapSpan = math.max(map.widthCells or 0, map.heightCells or 0)
    end
    local hardMax = math.max(maxDist, mapSpan, 32)
    while #candidates == 0 and expand < hardMax do
      expand = expand + 4
      -- Keep separation under strict mode while expanding search radius.
      candidates = collect(1, expand, true)
      if #candidates == 0 and not strictSep then
        candidates = collect(1, expand, false)
      end
    end
    if #candidates > 0 then
      maxDist = expand
    end
  end

  if #candidates == 0 then
    return nil, nil, "rejected: no eligible tiles"
  end

  -- Prefer candidates farther from the player when distributing on long routes.
  if opts.preferFar and player and #candidates > 1 then
    table.sort(candidates, function(a, b)
      local da = chebyshev(a.x, a.y, player.cellX, player.cellY)
      local db = chebyshev(b.x, b.y, player.cellX, player.cellY)
      return da > db
    end)
    local top = math.max(1, math.floor(#candidates * 0.4))
    local pick = candidates[rng(top)]
    return pick.x, pick.y, nil
  end

  local pick = candidates[rng(#candidates)]
  return pick.x, pick.y, nil
end

-- Validate a free walkable tile without requiring an encounter/grass cell.
-- Used only by developer Test spawn when allow_debug_spawn_outside_encounter_areas.
function Grass.validateWalkableTile(map, entities, player, x, y, minDist, maxDist, ignore)
  if not map then
    return false, "rejected: outside map"
  end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  if x == nil or y == nil or x < 0 or y < 0 or x >= w or y >= h then
    return false, "rejected: outside map"
  end
  if map.inBounds and not map:inBounds(x, y) then
    return false, "rejected: outside map"
  end
  if map.isWalkableCell and not map:isWalkableCell(x, y) then
    return false, "rejected: blocked tile"
  end
  if map.warpAtCell and map:warpAtCell(x, y) then
    return false, "rejected: warp tile"
  end
  if occupiedNonPassable(entities, x, y, ignore) then
    return false, "rejected: occupied by NPC"
  end
  if occupiedByWildSpawn(entities, x, y, ignore) then
    return false, "rejected: occupied by NPC"
  end
  if occupiedByFollower(entities, x, y, ignore) then
    return false, "rejected: occupied by NPC"
  end
  local px = player and player.cellX
  local py = player and player.cellY
  if px ~= nil and py ~= nil then
    if x == px and y == py then
      return false, "rejected: occupied by player"
    end
    local d = chebyshev(x, y, px, py)
    if minDist and d < minDist then
      return false, "rejected: too close to player"
    end
    if maxDist and d > maxDist then
      return false, "rejected: outside search radius"
    end
  end
  return true, nil
end

function Grass.walkableCells(map)
  local out = {}
  if not map then return out end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  for cy = 0, h - 1 do
    for cx = 0, w - 1 do
      local walkable = true
      if map.isWalkableCell then
        walkable = map:isWalkableCell(cx, cy)
      end
      if walkable then
        out[#out + 1] = { x = cx, y = cy }
      end
    end
  end
  return out
end

function Grass.pickFreeWalkable(map, entities, player, minDist, rng, maxDist, onReject)
  local list = Grass.walkableCells(map)
  if #list == 0 then
    if onReject then onReject("rejected: no eligible tiles") end
    return nil, nil, "rejected: no eligible tiles"
  end
  rng = rng or (love and love.math and love.math.random) or math.random
  minDist = minDist or 0
  maxDist = maxDist or 12

  local function collect(useMin, useMax)
    local candidates = {}
    for _, cell in ipairs(list) do
      local ok, reason = Grass.validateWalkableTile(
        map, entities, player, cell.x, cell.y, useMin, useMax, nil)
      if ok then
        candidates[#candidates + 1] = cell
      elseif onReject and reason then
        onReject(reason)
      end
    end
    return candidates
  end

  local candidates = collect(minDist, maxDist)
  if #candidates == 0 then
    for relax = minDist - 1, 1, -1 do
      candidates = collect(relax, maxDist)
      if #candidates > 0 then break end
    end
  end
  if #candidates == 0 then
    local expand = maxDist
    local mapSpan = math.max(map.widthCells or 0, map.heightCells or 0)
    local hardMax = math.max(maxDist, mapSpan, 32)
    while #candidates == 0 and expand < hardMax do
      expand = expand + 4
      candidates = collect(1, expand)
    end
  end
  if #candidates == 0 then
    return nil, nil, "No valid test spawn position on the current map."
  end
  local pick = candidates[rng(#candidates)]
  return pick.x, pick.y, nil
end

-- Neighboring grass tile for simple wander (stays in encounter zone).
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
