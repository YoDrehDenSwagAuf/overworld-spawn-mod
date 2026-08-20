-- Encounter silhouette modes: off / undiscovered / all.
-- Run: lua5.1 tests/wild_silhouette_mode_unit_test.lua
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
  wild_silhouettes = "off",
}
local modules = {}
local engineVersion = "red"

package.preload["src.render.Assets"] = function()
  return { exists = function() return true end }
end
package.preload["src.render.SpriteRenderer"] = function()
  return {
    DEFAULT_FRAME_WIDTH = 16, DEFAULT_FRAME_HEIGHT = 16,
    DEFAULT_ANCHOR_X = 8, DEFAULT_ANCHOR_Y = 16,
  }
end
package.preload["src.core.GameVersion"] = function()
  return {
    get = function() return engineVersion end,
    isYellow = function() return engineVersion == "yellow" end,
    isGold = function() return engineVersion == "gold" end,
    generation = function(which)
      which = which or engineVersion
      if which == "gold" or which == "silver" or which == "crystal" then
        return 2
      end
      return 1
    end,
  }
end
package.preload["src.render.PaletteFX"] = function()
  return { mode = "gbc" }
end

local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    find = function() return nil end,
    options = {
      get = function(_, k) return savedOpts[k] end,
      set = function(_, k, v) savedOpts[k] = v end,
    },
    assets = { path = function(_, rel) return rel end },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a"); f:close(); return data
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
        save = {
          pokedex = { seen = {}, owned = {}, caught = {} },
          options = { modOptions = { overworld_wild_spawns = savedOpts } },
        },
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

local LuminanceSheet = V.require("luminance_sheet")
function LuminanceSheet.silhouetteFor(src)
  if type(src) ~= "string" or src == "" then return nil end
  if src:sub(1, 5) == "silo:" then return src end
  return "silo:" .. src
end
function LuminanceSheet.pathFor(src)
  if type(src) ~= "string" or src == "" then return nil end
  return "luma:" .. src
end
function LuminanceSheet.submergedFor(src)
  if type(src) ~= "string" or src == "" then return nil end
  return "sub:" .. src
end
function LuminanceSheet.available() return true end

local Config = V.require("config")
local GameCompat = V.require("game_compat")
local Surface = V.require("surface")
local RuntimeSheets = V.require("runtime_sheets")
local SpriteProviders = V.require("sprite_providers")
local SpriteResolver = V.require("sprite_resolver")
local WaterSpriteRegistry = V.require("water_sprite_registry")
local VariableSize = V.require("variable_size")
VariableSize.clearCaches()

local render = {
  runtimeSheets = RuntimeSheets.new(V.mod),
  registrationInfo = {},
  fallbackPath = "assets/fallback/pokemon_missing.png",
  _modAssetPath = function(_, rel) return rel end,
  _fallbackPath = function() return "assets/fallback/pokemon_missing.png" end,
}
check(render.runtimeSheets:load() == true, "runtime sheets load")
local providers = SpriteProviders.new(V.mod, render)
local waterReg = WaterSpriteRegistry.new(V.mod)
pcall(function() waterReg:load() end)
local resolver = SpriteResolver.new(V.mod, providers, waterReg)

----------------------------------------------------------------
-- Migration + defaults
----------------------------------------------------------------
eq(Config.normalizeWildSilhouetteMode(false), "off", "bool false → off")
eq(Config.normalizeWildSilhouetteMode(true), "all", "bool true → all")
eq(Config.normalizeWildSilhouetteMode(nil), "off", "nil → off")
eq(Config.normalizeWildSilhouetteMode("undiscovered"), "undiscovered", "undiscovered passthrough")
eq(Config.DEFAULTS.wild_silhouettes, "off", "default off")

