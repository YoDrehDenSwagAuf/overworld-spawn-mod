-- Canonical Wilds sprite asset identity.
--
-- Maps stable internal species identifiers (mon.species) to the numeric IDs
-- used by Wilds-owned sprite/geometry assets (HGSS, Poké Followers, swimming,
-- levitate, True Size, followers, …).
--
-- runtimeDex (Pokédex position / GameCompat.speciesId) is mutable mod data and
-- must NEVER select Wilds assets. Unknown / Fakemon species return nil so
-- callers use the missing-sprite fallback instead of another Pokémon's art.
local V = ...

local SpeciesAssets = {}

SpeciesAssets.MAX_ID = 251

-- Gen1 + Gen2 internal species keys → Wilds canonical asset IDs (1..251).
-- Language-independent; never use localized display names.
local SPECIES_TO_ASSET_ID = {
  -- Gen 1
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
  -- Gen 2
  CHIKORITA=152, BAYLEEF=153, MEGANIUM=154, CYNDAQUIL=155, QUILAVA=156, TYPHLOSION=157,
  TOTODILE=158, CROCONAW=159, FERALIGATR=160, SENTRET=161, FURRET=162, HOOTHOOT=163,
  NOCTOWL=164, LEDYBA=165, LEDIAN=166, SPINARAK=167, ARIADOS=168, CROBAT=169,
  CHINCHOU=170, LANTURN=171, PICHU=172, CLEFFA=173, IGGLYBUFF=174, TOGEPI=175,
  TOGETIC=176, NATU=177, XATU=178, MAREEP=179, FLAAFFY=180, AMPHAROS=181,
  BELLOSSOM=182, MARILL=183, AZUMARILL=184, SUDOWOODO=185, POLITOED=186, HOPPIP=187,
  SKIPLOOM=188, JUMPLUFF=189, AIPOM=190, SUNKERN=191, SUNFLORA=192, YANMA=193,
  WOOPER=194, QUAGSIRE=195, ESPEON=196, UMBREON=197, MURKROW=198, SLOWKING=199,
  MISDREAVUS=200, UNOWN=201, WOBBUFFET=202, GIRAFARIG=203, PINECO=204, FORRETRESS=205,
  DUNSPARCE=206, GLIGAR=207, STEELIX=208, SNUBBULL=209, GRANBULL=210, QWILFISH=211,
  SCIZOR=212, SHUCKLE=213, HERACROSS=214, SNEASEL=215, TEDDIURSA=216, URSARING=217,
  SLUGMA=218, MAGCARGO=219, SWINUB=220, PILOSWINE=221, CORSOLA=222, REMORAID=223,
  OCTILLERY=224, DELIBIRD=225, MANTINE=226, SKARMORY=227, HOUNDOUR=228, HOUNDOOM=229,
  KINGDRA=230, PHANPY=231, DONPHAN=232, PORYGON2=233, STANTLER=234, SMEARGLE=235,
  TYROGUE=236, HITMONTOP=237, SMOOCHUM=238, ELEKID=239, MAGBY=240, MILTANK=241,
  BLISSEY=242, RAIKOU=243, ENTEI=244, SUICUNE=245, LARVITAR=246, PUPITAR=247,
  TYRANITAR=248, LUGIA=249, HO_OH=250, CELEBI=251,
}

local ASSET_TO_SPECIES = {}
for species, id in pairs(SPECIES_TO_ASSET_ID) do
  ASSET_TO_SPECIES[id] = species
end

SpeciesAssets.SPECIES_TO_ASSET_ID = SPECIES_TO_ASSET_ID

local function isPureNumeric(value)
  if type(value) == "number" then return true end
  if type(value) ~= "string" then return false end
  -- Reject non-numeric strings like "150FOO"; allow "150" / "150.0".
  return value:match("^%s*%d+%.?%d*%s*$") ~= nil
end

--- Resolve a species key to the Wilds canonical asset ID.
-- @param species string internal id ("MEWTWO") or number already-canonical id
-- @return number|nil asset id, or nil when Wilds has no asset for this species
function SpeciesAssets.idFor(species)
  if species == nil then return nil end

  if isPureNumeric(species) then
    local n = tonumber(species)
    if not n or n < 1 or math.floor(n) ~= n then return nil end
    n = math.floor(n)
    -- Already-canonical numeric ids: accept known Gen1/Gen2 assets, and
    -- passthrough higher positives for followsprite sheets that exist beyond
    -- 251 (preview). Never consult runtime Pokédex / mon.dex.
    if ASSET_TO_SPECIES[n] or n > SpeciesAssets.MAX_ID then
      return n
    end
    -- Numeric in 1..251 with no reverse entry cannot happen with a complete
    -- table; treat as canonical range passthrough for safety.
    if n <= SpeciesAssets.MAX_ID then
      return n
    end
    return nil
  end

  if type(species) ~= "string" or species == "" then
    return nil
  end
  -- Internal keys only (MEWTWO / mewtwo). Reject Title Case display names
  -- like "Mewtwo" / localized labels — those are not mon.species.
  local exact = SPECIES_TO_ASSET_ID[species]
  if exact then return exact end
  if species == species:lower() then
    return SPECIES_TO_ASSET_ID[species:upper()]
  end
  return nil
end

function SpeciesAssets.has(species)
  return SpeciesAssets.idFor(species) ~= nil
end

--- Reverse lookup: canonical asset id → internal species key (or nil).
function SpeciesAssets.speciesFor(assetId)
  local n = tonumber(assetId)
  if not n or n < 1 or math.floor(n) ~= n then return nil end
  return ASSET_TO_SPECIES[math.floor(n)]
end

function SpeciesAssets.count()
  local n = 0
  for _ in pairs(SPECIES_TO_ASSET_ID) do n = n + 1 end
  return n
end

return SpeciesAssets
