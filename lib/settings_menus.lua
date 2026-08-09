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

local function optSet(mod, key, value)
  if Config and type(Config.setOption) == "function" then
    return Config.setOption(mod, key, value, "options_menu")
  end
  if mod and mod.options and type(mod.options.set) == "function" then
    return mod.options:set(key, value)
  end
  return false
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

--- Create a ListMenu where stepper rows cycle values on left/right arrow keys.
-- Each item may be a stepper (with .choices, .current, .apply) or a plain
-- action row (with .onSelect).
function SettingsMenus:_makeStepperMenu(game, title, items, mod)
  local menus = self

  local menu = mod.ui.ListMenu.new(game, title, items, {
    onChoose = function(item, m)
      -- Cycle forward +1 when "A" / Confirm is pressed on a stepper item
      if item and item.stepper then
        menus:_stepItem(item, 1)
        return
      end

      if item and item.onSelect then
        item.onSelect()
        if m and m.close then m:close() end
      end
    end,
  })

  if not (menu and type(menu.update) == "function") then
    return menu
  end

  local heldLeft, heldRight = false, false

  local INITIAL_DELAY = 0.50
  local REPEAT_INTERVAL = 0.50

  local function isNavDown(dir)
    local input = game and game.input or (mod and mod.input)

    -- 1. Query Engine Input System
    if input then
      local downFunc = type(input.down) == "function" and function(k) return input:down(k) end
                    or type(input.isDown) == "function" and function(k) return input:isDown(k) end

      if downFunc then
        local aliases = dir == "left" 
          and { "left", "ui_left", "menu_left", "move_left", "dpleft" }
          or  { "right", "ui_right", "menu_right", "move_right", "dpright" }

        for _, alias in ipairs(aliases) do
          if downFunc(alias) then return true end
        end
      end
    end

    -- 2. Fallback: Query LÖVE Gamepad
    if love and love.joystick then
      for _, js in ipairs(love.joystick.getJoysticks()) do
        if js:isGamepad() then
          local btn = (dir == "left") and "dpleft" or "dpright"
          if js:isGamepadDown(btn) then return true end

          local axisVal = js:getGamepadAxis("leftx")
          if dir == "left" and axisVal < -0.5 then return true end
          if dir == "right" and axisVal > 0.5 then return true end
        end
      end
    end

    -- 3. Fallback: Query LÖVE Keyboard
    if love and love.keyboard and love.keyboard.isDown then
      if love.keyboard.isDown(dir) then return true end
    end

    return false
  end

  local baseUpdate = menu.update
  menu.update = function(self, dt)
    local item = self.items and self.items[self.index]
    if not (item and item.stepper) then
      self._stepperHold = nil
      self._stepperTimer = 0
      return baseUpdate(self, dt)
    end

    local nowLeft = isNavDown("left")
    local nowRight = isNavDown("right")

    local dir
    if nowLeft and not heldLeft then
      dir = -1
    elseif nowRight and not heldRight then
      dir = 1
    end
    heldLeft, heldRight = nowLeft, nowRight

    -- Initial tap
    if dir then
      menus:_stepItem(item, dir)
      self._stepperHold = dir
      self._stepperTimer = 0
      return
    end

    -- Controlled hold-to-repeat
    local held = self._stepperHold
    if held and ((held == -1 and nowLeft) or (held == 1 and nowRight)) then
      self._stepperTimer = (self._stepperTimer or 0) + (dt or 0.016)

      if self._stepperTimer >= INITIAL_DELAY then
        menus:_stepItem(item, held)
        self._stepperTimer = INITIAL_DELAY - REPEAT_INTERVAL
      end
      return
    end

    self._stepperHold = nil
    self._stepperTimer = 0
    return baseUpdate(self, dt)
  end

  return menu
end

