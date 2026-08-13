-- Gold / Gen1 SpriteDef.trueColor contract for land Wilds.
-- Run: luajit tests/gen2_sprite_color_unit_test.lua
--
-- Gold's world is GbcPalette + SpriteRenderer trueColor, not Gen1 PaletteFX
-- zone-shader. Serving luminance sheets with trueColor=false on Gold bakes
-- PaletteFX.dmgObj() and HGSS / Poké Followers draw monochrome.
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

local savedOpts = {
  sprite_style = "pokemmo",
  wild_silhouettes = nil,
  debug_logging = false,
  dev_overlay = false,
}
local fsPaths = {}

love = love or {}
love.filesystem = {
  getInfo = function(path)
    if fsPaths[path] then return { type = "file" } end
    local f = io.open(path, "rb") or io.open("./" .. tostring(path), "rb")
    if f then f:close(); return { type = "file" } end
    return nil
  end,
}

-- True Size / swimming luma only run when SpriteRenderer exposes geometry APIs.
package.preload["src.render.SpriteRenderer"] = function()
  local SR = {
    DEFAULT_FRAME_WIDTH = 16,
    DEFAULT_FRAME_HEIGHT = 16,
    DEFAULT_ANCHOR_X = 8,
    DEFAULT_ANCHOR_Y = 16,
  }
  function SR:getFrameGeometry(frame)
    return {
      frame = frame or 0, x = 0, y = 0,
      width = self.frameWidth or 16, height = self.frameHeight or 16,
      anchorX = self.anchorX or 8, anchorY = self.anchorY or 16,
    }
  end
  function SR:getPoseGeometry(facing, walkPhase, stepFlip)
    local g = self:getFrameGeometry(0)
    g.facing, g.walkPhase, g.stepFlip = facing, walkPhase, stepFlip
    g.mirror = facing == "right"
    return g
  end
  function SR:getScreenOrigin() return 0, 0 end
  return SR
