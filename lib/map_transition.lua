-- TransitionContext: classify overworld map changes so connection seams can
-- soft-handoff followers / wilds while warps keep full cleanup.
local V = ...
local MapNeighbors = V.require("map_neighbors")

local MapTransition = {}

MapTransition.KIND = {
  CONNECTION = "connection",
  WARP = "warp",
  DOOR = "door",
  TELEPORT = "teleport",
  BOOT = "boot",
}

local function emptyStats()
  return {
    wildsKept = 0,
    wildsDespawned = 0,
    wildsRebased = 0,
    followersReused = 0,
    followersRecreated = 0,
    rendererRebuilds = 0,
    kind = nil,
    fromMapId = nil,
    toMapId = nil,
  }
end

function MapTransition.emptyStats()
  return emptyStats()
end

function MapTransition.captureExit(logic, ev)
  local mapId = ev and ev.mapId
  local world = logic and logic.mod and logic.mod.world
  local ow = world and world.overworld and world:overworld()
  local player = ow and ow.player
  local wildIds = {}
  for _, id in ipairs((logic and logic.byMap and logic.byMap[mapId]) or {}) do
    wildIds[#wildIds + 1] = id
  end
  -- Also capture wilds still tracked on any map (soft multi-map).
  local allWildIds = {}
  if logic and logic.spawns then
    for id, record in pairs(logic.spawns) do
      if record and record.state ~= "removed" then
        allWildIds[#allWildIds + 1] = id
      end
    end
  end
  local trailers = {}
  if ow and ow.pokepcTrailers then
    for i, t in ipairs(ow.pokepcTrailers) do
      trailers[i] = t
    end
  end
  return {
    mapId = mapId,
    playerX = player and player.cellX,
    playerY = player and player.cellY,
    playerFacing = player and player.facing,
    playerSurfing = player and player.surfing == true,
    wildIds = wildIds,
    allWildIds = allWildIds,
    trailers = trailers,
    trailCells = ow and ow.pokepcTrailCells,
    trailHead = ow and ow.pokepcTrailHead,
    entityCount = ow and ow.entities and #ow.entities or 0,
    npcCount = ow and ow.npcs and #ow.npcs or 0,
    capturedAt = os.time and os.time() or 0,
  }
end

function MapTransition.classify(opts)
  opts = opts or {}
  local fromMapId = opts.fromMapId
  local toMapId = opts.toMapId
  local reason = opts.reason or opts.kind
  local game = opts.game
  local ow = opts.ow

  if reason == MapTransition.KIND.BOOT or reason == "save" or reason == "load"
     or reason == "boot" then
    return MapTransition.KIND.BOOT
  end
  if reason == MapTransition.KIND.TELEPORT or reason == "fly"
     or reason == "teleport" or reason == "dig" or reason == "teleport_fly" then
    return MapTransition.KIND.TELEPORT
  end
  if not fromMapId or not toMapId or fromMapId == toMapId then
    return MapTransition.KIND.WARP
  end

  if MapNeighbors.isSafeInteriorMap(game, toMapId)
     or MapNeighbors.isSafeInteriorMap(game, fromMapId) then
    return MapTransition.KIND.DOOR
  end

  local toType = MapNeighbors.mapType(game, toMapId)
  local fromType = MapNeighbors.mapType(game, fromMapId)
  if toType == "cave" or fromType == "cave"
     or toType == "building" or fromType == "building" then
    return MapTransition.KIND.WARP
  end

  local outdoorPair = MapNeighbors.isOutdoorType(fromType)
    and MapNeighbors.isOutdoorType(toType)
  if not outdoorPair then
    return MapTransition.KIND.WARP
  end

  -- Prefer explicit connection tables from the engine / map def.
  if MapNeighbors.areConnected(game, fromMapId, toMapId, ow) then
    return MapTransition.KIND.CONNECTION
  end

  -- Outdoor route/town/city pairs without tables still use soft handoff when
  -- the exit stash proves a continuous edge crossing (player still present).
  if opts.allowOutdoorHeuristic ~= false and opts.stash
     and opts.stash.playerX ~= nil and ow and ow.player then
    local idFrom = tostring(fromMapId):upper()
    local idTo = tostring(toMapId):upper()
    local routeTown = (idFrom:find("ROUTE", 1, true) and (idTo:find("TOWN", 1, true) or idTo:find("CITY", 1, true)))
      or (idTo:find("ROUTE", 1, true) and (idFrom:find("TOWN", 1, true) or idFrom:find("CITY", 1, true)))
      or (idFrom:find("ROUTE", 1, true) and idTo:find("ROUTE", 1, true))
    if routeTown then
      return MapTransition.KIND.CONNECTION
    end
    -- Generic outdoor↔outdoor with a live player delta: treat as connection.
    return MapTransition.KIND.CONNECTION
  end

  return MapTransition.KIND.WARP
end

function MapTransition.buildContext(opts)
  opts = opts or {}
  local fromMapId = opts.fromMapId
  local toMapId = opts.toMapId
  local kind = MapTransition.classify(opts)
  local offset = { x = 0, y = 0 }
  if kind == MapTransition.KIND.CONNECTION then
    offset = MapNeighbors.connectionOffset(
      opts.game, fromMapId, toMapId, opts.ow, opts.stash)
  end
  local neighborIds, neighborSet = MapNeighbors.activeNeighborMapIds(
    opts.game, toMapId, opts.ow)
  -- Ensure origin stays listed as a neighbor during soft handoff.
  if fromMapId and not neighborSet[fromMapId] then
    neighborIds[#neighborIds + 1] = fromMapId
    neighborSet[fromMapId] = true
  end
  return {
    kind = kind,
    fromMapId = fromMapId,
    toMapId = toMapId,
    connectionOffset = offset,
    neighborMapIds = neighborIds,
    neighborSet = neighborSet,
    stash = opts.stash,
    reason = opts.reason,
    soft = kind == MapTransition.KIND.CONNECTION,
    stats = emptyStats(),
  }
end

function MapTransition.isSoft(ctx)
  return ctx and ctx.kind == MapTransition.KIND.CONNECTION
end

function MapTransition.isHardCleanup(ctx)
  if not ctx then return true end
  local k = ctx.kind
  return k == MapTransition.KIND.WARP
    or k == MapTransition.KIND.DOOR
    or k == MapTransition.KIND.TELEPORT
    or k == MapTransition.KIND.BOOT
end

return MapTransition
