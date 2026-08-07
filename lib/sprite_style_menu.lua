-- Sprite Style choice helpers (shared confirm labels / availability checks).
-- Wilds gameplay settings live exclusively in Mod Settings now — this module
-- no longer injects SPRITE STYLE / SPAWN AMOUNT / RANDOM ENC / WATER MONS into
-- the normal Start / Pause menu.
--
-- Screens remain registered so Mod Settings / exports can still open them if
-- needed. Test Spawn uses the preview browser activate row instead.
local V = ...
local Config = V.require("config")
local DebugLog = V.require("debug_log")

local SpriteStyleMenu = {}
SpriteStyleMenu.__index = SpriteStyleMenu

SpriteStyleMenu.SCREEN_STYLE = "overworld_wild_spawns:sprite_style"
SpriteStyleMenu.SCREEN_SPAWN = "overworld_wild_spawns:spawn_amount"
SpriteStyleMenu.SCREEN_RANDOM = "overworld_wild_spawns:random_enc"
SpriteStyleMenu.SCREEN_WATER = "overworld_wild_spawns:water_mons"
-- Back-compat aliases.
SpriteStyleMenu.SCREEN = SpriteStyleMenu.SCREEN_STYLE
SpriteStyleMenu.SCREEN_GRASS = SpriteStyleMenu.SCREEN_RANDOM

SpriteStyleMenu.LABEL_STYLE = "SPRITE STYLE"
SpriteStyleMenu.LABEL_SPAWN = "SPAWN AMOUNT"
SpriteStyleMenu.LABEL_RANDOM = "RANDOM ENC"
SpriteStyleMenu.LABEL_WATER = "WATER MONS"
SpriteStyleMenu.MENU_LABEL = SpriteStyleMenu.LABEL_STYLE
SpriteStyleMenu.LABEL_GRASS = SpriteStyleMenu.LABEL_RANDOM

SpriteStyleMenu.STYLE_CHOICES = {
  { label = "FOLLOWERS/GSC", value = "followers" },
  { label = "HGSS / POKEMMO", value = "pokemmo" },
  { label = "POKEDEX", value = "pokedex" },
}
SpriteStyleMenu.CHOICES = SpriteStyleMenu.STYLE_CHOICES

SpriteStyleMenu.SPAWN_CHOICES = {
  { label = "LOW", value = "low" },
  { label = "NORMAL", value = "normal" },
  { label = "HIGH", value = "high" },
  { label = "VERY HIGH", value = "very_high" },
}

SpriteStyleMenu.RANDOM_CHOICES = {
  { label = "ON", value = true },
  { label = "OFF", value = false },
}

SpriteStyleMenu.WATER_CHOICES = {
  { label = "SWIM SPRITES", value = "swimming_sprites" },
  { label = "HID SILHOUETTE", value = "hidden_silhouettes" },
  { label = "SILHOUETTES", value = "silhouettes" },
  { label = "CLASSIC ENC", value = "classic_encounters" },
  { label = "DISABLED", value = "disabled" },
}

local STYLE_CONFIRM = {
  followers = "POKE FOLLOWERS / GSC",
  pokemmo = "HGSS / POKEMMO",
  pokedex = "POKEDEX",
}

local function providerAvailable(menu, style, game)
  local render = menu.logic and menu.logic.render
  local providers = render and render.spriteProviders
  if not providers then return false, "no providers" end
  style = Config.normalizeSpriteStyle(style)
  if style == "pokemmo" or style == "pokedex" then
    return true, "built-in"
  end
  if style == "followers" then
    return providers:providerAvailable("followers_ex", game)
  end
  return providers:providerAvailable(style, game)
end

local function activeFallbackLabel(menu, style, game)
  local render = menu.logic and menu.logic.render
  local providers = render and render.spriteProviders
  if not providers then return "HGSS / POKEMMO" end
  local id = select(1, providers:activeProviderForStyle(style, game))
  if id == "followers_ex" then return "POKE FOLLOWERS / GSC"
  elseif id == "pokedex" then return "POKEDEX"
  elseif id == "black" then return "FALLBACK"
  end
  return "HGSS / POKEMMO"
end

local function markCurrent(label, isCurrent)
  if not isCurrent then return label end
  local marked = "> " .. label
  if #marked > 14 then marked = ">" .. label end
  if #marked > 14 then return label end
  return marked
end

function SpriteStyleMenu.new(mod, logic)
  local self = setmetatable({}, SpriteStyleMenu)
  self.mod = mod
  self.logic = logic
  self._registered = false
  return self
end

function SpriteStyleMenu:_applyStyle(game, value)
  local mod = self.mod
  local avail, reason = providerAvailable(self, value, game)
  local message = "SPRITES: " .. (STYLE_CONFIRM[value] or tostring(value):upper())

  value = Config.normalizeSpriteStyle(value)
  if value == "followers" and not avail then
    message = ("POKE FOLLOWERS / GSC\nNOT READY\nUSING %s"):format(
      activeFallbackLabel(self, "followers", game))
  end

  local ok, err = Config.setSpriteStyle(mod, value, "mod_settings", {
    game = game,
    logic = self.logic,
    render = self.logic and self.logic.render,
    confirm = true,
    message = message,
  })
  if not ok then
    DebugLog.warn(mod, "sprite style apply failed: %s (%s)",
                  tostring(err), tostring(reason))
  end
  return ok
end

