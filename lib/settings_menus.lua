-- In-game OPTIONS / Start Menu submenus for Wilds.
--
-- Two top-level entries share the same mod.options keys as Mod Settings:
--   FOLLOWERS EX  → follower control options
--   WILDS OF KANTO → wild spawn / sprite / overlay options
--
-- No duplicate save keys. Labels stay ≤14 characters (Gen1Recomp truncates).
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

local function optSet(mod, key, value)
  if mod and mod.options and type(mod.options.set) == "function" then
    local ok = pcall(function() mod.options:set(key, value) end)
    if ok then return true end
  end
  return false
end

function SettingsMenus.new(mod, logic, follower)
  local self = setmetatable({}, SettingsMenus)
  self.mod = mod
  self.logic = logic
  self.follower = follower
  self._registered = false
  return self
end

function SettingsMenus:_settings()
  return self.follower and self.follower.settings
end

function SettingsMenus:_openChoice(game, title, choices, current, apply)
  local mod = self.mod
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
      if item and item.value ~= nil then
        apply(item.value)
      end
      if menu and menu.close then menu:close() end
    end,
  })
end

function SettingsMenus:_applyControlMode(game, value)
  optSet(self.mod, "follow_control", value)
  local settings = self:_settings()
  if settings and settings.setEngineMode then
    local mode = "follow"
    if value == "pokemon" then
      local trail = optGet(self.mod, "trainer_trail", false) == true
      local n = tonumber(optGet(self.mod, "follower_count", 1)) or 1
      if trail then mode = "lead_trainer"
      elseif n > 0 then mode = "pack"
      else mode = "pokemon" end
    end
    pcall(settings.setEngineMode, settings, game, mode)
  end
  if self.follower and self.follower.control then
    pcall(function()
      self.follower.control:alignSaveFromOptions(game)
      self.follower.control:syncAll(game, game and game.overworld)
    end)
  end
end

function SettingsMenus:_applyTrainerTrail(game, value)
  optSet(self.mod, "trainer_trail", value == true)
  local settings = self:_settings()
  if settings and settings.setEngineMode then
    local ui = optGet(self.mod, "follow_control", "trainer")
    if ui == "pokemon" then
      local n = tonumber(optGet(self.mod, "follower_count", 1)) or 1
      local mode = (value == true) and "lead_trainer"
        or ((n > 0) and "pack" or "pokemon")
      pcall(settings.setEngineMode, settings, game, mode)
    end
  end
  if self.follower and self.follower.control then
    pcall(function()
      self.follower.control:alignSaveFromOptions(game)
      self.follower.control:syncAll(game, game and game.overworld)
    end)
  end
end

function SettingsMenus:_applyFollowerCount(game, value)
  local n = tonumber(value) or 1
  local settings = self:_settings()
  if settings and settings.setFollowerCount then
    pcall(settings.setFollowerCount, settings, game, n)
  else
    optSet(self.mod, "follower_count", n)
  end
  if self.follower and self.follower.control then
    pcall(function()
      self.follower.control:setFollowerCount(game, n)
      self.follower.control:syncAll(game, game and game.overworld)
    end)
  end
end

