-- Start-menu quick settings for Wilds of Kanto.
--
-- Registers via ui.start_menu.items (same hook as Followers EX / preview
-- browser). Order:
--   1. SPRITE STYLE
--   2. SPAWN AMOUNT
--   3. GRASS ENC
--   4. WATER MONS
--
-- All four write the shared option keys through Config setters — the same
-- persistence used by Mod Settings (Spawn Amount is Start-Menu only).
local V = ...
local Config = V.require("config")
local DebugLog = V.require("debug_log")

local SpriteStyleMenu = {}
SpriteStyleMenu.__index = SpriteStyleMenu

SpriteStyleMenu.SCREEN_STYLE = "overworld_wild_spawns:sprite_style"
SpriteStyleMenu.SCREEN_SPAWN = "overworld_wild_spawns:spawn_amount"
SpriteStyleMenu.SCREEN_GRASS = "overworld_wild_spawns:grass_enc"
SpriteStyleMenu.SCREEN_WATER = "overworld_wild_spawns:water_mons"
-- Back-compat alias used by older tests / docs.
SpriteStyleMenu.SCREEN = SpriteStyleMenu.SCREEN_STYLE

SpriteStyleMenu.LABEL_STYLE = "SPRITE STYLE" -- 12
SpriteStyleMenu.LABEL_SPAWN = "SPAWN AMOUNT" -- 12
SpriteStyleMenu.LABEL_GRASS = "GRASS ENC"    -- 9
SpriteStyleMenu.LABEL_WATER = "WATER MONS"   -- 10
SpriteStyleMenu.MENU_LABEL = SpriteStyleMenu.LABEL_STYLE

-- Visible choice labels (all <= 14). Internal values match options / defaults.
SpriteStyleMenu.STYLE_CHOICES = {
  { label = "AUTO", value = "auto" },
  { label = "GOLD SPRITES", value = "gold" },
  { label = "FOLLOWERS EX", value = "followers_ex" },
  { label = "POKEMMO", value = "pokemmo" },
  { label = "POKEDEX", value = "pokedex" },
}
SpriteStyleMenu.CHOICES = SpriteStyleMenu.STYLE_CHOICES

SpriteStyleMenu.SPAWN_CHOICES = {
  { label = "LOW", value = "low" },
  { label = "NORMAL", value = "normal" },
  { label = "HIGH", value = "high" },
  { label = "VERY HIGH", value = "very_high" },
}

SpriteStyleMenu.GRASS_CHOICES = {
  { label = "CLASSIC", value = "classic" },
  { label = "HIDDEN", value = "hidden" },
  { label = "BOTH", value = "both" },
}

SpriteStyleMenu.WATER_CHOICES = {
  { label = "ON", value = true },
  { label = "OFF", value = false },
}

local STYLE_CONFIRM = {
  auto = "AUTO",
  gold = "GOLD",
  followers_ex = "FOLLOWERS EX",
  pokemmo = "POKEMMO",
  pokedex = "POKEDEX",
}

local function hasLabel(items, label)
  if type(items) ~= "table" then return false end
  for _, item in ipairs(items) do
    if type(item) == "table" and item.label == label then
      return true
    end
  end
  return false
end

local function providerAvailable(menu, style, game)
  local render = menu.logic and menu.logic.render
  local providers = render and render.spriteProviders
  if not providers then return false, "no providers" end
  if style == "auto" or style == "pokemmo" or style == "pokedex" then
    return true, "built-in"
  end
  return providers:providerAvailable(style, game)
end

local function activeFallbackLabel(menu, style, game)
  local render = menu.logic and menu.logic.render
  local providers = render and render.spriteProviders
  if not providers then return "POKEMMO" end
  local id = select(1, providers:activeProviderForStyle(style, game))
  if id == "gold" then return "GOLD"
  elseif id == "followers_ex" then return "FOLLOWERS EX"
  elseif id == "pokedex" then return "POKEDEX"
  elseif id == "black" then return "FALLBACK"
  end
  return "POKEMMO"
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

  if value == "gold" and not avail then
    message = ("GOLD SPRITES\nNOT INSTALLED\nUSING %s"):format(
      activeFallbackLabel(self, "gold", game))
  elseif value == "followers_ex" and not avail then
    message = ("FOLLOWERS EX\nNOT INSTALLED\nUSING %s"):format(
      activeFallbackLabel(self, "followers_ex", game))
  end

  local ok, err = Config.setSpriteStyle(mod, value, "start_menu", {
    game = game,
    logic = self.logic,
    render = self.logic and self.logic.render,
    confirm = true,
    message = message,
  })
  if not ok then
    DebugLog.warn(mod, "sprite style menu apply failed: %s (%s)",
                  tostring(err), tostring(reason))
  end
  return ok
