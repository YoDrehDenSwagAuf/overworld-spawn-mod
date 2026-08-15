-- HGSS / PokéMMO land↔water presentation + fingerprint (perf-safe).
--
-- Regression: applyProviderSprite passed mon.species ("RATTATA") as
-- context.speciesId. WaterSpriteRegistry keys on tonumber(id), so the
-- registry missed and HGSS fell back to land art with spriteState=water.
-- The presentation fingerprint then skipped the real water rebind.
--
-- Run: lua tests/hgss_water_presentation_perf_unit_test.lua
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

package.preload["src.render.SpriteRenderer"] = function()
  return {
    DEFAULT_FRAME_WIDTH = 16,
    DEFAULT_FRAME_HEIGHT = 16,
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
        image = { setFilter = function() end },
        resolveImage = function(self) return self.image end,
        draw = function() end,
      }
    end,
  }
end

local modules = {}
local saved = {
  sprite_style = "pokemmo",
  pokemon_size = "classic",
  water_spawns = "swimming_sprites",
  use_animated_overworld_sprites = true,
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
    log = { info = function() end, warn = function() end, error = function() end },
    content = {
      pokemon = { get = function() return nil end, each = function() return function() end end },
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
    pokemon_size = "classic",
    water_spawns = "swimming_sprites",
    use_animated_overworld_sprites = true,
    min_sprite_size = 16,
    wild_step_seconds = 0.28,
    aggressive_step_seconds = 0.18,
  },
  STATE = {
    AVAILABLE = "AVAILABLE",
    REMOVED = "REMOVED",
    ENCOUNTER_STARTING = "ENCOUNTER_STARTING",
    IN_BATTLE = "IN_BATTLE",
  },
  get = function(_, k) return saved[k] or modules.config.DEFAULTS[k] end,
  peekSavedOption = function(_, k) return saved[k], saved[k] ~= nil end,
  spriteStyle = function() return saved.sprite_style end,
  normalizeSpriteStyle = function(v)
    if v == "hgss" or v == "fullcolor" or v == "auto" or v == "gold" or v == "crystal" then
      return "pokemmo"
    end
    if v == "followers_ex" or v == "poke_followers" then return "followers" end
    return v or "pokemmo"
  end,
  pokemonSizeMode = function() return saved.pokemon_size end,
  normalizePokemonSize = function(v) return v == "true_size" and "true_size" or "classic" end,
  waterDisplayMode = function() return "swimming_sprites" end,
  wildSilhouettes = function() return false end,
  landArtUsesLuminance = function() return false end,
  waterArtUsesLuminance = function() return false end,
  paletteFxRedpp = function() return true end,
  spriteTrueColor = function() return true end,
  useAnimatedOverworldSprites = function() return true end,
  debug = function() return false end,
  devMode = function() return false end,
  devOverlay = function() return false end,
}
modules.debug_log = {
  warn = function() end, info = function() end,
  error = function() end, debug = function() end,
}
modules.tile = {
  CELL = 16, WIDTH = 16, HEIGHT = 16,
  pixelsForCell = function(x, y) return x * 16, y * 16 end,
}

local SpeciesAssets = V.require("species_assets")
local Surface = V.require("surface")
local WaterSpriteRegistry = V.require("water_sprite_registry")
local SpriteProviders = V.require("sprite_providers")
local SpriteResolver = V.require("sprite_resolver")
local SpawnRender = V.require("spawn_render")
local Behavior = V.require("behavior")
local Movement = V.require("movement")

------------------------------------------------------------------------
-- Registry isolation: string species keys must not resolve.
------------------------------------------------------------------------
print("== water registry identity ==")
local reg = WaterSpriteRegistry.new(V.mod)
check(reg:load() == true, "water registry loads")
check(reg.ready == true, "water registry ready")

eq(SpeciesAssets.idFor("RATTATA"), 19, "RATTATA → canonical 19")
eq(SpeciesAssets.idFor(19), 19, "numeric 19 stays 19")
eq(reg:resolve("RATTATA", "normal"), nil, "registry rejects species string")
local def19 = reg:resolve(19, "normal")
check(def19 ~= nil, "registry resolves asset 19")
if def19 then
  eq(def19.kind, "swimming", "RATTATA preferred kind is swimming")
end

local CASES = {
  { species = "RATTATA", id = 19, kind = "swimming" },
  { species = "POLIWAG", id = 60, kind = "swimming" },
  { species = "BLASTOISE", id = 9, kind = "swimming" },
  { species = "MAGIKARP", id = 129, kind = "swimming" },
  { species = "GYARADOS", id = 130, kind = "swimming" },
  { species = "LAPRAS", id = 131, kind = "swimming" },
  { species = "ABRA", id = 63, kind = "levitates" },
}

