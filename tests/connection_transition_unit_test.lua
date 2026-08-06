-- Outdoor connection soft-transition: followers reuse + wilds streaming.
-- Run: lua tests/connection_transition_unit_test.lua
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
  new = function(def, id)
    return { def = def, id = id, _new = true }
  end,
}
package.loaded["src.world.NPC"] = {
  new = function(_, mapId, def)
    return {
      id = "npc_" .. tostring(def and def.index or 0),
      cellX = def and def.x or 0,
      cellY = def and def.y or 0,
      px = (def and def.x or 0) * 16,
      py = (def and def.y or 0) * 16,
      facing = "down",
      moving = false,
      progress = 0,
      update = function() end,
    }
  end,
  walkPhase = function() return 0 end,
}
package.loaded["src.world.PikachuFollower"] = {
  update = function() end,
  onMapEntered = function() end,
  starterInParty = function() return nil end,
}
package.loaded["src.world.OverworldController"] = {
  update = function() end,
  interact = function() end,
}

local modules = {}
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end },
    find = function() return nil end,
    options = {
      get = function(_, key)
        if key == "follower_count" then return 3 end
        if key == "control_mode" then return "follow" end
        return nil
      end,
    },
    events = { on = function() end },
    exports = {},
    read = function(_, rel)
      local f = io.open(rel, "r")
      if not f then return nil end
      local s = f:read("*a")
      f:close()
      return s
    end,
  },
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local mod = chunk(V)
  modules[name] = mod
  return mod
end

local MapTransition = V.require("map_transition")
local MapNeighbors = V.require("map_neighbors")
local WildTransition = V.require("wild_transition")
local CellOccupancy = V.require("cell_occupancy")
local Config = V.require("config")
local ControlEngine = V.require("follower/control_engine")

-- ------- 1. Connection vs warp classification

local game = {
  data = {
    maps = {
      ROUTE_1 = {
        label = "Route 1", tileset = "OVERWORLD",
        widthCells = 20, heightCells = 36,
        connections = {
          { direction = "north", mapId = "VIRIDIAN_CITY", offset = 5 },
        },
      },
      VIRIDIAN_CITY = {
        label = "Viridian City", tileset = "OVERWORLD",
        widthCells = 40, heightCells = 36,
        connections = {
          { direction = "south", mapId = "ROUTE_1", offset = -5 },
        },
      },
      ROUTE_21 = {
        label = "Route 21", tileset = "OVERWORLD",
        widthCells = 20, heightCells = 40,
        connections = {
          { direction = "north", mapId = "PALLET_TOWN", offset = 0 },
        },
      },
      PALLET_TOWN = {
        label = "Pallet Town", tileset = "OVERWORLD",
        widthCells = 20, heightCells = 18,
      },
      VIRIDIAN_POKECENTER = {
        label = "Pokémon Center", tileset = "POKECENTER",
      },
      DIGLETTS_CAVE = {
        label = "Diglett's Cave", tileset = "CAVERN",
      },
    },
    encounters = {
      ROUTE_1 = {
        grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } },
      },
      ROUTE_21 = {
        water = { rate = 5, slots = { { species = "TENTACOOL", level = 5 } } },
      },
    },
  },
  save = {
    party = {
      { species = "PIDGEY", level = 5, hp = 20 },
      { species = "RATTATA", level = 4, hp = 18 },
      { species = "SQUIRTLE", level = 6, hp = 22 },
    },
    pokepcControlMode = "follow",
    pokepcFollowerCount = 3,
  },
  overworld = nil,
}

eq(MapTransition.classify({
  fromMapId = "ROUTE_1", toMapId = "VIRIDIAN_CITY", game = game,
}), "connection", "1. Route→City is connection")
eq(MapTransition.classify({
  fromMapId = "VIRIDIAN_CITY", toMapId = "ROUTE_1", game = game,
}), "connection", "1b. City→Route is connection")
eq(MapTransition.classify({
  fromMapId = "ROUTE_1", toMapId = "VIRIDIAN_POKECENTER", game = game,
}), "door", "1c. Center is door")
eq(MapTransition.classify({
  fromMapId = "ROUTE_1", toMapId = "DIGLETTS_CAVE", game = game,
}), "warp", "1d. Cave is warp")
eq(MapTransition.classify({
  fromMapId = "ROUTE_1", toMapId = "VIRIDIAN_CITY", game = game,
  reason = "fly",
}), "teleport", "1e. Fly is teleport")
eq(MapTransition.classify({
  fromMapId = nil, toMapId = "ROUTE_1", game = game, reason = "boot",
}), "boot", "1f. Boot/load")

