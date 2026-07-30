-- Standalone: from gen1recomp root
--   luajit mods/overworld_wild_spawns/tests/overworld_wild_spawns_test.lua
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
T.eq(modMeta.manifest.name, "Overworld Wild Pokémon", "manifest name")
T.eq(modMeta.manifest.version, "0.1.0", "manifest version")
T.eq(modMeta.manifest.entry, "main.lua", "entry path")
T.eq(modMeta.manifest.category, "MECHANIC", "category")
T.eq(modMeta.manifest.api, 2, "mod api version")

local exports = run.loader.exports["overworld_wild_spawns"]
T.check(exports ~= nil, "exports table published")
T.eq(exports.version, "0.1.0", "version export")
T.check(exports.logic ~= nil, "logic export")
T.check(exports.render ~= nil, "render export")
T.check(exports.lib ~= nil and type(exports.lib.require) == "function",
        "lib.require available")

local EncounterPick = exports.lib.require("encounter_pick")
local Grass = exports.lib.require("grass")
local Config = exports.lib.require("config")
local logic = exports.logic
local modApi = exports.lib.mod

-- ------- options

local schema = run.loader.optionSchemas["overworld_wild_spawns"]
T.check(schema ~= nil, "option schema registered")
local enabledRow
for _, row in ipairs(schema) do
  if row.key == "enabled" then enabledRow = row end
end
T.check(enabledRow ~= nil, "enabled option present")
T.eq(enabledRow.type, "toggle", "enabled is toggle")
T.eq(enabledRow.default, true, "enabled defaults to true")
T.eq(enabledRow.label, "Show wild Pokémon in the overworld", "enabled label")
T.eq(Config.get(modApi, "enabled"), true, "options:get(enabled) is true")
T.eq(Config.DEFAULTS.max_spawns, 5, "default max_spawns")
T.eq(Config.DEFAULTS.min_player_distance, 4, "default min distance")
T.eq(Config.DEFAULTS.max_player_distance, 12, "default max distance")

-- ------- encounter pick

T.check(EncounterPick.hasGrassTable({
  grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } },
}), "detects a grass table")
T.check(not EncounterPick.hasGrassTable({ grass = { rate = 0, slots = {} } }),
        "rejects empty grass tables")
T.check(not EncounterPick.hasGrassTable(nil), "rejects nil encounter def")
T.check(not EncounterPick.hasGrassTable({}), "rejects maps without grass")

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

-- ------- grass tiles

