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

function SpriteService.new(mod, opts)
  opts = opts or {}
  local self = setmetatable({}, SpriteService)
  self.mod = mod
  self.render = opts.render
  self.logic = opts.logic
  self._registered = false
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

--- Resolve a follower land/water sprite. No external mod paths.
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
