-- In-game Poke Followers EX / Wilds of Kanto menus share mod.options keys.
-- Run: lua tests/settings_menus_unit_test.lua
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
  sprite_style = "pokemmo",
  follow_control = "trainer",
  trainer_trail = false,
  follower_count = 3,
  enabled = true,
  spawn_density = "normal",
  random_encounters = true,
  water_spawns = "swimming_sprites",
  cave_spawns = "reachable",
  dev_overlay = false,
}
local setLog = {}
local screens = {}
local startItems = nil

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    options = {
      get = function(_, k) return optionStore[k] end,
      set = function(_, k, v)
        optionStore[k] = v
        setLog[#setLog + 1] = { k, v }
      end,
    },
    hooks = {
      wrap = function(_, name, fn)
        if name == "ui.start_menu.items" then
          startItems = fn(function(_, items) return items end, {}, {
            { label = "POKEDEX" }, { label = "OPTION" },
          })
        end
      end,
    },
    content = {
      screens = {
        register = function(_, id, def)
          screens[id] = def
        end,
      },
    },
    ui = {
      ListMenu = {
        new = function(_, game, title, items, opts)
          return { title = title, items = items, opts = opts, close = function() end }
        end,
      },
      push = function() end,
      insertBefore = function(items, before, entry)
        local out = {}
        for _, it in ipairs(items) do
          if it.label == before then out[#out + 1] = entry end
          out[#out + 1] = it
        end
        return out
      end,
    },
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

local SettingsMenus = V.require("settings_menus")
local menus = SettingsMenus.new(V.mod, {
  onOptionsChanged = function() end,
  render = {
    refreshAllSprites = function() end,
  },
}, nil)
menus:register()

eq(SettingsMenus.LABEL_FOLLOWERS, "POKE FOLLOW EX", "followers EX start label")
eq(SettingsMenus.LABEL_WILDS, "WILDS OF KANTO", "wilds start label")
check(#SettingsMenus.LABEL_FOLLOWERS <= 14, "followers label ≤14")
check(#SettingsMenus.LABEL_WILDS <= 14, "wilds label ≤14")
check(screens[SettingsMenus.SCREEN_FOLLOWERS] ~= nil, "followers screen registered")
check(screens[SettingsMenus.SCREEN_WILDS] ~= nil, "wilds screen registered")
check(startItems ~= nil, "start menu hook installed")

local labels = {}
for _, it in ipairs(startItems or {}) do
  labels[#labels + 1] = it.label
end
local joined = table.concat(labels, ",")
check(joined:find("POKE FOLLOW EX", 1, true), "start menu has Poke Followers EX")
check(joined:find("WILDS OF KANTO", 1, true), "start menu has Wilds of Kanto")

-- Shared keys: follower_count via Followers menu apply
menus:_applyFollowerCount({}, 6)
eq(optionStore.follower_count, 6, "followers menu writes follower_count")
eq(Config.get(V.mod, "follower_count"), 6, "Config.get sees same follower_count")

-- Shared keys: sprite style via Config.setSpriteStyle (Wilds menu path)
local ok = Config.setSpriteStyle(V.mod, "followers", "start_menu", {
  game = {},
  logic = { render = { refreshAllSprites = function() end } },
  confirm = false,
})
check(ok == true, "setSpriteStyle from wilds menu path")
eq(optionStore.sprite_style, "followers", "sprite_style shared key updated")
eq(Config.spriteStyle(V.mod), "followers", "spriteStyle reads shared key")

-- Control mode shared
menus:_applyControlMode({}, "pokemon")
eq(optionStore.follow_control, "pokemon", "control mode shared key")

-- Trainer trail shared
menus:_applyTrainerTrail({}, true)
eq(optionStore.trainer_trail, true, "trainer trail shared key")

-- No duplicate persistence keys introduced by menus module
local schema = assert(loadfile("options.lua"))()
local keys = {}
for _, row in ipairs(schema) do keys[row.key] = true end
check(keys.sprite_style and keys.follow_control and keys.follower_count
  and keys.trainer_trail and keys.enabled and keys.water_spawns,
  "menus map onto existing options.lua keys")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("settings_menus_unit_test: all passed")
