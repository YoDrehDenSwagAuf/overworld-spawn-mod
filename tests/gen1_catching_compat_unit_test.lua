-- Gen1 GameCompat catch adapter preserves the previous OW catching semantics.
-- Run: lua tests/gen1_catching_compat_unit_test.lua
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

package.loaded["src.core.GameVersion"] = {
  get = function() return "red" end,
  isYellow = function() return false end,
  generation = function() return 1 end,
}

local pokemonNewCalls = {}
package.preload["src.inventory.Bag"] = function()
  return {
    remove = function(save, id, qty)
      local n = (save.inventory[id] or 0) - (qty or 1)
      if n <= 0 then save.inventory[id] = nil else save.inventory[id] = n end
    end,
  }
end
package.preload["src.battle.Catching"] = function()
  local M = { last = nil }
  function M.attempt(ball, mon, def, rng, rateOverride)
    M.last = {
      ball = ball, mon = mon, def = def, rateOverride = rateOverride,
    }
    if ball == "MASTER_BALL" then return true, 3 end
    if M._force == "catch" then return true, 3 end
    if M._force == "fail" then return false, 2 end
    local rate = rateOverride or (def and def.catchRate) or 255
    local r = (rng or math.random)(0, 255)
    return r <= rate, 2
  end
  return M