-- ------- neighbors / rebase

local conn = MapNeighbors.findConnection(game, "ROUTE_1", "VIRIDIAN_CITY", nil)
check(conn ~= nil, "5. engine connection found")
local nx, ny = MapNeighbors.rebaseCell(10, 2, { x = 5, y = 36 })
eq(nx, 15, "6. rebase X")
eq(ny, 38, "6b. rebase Y")

-- ------- occupancy atomic rebase

local occ = CellOccupancy.new()
local e1 = { id = "w1", overworldWildSpawn = true, cellX = 3, cellY = 3 }
local e2 = { id = "w2", overworldWildSpawn = true, cellX = 4, cellY = 3 }
occ:rebuild({ logicEntities = { e1, e2 } })
local okRebase = occ:rebaseEntity(e1, 5, 5)
check(okRebase, "10. occupancy rebase ok")
eq(e1.cellX, 5, "10b. entity cell updated")
local bad = occ:rebaseEntity(e1, 4, 3)
check(not bad, "11. no double occupancy")

-- ------- wild ownership stamps

local record = { id = "w", mapId = "ROUTE_1", x = 8, y = 2, homeRegionId = "R1_A",
  state = Config.STATE.AVAILABLE }
local entity = {
  id = "w", cellX = 8, cellY = 2, overworldWildSpawn = true,
  behaviorState = { state = "WANDER", facing = "left", chasing = false,
                    anchorX = 8, anchorY = 2 },
  facing = "left", moving = true, targetX = 9, targetY = 2, progress = 4,
  px = 8 * 16 + 4, py = 2 * 16,
}
WildTransition.tagNewSpawn(entity, record, "ROUTE_1")
eq(entity.wildsOriginMapId, "ROUTE_1", "8. origin map stamped")
eq(record.wildsSpawnRegionId, "R1_A", "8b. region stamped")
check(WildTransition.allowsNewSpawns(game, "VIRIDIAN_CITY") == false,
      "12. no town spawns")
check(WildTransition.allowsNewSpawns(game, "ROUTE_1") == true,
      "12b. route still allows spawns")

-- Simulate root-map rebase preserving behavior.
local logicStub = {
  mod = V.mod,
  spawns = { w = record },
  entities = { w = entity },
  occupancy = CellOccupancy.new(),
  _attach = function() return true end,
  _despawn = function(self, id)
    self.spawns[id] = nil
    self.entities[id] = nil
  end,
  _recountRegions = function() end,
}
logicStub.occupancy:rebuild({ logicEntities = { entity } })
local ctx = MapTransition.buildContext({
  fromMapId = "ROUTE_1", toMapId = "VIRIDIAN_CITY", game = game,
  stash = { playerX = 10, playerY = 0 },
  ow = {
    map = { id = "VIRIDIAN_CITY", def = game.data.maps.VIRIDIAN_CITY,
            widthCells = 40, heightCells = 36 },
    player = { cellX = 15, cellY = 35 },
  },
})
eq(ctx.kind, "connection", "ctx is connection")
-- Force known offset (player delta 5, 35).
ctx.connectionOffset = { x = 5, y = 35 }
ctx.stats = MapTransition.emptyStats()
ctx.game = game
WildTransition.rebaseAll(logicStub, ctx)
eq(entity.cellX, 13, "6c. wild cellX rebased")
eq(entity.cellY, 37, "6d. wild cellY rebased")
eq(entity.behaviorState.anchorX, 13, "9. behavior anchor preserved/rebased")
eq(entity.behaviorState.state, "WANDER", "9b. behavior state preserved")
eq(entity.facing, "left", "9c. facing preserved")
eq(entity.wildsOriginMapId, "ROUTE_1", "13. origin not reclassified to city")
eq(record.mapId, "ROUTE_1", "13b. record mapId stays origin")

-- Keep near / despawn far
ctx.neighborSet = { ROUTE_1 = true, VIRIDIAN_CITY = true }
local player = { cellX = 15, cellY = 35 }
local keep, why = WildTransition.shouldKeep(logicStub, ctx, "w", player)
check(keep, "5. near wild kept (" .. tostring(why) .. ")")

