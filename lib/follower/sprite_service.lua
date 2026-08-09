-- Follower sprite resolution service (standalone; no PokéPC required).
-- Uses Wilds HGSS/PokeMMO runtime sheets (16×96, frames=6, walker=true).
-- Prepared shared API for PR 2 full wild/follower/ambient resolver.
local V = ...
local Constants = V.require("follower/constants")
local Config = V.require("config")
local DebugLog = V.require("debug_log")

local SpriteService = {}
SpriteService.__index = SpriteService

local SPECIES_TO_DEX = {
  BULBASAUR=1, IVYSAUR=2, VENUSAUR=3, CHARMANDER=4, CHARMELEON=5, CHARIZARD=6,
  SQUIRTLE=7, WARTORTLE=8, BLASTOISE=9, CATERPIE=10, METAPOD=11, BUTTERFREE=12,
  WEEDLE=13, KAKUNA=14, BEEDRILL=15, PIDGEY=16, PIDGEOTTO=17, PIDGEOT=18,
  RATTATA=19, RATICATE=20, SPEAROW=21, FEAROW=22, EKANS=23, ARBOK=24,
  PIKACHU=25, RAICHU=26, SANDSHREW=27, SANDSLASH=28, NIDORAN_F=29, NIDORINA=30,
  NIDOQUEEN=31, NIDORAN_M=32, NIDORINO=33, NIDOKING=34, CLEFAIRY=35, CLEFABLE=36,
  VULPIX=37, NINETALES=38, JIGGLYPUFF=39, WIGGLYTUFF=40, ZUBAT=41, GOLBAT=42,
  ODDISH=43, GLOOM=44, VILEPLUME=45, PARAS=46, PARASECT=47, VENONAT=48,
  VENOMOTH=49, DIGLETT=50, DUGTRIO=51, MEOWTH=52, PERSIAN=53, PSYDUCK=54,
  GOLDUCK=55, MANKEY=56, PRIMEAPE=57, GROWLITHE=58, ARCANINE=59, POLIWAG=60,
  POLIWHIRL=61, POLIWRATH=62, ABRA=63, KADABRA=64, ALAKAZAM=65, MACHOP=66,
  MACHOKE=67, MACHAMP=68, BELLSPROUT=69, WEEPINBELL=70, VICTREEBEL=71, TENTACOOL=72,
  TENTACRUEL=73, GEODUDE=74, GRAVELER=75, GOLEM=76, PONYTA=77, RAPIDASH=78,
  SLOWPOKE=79, SLOWBRO=80, MAGNEMITE=81, MAGNETON=82, FARFETCHD=83, DODUO=84,
  DODRIO=85, SEEL=86, DEWGONG=87, GRIMER=88, MUK=89, SHELLDER=90,
  CLOYSTER=91, GASTLY=92, HAUNTER=93, GENGAR=94, ONIX=95, DROWZEE=96,
  HYPNO=97, KRABBY=98, KINGLER=99, VOLTORB=100, ELECTRODE=101, EXEGGCUTE=102,
  EXEGGUTOR=103, CUBONE=104, MAROWAK=105, HITMONLEE=106, HITMONCHAN=107, LICKITUNG=108,
  KOFFING=109, WEEZING=110, RHYHORN=111, RHYDON=112, CHANSEY=113, TANGELA=114,
  KANGASKHAN=115, HORSEA=116, SEADRA=117, GOLDEEN=118, SEAKING=119, STARYU=120,
  STARMIE=121, MR_MIME=122, SCYTHER=123, JYNX=124, ELECTABUZZ=125, MAGMAR=126,
  PINSIR=127, TAUROS=128, MAGIKARP=129, GYARADOS=130, LAPRAS=131, DITTO=132,
  EEVEE=133, VAPOREON=134, JOLTEON=135, FLAREON=136, PORYGON=137, OMANYTE=138,
  OMASTAR=139, KABUTO=140, KABUTOPS=141, AERODACTYL=142, SNORLAX=143, ARTICUNO=144,
  ZAPDOS=145, MOLTRES=146, DRATINI=147, DRAGONAIR=148, DRAGONITE=149, MEWTWO=150, MEW=151,
}

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
    return ok and shiny and true or false
  end
  return false
end

--- Helper to check if a sprite style utilizes full 32-bit RGBA color.
local function is32BitStyle(style)
  if not style then return false end
  style = style:lower()
  return style == "redpp" or style == "pokemmo" or style == "hgss" or style == "fullcolor"
end

