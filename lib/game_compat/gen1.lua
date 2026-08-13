-- Gen 1 adapter for Wilds game compatibility.
--
-- Thin wrappers around the current Red / Blue / Yellow logic. Do not change
-- semantics here — future generations get their own adapter.
local V = ...

local Gen1 = {}
Gen1.supported = true
Gen1.generation = 1
-- National Dex cap for Gen1-only consumers (True Size, etc.). Shared
-- GameCompat.speciesId does not apply this cap.
Gen1.MAX_SPECIES = 151

Gen1.capabilities = {
  core = true,
  species = true,
  party = true,
  surf = true,
  encounters = true,
  followers = true,
  catching = true,
  ambient = true,
  townPokemon = true,
  safari = true,
}

-- Existing Gen1 name → dex fallback (moved from follower/sprite_service.lua).
-- Used only when the engine species resolver cannot resolve a key.
Gen1.SPECIES_TO_DEX = {
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

local function tryVRequire(name)
  local ok, mod = pcall(function() return V.require(name) end)
  if ok then return mod end
  return nil
end

--- Resolve a species key to a numeric id using current Gen1 paths.
-- 1. numeric id → return as-is if a positive integer
-- 2. engine species resolver (AnimatedSprites / game.data / content)
-- 3. existing Gen1 name mapping fallback
function Gen1.speciesId(species, game, mod)
  if species == nil then return nil end
  local n = tonumber(species)
  if n and n >= 1 and math.floor(n) == n then
    return math.floor(n)
  end
  if type(species) ~= "string" and type(species) ~= "number" then
    return nil
  end

  local AnimatedSprites = tryVRequire("animated_sprites")
  if AnimatedSprites and AnimatedSprites.resolveSpeciesId then
    local ok, dex = pcall(AnimatedSprites.resolveSpeciesId, species, game, mod)
    if ok and type(dex) == "number" and dex >= 1 then
      return math.floor(dex)
    end
  end

  if type(species) == "string" and species ~= "" then
    local mapped = Gen1.SPECIES_TO_DEX[species:upper()]
    if mapped then return mapped end
  end
  return nil
end

--- Current Red/Blue/Yellow surf detection (ControlEngine / water-compat).
function Gen1.isSurfing(game, ow)
  ow = ow or (game and game.overworld)
  local player = ow and ow.player
  if not player then return false end
  if player.surfing == true or player.isSurfing == true then return true end
  if player.surface == "water" or player.surface == "WATER" then return true end
  if game and game.player and game.player.surfing == true then return true end
  if ow and ow.map and player.cellX ~= nil and player.cellY ~= nil then
    return Gen1.isWaterCell(ow.map, player.cellX, player.cellY)
  end
  return false
end

function Gen1.isWaterCell(map, x, y)
  if not (map and type(map.isWaterCell) == "function") then return false end
  local ok, water = pcall(map.isWaterCell, map, x, y)
  return ok and water == true
end

function Gen1.party(game)
  if not (game and game.save and type(game.save.party) == "table") then
    return nil
  end
  return game.save.party
end

function Gen1.currentMapId(game, ow)
  ow = ow or (game and game.overworld)
  if ow and ow.map and ow.map.id ~= nil then
    return ow.map.id
  end
  return nil
end

--- Per-map encounter table. Same object as game.data.encounters[mapId].
function Gen1.encountersForMap(game, mapId)
  if not game or not game.data or type(game.data.encounters) ~= "table" then
    return nil
  end
  return game.data.encounters[mapId]
end

--- Exact current Gen1 wild battle entry: queue start_battle wild species level.
function Gen1.startWildBattle(world, species, level)
  if not (world and type(world.queueScript) == "function") then
    return nil, "no world"
  end
  return world:queueScript({
    { "start_battle", "wild", species, tonumber(level) or 5 },
  })
end

return Gen1
