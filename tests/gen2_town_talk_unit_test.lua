-- Gold town Pokémon talk via OverworldController.talkTo (World:interactBody seam).
-- Normal NPCs / trainers / signs fall through to the original talkTo.
-- Run: luajit tests/gen2_town_talk_unit_test.lua
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

local cryCalls = {}
package.loaded["src.core.Sound"] = {
  playCry = function(data, species)
    cryCalls[#cryCalls + 1] = { data = data, species = species }
  end,
}

local origTalkCalls = {}
local OverworldState = {
  talkTo = function(world, npc)
    origTalkCalls[#origTalkCalls + 1] = { world = world, npc = npc }
    if npc and npc.def and npc.def.trainer then
      world._trainerScript = npc.def.trainer
    end
    if npc and npc.kind == "sign" then
      world._signText = npc.text
    end
    return false
  end,
  interact = function() return false end,
  update = function() end,
}
package.loaded["src.world.OverworldController"] = OverworldState

local optionStore = { town_pokemon = true, sprite_style = "followers" }
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
modules.config = nil

local Config = V.require("config")
modules.config = Config
local AmbientCries = V.require("ambient_cries")
local AmbientPokemon = V.require("ambient_pokemon")
local GameCompat = V.require("game_compat")

local goldGame = {
  generation = 2,
  version = "gold",
  save = { party = { { species = "CHIKORITA", hp = 20 } }, pokedex = nil },
  data = {
    maps = {
      NEW_BARK_TOWN = { id = "NEW_BARK_TOWN", tileset = "OVERWORLD" },
    },
    pokemon = { SENTRET = { name = "SENTRET", dex = 161 } },
    sprites = {},
  },
  stack = { push = function() error("Gold must not use Gen1 TextBox path") end },
}

local player = { cellX = 5, cellY = 6, facing = "up", moving = false }
local shown = {}
local world = {
  game = goldGame,
  player = player,
  map = {
    id = "NEW_BARK_TOWN",
    widthCells = 20, heightCells = 18,
    inBounds = function() return true end,
    isWalkableCell = function() return true end,
    isWaterCell = function() return false end,
    warpAtCell = function() return nil end,
    isDoorCell = function() return false end,
    isCounterCell = function() return false end,
  },
  npcs = {},
  entities = {},
  showText = function(self, text, onDone)
    shown[#shown + 1] = { text = text, onDone = onDone }
    self._dialogActive = true
    self._onDone = onDone
  end,
}

V.mod.world = { game = goldGame, overworld = function() return world end }
goldGame.world = world

local ambient = AmbientPokemon.new(V.mod, {})
local installed = ambient:install()
check(installed == true, "town talk wrap installs on Gold")
check(OverworldState.talkTo == OverworldState._wildsAmbientTalkWrap,
      "OverworldController.talkTo wrapped (Gold interactBody seam)")

-- Spawn a New Bark Sentret in front of the player (y = 5, player faces up).
local guest = ambient:_makeGoldGuest(goldGame, world, "SENTRET", 5, 5, "WANDER")
ambient:_markAmbient(guest, "SENTRET", "WANDER")
guest.moving = true
guest.targetX, guest.targetY = 5, 4
guest.progress = 8
world.npcs[1] = guest
world.entities[1] = guest
ambient.active[guest] = true

eq(guest.wildsAmbientPokemon, true, "guest is a town Pokémon")
eq(guest.wildsBattleable, false, "town Pokémon not battleable")
eq(guest.wildsAggressive, false, "town Pokémon not aggressive")
eq(guest.wildsEncounterEnabled, false, "no random encounter")
eq(guest.overworldWildSpawn, false, "not a wild spawn")

-- Gold World:interactBody already found the facing NPC; it calls talkTo(world, npc).
local handled = OverworldState.talkTo(world, guest)
eq(handled, true, "interact/talkTo returns handled for town Pokémon")
eq(#origTalkCalls, 0, "original talkTo not used for town Pokémon")
eq(guest.facing, "down", "town Pokémon faces the player")
eq(guest.frozen, true, "frozen while dialog active")
eq(guest.moving, false, "mid-step finished before dialog")
eq(guest.cellX, 5, "no multi-cell teleport on talk")
eq(guest.cellY, 4, "snapped to in-flight target only")
eq(#cryCalls, 1, "cry attempted")
eq(cryCalls[1].species, "SENTRET", "cry species is Sentret")
eq(shown[1] and shown[1].text, AmbientCries.textFor("SENTRET"),
   "AmbientCries text shown via world:showText")
check(world._dialogActive == true, "Gold dialog active")
check(world._trainerScript == nil, "talking does not start a trainer/wild battle")

-- Unfreeze after dialog
shown[1].onDone()
eq(guest.frozen, false, "unfreezes after dialog")

----------------------------------------------------------------
-- Normal Gold NPC: original World:interact / talkTo path
----------------------------------------------------------------
local npc = {
  id = "elm",
  cellX = 6, cellY = 6,
  def = { index = 1, script = "ElmScript" },
  frozen = false,
}
local before = #origTalkCalls
local npcHandled = OverworldState.talkTo(world, npc)
eq(npcHandled, false, "normal NPC returns original talkTo result")
eq(#origTalkCalls, before + 1, "normal NPC uses original talkTo")
eq(origTalkCalls[#origTalkCalls].npc, npc, "original received the NPC")

----------------------------------------------------------------
-- Trainer: original trainer interaction unchanged
----------------------------------------------------------------
local trainer = {
  id = "youngster",
  cellX = 7, cellY = 7,
  def = { trainer = "YOUNGSTER_JOEY", index = 2 },
}
world._trainerScript = nil
local trainerHandled = OverworldState.talkTo(world, trainer)
eq(trainerHandled, false, "trainer falls through")
eq(world._trainerScript, "YOUNGSTER_JOEY", "original trainer path ran")

----------------------------------------------------------------
-- Sign / object: unchanged
----------------------------------------------------------------
local sign = { id = "sign", kind = "sign", text = "NEW BARK TOWN", def = { index = 3 } }
world._signText = nil
local signHandled = OverworldState.talkTo(world, sign)
eq(signHandled, false, "sign falls through")
eq(world._signText, "NEW BARK TOWN", "original sign path ran")

----------------------------------------------------------------
-- Guard flag without wildsAmbientPokemon still talks, never battles
----------------------------------------------------------------
local guard = {
  id = "guarded",
  cellX = 8, cellY = 8,
  facing = "left",
  wildsAmbientPokemon = false,
  def = { _wildsAmbientGuard = true },
  frozen = false,
  facePlayer = function(self, p)
    self.facing = "down"
    self._faced = p
  end,
}
-- Mark as ambient so talkTo() has species; guard flag is the wrap trigger.
guard.wildsAmbientPokemon = true
guard.ambientSpecies = "PIDGEY"
guard.wildsBattleable = false
local guardHandled = OverworldState.talkTo(world, guard)
eq(guardHandled, true, "ambient guard is handled")
eq(guard.frozen, true, "guard guest frozen during dialog")

----------------------------------------------------------------
-- Cry failure must not block text
----------------------------------------------------------------
package.loaded["src.core.Sound"].playCry = function() error("no cry") end
shown = {}
guest.frozen = false
guest.facing = "up"
local still = OverworldState.talkTo(world, guest)
eq(still, true, "talk still handled when cry fails")
check(shown[1] ~= nil, "text still appears if cry fails")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll Gen2 town-talk tests passed.")