function SpriteStyleMenu:_applySpawn(game, value)
  local ok, err = Config.setSpawnAmount(self.mod, value, "mod_settings", {
    game = game,
    logic = self.logic,
    confirm = true,
  })
  if not ok then
    DebugLog.warn(self.mod, "spawn amount apply failed: %s", tostring(err))
  end
  return ok
end

function SpriteStyleMenu:_applyRandom(game, value)
  local ok, err = Config.setRandomEncounters(self.mod, value, "mod_settings", {
    game = game,
    logic = self.logic,
    confirm = true,
  })
  if not ok then
    DebugLog.warn(self.mod, "random enc apply failed: %s", tostring(err))
  end
  return ok
end

function SpriteStyleMenu:_applyWater(game, value)
  local ok, err = Config.setWaterMons(self.mod, value, "mod_settings", {
    game = game,
    logic = self.logic,
    confirm = true,
  })
  if not ok then
    DebugLog.warn(self.mod, "water mons apply failed: %s", tostring(err))
  end
  return ok
end

function SpriteStyleMenu:_openStyleMenu(game)
  local mod = self.mod
  local current = Config.spriteStyle(mod)
  local items = {}

  for _, choice in ipairs(SpriteStyleMenu.STYLE_CHOICES) do
    local avail = select(1, providerAvailable(self, choice.value, game))
    local base = choice.label
    local label
    if choice.value == current then
      label = markCurrent(base, true)
    else
      if avail and choice.value == "followers" then
        local withStar = base .. " *"
        label = (#withStar <= 14) and withStar or base
      else
        label = base
      end
    end
    items[#items + 1] = { label = label, value = choice.value }
  end
  items[#items + 1] = { label = "CANCEL", value = nil }

  return mod.ui.ListMenu.new(game, SpriteStyleMenu.LABEL_STYLE, items, {
    onChoose = function(item, menu)
      if item and item.value then
        self:_applyStyle(game, item.value)
      end
      if menu and menu.close then menu:close() end
    end,
  })
end

function SpriteStyleMenu:_openSpawnMenu(game)
  local mod = self.mod
  local current = Config.spawnAmount(mod)
  local items = {}
  for _, choice in ipairs(SpriteStyleMenu.SPAWN_CHOICES) do
    items[#items + 1] = {
      label = markCurrent(choice.label, choice.value == current),
      value = choice.value,
    }
  end
  items[#items + 1] = { label = "CANCEL", value = nil }

  return mod.ui.ListMenu.new(game, SpriteStyleMenu.LABEL_SPAWN, items, {
    onChoose = function(item, menu)
      if item and item.value then
        self:_applySpawn(game, item.value)
      end
      if menu and menu.close then menu:close() end
    end,
  })
end

function SpriteStyleMenu:_openRandomMenu(game)
  local mod = self.mod
  local current = Config.randomEncountersEnabled(mod)
  local items = {}
  for _, choice in ipairs(SpriteStyleMenu.RANDOM_CHOICES) do
    items[#items + 1] = {
      label = markCurrent(choice.label, choice.value == current),
      value = choice.value,
    }
  end
  items[#items + 1] = { label = "CANCEL", value = nil }

  return mod.ui.ListMenu.new(game, SpriteStyleMenu.LABEL_RANDOM, items, {
    onChoose = function(item, menu)
      if item and item.value ~= nil then
        self:_applyRandom(game, item.value)
      end
      if menu and menu.close then menu:close() end
    end,
  })
end

function SpriteStyleMenu:_openWaterMenu(game)
  local mod = self.mod
  local current = Config.waterDisplayMode(mod)
  local items = {}
  for _, choice in ipairs(SpriteStyleMenu.WATER_CHOICES) do
    items[#items + 1] = {
      label = markCurrent(choice.label, choice.value == current),
      value = choice.value,
    }
  end
  items[#items + 1] = { label = "CANCEL", value = nil }

  return mod.ui.ListMenu.new(game, SpriteStyleMenu.LABEL_WATER, items, {
    onChoose = function(item, menu)
      if item and item.value ~= nil then
        self:_applyWater(game, item.value)
      end
      if menu and menu.close then menu:close() end
    end,
  })
end

function SpriteStyleMenu:_openMenu(game)
  return self:_openStyleMenu(game)
end

function SpriteStyleMenu:_applyChoice(game, value)
  return self:_applyStyle(game, value)
end

function SpriteStyleMenu:register()
  if self._registered then return end
  local mod = self.mod
  local menu = self

  if mod.content and mod.content.screens and mod.content.screens.register then
    mod.content.screens:register(SpriteStyleMenu.SCREEN_STYLE, {
      new = function(game) return menu:_openStyleMenu(game) end,
    })
    mod.content.screens:register(SpriteStyleMenu.SCREEN_SPAWN, {
      new = function(game) return menu:_openSpawnMenu(game) end,
    })
    mod.content.screens:register(SpriteStyleMenu.SCREEN_RANDOM, {
      new = function(game) return menu:_openRandomMenu(game) end,
    })
    mod.content.screens:register(SpriteStyleMenu.SCREEN_WATER, {
      new = function(game) return menu:_openWaterMenu(game) end,
    })
  end

  -- Intentionally do NOT wrap ui.start_menu.items — gameplay settings belong
  -- exclusively in Mod Settings. Test Spawn uses ui.options.rows.

  self._registered = true
  if Config.debug(mod) then
    DebugLog.info(mod, "sprite style screens registered (no start-menu rows)")
  end
end

return SpriteStyleMenu