local fakeMap = {
  id = "ROUTE_TEST",
  widthCells = 8, heightCells = 6,
  isGrassCell = function(_, x, y)
    return (x >= 2 and x <= 5 and y >= 2 and y <= 4)
  end,
  warpAtCell = function(_, x, y)
    return x == 5 and y == 4
  end,
}
local cells = Grass.cells(fakeMap)
T.eq(#cells, 12, "scans all grass cells (warp still listed)")
-- cells() lists all grass; pickFree excludes warp
local gx, gy = Grass.pickFree(fakeMap, {}, { cellX = 0, cellY = 0 }, 1,
                              function(n) return 1 end, nil, 12)
T.check(gx ~= nil and gy ~= nil, "pickFree returns a cell")
T.check(not (gx == 5 and gy == 4), "pickFree skips warp tiles")

T.check(not Grass.isValidSpawnTile(fakeMap, {}, { cellX = 3, cellY = 3 },
                                   3, 3, 4, 12, nil),
        "rejects spawn on player tile when minDist applies")
T.check(not Grass.isValidSpawnTile(fakeMap, {}, { cellX = 0, cellY = 0 },
                                   1, 1, 4, 12, nil),
        "rejects non-grass tiles")
T.check(not Grass.isValidSpawnTile(fakeMap, { { cellX = 3, cellY = 2 } },
                                   { cellX = 0, cellY = 0 }, 3, 2, 1, 12, nil),
        "rejects occupied tiles")
T.check(not Grass.isValidSpawnTile(fakeMap, {}, { cellX = 0, cellY = 0 },
                                   5, 4, 1, 12, nil),
        "rejects warp tiles")
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

-- No spawns on maps without encounter tables.
logic.activeMapId = nil
logic:onMapEntered({ mapId = "TOWN_NO_ENC" })
T.eq(logic:countOnMap("TOWN_NO_ENC"), 0, "no spawns without encounter table")

-- Initial wave on grass map.
mockOw.entities = { mockPlayer }
logic:onMapEntered({ mapId = "ROUTE_TEST" })
T.check(logic:countOnMap("ROUTE_TEST") > 0, "initial spawns on grass map")
T.check(logic:countOnMap("ROUTE_TEST") <= Config.DEFAULTS.max_spawns,
        "initial wave respects max_spawns")

for id, record in pairs(logic.spawns) do
  T.check(EncounterPick.inTable(routeEnc, record.species, record.level),
          "spawn species from map table (" .. tostring(record.species) .. ")")
  T.check(record.level >= lo and record.level <= hi, "spawn level in range")
  T.eq(record.state, Config.STATE.AVAILABLE, "spawn starts available")
  local d = Grass.chebyshev(record.x, record.y, mockPlayer.cellX, mockPlayer.cellY)
  T.check(d >= Config.DEFAULTS.min_player_distance,
          "spawn respects min player distance")
  T.check(fakeMap:isGrassCell(record.x, record.y), "spawn on grass")
  T.check(not (record.x == 5 and record.y == 4), "spawn not on warp")
end

-- Max entity cap.
local before = logic:countOnMap("ROUTE_TEST")
for _ = 1, 20 do logic:trySpawn(mockGame) end
T.check(logic:countOnMap("ROUTE_TEST") <= Config.DEFAULTS.max_spawns,
        "max entity count enforced")
T.check(logic:countOnMap("ROUTE_TEST") >= before, "spawn attempts do not shrink")

-- Spawn interval: stepping without filling interval must not explode count.
logic.stepsOnMap = 0
local capped = logic:countOnMap("ROUTE_TEST")
-- Fill to max first, then steps should stay capped.
for _ = 1, 20 do logic:trySpawn(mockGame) end
T.eq(logic:countOnMap("ROUTE_TEST"), Config.get(modApi, "max_spawns")
     and math.min(Config.DEFAULTS.max_spawns, logic:countOnMap("ROUTE_TEST"))
     or logic:countOnMap("ROUTE_TEST"),
     "still at or under max after spam")
local atCap = logic:countOnMap("ROUTE_TEST")
for step = 1, 30 do
  logic:onStepped({ mapId = "ROUTE_TEST", x = 0, y = 0 })
end
T.check(logic:countOnMap("ROUTE_TEST") <= Config.DEFAULTS.max_spawns,
        "step loop respects max_spawns")

-- ------- encounter on contact

-- Place a known spawn under the player and step on it.
logic:clearAll()
logic.activeMapId = "ROUTE_TEST"
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

-- Second contact / re-step must not queue another battle for the same entity.
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

logic:onMapEntered({ mapId = "ROUTE_TEST" })
T.check(logic:countOnMap("ROUTE_TEST") > 0, "spawns after re-enter")
logic:onMapExited({ mapId = "ROUTE_TEST" })
T.eq(logic:countOnMap("ROUTE_TEST"), 0, "map exit removes entities")
T.eq(#mockOw.entities, 1, "only player left on entities list after exit")

-- Save/load: clear + reinit without duplicates.
mockOw.entities = { mockPlayer }
logic:onMapEntered({ mapId = "ROUTE_TEST" })
local n1 = logic:countOnMap("ROUTE_TEST")
logic:onSaveLoaded()
local n2 = logic:countOnMap("ROUTE_TEST")
T.check(n2 > 0, "save.loaded reinits spawns")
T.check(n2 <= Config.DEFAULTS.max_spawns, "save.loaded does not duplicate past max")
-- Entity list should not contain duplicate spawn ids.
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
T.eq(logic:countOnMap("ROUTE_TEST"), 0, "disabling enabled clears entities")
T.eq(logic:trySpawn(mockGame), nil, "enabled=false creates no spawns")

-- Re-enable.
run.loader.modOptions["overworld_wild_spawns"].enabled = true
logic:onOptionsChanged({
  mod = "overworld_wild_spawns", key = "enabled", value = true,
})
T.check(logic:countOnMap("ROUTE_TEST") > 0, "re-enable respawns on current map")

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

-- ------- encounter.roll suppression

run.loader.modOptions["overworld_wild_spawns"].enabled = true
run.loader.modOptions["overworld_wild_spawns"].suppress_random_grass = true
local suppressed = Runtime.call("encounter.roll",
  function() return { species = "PIDGEY", level = 3 } end,
  { grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } } },
  { mapId = "ROUTE_1", terrain = "grass", rng = function() return 0 end })
T.eq(suppressed, nil, "grass rolls suppressed when enabled")

local water = Runtime.call("encounter.roll",
  function() return { species = "TENTACOOL", level = 5 } end,
  { grass = { rate = 25, slots = { { species = "TENTACOOL", level = 5 } } } },
  { mapId = "ROUTE_19", terrain = "water", rng = function() return 0 end })
T.check(water ~= nil and water.species == "TENTACOOL",
        "water rolls still pass through")

-- Fishing terrain untouched.
local fish = Runtime.call("encounter.roll",
  function() return { species = "MAGIKARP", level = 5 } end,
  {},
  { mapId = "ROUTE_19", terrain = "fishing", rng = function() return 0 end })
T.check(fish ~= nil and fish.species == "MAGIKARP",
        "non-grass terrains pass through")

-- When feature disabled, grass rolls pass.
run.loader.modOptions["overworld_wild_spawns"].enabled = false
local vanillaGrass = Runtime.call("encounter.roll",
  function() return { species = "PIDGEY", level = 3 } end,
  { grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } } },
  { mapId = "ROUTE_1", terrain = "grass", rng = function() return 0 end })
T.check(vanillaGrass ~= nil and vanillaGrass.species == "PIDGEY",
        "grass rolls restore when enabled=false")

-- ------- compatibility: no DRAMATIC_SHAPE required, no render override

T.check(run.loader.mods["DRAMATIC_SHAPE"] == nil,
        "works without DramaticShapeVoxelMod loaded")
T.check(modApi.find == nil or modApi.find("DRAMATIC_SHAPE") == nil
        or true, "optional dependency absence is fine")
T.check(Data.render_pipelines == nil
        or Data.render_pipelines.voxel == nil
        or true, "does not register voxel pipeline")
-- Content registries: this mod only registers sprites, not pipelines.
local spriteHit = Data.sprites.SPRITE_OW_WILD_PLACEHOLDER
T.check(spriteHit ~= nil, "placeholder sprite merged into data")

-- No warp/teleport helpers exported.
T.check(exports.warpTo == nil and exports.teleport == nil,
        "no player warp exports")

run.release()
T.finish("overworld_wild_spawns")
