-- ControlEngine + Settings ownership for follower_count options path.
-- Run: lua tests/follower_menu_options_path_unit_test.lua
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

local optionStore = {
  follow_control = "pokemon",
  trainer_trail = false,
  follower_count = 1,
  sprite_style = "pokemmo",
}
local modOptions = { overworld_wild_spawns = optionStore }

package.loaded["src.render.SpriteRenderer"] = {
  new = function(def, id) return { def = def, id = id } end,
}
package.loaded["src.world.OverworldController"] = {
  update = function() end,
}
package.loaded["src.world.PikachuFollower"] = {
  update = function() end,
  onMapEntered = function() end,
  starterInParty = function() return nil end,
}
package.loaded["src.world.NPC"] = {
  new = function()
    return {
      id = "npc", cellX = 0, cellY = 0, px = 0, py = 0,
      facing = "down", moving = false, progress = 0,
      update = function() end,
    }
  end,
  walkPhase = function() return 0 end,
}
package.loaded["src.core.GameVersion"] = {
  get = function() return "red" end,
  isYellow = function() return false end,
}

local game = {
  save = {
    options = { modOptions = modOptions },
    pokepcFollowerCount = 1,
    pokepcControlMode = "pack",
    party = {
      { species = "BULBASAUR", hp = 20, level = 5 },
      { species = "CHARMANDER", hp = 20, level = 5 },
      { species = "SQUIRTLE", hp = 20, level = 5 },
    },
  },
  mods = { modOptions = modOptions },
  overworld = {
    map = {
      width = 10, height = 10,
      tileAt = function() return { collision = 0 } end,
    },
    player = {
      cellX = 5, cellY = 5, facing = "down",
      px = 80, py = 80, moving = false,
    },
    npcs = {},
    entities = {},
    pokepcTrailers = {},
  },
  writeOptions = function() end,
}

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    world = { game = game },
    options = {
      get = function(_, k) return optionStore[k] end,
      -- no :set — Gen1Recomp parity
    },
    events = { on = function() end },
    find = function() return nil end,
    save = { get = function() return nil end, set = function() end },
    hooks = { wrap = function() end },
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

modules.debug_log = {
  warn = function() end, info = function() end, error = function() end, debug = function() end,
}
modules.tile = { CELL = 16 }
modules.json_decode = { decode = function() return nil end }

local Config = V.require("config")
modules.config = Config

local Settings = V.require("follower/settings")
local ControlEngine = V.require("follower/control_engine")
local settings = Settings.new(V.mod)
local engine = ControlEngine.new(V.mod, {
  settings = settings,
  selection = {
    getActiveFollowerMon = function() return game.save.party[1] end,
  },
  spriteService = {
    resolveFollowerSprite = function() return nil end,
  },
  render = {},
  game = game,
})
engine._gameRef = game

-- Prime a stale cache the old menu path used to force-write.
engine._optCache.follower_count = 1
optionStore.follower_count = 1
game.save.pokepcFollowerCount = 1

-- Canonical Mod-Settings-equivalent refresh after options write.
optionStore.follower_count = 4
engine:onOptionsChanged({
  mod = V.mod.id,
  key = "follower_count",
  value = 4,
  source = "options_menu",
  game = game,
})

eq(engine:followerCount(game), 4, "engine reads new follower_count")
eq(game.save.pokepcFollowerCount, 4, "save mirror updated")
check(engine._optCache.follower_count == nil or engine._optCache.follower_count == 4,
      "cache not stuck on primed 1")
-- After onOptionsChanged, cache was cleared; a later _opt may refill.
engine._optCache = {}
eq(engine:_opt("follower_count", 1), 4, "opt cache refill sees options")

-- setFollowerCount must invalidate, not force-cache.
engine._optCache.follower_count = 2
engine:setFollowerCount(game, 5)
eq(optionStore.follower_count, 5, "setFollowerCount writes options")
eq(game.save.pokepcFollowerCount, 5, "setFollowerCount mirrors save")
check(engine._optCache.follower_count == nil,
      "setFollowerCount clears cache slot")
eq(engine:followerCount(game), 5, "followerCount follows options after set")

-- alignSaveFromOptions must not re-write options via setFollowerCount loop;
-- it should update derived control mode when count hits 0.
optionStore.follow_control = "pokemon"
optionStore.trainer_trail = false
optionStore.follower_count = 0
engine:alignSaveFromOptions(game)
eq(game.save.pokepcFollowerCount, 0, "align mirrors count 0")
eq(game.save.pokepcControlMode, "pokemon", "align derives pokemon mode at 0")
optionStore.follower_count = 3
engine:alignSaveFromOptions(game)
eq(game.save.pokepcControlMode, "pack", "align derives pack mode at 3")

-- Follower facade uses payload.game
local Follower = V.require("follower/init")
local follower = Follower.new(V.mod, {})
follower.control = engine
follower.settings = settings
follower.lifecycle = {
  requestFollowerSpriteRefresh = function() end,
}
follower.control._installed = true

optionStore.follower_count = 6
follower:onOptionsChanged({
  key = "follower_count",
  mod = V.mod.id,
  value = 6,
  source = "options_menu",
  game = game,
})
eq(engine:followerCount(game), 6, "Follower:onOptionsChanged refreshes count")
eq(game.save.pokepcFollowerCount, 6, "Follower path mirrors save")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("follower_menu_options_path_unit_test: all passed")
