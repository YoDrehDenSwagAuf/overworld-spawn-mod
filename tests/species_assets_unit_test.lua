-- Canonical species → Wilds asset identity (reordered Pokédex / Fakemon).
-- Run: lua tests/species_assets_unit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. tostring(msg) .. "\n")
  else
    print("ok  " .. tostring(msg))
  end
end
local function eq(a, b, msg)
  check(a == b, string.format("%s (got %s expected %s)", msg, tostring(a), tostring(b)))
end

package.loaded["src.render.SpriteRenderer"] = {
  DEFAULT_FRAME_WIDTH = 16,
  DEFAULT_FRAME_HEIGHT = 16,
  getFrameGeometry = function() end,
  getPoseGeometry = function() end,
  getScreenOrigin = function() end,
  new = function(def, id)
    local fw = tonumber(def.frameWidth) or 16
    local fh = tonumber(def.frameHeight) or 16
    return {
      def = def,
      id = id,
      frameWidth = fw,
      frameHeight = fh,
      anchorX = tonumber(def.anchorX) or (fw / 2),
      anchorY = tonumber(def.anchorY) or fh,
    }
  end,
}

local modules = {}
local saved = {
  sprite_style = "pokemmo",
  pokemon_size = "true_size",
  water_spawns = "swimming_sprites",
  use_animated_overworld_sprites = true,
}

-- Reordered Pokédex: MEWTWO and TYRANITAR swapped at runtime.
local reorderedPokemon = {
  MEWTWO = { name = "Mewtwo", dex = 248, index = 248 },
  TYRANITAR = { name = "Tyranitar", dex = 150, index = 150 },
  PIKACHU = { name = "Pikachu", dex = 25, index = 25 },
  CHIKORITA = { name = "Chikorita", dex = 152, index = 152 },
  SENTRET = { name = "Sentret", dex = 161, index = 161 },
  LUGIA = { name = "Lugia", dex = 249, index = 249 },
  HO_OH = { name = "Ho-Oh", dex = 250, index = 250 },
  CELEBI = { name = "Celebi", dex = 251, index = 251 },
  BETA_MON_X = { name = "Beta Mon X", dex = 150, index = 150 },
}

local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    find = function() return nil end,
    options = { get = function(_, k) return saved[k] end },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local d = f:read("*a"); f:close(); return d
    end,
    assets = {
      path = function(_, r) return "mods/overworld_wild_spawns/" .. r end,
    },
    log = { info = function() end, warn = function() end },
    content = {
      pokemon = {
        get = function(_, key) return reorderedPokemon[key] end,
        each = function() return function() end end,
      },
      sprites = { get = function() return nil end },
    },
  },
  path = ".",
}

function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

modules.config = {
  DEFAULTS = {
    sprite_style = "pokemmo",
    pokemon_size = "true_size",
    water_spawns = "swimming_sprites",
    use_animated_overworld_sprites = true,
  },
  peekSavedOption = function(_, k) return saved[k], saved[k] ~= nil end,
  get = function(_, k) return saved[k] end,
  pokemonSizeMode = function() return saved.pokemon_size end,
  normalizePokemonSize = function(v) return v == "true_size" and "true_size" or "classic" end,
  normalizeSpriteStyle = function(v)
    if v == "hgss" or v == "fullcolor" then return "pokemmo" end
    if v == "followers_ex" or v == "poke_followers" then return "followers" end
    return v or "pokemmo"
  end,
  spriteStyle = function() return saved.sprite_style end,
  waterDisplayMode = function() return "swimming_sprites" end,
  wildSilhouettes = function() return false end,
  landArtUsesLuminance = function() return false end,
  waterArtUsesLuminance = function() return false end,
  paletteFxRedpp = function() return true end,
  spriteTrueColor = function() return true end,
  useAnimatedOverworldSprites = function() return true end,
  debug = function() return false end,
}
modules.debug_log = {
  warn = function() end, info = function() end,
  error = function() end, debug = function() end,
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }
modules.json_decode = assert(loadfile("lib/json_decode.lua"))(V)
modules.surface = {
  WATER = "water", GRASS = "grass", CAVE = "cave", INTERIOR = "interior",
  usesGrassOverlay = function() return false end,
}
modules.water_display = {
  isVoxelCameraActive = function() return false end,
  isSilhouettes = function() return false end,
  isHiddenSilhouettes = function() return false end,
  needsNativeSilhouetteSheet = function() return false end,
  needsNativeHiddenShadow = function() return false end,
}
modules.behavior = { isWater = function() return false end }
modules.luminance_sheet = {
  pathFor = function() return nil end,
  submergedFor = function() return nil end,
  silhouetteFor = function() return nil end,
}

