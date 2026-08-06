-- Soft map-connection handoff for wild overworld Pokémon.
-- Keeps origin-map spawns near the player across outdoor seams; hard warps
-- still use SpawnLogic full cleanup.
local V = ...
local Config = V.require("config")
local MapNeighbors = V.require("map_neighbors")
local MapTransition = V.require("map_transition")
local Grass = V.require("grass")

local WildTransition = {}

local DEFAULT_KEEP = 10
local DEFAULT_HARD = 18
local DEFAULT_MAX_AGE_STEPS = 48

function WildTransition.keepRadius(mod)
  local v = Config.get and Config.get(mod, "connection_keep_radius")
  return tonumber(v) or Config.DEFAULTS.connection_keep_radius or DEFAULT_KEEP
end

function WildTransition.hardDespawnRadius(mod)
  local v = Config.get and Config.get(mod, "connection_hard_despawn_radius")
  return tonumber(v) or Config.DEFAULTS.connection_hard_despawn_radius or DEFAULT_HARD
end

function WildTransition.maxTransitionAgeSteps(mod)
  local v = Config.get and Config.get(mod, "connection_max_age_steps")
  return tonumber(v) or Config.DEFAULTS.connection_max_age_steps or DEFAULT_MAX_AGE_STEPS
end

local function stampOrigin(entity, record, mapId)
  if record then
    record.wildsOriginMapId = record.wildsOriginMapId or record.mapId or mapId
    record.wildsSpawnRegionId = record.wildsSpawnRegionId or record.homeRegionId
    record.wildsIsNeighbor = record.wildsOriginMapId ~= mapId
  end
  if entity then
    entity.wildsOriginMapId = (record and record.wildsOriginMapId) or mapId
    entity.wildsSpawnRegionId = record and (record.wildsSpawnRegionId or record.homeRegionId)
    entity.wildsIsNeighbor = entity.wildsOriginMapId ~= mapId
    if entity.cellX ~= nil then
      entity.wildsWorldX = entity.cellX
      entity.wildsWorldY = entity.cellY
    end
  end
end

function WildTransition.ensureOwnership(logic, id)
  local record = logic.spawns[id]
  local entity = logic.entities[id]
  if not record and not entity then return end
  stampOrigin(entity, record, record and record.mapId or logic.activeMapId)
end

local function rebaseEntityCoords(entity, record, offset)
  local dx = tonumber(offset and offset.x) or 0
  local dy = tonumber(offset and offset.y) or 0
  if dx == 0 and dy == 0 then return end

  if entity then
    if entity.cellX ~= nil then entity.cellX = entity.cellX + dx end
    if entity.cellY ~= nil then entity.cellY = entity.cellY + dy end
    if entity.px ~= nil then entity.px = entity.px + dx * 16 end
    if entity.py ~= nil then entity.py = entity.py + dy * 16 end
    if entity.targetX ~= nil then entity.targetX = entity.targetX + dx end
    if entity.targetY ~= nil then entity.targetY = entity.targetY + dy end
    entity.wildsWorldX = entity.cellX
    entity.wildsWorldY = entity.cellY
    local bx = entity.behaviorState
    if bx then
      if bx.anchorX ~= nil then bx.anchorX = bx.anchorX + dx end
      if bx.anchorY ~= nil then bx.anchorY = bx.anchorY + dy end
      if bx.homeX ~= nil then bx.homeX = bx.homeX + dx end
      if bx.homeY ~= nil then bx.homeY = bx.homeY + dy end
      if bx.targetX ~= nil then bx.targetX = bx.targetX + dx end
      if bx.targetY ~= nil then bx.targetY = bx.targetY + dy end
      if bx.wanderAnchorX ~= nil then bx.wanderAnchorX = bx.wanderAnchorX + dx end
      if bx.wanderAnchorY ~= nil then bx.wanderAnchorY = bx.wanderAnchorY + dy end
    end
  end
  if record then
    if record.x ~= nil then record.x = record.x + dx end
    if record.y ~= nil then record.y = record.y + dy end
  end
end

