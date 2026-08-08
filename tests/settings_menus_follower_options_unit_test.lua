-- Regression: START → OPTIONS → POKE FOLLOW EX must use the same
-- mod.options + onOptionsChanged pipeline as Mod Settings.
-- Run: lua tests/settings_menus_follower_options_unit_test.lua
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
  follow_control = "trainer",
  trainer_trail = false,
  follower_count = 1,
  sprite_style = "pokemmo",
}
local setLog = {}
local followerPayloads = {}
local syncAllCalls = 0
local removeTrailersCalls = 0

local game = {
  save = {
    pokepcFollowerCount = 1,
    pokepcControlMode = "follow",
    party = {
      { species = "BULBASAUR", hp = 20, level = 5 },
      { species = "CHARMANDER", hp = 20, level = 5 },
      { species = "SQUIRTLE", hp = 20, level = 5 },
      { species = "PIKACHU", hp = 20, level = 5 },
      { species = "EEVEE", hp = 20, level = 5 },
      { species = "MEOWTH", hp = 20, level = 5 },
    },
  },
  overworld = {
    map = { width = 10, height = 10 },
    player = {
      cellX = 5, cellY = 5, facing = "down",
      px = 80, py = 80, moving = false,
    },
    npcs = {},
    entities = {},
    pokepcTrailers = {},
  },
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
      set = function(_, k, v)
        optionStore[k] = v
        setLog[#setLog + 1] = { k, v }
      end,
    },
    hooks = { wrap = function() end },
    content = { screens = { register = function() end } },
    ui = {
      ListMenu = {
        new = function(g, title, items, opts)
          return { title = title, items = items, opts = opts, close = function() end }
        end,
      },
      push = function() end,
    },
    events = { on = function() end },
    find = function() return nil end,
    save = { get = function() return nil end, set = function() end },
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
modules.config = {
  DEFAULTS = {
    follow_control = "trainer",
    trainer_trail = false,
    follower_count = 1,
    sprite_style = "pokemmo",
  },
  get = function(_, k)
    local v = optionStore[k]
    if v == nil then return modules.config.DEFAULTS[k] end
    return v
  end,
  spriteStyle = function() return optionStore.sprite_style or "pokemmo" end,
  debug = function() return false end,
}

local Settings = V.require("follower/settings")
local settings = Settings.new(V.mod)

-- Lightweight control stand-in that mirrors ControlEngine cache + sync hooks.
local control = {
  _optCache = { follower_count = 1 },
  _installed = true,
  settings = settings,
  syncAllCalls = 0,
}
function control:followerCount(g)
  return settings:followerCount(g)
end
function control:controlMode(g)
  return settings:engineMode(g)
end
function control:alignSaveFromOptions(g)
  settings:alignSave(g)
  self._optCache.follower_count = nil
end
function control:onOptionsChanged(payload)
  self._optCache = {}
  local g = (payload and payload.game) or game
  self:alignSaveFromOptions(g)
  self:syncAll(g, g and g.overworld)
end
function control:syncAll(g, ow)
  syncAllCalls = syncAllCalls + 1
  self.syncAllCalls = syncAllCalls
  if ow then
    removeTrailersCalls = removeTrailersCalls + 1
    ow.pokepcTrailers = {}
  end
end
function control:setFollowerCount(g, n)
  -- Intentionally wrong if menu still calls this as a parallel writer:
  -- would re-seed cache as a second source of truth.
  self._optCache.follower_count = n
  settings:setFollowerCount(g, n)
end

local follower = {
  settings = settings,
  control = control,
  lifecycle = {
    requestFollowerSpriteRefresh = function() end,
  },
}
function follower:onOptionsChanged(payload)
  followerPayloads[#followerPayloads + 1] = payload
  -- Same shape as lib/follower/init.lua
  settings:onOptionsChanged(payload)
  local key = payload and payload.key
  if key == "follow_control" or key == "trainer_trail" or key == "follower_count"
      or key == "sprite_style" then
    local g = payload.game or (V.mod.world and V.mod.world.game)
    settings:alignSave(g)
    control:onOptionsChanged(payload)
  end
end

local SettingsMenus = V.require("settings_menus")
local menus = SettingsMenus.new(V.mod, {
  onOptionsChanged = function() end,
}, follower, nil)

----------------------------------------------------------------
-- test_custom_menu_follower_count_updates_option
----------------------------------------------------------------
setLog = {}
followerPayloads = {}
syncAllCalls = 0
menus:_applyFollowerCount(game, 3)
eq(optionStore.follower_count, 3, "test_custom_menu_follower_count_updates_option")
eq(setLog[#setLog][1], "follower_count", "writes follower_count key")
eq(setLog[#setLog][2], 3, "writes follower_count value 3")

----------------------------------------------------------------
-- test_custom_menu_follower_count_updates_save_mirror
----------------------------------------------------------------
eq(game.save.pokepcFollowerCount, 3,
   "test_custom_menu_follower_count_updates_save_mirror")

----------------------------------------------------------------
-- test_custom_menu_follower_count_invalidates_control_cache
----------------------------------------------------------------
control._optCache = { follower_count = 1 }
menus:_applyFollowerCount(game, 4)
eq(control:followerCount(game), 4,
   "test_custom_menu_follower_count_invalidates_control_cache")
check(control._optCache.follower_count == nil,
      "cache slot cleared (not forced to selected value)")

----------------------------------------------------------------
-- test_custom_menu_follower_count_syncs_runtime
----------------------------------------------------------------
local beforeSync = syncAllCalls
menus:_applyFollowerCount(game, 3)
check(syncAllCalls == beforeSync + 1,
      "test_custom_menu_follower_count_syncs_runtime")
eq(followerPayloads[#followerPayloads].source, "options_menu",
   "payload source is options_menu")
eq(followerPayloads[#followerPayloads].key, "follower_count",
   "payload key is follower_count")
check(followerPayloads[#followerPayloads].game == game,
      "payload carries menu game")

----------------------------------------------------------------
-- test_custom_menu_follower_count_zero
----------------------------------------------------------------
optionStore.follow_control = "pokemon"
optionStore.trainer_trail = false
menus:_applyFollowerCount(game, 0)
eq(optionStore.follower_count, 0, "test_custom_menu_follower_count_zero option")
eq(game.save.pokepcFollowerCount, 0, "zero mirrors to save")
eq(settings:engineMode(game), "pokemon",
   "pokemon control + 0 followers → engineMode pokemon")
eq(game.save.pokepcControlMode, "pokemon", "save control mode mirror pokemon")

----------------------------------------------------------------
-- pack mode after raising count
----------------------------------------------------------------
menus:_applyFollowerCount(game, 2)
eq(settings:engineMode(game), "pack", "pokemon control + 2 → pack")
eq(game.save.pokepcControlMode, "pack", "save control mode mirror pack")

----------------------------------------------------------------
-- test_custom_menu_follower_count_root_refresh
----------------------------------------------------------------
menus:_applyFollowerCount(game, 5)
local root = menus:_openFollowersRoot(game)
local followersRight
for _, it in ipairs(root.items) do
  if it.label == "FOLLOWERS" then followersRight = it.right end
end
eq(followersRight, "5", "test_custom_menu_follower_count_root_refresh")

----------------------------------------------------------------
-- CONTROL MODE / TRAINER TRAIL also use canonical notify path
----------------------------------------------------------------
followerPayloads = {}
menus:_applyControlMode(game, "pokemon")
eq(optionStore.follow_control, "pokemon", "control mode writes option")
eq(followerPayloads[#followerPayloads].key, "follow_control",
   "control mode notifies follower pipeline")

followerPayloads = {}
menus:_applyTrainerTrail(game, true)
eq(optionStore.trainer_trail, true, "trainer trail writes option")
eq(followerPayloads[#followerPayloads].key, "trainer_trail",
   "trainer trail notifies follower pipeline")
eq(settings:engineMode(game), "lead_trainer", "trail on → lead_trainer")

----------------------------------------------------------------
-- Menu must not call control:setFollowerCount (no dual writer)
----------------------------------------------------------------
control._optCache = {}
local setFollowerCountCalls = 0
local origSet = control.setFollowerCount
control.setFollowerCount = function(self, g, n)
  setFollowerCountCalls = setFollowerCountCalls + 1
  return origSet(self, g, n)
end
menus:_applyFollowerCount(game, 6)
eq(setFollowerCountCalls, 0,
   "menu does not call control:setFollowerCount")
eq(optionStore.follower_count, 6, "count still applied via options path")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("settings_menus_follower_options_unit_test: all passed")
