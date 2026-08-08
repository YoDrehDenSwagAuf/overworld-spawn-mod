-- In-game OPTIONS submenus for Wilds.
--
-- START → OPTIONS →
--   POKE FOLLOW EX  → follower control options
--   WILDS OF KANTO  → wild spawn / sprite / ambient / overlay options
--
-- Both share the same mod.options keys as Mod Settings.
-- No duplicate save keys. No top-level START menu entries.
-- Labels stay ≤14 characters (Gen1Recomp truncates).
local V = ...
local Config = V.require("config")
local DebugLog = V.require("debug_log")

local SettingsMenus = {}
SettingsMenus.__index = SettingsMenus

SettingsMenus.SCREEN_FOLLOWERS = "overworld_wild_spawns:followers_ex_menu"
SettingsMenus.SCREEN_WILDS = "overworld_wild_spawns:wilds_menu"

-- Gen1 ListMenu truncates past 14 characters; full names live in README.
SettingsMenus.LABEL_FOLLOWERS = "POKE FOLLOW EX"
SettingsMenus.LABEL_WILDS = "WILDS OF KANTO"

-- OPTIONS activate-row labels (same 14-char budget).
SettingsMenus.OPTIONS_LABEL_FOLLOWERS = "POKE FOLLOW EX"
SettingsMenus.OPTIONS_LABEL_WILDS = "WILDS OF KANTO"

local function markCurrent(label, isCurrent)
  if not isCurrent then return label end
  local marked = "> " .. label
  if #marked > 14 then marked = ">" .. label end
  if #marked > 14 then return label end
  return marked
end

local function optGet(mod, key, default)
  if Config and type(Config.get) == "function" then
    local v = Config.get(mod, key)
    if v ~= nil then return v end
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local v = mod.options:get(key)
    if v ~= nil then return v end
  end
  return default
end

function SettingsMenus.new(mod, logic, follower, ambient)
  local self = setmetatable({}, SettingsMenus)
  self.mod = mod
  self.logic = logic
  self.follower = follower
  self.ambient = ambient
  self._onOptionsChanged = nil -- injected from main.lua (canonical handler)
  self._registered = false
  return self
end

--- Wire the exact same handler main.lua binds to mod.options_changed.
function SettingsMenus:setOptionsChangedHandler(fn)
  self._onOptionsChanged = fn
end

function SettingsMenus:_settings()
  return self.follower and self.follower.settings
end

function SettingsMenus:_resolveGame(game)
  if game then return game end
  local mod = self.mod
  if mod and mod.world then return mod.world.game end
  return nil
end

function SettingsMenus:_menuLog(fmt, ...)
  local mod = self.mod
  if not (Config and Config.debug and Config.debug(mod)) then return end
  DebugLog.info(mod, "[FollowerMenu] " .. fmt, ...)
end

--- Canonical writer for in-game OPTIONS menus.
-- Gen1Recomp has no mod.options:set. Writes loader/save option buckets via
-- Config.setOption (same storage Mod Manager uses), then invokes the shared
-- handleOptionsChanged from main.lua — not a reimplementation.
function SettingsMenus:_setOption(key, value, game)
  local mod = self.mod
  game = self:_resolveGame(game)
  local before = optGet(mod, key, nil)
  self:_menuLog("set %s: before=%s after=%s game=%s",
                tostring(key), tostring(before), tostring(value),
                tostring(game ~= nil))
  local ok = Config.setOption(mod, key, value, "options_menu", {
    game = game,
    onChanged = self._onOptionsChanged,
  })
  local after = optGet(mod, key, nil)
  self:_menuLog("set %s resolved=%s wrote=%s",
                tostring(key), tostring(after), tostring(ok))
  return ok == true
end

function SettingsMenus:_notifyLogic(key, value, game)
  -- Legacy name kept for callers; routes through canonical setter path
  -- only when the option was already written. Prefer _setOption.
  if self._onOptionsChanged then
    pcall(self._onOptionsChanged, {
      mod = self.mod.id, key = key, value = value,
      source = "options_menu", game = self:_resolveGame(game),
    })
  elseif self.logic and self.logic.onOptionsChanged then
    pcall(self.logic.onOptionsChanged, self.logic, {
      mod = self.mod.id, key = key, value = value, source = "options_menu",
    })
  end
