-- Start-menu Sprite Style picker for Wilds of Kanto.
--
-- Registers once via ui.start_menu.items (same hook as Followers EX / preview
-- browser). Both this menu and Mod Settings write the shared sprite_style key
-- through Config.setSpriteStyle — no second persistence store.
local V = ...
local Config = V.require("config")
local DebugLog = V.require("debug_log")

local SpriteStyleMenu = {}
SpriteStyleMenu.__index = SpriteStyleMenu

SpriteStyleMenu.SCREEN = "overworld_wild_spawns:sprite_style"
SpriteStyleMenu.MENU_LABEL = "SPRITE STYLE" -- 12 chars (<= 14)

-- Visible choice labels (all <= 14). Internal values match options.lua.
SpriteStyleMenu.CHOICES = {
  { label = "AUTO", value = "auto" },                 -- 4
  { label = "GOLD SPRITES", value = "gold" },         -- 12
  { label = "FOLLOWERS EX", value = "followers_ex" }, -- 12
  { label = "CRYSTAL", value = "crystal" },           -- 7
  { label = "POKEMMO", value = "pokemmo" },           -- 7
  { label = "POKEDEX", value = "pokedex" },           -- 7
}

local CONFIRM = {
  auto = "AUTO",
  gold = "GOLD",
  followers_ex = "FOLLOWERS EX",
  crystal = "CRYSTAL",
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
  elseif id == "crystal" then return "CRYSTAL"
  elseif id == "pokedex" then return "POKEDEX"
  elseif id == "black" then return "FALLBACK"
  end
  return "POKEMMO"
end

function SpriteStyleMenu.new(mod, logic)
  local self = setmetatable({}, SpriteStyleMenu)
  self.mod = mod
  self.logic = logic
  self._registered = false
  return self
end

function SpriteStyleMenu:_applyChoice(game, value)
  local mod = self.mod
  local avail, reason = providerAvailable(self, value, game)
  local message = "SPRITES: " .. (CONFIRM[value] or tostring(value):upper())

  if value == "gold" and not avail then
    message = ("GOLD SPRITES\nNOT INSTALLED\nUSING %s"):format(
      activeFallbackLabel(self, "gold", game))
  elseif value == "followers_ex" and not avail then
    message = ("FOLLOWERS EX\nNOT INSTALLED\nUSING %s"):format(
      activeFallbackLabel(self, "followers_ex", game))
  elseif value == "crystal" and not avail then
    message = ("CRYSTAL\nNOT INSTALLED\nUSING %s"):format(
      activeFallbackLabel(self, "crystal", game))
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

function SpriteStyleMenu:_openMenu(game)
  local mod = self.mod
  local current = Config.spriteStyle(mod)
  local items = {}

  for _, choice in ipairs(SpriteStyleMenu.CHOICES) do
    local avail = select(1, providerAvailable(self, choice.value, game))
    local base = choice.label
    local label
    if choice.value == current then
      -- Mark current selection; keep within 14 chars when possible.
      label = "> " .. base
      if #label > 14 then label = ">" .. base end
    else
      -- Optional "*" for installed external packs (GOLD SPRITES *= 14).
      if avail and (choice.value == "gold"
                    or choice.value == "followers_ex"
                    or choice.value == "crystal") then
        local withStar = base .. " *"
        if #withStar <= 14 then
          label = withStar
        else
          label = base
        end
      else
        label = base
      end
    end

    items[#items + 1] = {
      label = label,
      value = choice.value,
    }
  end

  items[#items + 1] = { label = "CANCEL", value = nil }

  return mod.ui.ListMenu.new(game, SpriteStyleMenu.MENU_LABEL, items, {
    onChoose = function(item, menu)
      if item and item.value then
        self:_applyChoice(game, item.value)
      end
      if menu and menu.close then menu:close() end
    end,
  })
end

function SpriteStyleMenu:register()
  if self._registered then return end
  local mod = self.mod
  local menu = self

  if mod.content and mod.content.screens and mod.content.screens.register then
    mod.content.screens:register(SpriteStyleMenu.SCREEN, {
      new = function(game)
        return menu:_openMenu(game)
      end,
    })
  end

  -- Always visible in the normal Start menu (not gated on Dev Mode).
  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then return out end
    if hasLabel(out, SpriteStyleMenu.MENU_LABEL) then return out end

    local entry = {
      label = SpriteStyleMenu.MENU_LABEL,
      onSelect = function()
        if mod.ui and type(mod.ui.push) == "function" then
          mod.ui.push(game, SpriteStyleMenu.SCREEN)
        else
          local screen = menu:_openMenu(game)
          if game and game.stack and screen then
            game.stack:push(screen)
          end
        end
      end,
    }

    if mod.ui and type(mod.ui.insertBefore) == "function" then
      return mod.ui.insertBefore(out, "SAVE", entry)
    end
    out[#out + 1] = entry
    return out
  end)

  self._registered = true
  if Config.debug(mod) then
    DebugLog.info(mod, "SPRITE STYLE start-menu entry registered")
  end
end

return SpriteStyleMenu
