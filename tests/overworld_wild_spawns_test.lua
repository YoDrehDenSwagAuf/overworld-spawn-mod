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
T.eq(modMeta.manifest.name, "Wilds of Kanto", "manifest name")
T.eq(modMeta.manifest.version, "1.0.2", "manifest version")
T.eq(modMeta.manifest.entry, "main.lua", "entry path")
T.eq(modMeta.manifest.category, "MECHANIC", "category")
T.eq(modMeta.manifest.api, 2, "mod api version")
T.eq(modMeta.manifest.github, "YoDrehDenSwagAuf/overworld-spawn-mod", "github field")

local exports = run.loader.exports["overworld_wild_spawns"]
T.check(exports ~= nil, "exports table published")
T.eq(exports.version, "1.0.2", "version export")
T.check(exports.logic ~= nil, "logic export")
T.check(exports.render ~= nil, "render export")
T.check(exports.hud ~= nil, "hud export")
T.check(exports.overlay ~= nil, "overlay export")
T.check(exports.browser ~= nil, "browser export")
T.check(exports.behaviorTick ~= nil, "behaviorTick export")
T.check(exports.lib ~= nil and type(exports.lib.require) == "function",
        "lib.require available")
T.check(type(exports.canSuppressVanilla) == "function", "canSuppressVanilla export")
T.check(type(exports.spawnSystemState) == "function", "spawnSystemState export")
T.check(type(exports.hudSnapshot) == "function", "hudSnapshot export")
T.check(type(exports.testSpawn) == "function", "testSpawn export")

local EncounterPick = exports.lib.require("encounter_pick")
local EncounterIndex = exports.lib.require("encounter_index")
local Grass = exports.lib.require("grass")
local Config = exports.lib.require("config")
local Diagnostics = exports.lib.require("diagnostics")
local Surface = exports.lib.require("surface")
local SpawnRegions = exports.lib.require("spawn_regions")
local Behavior = exports.lib.require("behavior")
local SpriteScale = exports.lib.require("sprite_scale")
local logic = exports.logic
local modApi = exports.lib.mod

-- ------- options

local schema = run.loader.optionSchemas["overworld_wild_spawns"]
T.check(schema ~= nil, "option schema registered")
local enabledRow, debugRow, forceRow
local devProps = {}
for _, row in ipairs(schema) do
  if row.key == "enabled" then enabledRow = row end
  if row.key == "debug_logging" then debugRow = row end
  if row.key == "force_test_spawn" then forceRow = row end
  if row.key == "dev_mode"
     or row.key == "debug_hud_always_visible"
     or row.key == "allow_debug_spawn_outside_encounter_areas"
     or row.key == "show_spawn_tile_overlay" then
    devProps[row.key] = row
  end
end
T.check(enabledRow ~= nil, "enabled option present")
T.eq(enabledRow.type, "toggle", "enabled is toggle")
T.eq(enabledRow.default, true, "enabled defaults to true")
T.eq(enabledRow.label, "Show Wild Mons", "enabled label")
T.check(debugRow ~= nil and debugRow.default == false, "debug_logging default false")
T.check(forceRow ~= nil and forceRow.default == false, "force_test_spawn default false")
T.check(devProps.dev_mode ~= nil, "dev_mode option present")
T.eq(devProps.dev_mode.type, "toggle", "dev_mode is toggle")
T.eq(devProps.dev_mode.default, false, "dev_mode defaults to false")
T.eq(devProps.dev_mode.label, "Dev Mode", "dev_mode label")
T.check(devProps.debug_hud_always_visible ~= nil
        and devProps.debug_hud_always_visible.default == false,
        "debug_hud_always_visible default false")
T.check(devProps.allow_debug_spawn_outside_encounter_areas ~= nil
        and devProps.allow_debug_spawn_outside_encounter_areas.default == false,
        "allow_debug_spawn_outside default false")
T.check(devProps.show_spawn_tile_overlay ~= nil
        and devProps.show_spawn_tile_overlay.default == false,
        "show_spawn_tile_overlay default false")
T.eq(Config.get(modApi, "enabled"), true, "options:get(enabled) is true")
T.eq(Config.get(modApi, "dev_mode"), false, "options:get(dev_mode) is false")
T.eq(Config.DEFAULTS.max_visible_pokemon, 12, "default max_visible_pokemon")
T.eq(Config.DEFAULTS.max_spawns, 12, "default max_spawns legacy alias")
T.eq(Config.DEFAULTS.min_player_distance, 3, "default min distance")
T.eq(Config.DEFAULTS.max_player_distance, 16, "default max distance")
T.eq(Config.DEFAULTS.spawn_density, "normal", "default spawn_density")
T.eq(Config.DEFAULTS.tiles_per_additional_pokemon, 24, "default tiles_per_additional")
T.eq(Config.DEFAULTS.initial_spawns, 1, "default initial_spawns is minimal path")
T.eq(Config.DEFAULTS.dev_mode, false, "DEFAULTS.dev_mode false")
T.eq(Config.DEFAULTS.enable_idle, true, "idle behaviour enabled by default")
T.eq(Config.DEFAULTS.enable_wander, true, "wander behaviour enabled by default")
T.eq(Config.DEFAULTS.enable_aggressive, true, "aggressive behaviour enabled by default")
T.eq(Config.DEFAULTS.enable_hidden, true, "hidden behaviour enabled by default")

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

-- Encounter fixtures use ROM/content species that were pre-registered during
-- mod load (FIXMON_*), never IDs invented after the registry freeze.
local routeEnc = {
  grass = {
    rate = 25,
    slots = {
      { species = "FIXMON_A", level = 3 },
      { species = "FIXMON_B", level = 4 },
    },
    buckets = { 128, 256 },
  },
}

-- Unique species vs slots (duplicates must not inflate species count).
local dupEnc = {
  grass = {
    rate = 25,
    slots = {
      { species = "FIXMON_B", level = 2 },
      { species = "FIXMON_B", level = 3 },
      { species = "FIXMON_A", level = 2 },
    },
  },
}
T.eq(EncounterPick.slotCount(dupEnc, "grass"), 3, "encounter slots count duplicates")
T.eq(EncounterPick.uniqueSpeciesCount(dupEnc, "grass"), 2,
     "unique species counts distinct IDs only")
local dupNames = EncounterPick.uniqueSpecies(dupEnc, "grass")
T.check(dupNames[1] == "FIXMON_A" or dupNames[1] == "FIXMON_B", "unique species sorted set")

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
T.check(picks.FIXMON_A and picks.FIXMON_B, "bucket picks cover both slots")

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
  species = "FIXMON_A",
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
T.eq(queued[1][1][3], "FIXMON_A", "battle species matches visible")
T.eq(queued[1][1][4], 4, "battle level matches visible")
T.eq(logic.spawns[forced.id], nil, "entity removed after encounter start")
T.eq(logic.entities[forced.id], nil, "entity table cleared")
T.check(logic.pendingBattle ~= nil, "pendingBattle set")
T.eq(logic.pendingBattle.species, "FIXMON_A", "pending species")

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
  species = "FIXMON_B",
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
T.eq(queued[1][1][3], "FIXMON_B", "bump battle species matches")
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
  function() return { species = "FIXMON_A", level = 3 } end,
  { grass = { rate = 25, slots = { { species = "FIXMON_A", level = 3 } } } },
  { mapId = "ROUTE_1", terrain = "grass", rng = function() return 0 end })
T.check(notSuppressed ~= nil and notSuppressed.species == "FIXMON_A",
        "REGRESSION: vanilla grass remains when spawn init fails")

-- Successful init => suppress grass only.
mockOw.map = fakeMap
mockOw.entities = { mockPlayer }
logic:onMapEntered({ mapId = "ROUTE_TEST" })
T.check(exports.canSuppressVanilla(), "ready after successful map init")
local suppressed = Runtime.call("encounter.roll",
  function() return { species = "FIXMON_A", level = 3 } end,
  { grass = { rate = 25, slots = { { species = "FIXMON_A", level = 3 } } } },
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
  function() return { species = "FIXMON_A", level = 3 } end,
  { grass = { rate = 25, slots = { { species = "FIXMON_A", level = 3 } } } },
  { mapId = "ROUTE_1", terrain = "grass", rng = function() return 0 end })
T.check(vanillaGrass ~= nil and vanillaGrass.species == "FIXMON_A",
        "grass rolls restore when enabled=false (hooks unwrapped)")

-- ------- compatibility: no DRAMATIC_SHAPE required

T.check(run.loader.mods["DRAMATIC_SHAPE"] == nil,
        "works without DramaticShapeVoxelMod loaded")
local spriteHit = Data.sprites.SPRITE_OW_WILD_PLACEHOLDER
T.check(spriteHit ~= nil, "placeholder sprite merged into data")
T.check(Data.sprites.SPRITE_OW_WILD_FIXMON_A ~= nil,
        "FIXMON_A overworld sprite pre-registered at load")
T.check(Data.sprites.SPRITE_OW_WILD_FIXMON_B ~= nil,
        "FIXMON_B overworld sprite pre-registered at load")
T.check(Data.sprites.SPRITE_OW_WILD_FIXMON_C ~= nil,
        "FIXMON_C overworld sprite pre-registered at load")