local SpeciesAssets = V.require("species_assets")
local SpeciesGeometry = V.require("species_geometry")
local AnimatedSprites = V.require("animated_sprites")
local GameCompat = V.require("game_compat")
local SpriteProviders = V.require("sprite_providers")
local WaterSpriteRegistry = V.require("water_sprite_registry")
local SpriteResolver = V.require("sprite_resolver")
local VariableSize = V.require("variable_size")
local RuntimeSheets = V.require("runtime_sheets")

------------------------------------------------------------------------
-- SpeciesAssets API
------------------------------------------------------------------------

eq(SpeciesAssets.count(), 251, "maps Gen1+Gen2 (251 species)")
eq(SpeciesAssets.MAX_ID, 251, "MAX_ID is 251")

eq(SpeciesAssets.idFor("MEWTWO"), 150, "MEWTWO → 150")
eq(SpeciesAssets.idFor("TYRANITAR"), 248, "TYRANITAR → 248")
eq(SpeciesAssets.idFor("PIKACHU"), 25, "PIKACHU → 25")
eq(SpeciesAssets.idFor("MEW"), 151, "MEW → 151")
eq(SpeciesAssets.idFor("CHIKORITA"), 152, "CHIKORITA → 152")
eq(SpeciesAssets.idFor("SENTRET"), 161, "SENTRET → 161")
eq(SpeciesAssets.idFor("LUGIA"), 249, "LUGIA → 249")
eq(SpeciesAssets.idFor("HO_OH"), 250, "HO_OH → 250")
eq(SpeciesAssets.idFor("CELEBI"), 251, "CELEBI → 251")
eq(SpeciesAssets.idFor("mewtwo"), 150, "lowercase MEWTWO still maps")
eq(SpeciesAssets.idFor(150), 150, "numeric 150 passthrough")
eq(SpeciesAssets.idFor("150"), 150, "numeric string 150 passthrough")
eq(SpeciesAssets.speciesFor(150), "MEWTWO", "reverse 150 → MEWTWO")
eq(SpeciesAssets.speciesFor(248), "TYRANITAR", "reverse 248 → TYRANITAR")
eq(SpeciesAssets.has("MEWTWO"), true, "has MEWTWO")
eq(SpeciesAssets.has("BETA_MON_X"), false, "no asset for Fakemon")
eq(SpeciesAssets.idFor("BETA_MON_X"), nil, "Fakemon → nil")
eq(SpeciesAssets.idFor("Mewtwo"), nil, "display name Mewtwo rejected")
eq(SpeciesAssets.idFor("Mewtu"), nil, "localized Mewtu rejected")

------------------------------------------------------------------------
-- Reordered Pokédex must not affect asset identity
------------------------------------------------------------------------

local game = {
  data = { pokemon = reorderedPokemon },
  save = { options = { modOptions = {} } },
}

-- Runtime GameCompat still reflects reordered dex (gameplay).
eq(GameCompat.speciesId("MEWTWO", game, V.mod), 248,
  "GameCompat runtime MEWTWO dex stays 248 when reordered")
