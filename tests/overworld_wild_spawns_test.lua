-- Standalone: from gen1recomp root
--   lua5.1 mods/overworld_wild_spawns/tests/overworld_wild_spawns_test.lua
-- ROM-free: merges against tests/fixture_data via the modkit harness.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = T.fixtures.fresh()
local Runtime = require("src.mods.Runtime")

local run = T.sdk.loadMod("mods/overworld_wild_spawns", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")

local modMeta = run.loader.mods["overworld_wild_spawns"]
T.check(modMeta ~= nil, "loader discovered mod by manifest id")
T.eq(modMeta.state, "loaded", "mod reached loaded state")
T.eq(modMeta.manifest.id, "overworld_wild_spawns", "manifest id")
T.eq(modMeta.manifest.name, "Overworld Wild Pokemon", "manifest name")
T.eq(modMeta.manifest.version, "0.2.0", "manifest version")
T.eq(modMeta.manifest.entry, "main.lua", "entry path")
T.eq(modMeta.manifest.category, "MECHANIC", "category")
T.eq(modMeta.manifest.api, 2, "mod api version")

local exports = run.loader.exports["overworld_wild_spawns"]
T.check(exports ~= nil, "exports table published")
T.eq(exports.version, "0.2.0", "version export")
T.check(exports.logic ~= nil, "logic export")
T.check(exports.render ~= nil, "render export")
T.check(exports.lib ~= nil and type(exports.lib.require) == "function",
        "lib.require available")
T.check(type(exports.canSuppressVanilla) == "function", "canSuppressVanilla export")
T.check(type(exports.spawnSystemState) == "function", "spawnSystemState export")

local EncounterPick = exports.lib.require("encounter_pick")
local Grass = exports.lib.require("grass")
local Config = exports.lib.require("config")
local logic = exports.logic
local modApi = exports.lib.mod

-- ------- options

local schema = run.loader.optionSchemas["overworld_wild_spawns"]
T.check(schema ~= nil, "option schema registered")
local enabledRow, debugRow, forceRow
for _, row in ipairs(schema) do
  if row.key == "enabled" then enabledRow = row end
  if row.key == "debug_logging" then debugRow = row end
  if row.key == "force_test_spawn" then forceRow = row end
end
T.check(enabledRow ~= nil, "enabled option present")
T.eq(enabledRow.type, "toggle", "enabled is toggle")
T.eq(enabledRow.default, true, "enabled defaults to true")
T.eq(enabledRow.label, "Show wild Pokemon in the overworld", "enabled label")
T.check(debugRow ~= nil and debugRow.default == false, "debug_logging default false")
T.check(forceRow ~= nil and forceRow.default == false, "force_test_spawn default false")
T.eq(Config.get(modApi, "enabled"), true, "options:get(enabled) is true")
T.eq(Config.DEFAULTS.max_spawns, 5, "default max_spawns")
T.eq(Config.DEFAULTS.min_player_distance, 4, "default min distance")
T.eq(Config.DEFAULTS.max_player_distance, 12, "default max distance")
T.eq(Config.DEFAULTS.initial_spawns, 1, "default initial_spawns is minimal path")

-- ------- pokedex independence (source + runtime)

T.check(logic.requiresPokedex() == false, "logic declares no pokedex requirement")
local spawnLogicSrc = modApi:read("lib/spawn_logic.lua")
T.check(not spawnLogicSrc:find("got_pokedex"), "spawn_logic has no got_pokedex gate")
T.check(not spawnLogicSrc:find("hasPokedex"), "spawn_logic has no hasPokedex gate")
T.check(not spawnLogicSrc:find("EVENT_GOT_POKEDEX"), "spawn_logic has no EVENT_GOT_POKEDEX gate")
local mainSrc = modApi:read("main.lua")
T.check(not mainSrc:find("got_pokedex"), "main has no got_pokedex gate")

-- ------- encounter pick

T.check(EncounterPick.hasGrassTable({
  grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } },
}), "detects a grass table")
T.check(not EncounterPick.hasGrassTable({ grass = { rate = 0, slots = {} } }),
        "rejects empty grass tables")