------------------------------------------------------------------------
-- Resolver: species string context must canonicalize before registry.
------------------------------------------------------------------------
print("== resolveWaterSprite species string ==")
local providers = SpriteProviders.new(V.mod)
local resolver = SpriteResolver.new(V.mod, providers, reg)
local registrySeen = {}
local origPreferred = reg.preferredKindFor
local origRegResolve = reg.resolve
function reg:preferredKindFor(speciesId)
  registrySeen[#registrySeen + 1] = speciesId
  return origPreferred(self, speciesId)
end
function reg:resolve(speciesId, ...)
  registrySeen[#registrySeen + 1] = speciesId
  return origRegResolve(self, speciesId, ...)
end

local function lastRegistryId()
  return registrySeen[#registrySeen]
end

for _, case in ipairs(CASES) do
  registrySeen = {}
  local entity = {
    species = case.species,
    enhancedDexId = case.id,
    surface = Surface.WATER,
    spriteState = "water",
    behavior = "WATER_IDLE",
  }
  local result = resolver:resolveForEntity(entity, {
    style = "pokemmo",
    speciesId = case.species, -- the port used to pass the string through
    variant = "normal",
    surface = Surface.WATER,
  })
  check(result ~= nil, case.species .. " water resolve returns")
  check(result and result.def and result.def.image, case.species .. " water has image")
  eq(result and result.spriteState, "water", case.species .. " spriteState=water")
  eq(result and result.spriteKind, case.kind, case.species .. " kind=" .. case.kind)
  eq(tonumber(lastRegistryId()), case.id, case.species .. " registry received " .. case.id)
  check(result and result.providerId and tostring(result.providerId):find("water_", 1, true),
    case.species .. " uses water registry (not land fallback)")
  check(result and result.def and result.def.image
    and not tostring(result.def.image):find("followsprites_runtime", 1, true),
    case.species .. " water image is not HGSS land sheet")
  check(result and result.def and result.def.frames == 6, case.species .. " frames=6")
  check(result and result.def and result.def.walker == true, case.species .. " walker")
end

-- HGSS public style normalizes to pokemmo and still hits the registry.
registrySeen = {}
local hgss = resolver:resolveForEntity({
  species = "RATTATA", enhancedDexId = 19,
  surface = Surface.WATER, spriteState = "water",
}, {
  style = "hgss",
  speciesId = "RATTATA",
  variant = "normal",
  surface = Surface.WATER,
})
eq(hgss and hgss.spriteKind, "swimming", "HGSS style → swimming registry")
eq(tonumber(lastRegistryId()), 19, "HGSS style registry received 19")

------------------------------------------------------------------------
-- applyProviderSprite fingerprint: one resolve per transition, zero after.
------------------------------------------------------------------------
print("== presentation fingerprint land↔water ==")
local render = SpawnRender.new(V.mod)
check(render.waterSpriteRegistry:load() == true, "render water registry loads")
render.waterSpriteRegistry.ready = true

local applyRegistryIds = {}
local applyReg = render.waterSpriteRegistry
local applyOrig = applyReg.resolve
function applyReg:resolve(speciesId, ...)
  applyRegistryIds[#applyRegistryIds + 1] = speciesId
  return applyOrig(self, speciesId, ...)
end

local resolveCalls = 0
local origResolveFor = render.spriteResolver.resolveForEntity
function render.spriteResolver:resolveForEntity(entity, context)
  resolveCalls = resolveCalls + 1
  return origResolveFor(self, entity, context)
end

local entity = {
  id = "wild-rattata",
  spawnId = "wild-rattata",
  species = "RATTATA",
  enhancedDexId = 19,
  facing = "down",
  visibleSprite = true,
  overworldWildSpawn = true,
  behavior = Behavior.GRASS_WANDER,
  behaviorState = Behavior.initState(Behavior.GRASS_WANDER, function() return 0 end),
  surface = Surface.GRASS,
  spriteState = "land",
  render = render,
  mod = V.mod,
}
Movement.init(entity, 4, 4, "down")

resolveCalls = 0
applyRegistryIds = {}
check(render:applyProviderSprite(entity, nil) == true, "land apply succeeds")
local landResolves = resolveCalls
check(landResolves >= 1, "land apply resolved once")
local landImage = entity.sprite and entity.sprite.def and entity.sprite.def.image
check(type(landImage) == "string", "land image bound")
eq(entity.spriteState, "land", "land spriteState")
eq(entity._wildsPresSpriteState, "land", "fingerprint recorded land")
eq(entity._wildsPresSurface, Surface.GRASS, "fingerprint recorded grass")

resolveCalls = 0
check(render:applyProviderSprite(entity, nil) == true, "unchanged land apply")
eq(resolveCalls, 0, "unchanged land → 0 resolves")

-- Land → water
entity.surface = Surface.WATER
entity.spriteState = "water"
entity.lastSpriteRefreshReason = "entered_water"
resolveCalls = 0
applyRegistryIds = {}
check(render:applyProviderSprite(entity, nil, { forcePresentationRefresh = true }) == true,
  "water apply succeeds")
eq(resolveCalls, 1, "land→water resolved exactly once")
eq(tonumber(applyRegistryIds[#applyRegistryIds]), 19, "water registry received 19")
local waterImage = entity.sprite and entity.sprite.def and entity.sprite.def.image
check(type(waterImage) == "string", "water image bound")
check(waterImage ~= landImage, "water image != land image")
eq(entity.spriteState, "water", "water spriteState")
eq(entity.spriteKind, "swimming", "Rattata water kind is swimming")
eq(entity._wildsPresSpriteState, "water", "fingerprint recorded water")
eq(entity._wildsPresSurface, Surface.WATER, "fingerprint recorded WATER")

resolveCalls = 0
check(render:applyProviderSprite(entity, nil) == true, "unchanged water apply")
eq(resolveCalls, 0, "unchanged water → 0 resolves")

-- Water → land
entity.surface = Surface.GRASS
entity.spriteState = "land"
entity.lastSpriteRefreshReason = "entered_land"
resolveCalls = 0
check(render:applyProviderSprite(entity, nil, { forcePresentationRefresh = true }) == true,
  "land restore succeeds")
eq(resolveCalls, 1, "water→land resolved exactly once")
local backImage = entity.sprite and entity.sprite.def and entity.sprite.def.image
check(backImage ~= waterImage, "restored land image != water image")
eq(entity.spriteState, "land", "restored spriteState=land")

resolveCalls = 0
check(render:applyProviderSprite(entity, nil) == true, "unchanged land after restore")
eq(resolveCalls, 0, "unchanged land after restore → 0 resolves")

------------------------------------------------------------------------
-- Stale water fingerprint (land art stamped as water) must force-rebind.
------------------------------------------------------------------------
print("== forcePresentationRefresh stale water ==")
entity.surface = Surface.WATER
entity.spriteState = "water"
entity.spriteKind = "pokemmo"
entity._wildsPresSpecies = entity.species
entity._wildsPresAssetId = 19
entity._wildsPresVariant = "normal"
entity._wildsPresStyle = "pokemmo"
entity._wildsPresSurface = Surface.WATER
entity._wildsPresSpriteState = "water"
entity._wildsPresForm = entity.spriteForm
entity._wildsPresWaterMode = "swimming_sprites"
entity.waterVoxelActive = false
entity.paletteRedpp = true
entity._wildsEffectiveSize = "classic"
entity.requestedSpriteStyle = "pokemmo"
entity.lastSpriteRefreshReason = "entered_water"
-- Keep a land-looking sheet bound.
entity.sprite.def.image = landImage
resolveCalls = 0
check(render:applyProviderSprite(entity, nil, { forcePresentationRefresh = true }) == true,
  "stale water force-refresh succeeds")
eq(resolveCalls, 1, "stale water fingerprint did not skip")
eq(entity.spriteKind, "swimming", "stale water rebound to swimming")
check(entity.sprite.def.image ~= landImage, "stale water rebound image changed")

------------------------------------------------------------------------
-- refreshEntitySprite wires force for entered_water.
------------------------------------------------------------------------
print("== refreshEntitySprite force reason ==")
local logic = {
  render = render,
  mod = V.mod,
}
-- Use the real SpawnLogic method via a thin bind if available; otherwise
-- replicate the reason→force contract the same way callers do.
local SpawnLogic = V.require("spawn_logic")
local refresh = SpawnLogic.refreshEntitySprite
entity.surface = Surface.GRASS
entity.spriteState = "land"
entity.lastSpriteRefreshReason = "entered_land"
check(render:applyProviderSprite(entity, nil, { forcePresentationRefresh = true }) == true,
  "reset to land before refresh test")
entity.lastSpriteRefreshReason = nil
resolveCalls = 0
check(select(1, refresh(logic, entity, {
  reason = "entered_water",
  surface = Surface.WATER,
  spriteState = "water",
})) == true, "refreshEntitySprite entered_water")
eq(entity.surface, Surface.WATER, "refresh set WATER")
eq(entity.spriteState, "water", "refresh set water state")
eq(entity.spriteKind, "swimming", "refresh bound swimming")
check(resolveCalls >= 1, "refresh resolved water")

------------------------------------------------------------------------
-- commitPendingSurfaceTransition is presentation, not AI consume.
------------------------------------------------------------------------
print("== commitPendingSurfaceTransition ==")
local chase = {
  species = "RATTATA",
  enhancedDexId = 19,
  surface = Surface.GRASS,
  spriteState = "land",
  originSurface = Surface.GRASS,
  cellX = 5,
  cellY = 5,
  mod = V.mod,
  render = render,
  behavior = Behavior.AGGRESSIVE,
  behaviorState = Behavior.initState(Behavior.AGGRESSIVE, function() return 0 end),
}
chase.behaviorState.pendingWaterEnter = true
Movement.init(chase, 5, 5, "down")
local map = {
  isWaterCell = function(_, x, y) return x == 5 and y == 5 end,
}
local ev = Behavior.commitPendingSurfaceTransition(chase, {
  map = map,
  logic = logic,
  game = nil,
})
eq(ev, "entered_water", "commit returns entered_water")
eq(chase.surface, Surface.WATER, "commit sets WATER")
eq(chase.spriteState, "water", "commit sets water state")
eq(chase.behaviorState.pendingWaterEnter, true,
  "commit leaves pendingWaterEnter for Behavior.tick")

if failures > 0 then
  io.stderr:write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
print("all passed")
