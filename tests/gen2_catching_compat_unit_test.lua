-- Gold GameCompat catch adapter: inventory, Mon, party/box, dex, species identity.
-- Run: lua tests/gen2_catching_compat_unit_test.lua
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
  get = function() return "gold" end,
  isYellow = function() return false end,
  isGold = function() return true end,
  generation = function() return 2 end,
}

local monNewCalls = {}
local unownCalls = {}
package.preload["src.inventory.Bag"] = function()
  return {
    remove = function(save, id, qty)
      local n = (save.inventory[id] or 0) - (qty or 1)
      if n <= 0 then save.inventory[id] = nil else save.inventory[id] = n end
    end,
  }
end
package.preload["src.battle.gen2.Mon"] = function()
  return {
    new = function(data, species, level, opts)
      monNewCalls[#monNewCalls + 1] = {
        species = species, level = level, opts = opts,
      }
      if not (data and data.pokemon and data.pokemon[species]) then
        return nil
      end
      local def = data.pokemon[species]
      return {
        species = species,
        name = def.name or species,
        level = level,
        experience = (level or 1) * (level or 1) * (level or 1),
        dvs = { attack = 8, defense = 8, speed = 8, special = 8, hp = 8 },
        statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
        stats = {
          hp = 22, attack = 12, defense = 11, speed = 13,
          specialAttack = 10, specialDefense = 10,
        },
        hp = 22,
        maxHp = 22,
        moves = { { id = "TACKLE", pp = 35, maxPp = 35 } },
        happiness = 70,
        status = nil,
        _fromMonNew = true,
      }
    end,
    stampOT = function(save, mon)
      mon.ot = save.player and save.player.name or "GOLD"
      mon.otName = mon.ot
      mon.otId = save.player and save.player.id or 1
      return mon
    end,
  }
end
package.preload["src.core.gen2.Boxes"] = function()
  return {
    NUM_BOXES = 14,
    MONS_PER_BOX = 20,
    PARTY_SIZE = 6,
    box = function(save, index)
      save.boxes = save.boxes or {}
      save.boxes[index] = save.boxes[index] or {}
      return save.boxes[index]
    end,
    isFull = function(save, index)
      local box = save.boxes and save.boxes[index]
      return box ~= nil and #box >= 20
    end,
  }
end
package.preload["src.battle.gen2.Catching"] = function()
  local M = { last = nil, _force = nil }
  function M.attempt(opts)
    M.last = opts
    if opts.ball == "MASTER_BALL" then return true, 255 end
    if M._force == "catch" then return true, 180 end
    if M._force == "fail" then return false, 40 end
    return false, 40
  end
  return M
