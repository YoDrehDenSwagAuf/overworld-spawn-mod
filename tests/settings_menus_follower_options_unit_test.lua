-- Regression: POKE FOLLOW EX writes Gen1Recomp option buckets (no options:set)
-- and uses the shared handleOptionsChanged handler from main.lua.
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

local modOptions = {
  overworld_wild_spawns = {
    follow_control = "trainer",
    trainer_trail = false,
    follower_count = 1,
    sprite_style = "pokemmo",
  },
}
local handlerCalls = {}
local syncAllCalls = 0

local game = {
  save = {
    options = { modOptions = modOptions },
    pokepcFollowerCount = 1,
    pokepcControlMode = "follow",
    party = {
      { species = "BULBASAUR", hp = 20, level = 5 },
      { species = "CHARMANDER", hp = 20, level = 5 },
      { species = "SQUIRTLE", hp = 20, level = 5 },
    },
  },
  mods = { modOptions = modOptions },
  overworld = {
    map = { width = 10, height = 10 },
    player = { cellX = 5, cellY = 5, facing = "down" },
    npcs = {}, entities = {}, pokepcTrailers = {},
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
      get = function(_, k)
        local b = modOptions.overworld_wild_spawns
        return b and b[k]
      end,
      -- intentionally no :set
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

local Config = V.require("config")
modules.config = Config

local Settings = V.require("follower/settings")
local settings = Settings.new(V.mod)

local control = {
  _optCache = { follower_count = 1 },
  _installed = true,
  settings = settings,
}
function control:followerCount(g) return settings:followerCount(g) end
function control:alignSaveFromOptions(g)
  settings:alignSave(g)
  self._optCache = {}
end
function control:onOptionsChanged(payload)
  self._optCache = {}
  self:alignSaveFromOptions(payload.game or game)
  self:syncAll()
end
function control:syncAll()
  syncAllCalls = syncAllCalls + 1
end

local follower = {
  settings = settings,
  control = control,
  lifecycle = { requestFollowerSpriteRefresh = function() end },
}
function follower:onOptionsChanged(payload)
  settings:onOptionsChanged(payload)
  local key = payload and payload.key
  if key == "follow_control" or key == "trainer_trail" or key == "follower_count" then
    settings:alignSave(payload.game or game)
    control:onOptionsChanged(payload)
  end
end

local function handleOptionsChanged(payload)
  handlerCalls[#handlerCalls + 1] = payload
  follower:onOptionsChanged(payload)
end

local SettingsMenus = V.require("settings_menus")
local menus = SettingsMenus.new(V.mod, { onOptionsChanged = function() end }, follower, nil)
menus:setOptionsChangedHandler(handleOptionsChanged)

check(V.mod.options.set == nil, "no mod.options:set in test (engine parity)")

menus:_applyFollowerCount(game, 3)
eq(modOptions.overworld_wild_spawns.follower_count, 3,
   "test_custom_menu_follower_count_updates_option")
eq(game.save.pokepcFollowerCount, 3,
   "test_custom_menu_follower_count_updates_save_mirror")
eq(V.mod.options:get("follower_count"), 3, "options:get sees bucket write")

control._optCache = { follower_count = 1 }
menus:_applyFollowerCount(game, 4)
eq(control:followerCount(game), 4,
   "test_custom_menu_follower_count_invalidates_control_cache")
check(control._optCache.follower_count == nil, "cache cleared")

local before = syncAllCalls
menus:_applyFollowerCount(game, 3)
check(syncAllCalls == before + 1, "test_custom_menu_follower_count_syncs_runtime")
eq(handlerCalls[#handlerCalls].source, "options_menu", "shared handler source")

modOptions.overworld_wild_spawns.follow_control = "pokemon"
modOptions.overworld_wild_spawns.trainer_trail = false
menus:_applyFollowerCount(game, 0)
eq(modOptions.overworld_wild_spawns.follower_count, 0,
   "test_custom_menu_follower_count_zero option")
eq(settings:engineMode(game), "pokemon", "engineMode pokemon at 0")
eq(game.save.pokepcControlMode, "pokemon", "save mode pokemon")

menus:_applyFollowerCount(game, 2)
eq(settings:engineMode(game), "pack", "engineMode pack at 2")

menus:_applyFollowerCount(game, 5)
local root = menus:_openFollowersRoot(game)
local right
for _, it in ipairs(root.items) do
  if it.label == "FOLLOWERS" then right = it.right end
end
eq(right, "5", "test_custom_menu_follower_count_root_refresh")

handlerCalls = {}
menus:_applyControlMode(game, "pokemon")
eq(modOptions.overworld_wild_spawns.follow_control, "pokemon", "control mode option")
eq(handlerCalls[#handlerCalls].key, "follow_control", "control mode uses shared handler")

handlerCalls = {}
menus:_applyTrainerTrail(game, true)
eq(modOptions.overworld_wild_spawns.trainer_trail, true, "trainer trail option")
eq(handlerCalls[#handlerCalls].key, "trainer_trail", "trail uses shared handler")
eq(settings:engineMode(game), "lead_trainer", "trail on → lead_trainer")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("settings_menus_follower_options_unit_test: all passed")