function SpriteService.new(mod, opts)
  opts = opts or {}
  local self = setmetatable({}, SpriteService)
  self.mod = mod
  self.render = opts.render
  self.logic = opts.logic
  self._registered = false
  self._partyHookInstalled = false
  self._imageCache = {}
  self._partyIconDefCache = {}
  return self
end

function SpriteService:dexOf(species)
  if type(species) == "number" then return species end
  if type(species) ~= "string" then return nil end
  local key = species:upper()
  if SPECIES_TO_DEX[key] then return SPECIES_TO_DEX[key] end
  local AnimatedSprites = V.require("animated_sprites")
  if AnimatedSprites and AnimatedSprites.resolveSpeciesId then
    local ok, dex = pcall(AnimatedSprites.resolveSpeciesId, species, nil, self.mod)
    if ok and dex then return dex end
  end
  return nil
end

function SpriteService:_modAssetPath(rel)
  if self.render and self.render._modAssetPath then
    return self.render:_modAssetPath(rel)
  end
  if self.mod and self.mod.assets and self.mod.assets.path then
    local ok, path = pcall(function() return self.mod.assets:path(rel) end)
    if ok and path then return path end
  end
  if self.mod and self.mod.path then
    return self.mod.path .. "/" .. rel
  end
  return rel
end

function SpriteService:_fallbackImage()
  return self:_modAssetPath("assets/fallback/pokemon_missing.png")
end

--- Resolve a follower land/water sprite matching the active configured style.
function SpriteService:resolveFollowerSprite(opts)
  opts = opts or {}
  local species = opts.species or "CHARMANDER"
  local shiny = opts.shiny == true
  local style = opts.style or Config.spriteStyle(self.mod)
  local surface = opts.surface or "land"
  local role = opts.role or "primary"
  local game = opts.game
  local variant = shiny and "shiny" or "normal"

  -- Water: prefer existing Wilds water resolver (swimming / levitates).
  if (surface == "surfing" or surface == "water") and self.logic
      and type(self.logic.resolveWaterSprite) == "function" then
    local def = self.logic:resolveWaterSprite(species, shiny, opts.form, {
      game = game,
      follower = true,
      allowLandFallback = false,
    })
    if def and def.image then
      return {
        id = def.id or "SPRITE_WILDS_FOLLOWER_WATER",
        image = def.image,
        frames = def.frames or 6,
        walker = def.walker ~= false,
        trueColor = def.trueColor ~= false,
        providerId = "water",
        role = role,
        surface = surface,
      }
    end
  end

  -- Land / fallback: Wilds sprite providers (pokemmo → followers → pokedex chain).
  local providers = self.render and self.render.spriteProviders
  if providers and type(providers.resolve) == "function" then
    local result = providers:resolve(style, species, variant, game)
    if result and result.def and result.def.image then
      local def = result.def
      local trueColor = def.trueColor ~= false
      if Config.spriteTrueColor then
        trueColor = Config.spriteTrueColor(self.mod)
      end
      return {
        id = (role == "player_controlled") and "SPRITE_PLAYER_POKEMON"
          or (role == "party_trailer" or role == "primary") and "SPRITE_WILDS_FOLLOWER_MON"
          or def.id or Constants.SPRITE_ID,
        image = def.image,
        frames = def.frames or 6,
        walker = def.walker ~= false,
        trueColor = trueColor,
        providerId = result.providerId,
        role = role,
        surface = "land",
      }
    end
  end

  -- Direct runtime sheet lookup (no providers finalized yet).
  local sheets = self.render and self.render.runtimeSheets
  if sheets then
    if not sheets.ready and sheets.load then pcall(function() sheets:load() end) end
    local dex = self:dexOf(species) or 4
    local def = sheets:spriteDef(dex, variant, "SPRITE_WILDS_FOLLOWER_MON")
    if def and def.image then
      return {
        id = def.id,
        image = def.image,
        frames = def.frames or 6,
        walker = true,
        trueColor = true,
        providerId = "pokemmo",
        role = role,
        surface = "land",
      }
    end
  end

  return {
    id = Constants.SPRITE_ID,
    image = self:_fallbackImage(),
    frames = 1,
    walker = false,
    trueColor = true,
    providerId = "fallback",
    role = role,
    surface = surface,
  }
end