end

--- ListMenu close-then-push: Gen1Recomp ListMenu:close() only pops when the
-- menu is stack top. Pushing a child first makes close() a no-op and leaves
-- a stale parent under the child.
function SettingsMenus:_pushScreen(game, screenId, menu)
  local mod = self.mod
  self:_menuLog("push %s (close parent first)", tostring(screenId))
  if menu and menu.close then menu:close() end
  if mod.ui and mod.ui.push then
    mod.ui.push(game, screenId)
  end
end

function SettingsMenus:_openChoice(game, title, choices, current, apply)
  local mod = self.mod
  local menus = self
  local items = {}
  for _, choice in ipairs(choices) do
    items[#items + 1] = {
      label = markCurrent(choice.label, choice.value == current),
      value = choice.value,
    }
  end
  items[#items + 1] = { label = "CANCEL", value = nil }
  return mod.ui.ListMenu.new(game, title, items, {
    onChoose = function(item, menu)
      -- Keep 0 / false: only nil means CANCEL.
      if item and item.value ~= nil then
        menus:_menuLog("choice %s -> %s", tostring(title), tostring(item.value))
        apply(item.value)
      end
      if menu and menu.close then menu:close() end
    end,
  })
end

function SettingsMenus:_applyControlMode(game, value)
  self:_setOption("follow_control", value, game)
end

function SettingsMenus:_applyTrainerTrail(game, value)
  self:_setOption("trainer_trail", value == true, game)
end

function SettingsMenus:_applyFollowerCount(game, value)
  local n = tonumber(value) or 1
  local settings = self:_settings()
  if settings and settings.clampCount then
    n = settings.clampCount(n)
  else
    n = math.max(0, math.min(6, math.floor(n)))
  end
  self:_setOption("follower_count", n, game)
end

function SettingsMenus:_openFollowersRoot(game)
  local mod = self.mod
  local menus = self
  local control = optGet(mod, "follow_control", "trainer")
  local trail = optGet(mod, "trainer_trail", false) == true
  local count = tonumber(optGet(mod, "follower_count", 1)) or 1
  self:_menuLog("open root control=%s trail=%s count=%s",
                tostring(control), tostring(trail), tostring(count))
  local items = {
    {
      label = "CONTROL MODE",
      screen = SettingsMenus.SCREEN_FOLLOWERS .. ":control",
      right = tostring(control):upper(),
    },
    {
      label = "TRAINER TRAIL",
      screen = SettingsMenus.SCREEN_FOLLOWERS .. ":trail",
      right = trail and "ON" or "OFF",
    },
    {
      label = "FOLLOWERS",
      screen = SettingsMenus.SCREEN_FOLLOWERS .. ":count",
      right = tostring(count),
    },
  }
  -- Leader is available via party submenu; surface a hint only.
  items[#items + 1] = {
    label = "LEADER",
    onSelect = function()
      if game and game.ui and game.ui.message then
        pcall(game.ui.message, game.ui, "USE PARTY MENU")
      end
    end,
    right = "PARTY",
  }
  items[#items + 1] = { label = "CANCEL" }

  return mod.ui.ListMenu.new(game, SettingsMenus.LABEL_FOLLOWERS, items, {
    onChoose = function(item, menu)
      if not item then return end
      menus:_menuLog("root choose: %s", tostring(item.label))
      if item.screen then
        menus:_pushScreen(game, item.screen, menu)
        return
      end
      if type(item.onSelect) == "function" then
        if menu and menu.close then menu:close() end
        item.onSelect()
        return
      end
      if menu and menu.close then menu:close() end
    end,
  })
end

function SettingsMenus:_openWildsRoot(game)
  local mod = self.mod
  local enabled = optGet(mod, "enabled", true) ~= false
  local style = Config.spriteStyle(mod)
  local fade = Config.spriteFade(mod)
  local spawn = Config.spawnAmount(mod)
  local random = Config.randomEncountersEnabled(mod)
  local water = Config.waterDisplayMode(mod)
  local cave = tostring(optGet(mod, "cave_spawns", "reachable") or "reachable")
  local town = Config.townPokemonEnabled(mod)
  local grass = Config.pokemonGrassRenderMode(mod)
  local idle = optGet(mod, "enable_idle", true) ~= false
  local roam = optGet(mod, "enable_wander", true) ~= false
  local chase = optGet(mod, "enable_aggressive", true) ~= false
  local hidden = optGet(mod, "enable_hidden", true) ~= false
  local dev = Config.devOverlay(mod) == true

  local menus = self
  local items = {
    {
      label = "SHOW WILD MONS",
      screen = SettingsMenus.SCREEN_WILDS .. ":enabled",
      right = enabled and "ON" or "OFF",
    },
    {
      label = "SPAWN AMOUNT",
      screen = SettingsMenus.SCREEN_WILDS .. ":spawn",
      right = tostring(spawn):upper():gsub("_", " "),
    },
    {
      label = "RANDOM ENC",
      screen = SettingsMenus.SCREEN_WILDS .. ":random",
      right = random and "ON" or "OFF",
    },
    {
      label = "WATER MONS",
      screen = SettingsMenus.SCREEN_WILDS .. ":water",
      right = tostring(water):upper():sub(1, 10),
    },
    {
      label = "CAVE SPAWNS",
      screen = SettingsMenus.SCREEN_WILDS .. ":cave",
      right = cave:upper():sub(1, 10),
    },
    {
      label = "SPRITE STYLE",
      screen = SettingsMenus.SCREEN_WILDS .. ":style",
      right = (style == "followers" and "FOLLOW/GSC")
        or (style == "pokedex" and "POKEDEX")
        or "HGSS",
    },
    {
      label = "SPRITE FADE",
      screen = SettingsMenus.SCREEN_WILDS .. ":fade",
      right = (fade == "faded") and "FADED" or "SOLID",
    },
    {
      label = "TOWN POKEMON",
      screen = SettingsMenus.SCREEN_WILDS .. ":town",
      right = town and "ON" or "OFF",
    },
    {
      label = "GRASS VIEW",
      screen = SettingsMenus.SCREEN_WILDS .. ":grass",
      right = (grass == "above") and "ABOVE" or "IMMERSED",
    },
    {
      label = "IDLE MONS",
      screen = SettingsMenus.SCREEN_WILDS .. ":idle",
      right = idle and "ON" or "OFF",
    },
    {
      label = "ROAM MONS",
      screen = SettingsMenus.SCREEN_WILDS .. ":roam",
      right = roam and "ON" or "OFF",
    },
    {
      label = "CHASE MONS",
      screen = SettingsMenus.SCREEN_WILDS .. ":chase",
      right = chase and "ON" or "OFF",
    },
    {
      label = "HIDDEN MONS",
      screen = SettingsMenus.SCREEN_WILDS .. ":hidden",
      right = hidden and "ON" or "OFF",
    },
    {
      label = "DEV OVERLAY",
      screen = SettingsMenus.SCREEN_WILDS .. ":dev",
      right = dev and "ON" or "OFF",
    },
    {
      label = "TEST SPAWN",
      onSelect = function()
        if mod.ui and mod.ui.push then
          -- Preview browser id may be registered as a content screen.
          pcall(mod.ui.push, game, "OverworldSpawnPreview")
        end
      end,
      right = "OPEN",
    },
  }
  items[#items + 1] = { label = "CANCEL" }

  return mod.ui.ListMenu.new(game, SettingsMenus.LABEL_WILDS, items, {
    onChoose = function(item, menu)
      if not item then return end
      if item.screen then
        menus:_pushScreen(game, item.screen, menu)
        return
      end
      if type(item.onSelect) == "function" then
        if menu and menu.close then menu:close() end
        item.onSelect()
        return
      end
      if menu and menu.close then menu:close() end
    end,
  })
end

function SettingsMenus:register()
  if self._registered then return end
  local mod = self.mod
  local menus = self

  if not (mod.content and mod.content.screens and mod.content.screens.register) then
    return
  end
  if not (mod.ui and mod.ui.ListMenu and mod.ui.ListMenu.new) then
    DebugLog.warn(mod, "settings menus skipped: ListMenu unavailable")
    return
  end

  mod.content.screens:register(SettingsMenus.SCREEN_FOLLOWERS, {
    new = function(game) return menus:_openFollowersRoot(game) end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_FOLLOWERS .. ":control", {
    new = function(game)
      return menus:_openChoice(game, "CONTROL MODE", {
        { label = "TRAINER", value = "trainer" },
        { label = "POKEMON", value = "pokemon" },
      }, optGet(mod, "follow_control", "trainer"), function(v)
        menus:_applyControlMode(game, v)
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_FOLLOWERS .. ":trail", {
    new = function(game)
      return menus:_openChoice(game, "TRAINER TRAIL", {
        { label = "OFF", value = false },
        { label = "ON", value = true },
      }, optGet(mod, "trainer_trail", false) == true, function(v)
        menus:_applyTrainerTrail(game, v)
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_FOLLOWERS .. ":count", {
    new = function(game)
      local choices = {}
      for i = 0, 6 do
        choices[#choices + 1] = { label = tostring(i), value = i }
      end
      return menus:_openChoice(game, "FOLLOWERS", choices,
        tonumber(optGet(mod, "follower_count", 1)) or 1, function(v)
          menus:_applyFollowerCount(game, v)
        end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS, {
    new = function(game) return menus:_openWildsRoot(game) end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":enabled", {
    new = function(game)
      return menus:_openChoice(game, "SHOW WILD MONS", {
        { label = "ON", value = true },
        { label = "OFF", value = false },
      }, optGet(mod, "enabled", true) ~= false, function(v)
        menus:_setOption("enabled", v == true, game)
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":spawn", {
    new = function(game)
      return menus:_openChoice(game, "SPAWN AMOUNT", {
        { label = "LOW", value = "low" },
        { label = "NORMAL", value = "normal" },
        { label = "HIGH", value = "high" },
        { label = "VERY HIGH", value = "very_high" },
      }, Config.spawnAmount(mod), function(v)
        Config.setSpawnAmount(mod, v, "options_menu", {
          game = game, logic = menus.logic, confirm = true,
        })
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":random", {
    new = function(game)
      return menus:_openChoice(game, "RANDOM ENC", {
        { label = "ON", value = true },
        { label = "OFF", value = false },
      }, Config.randomEncountersEnabled(mod), function(v)
        Config.setRandomEncounters(mod, v, "options_menu", {
          game = game, logic = menus.logic, confirm = true,
        })
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":water", {
    new = function(game)
      return menus:_openChoice(game, "WATER MONS", {
        { label = "SWIM SPRITES", value = "swimming_sprites" },
        { label = "HID SILHOUETTE", value = "hidden_silhouettes" },
        { label = "SILHOUETTES", value = "silhouettes" },
        { label = "CLASSIC ENC", value = "classic_encounters" },
        { label = "DISABLED", value = "disabled" },
      }, Config.waterDisplayMode(mod), function(v)
        Config.setWaterMons(mod, v, "options_menu", {
          game = game, logic = menus.logic, confirm = true,
        })
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":cave", {
    new = function(game)
      return menus:_openChoice(game, "CAVE SPAWNS", {
        { label = "REACHABLE", value = "reachable" },
        { label = "MIXED", value = "mixed" },
      }, tostring(optGet(mod, "cave_spawns", "reachable") or "reachable"), function(v)
        Config.setCaveSpawnMode(mod, v, "options_menu", {
          game = game, logic = menus.logic, confirm = true,
        })
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":style", {
    new = function(game)
      return menus:_openChoice(game, "SPRITE STYLE", {
        { label = "FOLLOWERS/GSC", value = "followers" },
        { label = "HGSS / POKEMMO", value = "pokemmo" },
        { label = "POKEDEX", value = "pokedex" },
      }, Config.spriteStyle(mod), function(v)
        Config.setSpriteStyle(mod, v, "options_menu", {
          game = game,
          logic = menus.logic,
          render = menus.logic and menus.logic.render,
          confirm = true,
        })
        if menus.ambient and menus.ambient.refreshSprites then
          pcall(menus.ambient.refreshSprites, menus.ambient, game)
        end
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":fade", {
    new = function(game)
      return menus:_openChoice(game, "SPRITE FADE", {
        { label = "SOLID", value = "solid" },
        { label = "FADED", value = "faded" },
      }, Config.spriteFade(mod), function(v)
        Config.setSpriteFade(mod, v, "options_menu", {
          game = game, logic = menus.logic, confirm = true,
        })
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":town", {
    new = function(game)
      return menus:_openChoice(game, "TOWN POKEMON", {
        { label = "ON", value = true },
        { label = "OFF", value = false },
      }, Config.townPokemonEnabled(mod), function(v)
        Config.setTownPokemon(mod, v, "options_menu", {
          game = game, ambient = menus.ambient, confirm = true,
        })
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":grass", {
    new = function(game)
      return menus:_openChoice(game, "GRASS VIEW", {
        { label = "ABOVE", value = "above" },
        { label = "IMMERSED", value = "immersed" },
      }, Config.pokemonGrassRenderMode(mod), function(v)
        menus:_setOption("pokemon_grass_render_mode", v, game)
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":idle", {
    new = function(game)
      return menus:_openChoice(game, "IDLE MONS", {
        { label = "ON", value = true },
        { label = "OFF", value = false },
      }, optGet(mod, "enable_idle", true) ~= false, function(v)
        menus:_setOption("enable_idle", v == true, game)
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":roam", {
    new = function(game)
      return menus:_openChoice(game, "ROAM MONS", {
        { label = "ON", value = true },
        { label = "OFF", value = false },
      }, optGet(mod, "enable_wander", true) ~= false, function(v)
        menus:_setOption("enable_wander", v == true, game)
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":chase", {
    new = function(game)
      return menus:_openChoice(game, "CHASE MONS", {
        { label = "ON", value = true },
        { label = "OFF", value = false },
      }, optGet(mod, "enable_aggressive", true) ~= false, function(v)
        menus:_setOption("enable_aggressive", v == true, game)
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":hidden", {
    new = function(game)
      return menus:_openChoice(game, "HIDDEN MONS", {
        { label = "ON", value = true },
        { label = "OFF", value = false },
      }, optGet(mod, "enable_hidden", true) ~= false, function(v)
        menus:_setOption("enable_hidden", v == true, game)
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":dev", {
    new = function(game)
      return menus:_openChoice(game, "DEV OVERLAY", {
        { label = "OFF", value = false },
        { label = "ON", value = true },
      }, Config.devOverlay(mod) == true, function(v)
        menus:_setOption("dev_overlay", v == true, game)
      end)
    end,
  })

  -- START → OPTIONS only (no top-level START entries).
  if mod.hooks and mod.hooks.wrap then
    mod.hooks:wrap("ui.options.rows", function(next, game, rows)
      local out = next(game, rows)
      if type(out) ~= "table" then return out end
      local function add(label, screen, id)
        local row = {
          id = id,
          label = label,
          value = function() return "OPEN" end,
          activate = function(g)
            if mod.ui and mod.ui.push then
              mod.ui.push(g, screen)
            end
          end,
        }
        if mod.ui and type(mod.ui.insertBefore) == "function" then
          out = mod.ui.insertBefore(out, "MODS", row) or out
        else
          out[#out + 1] = row
        end
      end
      add(SettingsMenus.OPTIONS_LABEL_FOLLOWERS, SettingsMenus.SCREEN_FOLLOWERS,
          "overworld_wild_spawns:followers_ex_open")
      add(SettingsMenus.OPTIONS_LABEL_WILDS, SettingsMenus.SCREEN_WILDS,
          "overworld_wild_spawns:wilds_open")
      return out
    end)
  end

  self._registered = true
  if Config.debug(mod) then
    DebugLog.info(mod, "OPTIONS menus registered: POKE FOLLOW EX + WILDS OF KANTO")
  end
end

-- Keys shown in each submenu (for tests / docs).
SettingsMenus.FOLLOWERS_OPTION_KEYS = {
  "follow_control", "trainer_trail", "follower_count",
}
SettingsMenus.WILDS_OPTION_KEYS = {
  "enabled", "spawn_density", "random_encounters", "water_spawns",
  "cave_spawns", "sprite_style", "sprite_fade", "town_pokemon",
  "pokemon_grass_render_mode", "enable_idle", "enable_wander",
  "enable_aggressive", "enable_hidden", "dev_overlay",
}

return SettingsMenus
