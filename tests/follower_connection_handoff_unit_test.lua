-- Seamless outdoor connection handoff for multi-Pokémon follower trains.
-- Run: lua tests/follower_connection_handoff_unit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. tostring(msg) .. "\n")
  else
    print("ok  " .. tostring(msg))
  end
end
local function eq(a, b, msg)
  check(a == b, string.format("%s (got %s expected %s)", msg, tostring(a), tostring(b)))
end

package.loaded["src.render.SpriteRenderer"] = {
  new = function(def, id) return { def = def, id = id } end,
}

local modules = {}
local listeners = {}
local eventBus = {}
function eventBus:on(name, callback)
  local list = listeners[name] or {}
  listeners[name] = list
  local entry = { callback = callback }
  list[#list + 1] = entry
  return function()
    for i, candidate in ipairs(list) do
      if candidate == entry then table.remove(list, i); break end
    end
    if #list == 0 and listeners[name] == list then listeners[name] = nil end
  end
end
function eventBus:emit(name, payload)
  local snapshot = {}
  for i, entry in ipairs(listeners[name] or {}) do snapshot[i] = entry end
  for _, entry in ipairs(snapshot) do entry.callback(payload) end
end

local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end },
    find = function() return nil end,
    options = { get = function() return nil end },
    exports = {},
    events = eventBus,
  },
  path = ".",
}

function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

modules.config = {
  DEFAULTS = { sprite_style = "pokemmo", follower_count = 6 },
  get = function(_, k) return modules.config.DEFAULTS[k] end,
  spriteStyle = function() return "pokemmo" end,
  debug = function() return false end,
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end,
  debug = function() end,
}
modules.tile = { CELL = 16 }
modules.cell_occupancy = {
  isFollowerEntity = function(e) return e and e.pokepcTrailer == true end,
}
modules.surface = { WATER = "WATER" }

local ControlEngine = V.require("follower/control_engine")

local function makeMap(id, tileset)
  return {
    id = id,
    def = { id = id, tileset = tileset or "OVERWORLD", width = 5, height = 5 },
    inBounds = function(_, x, y)
      return x >= 0 and y >= 0 and x < 10 and y < 10
    end,
    isWalkableCell = function(_, x, y)
      return x >= 0 and y >= 0 and x < 10 and y < 10
    end,
    isWaterCell = function() return false end,
  }
end

local function makeTrailer(slot, mon, x, y)
  return {
    id = "trailer" .. slot,
    pokepcTrailerId = "mon:" .. slot,
    pokepcTrailer = true,
    pokepcTrailerKind = "mon",
    wildsFollower = true,
    wildsFollowerRole = "party_trailer",
    pokepcMon = mon,
    cellX = x, cellY = y,
    px = x * 16, py = y * 16,
    facing = "up",
    moving = false,
    progress = 0,
    passable = true,
    update = function() end,
  }
end

local function makeEngine()
  return ControlEngine.new(V.mod, {
    settings = {
      followerCount = function() return 6 end,
      engineMode = function() return "follow" end,
    },
  })
end

local party = {}
for i = 1, 6 do
  party[i] = { species = "MON" .. i, hp = 20 }
end
local game = {
  save = {
    party = party,
    pokepcFollowerCount = 6,
    pokepcControlMode = "follow",
  },
}

local oldMap = makeMap("PALLET_TOWN")
local newMap = makeMap("ROUTE_1")
local trailers = {}
local cells = {}
for i = 1, 6 do
  trailers[i] = makeTrailer(i, party[i], 4, i)
  cells[i] = { x = 4, y = i }
end
local oldPlayer = { cellX = 4, cellY = 0, facing = "up", surfing = false }
local ow = {
  map = oldMap,
  player = oldPlayer,
  npcs = trailers,
  entities = { oldPlayer, unpack(trailers) },
  pokepcTrailers = trailers,
  pokepcTrailCells = cells,
  pokepcTrailHead = { x = 4, y = 0 },
  _wildsFollowerTrailSurface = "land",
}