--- Resolve sprite definition for a Party Pokémon matching user's configured style.
-- Cached per style+species+variant so the party menu doesn't re-run the full
-- provider chain on every icon draw.
function SpriteService:resolvePartyIconDef(mon, game)
  if not mon then return nil end
  local species = mon.species or "CHARMANDER"
  local shiny = isShinyMon(mon)
  local activeStyle = Config.spriteStyle and Config.spriteStyle(self.mod)
  -- The art set is mode-dependent (colored vs -grayscale), so the cache key
  -- must include the redpp gate; otherwise a mid-session COLORS toggle would
  -- keep serving the stale art.
  local redpp = Config.paletteFxRedpp and Config.paletteFxRedpp() or false
  local cacheKey = tostring(activeStyle or "") .. "|" .. tostring(species)
    .. (shiny and "|s" or "|n") .. "|" .. (redpp and "r" or "g")
  local cached = self._partyIconDefCache[cacheKey]
  if cached then return cached end

  local def = self:resolveFollowerSprite({
    species = species,
    shiny = shiny,
    form = mon.form,
    surface = "land",
    role = "party_menu",
    style = activeStyle,
    game = game,
  })
  if def then
    self._partyIconDefCache[cacheKey] = def
  end
  return def
end

-- Load an icon image through the game's Assets resolver (fallback:
-- love.graphics.newImage). Sprite Color was removed, so icons are always
-- loaded raw (true-color) — there is no DMG-gray bake variant anymore.
function SpriteService:getPartyIconImage(imagePath)
  if not imagePath or imagePath == "" then return nil end
  if self._imageCache[imagePath] then return self._imageCache[imagePath] end

  local img = nil
  local Assets = tryRequire("src.render.Assets")
  if Assets and type(Assets.image) == "function" then
    local ok, got = pcall(Assets.image, imagePath)
    if ok and got then img = got end
  end
  if not img and love and love.graphics and love.graphics.newImage then
    local ok, got = pcall(love.graphics.newImage, imagePath)
    if ok and got then img = got end
  end
  if not img then return nil end

  if img.setFilter then pcall(img.setFilter, img, "nearest", "nearest") end
  self._imageCache[imagePath] = img
  return img
end

--- Generates a Love2D Quad extracting a frame from a walking sprite sheet
--- (16×96, 6 frames stacked vertically → 16×16 frames). Frame 0 is STAND
--- down (front-facing idle); frame 3 is WALK down (the vanilla party-icon
--- blink alternate). Single-frame defs (e.g. pokedex fronts) draw whole.
function SpriteService:getPartyMonIconQuad(def, imgWidth, imgHeight, frameIndex)
  if not (love and love.graphics and love.graphics.newQuad) then return nil end
  if type(def) ~= "table" then return nil end
  imgWidth = tonumber(imgWidth) or 16
  imgHeight = tonumber(imgHeight) or 16
  if imgWidth < 1 or imgHeight < 1 then return nil end

  local frames = tonumber(def.frames) or 1
  local frameWidth, frameHeight = imgWidth, imgHeight
  local index = tonumber(frameIndex) or 0
  if frames > 1 and imgHeight >= frames * 16 then
    frameWidth = imgWidth
    frameHeight = math.floor(imgHeight / frames)
    index = math.max(0, math.min(frames - 1, index))
  end
  return love.graphics.newQuad(0, index * frameHeight, frameWidth, frameHeight,
                               imgWidth, imgHeight)
end

-- Drawn size of a quad: real Love quads expose getViewport; headless test
-- stubs carry w/h fields.
local function quadDrawnSize(quad, iw, ih)
  if type(quad.getViewport) == "function" then
    local _, _, vw, vh = quad:getViewport()
    return vw or iw, vh or ih
  end
  return quad.w or iw, quad.h or ih
end

local PARTY_SCREEN_MODULES = {
  "src.ui.PartyMenu", -- Gen1Recomp's real party screen (static drawIcon)
  "src.ui.PartyScreen",
  "src.ui.PartyPanel",
  "src.menu.PartyMenu",
  "src.ui.party.PartyScreen",
}

-- Methods that draw ONLY a mon's icon (safe to replace wholesale). Ambiguous
-- row drawers (drawMon / drawMember) are NOT hooked: overlaying an icon at
-- the row origin would misplace it, so those rely on patchPartyIconTrueColor.
local ICON_DRAW_FNS = { "drawMonIcon", "drawPokemonIcon", "drawIcon" }