end

function SpriteStyleMenu:_applySpawn(game, value)
  local ok, err = Config.setSpawnAmount(self.mod, value, "start_menu", {
    game = game,
    logic = self.logic,
    confirm = true,
  })
  if not ok then
    DebugLog.warn(self.mod, "spawn amount menu apply failed: %s", tostring(err))
  end
  return ok
end

function SpriteStyleMenu:_applyGrass(game, value)
  local ok, err = Config.setGrassEncounters(self.mod, value, "start_menu", {
    game = game,
    logic = self.logic,
    confirm = true,
  })
  if not ok then
    DebugLog.warn(self.mod, "grass enc menu apply failed: %s", tostring(err))
  end
  return ok
end

function SpriteStyleMenu:_applyWater(game, value)
  local ok, err = Config.setWaterMons(self.mod, value, "start_menu", {
    game = game,
    logic = self.logic,
    confirm = true,
  })
  if not ok then
    DebugLog.warn(self.mod, "water mons menu apply failed: %s", tostring(err))
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
      if avail and (choice.value == "gold" or choice.value == "followers_ex") then
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

function SpriteStyleMenu:_openGrassMenu(game)
  local mod = self.mod
  local current = Config.grassEncounters(mod)
  local items = {}
  for _, choice in ipairs(SpriteStyleMenu.GRASS_CHOICES) do
    items[#items + 1] = {
      label = markCurrent(choice.label, choice.value == current),
      value = choice.value,
    }
  end
  items[#items + 1] = { label = "CANCEL", value = nil }

  return mod.ui.ListMenu.new(game, SpriteStyleMenu.LABEL_GRASS, items, {
    onChoose = function(item, menu)
      if item and item.value then
        self:_applyGrass(game, item.value)
      end
      if menu and menu.close then menu:close() end
    end,
  })
end

function SpriteStyleMenu:_openWaterMenu(game)
  local mod = self.mod
  local current = Config.waterMons(mod)
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

-- Back-compat for tests that call _openMenu / _applyChoice.
function SpriteStyleMenu:_openMenu(game)
  return self:_openStyleMenu(game)
end

function SpriteStyleMenu:_applyChoice(game, value)
  return self:_applyStyle(game, value)
end

local function pushScreen(mod, menu, game, screenId, opener)
  if mod.ui and type(mod.ui.push) == "function" then
    mod.ui.push(game, screenId)
  else
    local screen = opener(menu, game)
    if game and game.stack and screen then
      game.stack:push(screen)
    end
  end
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
    mod.content.screens:register(SpriteStyleMenu.SCREEN_GRASS, {
      new = function(game) return menu:_openGrassMenu(game) end,
    })
    mod.content.screens:register(SpriteStyleMenu.SCREEN_WATER, {
      new = function(game) return menu:_openWaterMenu(game) end,
    })
  end

  -- Always visible in the normal Start menu (not gated on Dev Mode).
  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then return out end

    local function ensure(label, screenId, opener)
      if hasLabel(out, label) then return end
      local entry = {
        label = label,
        onSelect = function()
          pushScreen(mod, menu, game, screenId, opener)
        end,
      }
      if mod.ui and type(mod.ui.insertBefore) == "function" then
        out = mod.ui.insertBefore(out, "SAVE", entry)
      else
        out[#out + 1] = entry
      end
    end

    -- Insert in order before SAVE: STYLE, SPAWN, GRASS, WATER.
    ensure(SpriteStyleMenu.LABEL_STYLE, SpriteStyleMenu.SCREEN_STYLE,
           SpriteStyleMenu._openStyleMenu)
    ensure(SpriteStyleMenu.LABEL_SPAWN, SpriteStyleMenu.SCREEN_SPAWN,
           SpriteStyleMenu._openSpawnMenu)
    ensure(SpriteStyleMenu.LABEL_GRASS, SpriteStyleMenu.SCREEN_GRASS,
           SpriteStyleMenu._openGrassMenu)
    ensure(SpriteStyleMenu.LABEL_WATER, SpriteStyleMenu.SCREEN_WATER,
           SpriteStyleMenu._openWaterMenu)
    return out
  end)

  self._registered = true
  if Config.debug(mod) then
    DebugLog.info(mod, "start-menu STYLE / SPAWN / GRASS / WATER registered")
  end
end

return SpriteStyleMenu