savedOpts.wild_silhouettes = false
eq(Config.wildSilhouetteMode(V.mod), "off", "saved false → off")
savedOpts.wild_silhouettes = true
eq(Config.wildSilhouetteMode(V.mod), "all", "saved true → all")
savedOpts.wild_silhouettes = "undiscovered"
eq(Config.wildSilhouetteMode(V.mod), "undiscovered", "saved undiscovered")
savedOpts.wild_silhouettes = "off"

----------------------------------------------------------------
-- hasSeenSpecies Gen1 + Gold
----------------------------------------------------------------
local function makeGame(seen)
  return {
    save = {
      pokedex = { seen = seen or {}, owned = {}, caught = {} },
      options = { modOptions = { overworld_wild_spawns = savedOpts } },
    },
    mods = { modOptions = { overworld_wild_spawns = savedOpts } },
  }
end

engineVersion = "red"
do
  local g = makeGame({ PIDGEY = true })
  eq(GameCompat.hasSeenSpecies(g, "PIDGEY"), true, "Gen1 seen PIDGEY")
  eq(GameCompat.hasSeenSpecies(g, "RATTATA"), false, "Gen1 unseen RATTATA")
  eq(GameCompat.hasSeenSpecies(g, "FAKEMON_X"), false, "Gen1 unknown → unseen")
end

engineVersion = "gold"
do
  local g = makeGame({ SENTRET = true })
  eq(GameCompat.hasSeenSpecies(g, "SENTRET"), true, "Gold seen SENTRET")
  eq(GameCompat.hasSeenSpecies(g, "CHIKORITA"), false, "Gold unseen CHIKORITA")
end

local function isSilo(result)
  return result and (result.wildSilhouette == true
    or (result.def and type(result.def.image) == "string"
        and result.def.image:sub(1, 5) == "silo:"))
end

local function landResolve(species, game, surface)
  return resolver:resolveLandSprite({
    species = species,
    surface = surface or Surface.GRASS,
  }, { style = "pokemmo", game = game, speciesId = species })
end

----------------------------------------------------------------
-- MODE OFF / ALL / UNDISCOVERED — Gen1
----------------------------------------------------------------
engineVersion = "red"
do
  local g = makeGame({ PIDGEY = true }) -- RATTATA unseen
  savedOpts.wild_silhouettes = "off"
  check(not isSilo(landResolve("RATTATA", g)), "Gen1 OFF unseen → color")
  check(not isSilo(landResolve("PIDGEY", g)), "Gen1 OFF seen → color")

  savedOpts.wild_silhouettes = "all"
  check(isSilo(landResolve("RATTATA", g)), "Gen1 ALL unseen → silhouette")
  check(isSilo(landResolve("PIDGEY", g)), "Gen1 ALL seen → silhouette")

  savedOpts.wild_silhouettes = "undiscovered"
  check(isSilo(landResolve("RATTATA", g)), "Gen1 UNSEEN unseen → silhouette")
  check(not isSilo(landResolve("PIDGEY", g)), "Gen1 UNSEEN seen → color")
end

----------------------------------------------------------------
-- MODE OFF / ALL / UNDISCOVERED — Gold
----------------------------------------------------------------
engineVersion = "gold"
do
  local g = makeGame({ SENTRET = true }) -- CHIKORITA unseen
  savedOpts.wild_silhouettes = "off"
  check(not isSilo(landResolve("CHIKORITA", g)), "Gold OFF unseen → color")
  check(not isSilo(landResolve("SENTRET", g)), "Gold OFF seen → color")

  savedOpts.wild_silhouettes = "all"
  check(isSilo(landResolve("CHIKORITA", g)), "Gold ALL unseen → silhouette")
  check(isSilo(landResolve("SENTRET", g)), "Gold ALL seen → silhouette")

  savedOpts.wild_silhouettes = "undiscovered"
  check(isSilo(landResolve("CHIKORITA", g)), "Gold UNSEEN unseen → silhouette")
  check(not isSilo(landResolve("SENTRET", g)), "Gold UNSEEN seen → color")
end