--- Draw the follower-style icon at (x, y) matching the active sprite style.
-- Mirrors SpriteRenderer's trueColor contract: the sheet draws raw and the
-- covering rect is marked via PaletteFX.markTrueColor so the SGB zone pass
-- re-blits it unshaded (Sprite Color was removed — every icon is true-color).
function SpriteService:drawPartyIcon(game, mon, x, y, selected, counter)
  local def = self:resolvePartyIconDef(mon, game)
  if not (def and def.image) then return false end
  if not (love and love.graphics and love.graphics.draw) then return false end

  local img = self:getPartyIconImage(def.image)
  if not img then return false end

  local iw, ih = img:getWidth(), img:getHeight()
  local frameIndex = 0
  -- The selected mon's icon blinks between stand (0) and walk (3) frames,
  -- at the same HP-based speed the vanilla menu uses.
  if selected and (tonumber(def.frames) or 1) >= 4 then
    local hp = tonumber(mon and mon.hp) or 0
    local maxHp = mon and mon.stats and tonumber(mon.stats.hp) or 1
    local px = math.floor(hp * 48 / math.max(1, maxHp))
    local speed = px >= 27 and 5 or px >= 10 and 16 or 32
    if math.floor((tonumber(counter) or 0) / speed) % 2 == 1 then
      frameIndex = 3
    end
  end
  local quad = self:getPartyMonIconQuad(def, iw, ih, frameIndex)
  if not quad then return false end

  -- Oversized art (e.g. pokedex front pics) scales to the 16x16 icon slot.
  local qw, qh = quadDrawnSize(quad, iw, ih)
  local sx, sy = 1, 1
  if qw > 16 or qh > 16 then sx, sy = 16 / qw, 16 / qh end

  local prevShader = love.graphics.getShader and love.graphics.getShader()
  local r, g, b, a = love.graphics.getColor()
  love.graphics.setColor(1, 1, 1, 1)

  -- Grayscale icons must flow through the palette shade pass in every
  -- non-redpp mode so they colorize per palette (DMG = green shades,
  -- monochrome = gray) exactly like the follower/wild sprites. Only redpp
  -- (ADVANCED) serves colored art, which must bypass the shader and be
  -- claimed as true-color so it renders raw.
  local trueColorMode = Config.paletteFxRedpp and Config.paletteFxRedpp() or false
  if trueColorMode and love.graphics.setShader then love.graphics.setShader() end
  love.graphics.draw(img, quad, x, y, 0, sx, sy)
  if trueColorMode and love.graphics.setShader and prevShader then
    love.graphics.setShader(prevShader)
  end

  if trueColorMode then
    -- Claim the rect out of the shade-remap pass (the engine re-blits it
    -- unshaded on top of the colorized frame). Without this the zone shader
    -- re-tints the icon back to the classic palette.
    local PF = tryRequire("src.render.PaletteFX")
    if PF and type(PF.markTrueColor) == "function" then
      pcall(PF.markTrueColor, x, y, qw * sx, qh * sy)
    end
  end

  love.graphics.setColor(r, g, b, a)
  return true
end

function SpriteService:installPartyMenuHook()
  if self._partyHookInstalled then return true end

  local PartyScreen = nil
  for _, path in ipairs(PARTY_SCREEN_MODULES) do
    PartyScreen = tryRequire(path)
    if PartyScreen then
      self._partyScreenModule = path
      break
    end
  end
  if not PartyScreen then
    return false, "party_screen_not_found"
  end

  local iconFn = nil
  for _, name in ipairs(ICON_DRAW_FNS) do
    if type(PartyScreen[name]) == "function" then iconFn = name break end
  end
  if not iconFn then
    -- No dedicated icon-only drawer (e.g. whole-row drawMon): do not guess.
    -- patchPartyIconTrueColor covers the truecolor look instead.
    return false, "no_icon_draw_function"
  end

  local service = self
  local origDrawIcon = PartyScreen[iconFn]
  -- Engine signature (static call): PartyMenu.drawIcon(game, mon, x, y,
  -- selected, counter, forceAlt). forceAlt callers (trade animation) keep
  -- the vanilla frame cycling. Method-style screens (screen:drawMonIcon(mon,
  -- x, y)) fall through the same wrapper harmlessly.
  PartyScreen[iconFn] = function(game, mon, x, y, selected, counter, forceAlt, ...)
    if forceAlt then
      return origDrawIcon(game, mon, x, y, selected, counter, forceAlt, ...)
    end
    if service:drawPartyIcon(game, mon, x, y, selected, counter) then
      return true
    end
    return origDrawIcon(game, mon, x, y, selected, counter, forceAlt, ...)
  end

  self._partyHookInstalled = true
  DebugLog.info(self.mod, "Installed Party Menu sprite hook on %s.%s",
                tostring(self._partyScreenModule), tostring(iconFn))
  return true
end