function SettingsMenus:_openFollowersRoot(game)
  local mod = self.mod
  local control = optGet(mod, "follow_control", "trainer")
  local trail = optGet(mod, "trainer_trail", false) == true
  local count = tonumber(optGet(mod, "follower_count", 1)) or 1
  local items = {
    {
      label = "CONTROL MODE",
      onSelect = function()
        mod.ui.push(game, SettingsMenus.SCREEN_FOLLOWERS .. ":control")
      end,
      right = tostring(control):upper(),
    },
    {
      label = "TRAINER TRAIL",
      onSelect = function()
        mod.ui.push(game, SettingsMenus.SCREEN_FOLLOWERS .. ":trail")
      end,
      right = trail and "ON" or "OFF",
    },
    {
      label = "FOLLOWERS",
      onSelect = function()
        mod.ui.push(game, SettingsMenus.SCREEN_FOLLOWERS .. ":count")
      end,
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
  items[#items + 1] = { label = "CANCEL", onSelect = function() end }

  return mod.ui.ListMenu.new(game, SettingsMenus.LABEL_FOLLOWERS, items, {
    onChoose = function(item, menu)
      if item and item.onSelect then item.onSelect() end
      if menu and menu.close then menu:close() end
    end,
  })
end

function SettingsMenus:_openWildsRoot(game)
  local mod = self.mod
  local enabled = optGet(mod, "enabled", true) ~= false
  local style = Config.spriteStyle(mod)
  local spawn = Config.spawnAmount(mod)
  local random = Config.randomEncountersEnabled(mod)
  local water = Config.waterDisplayMode(mod)
  local cave = tostring(optGet(mod, "cave_spawns", "reachable") or "reachable")
  local dev = Config.devOverlay(mod) == true

  local items = {
    {
      label = "SHOW WILD MONS",
      onSelect = function()
        mod.ui.push(game, SettingsMenus.SCREEN_WILDS .. ":enabled")
      end,
      right = enabled and "ON" or "OFF",
    },
    {
      label = "SPAWN AMOUNT",
      onSelect = function()
        mod.ui.push(game, SettingsMenus.SCREEN_WILDS .. ":spawn")
      end,
      right = tostring(spawn):upper():gsub("_", " "),
    },
    {
      label = "RANDOM ENC",
      onSelect = function()
        mod.ui.push(game, SettingsMenus.SCREEN_WILDS .. ":random")
      end,
      right = random and "ON" or "OFF",
    },
    {
      label = "WATER MONS",
      onSelect = function()
        mod.ui.push(game, SettingsMenus.SCREEN_WILDS .. ":water")
      end,
      right = tostring(water):upper():sub(1, 10),
    },
    {
      label = "CAVE SPAWNS",
      onSelect = function()
        mod.ui.push(game, SettingsMenus.SCREEN_WILDS .. ":cave")
      end,
      right = cave:upper():sub(1, 10),
    },
    {
      label = "SPRITE STYLE",
      onSelect = function()
        mod.ui.push(game, SettingsMenus.SCREEN_WILDS .. ":style")
      end,
      right = (style == "followers" and "FOLLOW/GSC")
        or (style == "pokedex" and "POKEDEX")
        or "HGSS",
    },
    {
      label = "DEV OVERLAY",
      onSelect = function()
        mod.ui.push(game, SettingsMenus.SCREEN_WILDS .. ":dev")
      end,
      right = dev and "ON" or "OFF",
    },
    {
      label = "TEST SPAWN",
      onSelect = function()
        if mod.ui and mod.ui.push then
          pcall(mod.ui.push, mod.ui, game, "OverworldSpawnPreview")
        end
      end,
      right = "OPEN",
    },
  }
  items[#items + 1] = { label = "CANCEL", onSelect = function() end }

  return mod.ui.ListMenu.new(game, SettingsMenus.LABEL_WILDS, items, {
    onChoose = function(item, menu)
      if item and item.onSelect then item.onSelect() end
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
        optSet(mod, "enabled", v == true)
        if menus.logic and menus.logic.onOptionsChanged then
          pcall(menus.logic.onOptionsChanged, menus.logic, { mod = mod.id })
        end
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
        Config.setSpawnAmount(mod, v, "start_menu", {
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
        Config.setRandomEncounters(mod, v, "start_menu", {
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
        Config.setWaterMons(mod, v, "start_menu", {
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
        optSet(mod, "cave_spawns", v)
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
        Config.setSpriteStyle(mod, v, "start_menu", {
          game = game,
          logic = menus.logic,
          render = menus.logic and menus.logic.render,
          confirm = true,
        })
      end)
    end,
  })
  mod.content.screens:register(SettingsMenus.SCREEN_WILDS .. ":dev", {
    new = function(game)
      return menus:_openChoice(game, "DEV OVERLAY", {
        { label = "OFF", value = false },
        { label = "ON", value = true },
      }, Config.devOverlay(mod) == true, function(v)
        optSet(mod, "dev_overlay", v == true)
      end)
    end,
  })

  if mod.hooks and mod.hooks.wrap then
    mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
      local out = next(game, items)
      if type(out) ~= "table" then return out end
      local function add(label, screen)
        local row = {
          label = label,
          onSelect = function()
            if mod.ui and mod.ui.push then
              mod.ui.push(game, screen)
            end
          end,
        }
        if mod.ui and type(mod.ui.insertBefore) == "function" then
          out = mod.ui.insertBefore(out, "OPTION", row) or out
        else
          out[#out + 1] = row
        end
      end
      add(SettingsMenus.LABEL_FOLLOWERS, SettingsMenus.SCREEN_FOLLOWERS)
      add(SettingsMenus.LABEL_WILDS, SettingsMenus.SCREEN_WILDS)
      return out
    end)
  end

  self._registered = true
  if Config.debug(mod) then
    DebugLog.info(mod, "in-game FOLLOWERS EX + WILDS OF KANTO menus registered")
  end
end

return SettingsMenus