--- Cycle a stepper item's value left (-1) or right (+1) through its choices.
-- Defaults to wrapping so options cycle continuously forward or backward.
function SettingsMenus:_stepItem(item, dir)
  if not (item and item.choices and #item.choices > 0) then return end
  local cur = item.current
  local idx = 1
  for i, ch in ipairs(item.choices) do
    if ch.value == cur then idx = i; break end
  end
  local n = #item.choices
  local nextIdx

  -- Always wrap by default unless item.wrap is explicitly false
  if item.wrap ~= false then
    nextIdx = ((idx - 1 + dir) % n) + 1
  else
    nextIdx = idx + dir
    if nextIdx < 1 or nextIdx > n then return end
  end

  local chosen = item.choices[nextIdx]
  item.current = chosen.value
  item.right = chosen.label
  if item.apply then item.apply(chosen.value) end
end

function SettingsMenus:_applyControlMode(game, value)
  self:_setOption("follow_control", value, game)
end

function SettingsMenus:_applyTrainerTrail(game, value)
  self:_setOption("trainer_trail", value == true, game)
end

function SettingsMenus:_applyFollowerCount(game, value)
  local n = tonumber(value) or 1
  if self.mod.options and self.mod.options.set then
    self.mod.options:set("follower_count", n)
  end
  if self.follower and self.follower.control then
    local ctrl = self.follower.control
    ctrl:setFollowerCount(game, n)
    ctrl._optCache.follower_count = n
    if game and game.save then game.save.pokepcFollowerCount = n end
    local ctrlGame = ctrl:_game()
    if ctrlGame and ctrlGame ~= game and ctrlGame.save then
      ctrlGame.save.pokepcFollowerCount = n
    end
    local worldGame = self.mod.world and self.mod.world.game
    if worldGame and worldGame ~= game and worldGame ~= ctrlGame and worldGame.save then
      worldGame.save.pokepcFollowerCount = n
    end
  end
  self:_setOption("follower_count", n, game)
end

function SettingsMenus:_openFollowersRoot(game)
  local mod = self.mod
  local menus = self
  local control = optGet(mod, "follow_control", "trainer")
  local trail = optGet(mod, "trainer_trail", false) == true
  local count = tonumber(optGet(mod, "follower_count", 1)) or 1

  local countChoices = {}
  for i = 0, 6 do
    countChoices[#countChoices + 1] = { label = tostring(i), value = i }
  end

  local items = {
    {
      label = "CONTROL",
      stepper = true,
      wrap = true,
      choices = {
        { label = "TRAINER", value = "trainer" },
        { label = "POKEMON", value = "pokemon" },
      },
      current = control,
      right = tostring(control):upper(),
      apply = function(v) menus:_applyControlMode(game, v) end,
    },
    {
      label = "TRAIL",
      stepper = true,
      wrap = true,
      choices = {
        { label = "OFF", value = false },
        { label = "ON",  value = true  },
      },
      current = trail == true,
      right = trail and "ON" or "OFF",
      apply = function(v) menus:_applyTrainerTrail(game, v) end,
    },
    {
      label = "FOLLOWERS",
      stepper = true,
      wrap = true,
      choices = countChoices,
      current = count,
      right = tostring(count),
      apply = function(v) menus:_applyFollowerCount(game, v) end,
    },
    { label = "CANCEL", onSelect = function() end },
  }

  return menus:_makeStepperMenu(game, SettingsMenus.LABEL_FOLLOWERS, items, mod)
end

function SettingsMenus:_openWildsRoot(game)
  local mod = self.mod
  local menus = self

  local items = {
    {
      label = "SHOW WILD MONS",
      stepper = true,
      wrap = true,
      choices = { { label = "ON", value = true }, { label = "OFF", value = false } },
      current = optGet(mod, "enabled", true) ~= false,
      right = (optGet(mod, "enabled", true) ~= false) and "ON" or "OFF",
      apply = function(v)
        optSet(mod, "enabled", v == true)
        menus:_notifyLogic("enabled", v == true)
      end,
    },
    {
      label = "SPAWN AMT",
      stepper = true,
      wrap = true,
      choices = {
        { label = "LOW",    value = "low" },
        { label = "NORM",   value = "normal" },
        { label = "HIGH",   value = "high" },
        { label = "V.HIGH", value = "very_high" },
      },
      current = Config.spawnAmount(mod),
      right = ({ low = "LOW", normal = "NORM", high = "HIGH", very_high = "V.HIGH" })[tostring(Config.spawnAmount(mod))] or "NORM",
      apply = function(v)
        Config.setSpawnAmount(mod, v, "options_menu", {
          game = game, logic = menus.logic, confirm = true,
        })
      end,
    },
    {
      label = "RANDOM ENC",
      stepper = true,
      wrap = true,
      choices = { { label = "ON", value = true }, { label = "OFF", value = false } },
      current = Config.randomEncountersEnabled(mod),
      right = Config.randomEncountersEnabled(mod) and "ON" or "OFF",
      apply = function(v)
        Config.setRandomEncounters(mod, v, "options_menu", {
          game = game, logic = menus.logic, confirm = true,
        })
      end,
    },
    {
      label = "WATER MONS",
      stepper = true,
      wrap = true,
      choices = {
        { label = "SWIM",    value = "swimming_sprites" },
        { label = "HIDDEN",  value = "hidden_silhouettes" },
        { label = "SILHOU",  value = "silhouettes" },
        { label = "CLASSIC", value = "classic_encounters" },
        { label = "OFF",     value = "disabled" },
      },
      current = Config.waterDisplayMode(mod),
      right = ({ swimming_sprites = "SWIM", hidden_silhouettes = "HIDDEN", silhouettes = "SILHOU", classic_encounters = "CLASSIC", disabled = "OFF" })[tostring(Config.waterDisplayMode(mod))] or "SWIM",
      apply = function(v)
        Config.setWaterMons(mod, v, "options_menu", {
          game = game, logic = menus.logic, confirm = true,
        })
      end,
    },
    {
      label = "CAVE",
      stepper = true,
      wrap = true,
      choices = {
        { label = "REACH", value = "reachable" },
        { label = "MIXED", value = "mixed" },
      },
      current = tostring(optGet(mod, "cave_spawns", "reachable") or "reachable"),
      right = ({ reachable = "REACH", mixed = "MIXED" })[tostring(optGet(mod, "cave_spawns", "reachable") or "reachable")] or "REACH",
      apply = function(v)
        Config.setCaveSpawnMode(mod, v, "options_menu", {
          game = game, logic = menus.logic, confirm = true,
        })
      end,
    },
    {
      label = "GFX STYLE",
      stepper = true,
      wrap = true,
      choices = {
        { label = "GSC",  value = "followers" },
        { label = "HGSS", value = "pokemmo" },
        { label = "DEX",  value = "pokedex" },
      },
      current = Config.spriteStyle(mod),
      right = ({ followers = "GSC", pokemmo = "HGSS", pokedex = "DEX" })[tostring(Config.spriteStyle(mod))] or "GSC",
      apply = function(v)
        Config.setSpriteStyle(mod, v, "options_menu", {
          game = game, logic = menus.logic,
          render = menus.logic and menus.logic.render, confirm = true,
        })
        if menus.ambient and menus.ambient.refreshSprites then
          pcall(menus.ambient.refreshSprites, menus.ambient, game)
        end
      end,
    },
    {
      label = "SPRITE FADE",
      stepper = true,
      wrap = true,
      choices = {
        { label = "SOLID", value = "solid" },
        { label = "FADED", value = "faded" },
      },
      current = Config.spriteFade(mod),
      right = (Config.spriteFade(mod) == "faded") and "FADED" or "SOLID",
      apply = function(v)
        Config.setSpriteFade(mod, v, "options_menu", {
          game = game, logic = menus.logic, confirm = true,
        })
      end,
    },
    {
      label = "TOWN POKEMON",
      stepper = true,
      wrap = true,
      choices = { { label = "ON", value = true }, { label = "OFF", value = false } },
      current = Config.townPokemonEnabled(mod),
      right = Config.townPokemonEnabled(mod) and "ON" or "OFF",
      apply = function(v)
        Config.setTownPokemon(mod, v, "options_menu", {
          game = game, ambient = menus.ambient, confirm = true,
        })
      end,
    },
    {
      label = "GRASS",
      stepper = true,
      wrap = true,
      choices = {
        { label = "OVER", value = "above" },
        { label = "IN",   value = "immersed" },
      },
      current = Config.pokemonGrassRenderMode(mod),
      right = ({ above = "OVER", immersed = "IN" })[tostring(Config.pokemonGrassRenderMode(mod))] or "OVER",
      apply = function(v)
        optSet(mod, "pokemon_grass_render_mode", v)
        menus:_notifyLogic("pokemon_grass_render_mode", v)
      end,
    },
    {
      label = "IDLE MONS",
      stepper = true,
      wrap = true,
      choices = { { label = "ON", value = true }, { label = "OFF", value = false } },
      current = optGet(mod, "enable_idle", true) ~= false,
      right = (optGet(mod, "enable_idle", true) ~= false) and "ON" or "OFF",
      apply = function(v)
        optSet(mod, "enable_idle", v == true)
        menus:_notifyLogic("enable_idle", v == true)
      end,
    },
    {
      label = "ROAM MONS",
      stepper = true,
      wrap = true,
      choices = { { label = "ON", value = true }, { label = "OFF", value = false } },
      current = optGet(mod, "enable_wander", true) ~= false,
      right = (optGet(mod, "enable_wander", true) ~= false) and "ON" or "OFF",
      apply = function(v)
        optSet(mod, "enable_wander", v == true)
        menus:_notifyLogic("enable_wander", v == true)
      end,
    },
    {
      label = "CHASE MONS",
      stepper = true,
      wrap = true,
      choices = { { label = "ON", value = true }, { label = "OFF", value = false } },
      current = optGet(mod, "enable_aggressive", true) ~= false,
      right = (optGet(mod, "enable_aggressive", true) ~= false) and "ON" or "OFF",
      apply = function(v)
        optSet(mod, "enable_aggressive", v == true)
        menus:_notifyLogic("enable_aggressive", v == true)
      end,
    },
    {
      label = "HIDDEN MONS",
      stepper = true,
      wrap = true,
      choices = { { label = "ON", value = true }, { label = "OFF", value = false } },
      current = optGet(mod, "enable_hidden", true) ~= false,
      right = (optGet(mod, "enable_hidden", true) ~= false) and "ON" or "OFF",
      apply = function(v)
        optSet(mod, "enable_hidden", v == true)
        menus:_notifyLogic("enable_hidden", v == true)
      end,
    },
    {
      label = "DEV OVERLAY",
      stepper = true,
      wrap = true,
      choices = { { label = "OFF", value = false }, { label = "ON", value = true } },
      current = Config.devOverlay(mod) == true,
      right = (Config.devOverlay(mod) == true) and "ON" or "OFF",
      apply = function(v)
        optSet(mod, "dev_overlay", v == true)
        menus:_notifyLogic("dev_overlay", v == true)
      end,
    },
    {
      label = "TEST SPAWN",
      onSelect = function()
        if mod.ui and mod.ui.push then
          pcall(mod.ui.push, game, "OverworldSpawnPreview")
        end
      end,
      right = "OPEN",
    },
    { label = "CANCEL", onSelect = function() end },
  }

  return menus:_makeStepperMenu(game, SettingsMenus.LABEL_WILDS, items, mod)
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