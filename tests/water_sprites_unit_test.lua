-- Water sprite registry / resolver unit tests (no Gen1Recomp required).
-- Run: lua tests/water_sprites_unit_test.lua
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

local modRoot = "."
local modules = {}
local V = {
  mod = {
    path = modRoot,
    log = { info = function() end },
    find = function() return nil end,
    assets = {
      path = function(_, rel)
        return "mods/overworld_wild_spawns/" .. rel
      end,
    },
    read = function(_, rel)
      local f = io.open(rel, "rb")
      if not f then f = io.open("./" .. rel, "rb") end
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
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
    sprite_style = "auto",
    use_animated_overworld_sprites = true,
    water_spawns = "swimming_sprites",
  },
  get = function(_, k) return modules.config.DEFAULTS[k] end,
  spriteStyle = function() return modules.config._style or "pokemmo" end,
  normalizeSpriteStyle = function(v)
    if v == "followers_ex" or v == "poke_followers" then return "followers" end
    if v == "auto" or v == "gold" or v == "crystal" then return "pokemmo" end
    return v
  end,
  waterDisplayMode = function() return "swimming_sprites" end,
  debug = function() return false end,
  _style = "pokemmo",
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }
modules.debug_log = { warn = function() end, info = function() end, error = function() end }

local WaterSpriteRegistry = V.require("water_sprite_registry")
local SpriteResolver = V.require("sprite_resolver")
local SpriteProviders = V.require("sprite_providers")
local Surface = V.require("surface")
local RuntimeSheets = V.require("runtime_sheets")

------------------------------------------------------------------------
-- Registry load + resolve
------------------------------------------------------------------------
local reg = WaterSpriteRegistry.new(V.mod)
local okLoad, loadErr = reg:load()
check(okLoad == true, "water registry loads")
check(reg:isReady(), "water registry ready")
local sum = reg:summary()
check((sum.stats.swimmingMapped or 0) > 0, "swimming mapping loaded")
check((sum.stats.levitatesMapped or 0) > 0, "levitates mapping loaded")
print(("  swim=%s lev=%s unique=%s"):format(
  tostring(sum.stats.swimmingMapped),
  tostring(sum.stats.levitatesMapped),
  tostring(sum.stats.uniqueSpecies)))

eq(WaterSpriteRegistry.WATER_SPRITE_ORDER[1], "swimming", "priority swimming first")
eq(WaterSpriteRegistry.WATER_SPRITE_ORDER[2], "levitates", "priority levitates second")

-- Psyduck 54: swimming available
local def54, err54 = reg:resolve(54, "normal", nil, nil)
check(def54 ~= nil, "species 54 resolves (" .. tostring(err54) .. ")")
if def54 then
  eq(def54.kind, "swimming", "54 prefers swimming")
  eq(def54.variant, "normal", "54 normal variant")
  eq(def54.frames, 6, "54 frames=6")
  check(def54.walker == true, "54 walker")
  check(type(def54.image) == "string" and def54.image:find("water_runtime/swimming", 1, true),
        "54 image path under water_runtime/swimming")
  check(def54.source == "mapping", "54 source=mapping")
end

-- Abra 63: levitates only (no swimming in typical set)
local hasSwim63 = reg:hasKind(63, "swimming", "normal")
local hasLev63 = reg:hasKind(63, "levitates", "normal")
check(hasLev63 == true, "63 has levitates")
local def63 = reg:resolve(63, "normal")
check(def63 ~= nil, "63 resolves")
if def63 then
  if not hasSwim63 then
    eq(def63.kind, "levitates", "63 uses levitates when swimming missing")
  end
end

-- Shiny: prefer shiny swimming when present
local def1s = reg:resolve(1, "shiny")
check(def1s ~= nil, "1 shiny resolves")
if def1s then
  eq(def1s.kind, "swimming", "1 shiny uses swimming")
  eq(def1s.variant, "shiny", "1 shiny variant")
end

-- Form: default without suffix preferred (Venusaur 3 has _1 form)
local def3 = reg:resolve(3, "normal", nil, nil)
check(def3 ~= nil, "3 default form resolves")
if def3 then
  check(def3.form == nil or def3.formKey == "default",
        "3 prefers default form without random suffix")
end
local def3f = reg:resolve(3, "normal", nil, "1")
check(def3f ~= nil, "3 form=1 resolves when requested")
if def3f then
  eq(def3f.form, "1", "3 requested form=1")
end

