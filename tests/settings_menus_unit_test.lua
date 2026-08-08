-- In-game Poke Followers EX / Wilds of Kanto menus share mod.options keys
-- and live under START → OPTIONS (ui.options.rows), not the Start Menu.
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
  sprite_fade = "solid",
  sprite_color = "colored",
  follow_control = "trainer",
  trainer_trail = false,
  follower_count = 3,
  enabled = true,
  spawn_density = "normal",
  random_encounters = true,
  water_spawns = "swimming_sprites",
  cave_spawns = "reachable",
  town_pokemon = true,
  pokemon_grass_render_mode = "immersed",
  enable_idle = true,
  enable_wander = true,
  enable_aggressive = true,
  enable_hidden = true,
  dev_overlay = false,
}
local modOptions = { overworld_wild_spawns = optionStore }
local game = {
  save = { options = { modOptions = modOptions } },
  mods = { modOptions = modOptions },
  writeOptions = function() end,
}
local screens = {}
local optionsRows = nil
local startItems = nil
local wrappedHooks = {}

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    world = { game = game },
    -- Gen1Recomp: define/get only (no options:set).
    options = {
      get = function(_, k) return optionStore[k] end,
    },
    hooks = {
      wrap = function(_, name, fn)
        wrappedHooks[name] = true
        if name == "ui.options.rows" then
          optionsRows = fn(function(_, rows) return rows end, {}, {
            { id = "textSpeed", label = "TEXT SPEED" },
            { id = "mods", label = "MODS" },
          })
        elseif name == "ui.start_menu.items" then
          startItems = fn(function(_, items) return items end, {}, {
            { label = "POKEDEX" }, { label = "OPTION" }, { label = "SAVE" },
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
        -- Called as ListMenu.new(game, title, items, opts) — no self.
        new = function(game, title, items, opts)
          return { title = title, items = items, opts = opts, close = function() end }
        end,
      },
      push = function() end,
      insertBefore = function(items, before, entry)
        local out = {}
        for _, it in ipairs(items) do
          if it.label == before or it.id == before:lower() then
            out[#out + 1] = entry
          end
          out[#out + 1] = it
        end
        -- Also match MODS by id.
        if before == "MODS" then
          out = {}
          local inserted = false
          for _, it in ipairs(items) do
            if (it.label == "MODS" or it.id == "mods") and not inserted then
              out[#out + 1] = entry
              inserted = true
            end
            out[#out + 1] = it
          end
          if not inserted then out[#out + 1] = entry end
          return out
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
    refreshAllEntitySprites = function() return 0 end,
    invalidateAssetCache = function() end,
  },
}, nil, nil)
menus:register()

eq(SettingsMenus.LABEL_FOLLOWERS, "POKE FOLLOW EX", "followers EX label")
eq(SettingsMenus.LABEL_WILDS, "WILDS OF KANTO", "wilds label")
check(#SettingsMenus.LABEL_FOLLOWERS <= 14, "followers label ≤14")
check(#SettingsMenus.LABEL_WILDS <= 14, "wilds label ≤14")
check(screens[SettingsMenus.SCREEN_FOLLOWERS] ~= nil, "followers screen registered")
check(screens[SettingsMenus.SCREEN_WILDS] ~= nil, "wilds screen registered")
check(wrappedHooks["ui.options.rows"] == true, "OPTIONS rows hook installed")
check(wrappedHooks["ui.start_menu.items"] ~= true, "no Start Menu top-level hook")
check(startItems == nil, "Start Menu items untouched")
check(optionsRows ~= nil, "OPTIONS rows produced")

local labels = {}
for _, it in ipairs(optionsRows or {}) do
  labels[#labels + 1] = it.label
end
local joined = table.concat(labels, ",")
check(joined:find("POKE FOLLOW EX", 1, true), "OPTIONS has Poke Followers EX")
check(joined:find("WILDS OF KANTO", 1, true), "OPTIONS has Wilds of Kanto")

-- No duplicates
local countFollow, countWilds = 0, 0
for _, it in ipairs(optionsRows or {}) do
  if it.label == "POKE FOLLOW EX" then countFollow = countFollow + 1 end
  if it.label == "WILDS OF KANTO" then countWilds = countWilds + 1 end
end
eq(countFollow, 1, "no duplicate Poke Followers EX row")
eq(countWilds, 1, "no duplicate Wilds of Kanto row")

-- Activate rows open screens
for _, it in ipairs(optionsRows or {}) do
  if it.label == "POKE FOLLOW EX" or it.label == "WILDS OF KANTO" then
    check(type(it.activate) == "function", it.label .. " has activate")
    check(it.value() == "OPEN", it.label .. " value OPEN")
  end
end

check(V.mod.options.set == nil, "no mod.options:set (engine parity)")

-- Shared keys: follower_count via Followers menu apply (canonical options path)
menus:_applyFollowerCount(game, 6)
eq(optionStore.follower_count, 6, "followers menu writes follower_count")
eq(Config.get(V.mod, "follower_count"), 6, "Config.get sees same follower_count")

local ok = Config.setSpriteStyle(V.mod, "followers", "options_menu", {
  game = game,
  logic = { render = { refreshAllEntitySprites = function() end } },
  confirm = false,
})
check(ok == true, "setSpriteStyle from wilds menu path")
eq(optionStore.sprite_style, "followers", "sprite_style shared key updated")

menus:_applyControlMode(game, "pokemon")
eq(optionStore.follow_control, "pokemon", "control mode shared key")
menus:_applyTrainerTrail(game, true)
eq(optionStore.trainer_trail, true, "trainer trail shared key")

-- Menus map onto existing options.lua keys (no parallel persistence)
local schema = assert(loadfile("options.lua"))()
local keys = {}
for _, row in ipairs(schema) do keys[row.key] = true end
for _, k in ipairs(SettingsMenus.FOLLOWERS_OPTION_KEYS) do
  check(keys[k], "followers key in schema: " .. k)
end
for _, k in ipairs(SettingsMenus.WILDS_OPTION_KEYS) do
  check(keys[k], "wilds key in schema: " .. k)
end

-- Followers root: control options only (Sprite Color removed in 1.11.1)
local followRoot = menus:_openFollowersRoot(game)
local flabels = {}
for _, it in ipairs(followRoot.items) do flabels[#flabels + 1] = it.label end
local fjoin = table.concat(flabels, ",")
check(fjoin:find("FOLLOWERS", 1, true), "followers menu has Followers count")
check(fjoin:find("CONTROL MODE", 1, true), "followers menu has Control Mode")
check(fjoin:find("TRAINER TRAIL", 1, true), "followers menu has Trainer Trail")
check(not fjoin:find("SPRITE COLOR", 1, true), "no Sprite Color entry")
check(not fjoin:find("BOX LEADER", 1, true), "no unimplemented Box Leader")
-- Root right-label reads live options after apply
local countRight
for _, it in ipairs(followRoot.items) do
  if it.label == "FOLLOWERS" then countRight = it.right end
end
eq(countRight, "6", "followers root shows updated count")
-- Nested rows carry screen ids for close-then-push navigation
local hasScreen = false
for _, it in ipairs(followRoot.items) do
  if it.label == "FOLLOWERS" and it.screen then hasScreen = true end
end
check(hasScreen, "FOLLOWERS row has screen id for push")

-- Wilds root includes fade + town
local wildsRoot = menus:_openWildsRoot(game)
local wlabels = {}
for _, it in ipairs(wildsRoot.items) do wlabels[#wlabels + 1] = it.label end
local wjoin = table.concat(wlabels, ",")
check(wjoin:find("SPRITE FADE", 1, true), "wilds menu has Sprite Fade")
check(wjoin:find("TOWN POKEMON", 1, true), "wilds menu has Town Pokémon")
check(not wjoin:find("CONTROL MODE", 1, true), "no follower control in wilds menu")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("settings_menus_unit_test: all passed")