end
package.preload["src.core.gen2.Unown"] = function()
  return {
    registerCatch = function(save, mon)
      unownCalls[#unownCalls + 1] = mon and mon.species
      return true
    end,
  }
end
package.preload["src.core.gen2.BugContest"] = function()
  return {
    isActive = function(save)
      return save and save.bugContest and save.bugContest.active == true
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
local SpeciesAssets = V.require("species_assets")
local GoldCatching = require("src.battle.gen2.Catching")

local game = {
  generation = 2,
  version = "gold",
  save = {
    inventory = { POKE_BALL = 7, GREAT_BALL = 1, ULTRA_BALL = 3, MASTER_BALL = 1 },
    party = { { species = "CHIKORITA", level = 5 } },
    boxes = {},
    currentBox = 1,
    pokedex = { seen = {}, caught = {} },
    player = { name = "GOLD", id = 4321 },
  },
  data = {
    pokemon = {
      SENTRET = { name = "SENTRET", catchRate = 255, dex = 161, index = 161 },
      MEWTWO = { name = "MEWTWO", catchRate = 3, dex = 248, index = 248 },
      TYRANITAR = { name = "TYRANITAR", catchRate = 45, dex = 150, index = 150 },
      FAKEMON = { name = "FAKEMON", catchRate = 90, dex = 999, index = 999 },
      PIDGEY = { name = "PIDGEY", catchRate = 255, dex = 16, index = 16 },
    },
  },
}

eq(GameCompat.supportsFeature("catching", nil, game), true, "Gold catching capability")
eq(GameCompat.supportsFeature("safari", nil, game), false, "Gold safari stays off")
eq(GameCompat.Gen2.capabilities.catching, true, "Gen2.capabilities.catching")

----------------------------------------------------------------
-- A/B. HUD counts + consume one ball
----------------------------------------------------------------
eq(GameCompat.ballCount(game, "POKE_BALL"), 7, "A. Poké Ball count from Gold inventory")
eq(GameCompat.ballCount(game, "GREAT_BALL"), 1, "Great Ball count")
eq(GameCompat.ballCount(game, "MASTER_BALL"), 1, "Master Ball count")
check(GameCompat.consumeBall(game, "POKE_BALL") == true, "C. consume Poké Ball")
eq(GameCompat.ballCount(game, "POKE_BALL"), 6, "consume subtracts exactly one")
check(GameCompat.consumeBall(game, "LURE_BALL") == false, "unknown/zero ball cannot throw")
eq(game.save.inventory.LURE_BALL, nil, "missing ball does not corrupt inventory")

game.save.inventory.POKE_BALL = 0
check(GameCompat.consumeBall(game, "POKE_BALL") == false, "zero balls cannot throw")
eq(GameCompat.ballCount(game, "POKE_BALL"), 0, "zero consume does not change count")
game.save.inventory.POKE_BALL = 6

----------------------------------------------------------------
-- Catch math: native Gold attempt, Wilds rateOverride as species rate
----------------------------------------------------------------
GoldCatching._force = "fail"
local caught, shakes = GameCompat.attemptCatch(game, {
  ballType = "POKE_BALL",
  mon = { species = "SENTRET", hp = 20, stats = { hp = 20 } },
  def = game.data.pokemon.SENTRET,
  rng = function() return 0 end,
  rateOverride = 77,
  species = "SENTRET",
})
eq(caught, false, "D. forced Gold fail")
eq(GoldCatching.last.ball, "POKE_BALL", "Gold attempt uses ball id")
eq(GoldCatching.last.catchRate, 77, "Wilds rateOverride is Gold species rate")
eq(GoldCatching.last.species, "SENTRET", "Gold attempt species is entity id")
check(shakes >= 1, "fail still reports presentation shakes")

GoldCatching._force = nil
caught = GameCompat.attemptCatch(game, {
  ballType = "MASTER_BALL",
  mon = { species = "MEWTWO", hp = 20, stats = { hp = 20 } },
  def = game.data.pokemon.MEWTWO,
  rng = function() return 255 end,
  rateOverride = 1,
  species = "MEWTWO",
})
eq(caught, true, "I. Gold Master Ball guaranteed")

----------------------------------------------------------------
-- E/F. Mon creation + party insert
----------------------------------------------------------------
monNewCalls = {}
local sentret = GameCompat.createCaughtPokemon(game, "SENTRET", 3, {})
eq(sentret.species, "SENTRET", "E. real Gold species SENTRET")
eq(sentret.level, 3, "E. level from Wilds entity")
eq(sentret._fromMonNew, true, "E. Mon.new constructed the mon")
eq(sentret.ot, "GOLD", "E. stampOT wrote player OT")
eq(sentret.otId, 4321, "E. stampOT wrote player id")
eq(sentret.experience, 27, "E. Mon.new filled experience")
eq(sentret.moves[1].id, "TACKLE", "E. Mon.new filled moves")
eq(monNewCalls[1].species, "SENTRET", "Mon.new species is SENTRET")

local given = GameCompat.giveCaughtPokemon(game, sentret)
eq(given.destination, "party", "F. party < 6 adds to party")
eq(game.save.party[#game.save.party].species, "SENTRET", "F. last party slot is SENTRET")

GameCompat.markSpeciesCaught(game, "SENTRET", sentret)
eq(game.save.pokedex.caught.SENTRET, true, "H. Gold caught stamp")
eq(game.save.pokedex.seen.SENTRET, true, "H. Gold seen stamp")
eq(unownCalls[1], "SENTRET", "Unown.registerCatch saw the mon")
eq(game.save.party[#game.save.party].species, "SENTRET",
   "Q. save.party still holds SENTRET")

----------------------------------------------------------------
-- G. party full → current Gold box, insert at head
----------------------------------------------------------------
game.save.party = {
  { species = "A" }, { species = "B" }, { species = "C" },
  { species = "D" }, { species = "E" }, { species = "F" },
}
eq(GameCompat.playerHasPartySpace(game), false, "party of 6 is full")
game.save.boxes[1] = { { species = "OLD" } }
local boxed = GameCompat.createCaughtPokemon(game, "PIDGEY", 8)
local boxResult = GameCompat.giveCaughtPokemon(game, boxed)
eq(boxResult.destination, "box", "G. party full → box")
eq(boxResult.boxNum, 1, "G. current box 1")
eq(game.save.boxes[1][1].species, "PIDGEY", "G. SendMonIntoBox inserts at head")
eq(game.save.boxes[1][2].species, "OLD", "G. previous box mon shifted")
eq(#game.save.party, 6, "G. party stays 6")
eq(game.save.boxes[1][1].species, "PIDGEY", "Q. boxed catch remains in save.boxes")

----------------------------------------------------------------
-- Reordered Dex: MEWTWO stays MEWTWO even if runtime dex is 248
----------------------------------------------------------------
eq(GameCompat.speciesId("MEWTWO", game, V.mod), 248, "runtime MEWTWO dex is 248")
eq(SpeciesAssets.idFor("MEWTWO"), 150, "SpeciesAssets MEWTWO is still 150")
monNewCalls = {}
local mewtwo = GameCompat.createCaughtPokemon(game, "MEWTWO", 70)
eq(mewtwo.species, "MEWTWO", "reordered-Dex create is MEWTWO")
check(mewtwo.species ~= 150 and mewtwo.species ~= 248,
      "create does not store a dex/asset number as species")
eq(monNewCalls[1].species, "MEWTWO", "Mon.new received MEWTWO not 150")
game.save.party = {}
GameCompat.giveCaughtPokemon(game, mewtwo)
GameCompat.markSpeciesCaught(game, "MEWTWO", mewtwo)
eq(game.save.pokedex.caught.MEWTWO, true, "dex keyed by MEWTWO")
check(game.save.pokedex.caught[150] == nil, "asset id 150 did not leak into caught")
check(game.save.pokedex.caught[248] == nil, "runtime dex 248 did not leak into caught")
eq(game.save.party[1].species, "MEWTWO", "party identity is MEWTWO")

local entity = { species = "MEWTWO", level = 70, assetId = 150 }
eq(GameCompat.captureSpecies(entity, { species = "MEWTWO" }), "MEWTWO",
   "entity.species is authoritative")
eq(GameCompat.captureLevel(entity, { level = 70 }), 70, "entity/record level")

----------------------------------------------------------------
-- Fakemon: capture the registry species, do not rewrite to vanilla
----------------------------------------------------------------
monNewCalls = {}
local fake = GameCompat.createCaughtPokemon(game, "FAKEMON", 12)
eq(fake.species, "FAKEMON", "Fakemon species preserved")
eq(fake._fromMonNew, true, "Gold registry Fakemon uses Mon.new")
eq(fake.name, "FAKEMON", "Fakemon name from Gold def")
check(fake.species ~= "PIDGEY" and fake.species ~= "SENTRET",
      "Fakemon was not rewritten to a vanilla mon")

local unknown = GameCompat.createCaughtPokemon(game, "UNKNOWN_MON", 5)
eq(unknown.species, "UNKNOWN_MON", "unknown species keeps its id")
check(unknown.species ~= "PIDGEY", "unknown is not turned into PIDGEY")

----------------------------------------------------------------
-- Special session: Bug Contest blocks OW throws; not treated as Safari
----------------------------------------------------------------
eq(GameCompat.specialCatchSessionBlocks(game, {}), false, "no contest → not blocked")
game.save.bugContest = { active = true, balls = 20 }
eq(GameCompat.specialCatchSessionBlocks(game, {}), true, "Bug Contest blocks OW throws")
eq(GameCompat.supportsFeature("safari", nil, game), false,
   "contest is not turned into Safari capability")
game.save.bugContest.active = false
eq(GameCompat.specialCatchSessionBlocks(game, {}), false, "inactive contest allows throws")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("gen2_catching_compat_unit_test: all passed")
