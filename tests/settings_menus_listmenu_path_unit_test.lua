-- Simulate the real Gen1Recomp ListMenu interaction path for
-- START → OPTIONS → POKE FOLLOW EX.
--
-- Critical engine facts (verified against gen1recomp source):
--   * mod.options has define/get only — NO options:set
--   * ManagerState:setOption writes loader.modOptions + emits options_changed
--   * ListMenu stores item tables as-is; onChoose receives the original item
--   * ListMenu:close() only pops when the menu is stack top
--
-- Run: lua tests/settings_menus_listmenu_path_unit_test.lua
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

-- Real Gen1Recomp option storage shape.
local modOptions = {
  overworld_wild_spawns = {
    follow_control = "trainer",
    trainer_trail = false,
    follower_count = 1,
    sprite_style = "pokemmo",
    enabled = true,
  },
}

local stack = {}
local pushedScreens = {}
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
      { species = "PIKACHU", hp = 20, level = 5 },
    },
  },
  mods = { modOptions = modOptions },
  overworld = {
    map = { width = 10, height = 10 },
    player = { cellX = 5, cellY = 5, facing = "down", px = 80, py = 80 },
    npcs = {}, entities = {}, pokepcTrailers = {},
  },
  stack = {
    _items = stack,
    push = function(self, screen)
      stack[#stack + 1] = screen
    end,
    pop = function(self)
      local top = stack[#stack]
      stack[#stack] = nil
      return top
    end,
    top = function(self)
      return stack[#stack]
    end,
  },
  writeOptions = function() end,
}

-- Minimal ListMenu stand-in matching Gen1Recomp semantics.
local function ListMenu_new(g, title, items, opts)
  local menu = {
    game = g,
    title = title,
    items = items, -- original tables preserved
    opts = opts,
    index = 1,
  }
  function menu:close()
    local top = self.game.stack:top()
    if top == self then self.game.stack:pop() end
  end
  function menu:choose(index)
    self.index = index or self.index
    local item = self.items[self.index]
    if self.opts and self.opts.onChoose then
      self.opts.onChoose(item, self)
    end
  end
  return menu
end

local screens = {}
local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    world = { game = game },
    -- NO options.set — matches Gen1Recomp Loader._api
    options = {
      get = function(_, key)
        local bucket = modOptions.overworld_wild_spawns
        if bucket and bucket[key] ~= nil then return bucket[key] end
        return nil
      end,
      define = function() end,
    },
    hooks = { wrap = function() end },
    content = {
      screens = {
        register = function(_, id, def) screens[id] = def end,
      },
    },
    ui = {
      ListMenu = { new = ListMenu_new },
      push = function(g, screenId)
        pushedScreens[#pushedScreens + 1] = screenId
        local def = screens[screenId]
        check(def ~= nil, "screen registered: " .. tostring(screenId))
        local menu = def.new(g or game)
        game.stack:push(menu)
        return menu
      end,
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
modules.config = nil -- load real config

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
function control:controlMode(g) return settings:engineMode(g) end
function control:alignSaveFromOptions(g)
  settings:alignSave(g)
  self._optCache = {}
end
function control:onOptionsChanged(payload)
  self._optCache = {}
  local g = (payload and payload.game) or game
  self:alignSaveFromOptions(g)
  self:syncAll(g, g.overworld)
end
function control:syncAll()
  syncAllCalls = syncAllCalls + 1
end
function control:setFollowerCount()
  error("menu must not call control:setFollowerCount")
end

local follower = {
  settings = settings,
  control = control,
  lifecycle = { requestFollowerSpriteRefresh = function() end },
}
function follower:onOptionsChanged(payload)
  settings:onOptionsChanged(payload)
  local key = payload and payload.key
  if key == "follow_control" or key == "trainer_trail" or key == "follower_count"
      or key == "sprite_style" then
    local g = payload.game or game
    settings:alignSave(g)
    control:onOptionsChanged(payload)
  end
end

-- Shared handler matching main.lua (logic + follower + ambient).
local function handleOptionsChanged(payload)
  handlerCalls[#handlerCalls + 1] = payload
  follower:onOptionsChanged(payload)
end

local SettingsMenus = V.require("settings_menus")
local menus = SettingsMenus.new(V.mod, {
  onOptionsChanged = function() end,
}, follower, nil)
menus:setOptionsChangedHandler(handleOptionsChanged)
menus:register()

----------------------------------------------------------------
-- Prove mod.options:set is absent (engine contract)
----------------------------------------------------------------
check(V.mod.options.set == nil, "mod.options:set is absent (Gen1Recomp)")

----------------------------------------------------------------
-- Interactive path: root → FOLLOWERS → 4
----------------------------------------------------------------
handlerCalls = {}
syncAllCalls = 0
pushedScreens = {}
stack = {}
game.stack._items = stack

local root = menus:_openFollowersRoot(game)
game.stack:push(root)
eq(root.items[3].label, "FOLLOWERS", "third row is FOLLOWERS")
eq(root.items[3].right, "1", "root shows initial count 1")
check(type(root.items[3].onSelect) ~= "function",
      "FOLLOWERS uses screen id, not fragile onSelect-only")
check(root.items[3].screen ~= nil, "FOLLOWERS has screen id")

-- Choose FOLLOWERS row (index 3) — exercises onChoose + close-then-push
root:choose(3)
eq(pushedScreens[#pushedScreens], SettingsMenus.SCREEN_FOLLOWERS .. ":count",
   "child FOLLOWERS screen pushed")
check(game.stack:top() ~= root, "parent root closed before/after push")
local child = game.stack:top()
check(child ~= nil and child.title == "FOLLOWERS", "child menu is FOLLOWERS choice")

-- Find value 4 in child items and choose it
local idx4
for i, it in ipairs(child.items) do
  if it.value == 4 then idx4 = i break end
end
check(idx4 ~= nil, "choice menu has value 4")
child:choose(idx4)

eq(modOptions.overworld_wild_spawns.follower_count, 4,
   "bucket follower_count == 4 after ListMenu path")
eq(V.mod.options:get("follower_count"), 4, "mod.options:get == 4")
eq(settings:followerCount(game), 4, "settings:followerCount == 4")
eq(control:followerCount(game), 4, "control:followerCount == 4")
eq(game.save.pokepcFollowerCount, 4, "save mirror == 4")
check(#handlerCalls >= 1, "shared handleOptionsChanged called")
eq(handlerCalls[#handlerCalls].key, "follower_count", "handler key follower_count")
eq(handlerCalls[#handlerCalls].source, "options_menu", "handler source options_menu")
check(syncAllCalls >= 1, "syncAll called after choice")

-- Re-open root — must show 4
local root2 = menus:_openFollowersRoot(game)
local right4
for _, it in ipairs(root2.items) do
  if it.label == "FOLLOWERS" then right4 = it.right end
end
eq(right4, "4", "reopened root shows FOLLOWERS 4")

----------------------------------------------------------------
-- value 0 (truthiness) via ListMenu path
----------------------------------------------------------------
handlerCalls = {}
stack = {}
game.stack._items = stack
root = menus:_openFollowersRoot(game)
game.stack:push(root)
root:choose(3)
child = game.stack:top()
local idx0
for i, it in ipairs(child.items) do
  if it.value == 0 then idx0 = i break end
end
child:choose(idx0)
eq(modOptions.overworld_wild_spawns.follower_count, 0, "FOLLOWERS=0 writes 0")
eq(game.save.pokepcFollowerCount, 0, "save mirror 0")

----------------------------------------------------------------
-- CONTROL MODE → POKEMON via ListMenu path
----------------------------------------------------------------
stack = {}
game.stack._items = stack
root = menus:_openFollowersRoot(game)
game.stack:push(root)
root:choose(1) -- CONTROL MODE
child = game.stack:top()
eq(child.title, "CONTROL MODE", "control mode child open")
local idxPoke
for i, it in ipairs(child.items) do
  if it.value == "pokemon" then idxPoke = i break end
end
child:choose(idxPoke)
eq(modOptions.overworld_wild_spawns.follow_control, "pokemon",
   "control mode pokemon written")
eq(settings:followControl(), "pokemon", "settings followControl pokemon")
-- count is 0 → engineMode pokemon
eq(settings:engineMode(game), "pokemon", "engineMode pokemon at count 0")
eq(game.save.pokepcControlMode, "pokemon", "save mode mirror pokemon")

local root3 = menus:_openFollowersRoot(game)
local modeRight
for _, it in ipairs(root3.items) do
  if it.label == "CONTROL MODE" then modeRight = it.right end
end
eq(modeRight, "POKEMON", "root shows CONTROL MODE POKEMON")

----------------------------------------------------------------
-- TRAINER TRAIL → ON (false→true) via ListMenu path
----------------------------------------------------------------
stack = {}
game.stack._items = stack
root = menus:_openFollowersRoot(game)
game.stack:push(root)
root:choose(2)
child = game.stack:top()
local idxOn
for i, it in ipairs(child.items) do
  if it.value == true then idxOn = i break end
end
child:choose(idxOn)
eq(modOptions.overworld_wild_spawns.trainer_trail, true, "trainer_trail true")
eq(settings:trainerTrail(), true, "settings trainerTrail true")
eq(settings:engineMode(game), "lead_trainer", "engineMode lead_trainer")
eq(game.save.pokepcControlMode, "lead_trainer", "save mode lead_trainer")

local root4 = menus:_openFollowersRoot(game)
local trailRight
for _, it in ipairs(root4.items) do
  if it.label == "TRAINER TRAIL" then trailRight = it.right end
end
eq(trailRight, "ON", "root shows TRAINER TRAIL ON")

----------------------------------------------------------------
-- FOLLOWERS 6 + pack mode
----------------------------------------------------------------
modOptions.overworld_wild_spawns.trainer_trail = false
stack = {}
game.stack._items = stack
root = menus:_openFollowersRoot(game)
game.stack:push(root)
root:choose(3)
child = game.stack:top()
local idx6
for i, it in ipairs(child.items) do
  if it.value == 6 then idx6 = i break end
end
child:choose(idx6)
eq(modOptions.overworld_wild_spawns.follower_count, 6, "FOLLOWERS=6")
eq(settings:engineMode(game), "pack", "pokemon+6 → pack")
eq(game.save.pokepcControlMode, "pack", "save mode pack")

----------------------------------------------------------------
-- close-then-push ordering: parent must not remain under child
----------------------------------------------------------------
stack = {}
game.stack._items = stack
root = menus:_openFollowersRoot(game)
game.stack:push(root)
local beforeTop = game.stack:top()
root:choose(3)
check(game.stack:top() ~= beforeTop, "parent not left under child")
check(#stack == 1, "exactly one menu on stack after push")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("settings_menus_listmenu_path_unit_test: all passed")