--- Load/RUNTIME fallback: flip trueColor on the game's menu-icon sprite defs
-- so the party menu renders its icons in full color (matching follower
-- trueColor mode) even when no PartyScreen draw method is hookable.
-- Idempotent + guarded. Sprite Color was removed, so this always applies.
function SpriteService:patchPartyIconTrueColor(game)
  if self._iconPatchApplied then return true, "already" end
  if not (game and game.data and type(game.data.sprites) == "table") then
    return false, "sprites_unavailable"
  end

  local sprites = game.data.sprites
  local patched = 0
  local function flip(id, def)
    if type(def) ~= "table" or def.trueColor ~= false then return end
    if (tonumber(def.frames) or 1) > 1 then return end
    def.trueColor = true
    patched = patched + 1
  end

  -- Heuristic: engine icon sprite ids are ICON-prefixed or -suffixed
  -- (case-insensitive). Narrow to avoid unrelated defs with "icon" mid-id.
  for id, def in pairs(sprites) do
    if type(id) == "string" then
      local iconId = id:match("^[Ii][Cc][Oo][Nn]") or id:match("[Ii][Cc][Oo][Nn]$")
      if iconId then flip(id, def) end
    end
  end
  -- Precise: icon defs referenced by party / box members.
  local function flipForMon(mon)
    if type(mon) ~= "table" then return end
    local icon = mon.icon
    local id = type(icon) == "string" and icon
      or (type(icon) == "table" and icon.id) or nil
    if type(id) == "string" then flip(id, sprites[id]) end
  end
  local save = game.save
  for _, mon in ipairs((save and save.party) or {}) do flipForMon(mon) end
  for _, box in ipairs((save and save.boxes) or {}) do
    if type(box) == "table" then
      for _, mon in ipairs(box) do flipForMon(mon) end
    end
  end

  -- Only treat as applied when at least one def was flipped; otherwise retry
  -- later (party may be empty or icon ids not yet registered on first call).
  if patched > 0 then
    self._iconPatchApplied = true
    DebugLog.info(self.mod, "party icon truecolor patch applied (%d defs)", patched)
  end
  return true, patched
end

--- LOAD PHASE only: register SPRITE_PIKACHU so stock PikachuFollower can spawn
--- without PokéPC. Uses Charmander (dex 4) as the registered default image;
--- live species is applied via entity-local rebind, not global mutation.
function SpriteService:registerLoadPhaseSprites()
  if self._registered then return true, "already" end
  local mod = self.mod
  if not (mod and mod.content and mod.content.sprites) then
    return false, "no_content_sprites"
  end

  local sheets = self.render and self.render.runtimeSheets
  if sheets and sheets.load then pcall(function() sheets:load() end) end

  local image = self:_fallbackImage()
  local frames = 1
  local walker = false
  if sheets then
    local def = sheets:spriteDef(4, "normal", Constants.SPRITE_ID)
    if def and def.image then
      image = def.image
      frames = def.frames or 6
      walker = true
    end
  end

  local spriteDef = {
    id = Constants.SPRITE_ID,
    image = image,
    frames = frames,
    walker = walker,
    trueColor = true,
  }

  local sprites = mod.content.sprites
  local ok, err = pcall(function()
    if sprites.get and sprites:get(Constants.SPRITE_ID) then
      if sprites.patch then
        sprites:patch(Constants.SPRITE_ID, spriteDef)
      end
    elseif sprites.register then
      sprites:register(Constants.SPRITE_ID, spriteDef)
    end
  end)
  if not ok then
    DebugLog.warn(mod, "SPRITE_PIKACHU registration failed: %s", tostring(err))
    return false, err
  end

  -- Optional mon trailer id (entity-local defs also work without registry).
  pcall(function()
    if sprites.get and not sprites:get("SPRITE_WILDS_FOLLOWER_MON") and sprites.register then
      sprites:register("SPRITE_WILDS_FOLLOWER_MON", {
        id = "SPRITE_WILDS_FOLLOWER_MON",
        image = image,
        frames = frames,
        walker = walker,
        trueColor = true,
      })
    end
  end)

  pcall(function() self:installPartyMenuHook() end)

  self._registered = true
  DebugLog.info(mod, "registered SPRITE_PIKACHU for standalone follower (image=%s)",
                tostring(image))
  return true, "registered"
end

function SpriteService:hasSpritePikachu(game)
  local sprites = game and game.data and game.data.sprites
  if sprites and sprites[Constants.SPRITE_ID] then return true end
  local modSprites = self.mod and self.mod.content and self.mod.content.sprites
  if modSprites and modSprites.get then
    local ok, got = pcall(function() return modSprites:get(Constants.SPRITE_ID) end)
    if ok and got then return true end
  end
  return self._registered == true
end

return SpriteService