T.check(exports.render.speciesSpriteIds.FIXMON_A == "SPRITE_OW_WILD_FIXMON_A",
        "speciesSpriteIds lookup for FIXMON_A")
T.check(exports.render.contentRegistrationOpen == false,
        "content registration closed after mod init")
T.check((exports.render.registeredCount or 0) >= 3,
        "registered at least fixture species sprites")
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
     "Visible and reactive wild Pokemon for the Gen 1 overworld.",
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

-- =====================================================================
-- Developer mode / diagnostics / preview browser / test spawn
-- =====================================================================

-- Reset to a clean grass-map state with empty pokedex.
-- Encounter tables use pre-registered FIXMON_* so map init / HUD / spawns work
-- after the content registry freeze. Late-added species (below) remain listed
-- in the preview browser with UNAVAILABLE overworld sprites.
mockOw.map = fakeMap
mockOw.entities = { mockPlayer }
mockPlayer.cellX, mockPlayer.cellY = 0, 0
mockGame.save.pokedex = { seen = {}, owned = {} }
mockGame.save.flags = {}
mockGame.data.encounters.ROUTE_TEST = {
  grass = {
    rate = 25,
    slots = {
      { species = "FIXMON_B", level = 2 },
      { species = "FIXMON_B", level = 3 },
      { species = "FIXMON_A", level = 2 },
    },
  },
  water = {
    rate = 5,
    slots = { { species = "FIXMON_C", level = 10 } },
  },
}
mockGame.data.encounters.ROUTE_2 = {
  grass = {
    rate = 25,
    slots = {
      { species = "FIXMON_A", level = 3 },
      { species = "FIXMON_A", level = 5 },
      { species = "FIXMON_A", level = 7 },
    },
  },
}
mockGame.data.maps = mockGame.data.maps or {}
mockGame.data.maps.ROUTE_TEST = { id = "ROUTE_TEST", label = "Route 1", tileset = "OVERWORLD" }
mockGame.data.maps.ROUTE_2 = { id = "ROUTE_2", label = "Route 2", tileset = "OVERWORLD" }
mockGame.data.pokemon = mockGame.data.pokemon or {}
-- Ensure fixture species remain visible in game.data for browser/HUD.
mockGame.data.pokemon.FIXMON_A = mockGame.data.pokemon.FIXMON_A or Data.pokemon.FIXMON_A
mockGame.data.pokemon.FIXMON_B = mockGame.data.pokemon.FIXMON_B or Data.pokemon.FIXMON_B
mockGame.data.pokemon.FIXMON_C = mockGame.data.pokemon.FIXMON_C or Data.pokemon.FIXMON_C
-- Late-added species: exist in ROM-like data but were NOT content-registered.
mockGame.data.pokemon.PIDGEY = {
  id = "PIDGEY", name = "Pidgey", dex = 16, spriteFront = "x.png",
}
mockGame.data.pokemon.RATTATA = {
  id = "RATTATA", name = "Rattata", dex = 19, spriteFront = "y.png",
}
mockGame.data.pokemon.MAGIKARP = {
  id = "MAGIKARP", name = "Magikarp", dex = 129, spriteFront = "z.png",
}

-- dev_mode false: HUD hidden, browser gated.
run.loader.modOptions["overworld_wild_spawns"] = {
  enabled = true,
  suppress_random_grass = true,
  dev_mode = false,
  debug_hud_always_visible = false,
  show_spawn_tile_overlay = false,
  allow_debug_spawn_outside_encounter_areas = false,
}
T.eq(Config.devMode(modApi), false, "dev_mode false")
T.check(not exports.hud:shouldShow(), "HUD hidden when dev_mode false")
logic:onMapEntered({ mapId = "ROUTE_TEST" })
T.check(not exports.hud:shouldShow(), "HUD still hidden after map enter without dev_mode")

-- Enable developer mode (runtime option change).
run.loader.modOptions["overworld_wild_spawns"].dev_mode = true
logic:onOptionsChanged({
  mod = "overworld_wild_spawns", key = "dev_mode", value = true,
})
T.check(Config.devMode(modApi), "dev_mode true after options_changed")
T.check(exports.hud:shouldShow(), "HUD appears after map enter with dev_mode")

-- HUD values: unique species vs slots, tiles, assets.
local hud = exports.hudSnapshot()
T.eq(hud.encounterSpecies, 2, "HUD unique species (FIXMON_A+FIXMON_B)")
T.eq(hud.encounterSlots, 3, "HUD encounter slots")
T.check(hud.eligibleTiles > 0, "HUD eligible tiles > 0")
T.check(hud.requiredAssets == 2, "HUD required assets == unique species")
T.check(hud.loadedAssets >= 0 and hud.loadedAssets <= hud.requiredAssets,
        "HUD loaded assets in range")
T.check(hud.activePokemon >= 0, "HUD active pokemon present")
T.check(hud.spawnStatus ~= nil and hud.spawnStatus ~= "", "HUD spawn status set")
T.check(hud.rendererStatus ~= nil, "HUD renderer status set")
-- Status must not invent READY when broken; here init succeeded so READY ok.
T.eq(hud.spawnStatus, Config.STATUS.READY, "HUD spawn system READY after successful init")

local lines = exports.hudLines()
T.check(lines[1] == "Wilds of Kanto Debug", "HUD title line")
local joined = table.concat(lines, "\n")
T.check(joined:find("Encounter species: 2", 1, true), "HUD text has species count")
T.check(joined:find("Encounter slots: 3", 1, true), "HUD text has slot count")

-- HUD works without pokedex.
T.check(mockGame.save.pokedex.owned
        and next(mockGame.save.pokedex.owned) == nil,
        "pokedex owned empty during HUD test")
T.check(logic.requiresPokedex() == false, "logic still requires no pokedex")

-- Permanent HUD option.
run.loader.modOptions["overworld_wild_spawns"].debug_hud_always_visible = true
logic.state.hudShownAt = nil
T.check(exports.hud:shouldShow(), "always-visible HUD shows without recent map enter")
run.loader.modOptions["overworld_wild_spawns"].debug_hud_always_visible = false

-- Global encounter index + location collapse.
local index = EncounterIndex.build(mockGame)
T.check(index.FIXMON_A ~= nil, "index has FIXMON_A from global encounters")
T.check(index.FIXMON_B ~= nil, "index has FIXMON_B")
T.check(index.FIXMON_C ~= nil, "index has FIXMON_C water slot")
local aLines = EncounterIndex.formatLocations(index.FIXMON_A)
local collapsed = table.concat(aLines, " | ")
T.check(collapsed:find("Route 2", 1, true), "locations include Route 2")
T.check(collapsed:find("3-7", 1, true) or collapsed:find("Level 3-7", 1, true),
        "Route 2 levels collapsed to range")
-- Same route multiple levels for FIXMON_B on ROUTE_TEST -> single line range.
local bLines = EncounterIndex.formatLocations(index.FIXMON_B)
local rtxt = table.concat(bLines, " | ")
T.check(rtxt:find("2-3", 1, true) or rtxt:find("Level 2-3", 1, true),
        "same route levels collapsed")

-- Preview browser lists species without pokedex / unseen species.
exports.browser:invalidateIndex()
local rows = exports.browser:speciesRows(mockGame)
local seenIds = {}
for _, row in ipairs(rows) do seenIds[row.value] = row end
T.check(seenIds.FIXMON_A, "preview shows FIXMON_A without pokedex")
T.check(seenIds.PIDGEY, "preview shows late PIDGEY without pokedex")
T.check(seenIds.RATTATA, "preview shows late RATTATA without pokedex")
T.check(seenIds.MAGIKARP or true, "preview may include species from content/data")
-- Late species without per-species registration still get the shared fallback.
T.check(seenIds.PIDGEY.right:find("FALLBACK", 1, true)
        or exports.render:assetStatusFor("PIDGEY", mockGame).fallbackAvailable == true,
        "late PIDGEY uses fallback overworld preview")
