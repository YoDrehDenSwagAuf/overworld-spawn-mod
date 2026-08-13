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
eq(def.trueColor, true, "provider trueColor is kept (sprite_color is not a gate)")

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

-- ------- Gen2 town Pokémon: curated Johto catalog, no Kanto fallback
package.loaded["src.core.GameVersion"] = {
  get = function() return "gold" end,
  isYellow = function() return false end,
  isGold = function() return true end,
  generation = function() return 2 end,
}
local goldGame = {
  save = { pokedex = nil, pokedexReceived = false },
  data = {
    maps = {
      NEW_BARK_TOWN = { id = "NEW_BARK_TOWN", tileset = "OVERWORLD" },
      CHERRYGROVE_CITY = { id = "CHERRYGROVE_CITY", tileset = "OVERWORLD" },
      VIOLET_CITY = { id = "VIOLET_CITY", tileset = "OVERWORLD" },
      AZALEA_TOWN = { id = "AZALEA_TOWN", tileset = "OVERWORLD" },
      GOLDENROD_CITY = { id = "GOLDENROD_CITY", tileset = "OVERWORLD" },
      ECRUTEAK_CITY = { id = "ECRUTEAK_CITY", tileset = "OVERWORLD" },
      OLIVINE_CITY = { id = "OLIVINE_CITY", tileset = "OVERWORLD" },
      CIANWOOD_CITY = { id = "CIANWOOD_CITY", tileset = "OVERWORLD" },
      MAHOGANY_TOWN = { id = "MAHOGANY_TOWN", tileset = "OVERWORLD" },
      BLACKTHORN_CITY = { id = "BLACKTHORN_CITY", tileset = "OVERWORLD" },
      ROUTE_29 = { id = "ROUTE_29", tileset = "OVERWORLD" },
    },
    -- Gold sprites do not include Gen1 SPRITE_PIKACHU — that was the dead path.
    sprites = { SPRITE_GOLD = { id = "SPRITE_GOLD", image = "x.png", frames = 6 } },
    encounters = {
      PALLET_TOWN = { grass = { rate = 25, slots = { { species = "PIDGEY", level = 3 } } } },
    },
    gen2Encounters = {
      grass = {
        ROUTE_29 = { rates = { DAY = 25 }, slots = { DAY = { { species = "PIDGEY", level = 2 } } } },
      },
    },
    pokemon = {},
  },
}
check(AmbientPokemon.isEligibleMap(goldGame, "NEW_BARK_TOWN"), "New Bark is eligible")
check(AmbientPokemon.isEligibleMap(goldGame, "CHERRYGROVE_CITY"),
      "Cherrygrove is in the Johto catalog")
check(AmbientPokemon.isEligibleMap(goldGame, "GOLDENROD_CITY"), "Goldenrod is eligible")
check(not AmbientPokemon.isEligibleMap(goldGame, "ROUTE_29"),
      "Route 29 is wilds, not town Pokémon")
check(not AmbientPokemon.isEligibleMap(goldGame, "PALLET_TOWN"),
      "Gold does not use Kanto town maps")
eq(AmbientPokemon.targetCount(goldGame, "NEW_BARK_TOWN"), 1, "New Bark count 1")
check(AmbientPokemon.targetCount(goldGame, "CHERRYGROVE_CITY") >= 1,
      "Cherrygrove catalog count >= 1")
local pool = AmbientPokemon.speciesPool(goldGame, "NEW_BARK_TOWN")
eq(#pool, 1, "New Bark pool size 1")
eq(pool[1], "SENTRET", "New Bark curated Sentret")
local cherryPool = AmbientPokemon.speciesPool(goldGame, "CHERRYGROVE_CITY")
check(#cherryPool >= 1, "Cherrygrove pool is non-empty")
eq(cherryPool[1], "PIDGEY", "Cherrygrove curated Pidgey")
local routePool = AmbientPokemon.speciesPool(goldGame, "ROUTE_29")
eq(#routePool, 0, "no Kanto FALLBACK_POOL on Gold routes")
check(AmbientPokemon.isLegendary("LUGIA"), "Lugia blocked as legendary")
check(AmbientPokemon.isLegendary("HO_OH"), "Ho-Oh blocked as legendary")
check(AmbientPokemon.isLegendary("CELEBI"), "Celebi blocked as legendary")

-- Gold ambient consumes the catalog and builds a guest without SPRITE_PIKACHU.
local goldMap = {
  id = "NEW_BARK_TOWN",
  widthCells = 20, heightCells = 18,
  def = goldGame.data.maps.NEW_BARK_TOWN,
  inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 20 and y < 18 end,
  isWalkableCell = function() return true end,
  isWaterCell = function() return false end,
  warpAtCell = function() return nil end,
  isDoorCell = function() return false end,
  isCounterCell = function() return false end,
}
local goldOw = {
  player = { cellX = 2, cellY = 2 },
  entities = {},
  npcs = {},
  map = goldMap,
}
local goldAmbient = AmbientPokemon.new(V.mod, {})
local goldSpawned = goldAmbient:spawnForMap(goldGame, goldOw)
eq(goldSpawned, 1, "New Bark Sentret entity created without SPRITE_PIKACHU")
eq(goldAmbient:countActive(), 1, "one active Gold ambient")
local guest
for npc in pairs(goldAmbient.active) do guest = npc end
check(guest ~= nil, "Gold ambient guest exists")
eq(guest.ambientSpecies, "SENTRET", "guest species is Sentret")
eq(guest.wildsAmbientPokemon, true, "NPC-like ambient marker")
eq(guest.wildsAggressive, false, "town Pokémon is non-aggressive")
eq(guest.wildsBattleable, false, "town Pokémon is not battleable")
eq(guest.wildsEncounterEnabled, false, "not sourced from encounter tables")
eq(guest.overworldWildSpawn, false, "not a wild spawn")
check(guest.behaviorState == nil, "town Pokémon is not in the Wild Behavior pool")
check(guest._wildsGoldGuest == true, "Gold guest flag for rebuildPeople")
check(#goldOw.npcs == 1, "Gold ambient is on ow.npcs")
check(#goldOw.entities == 1, "Gold ambient is on ow.entities")

-- Empty Pokédex still appears (already spawned above with pokedex = nil).
check(goldGame.save.pokedex == nil, "fixture Pokédex is empty")
eq(goldSpawned, 1, "empty Pokédex still spawned New Bark Sentret")

-- Live overworld wiring: WorldAPI:overworld() is how Gold map.entered finds World.
V.mod.world = {
  game = goldGame,
  overworld = function() return goldOw end,
}

-- Map exit removes it.
goldAmbient:onMapExited({ mapId = "NEW_BARK_TOWN" })
eq(goldAmbient:countActive(), 0, "map exit removes Gold town Pokémon")
eq(#goldOw.npcs, 0, "npcs list cleared on exit")
eq(#goldOw.entities, 0, "entities list cleared on exit")

goldOw.npcs, goldOw.entities = {}, {}
goldOw.map = goldMap
goldAmbient.activeMapId = nil
goldAmbient:onMapEntered({ mapId = "NEW_BARK_TOWN" })
eq(goldAmbient:countActive(), 1, "onMapEntered via liveOverworld/overworld() spawns")
goldAmbient:onMapExited({ mapId = "NEW_BARK_TOWN" })
eq(goldAmbient:countActive(), 0, "onMapExited clears after live enter")
V.mod.world = { game = nil, overworld = function() return nil end }

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("ambient_pokemon_unit_test: all passed")