-- Missing species → nil
local miss, missErr = reg:resolve(99999, "normal")
check(miss == nil, "missing species returns nil")
check(type(missErr) == "string", "missing species error string")

-- Cache returns same def
local a = reg:resolve(54, "normal")
local b = reg:resolve(54, "normal")
check(a and b and a.image == b.image, "registry cache stable")
check(a and a.artFamily == "hgss_water", "registry tags artFamily=hgss_water")

-- Style participates in WaterSpriteRegistry cache key.
modules.config._style = "pokemmo"
reg:invalidateCache()
local hgssDef = reg:resolve(54, "normal", nil, nil, { style = "pokemmo" })
modules.config._style = "followers"
local followersStyleDef = reg:resolve(54, "normal", nil, nil, { style = "followers" })
check(hgssDef ~= nil and followersStyleDef ~= nil, "style-tagged resolves succeed")
-- Distinct cache entries (same asset family here, but keys must not collide).
reg.cache["probe"] = { ok = true, def = { image = "STALE" } }
local keyCount = 0
for k in pairs(reg.cache) do
  if type(k) == "string" and k:find(":pokemmo:", 1, true) then keyCount = keyCount + 1 end
  if type(k) == "string" and k:find(":followers:", 1, true) then keyCount = keyCount + 1 end
end
check(keyCount >= 2, "cache keys include pokemmo and followers styles")
reg:invalidateCache()
check(next(reg.cache) == nil, "invalidateCache clears water registry cache")
modules.config._style = "pokemmo"

------------------------------------------------------------------------
-- SpriteResolver land vs water
------------------------------------------------------------------------
local rs = RuntimeSheets.new(V.mod)
pcall(function() rs:load() end)
local fakeRender = {
  runtimeSheets = rs,
  _modAssetPath = function(_, rel)
    return "mods/overworld_wild_spawns/" .. rel
  end,
}
local providers = SpriteProviders.new(V.mod, fakeRender)

local resolver = SpriteResolver.new(V.mod, providers, reg)

-- Surface helpers
check(Surface.isWaterEntity({ surface = "WATER" }) == true, "Surface.isWaterEntity WATER")
check(Surface.isWaterEntity({ behavior = "WATER_IDLE" }) == true, "Surface.isWaterEntity WATER_IDLE")
check(Surface.isWaterEntity({ surface = "GRASS" }) == false, "Surface.isWaterEntity GRASS false")
check(SpriteResolver.SurfaceState.isWaterEntity({ surface = "WATER" }) == true,
      "SurfaceState.isWaterEntity")

local landEntity = {
  species = "PSYDUCK",
  enhancedDexId = 54,
  surface = "GRASS",
  isShiny = false,
}
local land = resolver:resolveForEntity(landEntity, {
  style = "pokemmo",
  surface = "land",
  speciesId = 54,
  variant = "normal",
})
check(land ~= nil and land.def ~= nil, "land resolve returns def")
if land then
  eq(land.spriteState, "land", "land spriteState")
  check(land.waterOverride ~= true, "land no water override")
  check(land.providerId ~= "followers_ex", "explicit pokemmo land never followers_ex")
end

local keyLand = resolver:cacheKey(landEntity, {
  style = "pokemmo", speciesId = 54, variant = "normal", form = nil,
}, "land")
eq(keyLand, "54:normal:default:land:pokemmo:na:flat:none:na:color:classic:1:na",
   "cache key includes style+surface+silhouette+size+generation+color")
local keyFollowers = resolver:cacheKey(landEntity, {
  style = "followers", speciesId = 54, variant = "normal", form = nil,
}, "land")
check(keyLand ~= keyFollowers, "pokemmo and followers use different cache keys")

local waterEntity = {
  species = "PSYDUCK",
  enhancedDexId = 54,
  surface = "WATER",
  behavior = "WATER_IDLE",
  isShiny = false,
}
local water = resolver:resolveForEntity(waterEntity, {
  style = "pokemmo",
  surface = "water",
  speciesId = 54,
  variant = "normal",
})
check(water ~= nil and water.def ~= nil, "water resolve returns def")
if water then
  eq(water.spriteState, "water", "water spriteState")
  eq(water.spriteKind, "swimming", "pokemmo-on-water falls back to swimming")
  check(water.waterOverride == true, "water override active")
  check(water.def.frames == 6, "water frames=6")
  check(water.def.walker == true, "water walker")
end