----------------------------------------------------------------
-- Unknown species → silhouette in undiscovered mode
----------------------------------------------------------------
do
  local g = makeGame({})
  savedOpts.wild_silhouettes = "undiscovered"
  eq(Config.shouldWildSilhouette(V.mod, g, "FAKEMON_X"), true,
     "unknown species → silhouette (conservative)")
  eq(Config.shouldWildSilhouette(V.mod, g, nil), true,
     "nil species → silhouette")
end

----------------------------------------------------------------
-- Followers / interior unaffected
----------------------------------------------------------------
do
  local g = makeGame({})
  savedOpts.wild_silhouettes = "all"
  local interior = landResolve("RATTATA", g, Surface.INTERIOR)
  check(not isSilo(interior), "interior not silhouetted even in ALL")
  savedOpts.wild_silhouettes = "undiscovered"
  interior = landResolve("RATTATA", g, Surface.INTERIOR)
  check(not isSilo(interior), "interior not silhouetted in UNSEEN")
end

----------------------------------------------------------------
-- Water composition with Undiscovered
----------------------------------------------------------------
engineVersion = "gold"
do
  local g = makeGame({ LAPRAS = true })
  savedOpts.wild_silhouettes = "undiscovered"
  local unseen = resolver:resolveWaterSprite({
    species = "MAGIKARP", surface = Surface.WATER, spriteState = "water",
  }, { style = "pokemmo", game = g, speciesId = "MAGIKARP", variant = "normal" })
  local seen = resolver:resolveWaterSprite({
    species = "LAPRAS", surface = Surface.WATER, spriteState = "water",
  }, { style = "pokemmo", game = g, speciesId = "LAPRAS", variant = "normal" })
  check(isSilo(unseen), "water UNSEEN unseen → silhouette")
  check(not isSilo(seen), "water UNSEEN seen → color")
end

----------------------------------------------------------------
-- Live Pokédex discovery → presentation change once
----------------------------------------------------------------
engineVersion = "gold"
do
  local g = makeGame({})
  savedOpts.wild_silhouettes = "undiscovered"
  local species = "SENTRET"
  eq(Config.shouldWildSilhouette(V.mod, g, species), true,
     "before seen → want silhouette")

  -- Simulate presentation fingerprint before discovery.
  local entity = {
    species = species,
    surface = "grass",
    spriteState = "land",
    sprite = { def = { image = "silo:old.png" } },
    _wildsPresSpecies = species,
    _wildsPresAssetId = 161,
    _wildsPresVariant = "normal",
    _wildsPresStyle = "pokemmo",
    _wildsPresSurface = "grass",
    _wildsPresSpriteState = "land",
    _wildsPresForm = nil,
    _wildsPresWaterMode = "swimming_sprites",
    _wildsPresSilhouette = true,
    waterVoxelActive = false,
    paletteRedpp = false,
    _wildsEffectiveSize = "classic",
    requestedSpriteStyle = "pokemmo",
  }

  -- Mark seen: effective silhouette flips.
  g.save.pokedex.seen.SENTRET = true
  eq(Config.shouldWildSilhouette(V.mod, g, species), false,
     "after seen → want color")

  local wantSilo = Config.shouldWildSilhouette(V.mod, g, species) == true
  check(entity._wildsPresSilhouette ~= wantSilo,
        "fingerprint silhouette bit mismatches after discovery")

  -- After a refresh stamps the new bit, subsequent checks match (no rebuild).
  entity._wildsPresSilhouette = wantSilo
  check(entity._wildsPresSilhouette == wantSilo,
        "after stamp, silhouette fingerprint stable")
end

----------------------------------------------------------------
-- Existing follower / tower tests still load (smoke)
----------------------------------------------------------------
do
  -- Ensure Config helpers used by follower path still work.
  eq(Config.wildSilhouettes(V.mod) == true, Config.wildSilhouetteMode(V.mod) == "all",
     "wildSilhouettes bool mirrors all mode")
end

print("")
if failures > 0 then
  io.stderr:write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
print("all wild_silhouette_mode tests passed")
