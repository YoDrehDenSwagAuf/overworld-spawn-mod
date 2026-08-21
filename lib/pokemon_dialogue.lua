-- Wilds-owned Pokémon dialogue presentation with optional PMDCollab portraits.
-- Portraits are independent of overworld Sprite Style.
local V = ...

local PokemonDialogue = {}

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function isShinyMon(mon)
  if not mon then return false end
  if mon.shiny == true or mon.isShiny == true then return true end
  local Stats = tryRequire("src.pokemon.Stats")
  if Stats and Stats.isShiny and mon.dvs then
    local ok, shiny = pcall(Stats.isShiny, mon.dvs)
    return ok and shiny == true
  end
  return false
end

function PokemonDialogue.resolvePortraitOpts(mon, species, opts)
  opts = opts or {}
  local shiny = opts.shiny
  if shiny == nil then
    shiny = isShinyMon(mon)
  end
  return {
    species = species or (mon and mon.species),
    shiny = shiny == true,
    mood = opts.mood,
    randomGeneric = opts.randomGeneric,
    rng = opts.rng,
    mon = mon,
  }
end

local function stackTop(game)
  local stack = game and game.stack
  if not (stack and type(stack.top) == "function") then return nil end
  local ok, top = pcall(stack.top, stack)
  if ok then return top end
  return nil
end

local function loadPortraitImage(path)
  if type(path) ~= "string" or path == "" then return nil end
  if not (love and love.graphics and love.graphics.newImage) then
    return nil
  end
  local ok, img = pcall(love.graphics.newImage, path)
  if not ok or not img then return nil end
  if img.setFilter then
    pcall(function() img:setFilter("nearest", "nearest") end)
  end
  return img
end

--- Draw portrait above-left of the TextBox (may slightly overlap the top border).
-- Gen1 box defaults: tx=0,ty=12,tw=20,th=6 → pixel y=96 on 160×144.
-- Choice boxes sit on the right; left portrait avoids Ok/Ball collision.
local function attachPortraitDraw(textbox, portrait)
  if type(textbox) ~= "table" or type(textbox.draw) ~= "function" then
    return false
  end
  if not portrait or not portrait.path then return false end
  if textbox._wildsPortraitWrapped then
    textbox._wildsPortrait = portrait
    return true
  end
  local img = loadPortraitImage(portrait.path)
  if not img then return false end
  portrait._image = img
  local orig = textbox.draw
  textbox._wildsPortraitOrigDraw = orig
  textbox._wildsPortrait = portrait
  textbox._wildsPortraitWrapped = true
  function textbox:draw(...)
    orig(self, ...)
    local p = self._wildsPortrait
    local image = p and p._image
    if not image then return end
    if not (love and love.graphics and love.graphics.draw) then return end
    local boxTy = tonumber(self.boxTy) or 12
    local size = 40
    if image.getWidth then
      local ok, w = pcall(function() return image:getWidth() end)
      if ok and type(w) == "number" and w > 0 then size = w end
    end
    -- Sit just above the dialogue box, left side; slight overlap into the
    -- frame is intentional so Gen1 keeps full text width.
    local x = 4
    local y = boxTy * 8 - size + 4
    if y < 0 then y = 0 end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(image, x, y, 0, 1, 1)
  end
  return true
end

local function resolvePortrait(mod, opts)
  opts = opts or {}
  if opts.portrait then
    return opts.portrait
  end
  local species = opts.species
  if not species and opts.mon then
    species = opts.mon.species
  end
  if not species then return nil end
  local PortraitRegistry = V.require("portrait_registry")
  local randomGeneric = opts.randomGeneric
  if randomGeneric == nil then
    randomGeneric = opts.mood == nil
  end
  return PortraitRegistry.resolve(species, {
    mod = mod,
    shiny = opts.shiny,
    mood = opts.mood,
    randomGeneric = randomGeneric == true,
    rng = opts.rng,
  })
end

local function afterPresent(mod, game, portrait)
  if not portrait then return end
  local top = stackTop(game)
  if top then
    attachPortraitDraw(top, portrait)
  end
end

function PokemonDialogue.presentText(mod, game, ow, text, onDone, opts)
  opts = opts or {}
  local GameCompat = V.require("game_compat")
  local portrait = resolvePortrait(mod, opts)
  -- Stable for this dialog (multi-page): portrait table is fixed here.
  local result = GameCompat.presentText(mod, game, ow, text, onDone)
  afterPresent(mod, game, portrait)
  return result, portrait
end

function PokemonDialogue.presentTextChoice(mod, game, ow, text, onChoose, opts)
  opts = opts or {}
  local GameCompat = V.require("game_compat")
  local portrait = resolvePortrait(mod, opts)
  local choiceOpts = {
    labels = opts.labels,
    box = opts.box,
    defaultNo = opts.defaultNo,
    noSound = opts.noSound,
  }
  local result = GameCompat.presentTextChoice(mod, game, ow, text, onChoose, choiceOpts)
  afterPresent(mod, game, portrait)
  return result, portrait
end

return PokemonDialogue