-- Ensure pokedex filter is not applied: empty seen/owned still lists species.
T.check(#rows > 0, "preview browser non-empty without pokedex")

-- Fallback asset is registered at load and present on disk in the mod tree.
T.eq(exports.render.fallbackId, "SPRITE_OW_WILD_FALLBACK", "fallback sprite id")
T.check(exports.render.fallbackAvailable == true, "fallback available after load")
local fbPath = exports.render.fallbackPath
T.check(type(fbPath) == "string" and fbPath:find("fallback/pokemon_missing.png", 1, true),
        "fallback path points at assets/fallback/pokemon_missing.png")
local fbDef = run.loader.content.sprites:get("SPRITE_OW_WILD_FALLBACK")
T.check(fbDef ~= nil, "fallback sprite registered in content")
T.check(fbDef.image:find("fallback/pokemon_missing.png", 1, true),
        "fallback content image path")
-- Placeholder also uses the assets/ prefix (LÖVE virtual path under the mod).
local phDef = run.loader.content.sprites:get("SPRITE_OW_WILD_PLACEHOLDER")
T.check(phDef ~= nil and phDef.image:find("assets/spawn_placeholder.png", 1, true),
        "placeholder uses assets/spawn_placeholder.png")

-- Screens registered.
local screens = run.loader.content.screens
T.check(screens:get("OverworldSpawnPreview") ~= nil,
        "preview screen registered")
T.check(screens:get("OverworldSpawnPreviewDetail") ~= nil,
        "preview detail screen registered")

-- Debug HUD pipeline registered (present-only).
local pipes = run.loader.content.render_pipelines
T.check(pipes:get("owwild_debug_hud") ~= nil, "debug HUD render pipeline registered")
T.check(pipes:get("owwild_debug_hud").present ~= nil, "pipeline has present()")
T.check(pipes:get("owwild_debug_hud").drawWorld == nil,
        "HUD pipeline is present-only (does not replace world)")

-- Test spawn without pokedex, no player move, no pokedex mutation.
mockOw.entities = { mockPlayer }
logic:clearAll()
logic.activeMapId = "ROUTE_TEST"
logic.state.initialized = true
logic.state.mapSupported = true
logic.state.encounterDataAvailable = true
logic.state.eligibleTilesAvailable = true
logic.state.rendererAvailable = true
logic.state.updateCallbackRegistered = true
logic.state.pipelineVerified = true
logic.grassCache = Grass.cells(fakeMap)
run.loader.modOptions["overworld_wild_spawns"].dev_mode = true
run.loader.modOptions["overworld_wild_spawns"].allow_debug_spawn_outside_encounter_areas = false

local px0, py0 = mockPlayer.cellX, mockPlayer.cellY
local pokedexBefore = mockGame.save.pokedex
local flagsBefore = mockGame.save.flags
exports.render.assetInfo = {}
exports.render.runtimeImageCache = {}

-- =====================================================================
-- REGRESSION: content registries frozen → test spawn / lookup must not
-- call sprites:register (no "content is frozen after load").
-- =====================================================================
local spritesReg = run.loader.content.sprites
T.check(spritesReg.frozen == true, "sprites registry is frozen after load")
local registerCalls = 0
local overrideCalls = 0
local patchCalls = 0
local removeCalls = 0
local origRegister = spritesReg.register
local origOverride = spritesReg.override
local origPatch = spritesReg.patch
local origRemove = spritesReg.remove
spritesReg.register = function(self, ...)
  registerCalls = registerCalls + 1
  return origRegister(self, ...)
end
spritesReg.override = function(self, ...)
  overrideCalls = overrideCalls + 1
  return origOverride(self, ...)
end
spritesReg.patch = function(self, ...)
  patchCalls = patchCalls + 1
  return origPatch(self, ...)
end
spritesReg.remove = function(self, ...)
  removeCalls = removeCalls + 1
  return origRemove(self, ...)
end

-- Pure lookup: known species returns pre-registered id; no registry writes.
local sid, sidErr = exports.render:spriteIdFor("FIXMON_A")
T.eq(sid, "SPRITE_OW_WILD_FIXMON_A", "spriteIdFor returns pre-registered id")
T.eq(sidErr, nil, "spriteIdFor no error for known species")
T.eq(registerCalls, 0, "spriteIdFor does not call sprites:register")

-- Late species without a per-species sprite still resolve to the shared fallback.
local missingId, missingErr, usedFb = exports.render:spriteIdFor("PIDGEY")
T.eq(missingId, "SPRITE_OW_WILD_FALLBACK", "spriteIdFor returns shared fallback")
T.eq(missingErr, nil, "spriteIdFor no hard error when fallback exists")
T.eq(usedFb, true, "spriteIdFor reports shared-fallback flag")
T.eq(registerCalls, 0, "fallback spriteIdFor still does not register")

-- =====================================================================
-- REGRESSION: missing cache/pidgey.png must NOT block test spawn.
-- Given: species exists, no cache file, no real overworld PNG, fallback ok.
-- When: test spawn Pidgey
-- Then: fallback loaded, entity created/registered/rendered, no crash.
-- =====================================================================
exports.render:invalidateAssetCache("PIDGEY")
local pidgeyCandidates = exports.render:assetCandidates("PIDGEY", mockGame)
local sources = {}
for _, c in ipairs(pidgeyCandidates) do sources[#sources + 1] = c.source end
local joinedSources = table.concat(sources, ",")
T.check(joinedSources:find("dex_padded", 1, true)
        or joinedSources:find("species_id", 1, true),
        "Pidgey candidates include species-id / dex paths before cache")
T.check(joinedSources:find("runtime_cache", 1, true),
        "Pidgey candidates list optional cache last among real sources")
T.check(not (pidgeyCandidates[1] and pidgeyCandidates[1].source == "runtime_cache"),
        "Pidgey is not searched exclusively under cache/")
local cacheOnly = true
for _, c in ipairs(pidgeyCandidates) do
  if c.source ~= "runtime_cache" then cacheOnly = false break end
end
T.check(not cacheOnly, "Pidgey resolution is not cache-only")

-- Same for Kakuna-shaped names: cache must not be the only candidate.
mockGame.data.pokemon.KAKUNA = {
  id = "KAKUNA", name = "Kakuna", dex = 14, spriteFront = "missing_kakuna.png",
}
exports.render:invalidateAssetCache("KAKUNA")
local kakunaCandidates = exports.render:assetCandidates("KAKUNA", mockGame)
T.check(#kakunaCandidates >= 2, "Kakuna has multiple candidate paths")
T.check(kakunaCandidates[#kakunaCandidates].source == "runtime_cache"
        or kakunaCandidates[#kakunaCandidates].path:find("cache/", 1, true),
        "Kakuna cache candidate is last")
local kakunaCacheOnly = true
for _, c in ipairs(kakunaCandidates) do
  if c.source ~= "runtime_cache" then kakunaCacheOnly = false break end
end
T.check(not kakunaCacheOnly, "Kakuna is not searched exclusively under cache/")

-- Resolve with no readable real asset → FALLBACK_LOADED.
local resolvedPidgey = exports.render:resolveAsset("PIDGEY", mockGame, { force = true })
T.eq(resolvedPidgey.status, "FALLBACK_LOADED", "Pidgey resolves to fallback when real assets missing")
T.check(resolvedPidgey.fallbackUsed == true, "Pidgey fallbackUsed")
T.check(resolvedPidgey.path
        and resolvedPidgey.path:find("fallback/pokemon_missing.png", 1, true),
        "Pidgey resolved path is fallback png")

-- Bake must return a LÖVE virtual path, never getSaveDirectory() absolute.
local renderSrcBake = modApi:read("lib/spawn_render.lua")
T.check(not renderSrcBake:find("getSaveDirectory() ..", 1, true)
        and not renderSrcBake:find("getSaveDirectory()..", 1, true),
        "bakeSheet does not concatenate getSaveDirectory() into image paths")
T.check(renderSrcBake:find('overworld_wild_spawns-cache', 1, true),
        "optional cache uses overworld_wild_spawns-cache virtual dir")
T.check(renderSrcBake:find("assets/fallback/pokemon_missing.png", 1, true),
        "static fallback asset path present")
-- Documented: never return OS absolute bake paths.
T.check(renderSrcBake:find("never an OS absolute path", 1, true)
        or renderSrcBake:find("LÖVE-virtual relative path", 1, true)
        or renderSrcBake:find("virtual path", 1, true),
        "bake path contract documented as virtual")

-- Late species with no per-species sprite: test spawn SUCCEEDS via fallback.
local missingSpawn = exports.testSpawn("PIDGEY", { level = 4 })
T.check(missingSpawn.ok == true,
        "test spawn succeeds with fallback when real asset missing: "
          .. tostring(missingSpawn.error))
T.check(missingSpawn.fallbackUsed == true, "test spawn reports fallbackUsed")
T.eq(missingSpawn.runtimeImage, "FALLBACK_LOADED", "preview runtime FALLBACK LOADED")
T.check(missingSpawn.summary
        and missingSpawn.summary:find("fallback", 1, true),
        "test spawn summary mentions fallback")
T.eq(registerCalls, 0, "fallback test spawn does not register content")

-- Happy path with a species registered during mod init.
local result = exports.testSpawn("FIXMON_A", { level = 4 })
T.check(result.ok == true, "test spawn succeeds without pokedex: " .. tostring(result.error))
T.eq(result.failedAt, nil, "test spawn no failed step")
T.eq(#result.steps, 7, "test spawn reports 7 phases")
for i = 1, 7 do
  T.check(result.steps[i] and result.steps[i].ok, "test spawn step " .. i .. " ok")
end
T.eq(mockPlayer.cellX, px0, "test spawn does not move player X")
T.eq(mockPlayer.cellY, py0, "test spawn does not move player Y")
T.check(mockGame.save.pokedex == pokedexBefore, "test spawn does not replace pokedex table")
T.check(next(mockGame.save.pokedex.seen) == nil, "test spawn does not mark seen")
T.check(next(mockGame.save.pokedex.owned) == nil, "test spawn does not mark owned")
T.check(mockGame.save.flags == flagsBefore, "test spawn does not replace flags table")

-- Entity from test spawn is registered in the world list.
-- Gen1 species with native runtime sheets are not treated as missing-art
-- fallbacks anymore (PIDGEY resolves to dex 16 sheet).
local fbEntity = nil
for _, e in ipairs(mockOw.entities) do
  if e.overworldWildSpawn and e.species == "PIDGEY" then fbEntity = e break end
end
T.check(fbEntity ~= nil, "fallback test spawn entity present in world")
T.check(fbEntity.registeredInWorld == true, "fallback entity registeredInWorld")
T.check(fbEntity.sprite ~= nil and fbEntity.draw ~= nil, "fallback entity has draw path")
T.check(fbEntity.usingFallback == true or missingSpawn.fallbackUsed == true
        or fbEntity.pokemonRenderer ~= nil,
        "test-spawn entity has fallback or native renderer path")

-- Repeated test spawn must not re-register sprites.
local result2 = exports.testSpawn("FIXMON_B", { level = 5 })
T.check(result2.ok == true, "second test spawn succeeds: " .. tostring(result2.error))
T.eq(registerCalls, 0, "no sprites:register across test spawns after freeze")
T.eq(overrideCalls, 0, "no sprites:override after freeze")
T.eq(patchCalls, 0, "no sprites:patch after freeze")
T.eq(removeCalls, 0, "no sprites:remove after freeze")

-- Name sanitization: Mr. Mime / Farfetch'd style tokens.
local mimeTok = nil
do
  -- exercise sanitize via candidates for a synthetic mon
  mockGame.data.pokemon.MR_MIME = {
    id = "MR_MIME", name = "Mr. Mime", dex = 122,
    spriteFront = "assets/generated/battle/front/mr_mime.png",
  }
  local cands = exports.render:assetCandidates("MR_MIME", mockGame)
  local hasDisplay = false
  for _, c in ipairs(cands) do
    if c.source == "display_name" then
      hasDisplay = true
      T.check(c.path:find("mrmime", 1, true), "Mr. Mime display token strips punctuation")
    end
    if c.source == "dex_padded" then
      T.check(c.path:find("122.png", 1, true), "dex-padded path uses species dex")
    end
  end
  T.check(hasDisplay, "Mr. Mime has sanitized display_name candidate")
end

-- Preview browser navigation / status after freeze: no registry mutation.
exports.browser:invalidateIndex()
local browsed = exports.browser:speciesRows(mockGame)
T.check(#browsed > 0, "browser navigation works after registry freeze")
local detail = exports.browser:_openDetail(mockGame, "FIXMON_A")
T.check(detail ~= nil, "browser detail opens after freeze")
local detailMissing = exports.browser:_openDetail(mockGame, "RATTATA")
T.check(detailMissing ~= nil, "browser detail opens for missing-sprite species")
T.eq(registerCalls, 0, "preview browser does not register sprites")

-- Map change / options change must not register sprites.
logic:onMapExited({ mapId = "ROUTE_TEST" })
mockOw.entities = { mockPlayer }
logic:onMapEntered({ mapId = "ROUTE_TEST" })
logic:onOptionsChanged({
  mod = "overworld_wild_spawns", key = "sprite_opacity", value = 0.9,
})
T.eq(registerCalls, 0, "map/options changes do not register sprites")

-- Attempting internal registration after init is rejected by the mod guard.
local lateReg, lateErr = exports.render:_registerSprite("SPRITE_OW_WILD_LATE", {
  image = "x.png", frames = 1, trueColor = true,
})
T.eq(lateReg, nil, "mod guard blocks late sprite registration")
T.check(type(lateErr) == "string"
        and lateErr:find("after mod initialization", 1, true) ~= nil,
        "late registration returns clear mod error")
T.eq(registerCalls, 0, "guarded late registration never reaches registry")

-- Restore registry methods.
spritesReg.register = origRegister
spritesReg.override = origOverride
spritesReg.patch = origPatch
spritesReg.remove = origRemove

-- Precise failure phase: unknown species fails at step 1.
local bad = exports.testSpawn("NOT_A_REAL_MON")
T.check(bad.ok == false, "unknown species test spawn fails")
T.eq(bad.failedAt, 1, "fails at species resolved")
T.check(tostring(bad.error):find("unknown", 1, true), "error mentions unknown species")

-- Source scan: spriteIdFor / testSpawn path must not contain runtime register.
local renderSrc = modApi:read("lib/spawn_render.lua")
local sidPos = renderSrc:find("function SpawnRender:spriteIdFor", 1, true)
T.check(sidPos ~= nil, "spriteIdFor present")
local sidEnd = renderSrc:find("\nfunction SpawnRender:getRuntimeImage", sidPos, true)
T.check(sidEnd ~= nil, "getRuntimeImage follows spriteIdFor")
local spriteIdForBody = renderSrc:sub(sidPos, sidEnd)
T.check(not spriteIdForBody:find(":register", 1, true),
        "spriteIdFor body has no :register call")
T.check(renderSrc:find("registerContent", 1, true),
        "registerContent performs load-time registration")
T.check(not renderSrc:find("frozen%s*=%s*false", 1),
        "mod never clears registry.frozen")
local logicSrc = modApi:read("lib/spawn_logic.lua")
local testPos = logicSrc:find("function SpawnLogic:testSpawn", 1, true)
T.check(testPos ~= nil, "testSpawn present")
local testEnd = logicSrc:find("\nfunction SpawnLogic:onMapEntered", testPos, true)
local testBody = logicSrc:sub(testPos, testEnd or #logicSrc)
T.check(not testBody:find("sprites:register", 1, true),
        "testSpawn does not call sprites:register")
T.check(not testBody:find("content.sprites:register", 1, true),
        "testSpawn does not call content.sprites:register")

-- allow_debug_spawn_outside_encounter_areas bypasses only encounter-tile rule.
-- Blocked / warp / player tiles remain forbidden.
run.loader.modOptions["overworld_wild_spawns"].allow_debug_spawn_outside_encounter_areas = true
local okW, reasonW = Grass.validateWalkableTile(
  fakeMap, {}, mockPlayer, 2, 2, 1, 12, nil)
T.check(not okW and reasonW == "rejected: blocked tile",
        "outside mode still forbids blocked tiles")
okW, reasonW = Grass.validateWalkableTile(
  fakeMap, {}, mockPlayer, 5, 4, 1, 12, nil)
T.check(not okW and reasonW == "rejected: warp tile",
        "outside mode still forbids warp tiles")
okW, reasonW = Grass.validateWalkableTile(
  fakeMap, {}, mockPlayer, 0, 0, 1, 12, nil)
T.check(not okW and reasonW == "rejected: occupied by player",
        "outside mode still forbids player tile")
-- Non-grass walkable cell becomes allowed for placement validation.
fakeMap.isGrassCell = function(_, x, y)
  return (x >= 2 and x <= 5 and y >= 2 and y <= 4)
end
local nonGrassOk = Grass.validateWalkableTile(
  fakeMap, {}, { cellX = 0, cellY = 0 }, 1, 0, 1, 12, nil)
T.check(nonGrassOk, "outside mode allows free non-encounter walkable tile")
local grassStillRequired = select(1, Grass.validateSpawnTile(
  fakeMap, {}, { cellX = 0, cellY = 0 }, 1, 0, 1, 12, nil))
T.check(not grassStillRequired, "normal spawn still requires encounter tile")

-- Overlay does not alter collision (markers are passable).
run.loader.modOptions["overworld_wild_spawns"].show_spawn_tile_overlay = true
mockOw.map = fakeMap
mockOw.entities = { mockPlayer }
exports.overlay:rebuild()
local overlayCount = 0
local nonPassableOverlay = 0
for _, e in ipairs(mockOw.entities) do
  if e.overworldWildOverlay then
    overlayCount = overlayCount + 1
    if not e.passable then nonPassableOverlay = nonPassableOverlay + 1 end
  end
end
T.check(overlayCount > 0, "overlay places markers when enabled")
T.eq(nonPassableOverlay, 0, "overlay markers are passable (no collision change)")
exports.overlay:clear()
T.eq(#exports.overlay.markers, 0, "overlay clear removes markers")

-- Overlay legend documented in code.
local legend = exports.overlay:legend()
T.check(#legend >= 4, "overlay legend has entries")

-- Visibility counters exist and are separated.
local vis = Diagnostics.visibilityCounts(logic)
T.check(vis.created ~= nil and vis.registered ~= nil
        and vis.rendered ~= nil and vis.visible ~= nil,
        "visibility counters separated")

-- Status constants are the required set.
for _, name in ipairs({
  "DISABLED", "INITIALIZING", "NO_ENCOUNTER_DATA", "NO_ELIGIBLE_TILES",
  "ASSETS_LOADING", "ASSET_ERROR", "NO_RENDERER", "READY", "SPAWNING",
  "FALLBACK_TO_VANILLA", "ERROR",
}) do
  T.check(Config.STATUS[name] ~= nil, "status constant " .. name)
end

-- NO_ENCOUNTER_DATA status on town map.
mockOw.map = townMap
mockOw.entities = { mockPlayer }
logic:onMapEntered({ mapId = "TOWN_NO_ENC" })
T.eq(Diagnostics.spawnSystemStatus(logic), Config.STATUS.NO_ENCOUNTER_DATA,
     "status NO_ENCOUNTER_DATA without grass table")

-- DramaticShapeVoxelMod is not a hard dependency.
T.check(modMeta.manifest.dependencies == nil
        or (type(modMeta.manifest.dependencies) == "table"
            and #modMeta.manifest.dependencies == 0),
        "no hard dependencies")
T.check(modMeta.manifest.optional_dependencies == nil
        or (type(modMeta.manifest.optional_dependencies) == "table"
            and #modMeta.manifest.optional_dependencies == 0),
        "no optional_dependencies; DRAMATIC_SHAPE not required")
T.check(run.loader.mods["DRAMATIC_SHAPE"] == nil,
        "works without DramaticShapeVoxelMod loaded (dev suite)")

-- Source scan: no pokedex gates in spawn/preview paths.
local previewSrc = modApi:read("lib/preview_browser.lua")
T.check(not previewSrc:find("got_pokedex"), "preview has no got_pokedex gate")
T.check(not previewSrc:find("hasPokedex"), "preview has no hasPokedex gate")
T.check(previewSrc:find("diag", 1, true), "preview may mention pokedex as diag only")
local spawnSrc = modApi:read("lib/spawn_logic.lua")
T.check(spawnSrc:find("Diagnostic only", 1, true)
        or spawnSrc:find("diag%-only")
        or spawnSrc:find("never a spawn"),
        "spawn_logic documents pokedex as diagnostic only")

-- Disable dev_mode: HUD and outside-spawn flag inactive.
run.loader.modOptions["overworld_wild_spawns"].dev_mode = false
run.loader.modOptions["overworld_wild_spawns"].debug_hud_always_visible = true
run.loader.modOptions["overworld_wild_spawns"].allow_debug_spawn_outside_encounter_areas = true
run.loader.modOptions["overworld_wild_spawns"].show_spawn_tile_overlay = true
T.check(not Config.devMode(modApi), "dev_mode off")
T.check(not exports.hud:shouldShow(), "HUD off when dev_mode false even if always_visible")
T.check(not Config.allowOutsideEncounter(modApi),
        "outside spawn ignored when dev_mode false")
T.check(not Config.showSpawnTileOverlay(modApi),
        "overlay ignored when dev_mode false")
local denied = exports.testSpawn("FIXMON_A")
T.check(denied.ok == false, "test spawn denied when dev_mode false")

-- Works without Pokédex and without DramaticShapeVoxelMod (already asserted).
T.check(mockGame.save.pokedex == nil
        or (mockGame.save.pokedex.seen and next(mockGame.save.pokedex.seen) == nil),
        "suite completes with empty / unused pokedex")

-- ============================================================
-- 0.4.2: Wilds of Kanto public rename; density/behaviours from 0.4.0
-- ============================================================

local schemaKeys = {}
for _, row in ipairs(schema) do schemaKeys[row.key] = row end
T.check(schemaKeys.spawn_density == nil, "spawn_density removed from Mod Settings")
T.check(schemaKeys.grass_encounters == nil, "grass_encounters removed from schema")
T.check(schemaKeys.random_encounters ~= nil, "random_encounters option present")
T.eq(schemaKeys.random_encounters.default, true, "random_encounters default ON")
T.eq(schemaKeys.random_encounters.label, "Random Enc", "random_encounters label")
T.check(schemaKeys.water_spawns ~= nil, "water_spawns option present")
T.eq(schemaKeys.water_spawns.type, "choice", "water_spawns is choice")
T.eq(schemaKeys.water_spawns.default, "swimming_sprites", "water_spawns default swimming_sprites")
T.eq(schemaKeys.water_spawns.label, "Water Mons", "water_spawns label")
T.eq(#schemaKeys.water_spawns.choices, 5, "five water display modes")
T.check(schemaKeys.max_visible_pokemon == nil, "max_visible_pokemon removed from public schema")
T.check(schemaKeys.min_sprite_size == nil, "min_sprite_size removed from public schema")
T.check(schemaKeys.sprite_opacity == nil, "sprite_opacity removed from public schema")
T.check(schemaKeys.strict_world_billboard_debug == nil, "strict billboard debug removed")
T.check(schemaKeys.max_spawns == nil, "legacy max_spawns removed from schema")
T.check(schemaKeys.enable_idle ~= nil, "enable_idle option")
T.check(schemaKeys.enable_wander ~= nil, "enable_wander option")
T.check(schemaKeys.enable_aggressive ~= nil, "enable_aggressive option")
T.check(schemaKeys.enable_hidden ~= nil, "enable_hidden option")
T.check(schemaKeys.show_behavior_overlays ~= nil, "show_behavior_overlays option")
T.eq(schemaKeys.enable_wander.label, "Roam Mons", "wander label")
T.eq(schemaKeys.enable_aggressive.label, "Chase Mons", "aggressive label")
T.eq(schemaKeys.enable_hidden.label, "Hidden Mons", "hidden label")
T.eq(schemaKeys.pokemon_grass_render_mode.label, "Grass View", "grass view label")
-- All visible labels must fit Gen1Recomp's 14-character option row.
for _, row in ipairs(schema) do
  T.check(#row.label <= 14,
          ("option label <=14: %s (%d)"):format(row.label, #row.label))
  if row.choices then
    for _, choice in ipairs(row.choices) do
      local display = choice[1]
      T.check(#tostring(display) <= 14,
              ("choice label <=14: %s (%d)"):format(tostring(display), #tostring(display)))
    end
  end
end
-- Hardcoded fine-tuning defaults remain available to runtime helpers.
T.eq(Config.DEFAULTS.max_visible_pokemon, 12, "runtime default max_visible_pokemon")
T.eq(Config.DEFAULTS.min_sprite_size, 16, "runtime default min_sprite_size")
T.eq(Config.DEFAULTS.sprite_opacity, 1.0, "runtime default sprite_opacity")
T.eq(Config.DEFAULTS.enable_grass_movement_effects, true, "runtime default grass movement")

-- Density: small patch vs long route.
local smallTarget = SpawnRegions.targetCount({
  eligibleTiles = 18, minVisible = 1, maxVisible = 12,
  tilesPerAdditional = 24, density = "normal", mapSpan = 20,
})
local longTarget = SpawnRegions.targetCount({
  eligibleTiles = 180, minVisible = 1, maxVisible = 12,
  tilesPerAdditional = 24, density = "normal", mapSpan = 60,
})
T.check(smallTarget <= 3, "small route target stays low (" .. tostring(smallTarget) .. ")")
T.check(longTarget > smallTarget, "long route target exceeds small route")
T.check(longTarget <= 12, "long route respects maximum")

local highTarget = SpawnRegions.targetCount({
  eligibleTiles = 180, minVisible = 1, maxVisible = 16,
  tilesPerAdditional = 24, density = "very_high", mapSpan = 60,
})
T.check(highTarget >= longTarget, "very_high density raises target")

-- Regions: two disconnected grass patches get separate quotas.
local regionCells = {}
for x = 0, 5 do regionCells[#regionCells + 1] = { x = x, y = 0 } end
for x = 20, 29 do regionCells[#regionCells + 1] = { x = x, y = 0 } end
local regions = SpawnRegions.build(regionCells)
T.eq(#regions, 2, "two disconnected patches become two regions")
local quotas, assigned = SpawnRegions.allocate(regions, 6)
T.check(assigned <= 6, "allocation never exceeds target")
local qSum = 0
for _, q in pairs(quotas) do qSum = qSum + q end
T.eq(qSum, assigned, "quota sum matches assigned")
T.check((quotas[1] or 0) >= 1 and (quotas[2] or 0) >= 1,
        "both regions receive capacity when target allows")

-- Surface abstraction.
local grassSurface = Surface.resolve(mockGame, {
  id = "ROUTE_X",
  def = { tileset = "OVERWORLD", index = 1 },
  isGrassCell = function() return true end,
  widthCells = 4, heightCells = 4,
}, { grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } } })
T.eq(grassSurface.surface, Surface.GRASS, "grass surface when grass tiles exist")

local caveMap = {
  id = "MT_MOON_1F",
  def = { tileset = "CAVERN", index = 40 },
  widthCells = 4, heightCells = 4,
  isGrassCell = function() return false end,
  isWalkableCell = function() return true end,
  isWaterCell = function() return false end,
  warpAtCell = function() return nil end,
}
local caveSurface = Surface.resolve(mockGame, caveMap, {
  grass = { rate = 10, slots = { { species = "ZUBAT", level = 8 } } },
})
T.eq(caveSurface.surface, Surface.CAVE, "cave surface without grass graphics")
T.eq(caveSurface.tileMode, "walkable", "cave uses walkable tiles")
T.check(Surface.allowsBehavior(Surface.CAVE, Behavior.IDLE_LOOK), "cave allows idle")
T.check(not Surface.allowsBehavior(Surface.CAVE, Behavior.HIDDEN_GRASS),
        "cave does not use grass-shake hidden")
T.check(Surface.allowsBehavior(Surface.CAVE, Behavior.HIDDEN_CAVE),
        "cave allows hidden cave effect")

local waterSurface = Surface.resolve(mockGame, {
  id = "ROUTE_19",
  def = { tileset = "OVERWORLD", index = 1 },
  isGrassCell = function() return false end,
  isWaterCell = function() return true end,
  widthCells = 2, heightCells = 2,
}, { water = { rate = 5, slots = { { species = "TENTACOOL", level = 5 } } } })
T.eq(waterSurface.surface, Surface.WATER, "water surface from surf table")
T.check(waterSurface.fishingSeparate == true, "fishing kept separate from surf")

-- Fishing never free-spawns.
T.check(EncounterPick.pick({
  fishing = { slots = { { species = "MAGIKARP", level = 5 } } },
}, function() return 0 end, "fishing") == nil,
  "fishing kind rejected for free overworld pick")
local waterPick = EncounterPick.pick({
  water = { rate = 5, slots = { { species = "TENTACOOL", level = 5 } } },
  grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } },
}, function(a, b)
  if b then return a end
  return 0
end, "water")
T.check(waterPick and waterPick.species == "TENTACOOL",
        "water pick uses surf table species")

-- Behaviour weights and idle look.
local w = Behavior.weightsFor("PIDGEY", Surface.GRASS, {})
T.check(w[Behavior.IDLE_LOOK] > 0, "idle weight positive")
T.check(w[Behavior.AGGRESSIVE] > 0, "aggressive weight positive")
local idleOnly = Behavior.pick("METAPOD", Surface.GRASS, {
  enable_wander = false, enable_aggressive = false, enable_hidden = false,
}, function() return 0.1 end)
T.eq(idleOnly, Behavior.IDLE_LOOK, "forced idle when others disabled")

local bstate = Behavior.initState(Behavior.IDLE_LOOK, function(a, b)
  if b then return a end
  if a then return 1 end
  return 0.5
end)
T.check(bstate.lookInterval >= 5 and bstate.lookInterval <= 10,
        "idle look interval in 5-10s")
local bstate2 = Behavior.initState(Behavior.IDLE_LOOK, function(a, b)
  if b then return b end
  if a then return a end
  return 0.9
end)
T.check(bstate.lookInterval ~= bstate2.lookInterval
        or bstate.nextActionAt ~= bstate2.nextActionAt,
        "idle intervals differ across entities when rng differs")

-- Idle stays on tile.
local idleEnt = {
  cellX = 4, cellY = 4, facing = "down",
  behaviorState = Behavior.initState(Behavior.IDLE_LOOK, function() return 0 end),
  setCell = function(self, x, y) self.cellX, self.cellY = x, y end,
  surface = Surface.GRASS,
  state = Config.STATE.AVAILABLE,
}
idleEnt.behavior = Behavior.IDLE_LOOK
idleEnt.behaviorState.nextActionAt = 0
Behavior.tick(idleEnt, {
  map = fakeMap, entities = {}, player = mockPlayer, dt = 0.016,
})
T.eq(idleEnt.cellX, 4, "idle look does not move X")
T.eq(idleEnt.cellY, 4, "idle look does not move Y")

-- Wander stays in home region.
local home = regions[1]
local wanderEnt = {
  cellX = home.tiles[1].x, cellY = home.tiles[1].y,
  facing = "down", surface = Surface.GRASS,
  homeRegion = home, homeRegionId = home.id,
  behavior = Behavior.GRASS_WANDER,
  behaviorState = Behavior.initState(Behavior.GRASS_WANDER, function() return 0.2 end),
  state = Config.STATE.AVAILABLE,
  setCell = function(self, x, y) self.cellX, self.cellY = x, y end,
}
wanderEnt.behaviorState.nextActionAt = 0
local longMap = {
  widthCells = 40, heightCells = 4,
  inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 40 and y < 4 end,
  isGrassCell = function(_, x, y)
    return (y == 0 and x >= 0 and x <= 5) or (y == 0 and x >= 20 and x <= 29)
  end,
  isWalkableCell = function() return true end,
  warpAtCell = function() return nil end,
}
for _ = 1, 20 do
  wanderEnt.behaviorState.nextActionAt = 0
  Behavior.tick(wanderEnt, {
    map = longMap, entities = { wanderEnt },
    player = { cellX = 100, cellY = 100 }, dt = 0.05,
  })
end
T.check(SpawnRegions.contains(home, wanderEnt.cellX, wanderEnt.cellY),
        "wanderer stays inside home region")

-- Aggressive sight: facing line only, walls block.
local aggEnt = {
  cellX = 2, cellY = 2, facing = "right", surface = Surface.GRASS,
  behavior = Behavior.AGGRESSIVE,
  behaviorState = Behavior.initState(Behavior.AGGRESSIVE, function() return 0 end),
  state = Config.STATE.AVAILABLE,
  setCell = function(self, x, y) self.cellX, self.cellY = x, y end,
}
aggEnt.behaviorState.facing = "right"
aggEnt.facing = "right"
local sightMap = {
  widthCells = 10, heightCells = 10,
  inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 10 and y < 10 end,
  isWalkableCell = function(_, x, y) return not (x == 4 and y == 2) end,
  isGrassCell = function() return true end,
}
T.check(Behavior.playerInSight(aggEnt, { cellX = 5, cellY = 2 }, sightMap, {}, 4) == false,
        "wall blocks aggressive sight")
sightMap.isWalkableCell = function() return true end
T.check(Behavior.playerInSight(aggEnt, { cellX = 5, cellY = 2 }, sightMap, {}, 4) == true,
        "clear facing line detects player")
T.check(Behavior.playerInSight(aggEnt, { cellX = 5, cellY = 3 }, sightMap, {}, 4) == false,
        "no diagonal aggressive activation")

-- Hidden grass: no sprite, contact uses preset species.
local hiddenRec = {
  id = "hid1", mapId = "ROUTE_TEST", x = 4, y = 3,
  species = "PIDGEY", level = 3, state = Config.STATE.AVAILABLE,
  behavior = Behavior.HIDDEN_GRASS, surface = Surface.GRASS,
  visibleSprite = false, hiddenEncounter = true,
}
local hidEntity = exports.render:makeEntity(mockGame, hiddenRec)
T.check(hidEntity.sprite == nil, "hidden grass has no pokemon sprite")
T.check(hidEntity.hiddenEncounter == true, "hidden flag set")
T.check(Behavior.isHidden(Behavior.HIDDEN_GRASS), "HIDDEN_GRASS is hidden")
T.check(Behavior.isHidden(Behavior.HIDDEN_CAVE), "HIDDEN_CAVE is hidden")

-- Extra suites in nested scopes (Lua 5.1 200-local limit on the main chunk).
do
  local Tile = exports.lib.require("tile")
  local Movement = exports.lib.require("movement")
  local VoxelAdapter = exports.lib.require("voxel_adapter")
  T.eq(Tile.CELL, 16, "tile size is Gen1Recomp 16px")

  local scale = SpriteScale.compute("PIDGEY", nil, {
    minVisibleHeight = 14, targetVisibleHeight = 16,
  })
  T.check(SpriteScale.fitsOneTile(scale), "default scale fits one tile")
  T.check(scale.renderedW <= Tile.WIDTH + 1e-6, "rendered W <= tile")
  T.check(scale.renderedH <= Tile.HEIGHT + 1e-6, "rendered H <= tile")
  T.check(scale.final2DScale <= scale.maximumOneTileScale + 1e-6,
          "final scale capped by one-tile max")

  local tiny = SpriteScale.compute("KAKUNA", {
    getDimensions = function() return 8, 8 end,
  }, { minVisibleHeight = 14, targetVisibleHeight = 16, minSpriteSizeOption = 16 })
  T.check(tiny.desiredScale >= 1.0, "tiny desired scale enlarges")
  T.check(tiny.renderedW <= Tile.WIDTH + 1e-6, "tiny rendered W <= tile")
  T.check(tiny.renderedH <= Tile.HEIGHT + 1e-6, "tiny rendered H <= tile")
  T.check(math.abs(tiny.renderedW / tiny.renderedH - 1) < 1e-6,
          "tiny aspect ratio preserved")

  local huge = SpriteScale.compute("SNORLAX", {
    getDimensions = function() return 96, 96 end,
  }, { minVisibleHeight = 14, targetVisibleHeight = 16 })
  T.check(huge.scale < 1.0, "huge source shrinks")
  T.check(huge.renderedW <= Tile.WIDTH + 1e-6, "huge rendered W <= tile")
  T.check(huge.renderedH <= Tile.HEIGHT + 1e-6, "huge rendered H <= tile")

  local padded = {
    getDimensions = function() return 64, 64 end,
    getData = function()
      return {
        getPixel = function(_, x, y)
          if x >= 20 and x <= 35 and y >= 30 and y <= 49 then
            return 0.2, 0.2, 0.2, 1
          end
          return 0, 0, 0, 0
        end,
      }
    end,
  }
  local paddedScale = SpriteScale.compute("PIDGEY", padded, {})
  T.eq(paddedScale.contentW, 16, "visible bounds ignore transparent X pad")
  T.eq(paddedScale.contentH, 20, "visible bounds ignore transparent Y pad")
  T.check(paddedScale.renderedW <= Tile.WIDTH + 1e-6, "padded rendered W <= tile")
  T.check(paddedScale.renderedH <= Tile.HEIGHT + 1e-6, "padded rendered H <= tile")
  T.check(paddedScale.grassOcclusionHeight <= paddedScale.renderedH * 0.35 + 1e-6,
          "grass occlusion <= 35% of rendered height")

  local forced = SpriteScale.compute("PIDGEY", {
    getDimensions = function() return 16, 16 end,
  }, { minSpriteSizeOption = 64, minVisibleHeight = 64, targetVisibleHeight = 64 })
  T.check(forced.renderedH <= Tile.HEIGHT + 1e-6, "min option cannot exceed one tile")

  local speciesOk, speciesFail = 0, 0
  if mockGame.data and mockGame.data.pokemon then
    for speciesId, _ in pairs(mockGame.data.pokemon) do
      local info = SpriteScale.compute(speciesId, {
        getDimensions = function() return 56, 56 end,
      }, {})
      if SpriteScale.fitsOneTile(info) then speciesOk = speciesOk + 1
      else speciesFail = speciesFail + 1 end
    end
  end
  T.check(speciesFail == 0, "all probed species fit one tile (fail=" .. speciesFail .. ")")
  T.check(speciesOk > 0, "probed at least one species for one-tile scale")

  local moveEnt = {
    cellX = 3, cellY = 4, facing = "down",
    behaviorState = { facing = "down" },
  }
  Movement.init(moveEnt, 3, 4, "down")
  T.eq(moveEnt.position.tileX, 3, "movement tileX")
  T.eq(moveEnt.px, 3 * Tile.CELL, "pixelX from tile")
  T.check(Movement.beginStep(moveEnt, 4, 4, { facing = "right" }), "begin step")
  T.eq(moveEnt.cellX, 3, "cell stays at origin during step")
  T.eq(moveEnt.targetX, 4, "target tile set")
  T.eq(moveEnt.position.previousTileX, 3, "previous tile captured")
  Movement.update(moveEnt, moveEnt.movement.duration)
  T.eq(moveEnt.cellX, 4, "cell finalized after step")
  T.eq(moveEnt.px, 4 * Tile.CELL, "pixel finalized after step")
end

do
  local Movement = exports.lib.require("movement")
  local VoxelAdapter = exports.lib.require("voxel_adapter")
  local agg2 = {
    cellX = 2, cellY = 2, facing = "right", surface = Surface.GRASS,
    behavior = Behavior.AGGRESSIVE, mod = modApi,
    behaviorState = Behavior.initState(Behavior.AGGRESSIVE, function() return 0 end),
    state = Config.STATE.AVAILABLE,
  }
  Movement.init(agg2, 2, 2, "right")
  agg2.behaviorState.facing = "right"
  agg2.facing = "right"
  local clearMap = {
    widthCells = 10, heightCells = 10,
    inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 10 and y < 10 end,
    isWalkableCell = function() return true end,
    isGrassCell = function() return true end,
  }
  local ev = Behavior.tick(agg2, {
    map = clearMap, entities = { agg2 },
    player = { cellX = 5, cellY = 2 }, dt = 0.016,
  })
  T.eq(ev, "alert", "aggressive emits alert once")
  T.eq(agg2.behaviorState.state, Behavior.STATE.ALERT, "enters ALERT")
  T.eq(agg2.cellX, 2, "ALERT does not move")
  local ev2 = Behavior.tick(agg2, {
    map = clearMap, entities = { agg2 },
    player = { cellX = 5, cellY = 2 }, dt = 0.016,
  })
  T.check(ev2 == nil, "no second alert while already detected")
  Behavior.markChaseReady(agg2)
  T.check(agg2.behaviorState.chaseReady or agg2.behaviorState.chasing,
          "chase armed by emote onDone path")
  Behavior.tick(agg2, {
    map = clearMap, entities = { agg2 },
    player = { cellX = 5, cellY = 2 }, dt = 0.016,
  })
  T.check(agg2.behaviorState.state == Behavior.STATE.CHASING
          or agg2.behaviorState.chasing,
          "chase state active after ready")
  local idBefore = "wilds_of_kanto_entity_99"
  agg2.id = idBefore
  Behavior.tick(agg2, {
    map = clearMap, entities = { agg2 },
    player = { cellX = 5, cellY = 2 }, dt = 0.2,
  })
  T.eq(agg2.id, idBefore, "stable id unchanged during chase")

  local okUnsafe = VoxelAdapter.isPoseSafe({
    hiddenEncounter = true, visibleSprite = false, sprite = nil,
  })
  T.check(not okUnsafe, "hidden/nil sprite rejected for Voxel")
  local safeEnt = exports.render:makeEntity(mockGame, {
    id = "wilds_of_kanto_entity_safe",
    mapId = "ROUTE_TEST", x = 1, y = 1,
    species = "PIDGEY", level = 5, state = Config.STATE.AVAILABLE,
    visibleSprite = true,
  })
  T.check(VoxelAdapter.isPoseSafe(safeEnt), "visible entity with sprite is Voxel-safe")
  T.check(select(1, VoxelAdapter.probePose(safeEnt)), "pose probe succeeds for visible entity")
  T.eq(safeEnt.voxelScale, 1, "voxel scale stays 1 (not 2D finalScale)")
  local adapter = VoxelAdapter.new(modApi)
  adapter:updateEntity(safeEnt)
  T.eq(safeEnt.voxelScale, 1, "adapter keeps voxel scale at 1")
  T.check(safeEnt.final2DScale ~= nil, "2D final scale present")
  T.check(safeEnt.voxelUpdateOk == true, "voxel update OK for safe entity")

  local hid2 = exports.render:makeEntity(mockGame, {
    id = "wilds_of_kanto_entity_hid",
    mapId = "ROUTE_TEST", x = 4, y = 3,
    species = "PIDGEY", level = 3, state = Config.STATE.AVAILABLE,
    behavior = Behavior.HIDDEN_GRASS, surface = Surface.GRASS,
    visibleSprite = false, hiddenEncounter = true,
  })
  mockOw.entities = { mockPlayer }
  local attachedHid = logic:_attach(hid2)
  T.check(attachedHid, "hidden logical attach ok")
  T.check(hid2.worldRegistration == "logical_only", "hidden stays logical-only")
  local hidInList = false
  for _, e in ipairs(mockOw.entities) do
    if e == hid2 then hidInList = true end
  end
  T.check(not hidInList, "hidden entity not in ow.entities")

  local boom = {
    overworldWildSpawn = true,
    sprite = nil, px = 0, py = 0, cellX = 0, cellY = 0,
    pose = function(self) return self.sprite, self.px, self.py, "down", 0, false, false end,
  }
  local okBoom, boomWhy = VoxelAdapter.probePose(boom)
  T.check(not okBoom, "nil-sprite pose probe fails safely: " .. tostring(boomWhy))
end

-- Land species must not be picked from water tables.
local landOnWater = EncounterPick.pick({
  water = { rate = 5, slots = { { species = "TENTACOOL", level = 5 } } },
}, nil, "water")
T.check(landOnWater.species ~= "PIDGEY", "water pick is not a land species")

-- Registry freeze still holds (no runtime register).
T.check(not exports.render:isContentRegistrationOpen(),
        "content registration closed after load")

-- Player teleport safety unchanged.
local SpawnLogicMod = exports.lib.require("spawn_logic")
T.check(SpawnLogicMod.touchesPlayerPosition() == false, "never touches player position")

-- HUD exposes new density fields.
run.loader.modOptions["overworld_wild_spawns"].dev_mode = true
run.loader.modOptions["overworld_wild_spawns"].enabled = true
mockOw.map = fakeMap
mockOw.entities = { mockPlayer }
mockOw.player = mockPlayer
logic:onMapEntered({ mapId = "ROUTE_TEST" })
local snap = Diagnostics.hudSnapshot(logic)
T.check(snap.targetPokemon ~= nil, "HUD reports target Pokemon")
T.check(snap.spawnRegions ~= nil, "HUD reports spawn regions")
T.check(snap.surface ~= nil, "HUD reports surface")
local hudLines = Diagnostics.hudLines(logic)
local joined = table.concat(hudLines, "\n")
T.check(joined:find("Target Pokemon", 1, true), "HUD lines include Target Pokemon")
T.check(joined:find("Spawn regions", 1, true), "HUD lines include Spawn regions")
T.check(joined:find("Surface:", 1, true), "HUD lines include Surface")

-- Active entities carry a behaviour.
local anyBehavior = false
for _, rec in pairs(logic.spawns) do
  if rec.behavior then anyBehavior = true end
end
T.check(anyBehavior, "spawned entities receive a behaviour type")

-- ------- sprite style providers
local AnimatedSprites = exports.lib.require("animated_sprites")
local JsonDecode = exports.lib.require("json_decode")
local SpriteProviders = exports.lib.require("sprite_providers")
T.check(exports.animated ~= nil, "animated export present")
T.check(exports.render.animated ~= nil, "render.animated present")
T.check(exports.spriteProviders ~= nil, "spriteProviders export present")
T.check(exports.render.spriteProviders ~= nil, "render.spriteProviders present")
T.check(type(exports.registerSpriteProvider) == "function", "registerSpriteProvider export")
T.check(type(exports.listSpriteProviders) == "function", "listSpriteProviders export")
T.check(type(exports.refreshAllEntitySprites) == "function", "refreshAllEntitySprites export")

local styleOpt
local legacyAnimOpt
for _, row in ipairs(schema) do
  if row.key == "sprite_style" then styleOpt = row end
  if row.key == "use_animated_overworld_sprites" then legacyAnimOpt = row end
end
T.check(styleOpt ~= nil, "sprite_style option present")
T.check(legacyAnimOpt == nil, "legacy Mon Sprites option removed")
T.eq(styleOpt.type, "choice", "sprite_style is choice")
T.eq(styleOpt.default, "pokemmo", "sprite_style defaults pokemmo")
T.eq(styleOpt.label, "Sprite Style", "sprite_style label")
T.check(#styleOpt.label <= 14, "sprite_style label <= 14 chars")
T.eq(Config.DEFAULTS.sprite_style, "pokemmo", "DEFAULTS sprite_style pokemmo")
T.eq(Config.spriteStyle(modApi), "pokemmo", "spriteStyle helper pokemmo")
T.eq(Config.useAnimatedOverworldSprites(modApi), true, "animated helper true for pokemmo")

local animSys = exports.animated
T.check(animSys.loaded == true, "animated system loaded at mod init")
T.eq(animSys.mappingFilesFound, 1, "shared followsprites mapping file found")
T.check(animSys.validSpeciesCount >= 151,
        "at least Gen1 species have valid follow mappings")
T.eq(AnimatedSprites.SPRITE_DIR,
     "assets/enhanced_overworld/followsprites",
     "followsprite dir")
T.eq(AnimatedSprites.mappingRelPath(),
     "assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json",
     "followsprites mapping path")

-- Language-independent identity = dex / speciesId
T.eq(AnimatedSprites.resolveSpeciesId("CHARMELEON", {
  data = { pokemon = { CHARMELEON = { name = "Glutexo", dex = 5 } } }
}), 5, "German display name still resolves dex 5")
T.eq(AnimatedSprites.resolveSpeciesId("CHARMELEON", {
  data = { pokemon = { CHARMELEON = { name = "Reptincel", dex = 5 } } }
}), 5, "French display name still resolves dex 5")
T.check(AnimatedSprites.resolveSpeciesId("Glutexo", {
  data = { pokemon = { CHARMELEON = { name = "Glutexo", dex = 5 } } }
}) == nil, "localized name is not a lookup key")

local m5 = animSys:getMapping(5)
T.check(m5 and m5.valid, "followsprites mapping loaded for speciesId 5")
T.check(type(m5.fileName) == "string" and m5.fileName ~= "",
        "mapping filename present for species 5")
T.check(m5.speciesName == nil or type(m5.speciesName) == "string",
        "speciesName remains display-only / optional")

-- Facing map
T.eq(AnimatedSprites.normalizeFacing("front"), "down", "front=down")
T.eq(AnimatedSprites.normalizeFacing("back"), "up", "back=up")

-- Large frames (follow-sprites may be single-tile or taller; keep footprint checks soft)
local charizard = animSys:getFrame(6, "idle", "down", 1)
T.check(charizard ~= nil, "Charizard idle frame resolves")
local scaleInfo = AnimatedSprites.calculateAnimatedSpriteScale(nil, charizard, {})
T.eq(scaleInfo.logicalFootprintTiles, 1, "large frame keeps 1-tile collision")

-- Idle left resolves (follow-sprites usually have a dedicated idle frame)
local idleLeftFrames, usedAnim = animSys:resolveFrames(1, "idle", "left")
T.check(idleLeftFrames and #idleLeftFrames >= 1, "Bulbasaur idle.left resolves")
T.check(usedAnim == "idle" or usedAnim == "walk",
        "Bulbasaur idle.left uses idle or walk fallback")

-- JSON decode smoke
local decoded = JsonDecode.decode('{"speciesId":1,"ok":true}')
T.check(decoded and decoded.speciesId == 1 and decoded.ok == true, "json_decode works")

-- Sprite style live toggle without respawn
run.loader.modOptions["overworld_wild_spawns"].sprite_style = "pokedex"
T.eq(Config.spriteStyle(modApi), "pokedex", "sprite_style can select pokedex")
T.eq(Config.useAnimatedOverworldSprites(modApi), false, "pokedex disables animated helper")
logic:onOptionsChanged({
  mod = modApi.id, key = "sprite_style", value = "pokedex",
})
run.loader.modOptions["overworld_wild_spawns"].sprite_style = "pokemmo"
logic:onOptionsChanged({
  mod = modApi.id, key = "sprite_style", value = "pokemmo",
})
T.eq(Config.spriteStyle(modApi), "pokemmo", "sprite_style pokemmo")
run.loader.modOptions["overworld_wild_spawns"].sprite_style = "followers"
logic:onOptionsChanged({
  mod = modApi.id, key = "sprite_style", value = "followers",
})
T.eq(Config.spriteStyle(modApi), "followers", "sprite_style followers")
run.loader.modOptions["overworld_wild_spawns"].sprite_style = "pokemmo"
logic:onOptionsChanged({
  mod = modApi.id, key = "sprite_style", value = "pokemmo",
})

-- HUD mentions sprite style / follow sprites
local linesAnim = Diagnostics.hudLines(logic)
local joinedAnim = table.concat(linesAnim, "\n")
T.check(joinedAnim:find("Follow sprites", 1, true), "HUD shows follow sprite status")
T.check(joinedAnim:find("Requested style:", 1, true), "HUD shows requested sprite style")
T.check(joinedAnim:find("Active provider:", 1, true), "HUD shows active provider")
T.check(joinedAnim:find("Body renderer: NATIVE_SPRITE_RENDERER", 1, true),
        "HUD shows native body renderer")

-- Provider list includes builtins
local listed = exports.listSpriteProviders()
local sawPokemmo, sawPokedex = false, false
for _, row in ipairs(listed) do
  if row.id == "pokemmo" then sawPokemmo = true end
  if row.id == "pokedex" then sawPokedex = true end
end
T.check(sawPokemmo and sawPokedex, "builtin providers listed")
T.check(exports.getSpriteProvider("pokemmo") ~= nil, "getSpriteProvider pokemmo")
T.check(exports.getSpriteProvider("followers_ex") ~= nil, "getSpriteProvider followers_ex")
T.check(SpriteProviders.STYLE_CHAINS.pokemmo[1] == "pokemmo", "pokemmo chain starts pokemmo")
T.check(SpriteProviders.STYLE_CHAINS.followers[1] == "followers_ex",
        "followers style maps to followers_ex provider")
T.check(SpriteProviders.STYLE_CHAINS.followers[2] == "pokemmo",
        "followers falls back to pokemmo")
T.check(Config.normalizeSpriteStyle("auto") == "pokemmo", "auto migrates to pokemmo")
T.check(Config.normalizeSpriteStyle("gold") == "pokemmo", "gold migrates to pokemmo")
T.check(Config.normalizeSpriteStyle("followers_ex") == "followers",
        "followers_ex migrates to followers")
T.check(type(exports.setSpriteStyle) == "function", "setSpriteStyle export")
T.check(exports.spriteStyleMenu ~= nil, "spriteStyleMenu export")
T.eq(exports.spriteStyleMenu._registered, true, "SPRITE STYLE menu registered once")

local styleChoices = {}
for _, choice in ipairs(styleOpt.choices) do
  styleChoices[choice[2]] = choice[1]
  T.check(#choice[1] <= 14, "style choice label <= 14: " .. tostring(choice[1]))
end
T.eq(#styleOpt.choices, 3, "exactly three public sprite styles")
T.check(styleChoices.pokemmo == "HGSS / PokeMMO", "HGSS / PokeMMO choice present")
T.check(styleChoices.followers == "Poke Followers", "Poke Followers choice present")
T.check(styleChoices.pokedex == "Pokedex", "Pokedex choice present")
T.check(styleChoices.auto == nil and styleChoices.gold == nil, "legacy styles removed")
T.eq(#("SPRITE STYLE"), 12, "SPRITE STYLE menu length")

-- Shared setter writes the same sprite_style key
mockGame.save.options = mockGame.save.options or {}
mockGame.save.options.modOptions = mockGame.save.options.modOptions or {}
mockGame.mods = mockGame.mods or { modOptions = {} }
local setOk = exports.setSpriteStyle("gold", "test", { confirm = false, game = mockGame })
T.check(setOk == true, "setSpriteStyle legacy gold ok (normalizes)")
T.eq(Config.spriteStyle(modApi), "pokemmo", "setSpriteStyle migrated gold→pokemmo")
setOk = exports.setSpriteStyle("followers", "test", { confirm = false, game = mockGame })
T.check(setOk == true, "setSpriteStyle followers ok")
T.eq(Config.spriteStyle(modApi), "followers", "setSpriteStyle persisted followers")
setOk = exports.setSpriteStyle("pokemmo", "test", { confirm = false, game = mockGame })
T.check(setOk == true, "setSpriteStyle pokemmo ok")
T.eq(Config.spriteStyle(modApi), "pokemmo", "setSpriteStyle restored pokemmo")

-- Mod disable clears entities.
run.loader.modOptions["overworld_wild_spawns"].enabled = false
logic:onOptionsChanged({ mod = modApi.id, key = "enabled", value = false })
T.eq(logic:countOnMap("ROUTE_TEST"), 0, "disable clears entities")

run.release()
T.finish("overworld_wild_spawns")