-- Poke Followers style on water → swimming override
local waterEx = resolver:resolveForEntity(waterEntity, {
  style = "followers",
  surface = "water",
  speciesId = 54,
  variant = "normal",
})
-- Followers style prefers poke_followers submerged sheets when present.
check(waterEx and (waterEx.spriteKind == "followers_ex"
      or waterEx.spriteKind == "submerged"
      or waterEx.spriteKind == "swimming"),
      "followers on water → submerged/followers_ex (or swimming fallback)")

-- Pokedex style on water → swimming
local waterDex = resolver:resolveForEntity(waterEntity, {
  style = "pokedex",
  surface = "water",
  speciesId = 54,
  variant = "normal",
})
check(waterDex and waterDex.spriteKind == "swimming",
      "pokedex on water → swimming")

-- Levitates-only species on water
local levEntity = {
  species = "ABRA",
  enhancedDexId = 63,
  surface = "WATER",
  behavior = "WATER_WANDER",
}
local lev = resolver:resolveForEntity(levEntity, {
  style = "pokemmo",
  surface = "water",
  speciesId = 63,
  variant = "normal",
})
check(lev ~= nil, "63 water resolves")
if lev and not reg:hasKind(63, "swimming", "normal") then
  eq(lev.spriteKind, "levitates", "63 water uses levitates")
end

-- HGSS/pokemmo: provider resolveWater must NOT steal water presentation.
-- Style owns art family — HGSS uses the Wilds swimming/levitate registry.
local customCalled = false
local pokemmoProv = providers.providers.pokemmo
check(pokemmoProv ~= nil, "pokemmo provider registered")
local prevResolveWater = pokemmoProv.resolveWater
pokemmoProv.resolveWater = function(_, speciesId, variant)
  customCalled = true
  return {
    image = "mods/test/fake_water.png",
    frames = 1,
    trueColor = true,
    id = "TEST_WATER",
  }, { usedVariant = variant, providerMod = "test" }
end
local resolver2 = SpriteResolver.new(V.mod, providers, reg)
local custom = resolver2:resolveWaterSprite(waterEntity, {
  style = "pokemmo",
  speciesId = 54,
  variant = "normal",
})
check(customCalled == false, "pokemmo skips provider resolveWater")
check(custom and custom.spriteKind == "swimming", "pokemmo water uses Wilds swimming")
check(custom and custom.meta and custom.meta.artFamily == "hgss_water",
  "pokemmo water artFamily=hgss_water")
local rel = custom and custom.meta and tostring(custom.meta.relativePath or "")
check(rel == "" or not rel:find("poke_followers", 1, true),
  "pokemmo water path is not poke_followers")

pokemmoProv.resolveWater = prevResolveWater
local fallback = resolver2:resolveWaterSprite(waterEntity, {
  style = "pokemmo",
  speciesId = 54,
  variant = "normal",
})
check(fallback and fallback.spriteKind == "swimming",
      "pokemmo water stays on Wilds swimming registry")

-- Followers style keeps poke_followers submerged art family when available.
local followersWater = resolver2:resolveWaterSprite(waterEntity, {
  style = "followers",
  speciesId = 54,
  variant = "normal",
})
check(followersWater ~= nil, "followers water resolves")
if followersWater then
  local fam = (followersWater.meta and followersWater.meta.artFamily)
    or (followersWater.def and followersWater.def.artFamily)
  check(followersWater.spriteKind == "submerged"
      or followersWater.spriteKind == "followers_ex"
      or followersWater.spriteKind == "swimming",
    "followers water kind is submerged/followers or swim fallback")
  if followersWater.spriteKind == "submerged"
      or followersWater.providerId == "poke_followers_submerged" then
    eq(fam, "poke_followers_submerged", "followers water artFamily")
  end
end

-- Style switch invalidates resolver + registry caches (no stale family).
resolver2:invalidateCache()
check(next(resolver2.cache) == nil, "resolver invalidate clears cache")
check(next(reg.cache) == nil, "resolver invalidate clears water registry cache")

-- applyEntityMeta
resolver:applyEntityMeta(waterEntity, water)
eq(waterEntity.spriteState, "water", "entity.spriteState set")
eq(waterEntity.spriteKind, "swimming", "entity.spriteKind set")
check(waterEntity.waterOverride == true, "entity.waterOverride set")

-- Kind order with preferredWaterKind override
local order = reg:kindOrder("levitates")
eq(order[1], "levitates", "preferred kind first")
eq(order[2], "swimming", "swimming still second")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll water sprite tests passed.")
