-- Ambient / Town Pokémon unit tests (ROM-free).
-- Run: lua tests/ambient_pokemon_unit_test.lua
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

local optionStore = { town_pokemon = true, sprite_style = "followers", sprite_color = "colored" }
local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    options = {
      get = function(_, k) return optionStore[k] end,
      set = function(_, k, v) optionStore[k] = v end,
    },
    world = { game = nil, overworld = function() return nil end },
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
modules.debug_log = { warn = function() end, info = function() end, error = function() end }

local Config = V.require("config")
modules.config = Config
local AmbientCries = V.require("ambient_cries")
local AmbientPokemon = V.require("ambient_pokemon")

-- ------- Cries
eq(AmbientCries.FALLBACK, "[...]", "fallback cry exactly [...]")
eq(AmbientCries.textFor("PIKACHU"), "Pikaa...", "curated Pikachu")
eq(AmbientCries.textFor("EEVEE"), "Vee...", "curated Eevee")
eq(AmbientCries.textFor("RATTATA"), "[...]", "uncurated → [...]")
eq(AmbientCries.textFor(nil), "[...]", "nil → [...]")
eq(AmbientCries.textFor(""), "[...]", "empty → [...]")
check(AmbientCries.curatedCount() >= 8, "curated cry table has several species")
check(AmbientCries.curatedCount() < 40, "not 151 invented cries")
check(not AmbientCries.textFor("UNKNOWN"):find("%.%.%.$", 1, false)
        or AmbientCries.textFor("UNKNOWN") == "[...]",
      "unknown uses bracket fallback")
eq(AmbientCries.textFor("MEWTWO"), "[...]", "legendary fallback [...]")

-- ------- Map classification
local game = {
  data = {
    maps = {
      PALLET_TOWN = { id = "PALLET_TOWN", tileset = "OVERWORLD", label = "PALLET TOWN" },
      VIRIDIAN_CITY = { id = "VIRIDIAN_CITY", tileset = "OVERWORLD" },
      VIRIDIAN_POKECENTER = { id = "VIRIDIAN_POKECENTER", tileset = "POKECENTER" },
      PALLET_TOWN_REDS_HOUSE_1F = { id = "PALLET_TOWN_REDS_HOUSE_1F", tileset = "HOUSE" },
      VIRIDIAN_MART = { id = "VIRIDIAN_MART", tileset = "MART" },
      PALLET_TOWN_OAKS_LAB = { id = "PALLET_TOWN_OAKS_LAB", tileset = "LAB" },
      ROUTE_1_GATE = { id = "ROUTE_1_GATE", tileset = "GATE" },
      MT_MOON_1F = { id = "MT_MOON_1F", tileset = "CAVERN" },
      ROUTE_1 = { id = "ROUTE_1", tileset = "OVERWORLD" },
      SAFARI_ZONE_CENTER = { id = "SAFARI_ZONE_CENTER", tileset = "FOREST" },
      POWER_PLANT = { id = "POWER_PLANT", tileset = "FACILITY" },
      ROCKET_HIDEOUT_B1F = { id = "ROCKET_HIDEOUT_B1F", tileset = "FACILITY" },
      POKEMON_TOWER_1F = { id = "POKEMON_TOWER_1F", tileset = "CEMETERY" },
      VICTORY_ROAD_1F = { id = "VICTORY_ROAD_1F", tileset = "CAVERN" },
      SILPH_CO_1F = { id = "SILPH_CO_1F", tileset = "FACILITY" },
    },
    encounters = {},
    pokemon = {},
    sprites = { SPRITE_PIKACHU = { id = "SPRITE_PIKACHU", image = "x.png", frames = 6 } },
  },
}

eq(AmbientPokemon.classifyMap(game, "PALLET_TOWN"), "town", "Pallet is town")
eq(AmbientPokemon.classifyMap(game, "VIRIDIAN_CITY"), "town", "Viridian is town")
eq(AmbientPokemon.classifyMap(game, "VIRIDIAN_POKECENTER"), "pokecenter", "center")
eq(AmbientPokemon.classifyMap(game, "PALLET_TOWN_REDS_HOUSE_1F"), "house", "house")
eq(AmbientPokemon.classifyMap(game, "VIRIDIAN_MART"), "mart", "mart")
eq(AmbientPokemon.classifyMap(game, "PALLET_TOWN_OAKS_LAB"), "lab", "lab")
eq(AmbientPokemon.classifyMap(game, "ROUTE_1_GATE"), "gate", "gate")
check(AmbientPokemon.classifyMap(game, "MT_MOON_1F") == nil, "no ambient in cave")
check(AmbientPokemon.classifyMap(game, "ROUTE_1") == nil, "no ambient on route")
check(AmbientPokemon.classifyMap(game, "SAFARI_ZONE_CENTER") == nil, "no ambient Safari")
check(AmbientPokemon.classifyMap(game, "POWER_PLANT") == nil, "no ambient Power Plant")
check(AmbientPokemon.classifyMap(game, "ROCKET_HIDEOUT_B1F") == nil, "no ambient Rocket")
check(AmbientPokemon.classifyMap(game, "POKEMON_TOWER_1F") == nil, "no ambient Tower")
check(AmbientPokemon.classifyMap(game, "VICTORY_ROAD_1F") == nil, "no ambient Victory Road")
check(AmbientPokemon.classifyMap(game, "SILPH_CO_1F") == nil, "no ambient Silph")