eq(GameCompat.speciesId("TYRANITAR", game, V.mod), 150,
  "GameCompat runtime TYRANITAR dex stays 150 when reordered")

-- AnimatedSprites.resolveSpeciesId still reads mon.dex (legacy runtime).
eq(AnimatedSprites.resolveSpeciesId("MEWTWO", game, V.mod), 248,
  "legacy resolveSpeciesId follows runtime dex (not used for assets)")

-- SpeciesAssets ignores runtime dex entirely.
eq(SpeciesAssets.idFor("MEWTWO"), 150,
  "reordered MEWTWO still canonical asset 150")
eq(SpeciesAssets.idFor("TYRANITAR"), 248,
  "reordered TYRANITAR still canonical asset 248")
eq(SpeciesAssets.idFor("BETA_MON_X"), nil,
  "Fakemon with runtime dex 150 still has no asset id")

------------------------------------------------------------------------
-- Providers / HGSS / Followers / True Size / Water
------------------------------------------------------------------------

local render = {
  runtimeSheets = RuntimeSheets.new(V.mod),
  fallbackPath = "assets/fallback/pokemon_missing.png",
  fallbackId = "SPRITE_OW_WILD_FALLBACK",
  _modAssetPath = function(_, rel) return "mods/overworld_wild_spawns/" .. rel end,
}
pcall(function() render.runtimeSheets:load() end)

local providers = SpriteProviders.new(V.mod, render)
providers:finalize(game)

-- HGSS / pokemmo
saved.sprite_style = "pokemmo"
local hgssMewtwo = providers:resolve("pokemmo", "MEWTWO", "normal", game)
check(hgssMewtwo and hgssMewtwo.def and hgssMewtwo.def.image, "HGSS MEWTWO resolves")
if hgssMewtwo and hgssMewtwo.def then
  check(tostring(hgssMewtwo.def.image):find("150") ~= nil,
    "HGSS MEWTWO uses asset 150 (not 248)")
  check(tostring(hgssMewtwo.def.image):find("248") == nil,
    "HGSS MEWTWO does not use 248")
end

local hgssTyranitar = providers:resolve("pokemmo", "TYRANITAR", "normal", game)
check(hgssTyranitar and hgssTyranitar.def and hgssTyranitar.def.image,
  "HGSS TYRANITAR resolves")
if hgssTyranitar and hgssTyranitar.def then
  check(tostring(hgssTyranitar.def.image):find("248") ~= nil,
    "HGSS TYRANITAR uses asset 248 (not 150)")
  check(tostring(hgssTyranitar.def.image):find("/150") == nil
     and tostring(hgssTyranitar.def.image):find("150%-") == nil,
    "HGSS TYRANITAR does not use Mewtwo asset 150")
end

-- Poké Followers
saved.sprite_style = "followers"
local folMewtwo = providers:resolve("followers", "MEWTWO", "normal", game)
check(folMewtwo and folMewtwo.def and folMewtwo.def.image, "Followers MEWTWO resolves")
if folMewtwo and folMewtwo.def then
  check(tostring(folMewtwo.def.image):find("150") ~= nil,
    "Followers MEWTWO uses follower_150 / asset 150")
  check(tostring(folMewtwo.def.image):find("248") == nil,
    "Followers MEWTWO does not use 248")
end

local folTyr = providers:resolve("followers", "TYRANITAR", "normal", game)
check(folTyr and folTyr.def and folTyr.def.image, "Followers TYRANITAR resolves")
if folTyr and folTyr.def then
  check(tostring(folTyr.def.image):find("248") ~= nil,
    "Followers TYRANITAR uses asset 248")
end