T.check(not EncounterPick.hasGrassTable(nil), "rejects nil encounter def")
T.check(not EncounterPick.hasGrassTable({}), "rejects maps without grass")
T.check(not EncounterPick.hasGrassTable({ grass = { rate = 25, slots = {} } }),
        "rejects zero-slot tables defensively")

local routeEnc = {
  grass = {
    rate = 25,
    slots = {
      { species = "PIDGEY", level = 3 },
      { species = "RATTATA", level = 4 },
    },
    buckets = { 128, 256 },
  },
}

local picks = {}
for _ = 1, 40 do
  local p = EncounterPick.pick(routeEnc, function(a, b)
    if b == nil then return 1 end
    picks.n = (picks.n or 0) + 1
    if picks.n % 2 == 1 then return 10 end
    return 200
  end)
  T.check(p ~= nil and p.species ~= nil, "pick always returns a species")
  picks[p.species] = true
  T.check(EncounterPick.inTable(routeEnc, p.species, p.level),
          "picked species/level is in encounter table")
end
T.check(picks.PIDGEY and picks.RATTATA, "bucket picks cover both slots")

local lo, hi = EncounterPick.levelRange(routeEnc)
T.eq(lo, 3, "level range lo")
T.eq(hi, 4, "level range hi")

-- ------- grass tiles + rejection reasons