----------------------------------------------------------------
-- Preserve and translate a six-member train at an outdoor connection.
----------------------------------------------------------------
local engine = makeEngine()
check(engine:_captureMapExit(game, ow, {
  mapId = "PALLET_TOWN", toMapId = "ROUTE_1",
}), "captures live trailer train on map exit")

-- setMap has installed the destination lists. crossConnection then rebases
-- the player to one cell beyond the southern edge (y=10) before stepping in.
local newPlayer = {
  cellX = 4, cellY = 10, targetX = 4, targetY = 9,
  facing = "up", surfing = false, stepFrames = 16,
}
ow.map = newMap
ow.player = newPlayer
ow.npcs = {}
ow.entities = { newPlayer }
ow.neighbors = { { map = oldMap, ox = 0, oy = 160 } }

check(engine:_queueMapEntry(game, ow, {
  mapId = "ROUTE_1", fromMapId = "PALLET_TOWN",
  map = newMap, via = "connection",
}), "queues outside-to-outside connection handoff")
engine._pendingMapTrailerSync = true
check(engine:_applyConnectionHandoff(ow), "applies pending handoff")
eq(#ow.pokepcTrailers, 6, "all six followers preserved")
eq(#ow.npcs, 6, "all six followers reattached to NPC list")
eq(#ow.entities, 7, "all six followers reattached to draw list")
check(ow.pokepcTrailers[1] == trailers[1], "follower object identity preserved")
eq(trailers[1].cellY, 11, "first follower retains old-side position")
eq(trailers[6].cellY, 16, "tail retains full formation depth")
eq(ow.pokepcTrailHead.y, 10, "trail head translated to pre-seam player cell")
eq(ow.pokepcTrailCells[6].y, 16, "trail buffer translated with tail")
check(ow._wildsFollowerSeamActive == true, "neighbor checks enabled during handoff")
check(engine._pendingMapTrailerSync == false, "fresh-entry reseed suppressed")

for i = 1, 6 do
  check(engine:isFollowerCellAllowed(game, ow, trailers[i], 4, 10 + i, {
    surface = "land", role = "party_trailer",
  }), "old-map neighbor cell remains walkable for follower " .. i)
end

-- Normal synchronization should queue sequential movement, not collapse the
-- train onto the player.  The first tick leaves every follower distinct.
engine:syncTrailers(game, ow, {})
engine:advanceAllTrailers(ow)
local seen = {}
for i, trailer in ipairs(trailers) do
  local key = tostring(trailer.cellX) .. "," .. tostring(trailer.cellY)
  check(not seen[key], "follower " .. i .. " remains on a distinct cell")
  seen[key] = true
  check(not (trailer.cellX == newPlayer.cellX and trailer.cellY == newPlayer.cellY),
        "follower " .. i .. " does not stack on player")
end

check(engine:_finishConnectionHandoffIfComplete(ow) == false,
      "handoff stays active while tail remains on neighbor")
for i, trailer in ipairs(trailers) do
  trailer.cellX, trailer.cellY = 4, i
  trailer.px, trailer.py = 64, i * 16
  trailer.targetX, trailer.targetY = nil, nil
  trailer.moving, trailer.progress = false, 0
  ow.pokepcTrailCells[i] = { x = 4, y = i }
end
check(engine:_finishConnectionHandoffIfComplete(ow) == true,
      "handoff ends after the complete train crosses")
check(ow._wildsFollowerSeamActive == nil, "neighbor exception removed after crossing")

----------------------------------------------------------------
-- Neighbor coordinate resolution works in every connection direction and
-- with a connection offset (offsets are expressed in pixels by the engine).
----------------------------------------------------------------
do
  local probe = { wildsFollowerRole = "party_trailer" }
  ow._wildsFollowerSeamActive = true
  local cases = {
    { name = "north", x = 4, y = 11, ox = 0, oy = 160 },
    { name = "south", x = 4, y = -1, ox = 0, oy = -160 },
    { name = "west", x = 11, y = 4, ox = 160, oy = 0 },
    { name = "east", x = -1, y = 4, ox = -160, oy = 0 },
    { name = "offset", x = 6, y = 11, ox = 32, oy = 160 },
  }
  for _, case in ipairs(cases) do
    ow.neighbors = { { map = oldMap, ox = case.ox, oy = case.oy } }
    check(engine:isFollowerCellAllowed(game, ow, probe, case.x, case.y, {
      surface = "land", role = "party_trailer",
    }), case.name .. " neighbor coordinates resolve")
  end
  ow._wildsFollowerSeamActive = nil
end

----------------------------------------------------------------
-- Warps and indoor connections retain the existing fresh-entry behavior.
----------------------------------------------------------------
ow.map = oldMap
ow.player = oldPlayer
ow.pokepcTrailers = trailers
ow.pokepcTrailCells = cells
ow.pokepcTrailHead = { x = 4, y = 0 }
check(engine:_captureMapExit(game, ow, {
  mapId = "PALLET_TOWN", toMapId = "REDS_HOUSE_1F",
}), "captures before warp for classification")
check(engine:_queueMapEntry(game, ow, {
  mapId = "REDS_HOUSE_1F", fromMapId = "PALLET_TOWN",
  map = makeMap("REDS_HOUSE_1F", "HOUSE"), via = "warp",
}) == false, "warp does not use soft handoff")
check(engine._pendingConnectionHandoff == nil, "warp leaves no pending handoff")

check(engine:_captureMapExit(game, ow, {
  mapId = "PALLET_TOWN", toMapId = "GATE",
}), "captures before classified indoor connection")
check(engine:_queueMapEntry(game, ow, {
  mapId = "GATE", fromMapId = "PALLET_TOWN",
  map = makeMap("GATE", "GATE"), via = "connection",
}) == false, "outside-to-indoor connection keeps fresh-entry behavior")

----------------------------------------------------------------
-- TC-5 ledge continuation: the engine emits a jump as two one-cell scripted
-- moves. Followers may enter the trainer's vacated takeoff cell during the
-- jump, but must not target the landing until the trainer starts leaving it.
----------------------------------------------------------------
do
  local previousCollision = package.loaded["src.world.Collision"]
  package.loaded["src.world.Collision"] = {
    DELTA = {
      up = { 0, -1 }, down = { 0, 1 },
      left = { -1, 0 }, right = { 1, 0 },
    },
  }
  local ledgeEngine = makeEngine()
  ledgeEngine.ledgeStep = function(_, _, _, _, cy, dir)
    return cy == 6 and dir == "down"
  end
  local ledgePlayer = {
    cellX = 4, cellY = 6, targetX = 4, targetY = 7,
    moving = true, facing = "down", stepFrames = 16,
  }
  local ledgeTrailers, ledgeGoals = {}, {}
  for i = 1, 6 do
    ledgeTrailers[i] = makeTrailer(i, party[i], 4, 6 - i)
    ledgeGoals[i] = { x = 4, y = 6 - i }
  end
  local ledgeOw = {
    map = newMap,
    player = ledgePlayer,
    npcs = ledgeTrailers,
    entities = { ledgePlayer, unpack(ledgeTrailers) },
    pokepcTrailers = ledgeTrailers,
    pokepcTrailCells = ledgeGoals,
    pokepcTrailHead = { x = 4, y = 6 },
    _wildsFollowerTrailSurface = "land",
  }
  ledgeEngine:syncTrailers(game, ledgeOw, {})
  eq(ledgeOw.pokepcTrailHead.ledgeHop, "down",
     "TC-5 first ledge phase records pending hop")
  eq(ledgeOw.pokepcTrailCells[1].y, 6,
     "TC-5 first ledge phase retains takeoff goal")

  ledgePlayer.cellY, ledgePlayer.targetY = 7, 8
  ledgeTrailers[1].cellX, ledgeTrailers[1].cellY = 4, 6
  ledgeTrailers[1].px, ledgeTrailers[1].py = 64, 96
  ledgeTrailers[1].targetX, ledgeTrailers[1].targetY = nil, nil
  ledgeTrailers[1].moving, ledgeTrailers[1].progress = false, 0
  ledgeEngine:syncTrailers(game, ledgeOw, {})
  check(ledgeOw.pokepcTrailHead.ledgeHop == nil,
        "TC-5 second ledge phase clears pending hop")
  eq(ledgeOw.pokepcTrailCells[1].y, 6,
     "TC-5 landing remains reserved for trainer after second ledge phase")
  check(ledgeTrailers[1].moving == false,
        "TC-5 lead follower does not hop concurrently onto trainer landing")

  ledgePlayer.cellY, ledgePlayer.targetY = 8, 9
  ledgeEngine:syncTrailers(game, ledgeOw, {})
  eq(ledgeOw.pokepcTrailCells[1].y, 8,
     "TC-5 trainer's first post-hop step releases landing to lead follower")
  check(ledgeTrailers[1].moving == true and ledgeTrailers[1].hopStep == true,
        "TC-5 lead follower hops only after trainer vacates landing")
  check(ledgeOw.pokepcTrailCells[2].y ~= ledgeOw.pokepcTrailCells[1].y,
        "TC-5 ledge landing belongs to exactly one trailer slot")

  -- Reverse-jump mods allow the trainer to traverse a stock one-way ledge
  -- against its declared facing. Follower recognition must match the same
  -- ledge geometry from either side.
  local reverseEngine = makeEngine()
  local reverseMap = makeMap("ROUTE_REVERSE_LEDGE", "OVERWORLD")
  reverseMap.cellTile = function(_, _, y)
    if y == 6 then return 101 end -- normal-direction standing tile
    if y == 7 then return 202 end -- blocked ledge tile
    if y == 8 then return 303 end -- reverse-direction standing tile
    return 0
  end
  local reverseGame = {
    data = { field = { ledges = {
      {
        tileset = "OVERWORLD", facing = "down", input = "down",
        standingTile = 101, ledgeTile = 202,
      },
    } } },
  }
  check(reverseEngine:ledgeStep(reverseGame, { map = reverseMap }, 4, 6, "down"),
        "TC-5 stock-direction ledge geometry is recognized")
  check(reverseEngine:ledgeStep(reverseGame, { map = reverseMap }, 4, 8, "up"),
        "TC-5 reverse-direction ledge geometry is recognized")
  reverseMap.isWalkableCell = function(_, x, y)
    return x >= 0 and y >= 0 and x < 10 and y < 10 and not (x == 4 and y == 7)
  end
  reverseGame.save = game.save
  local reverseTrailers, reverseGoals = {}, {}
  for i = 1, 6 do
    reverseTrailers[i] = makeTrailer(i, party[i], i - 1, 1)
    reverseGoals[i] = { x = i - 1, y = 1 }
  end
  reverseTrailers[1].cellX, reverseTrailers[1].cellY = 4, 8
  reverseTrailers[1].px, reverseTrailers[1].py = 64, 128
  reverseGoals[1] = { x = 4, y = 6 }
  local reversePlayer = { cellX = 9, cellY = 9, facing = "up" }
  local reverseOw = {
    map = reverseMap,
    player = reversePlayer,
    npcs = reverseTrailers,
    entities = { reversePlayer, unpack(reverseTrailers) },
    pokepcTrailers = reverseTrailers,
    pokepcTrailCells = reverseGoals,
    pokepcTrailHead = { x = 9, y = 9 },
    _wildsFollowerTrailSurface = "land",
    _wildsFollowerSeamActive = true,
  }
  reverseEngine:syncTrailers(reverseGame, reverseOw, {})
  check(reverseTrailers[1].moving == true and reverseTrailers[1].hopStep == true,
        "TC-5 follower executes reverse two-cell ledge hop")
  eq(reverseTrailers[1].targetY, 6,
     "TC-5 reverse follower hop targets original takeoff cell")

  -- The ledge's middle cell is deliberately not walkable. A follower must
  -- classify the two-cell hop before ordinary one-cell validation or it will
  -- wait forever at the takeoff edge.
  local blockedLedgeMap = makeMap("ROUTE_LEDGE", "OVERWORLD")
  blockedLedgeMap.isWalkableCell = function(_, x, y)
    return x >= 0 and y >= 0 and x < 10 and y < 10 and not (x == 4 and y == 7)
  end
  local hopTrailers, hopGoals = {}, {}
  for i = 1, 6 do
    hopTrailers[i] = makeTrailer(i, party[i], i - 1, 1)
    hopGoals[i] = { x = i - 1, y = 1 }
  end
  hopTrailers[1].cellX, hopTrailers[1].cellY = 4, 6
  hopTrailers[1].px, hopTrailers[1].py = 64, 96
  hopGoals[1] = { x = 4, y = 8 }
  local hopPlayer = { cellX = 9, cellY = 9, facing = "down" }
  local hopOw = {
    map = blockedLedgeMap,
    player = hopPlayer,
    npcs = hopTrailers,
    entities = { hopPlayer, unpack(hopTrailers) },
    pokepcTrailers = hopTrailers,
    pokepcTrailCells = hopGoals,
    pokepcTrailHead = { x = 9, y = 9 },
    _wildsFollowerTrailSurface = "land",
    _wildsFollowerSeamActive = true,
  }
  ledgeEngine:syncTrailers(game, hopOw, {})
  check(hopTrailers[1].moving == true,
        "TC-5 follower starts hop despite non-walkable middle ledge cell")
  check(hopTrailers[1].hopStep == true,
        "TC-5 follower uses two-cell hop command")
  eq(hopTrailers[1].targetY, 8,
     "TC-5 follower targets the valid ledge landing")

  -- The hop must be a real movement step, not a delayed placement repair.
  -- Halfway through it, pose() should expose both the raised visual position
  -- and the renderer's hopping flag; after one step clock it must land cleanly.
  local previousNPC = package.loaded["src.world.NPC"]
  package.loaded["src.world.NPC"] = {
    new = function(_, _, def)
      return {
        id = def.index,
        cellX = def.x, cellY = def.y,
        px = def.x * 16, py = def.y * 16,
        pose = function(ent)
          return ent.sprite, ent.px, ent.py, ent.facing, 1, false
        end,
      }
    end,
    walkPhase = function() return 1 end,
  }
  local posedHop = ledgeEngine:makeTrailer(
    game, hopOw, 4, 6, "down", "mon", party[1], 1)
  check(posedHop ~= nil, "TC-5 constructs a renderable follower")
  posedHop.moving, posedHop.hopStep = true, true
  posedHop.stepFrames, posedHop.progress = 16, 8
  posedHop.targetX, posedHop.targetY = 4, 8
  local _, _, hopPoseY, _, _, _, poseIsHopping = posedHop:pose()
  eq(hopPoseY, 86, "TC-5 hop pose reaches a ten-pixel midpoint arc")
  check(poseIsHopping == true, "TC-5 hop pose marks the follower as hopping")
  package.loaded["src.world.NPC"] = previousNPC

  for _ = 1, hopTrailers[1].stepFrames do
    ControlEngine.advanceTrailerStep(hopTrailers[1], blockedLedgeMap, hopOw.entities)
  end
  eq(hopTrailers[1].cellY, 8, "TC-5 follower completes at the ledge landing")
  check(hopTrailers[1].moving == false,
        "TC-5 follower is stationary after completing the hop")
  check(hopTrailers[1].hopStep == nil,
        "TC-5 follower clears hop state only after landing")
  package.loaded["src.world.Collision"] = previousCollision
end

----------------------------------------------------------------
-- TC-5: a bent six-member train drains completely after the seam. The seam
-- exception must not retire while followers overlap or remain off-goal.
----------------------------------------------------------------
do
  local drainEngine = makeEngine()
  local drainTrailers, drainCells = {}, {}
  for i = 1, 5 do
    drainTrailers[i] = makeTrailer(i, party[i], 4, 9 - i)
    drainCells[i] = { x = 4, y = 9 - i }
  end
  drainTrailers[6] = makeTrailer(6, party[6], 3, 4)
  drainCells[6] = { x = 3, y = 4 }
  local drainPlayer = { cellX = 4, cellY = 9, facing = "down", surfing = false }
  local drainOw = {
    map = oldMap,
    player = drainPlayer,
    npcs = drainTrailers,
    entities = { drainPlayer, unpack(drainTrailers) },
    pokepcTrailers = drainTrailers,
    pokepcTrailCells = drainCells,
    pokepcTrailHead = { x = 4, y = 9 },
    _wildsFollowerTrailSurface = "land",
  }
  check(drainEngine:_captureMapExit(game, drainOw, {
    mapId = "PALLET_TOWN", toMapId = "ROUTE_1",
  }), "TC-5 captures bent train before drain scenario")
  local routePlayer = {
    cellX = 4, cellY = -1, targetX = 4, targetY = 0,
    facing = "down", surfing = false, stepFrames = 16,
  }
  drainOw.map = newMap
  drainOw.player = routePlayer
  drainOw.npcs = {}
  drainOw.entities = { routePlayer }
  drainOw.neighbors = { { map = oldMap, ox = 0, oy = -160 } }
  check(drainEngine:_queueMapEntry(game, drainOw, {
    mapId = "ROUTE_1", fromMapId = "PALLET_TOWN",
    map = newMap, via = "connection",
  }), "TC-5 queues bent train handoff")
  check(drainEngine:_applyConnectionHandoff(drainOw),
        "TC-5 applies bent train handoff")

  -- A live catch-up frame can put the lead trailer geometrically behind the
  -- second trailer. It must wait instead of stepping into that occupied cell.
  do
    local ys = { 3, 4, 2, 1, 0, -1 }
    local schedulerTrailers, schedulerGoals = {}, {}
    for i = 1, 6 do
      schedulerTrailers[i] = makeTrailer(i, party[i], 4, ys[i])
      schedulerGoals[i] = { x = 4, y = 7 - i }
    end
    local schedulerPlayer = { cellX = 4, cellY = 7, facing = "down" }
    local schedulerOw = {
      map = newMap,
      player = schedulerPlayer,
      npcs = schedulerTrailers,
      entities = { schedulerPlayer, unpack(schedulerTrailers) },
      neighbors = { { map = oldMap, ox = 0, oy = -160 } },
      pokepcTrailers = schedulerTrailers,
      pokepcTrailCells = schedulerGoals,
      pokepcTrailHead = { x = 4, y = 7 },
      _wildsFollowerTrailSurface = "land",
      _wildsFollowerSeamActive = true,
    }
    drainEngine:syncTrailers(game, schedulerOw, {})
    check(schedulerTrailers[1].moving == false,
          "TC-5 lead waits while its next cell is occupied")
    check(schedulerTrailers[1].targetX == nil,
          "TC-5 occupied catch-up cell is not claimed as a target")
  end

  -- Regression fixture from the first live observer run: every trailer had
  -- crossed into the destination bounds, but slots 1 and 2 still occupied the
  -- same cell and the train had not settled onto its distinct goals.  Bounds
  -- alone must not retire the seam exception in this state.
  do
    local duplicateOw = {
      map = newMap,
      _wildsFollowerSeamActive = true,
      pokepcTrailers = {},
      pokepcTrailCells = {},
    }
    for i = 1, 6 do
      local y = (i <= 2) and 4 or (6 - i)
      duplicateOw.pokepcTrailers[i] = makeTrailer(i, party[i], 4, y)
      duplicateOw.pokepcTrailCells[i] = { x = 4, y = 6 - i }
    end
    check(drainEngine:_finishConnectionHandoffIfComplete(duplicateOw) == false,
          "TC-5 live duplicate-cell fixture keeps seam settlement active")
    check(duplicateOw._wildsFollowerSeamActive == true,
          "TC-5 live duplicate-cell fixture is not retired")
  end

  local drainContinuity, retiredSafely, drainGapDetail = true, true, nil
  local function inspectDrain()
    local seen, distinct, compact, stable, previous = {}, true, true, true, nil
    for i, trailer in ipairs(drainOw.pokepcTrailers or {}) do
      local key = tostring(trailer.cellX) .. "," .. tostring(trailer.cellY)
      if seen[key] then distinct = false end
      seen[key] = true
      if previous then
        local gap = math.abs(trailer.cellX - previous.cellX)
          + math.abs(trailer.cellY - previous.cellY)
        if gap ~= 1 then
          compact = false
          drainGapDetail = drainGapDetail or string.format(
            "pair %d gap %d (%d,%d)->(%d,%d)", i - 1, gap,
            previous.cellX, previous.cellY, trailer.cellX, trailer.cellY)
        end
      end
      previous = trailer
      local goal = (drainOw.pokepcTrailCells or {})[i]
      if trailer.moving or not newMap:inBounds(trailer.cellX, trailer.cellY)
         or not goal or not newMap:inBounds(goal.x, goal.y) then
        stable = false
      end
    end
    return distinct, compact, stable
  end
  local function tickDrain()
    local wasActive = drainOw._wildsFollowerSeamActive == true
    drainEngine:syncTrailers(game, drainOw, {})
    drainEngine:advanceAllTrailers(drainOw)
    drainEngine:_finishConnectionHandoffIfComplete(drainOw)
    local distinct, compact, stable = inspectDrain()
    drainContinuity = drainContinuity and distinct and compact
    if wasActive and drainOw._wildsFollowerSeamActive ~= true then
      retiredSafely = distinct and stable
    end
  end
  for _ = 1, 9 do
    routePlayer.targetX, routePlayer.targetY = routePlayer.cellX, routePlayer.cellY + 1
    routePlayer.moving, routePlayer.progress = true, 0
    for frame = 1, 16 do
      if frame == 16 then
        routePlayer.cellY = routePlayer.targetY
        routePlayer.px, routePlayer.py = routePlayer.cellX * 16, routePlayer.cellY * 16
        routePlayer.targetX, routePlayer.targetY = nil, nil
        routePlayer.moving, routePlayer.progress = false, 0
      end
      tickDrain()
    end
  end
  for _ = 1, 96 do tickDrain() end

  local drainSeen, drainDistinct, drainStable = {}, true, true
  for i, trailer in ipairs(drainOw.pokepcTrailers or {}) do
    local key = tostring(trailer.cellX) .. "," .. tostring(trailer.cellY)
    if drainSeen[key] then drainDistinct = false end
    drainSeen[key] = true
    local goal = (drainOw.pokepcTrailCells or {})[i]
    if trailer.moving or not newMap:inBounds(trailer.cellX, trailer.cellY)
       or not goal or not newMap:inBounds(goal.x, goal.y) then
      drainStable = false
    end
  end
  check(drainDistinct, "TC-5 terminal train has six distinct cells")
  check(drainStable, "TC-5 terminal train and retained goals are destination-valid")
  check(drainContinuity,
        "TC-5 train remains distinct and one-cell compact throughout natural drain"
          .. (drainGapDetail and (": " .. drainGapDetail) or ""))
  check(retiredSafely, "TC-5 seam exception does not retire before settlement")
  check(drainOw._wildsFollowerSeamActive == nil,
        "TC-5 seam exception retires only after terminal settlement")
end

----------------------------------------------------------------
-- Acceptance boundary: exercise the actual install/reassert event lifecycle.
-- This is intentionally red until reinstall retires old event subscriptions.
----------------------------------------------------------------
do
  listeners = {}
  local shouldSpawn = function() return false end
  package.loaded["src.world.PikachuFollower"] = {
    update = function(gameArg, owArg)
      if shouldSpawn(gameArg, owArg) then return "spawn" end
      return "skip"
    end,
    onMapEntered = function(gameArg, owArg)
      if shouldSpawn(gameArg, owArg) then return "spawn" end
      return "skip"
    end,
    starterInParty = function() return nil end,
  }
  package.loaded["src.world.NPC"] = {
    new = function()
      return { cellX = 0, cellY = 0, px = 0, py = 0, update = function() end }
    end,
    walkPhase = function() return 0 end,
  }
  local OverworldState = {}
  function OverworldState:update() end
  package.loaded["src.world.OverworldController"] = OverworldState

  local lifecycleEngine = makeEngine()
  lifecycleEngine._gameRef = game
  check(lifecycleEngine:install(), "initial control-engine install")
  lifecycleEngine:restore()
  check(lifecycleEngine:install(), "mods.loaded control-engine reassertion")
  lifecycleEngine:restore()
  check(lifecycleEngine:install(), "game.ready control-engine reassertion")

  eq(#(listeners["map.exited"] or {}), 1,
     "TC-1 exactly one active map.exited listener after reassertions")
  eq(#(listeners["map.entered"] or {}), 1,
     "TC-1 exactly one active map.entered listener after reassertions")

  local proofTrailers, proofCells = {}, {}
  for i = 1, 6 do
    proofTrailers[i] = makeTrailer(i, party[i], 4, i)
    proofCells[i] = { x = 4, y = i }
  end
  local proofPlayer = { cellX = 4, cellY = 0, facing = "up", surfing = false }
  local proofOw = {
    map = oldMap,
    player = proofPlayer,
    npcs = proofTrailers,
    entities = { proofPlayer, unpack(proofTrailers) },
    pokepcTrailers = proofTrailers,
    pokepcTrailCells = proofCells,
    pokepcTrailHead = { x = 4, y = 0 },
    _wildsFollowerTrailSurface = "land",
  }
  game.overworld = proofOw
  eventBus:emit("map.exited", {
    mapId = "PALLET_TOWN", toMapId = "ROUTE_1",
  })
  local destinationPlayer = {
    cellX = 4, cellY = 9, facing = "up", surfing = false,
  }
  proofOw.map = newMap
  proofOw.player = destinationPlayer
  proofOw.npcs = {}
  proofOw.entities = { destinationPlayer }
  eventBus:emit("map.entered", {
    mapId = "ROUTE_1", fromMapId = "PALLET_TOWN",
    map = newMap, via = "connection",
  })
  -- crossConnection performs this rebase after map.entered and before the
  -- wrapped overworld update observes the destination.
  destinationPlayer.cellY = 10
  destinationPlayer.px, destinationPlayer.py = 64, 160
  destinationPlayer.targetX, destinationPlayer.targetY = 4, 9
  proofOw.neighbors = { { map = oldMap, ox = 0, oy = 160 } }

  check(lifecycleEngine._pendingConnectionHandoff ~= nil,
        "TC-2 real event lifecycle retains the queued handoff")
  check(lifecycleEngine:_applyConnectionHandoff(proofOw),
        "TC-2 first post-connection update applies the handoff")
  local attached = 0
  for _, trailer in ipairs(proofTrailers) do
    for _, entity in ipairs(proofOw.entities or {}) do
      if entity == trailer then attached = attached + 1; break end
    end
  end
  eq(attached, 6, "TC-2 six follower identities survive in the draw list")
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nall follower connection handoff tests passed")