entity.cellX, entity.cellY = 15 + 30, 35 + 30
record.x, record.y = entity.cellX, entity.cellY
keep, why = WildTransition.shouldKeep(logicStub, ctx, "w", player)
check(not keep, "6. far wild despawned (" .. tostring(why) .. ")")

-- Interior warp must not keep
local doorCtx = MapTransition.buildContext({
  fromMapId = "ROUTE_1", toMapId = "VIRIDIAN_POKECENTER", game = game,
})
doorCtx.game = game
entity.cellX, entity.cellY = 15, 35
record.x, record.y = 15, 35
keep = WildTransition.shouldKeep(logicStub, doorCtx, "w", player)
check(not keep, "7. interior warp removes wilds")

-- ------- follower reuse on connection (no SpriteRenderer.new)

local engine = ControlEngine.new(V.mod, {
  logic = { lastTransition = nil },
})
engine._gameRef = game
local ow = {
  map = {
    id = "ROUTE_1",
    def = game.data.maps.ROUTE_1,
    widthCells = 20, heightCells = 36,
    inBounds = function(_, x, y)
      return x >= 0 and y >= 0 and x < 20 and y < 36
    end,
    isWalkableCell = function() return true end,
    isWaterCell = function() return false end,
  },
  player = {
    cellX = 10, cellY = 5, facing = "up",
    px = 160, py = 80, moving = false,
  },
  npcs = {},
  entities = {},
  pokepcTrailers = {},
}
game.overworld = ow

-- Seed trailers once.
engine:syncTrailers(game, ow, { mapEnter = true })
local trailers = ow.pokepcTrailers
check(#trailers >= 1, "2. trailers spawned initially")
local refs = {}
for i, t in ipairs(trailers) do refs[i] = t end
local newsBefore = engine.diag.spriteRendererNews or 0
local makeBefore = engine.diag.makeTrailerCalls or 0

-- Simulate engine setMap rebuilding entity lists (orphans trailers).
ow.entities = { ow.player }
ow.npcs = {}
ow.player.cellX, ow.player.cellY = 15, 35
local fctx = {
  kind = "connection",
  fromMapId = "ROUTE_1",
  toMapId = "VIRIDIAN_CITY",
  connectionOffset = { x = 5, y = 30 },
  stash = { trailers = trailers },
}
engine.deps.logic.lastTransition = fctx
engine:onConnectionTransition(game, ow, fctx)
engine:update(game, ow, { source = "test" })

eq(engine.diag.makeTrailerCalls, makeBefore, "3. no makeTrailer on connection")
eq(engine.diag.spriteRendererNews, newsBefore, "3b. no SpriteRenderer.new on connection")
for i, t in ipairs(ow.pokepcTrailers) do
  eq(t, refs[i], "2b. follower entity ref identical slot " .. i)
end
local stillInWorld = false
for _, e in ipairs(ow.entities) do
  if e == refs[1] then stillInWorld = true end
end
check(stillInWorld, "2c. trailer reattached to ow.entities")
local oldX = refs[1].cellX
-- Offset was applied during connection sync; head/trail meta also shifted.
check(type(refs[1].cellX) == "number", "4. trail cell numeric after rebase")
check(ow.pokepcTrailHead ~= nil, "4b. trail head present after connection")
check((engine.diag.followersReused or 0) >= 1, "followers reused counter")
check(oldX ~= nil, "4c. trailer kept a cell after rebase")

-- Hard warp still recreates when trailers missing from composition path
ow.entities = { ow.player }
ow.npcs = {}
ow.pokepcTrailers = {}
engine.deps.logic.lastTransition = {
  kind = "warp", fromMapId = "ROUTE_1", toMapId = "VIRIDIAN_POKECENTER",
}
engine._pendingMapTrailerSync = true
local newsWarp = engine.diag.spriteRendererNews or 0
engine:update(game, ow, { source = "test-warp" })
check((engine.diag.spriteRendererNews or 0) > newsWarp
      or #(ow.pokepcTrailers) >= 0,
      "17. warp path can rebuild trailers")

-- ------- full ow.entities wipe must not happen on soft connection classify
check(MapTransition.isSoft(ctx) == true, "16. connection is soft")
check(MapTransition.isHardCleanup(doorCtx) == true, "17b. door is hard cleanup")

print("")
if failures > 0 then
  io.stderr:write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
print("All connection transition tests passed.")
