-- Standalone: from gen1recomp root
--   luajit mods/overworld-spawns/tests/overworld_spawns_test.lua
-- ROM-free: merges against tests/fixture_data via the modkit harness.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = T.fixtures.fresh()

local run = T.sdk.loadMod("mods/overworld-spawns", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")

local exports = run.loader.exports["overworld-spawns"]
T.check(exports ~= nil, "exports table published")
T.eq(exports.version, "1.0.0", "version export")
T.check(exports.logic ~= nil, "logic export")
T.check(exports.render ~= nil, "render export")
T.check(exports.lib ~= nil and type(exports.lib.require) == "function",
        "lib.require available")

-- Pure helpers work without a live overworld.
local EncounterPick = exports.lib.require("encounter_pick")
local Grass = exports.lib.require("grass")
local Config = exports.lib.require("config")

T.check(EncounterPick.hasGrassTable({
  grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } },
}), "detects a grass table")
T.check(not EncounterPick.hasGrassTable({ grass = { rate = 0, slots = {} } }),
        "rejects empty grass tables")
T.check(not EncounterPick.hasGrassTable(nil), "rejects nil encounter def")

local picks = {}
for _ = 1, 40 do
  local p = EncounterPick.pick({
    grass = {
      rate = 25,
      slots = {
        { species = "PIDGEY", level = 3 },
        { species = "RATTATA", level = 4 },
      },
      buckets = { 128, 256 },
    },
  }, function(a, b)
    if b == nil then return 1 end
    -- Force first bucket, then second, alternating deterministically.
    picks.n = (picks.n or 0) + 1
    if picks.n % 2 == 1 then return 10 end
    return 200
  end)
  T.check(p ~= nil and p.species ~= nil, "pick always returns a species")
  picks[p.species] = true
end
T.check(picks.PIDGEY and picks.RATTATA, "bucket picks cover both slots")

-- Grass scan against a tiny fake map.
local fakeMap = {
  widthCells = 4, heightCells = 3,
  isGrassCell = function(_, x, y)
    return (x == 1 and y == 1) or (x == 2 and y == 2)
  end,
}
local cells = Grass.cells(fakeMap)
T.eq(#cells, 2, "scans grass cells")
local gx, gy = Grass.pickFree(fakeMap, {}, { cellX = 0, cellY = 0 }, 1,
                              function(n) return 1 end)
T.check(gx ~= nil and gy ~= nil, "pickFree returns a cell")

T.eq(Config.DEFAULTS.max_spawns, 5, "default max_spawns")
T.check(Data.sprites.SPRITE_OW_SPAWN_PLACEHOLDER ~= nil,
        "placeholder sprite merged into data")

-- encounter.roll wrap suppresses grass when the option is on.
local Runtime = require("src.mods.Runtime")
local suppressed = Runtime.call("encounter.roll",
  function() return { species = "PIDGEY", level = 3 } end,
  { grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } } },
  { mapId = "ROUTE_1", terrain = "grass", rng = function() return 0 end })
T.eq(suppressed, nil, "grass rolls suppressed by default")

local water = Runtime.call("encounter.roll",
  function() return { species = "TENTACOOL", level = 5 } end,
  { grass = { rate = 25, slots = { { species = "TENTACOOL", level = 5 } } } },
  { mapId = "ROUTE_19", terrain = "water", rng = function() return 0 end })
T.check(water ~= nil and water.species == "TENTACOOL",
        "water rolls still pass through")

run.release()
T.finish("overworld_spawns")
