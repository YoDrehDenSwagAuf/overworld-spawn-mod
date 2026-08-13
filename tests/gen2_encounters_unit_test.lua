-- Gen2 encounter provider: kind-first Gold tables → Wilds-normalized candidates.
-- Fixtures match engine shape (data.gen2Encounters); they are not a Johto dump.
-- Run: lua tests/gen2_encounters_unit_test.lua
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

local engine = {
  version = "gold",
  generation = 2,
  isYellow = false,
}
package.loaded["src.core.GameVersion"] = {
  get = function() return engine.version end,
  isYellow = function() return engine.isYellow end,
  isGold = function() return engine.version == "gold" end,
  generation = function() return engine.generation end,
}

local modules = {}
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    content = { pokemon = { get = function() return nil end } },
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

local GameCompat = V.require("game_compat")
local Enc = V.require("gen2/encounters")
local Town = V.require("gen2/town_pokemon")

-- Shape copied from src/battle/gen2/Encounter.lua + Game2.lua (kind-first).
-- Slot species/levels are synthetic so the test does not invent ROM tables.
local ROUTE_29 = {
  rates = { MORN = 25, DAY = 25, NITE = 25 },
  slots = {
    MORN = {
      { species = "PIDGEY",   level = 2 },
      { species = "RATTATA",  level = 2 },
      { species = "SENTRET",  level = 3 },
      { species = "PIDGEY",   level = 3 },
      { species = "RATTATA",  level = 3 },
      { species = "PIDGEY",   level = 4 },
      { species = "SENTRET",  level = 4 },
    },
    DAY = {
      { species = "PIDGEY",   level = 2 },
      { species = "RATTATA",  level = 2 },
      { species = "SENTRET",  level = 3 },
      { species = "PIDGEY",   level = 3 },
      { species = "RATTATA",  level = 3 },
      { species = "PIDGEY",   level = 4 },
      { species = "SENTRET",  level = 4 },
    },
    NITE = {
      { species = "HOOTHOOT", level = 2 },
      { species = "RATTATA",  level = 2 },
      { species = "HOOTHOOT", level = 3 },
      { species = "RATTATA",  level = 3 },
      { species = "HOOTHOOT", level = 4 },
      { species = "RATTATA",  level = 4 },
      { species = "HOOTHOOT", level = 4 },
    },
  },
}

local ROUTE_30_WATER = {
  rate = 10,
  slots = {
    { species = "POLIWAG",   level = 15 },
    { species = "POLIWHIRL", level = 20 },
    { species = "POLIWAG",   level = 15 },
  },
}

local function goldGame(daytime)
  return {
    version = { id = "gold", name = "Pokémon Gold" },
    world = { daytime = daytime or "DAY" },
    data = {
      gen2Encounters = {
        grass = { ROUTE_29 = ROUTE_29 },
        water = { ROUTE_30 = ROUTE_30_WATER },
        fishing = {
          ROUTE_30 = { { species = "MAGIKARP", level = 10 } },
        },
      },
    },
  }
end

local alwaysFirst = function() return 0 end