-- Fakemon → missing sprite (not Mewtwo)
local fake = providers:resolve("pokemmo", "BETA_MON_X", "normal", game)
check(fake ~= nil, "Fakemon resolve returns a result")
eq(fake and fake.providerId, "black", "Fakemon falls through to black/missing")
if fake and fake.def then
  check(tostring(fake.def.image):find("pokemon_missing") ~= nil
     or fake.meta and fake.meta.fallback == true,
    "Fakemon uses pokemon_missing.png fallback")
  check(tostring(fake.def.image):find("150") == nil
     or tostring(fake.def.image):find("pokemon_missing") ~= nil,
    "Fakemon must not show Mewtwo sheet")
end

-- True Size geometry
local goldGame = {
  data = { pokemon = reorderedPokemon },
  save = { options = { modOptions = {} } },
  world = { map = { id = "ROUTE_29" }, playerState = "walk" },
}
-- Force Gen2 adapter so normalizeDex allows 152..251.
do
  local Gen2 = V.require("game_compat/gen2")
  local origCurrent = GameCompat.current
  -- Prefer generation detection: goldWorld-like shape is enough for many
  -- paths; also stub generation when needed.
  local origGen = GameCompat.generation
  function GameCompat.generation(mod, game)
    if game == goldGame or (game and game.world and game.world.playerState ~= nil) then
      return 2
    end
    return origGen(mod, game)
  end
end

local geoMewtwo = SpeciesGeometry.entryFor(SpeciesAssets.idFor("MEWTWO"), V.mod, goldGame)
local geoTyr = SpeciesGeometry.entryFor(SpeciesAssets.idFor("TYRANITAR"), V.mod, goldGame)
check(geoMewtwo ~= nil, "True Size geometry for MEWTWO/150 exists")
check(geoTyr ~= nil, "True Size geometry for TYRANITAR/248 exists")
eq(SpeciesGeometry.normalizeDex(SpeciesAssets.idFor("MEWTWO"), goldGame), 150,
  "True Size key for MEWTWO is 150")
eq(SpeciesGeometry.normalizeDex(SpeciesAssets.idFor("TYRANITAR"), goldGame), 248,
  "True Size key for TYRANITAR is 248")

-- VariableSize must use species string → asset id, not runtime dex
local landRel = select(1, SpeciesGeometry.relativePath(150, "pokemmo", "normal", V.mod))
local landDef = {
  image = landRel or "assets/generated/true_size/hgss/150-normal.png",
  frames = 6, walker = true, trueColor = true, id = "T150",
}
landDef = VariableSize.applyToDef(V.mod, landDef, {
  speciesId = "MEWTWO",
  game = goldGame,
  style = "pokemmo",
  packId = "pokemmo",
  variant = "normal",
})
check(landDef and tonumber(landDef.frameWidth) and landDef.frameWidth > 0,
  "True Size applyToDef via MEWTWO species string")
local pack150 = select(1, SpeciesGeometry.packGeometry(150, "pokemmo", V.mod))
if pack150 and landDef then
  eq(landDef.frameWidth, pack150.frameWidth,
    "True Size MEWTWO geometry matches asset 150 (not 248)")
end

-- Water registry / swimming
local waterReg = WaterSpriteRegistry.new(V.mod)
pcall(function() waterReg:load() end)
local resolver = SpriteResolver.new(V.mod, providers, waterReg)

local function waterEntity(species, runtimeDex)
  return {
    species = species,
    dex = runtimeDex,
    enhancedDexId = nil, -- must derive from species, not runtime dex
    surface = "water",
    behavior = "WATER_IDLE",
  }
end

saved.sprite_style = "pokemmo"
local swimMewtwo = resolver:resolveWaterSprite(waterEntity("MEWTWO", 248), {
  style = "pokemmo",
  game = game,
  variant = "normal",
})
check(swimMewtwo and swimMewtwo.def and swimMewtwo.def.image, "Swimming MEWTWO resolves")
if swimMewtwo and swimMewtwo.def then
  check(tostring(swimMewtwo.def.image):find("150") ~= nil,
    "Swimming MEWTWO uses asset 150")
  check(tostring(swimMewtwo.def.image):find("248") == nil,
    "Swimming MEWTWO does not use swimming/248")
