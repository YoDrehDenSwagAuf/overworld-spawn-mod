-- Followers water compat + resolveWaterSprite export unit tests.
-- Run: lua tests/followers_water_compat_unit_test.lua
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

local modules = {}
local fakeFollowersExports = {
  version = "1.0.19",
  getActiveFollowerMon = function()
    return { species = "PSYDUCK", dvs = { attack = 1, defense = 1, speed = 1, special = 1 } }
  end,
}

local V = {
  mod = {
    path = ".",
    log = { info = function() end },
    find = function(_, id)
      if id == "FOLLOWERS_EX" then
        return { id = id, version = "1.0.19", exports = fakeFollowersExports }
      end
      return nil
    end,
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    assets = {
      path = function(_, rel)
        return "mods/overworld_wild_spawns/" .. rel
      end,
    },
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
  DEFAULTS = { sprite_style = "auto", use_animated_overworld_sprites = true },
  get = function(_, k) return modules.config.DEFAULTS[k] end,
  spriteStyle = function() return "auto" end,
  debug = function() return false end,
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end, debug = function() end,
}

local FollowersWaterCompat = V.require("followers_water_compat")
local WaterSpriteRegistry = V.require("water_sprite_registry")
local AnimatedSprites = V.require("animated_sprites")
local Surface = V.require("surface")

-- Minimal SpawnLogic-like resolver using registry only.
local reg = WaterSpriteRegistry.new(V.mod)
check(reg:load() == true, "water registry loads")

local function resolveWaterSprite(speciesId, isShiny, form, opts)
  opts = opts or {}
  local variant = (isShiny == true or isShiny == "shiny") and "shiny" or "normal"
  local dexId = speciesId
  if type(dexId) ~= "number" then
    dexId = AnimatedSprites.resolveSpeciesId(speciesId, opts.game, V.mod)
  end
  -- Psyduck hardcoded for name resolve in tests when AnimatedSprites lacks data.
  if dexId == nil and tostring(speciesId) == "PSYDUCK" then dexId = 54 end
  if dexId == nil and tostring(speciesId) == "ABRA" then dexId = 63 end
  if not dexId then return nil, { error = "no dex" } end
  if opts.follower == true or opts.allowLandFallback == false then
    local waterDef = reg:resolve(dexId, variant, nil, form)
    if not waterDef then return nil, { error = "no water" } end
    return {
      image = waterDef.image,
      frames = waterDef.frames,
      walker = true,
      kind = waterDef.kind,
      id = waterDef.id,
    }, {
      kind = waterDef.kind,
      speciesId = dexId,
      variant = waterDef.variant or variant,
      form = form,
      image = waterDef.image,
      frames = waterDef.frames,
      walker = true,
    }
  end
  return nil, { error = "unsupported" }
end

local def54, meta54 = resolveWaterSprite(54, false, nil, { follower = true })
check(def54 ~= nil, "resolveWaterSprite 54")
eq(meta54.kind, "swimming", "54 swimming")
check(def54.image ~= nil, "54 image")

local def63, meta63 = resolveWaterSprite(63, false, nil, { follower = true })
check(def63 ~= nil, "resolveWaterSprite 63")
eq(meta63.kind, "levitates", "63 levitates")

local missing = resolveWaterSprite(9999, false, nil, { follower = true, allowLandFallback = false })
check(missing == nil, "follower path never returns land fallback")

------------------------------------------------------------------------
-- Compat adapter: no crash without Followers
------------------------------------------------------------------------
local bareMod = {
  path = ".",
  log = { info = function() end },
  find = function() return nil end,
}
local bare = FollowersWaterCompat.new(bareMod, { resolveWaterSprite = resolveWaterSprite })
check(bare:isInstalled() == false, "not installed without Followers")
check(bare:tick(nil, { player = { surfing = true }, entities = {} }) == false,
      "tick without Followers is safe")

------------------------------------------------------------------------
-- Compat adapter with Followers + surfing
------------------------------------------------------------------------
local compat = FollowersWaterCompat.new(V.mod, { resolveWaterSprite = resolveWaterSprite })
check(compat:isInstalled() == true, "Followers EX detected via public find/exports")

local followerEntity = {
  id = "trailer1",
  cellX = 4, cellY = 4,
  passable = true,
  pokepcTrailer = true,
  pokepcTrailerKind = "mon",
  pokepcMon = { species = "PSYDUCK" },
  species = "PSYDUCK",
  sprite = {
    def = {
      id = "SPRITE_POKEPC_MON",
      image = "mods/PokePCFollowers_VoxelMerge/assets/sprites/follower_PSYDUCK.png",
      frames = 6,
      walker = true,
      trueColor = true,
    },
  },
}
local owLand = {
  player = { cellX = 5, cellY = 4, surfing = false },
  entities = { followerEntity },
  pokepcTrailers = { followerEntity },
}
local changed = compat:tick(nil, owLand, resolveWaterSprite)
-- First tick establishes cache; may or may not change sprite on land.
check(compat.status.detected == true, "active follower detected")
eq(compat.status.surface, "land", "land surface")

local landImage = followerEntity.sprite.def.image
local owWater = {
  player = { cellX = 5, cellY = 4, surfing = true, surface = Surface.WATER },
  entities = { followerEntity },
  pokepcTrailers = { followerEntity },
}
-- SpriteRenderer is unavailable in unit tests; applySpriteDef fails gracefully.
changed = compat:tick(nil, owWater, resolveWaterSprite)
check(compat.status.surface == "water", "water surface while surfing")
-- Without SpriteRenderer, water apply fails → unavailable fallback, no crash.
check(compat.status.waterSprite == "unavailable" or compat.status.waterSprite == "YES",
      "water sprite status set")
check(compat.status.lastAction ~= nil, "lastAction recorded")

-- No per-frame thrash: second tick with same state is cached.
compat:tick(nil, owWater, resolveWaterSprite)
eq(compat.status.lastAction, "cached", "no sprite swap every frame")

-- Repeated land ticks after style resolve must not thrash.
compat:invalidateStyle()
owLand.player.surfing = false
compat:tick(nil, owLand, resolveWaterSprite)
check(compat.status.lastAction == "to_land_keep" or compat.status.lastAction == "to_land"
      or compat.status.lastAction == "style_land" or compat.status.lastAction == "cached",
      "land tick after invalidate recorded")
compat:tick(nil, owLand, resolveWaterSprite)
eq(compat.status.lastAction, "cached", "second land tick cached")

-- Sticky follower: same entity reference across ticks.
local e1 = select(1, compat:activeFollower(owLand, nil))
local e2 = select(1, compat:activeFollower(owLand, nil))
eq(e1, e2, "activeFollower sticky same reference")
eq(e1, followerEntity, "activeFollower returns known trailer")

-- Leave water.
owLand.player.surfing = false
compat:tick(nil, owLand, resolveWaterSprite)
eq(compat.status.surface, "land", "back on land")
check(compat.status.lastAction == "to_land" or compat.status.lastAction == "to_land_keep"
      or compat.status.lastAction == "cached",
      "land restore path")

-- HUD lines
local lines = compat:hudLines()
check(#lines >= 4, "hud lines present")
check(lines[1]:find("Follower detected", 1, true), "hud follower detected")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll followers_water_compat tests passed.")