local function findSafeCell(logic, ow, entity, x, y)
  local occ = logic.occupancy
  local savedPx, savedPy = entity and entity.px, entity and entity.py
  local function attempt(nx, ny, snapped)
    if not entity then return nx, ny end
    if occ and occ.rebaseEntity then
      local ok = occ:rebaseEntity(entity, nx, ny)
      if not ok then return nil end
    else
      entity.cellX, entity.cellY = nx, ny
    end
    if snapped or savedPx == nil or savedPy == nil then
      entity.px, entity.py = nx * 16, ny * 16
    else
      entity.px, entity.py = savedPx, savedPy
    end
    return nx, ny
  end

  if attempt(x, y, false) then return x, y end
  local deltas = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
    { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 },
  }
  for _, d in ipairs(deltas) do
    local nx, ny = x + d[1], y + d[2]
    local map = ow and ow.map
    if map and map.inBounds and map:inBounds(nx, ny)
       and map.isWalkableCell and not map:isWalkableCell(nx, ny) then
      -- blocked root cell
    else
      if attempt(nx, ny, true) then return nx, ny end
    end
  end
  return nil
end

function WildTransition.rebaseAll(logic, ctx)
  local offset = ctx and ctx.connectionOffset or { x = 0, y = 0 }
  local stats = ctx.stats or MapTransition.emptyStats()
  local world = logic.mod.world
  local ow = world and world.overworld and world:overworld()
  local doomed = {}

  -- Release all first so rebase targets are free within the moved set.
  if logic.occupancy then
    for id, record in pairs(logic.spawns) do
      local entity = logic.entities[id]
      if record and record.state ~= Config.STATE.REMOVED and entity then
        logic.occupancy:releaseEntity(entity)
      end
    end
  end

  for id, record in pairs(logic.spawns) do
    local entity = logic.entities[id]
    if record and record.state ~= Config.STATE.REMOVED then
      stampOrigin(entity, record, record.mapId or ctx.fromMapId)
      rebaseEntityCoords(entity, record, offset)
      stats.wildsRebased = stats.wildsRebased + 1
      if entity then
        entity.wildsIsNeighbor = entity.wildsOriginMapId ~= ctx.toMapId
        local x = entity.cellX or record.x
        local y = entity.cellY or record.y
        local sx, sy = findSafeCell(logic, ow, entity, x, y)
        if not sx then
          doomed[#doomed + 1] = id
        else
          record.x, record.y = sx, sy
          if entity.px == nil then entity.px = sx * 16 end
          if entity.py == nil then entity.py = sy * 16 end
          if logic._attach then
            pcall(logic._attach, logic, entity)
          end
        end
      end
    end
  end

  for _, id in ipairs(doomed) do
    logic:_despawn(id, true)
    stats.wildsDespawned = stats.wildsDespawned + 1
  end
  return stats
end

function WildTransition.shouldKeep(logic, ctx, id, player)
  local record = logic.spawns[id]
  local entity = logic.entities[id]
  if not record or record.state == Config.STATE.REMOVED then
    return false, "removed"
  end
  local origin = (entity and entity.wildsOriginMapId)
    or record.wildsOriginMapId or record.mapId
  if MapNeighbors.isSafeInteriorMap(ctx and ctx.game, ctx and ctx.toMapId) then
    return false, "safe_interior"
  end
  if origin and MapNeighbors.isSafeInteriorMap(ctx and ctx.game, origin) then
    return false, "origin_interior"
  end
  -- Never keep across door/warp kinds.
  if ctx and MapTransition.isHardCleanup(ctx) then
    return false, "hard_transition"
  end
  local neighborSet = ctx and ctx.neighborSet or {}
  if origin and not neighborSet[origin] and origin ~= (ctx and ctx.toMapId)
     and origin ~= (ctx and ctx.fromMapId) then
    return false, "origin_not_neighbor"
  end
  if entity and entity.behaviorState and entity.behaviorState.chasing then
    return true, "chasing"
  end
  local x = (entity and entity.cellX) or record.x
  local y = (entity and entity.cellY) or record.y
  if not player or x == nil or y == nil then
    return true, "no_player"
  end
  local d = Grass.chebyshev(x, y, player.cellX, player.cellY)
  local hard = WildTransition.hardDespawnRadius(logic.mod)
  if d > hard then
    return false, "hard_radius"
  end
  local age = record.wildsTransitionAgeSteps or 0
  if age > WildTransition.maxTransitionAgeSteps(logic.mod)
     and d > WildTransition.keepRadius(logic.mod) then
    return false, "max_age"
  end
  return true, "ok"
end

function WildTransition.pruneAfterTransition(logic, ctx)
  local stats = ctx.stats or MapTransition.emptyStats()
  local world = logic.mod.world
  local ow = world and world.overworld and world:overworld()
  local player = ow and ow.player
  local doomed = {}
  for id in pairs(logic.spawns) do
    local keep, reason = WildTransition.shouldKeep(logic, ctx, id, player)
    if keep then
      stats.wildsKept = stats.wildsKept + 1
      local record = logic.spawns[id]
      local entity = logic.entities[id]
      if record then
        record.wildsTransitionAgeSteps = 0
        record.wildsLastNearPlayerTick = (record.wildsLastNearPlayerTick or 0)
      end
      if entity then
        entity.wildsLastNearPlayerTick = entity.wildsLastNearPlayerTick or 0
      end
      stampOrigin(entity, record, ctx.toMapId)
    else
      doomed[#doomed + 1] = { id = id, reason = reason }
    end
  end
  for _, item in ipairs(doomed) do
    logic:_despawn(item.id, true)
    stats.wildsDespawned = stats.wildsDespawned + 1
  end
  if logic._recountRegions then logic:_recountRegions() end
  return stats
end

function WildTransition.streamStep(logic, ow)
  if not logic or not ow or not ow.player then return 0 end
  local player = ow.player
  local keepR = WildTransition.keepRadius(logic.mod)
  local hardR = WildTransition.hardDespawnRadius(logic.mod)
  local rootId = ow.map and ow.map.id
  local game = logic.mod.world and logic.mod.world.game
  local _, neighborSet = MapNeighbors.activeNeighborMapIds(game, rootId, ow)
  if logic._softNeighborSet then
    for k, v in pairs(logic._softNeighborSet) do
      if v then neighborSet[k] = true end
    end
  end
  local doomed = {}
  for id, record in pairs(logic.spawns) do
    if record.state == Config.STATE.AVAILABLE then
      local entity = logic.entities[id]
      local origin = (entity and entity.wildsOriginMapId)
        or record.wildsOriginMapId or record.mapId
      local x = (entity and entity.cellX) or record.x
      local y = (entity and entity.cellY) or record.y
      local d = Grass.chebyshev(x or 0, y or 0, player.cellX, player.cellY)
      record.wildsTransitionAgeSteps = (record.wildsTransitionAgeSteps or 0) + 1
      if d <= keepR then
        record.wildsLastNearPlayerTick = record.wildsTransitionAgeSteps
        if entity then
          entity.wildsLastNearPlayerTick = record.wildsTransitionAgeSteps
        end
      end
      local chasing = entity and entity.behaviorState and entity.behaviorState.chasing
      if not chasing then
        if d > hardR then
          doomed[#doomed + 1] = id
        elseif origin and rootId and origin ~= rootId and not neighborSet[origin] then
          doomed[#doomed + 1] = id
        elseif (record.wildsTransitionAgeSteps or 0)
               > WildTransition.maxTransitionAgeSteps(logic.mod)
               and d > keepR then
          doomed[#doomed + 1] = id
        end
      end
    end
  end
  for _, id in ipairs(doomed) do
    logic:_despawn(id, true)
  end
  if #doomed > 0 and logic._recountRegions then logic:_recountRegions() end
  return #doomed
end

function WildTransition.tagNewSpawn(entity, record, mapId)
  stampOrigin(entity, record, mapId)
  if record then
    record.wildsIsNeighbor = false
    record.wildsTransitionAgeSteps = 0
  end
  if entity then
    entity.wildsIsNeighbor = false
  end
end

-- Town / city maps must not gain new wild spawns from this soft path.
function WildTransition.allowsNewSpawns(game, mapId)
  local t = MapNeighbors.mapType(game, mapId)
  if t == "town" or t == "city" then return false end
  if MapNeighbors.isSafeInteriorMap(game, mapId) then return false end
  return true
end

return WildTransition