----------------------------------------------------------------
-- Kind-first Gold tables, not Gen1 map-first
----------------------------------------------------------------
do
  local game = goldGame("DAY")
  game.data.encounters = {
    ROUTE_29 = {
      grass = { rate = 99, slots = { { species = "MEW", level = 99 } } },
    },
  }
  local enc = GameCompat.encountersForMap(game, "ROUTE_29")
  check(enc ~= nil, "Gold Route 29 has a normalized encDef")
  eq(enc.grass.rate, 25, "Route 29 grass rate from Gold rates.DAY")
  eq(#enc.grass.slots, 7, "Route 29 has 7 grass slots")
  eq(enc.grass.slots[1].species, "PIDGEY", "DAY slot 1 is Pidgey")
  eq(enc.grass.slots[3].species, "SENTRET", "DAY slot 3 is Sentret")
  eq(enc.grass.slots[3].level, 3, "Sentret keeps source level 3")
  eq(enc._source, "gen2Encounters", "source tag is gen2Encounters")
  local sawMew = false
  for _, slot in ipairs(enc.grass.slots) do
    if slot.species == "MEW" then sawMew = true end
  end
  check(not sawMew, "Gen1 map-first MEW table is ignored on Gold")
end

do
  local day = Enc.forMap(goldGame("DAY"), "ROUTE_29")
  local nite = Enc.forMap(goldGame("NITE"), "ROUTE_29")
  local morn = Enc.forMap(goldGame("MORN"), "ROUTE_29")
  local dark = Enc.forMap(goldGame("DARK"), "ROUTE_29")
  eq(day.grass.slots[1].species, "PIDGEY", "DAY group starts with Pidgey")
  eq(nite.grass.slots[1].species, "HOOTHOOT", "NITE group starts with Hoothoot")
  eq(morn.grass.timeOfDay, "MORN", "MORN key preserved")
  eq(dark.grass.slots[1].species, "HOOTHOOT", "DARK reuses NITE")
  eq(nite.grass.slots[1].level, 2, "Hoothoot source level 2")
end

do
  local game = goldGame("DAY")
  game.world.timeOfDay = function() return "NITE" end
  game.world.daytime = "DAY"
  -- Field daytime wins when present (matches live World.daytime).
  local enc = Enc.forMap(game, "ROUTE_29")
  eq(enc.grass.slots[1].species, "PIDGEY", "world.daytime field is authoritative")
end

do
  local game = goldGame("DAY")
  game.world.daytime = nil
  game.world.timeOfDay = function() return "NITE" end
  local enc = Enc.forMap(game, "ROUTE_29")
  eq(enc.grass.slots[1].species, "HOOTHOOT", "timeOfDay() used when daytime unset")
end

do
  local game = goldGame("DAY")
  local slot = Enc.pick(game, "ROUTE_29", "grass", { random = alwaysFirst })
  check(slot ~= nil, "grass pick returns a slot")
  eq(slot.species, "PIDGEY", "first grass slot via 0-roll")
  eq(slot.level, 2, "first grass slot keeps level 2")
  local land = Enc.pick(game, "ROUTE_29", "land", { random = alwaysFirst })
  eq(land.species, "PIDGEY", "land kind aliases grass")
end

do
  local game = goldGame("DAY")
  local enc = Enc.forMap(game, "ROUTE_30")
  check(enc.water ~= nil, "Route 30 water table present")
  eq(enc.water.rate, 10, "water rate preserved")
  eq(enc.water.slots[1].species, "POLIWAG", "water slot 1 Poliwag")
  eq(enc.water.slots[1].level, 15, "water slot 1 level 15")
  local slot = Enc.pick(game, "ROUTE_30", "water", { random = alwaysFirst })
  eq(slot.species, "POLIWAG", "water pick first slot")
  eq(slot.level, 15, "water pick keeps source level")
end

do
  local game = goldGame("DAY")
  check(Enc.forMap(game, "NEW_BARK_TOWN") == nil, "town with no encounters → nil")
  check(Enc.pick(game, "NEW_BARK_TOWN", "grass", { random = alwaysFirst }) == nil,
        "empty map pick is nil")
end

do
  local game = goldGame("DAY")
  local enc = Enc.forMap(game, "ROUTE_30")
  check(enc.fishing == nil, "fishing is not a visible Wilds source")
  check(Enc.pick(game, "ROUTE_30", "fishing", { random = alwaysFirst }) == nil,
        "fishing pick is nil")
end

do
  local game = {
    version = { id = "gold" },
    world = { daytime = "DAY" },
    data = {
      encounters = {
        ROUTE_29 = {
          grass = { rate = 25, slots = { { species = "PIDGEY", level = 2 } } },
        },
      },
    },
  }
  check(Enc.forMap(game, "ROUTE_29") == nil,
        "Gen1 map-first table is rejected as Gold data")
end

do
  eq(Town.catalog and Town.CATALOG.NEW_BARK_TOWN.species or Town.speciesForMap("NEW_BARK_TOWN"),
     "SENTRET", "New Bark catalog species is Sentret")
  eq(Town.speciesForMap("NEW_BARK_TOWN"), "SENTRET", "speciesForMap New Bark")
  eq(Town.targetCount("NEW_BARK_TOWN"), 1, "New Bark count is 1")
  check(Town.forMap("CHERRYGROVE_CITY") == nil, "Cherrygrove not in first catalog")
  check(Town.forMap("ROUTE_29") == nil, "Route 29 is not a town catalog map")
end

----------------------------------------------------------------
-- Gen1 still uses map-first encounters, never Gold tables
----------------------------------------------------------------
do
  engine.version = "red"
  engine.generation = 1
  local game = {
    version = { id = "red" },
    data = {
      encounters = {
        ROUTE_1 = {
          grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } },
        },
      },
      gen2Encounters = {
        grass = { ROUTE_1 = ROUTE_29 },
      },
    },
  }
  local enc = GameCompat.encountersForMap(game, "ROUTE_1")
  eq(enc.grass.slots[1].species, "PIDGEY", "Gen1 Route 1 still Pidgey")
  eq(enc.grass.slots[1].level, 3, "Gen1 Route 1 level unchanged")
  eq(enc.grass.slots[3], nil, "Gen1 table is not the 7-slot Gold fixture")
  engine.version = "gold"
  engine.generation = 2
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll Gen2 encounter provider tests passed.")