end
package.preload["src.pokemon.Pokemon"] = function()
  return {
    new = function(data, species, level)
      pokemonNewCalls[#pokemonNewCalls + 1] = { species = species, level = level }
      return {
        species = species, level = level, hp = 20, stats = { hp = 20 },
        _fromPokemonNew = true,
      }
    end,
  }
end
package.preload["src.pokemon.Party"] = function()
  return {
    MAX = 6,
    add = function(party, mon)
      if #party >= 6 then return false end
      table.insert(party, mon)
      return true
    end,
  }
end
package.preload["src.pokemon.Boxes"] = function()
  return {
    deposit = function(save, mon)
      save.boxes = save.boxes or { {} }
      for i = 1, 12 do
        save.boxes[i] = save.boxes[i] or {}
        if #save.boxes[i] < 20 then
          table.insert(save.boxes[i], mon)
          return i
        end
      end
      return nil
    end,
  }
end

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
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
local CatchingApi = require("src.battle.Catching")

local game = {
  generation = 1,
  version = "red",
  save = {
    inventory = { POKE_BALL = 5, GREAT_BALL = 2, ULTRA_BALL = 0, MASTER_BALL = 1 },
    party = {},
    boxes = { {} },
    pokedex = { seen = {}, owned = {} },
    player = { name = "RED", id = 1234 },
  },
  data = {
    pokemon = {
      PIDGEY = { name = "PIDGEY", catchRate = 255 },
      MEWTWO = { name = "MEWTWO", catchRate = 3, dex = 248 },
    },
  },
}

eq(GameCompat.supportsFeature("catching", nil, game), true, "Red catching on")
eq(GameCompat.ballCount(game, "POKE_BALL"), 5, "Gen1 ballCount reads inventory")
eq(GameCompat.ballCount(game, "ULTRA_BALL"), 0, "Gen1 zero ball count")
eq(GameCompat.ballCount(game, "MISSING"), 0, "Gen1 missing ball is 0")

check(GameCompat.consumeBall(game, "POKE_BALL") == true, "Gen1 consume ok")
eq(GameCompat.ballCount(game, "POKE_BALL"), 4, "Gen1 consume subtracts one")
check(GameCompat.consumeBall(game, "ULTRA_BALL") == false, "Gen1 zero cannot consume")
eq(game.save.inventory.ULTRA_BALL, 0, "Gen1 zero consume leaves count unchanged")

local rate, def = GameCompat.catchRate(game, "PIDGEY")
eq(rate, 255, "Gen1 PIDGEY catchRate")
eq(def.name, "PIDGEY", "Gen1 catchRate returns def")

CatchingApi._force = "fail"
local caught, shakes = GameCompat.attemptCatch(game, {
  ballType = "POKE_BALL",
  mon = { species = "PIDGEY", hp = 20, stats = { hp = 20 } },
  def = def,
  rng = function() return 255 end,
  rateOverride = 40,
  species = "PIDGEY",
})
eq(caught, false, "Gen1 forced fail")
eq(CatchingApi.last.ball, "POKE_BALL", "Gen1 attempt uses ball type")
eq(CatchingApi.last.rateOverride, 40, "Gen1 passes Wilds rateOverride through")
eq(CatchingApi.last.mon.species, "PIDGEY", "Gen1 attempt mon species is entity id")

CatchingApi._force = nil
caught, shakes = GameCompat.attemptCatch(game, {
  ballType = "MASTER_BALL",
  mon = { species = "MEWTWO", hp = 20, stats = { hp = 20 } },
  def = { catchRate = 3, name = "MEWTWO" },
  rng = function() return 255 end,
  rateOverride = 1,
  species = "MEWTWO",
})
eq(caught, true, "Gen1 Master Ball still guaranteed")
eq(shakes, 3, "Gen1 Master Ball 3 shakes")

pokemonNewCalls = {}
local mon = GameCompat.createCaughtPokemon(game, "MEWTWO", 70, { shiny = true })
eq(mon.species, "MEWTWO", "Gen1 create uses entity species MEWTWO")
eq(mon.level, 70, "Gen1 create uses entity level")
eq(mon.shiny, true, "Gen1 create preserves shiny")
eq(mon._fromPokemonNew, true, "Gen1 create uses Pokemon.new")
eq(pokemonNewCalls[1].species, "MEWTWO", "Pokemon.new species is MEWTWO not asset 150")
check(mon.species ~= 150 and mon.species ~= "150", "canonical asset id did not leak")

eq(GameCompat.playerHasPartySpace(game), true, "empty party has space")
local given = GameCompat.giveCaughtPokemon(game, mon)
eq(given.destination, "party", "Gen1 party insert")
eq(#game.save.party, 1, "party count 1")
eq(game.save.party[1].species, "MEWTWO", "party mon is MEWTWO")

GameCompat.markSpeciesCaught(game, "MEWTWO", mon)
eq(game.save.pokedex.owned.MEWTWO, true, "Gen1 owned stamp")
eq(game.save.pokedex.seen.MEWTWO, true, "Gen1 seen stamp")
check(game.save.pokedex.owned[150] == nil, "Gen1 dex is not keyed by asset 150")

for i = 2, 6 do
  GameCompat.giveCaughtPokemon(game, { species = "PIDGEY", level = i })
end
eq(#game.save.party, 6, "party filled to 6")
eq(GameCompat.playerHasPartySpace(game), false, "full party has no space")

local boxed = GameCompat.createCaughtPokemon(game, "PIDGEY", 4)
local boxResult = GameCompat.giveCaughtPokemon(game, boxed)
eq(boxResult.destination, "box", "Gen1 party-full goes to Boxes.deposit")
eq(boxResult.boxNum, 1, "Gen1 deposit box number")
eq(game.save.boxes[1][#game.save.boxes[1]].species, "PIDGEY", "boxed species is PIDGEY")

eq(GameCompat.specialCatchSessionBlocks(game, {}), false, "Gen1 has no extra session block")
eq(GameCompat.captureSpecies({ species = "MEWTWO" }, { species = "MEWTWO" }),
   "MEWTWO", "captureSpecies prefers record/entity species")
eq(GameCompat.captureSpecies({ species = "MEWTWO", assetId = 150 }, nil),
   "MEWTWO", "captureSpecies ignores assetId field")

local src = assert(io.open("lib/catching/init.lua", "r")):read("*a")
check(not src:find("generation == 2", 1, true), "catching/init has no generation == 2")
check(not src:find('if Gold', 1, true), "catching/init has no Gold branch")
check(src:find("GameCompat.ballCount", 1, true), "catching asks compat.ballCount")
check(src:find("GameCompat.consumeBall", 1, true), "catching asks compat.consumeBall")
check(src:find("GameCompat.giveCaughtPokemon", 1, true), "catching asks compat.giveCaughtPokemon")
check(src:find("GameCompat.createCaughtPokemon", 1, true),
      "catching asks compat.createCaughtPokemon")
check(not src:find("src.pokemon.Pokemon", 1, true),
      "catching/init no longer constructs Gen1 Pokemon directly")
check(not src:find("src.inventory.Bag", 1, true),
      "catching/init no longer touches Bag directly")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("gen1_catching_compat_unit_test: all passed")