-- ------- Safe cells
local map = {
  id = "PALLET_TOWN",
  widthCells = 20, heightCells = 18,
  def = game.data.maps.PALLET_TOWN,
  inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 20 and y < 18 end,
  isWalkableCell = function(_, x, y) return true end,
  isWaterCell = function() return false end,
  warpAtCell = function(_, x, y) return x == 5 and y == 5 end,
  isDoorCell = function(_, x, y) return x == 6 and y == 6 end,
  isCounterCell = function() return false end,
}
local ow = {
  player = { cellX = 2, cellY = 2 },
  entities = { { cellX = 3, cellY = 3 } },
  npcs = {},
  map = map,
}
check(not AmbientPokemon.isSafeSpawnCell(ow, map, 5, 5), "safe cell rejects warp")
check(not AmbientPokemon.isSafeSpawnCell(ow, map, 6, 6), "safe cell rejects door")
check(not AmbientPokemon.isSafeSpawnCell(ow, map, 3, 3), "safe cell rejects occupied")
check(not AmbientPokemon.isSafeSpawnCell(ow, map, 2, 2), "safe cell rejects player")
-- Cell next to warp rejected (doorway)
check(not AmbientPokemon.isSafeSpawnCell(ow, map, 5, 4), "rejects adjacent to warp")
check(AmbientPokemon.isSafeSpawnCell(ow, map, 10, 10), "accepts free walkable cell")

-- ------- Entity markers / battle guards
local ambient = AmbientPokemon.new(V.mod, {})
local fake = {}
ambient:_markAmbient(fake, "PIKACHU", "IDLE")
eq(fake.wildsAmbientPokemon, true, "ambient marker")
eq(fake.wildsBattleable, false, "battleable false")
eq(fake.wildsAggressive, false, "aggressive false")
eq(fake.wildsEncounterEnabled, false, "encounter false")
eq(fake.overworldWildSpawn, false, "not wild spawn")
check(Config.isBattleableWild(fake) == false, "isBattleableWild false for ambient")

-- ------- Toggle clear / density defaults
eq(Config.townPokemonEnabled(V.mod), true, "town_pokemon default on")
optionStore.town_pokemon = false
eq(Config.townPokemonEnabled(V.mod), false, "town toggle off")

local dens = AmbientPokemon.DENSITY
check(dens.pokecenter.min == 1 and dens.pokecenter.max == 2, "center density 1–2")
check(dens.house.min == 0 and dens.house.max == 1, "house density 0–1")
check(dens.mart.min == 0 and dens.mart.max == 1, "mart density 0–1")
check(dens.lab.min == 1 and dens.lab.max == 3, "lab density 1–3")
check(dens.town.min == 1 and dens.town.max == 3, "town density 1–3")
check(dens.gate.min == 0 and dens.gate.max == 1, "gate density 0–1")

-- ------- Species pool excludes legendaries
for _, sp in ipairs(AmbientPokemon.FALLBACK_POOL) do
  check(not AmbientPokemon.isLegendary(sp), "fallback not legendary: " .. sp)
end
check(AmbientPokemon.isLegendary("MEWTWO"), "Mewtwo blocked")
check(AmbientPokemon.isLegendary("MEW"), "Mew blocked")

-- ------- Dev overlay labels
local l1, l2 = AmbientPokemon.devLabel(fake)
eq(l1, "AMBIENT", "dev label AMBIENT")
eq(l2, "IDLE", "dev label IDLE")
fake.ambientBehavior = "WANDER"
l1, l2 = AmbientPokemon.devLabel(fake)
eq(l2, "WANDER", "dev label WANDER")

-- ------- Style resolver uses selected style (cache key)
local calls = {}
ambient.render = {
  spriteProviders = {
    resolve = function(_, style, species)
      calls[#calls + 1] = { style = style, species = species }
      return {
        def = { image = "img/" .. species .. ".png", frames = 6, walker = true, trueColor = true },
        providerId = "followers_ex",
      }
    end,
  },
}
optionStore.sprite_style = "pokemmo"
local def = ambient:_resolveSprite("EEVEE", game)
check(def ~= nil, "resolved ambient sprite")
eq(calls[1].style, "pokemmo", "ambient style resolver uses selected style")
eq(def.trueColor, true, "colored trueColor on ambient def")
optionStore.sprite_color = "classic"
ambient._spriteCache = {}
def = ambient:_resolveSprite("EEVEE", game)
eq(def.trueColor, false, "classic forces trueColor false")

-- Refresh sprites path
ambient.active[fake] = true
fake.ambientSpecies = "EEVEE"
fake.id = "ambient_test"
-- Without SpriteRenderer module, bind returns false — still safe.
local n = ambient:refreshSprites(game)
check(type(n) == "number", "refreshSprites returns count")

-- Toggle off clears
ambient.active[fake] = true
ambient:onTownPokemonToggled(false, game)
eq(ambient:countActive(), 0, "town toggle removes ambient entities")

-- Hostile map spawn count 0
ow.map.id = "MT_MOON_1F"
ow.map.def = game.data.maps.MT_MOON_1F
optionStore.town_pokemon = true
local spawned = ambient:spawnForMap(game, ow)
eq(spawned, 0, "no ambient spawn on hostile map")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("ambient_pokemon_unit_test: all passed")