end

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end, error = function() end },
    find = function() return nil end,
    options = {
      get = function(_, key) return savedOpts[key] end,
      set = function(_, key, value) savedOpts[key] = value end,
    },
    assets = {
      path = function(_, rel) return rel end,
    },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    content = {
      pokemon = {
        get = function() return nil end,
        each = function() return function() end end,
      },
      sprites = { get = function() return nil end },
    },
    world = {
      game = {
        save = { options = { modOptions = { overworld_wild_spawns = savedOpts } } },
        mods = { modOptions = { overworld_wild_spawns = savedOpts } },
      },
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

local function setEngineVersion(v)
  if v == nil then
    package.loaded["src.core.GameVersion"] = nil
    return
  end
  local id = string.lower(tostring(v))
  package.loaded["src.core.GameVersion"] = {
    get = function() return id end,
    isYellow = function() return id == "yellow" end,
    isGold = function() return id == "gold" end,
    generation = function(which)
      which = which or id
      if which == "gold" or which == "silver" or which == "crystal" then
        return 2
      end
      if which == "red" or which == "blue" or which == "yellow" then
        return 1
      end
      error("unknown GameVersion id: " .. tostring(which))
    end,
  }
end

local function setPaletteMode(mode)
  package.loaded["src.render.PaletteFX"] = { mode = mode }
end

-- Derive-luma / silhouette in this harness: tag the path instead of encoding pixels.
local LuminanceSheet = V.require("luminance_sheet")
function LuminanceSheet.pathFor(src)
  if type(src) ~= "string" or src == "" then return nil end
  if src:sub(1, 5) == "luma:" or src:sub(1, 5) == "silo:" then return src end
  return "luma:" .. src
end
function LuminanceSheet.silhouetteFor(src)
  if type(src) ~= "string" or src == "" then return nil end
  if src:sub(1, 5) == "silo:" then return src end
  return "silo:" .. src
end
function LuminanceSheet.submergedFor(src)
  if type(src) ~= "string" or src == "" then return nil end
  if src:sub(1, 4) == "sub:" then return src end
  return "sub:" .. src
end
function LuminanceSheet.available()
  return true
end

local Config = V.require("config")
local GameCompat = V.require("game_compat")
local Surface = V.require("surface")
local RuntimeSheets = V.require("runtime_sheets")
local SpriteProviders = V.require("sprite_providers")
local SpriteResolver = V.require("sprite_resolver")
local VariableSize = V.require("variable_size")
VariableSize.clearCaches()
local WaterSpriteRegistry = V.require("water_sprite_registry")

local render = {
  runtimeSheets = RuntimeSheets.new(V.mod),
  registrationInfo = {},
  fallbackPath = "assets/fallback/pokemon_missing.png",
  fallbackId = "SPRITE_OW_WILD_FALLBACK",
  _modAssetPath = function(_, rel) return rel end,
  _fallbackPath = function() return "assets/fallback/pokemon_missing.png" end,
}
check(render.runtimeSheets:load() == true, "runtime HGSS sheets load")

local providers = SpriteProviders.new(V.mod, render)
local waterReg = WaterSpriteRegistry.new(V.mod)
check(waterReg:load() == true, "water sprite registry loads")
local resolver = SpriteResolver.new(V.mod, providers, waterReg)

local SPECIES = {
  PIDGEY = 16,
  RATTATA = 19,
  PIKACHU = 25,
  POLIWAG = 60,
  ABRA = 63,
  GYARADOS = 130,
  LAPRAS = 131,
  BLASTOISE = 9,
  CHIKORITA = 152,
  CYNDAQUIL = 155,
  SENTRET = 161,
}

local function copySpawnRenderDef(resultDef, species)
  local def = {
    image = resultDef.image,
    frames = resultDef.frames or 1,
    trueColor = resultDef.trueColor ~= false,
    id = resultDef.id or ("SPRITE_OW_WILD_" .. tostring(species)),
    frameWidth = resultDef.frameWidth,
    frameHeight = resultDef.frameHeight,
    anchorX = resultDef.anchorX,
    anchorY = resultDef.anchorY,
  }
  if resultDef.walker == true then def.walker = true end
  for k, v in pairs(resultDef) do
    if def[k] == nil then def[k] = v end
  end
  return def
end

local function isLumaPath(path)
  return type(path) == "string" and path:sub(1, 5) == "luma:"
end
local function isSiloPath(path)
  return type(path) == "string" and path:sub(1, 5) == "silo:"
end
local function isSubPath(path)
  return type(path) == "string" and path:sub(1, 4) == "sub:"
end

------------------------------------------------------------------------
-- Schema / Config defaults
------------------------------------------------------------------------

local schema = assert(loadfile("options.lua"))()
local byKey = {}
for _, row in ipairs(schema) do byKey[row.key] = row end
eq(byKey.wild_silhouettes.default, false, "options.lua wild_silhouettes default false")
eq(Config.DEFAULTS.wild_silhouettes, false, "Config.DEFAULTS.wild_silhouettes false")

savedOpts.wild_silhouettes = nil
eq(Config.wildSilhouettes(V.mod), false, "unset wildSilhouettes is false")

savedOpts.wild_silhouettes = true
eq(Config.wildSilhouettes(V.mod), true, "explicit wildSilhouettes true is honored")
savedOpts.wild_silhouettes = false
eq(Config.wildSilhouettes(V.mod), false, "explicit wildSilhouettes false is honored")
savedOpts.wild_silhouettes = nil

------------------------------------------------------------------------
-- landArtUsesLuminance: Gold never, Gen1 follows PaletteFX.redpp
------------------------------------------------------------------------

setPaletteMode("gbc")
setEngineVersion("gold")
eq(GameCompat.generation(V.mod), 2, "gold generation is 2")
eq(Config.landArtUsesLuminance(V.mod), false, "Gold gbc: land art stays colored")
eq(Config.waterArtUsesLuminance(V.mod), false, "Gold gbc: water art stays colored")
eq(Config.spriteTrueColor(V.mod), false, "spriteTrueColor still equals paletteFxRedpp (gbc)")
eq(Config.paletteFxRedpp(), false, "gbc is not redpp")

setEngineVersion("red")
eq(GameCompat.generation(V.mod), 1, "red generation is 1")
eq(Config.landArtUsesLuminance(V.mod), true, "Red non-redpp: land uses luminance")
eq(Config.waterArtUsesLuminance(V.mod), true, "Red non-redpp: water uses luminance")
eq(Config.spriteTrueColor(V.mod), false, "Red gbc/classic: spriteTrueColor false")

setEngineVersion("blue")
eq(Config.landArtUsesLuminance(V.mod), true, "Blue non-redpp: land uses luminance")
setEngineVersion("yellow")
eq(Config.landArtUsesLuminance(V.mod), true, "Yellow non-redpp: land uses luminance")

setPaletteMode("redpp")
setEngineVersion("red")
eq(Config.landArtUsesLuminance(V.mod), false, "Red ADVANCED: land skips luminance")
eq(Config.spriteTrueColor(V.mod), true, "Red ADVANCED: spriteTrueColor true")
setEngineVersion("gold")
eq(Config.landArtUsesLuminance(V.mod), false, "Gold ADVANCED: land still skips luminance")

setPaletteMode("gbc")

------------------------------------------------------------------------
-- GOLD HGSS land: original color, trueColor=true, no luma conversion
------------------------------------------------------------------------

setEngineVersion("gold")
savedOpts.sprite_style = "pokemmo"
savedOpts.wild_silhouettes = nil

local function assertGoldHgss(name, dex)
  local r = providers:resolve("pokemmo", dex, "normal", nil)
  check(r ~= nil, "Gold HGSS resolve " .. name)
  if not r then return end
  eq(r.providerId, "pokemmo", "Gold HGSS " .. name .. " provider pokemmo")
  eq(r.def.trueColor, true, "Gold HGSS " .. name .. " trueColor true")
  check(not isLumaPath(r.def.image), "Gold HGSS " .. name .. " image is not a luma sheet")
  check(not isSiloPath(r.def.image), "Gold HGSS " .. name .. " image is not a silhouette")
  local copied = copySpawnRenderDef(r.def, name)
  eq(copied.trueColor, true, "Gold HGSS " .. name .. " SpawnRender copy keeps trueColor")
  check(copied.frameWidth == r.def.frameWidth, "Gold HGSS " .. name .. " frameWidth copied")
  check(copied.frameHeight == r.def.frameHeight, "Gold HGSS " .. name .. " frameHeight copied")
end

assertGoldHgss("SENTRET", SPECIES.SENTRET)
assertGoldHgss("CHIKORITA", SPECIES.CHIKORITA)
assertGoldHgss("CYNDAQUIL", SPECIES.CYNDAQUIL)
assertGoldHgss("PIDGEY", SPECIES.PIDGEY)

local land = resolver:resolveLandSprite({
  species = "SENTRET", enhancedDexId = SPECIES.SENTRET, surface = Surface.GRASS,
}, { style = "pokemmo", speciesId = SPECIES.SENTRET })
check(land ~= nil, "Gold HGSS resolver land SENTRET")
if land then
  eq(land.def.trueColor, true, "Gold HGSS resolver SENTRET trueColor true")
  eq(land.wildSilhouette == true, false, "Gold HGSS silhouettes OFF does not flag SENTRET")
end

------------------------------------------------------------------------
-- GOLD Poké Followers land: colored PNG, trueColor=true, no land luma
------------------------------------------------------------------------

savedOpts.sprite_style = "followers"

local function assertGoldFollowers(name, dex)
  local r = providers:resolve("followers", dex, "normal", nil)
  check(r ~= nil, "Gold Followers resolve " .. name)
  if not r then return end
  eq(r.providerId, "followers_ex", "Gold Followers " .. name .. " provider followers_ex")
  eq(r.def.trueColor, true, "Gold Followers " .. name .. " trueColor true")
  check(not isLumaPath(r.def.image), "Gold Followers " .. name .. " skipped LuminanceSheet.pathFor")
  check(type(r.def.image) == "string"
        and r.def.image:find("poke_followers", 1, true) ~= nil,
        "Gold Followers " .. name .. " serves poke_followers art")
  local copied = copySpawnRenderDef(r.def, name)
  eq(copied.trueColor, true, "Gold Followers " .. name .. " SpawnRender copy keeps trueColor")
end

assertGoldFollowers("SENTRET", SPECIES.SENTRET)
assertGoldFollowers("PIDGEY", SPECIES.PIDGEY)

------------------------------------------------------------------------
-- Silhouettes ON: land encounter only, trueColor=false, wildSilhouette=true
------------------------------------------------------------------------

savedOpts.sprite_style = "pokemmo"
savedOpts.wild_silhouettes = true
setEngineVersion("gold")

local silo = resolver:resolveLandSprite({
  species = "SENTRET", enhancedDexId = SPECIES.SENTRET, surface = Surface.GRASS,
}, { style = "pokemmo", speciesId = SPECIES.SENTRET })
check(silo ~= nil, "Gold silhouette resolve SENTRET")
if silo then
  eq(silo.wildSilhouette, true, "Gold silhouette wildSilhouette true")
  eq(silo.def.trueColor, false, "Gold silhouette trueColor false")
  check(isSiloPath(silo.def.image), "Gold silhouette image is silhouette sheet")
  local copied = copySpawnRenderDef(silo.def, "SENTRET")
  eq(copied.trueColor, false, "Gold silhouette SpawnRender copy keeps trueColor false")
end

local siloOffMap = resolver:resolveLandSprite({
  species = "SENTRET", enhancedDexId = SPECIES.SENTRET, surface = Surface.INTERIOR,
}, { style = "pokemmo", speciesId = SPECIES.SENTRET })
if siloOffMap then
  eq(siloOffMap.wildSilhouette == true, false,
     "Gold silhouette does not apply outside grass/cave")
  eq(siloOffMap.def.trueColor, true, "Gold interior SENTRET stays colored")
end

savedOpts.wild_silhouettes = nil
silo = resolver:resolveLandSprite({
  species = "SENTRET", enhancedDexId = SPECIES.SENTRET, surface = Surface.GRASS,
}, { style = "pokemmo", speciesId = SPECIES.SENTRET })
if silo then
  eq(silo.wildSilhouette == true, false, "Gold default is not silhouette")
  eq(silo.def.trueColor, true, "Gold default grass SENTRET stays colored")
end

------------------------------------------------------------------------
-- GEN1 HGSS / Followers: luminance contract unchanged (non-ADVANCED)
------------------------------------------------------------------------

local function assertGen1LumaLand(version, style, name, dex, providerId)
  setEngineVersion(version)
  setPaletteMode("gbc")
  savedOpts.sprite_style = style
  savedOpts.wild_silhouettes = nil
  local r = providers:resolve(style, dex, "normal", nil)
  check(r ~= nil, version .. " " .. style .. " resolve " .. name)
  if not r then return end
  eq(r.providerId, providerId, version .. " " .. style .. " " .. name .. " provider")
  eq(r.def.trueColor, false, version .. " " .. style .. " " .. name .. " trueColor false")
  check(isLumaPath(r.def.image),
        version .. " " .. style .. " " .. name .. " served via LuminanceSheet")
end

assertGen1LumaLand("red", "pokemmo", "PIDGEY", SPECIES.PIDGEY, "pokemmo")
assertGen1LumaLand("blue", "pokemmo", "PIDGEY", SPECIES.PIDGEY, "pokemmo")
assertGen1LumaLand("yellow", "pokemmo", "PIDGEY", SPECIES.PIDGEY, "pokemmo")
assertGen1LumaLand("red", "followers", "PIDGEY", SPECIES.PIDGEY, "followers_ex")
assertGen1LumaLand("blue", "followers", "PIDGEY", SPECIES.PIDGEY, "followers_ex")
assertGen1LumaLand("yellow", "followers", "PIDGEY", SPECIES.PIDGEY, "followers_ex")

-- Gen1 ADVANCED keeps colored land art.
setEngineVersion("red")
setPaletteMode("redpp")
savedOpts.sprite_style = "pokemmo"
local adv = providers:resolve("pokemmo", SPECIES.PIDGEY, "normal", nil)
check(adv ~= nil, "Red ADVANCED HGSS Pidgey resolves")
if adv then
  eq(adv.def.trueColor, true, "Red ADVANCED HGSS Pidgey trueColor true")
  check(not isLumaPath(adv.def.image), "Red ADVANCED HGSS Pidgey is not luma")
end
local advF = providers:resolve("followers", SPECIES.PIDGEY, "normal", nil)
if advF then
  eq(advF.def.trueColor, true, "Red ADVANCED Followers Pidgey trueColor true")
  check(not isLumaPath(advF.def.image), "Red ADVANCED Followers Pidgey is not luma")
end

------------------------------------------------------------------------
-- Water: Gold keeps colored custom art; Gen1 luminance unchanged
------------------------------------------------------------------------

local function applySwim(dex, presentation, packId)
  presentation = presentation or "swimming"
  packId = packId or "swimming"
  local def = {
    image = "assets/generated/followsprites_runtime/016-normal.png",
    frames = 6,
    walker = true,
    trueColor = true,
    id = "SPRITE_OW_WILD_WATER_" .. tostring(dex),
  }
  return VariableSize.applyToDef(V.mod, def, {
    speciesId = dex,
    style = savedOpts.sprite_style or "pokemmo",
    presentation = presentation,
    packId = packId,
  })
end

local function waterEntity(dex, name)
  return {
    species = name or tostring(dex),
    enhancedDexId = dex,
    surface = Surface.WATER,
    behavior = "WATER_IDLE",
  }
end

setPaletteMode("gbc")
setEngineVersion("gold")
savedOpts.sprite_style = "pokemmo"
savedOpts.wild_silhouettes = nil

local function assertGoldHgssWater(name, dex, kind)
  kind = kind or "swimming"
  local pack = (kind == "levitate" or kind == "levitates") and "levitate" or "swimming"
  local out = applySwim(dex, pack, pack)
  eq(out.trueColor, true, "Gold HGSS " .. kind .. " " .. name .. " trueColor true")
  check(not isLumaPath(out.image), "Gold HGSS " .. kind .. " " .. name .. " is not luma")
  check(tonumber(out.frameWidth) ~= nil, "Gold HGSS " .. kind .. " " .. name .. " frameWidth")
  check(tonumber(out.frameHeight) ~= nil, "Gold HGSS " .. kind .. " " .. name .. " frameHeight")
  check(tonumber(out.anchorX) ~= nil, "Gold HGSS " .. kind .. " " .. name .. " anchorX")
  check(tonumber(out.anchorY) ~= nil, "Gold HGSS " .. kind .. " " .. name .. " anchorY")
  local fw, fh, ax, ay = out.frameWidth, out.frameHeight, out.anchorX, out.anchorY
  local r = resolver:resolveWaterSprite(waterEntity(dex, name), {
    style = "pokemmo", speciesId = dex, variant = "normal",
  })
  check(r ~= nil and r.def ~= nil, "Gold HGSS resolver water " .. name)
  if r and r.def then
    eq(r.def.trueColor, true, "Gold HGSS resolver " .. name .. " trueColor true")
    check(not isLumaPath(r.def.image), "Gold HGSS resolver " .. name .. " is not luma")
    eq(r.def.frameWidth, fw, "Gold HGSS resolver " .. name .. " frameWidth unchanged")
    eq(r.def.frameHeight, fh, "Gold HGSS resolver " .. name .. " frameHeight unchanged")
    eq(r.def.anchorX, ax, "Gold HGSS resolver " .. name .. " anchorX unchanged")
    eq(r.def.anchorY, ay, "Gold HGSS resolver " .. name .. " anchorY unchanged")
  end
end

assertGoldHgssWater("RATTATA", SPECIES.RATTATA, "swimming")
assertGoldHgssWater("POLIWAG", SPECIES.POLIWAG, "swimming")
assertGoldHgssWater("BLASTOISE", SPECIES.BLASTOISE, "swimming")
assertGoldHgssWater("LAPRAS", SPECIES.LAPRAS, "swimming")
assertGoldHgssWater("GYARADOS", SPECIES.GYARADOS, "swimming")
assertGoldHgssWater("ABRA", SPECIES.ABRA, "levitate")

-- Shiny HGSS water keeps variant + color
do
  local shiny = resolver:resolveWaterSprite(waterEntity(SPECIES.RATTATA, "RATTATA"), {
    style = "pokemmo", speciesId = SPECIES.RATTATA, variant = "shiny",
  })
  check(shiny ~= nil and shiny.def ~= nil, "Gold HGSS shiny Rattata water")
  if shiny and shiny.def then
    eq(shiny.def.trueColor, true, "Gold HGSS shiny water trueColor true")
    check(not isLumaPath(shiny.def.image), "Gold HGSS shiny water is not luma")
    local v = (shiny.meta and shiny.meta.usedVariant) or shiny.def.variant
    check(v == "shiny" or v == "normal", "Gold HGSS shiny water keeps a variant")
  end
end

-- Followers submerged: colored subPath, no pathFor
savedOpts.sprite_style = "followers"
local function assertGoldFollowersWater(name, dex)
  local r = resolver:resolveWaterSprite(waterEntity(dex, name), {
    style = "followers", speciesId = dex, variant = "normal",
  })
  check(r ~= nil and r.def ~= nil, "Gold Followers water " .. name)
  if not r or not r.def then return end
  eq(r.providerId, "poke_followers_submerged", "Gold Followers water " .. name .. " provider")
  eq(r.def.trueColor, true, "Gold Followers water " .. name .. " trueColor true")
  check(isSubPath(r.def.image), "Gold Followers water " .. name .. " uses colored submergedFor")
  check(not isLumaPath(r.def.image), "Gold Followers water " .. name .. " skipped pathFor")
  eq(r.spriteKind, "submerged", "Gold Followers water " .. name .. " kind submerged")
end

assertGoldFollowersWater("SENTRET", SPECIES.SENTRET)
assertGoldFollowersWater("RATTATA", SPECIES.RATTATA)
assertGoldFollowersWater("PIKACHU", SPECIES.PIKACHU)

do
  local shiny = resolver:resolveWaterSprite(waterEntity(SPECIES.PIKACHU, "PIKACHU"), {
    style = "followers", speciesId = SPECIES.PIKACHU, variant = "shiny",
  })
  check(shiny ~= nil and shiny.def ~= nil, "Gold Followers shiny Pikachu water")
  if shiny and shiny.def then
    eq(shiny.def.trueColor, true, "Gold Followers shiny water trueColor true")
    check(not isLumaPath(shiny.def.image), "Gold Followers shiny water skipped pathFor")
    eq(shiny.meta.usedVariant, "shiny", "Gold Followers shiny water keeps shiny variant")
  end
end

-- Encounter silhouettes still black-out Gold water
savedOpts.sprite_style = "pokemmo"
savedOpts.wild_silhouettes = true
do
  local silo = resolver:resolveWaterSprite(waterEntity(SPECIES.RATTATA, "RATTATA"), {
    style = "pokemmo", speciesId = SPECIES.RATTATA, variant = "normal",
  })
  check(silo ~= nil and silo.def ~= nil, "Gold water silhouette resolves")
  if silo and silo.def then
    eq(silo.def.trueColor, false, "Gold water silhouette trueColor false")
    check(silo.wildSilhouette == true or isSiloPath(silo.def.image),
          "Gold water silhouette flagged or silo image")
  end
end
savedOpts.wild_silhouettes = nil

setPaletteMode("redpp")
setEngineVersion("gold")
savedOpts.sprite_style = "pokemmo"
local waterOut = applySwim(SPECIES.PIDGEY)
eq(waterOut.trueColor, true, "ADVANCED swimming pack: trueColor true")
check(not isLumaPath(waterOut.image), "ADVANCED swimming pack skips luma")

setEngineVersion("red")
setPaletteMode("gbc")
savedOpts.sprite_style = "pokemmo"
waterOut = applySwim(SPECIES.PIDGEY)
eq(waterOut.trueColor, false, "Red gbc swimming pack: luminance trueColor false")
check(isLumaPath(waterOut.image), "Red gbc swimming pack derives luma")

setEngineVersion("blue")
waterOut = applySwim(SPECIES.PIDGEY)
eq(waterOut.trueColor, false, "Blue gbc swimming pack: luminance trueColor false")

setEngineVersion("yellow")
waterOut = applySwim(SPECIES.PIDGEY)
eq(waterOut.trueColor, false, "Yellow gbc swimming pack: luminance trueColor false")

savedOpts.sprite_style = "followers"
setEngineVersion("red")
do
  local r = resolver:resolveWaterSprite(waterEntity(SPECIES.PIKACHU, "PIKACHU"), {
    style = "followers", speciesId = SPECIES.PIKACHU, variant = "normal",
  })
  check(r ~= nil and r.def ~= nil, "Red Followers water Pikachu")
  if r and r.def then
    eq(r.def.trueColor, false, "Red Followers water trueColor false")
    check(isLumaPath(r.def.image), "Red Followers water still uses pathFor")
  end
end
setEngineVersion("blue")
do
  local r = resolver:resolveWaterSprite(waterEntity(SPECIES.PIKACHU, "PIKACHU"), {
    style = "followers", speciesId = SPECIES.PIKACHU, variant = "normal",
  })
  if r and r.def then
    eq(r.def.trueColor, false, "Blue Followers water trueColor false")
  end
end
setEngineVersion("yellow")
do
  local r = resolver:resolveWaterSprite(waterEntity(SPECIES.PIKACHU, "PIKACHU"), {
    style = "followers", speciesId = SPECIES.PIKACHU, variant = "normal",
  })
  if r and r.def then
    eq(r.def.trueColor, false, "Yellow Followers water trueColor false")
  end
end

------------------------------------------------------------------------
-- Gen2 entity adapt does not strip sprite.trueColor
------------------------------------------------------------------------

setEngineVersion("gold")
local entity = {
  sprite = { trueColor = true, image = "colored.png" },
  draw = function() end,
  update = function() end,
}
GameCompat.adaptWildEntity(entity, { generation = 2 })
eq(entity.sprite.trueColor, true, "Gold adaptWildEntity keeps sprite.trueColor")
check(entity._wildsGoldAdapted == true, "Gold entity is adapted")

------------------------------------------------------------------------
-- SpawnRender source still copies trueColor / logs the bound def
------------------------------------------------------------------------

local spawnSrc = assert(io.open("lib/spawn_render.lua", "r")):read("*a")
check(spawnSrc:find("trueColor = resolvedProvider.def.trueColor ~= false", 1, true),
      "Entity.new copies provider trueColor")
check(spawnSrc:find("trueColor = result.def.trueColor ~= false", 1, true),
      "applyProviderSprite copies provider trueColor")
check(spawnSrc:find("[Wilds][Color]", 1, true),
      "DEV [Wilds][Color] log is present before SpriteRenderer")
local resolverSrc = assert(io.open("lib/sprite_resolver.lua", "r")):read("*a")
check(resolverSrc:find("[Wilds][Gen2][WaterColor]", 1, true),
      "DEV [Wilds][Gen2][WaterColor] log is present")
check(spawnSrc:find("if def[k] == nil then def[k] = v end", 1, true)
      or spawnSrc:find("if drawDef[k] == nil then drawDef[k] = v end", 1, true),
      "SpawnRender copies remaining SpriteDef keys (artFamily)")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("all gen2 sprite color checks passed")