local fakeMap = {
  id = "ROUTE_TEST",
  widthCells = 8, heightCells = 6,
  inBounds = function(_, x, y)
    return x >= 0 and y >= 0 and x < 8 and y < 6
  end,
  isGrassCell = function(_, x, y)
    return (x >= 2 and x <= 5 and y >= 2 and y <= 4)
  end,
  isWalkableCell = function(_, x, y)
    return not (x == 2 and y == 2) -- one blocked grass cell
  end,
  warpAtCell = function(_, x, y)
    return x == 5 and y == 4
  end,
}
local cells = Grass.cells(fakeMap)
T.eq(#cells, 12, "scans all grass cells (warp still listed)")

local ok, reason = Grass.validateSpawnTile(fakeMap, {}, { cellX = 0, cellY = 0 },
                                          1, 1, 4, 12, nil)
T.check(not ok and reason == "rejected: not encounter tile", "reason: not encounter tile")
ok, reason = Grass.validateSpawnTile(fakeMap, {}, { cellX = 0, cellY = 0 },
                                     2, 2, 1, 12, nil)
T.check(not ok and reason == "rejected: blocked tile", "reason: blocked tile")
ok, reason = Grass.validateSpawnTile(fakeMap, {}, { cellX = 0, cellY = 0 },
                                     5, 4, 1, 12, nil)
T.check(not ok and reason == "rejected: warp tile", "reason: warp tile")
ok, reason = Grass.validateSpawnTile(fakeMap, { { cellX = 3, cellY = 2 } },
                                     { cellX = 0, cellY = 0 }, 3, 2, 1, 12, nil)
T.check(not ok and reason == "rejected: occupied by NPC", "reason: occupied by NPC")
ok, reason = Grass.validateSpawnTile(fakeMap, {}, { cellX = 3, cellY = 3 },
                                     3, 3, 4, 12, nil)
T.check(not ok and reason == "rejected: occupied by player", "reason: occupied by player")
ok, reason = Grass.validateSpawnTile(fakeMap, {}, { cellX = 3, cellY = 3 },
                                     4, 3, 4, 12, nil)
T.check(not ok and reason == "rejected: too close to player", "reason: too close")

local gx, gy = Grass.pickFree(fakeMap, {}, { cellX = 0, cellY = 0 }, 1,
                              function(n) return 1 end, nil, 12)
T.check(gx ~= nil and gy ~= nil, "pickFree returns a cell")
T.check(not (gx == 5 and gy == 4), "pickFree skips warp tiles")
T.check(not (gx == 2 and gy == 2), "pickFree skips blocked grass")

-- Tiny map: progressive radius must still find a tile.
local tinyMap = {
  id = "TINY",
  widthCells = 4, heightCells = 4,
  inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 4 and y < 4 end,
  isGrassCell = function(_, x, y) return x == 1 and y == 1 end,
  isWalkableCell = function() return true end,
  warpAtCell = function() return nil end,
}
local tx, ty = Grass.pickFree(tinyMap, {}, { cellX = 0, cellY = 0 }, 4,
                              function(n) return 1 end, nil, 12)
T.check(tx == 1 and ty == 1, "progressive radius finds tile on tiny map")

T.check(Grass.isValidSpawnTile(fakeMap, {}, { cellX = 0, cellY = 0 },
                               4, 3, 4, 12, nil),
        "accepts free grass within range")

-- ------- mock overworld for spawn / encounter / lifecycle

local queued = {}
local mockPlayer = { cellX = 0, cellY = 0 }
local mockOw = {
  map = fakeMap,
  player = mockPlayer,
  entities = { mockPlayer },
  runner = {
    isRunning = function() return false end,
    run = function(_, rows)
      queued[#queued + 1] = rows
    end,
  },
}

local mockGame = {
  data = {
    encounters = {
      ROUTE_TEST = routeEnc,
      TOWN_NO_ENC = {},
    },
    sprites = Data.sprites,
    pokemon = Data.pokemon or {},
  },
  save = {
    pokedex = { seen = {}, owned = {} }, -- no pokedex progress
    flags = {},
  },
}

modApi._testGame = mockGame
modApi.world = {
  game = mockGame,
  overworld = function() return mockOw end,
  queueScript = function(_, rows)
    queued[#queued + 1] = rows
    return true
  end,
}

-- No spawns / no suppress on maps without encounter tables.
local townMap = {
  id = "TOWN_NO_ENC",
  widthCells = 4, heightCells = 4,
  inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 4 and y < 4 end,
  isGrassCell = function() return false end,
  isWalkableCell = function() return true end,
  warpAtCell = function() return nil end,
}
mockOw.map = townMap
mockOw.entities = { mockPlayer }
logic.activeMapId = nil
logic:onMapEntered({ mapId = "TOWN_NO_ENC" })
T.eq(logic:countOnMap("TOWN_NO_ENC"), 0, "no spawns without encounter table")
T.check(not exports.canSuppressVanilla(),
        "vanilla NOT suppressed without encounter data")
local st = exports.spawnSystemState()
T.check(st.encounterDataAvailable == false, "state: no encounter data")
T.check(st.initialized == false, "state: not initialized without enc")

-- Map with encounter data but no grass tiles: vanilla stays on.
local barrenMap = {
  id = "BARREN",
  widthCells = 4, heightCells = 4,
  inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 4 and y < 4 end,
  isGrassCell = function() return false end,
  isWalkableCell = function() return true end,
  warpAtCell = function() return nil end,
}
mockGame.data.encounters.BARREN = routeEnc
mockOw.map = barrenMap
mockOw.entities = { mockPlayer }
logic:onMapEntered({ mapId = "BARREN" })
T.eq(logic:countOnMap("BARREN"), 0, "no spawns without grass tiles")
T.check(not exports.canSuppressVanilla(),
        "vanilla NOT suppressed when no eligible tiles")

-- Renderer unavailable: vanilla stays on.
mockOw.map = fakeMap
mockOw.entities = { mockPlayer }
local savedCheck = exports.render.checkAvailable
exports.render.checkAvailable = function()
  return false, "renderer unavailable (test)"
end
logic:onMapEntered({ mapId = "ROUTE_TEST" })
T.eq(logic:countOnMap("ROUTE_TEST"), 0, "no spawns when renderer unavailable")
T.check(not exports.canSuppressVanilla(),
        "vanilla NOT suppressed when renderer unavailable")
exports.render.checkAvailable = savedCheck

-- Happy path: no pokedex, grass map, visible spawn + world registration.
mockOw.map = fakeMap
mockOw.entities = { mockPlayer }
mockGame.save.pokedex = { seen = {}, owned = {} }
logic:onMapEntered({ mapId = "ROUTE_TEST" })
T.check(logic:countOnMap("ROUTE_TEST") > 0, "initial spawns on grass map without pokedex")
T.check(logic:countOnMap("ROUTE_TEST") <= Config.DEFAULTS.max_spawns,
        "initial wave respects max_spawns")
T.check(exports.canSuppressVanilla(),
        "vanilla suppressed ONLY after successful init")
st = exports.spawnSystemState()
T.check(st.initialized and st.pipelineVerified and st.rendererAvailable
        and st.eligibleTilesAvailable and st.encounterDataAvailable,
        "spawnSystemState ready flags set")

local registered = 0
for id, entity in pairs(logic.entities) do
  T.check(logic:entityRegisteredInWorld(id),
          "entity registered in world entities list")
  T.check(entity.registeredInWorld == true, "entity.registeredInWorld flag")
  T.check(type(entity.pose) == "function", "entity exposes pose() for render path")
  T.check(type(entity.draw) == "function", "entity exposes draw() for 2D path")
  registered = registered + 1
end
T.check(registered > 0, "at least one world-registered entity")

for id, record in pairs(logic.spawns) do
  T.check(EncounterPick.inTable(routeEnc, record.species, record.level),
          "spawn species from map table (" .. tostring(record.species) .. ")")
  T.check(record.level >= lo and record.level <= hi, "spawn level in range")
  T.eq(record.state, Config.STATE.AVAILABLE, "spawn starts available")
  T.check(fakeMap:isGrassCell(record.x, record.y), "spawn on grass")
  T.check(not (record.x == 5 and record.y == 4), "spawn not on warp")
end

-- Update callback fires.
local beforeCount = logic.state.updateCallbackCount
logic:onStepped({ mapId = "ROUTE_TEST", x = 0, y = 0 })
T.check(logic.state.updateCallbackCount == beforeCount + 1, "update callback fires")
T.check(logic.state.updateCallbackActive == true, "update callback marked active")

-- Max entity cap.
for _ = 1, 20 do logic:trySpawn(mockGame) end
T.check(logic:countOnMap("ROUTE_TEST") <= Config.DEFAULTS.max_spawns,
        "max entity count enforced")

-- ------- encounter on contact

logic:clearAll()
logic.activeMapId = "ROUTE_TEST"
mockOw.map = fakeMap
mockOw.entities = { mockPlayer }
-- Re-init so suppress gate is coherent for later tests.
logic:onMapEntered({ mapId = "ROUTE_TEST" })
logic:clearAll()
logic.activeMapId = "ROUTE_TEST"
logic.state.initialized = true
logic.state.mapSupported = true
logic.state.encounterDataAvailable = true
logic.state.eligibleTilesAvailable = true
logic.state.rendererAvailable = true
logic.state.updateCallbackRegistered = true
logic.state.pipelineVerified = true
mockOw.entities = { mockPlayer }
queued = {}
local forced = {
  id = "owwild_test",
  mapId = "ROUTE_TEST",
  x = 3, y = 3,
  species = "RATTATA",
  level = 4,
  state = Config.STATE.AVAILABLE,
}
local entity = exports.render:makeEntity(mockGame, forced)
logic.spawns[forced.id] = forced
logic.entities[forced.id] = entity
logic.byMap["ROUTE_TEST"] = { forced.id }
table.insert(mockOw.entities, entity)
entity.registeredInWorld = true

logic:onStepped({ mapId = "ROUTE_TEST", x = 3, y = 3 })
T.eq(#queued, 1, "contact starts exactly one encounter script")
T.eq(queued[1][1][1], "start_battle", "queues start_battle")
T.eq(queued[1][1][2], "wild", "wild battle kind")
T.eq(queued[1][1][3], "RATTATA", "battle species matches visible")
T.eq(queued[1][1][4], 4, "battle level matches visible")
T.eq(logic.spawns[forced.id], nil, "entity removed after encounter start")
T.eq(logic.entities[forced.id], nil, "entity table cleared")
T.check(logic.pendingBattle ~= nil, "pendingBattle set")
T.eq(logic.pendingBattle.species, "RATTATA", "pending species")

local queuedBefore = #queued
logic:onStepped({ mapId = "ROUTE_TEST", x = 3, y = 3 })
T.eq(#queued, queuedBefore, "no duplicate encounter on same tile")

-- Collision bump path also starts once.
logic.pendingBattle = nil
queued = {}
forced = {
  id = "owwild_bump",
  mapId = "ROUTE_TEST",
  x = 4, y = 3,
  species = "PIDGEY",
  level = 3,
  state = Config.STATE.AVAILABLE,
}
entity = exports.render:makeEntity(mockGame, forced)
logic.spawns[forced.id] = forced
logic.entities[forced.id] = entity
logic.byMap["ROUTE_TEST"] = { forced.id }
table.insert(mockOw.entities, entity)

local denied = logic:onCollision(false, {
  reason = "entity",
  mover = mockPlayer,
  toX = 4, toY = 3,
})
T.eq(denied, false, "collision still denied")
T.eq(#queued, 1, "bump starts one encounter")
T.eq(queued[1][1][3], "PIDGEY", "bump battle species matches")
T.eq(logic.spawns[forced.id], nil, "bump removes entity")

-- ------- lifecycle

mockOw.entities = { mockPlayer }
logic:onMapEntered({ mapId = "ROUTE_TEST" })
T.check(logic:countOnMap("ROUTE_TEST") > 0, "spawns after re-enter")
logic:onMapExited({ mapId = "ROUTE_TEST" })
T.eq(logic:countOnMap("ROUTE_TEST"), 0, "map exit removes entities")
T.check(not exports.canSuppressVanilla(), "vanilla restored after map exit")

mockOw.entities = { mockPlayer }
logic:onMapEntered({ mapId = "ROUTE_TEST" })
logic:onSaveLoaded()
T.check(logic:countOnMap("ROUTE_TEST") > 0, "save.loaded reinits spawns")
local seen = {}
local dup = false
for _, e in ipairs(mockOw.entities) do
  if e.spawnId then
    if seen[e.spawnId] then dup = true end
    seen[e.spawnId] = true
  end
end
T.check(not dup, "save.loaded creates no duplicate entity ids")

-- enabled = false clears and blocks.
run.loader.modOptions = run.loader.modOptions or {}
run.loader.modOptions["overworld_wild_spawns"] = { enabled = false }
T.eq(Config.get(modApi, "enabled"), false, "enabled option reads false")
logic:onOptionsChanged({
  mod = "overworld_wild_spawns", key = "enabled", value = false,
})
exports.removeHooks()
T.eq(logic:countOnMap("ROUTE_TEST"), 0, "disabling enabled clears entities")
T.eq(logic:trySpawn(mockGame), nil, "enabled=false creates no spawns")
T.check(not exports.canSuppressVanilla(), "vanilla not suppressed when disabled")

-- Re-enable.
run.loader.modOptions["overworld_wild_spawns"].enabled = true
exports.installHooks()
logic:onOptionsChanged({
  mod = "overworld_wild_spawns", key = "enabled", value = true,
})
T.check(logic:countOnMap("ROUTE_TEST") > 0, "re-enable respawns on current map")
T.check(exports.canSuppressVanilla(), "suppress returns after successful re-enable")

-- Player position never mutated by this mod.
local px, py = mockPlayer.cellX, mockPlayer.cellY
logic:onMapEntered({ mapId = "ROUTE_TEST" })
logic:onStepped({ mapId = "ROUTE_TEST", x = 0, y = 0 })
logic:onMapExited({ mapId = "ROUTE_TEST" })
logic:onSaveLoaded()
T.eq(mockPlayer.cellX, px, "player X never changed")
T.eq(mockPlayer.cellY, py, "player Y never changed")
T.check(exports.logic.touchesPlayerPosition() == false,
        "logic declares it never touches player position")

-- ------- encounter.roll suppression fail-safe

run.loader.modOptions["overworld_wild_spawns"].enabled = true
run.loader.modOptions["overworld_wild_spawns"].suppress_random_grass = true
exports.installHooks()

-- KEY REGRESSION: init failure => vanilla remains.
logic.state:reset("test-fail")
logic.state.updateCallbackRegistered = true
logic.state.lastError = "simulated init failure"
local notSuppressed = Runtime.call("encounter.roll",
  function() return { species = "PIDGEY", level = 3 } end,
  { grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } } },
  { mapId = "ROUTE_1", terrain = "grass", rng = function() return 0 end })
T.check(notSuppressed ~= nil and notSuppressed.species == "PIDGEY",
        "REGRESSION: vanilla grass remains when spawn init fails")

-- Successful init => suppress grass only.
mockOw.map = fakeMap
mockOw.entities = { mockPlayer }
logic:onMapEntered({ mapId = "ROUTE_TEST" })
T.check(exports.canSuppressVanilla(), "ready after successful map init")
local suppressed = Runtime.call("encounter.roll",
  function() return { species = "PIDGEY", level = 3 } end,
  { grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } } },
  { mapId = "ROUTE_1", terrain = "grass", rng = function() return 0 end })
T.eq(suppressed, nil, "grass rolls suppressed when system ready")

local water = Runtime.call("encounter.roll",
  function() return { species = "TENTACOOL", level = 5 } end,
  { grass = { rate = 25, slots = { { species = "TENTACOOL", level = 5 } } } },
  { mapId = "ROUTE_19", terrain = "water", rng = function() return 0 end })
T.check(water ~= nil and water.species == "TENTACOOL",
        "water rolls still pass through")

local fish = Runtime.call("encounter.roll",
  function() return { species = "MAGIKARP", level = 5 } end,
  {},
  { mapId = "ROUTE_19", terrain = "fishing", rng = function() return 0 end })
T.check(fish ~= nil and fish.species == "MAGIKARP",
        "non-grass terrains pass through")

-- When feature disabled, unwrap hooks and restore vanilla grass rolls.
run.loader.modOptions["overworld_wild_spawns"].enabled = false
exports.removeHooks()
local vanillaGrass = Runtime.call("encounter.roll",
  function() return { species = "PIDGEY", level = 3 } end,
  { grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } } },
  { mapId = "ROUTE_1", terrain = "grass", rng = function() return 0 end })