end

local swimTyr = resolver:resolveWaterSprite(waterEntity("TYRANITAR", 150), {
  style = "pokemmo",
  game = game,
  variant = "normal",
})
check(swimTyr and swimTyr.def and swimTyr.def.image, "Swimming TYRANITAR resolves")
if swimTyr and swimTyr.def then
  check(tostring(swimTyr.def.image):find("248") ~= nil,
    "Swimming TYRANITAR uses asset 248")
end

local swimFake = resolver:resolveLandSprite({
  species = "BETA_MON_X", dex = 150, surface = "grass",
}, { style = "pokemmo", game = game })
check(swimFake and swimFake.providerId == "black",
  "Land Fakemon → missing/black, not Mewtwo")

------------------------------------------------------------------------
-- Follower sprite service
------------------------------------------------------------------------

local SpriteService = V.require("follower/sprite_service")
local svc = SpriteService.new(V.mod, { render = render, logic = nil })
eq(svc:assetIdOf("MEWTWO"), 150, "follower assetIdOf MEWTWO → 150")
eq(svc:dexOf("MEWTWO", game), 248, "follower dexOf keeps runtime 248")

local folSvc = svc:resolveFollowerSprite({
  species = "MEWTWO", shiny = false, style = "pokemmo",
  surface = "land", role = "primary", game = game,
})
check(folSvc and folSvc.image, "follower service MEWTWO resolves")
eq(folSvc and folSvc.assetId, 150, "follower service assetId 150")
eq(folSvc and folSvc.dex, 248, "follower service runtime dex field 248")
if folSvc then
  check(tostring(folSvc.image):find("150") ~= nil,
    "follower service image uses asset 150")
end

local fakeSvc = svc:resolveFollowerSprite({
  species = "BETA_MON_X", shiny = false, style = "pokemmo",
  surface = "land", role = "primary", game = game,
})
check(fakeSvc and fakeSvc.fallback == true, "follower Fakemon → missing fallback")
if fakeSvc then
  check(tostring(fakeSvc.image):find("pokemon_missing") ~= nil,
    "follower Fakemon image is pokemon_missing.png")
end

------------------------------------------------------------------------
-- Vanilla Gen1 / Gen2 regressions (canonical == expected)
------------------------------------------------------------------------

local vanilla = {
  PIKACHU = 25, MEWTWO = 150, MEW = 151,
  CHIKORITA = 152, SENTRET = 161, TYRANITAR = 248,
  LUGIA = 249, HO_OH = 250, CELEBI = 251,
  RATTATA = 19, BLASTOISE = 9, ONIX = 95,
}
for species, id in pairs(vanilla) do
  eq(SpeciesAssets.idFor(species), id, "vanilla " .. species .. " → " .. id)
end

-- True Size snapshot species still resolve to same geometry keys
local geomTable = SpeciesGeometry.load(V.mod)
for _, pair in ipairs({
  { "RATTATA", 19 }, { "BLASTOISE", 9 }, { "ONIX", 95 },
  { "MEWTWO", 150 }, { "TYRANITAR", 248 },
}) do
  eq(SpeciesAssets.idFor(pair[1]), pair[2],
    "True Size regression " .. pair[1] .. " asset id")
  local entry = geomTable[pair[2]]
  local g = entry and entry.packs and entry.packs.pokemmo
  check(g and tonumber(g.frameWidth) and g.frameWidth > 0,
    "True Size regression " .. pair[1] .. " geometry present")
end

------------------------------------------------------------------------
-- Language independence: internal key only
------------------------------------------------------------------------

eq(SpeciesAssets.idFor("MEWTWO"), SpeciesAssets.idFor("mewtwo"),
  "case-insensitive internal key")
check(SpeciesAssets.idFor("Mewtwo") == nil
   and SpeciesAssets.idFor("MEWTWO") == 150,
  "display-name vs internal-key separation")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll species_assets tests passed.")