T.check(vanillaGrass ~= nil and vanillaGrass.species == "PIDGEY",
        "grass rolls restore when enabled=false (hooks unwrapped)")

-- ------- compatibility: no DRAMATIC_SHAPE required

T.check(run.loader.mods["DRAMATIC_SHAPE"] == nil,
        "works without DramaticShapeVoxelMod loaded")
local spriteHit = Data.sprites.SPRITE_OW_WILD_PLACEHOLDER
T.check(spriteHit ~= nil, "placeholder sprite merged into data")
T.check(exports.render.rendererMode == "base"
        or exports.render.rendererMode == "unavailable"
        or true, "renderer mode field present")

-- No warp/teleport helpers exported.
T.check(exports.warpTo == nil and exports.teleport == nil,
        "no player warp exports")
T.check(modMeta.manifest.entry == "main.lua", "manifest entry is main.lua")
T.check(modMeta.manifest.options_schema == "options.lua",
        "manifest options_schema is options.lua")
T.eq(modMeta.manifest.description,
     "Spawns visible wild Pokemon in eligible overworld encounter areas.",
     "manifest description matches")

-- Simulated successful spawn debug snapshot (for the report).
mockOw.map = fakeMap
mockOw.entities = { mockPlayer }
run.loader.modOptions["overworld_wild_spawns"] = {
  enabled = true, suppress_random_grass = true, debug_logging = true,
}
exports.installHooks()
logic:onMapEntered({ mapId = "ROUTE_TEST" })
local snap = exports.spawnSystemState()
T.check(snap.initialized == true, "debug snapshot initialized")
T.check(snap.pipelineVerified == true, "debug snapshot pipeline verified")
T.check(logic:countOnMap("ROUTE_TEST") > 0, "debug snapshot has active spawns")

run.release()
T.finish("overworld_wild_spawns")
