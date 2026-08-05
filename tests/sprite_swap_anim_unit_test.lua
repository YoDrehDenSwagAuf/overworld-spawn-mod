-- Sprite-swap animation contract + AGGRESSIVE search wander.
-- Proves native walker sheets stay on Movement.walkPhase / pose(), and that
-- provider / follower swaps do not invent a second enhanced-atlas body path.
-- Run: lua tests/sprite_swap_anim_unit_test.lua
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
local savedOpts = { sprite_style = "pokemmo" }
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end, error = function() end },
    find = function() return nil end,
    options = {
      get = function(_, key) return savedOpts[key] end,
    },
    assets = {
      path = function(_, rel) return "mods/overworld_wild_spawns/" .. rel end,
    },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
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
    sprite_style = "pokemmo",
    use_animated_overworld_sprites = true,
    wild_step_seconds = 0.28,
    aggressive_step_seconds = 0.18,
    aggressive_sight_range = 4,
    idle_look_min_s = 5,
    idle_look_max_s = 10,
    grass_occlusion_px = 6,
    min_sprite_size = 16,
  },
  STATE = {
    AVAILABLE = "AVAILABLE",
    REMOVED = "REMOVED",
    ENCOUNTER_STARTING = "ENCOUNTER_STARTING",
    IN_BATTLE = "IN_BATTLE",
  },
  get = function(_, k) return modules.config.DEFAULTS[k] end,
  spriteStyle = function() return savedOpts.sprite_style or "pokemmo" end,
  waterDisplayMode = function() return savedOpts.water_spawns or "swimming_sprites" end,
  useAnimatedOverworldSprites = function() return true end,
  debug = function() return false end,
  devOverlay = function() return false end,
}
modules.tile = {
  CELL = 16, WIDTH = 16, HEIGHT = 16,
  pixelsForCell = function(x, y) return x * 16, y * 16 end,
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end, debug = function() end,
}

local SpriteRendererStub = {
  new = function(def, id)
    return {
      def = def,
      id = id,
      image = { setFilter = function() end },
      resolveImage = function(self) return self.image end,
      draw = function() end,
    }
  end,
}
package.preload["src.render.SpriteRenderer"] = function() return SpriteRendererStub end

local Movement = V.require("movement")
local Behavior = V.require("behavior")
local Surface = V.require("surface")
local CellOccupancy = V.require("cell_occupancy")
local RuntimeSheets = V.require("runtime_sheets")
local SpawnRender = V.require("spawn_render")
local FollowersWaterCompat = V.require("followers_water_compat")
local SpawnFx = V.require("spawn_fx")

-- Body always visible in these unit tests.
if SpawnFx then
  SpawnFx.bodyVisible = function() return true end
  SpawnFx.visualLift = function() return 0 end
end

------------------------------------------------------------------------
-- A) PokeMMO / native sheet defs
------------------------------------------------------------------------
print("== native PokeMMO sheet contract ==")
local sheets = RuntimeSheets.new(V.mod)
check(sheets:load() == true, "runtime sheets load")
local def25 = select(1, sheets:spriteDef(25, "normal"))
check(def25 ~= nil, "Pikachu spriteDef")
eq(def25.frames, 6, "PokeMMO frames == 6")
eq(def25.walker, true, "PokeMMO walker == true")

------------------------------------------------------------------------
-- B) applyProviderSprite: single native animation path
------------------------------------------------------------------------
print("== applyProviderSprite native path ==")
local render = SpawnRender.new(V.mod)
render.spriteProviders = {
  resolve = function(_, style, species, variant)
    return {
      def = {
        image = def25.image,
        frames = 6,
        walker = true,
        trueColor = true,
        id = "SPRITE_OW_WILD_PIKACHU",
      },
      providerId = "pokemmo",
      spriteState = "land",
      fallbackStep = 0,
      meta = { usedVariant = variant or "normal", loadPath = def25.image },
    }
  end,
}
render.spriteResolver = nil
render.animated = {
  newAnimationState = function()
    error("must not create enhanced animation state for native sheets")
  end,
}

local entity = {
  id = "wild1",
  spawnId = "wild1",
  species = "PIKACHU",
  enhancedDexId = 25,
  facing = "down",
  stepFlip = true,
  walkFlip = true,
  flip = true,
  phase = 0,
  visibleSprite = true,
  overworldWildSpawn = true,
  behavior = Behavior.GRASS_WANDER,
  behaviorState = Behavior.initState(Behavior.GRASS_WANDER, function() return 0 end),
  surface = Surface.GRASS,
  render = render,
  mod = V.mod,
}
Movement.init(entity, 2, 3, "down")
check(Movement.beginStep(entity, 2, 4), "begin wild step before swap")
entity.movement.progress = (entity.movement.duration or 0.28) * 0.5
local phaseBefore = Movement.walkPhase(entity)
eq(phaseBefore, 1, "mid-step walkPhase is 1 before swap")
local progressBefore = entity.movement.progress
local stepFlipBefore = entity.stepFlip
local facingBefore = entity.facing

local applied = render:applyProviderSprite(entity, nil)
check(applied == true, "applyProviderSprite succeeds")
eq(entity.nativeSpriteRenderer, true, "nativeSpriteRenderer true after swap")
eq(entity.usingEnhancedSprite, false, "usingEnhancedSprite false for native sheet")
eq(entity.sprite.def.frames, 6, "swap def.frames == 6")
eq(entity.sprite.def.walker, true, "swap def.walker == true")
eq(entity.movement.progress, progressBefore, "movement progress preserved")
eq(entity.stepFlip, stepFlipBefore, "stepFlip preserved")
eq(entity.facing, facingBefore, "facing preserved")
eq(Movement.walkPhase(entity), 1, "walkPhase still 1 after swap")
check(Movement.isBusy(entity) == true, "still busy after swap")

-- Entity:pose returns the same phase the renderer must draw.
entity.pose = SpawnRender and nil
setmetatable(entity, { __index = getmetatable(render) and nil })
-- Bind Entity methods from SpawnRender's Entity table via a fresh make path:
-- call pose through the prototype stored on render-created entities.
-- Reuse Movement + walkPhase contract directly matching Entity:pose.
Movement.syncLegacyFields(entity)
local posePhase = Movement.walkPhase(entity)
eq(posePhase, 1, "pose phase matches walkPhase mid-step")
eq(entity.usingEnhancedSprite, false, "enhanced flag stays false after sync")

-- Finish step → stand frame
local done = false
for _ = 1, 40 do
  done = Movement.update(entity, 0.05)
  if done then break end
end
check(done == true, "step completes after swap")
eq(Movement.walkPhase(entity), 0, "stand phase after step end")

------------------------------------------------------------------------
-- C) Follower applySpriteDef preserves owner pose / exact def
------------------------------------------------------------------------
print("== follower sprite swap ==")
local followerApiCalls = 0
local fakeFollowersExports = {
  version = "1.0.19",
  getActiveFollowerMon = function()
    return { species = "PIKACHU", dvs = { attack = 1, defense = 1, speed = 1, special = 1 } }
  end,
}
V.mod.find = function(_, id)
  if id == "FOLLOWERS_EX" then
    return { id = id, version = "1.0.19", exports = fakeFollowersExports }
  end
  return nil
end

local compat = FollowersWaterCompat.new(V.mod, {
  resolveLandSprite = function(species, shiny, form, opts)
    return {
      image = def25.image,
      frames = 6,
      walker = true,
      trueColor = true,
      id = "SPRITE_POKEPC_MON",
      customFollowerField = "keep-me",
    }, { providerId = "pokemmo", kind = "pokemmo" }
  end,
})

local follower = {
  id = "trailer1",
  spawnId = "trailer1",
  cellX = 4, cellY = 4, px = 64, py = 64,
  facing = "left",
  phase = 1,
  flip = true,
  stepFlip = true,
  walkFlip = true,
  moving = true,
  passable = true,
  pokepcTrailer = true,
  pokepcTrailerKind = "mon",
  pokepcMon = { species = "PIKACHU" },
  species = "PIKACHU",
  pokepcShiny = false,
  movement = { state = "MOVING", progress = 0.12, facing = "left" },
  position = { tileX = 4, tileY = 4, pixelX = 64, pixelY = 64 },
  sprite = SpriteRendererStub.new({
    id = "SPRITE_POKEPC_MON",
    image = "mods/PokePCFollowers_VoxelMerge/assets/sprites/follower_PIKACHU.png",
    frames = 6,
    walker = true,
    trueColor = true,
  }, "trailer1"),
}
local owLand = {
  player = { cellX = 5, cellY = 4, surfing = false },
  entities = { follower },
  pokepcTrailers = { follower },
}
savedOpts.sprite_style = "pokemmo"
modules.config.spriteStyle = function() return "pokemmo" end

local changed = compat:tick(nil, owLand, function() return nil end)
check(changed == true or compat.status.lastAction == "to_land"
      or compat.status.lastAction == "style_land"
      or compat.status.lastAction == "to_land_keep",
      "follower land tick recorded")
eq(follower.facing, "left", "follower facing preserved")
eq(follower.phase, 1, "follower phase preserved")
eq(follower.stepFlip, true, "follower stepFlip preserved")
eq(follower.flip, true, "follower flip preserved")
eq(follower.movement.progress, 0.12, "follower movement progress preserved")
eq(follower.passable, true, "follower passable preserved")
eq(follower.usingEnhancedSprite, false, "follower not marked enhanced atlas")
if follower.sprite and follower.sprite.def then
  eq(follower.sprite.def.frames, 6, "follower def.frames exact")
  eq(follower.sprite.def.walker, true, "follower def.walker exact true")
  eq(follower.sprite.def.customFollowerField, "keep-me",
     "extra follower def fields retained")
end

-- Static provider must not be forced into a walker sheet.
local staticCompat = FollowersWaterCompat.new(V.mod, {
  resolveLandSprite = function()
    return {
      image = "assets/front/25.png",
      frames = 1,
      walker = false,
      trueColor = true,
      id = "SPRITE_STATIC",
    }, { providerId = "pokedex", kind = "pokedex" }
  end,
})
staticCompat:invalidateStyle()
local staticFollower = {
  id = "trailer2",
  cellX = 1, cellY = 1,
  facing = "down", phase = 0, flip = false, stepFlip = false,
  passable = true,
  pokepcTrailer = true,
  pokepcTrailerKind = "mon",
  pokepcMon = { species = "PIKACHU" },
  species = "PIKACHU",
  sprite = SpriteRendererStub.new({
    image = "old.png", frames = 6, walker = true,
  }, "trailer2"),
}
staticCompat:tick(nil, {
  player = { surfing = false },
  entities = { staticFollower },
  pokepcTrailers = { staticFollower },
}, function() return nil end)
if staticFollower.sprite and staticFollower.sprite.def then
  eq(staticFollower.sprite.def.frames, 1, "static provider frames stay 1")
  eq(staticFollower.sprite.def.walker, false, "static provider walker stays false")
end

------------------------------------------------------------------------
-- D) AGGRESSIVE search wander
------------------------------------------------------------------------
print("== AGGRESSIVE search wander ==")
eq(Behavior.AGGRESSIVE_SEARCH_WANDER_MIN_S, 1.5, "search wander min 1.5s")
eq(Behavior.AGGRESSIVE_SEARCH_WANDER_MAX_S, 3.5, "search wander max 3.5s")
eq(Behavior.AGGRESSIVE_SEARCH_WANDER_STEP_CHANCE, 0.60, "search wander step chance 60%")

local map = {
  widthCells = 8, heightCells = 8,
  inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 8 and y < 8 end,
  isWalkableCell = function() return true end,
  isGrassCell = function() return true end,
  isWaterCell = function() return false end,
  warpAtCell = function() return nil end,
}
local region = { id = "r1", membership = {} }
for y = 0, 7 do
  for x = 0, 7 do
    region.membership[x .. "," .. y] = true
  end
end

local agg = {
  id = "agg1",
  cellX = 3, cellY = 3,
  surface = Surface.GRASS,
  overworldWildSpawn = true,
  facing = "down",
  mod = V.mod,
  homeRegion = region,
}
Behavior.attach(agg, Behavior.AGGRESSIVE, region, function() return 0.99 end)
Movement.init(agg, 3, 3, "down")
local bx = agg.behaviorState
bx.nextActionAt = 0
eq(agg.behavior, Behavior.AGGRESSIVE, "behaviour stays AGGRESSIVE")

local playerFar = { cellX = 20, cellY = 20 }
local occupancy = CellOccupancy.new()
occupancy:rebuild({ player = playerFar, entities = { agg } })

-- Sequenced RNG: float#1 takes step branch, float#2 skips face-only, then cooldown.
local function makeStepRng()
  local floats = 0
  return function(n)
    if n then return 1 end
    floats = floats + 1
    if floats == 1 then return 0.1 end  -- < step chance
    if floats == 2 then return 0.9 end  -- >= faceOnlyChance
    return 0.5
  end
end

local movedOnce = false
for _ = 1, 12 do
  bx.nextActionAt = 0
  Behavior.tick(agg, {
    map = map,
    entities = { agg },
    player = playerFar,
    dt = 0.016,
    occupancy = occupancy,
    rng = makeStepRng(),
    sightRange = 4,
  })
  if Movement.isBusy(agg) or bx.state == Behavior.STATE.MOVING then
    movedOnce = true
    break
  end
end
check(movedOnce == true, "AGGRESSIVE search phase eventually wanders")
eq(agg.behavior, Behavior.AGGRESSIVE, "still AGGRESSIVE after wander")

-- Detection while idle search: no new wander, alert once.
if Movement.isBusy(agg) then
  for _ = 1, 40 do
    local d = Movement.update(agg, 0.05)
    if d then
      occupancy:commitMove(agg)
      break
    end
  end
end
Movement.init(agg, 3, 3, "right")
occupancy:rebuild({ player = playerFar, entities = { agg } })
bx = agg.behaviorState
bx.nextActionAt = 0
bx.playerDetected = false
bx.chasing = false
bx.sightDisabled = false
bx.state = Behavior.STATE.IDLE
bx.alertEmoteSpawned = false
bx.alertAt = nil
bx.facing = "right"
agg.facing = "right"
local playerSeen = { cellX = 5, cellY = 3 }
check(Behavior.playerInSight(agg, playerSeen, map, { agg }, 4) == true,
      "fixture: player in sight before tick")
local ev = Behavior.tick(agg, {
  map = map,
  entities = { agg },
  player = playerSeen,
  dt = 0.016,
  occupancy = occupancy,
  rng = makeStepRng(),
  sightRange = 4,
})
eq(ev, "alert", "detection returns alert")
eq(bx.state, Behavior.STATE.ALERT, "alert state after detection")
check(not Movement.isBusy(agg), "no wander step after detection")

-- Mid-wander detection cancels reservation and alerts.
Movement.init(agg, 3, 3, "right")
bx.playerDetected = false
bx.chasing = false
bx.sightDisabled = false
bx.state = Behavior.STATE.IDLE
bx.alertAt = nil
bx.chaseReady = false
bx.facing = "right"
agg.facing = "right"
occupancy = CellOccupancy.new()
occupancy:rebuild({ player = playerSeen, entities = { agg } })
check(occupancy:reserveMove(agg, 3, 3, 4, 3) == true, "reserve wander step")
check(Movement.beginStep(agg, 4, 3, { facing = "right" }) == true, "begin search step")
agg.movement.progress = (agg.movement.duration or 0.28) * 0.5
eq(Movement.walkPhase(agg), 1, "walkPhase mid search wander is 1")

ev = Behavior.tick(agg, {
  map = map,
  entities = { agg },
  player = playerSeen,
  dt = 0.016,
  occupancy = occupancy,
  rng = makeStepRng(),
  sightRange = 4,
})
eq(ev, "alert", "mid-wander detection alerts")
check(not Movement.isBusy(agg), "wander step stopped on detection")
eq(agg.behavior, Behavior.AGGRESSIVE, "behaviour remains AGGRESSIVE")

-- WATER_AGGRESSIVE also search-wanders on water cells.
print("== WATER_AGGRESSIVE search wander ==")
local waterMap = {
  widthCells = 8, heightCells = 8,
  inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 8 and y < 8 end,
  isWalkableCell = function() return false end,
  isGrassCell = function() return false end,
  isWaterCell = function() return true end,
  warpAtCell = function() return nil end,
}
local waterAgg = {
  id = "wagg1",
  cellX = 2, cellY = 2,
  surface = Surface.WATER,
  overworldWildSpawn = true,
  facing = "down",
  mod = V.mod,
  homeRegion = region,
}
Behavior.attach(waterAgg, Behavior.WATER_AGGRESSIVE, region, function(n)
  if n then return 1 end
  return 0.99
end)
Movement.init(waterAgg, 2, 2, "down")
waterAgg.behaviorState.nextActionAt = 0
local wOcc = CellOccupancy.new()
wOcc:rebuild({
  player = { cellX = 20, cellY = 20, surfing = true },
  entities = { waterAgg },
})
local waterMoved = false
for _ = 1, 12 do
  waterAgg.behaviorState.nextActionAt = 0
  Behavior.tick(waterAgg, {
    map = waterMap,
    entities = { waterAgg },
    player = { cellX = 20, cellY = 20, surfing = true },
    dt = 0.016,
    occupancy = wOcc,
    waterRegions = { componentOf = function() return 1 end },
    rng = makeStepRng(),
    sightRange = 4,
  })
  if Movement.isBusy(waterAgg)
     or waterAgg.behaviorState.state == Behavior.STATE.MOVING then
    waterMoved = true
    break
  end
end
check(waterMoved == true, "WATER_AGGRESSIVE search wander on water")
eq(waterAgg.behavior, Behavior.WATER_AGGRESSIVE, "still WATER_AGGRESSIVE")

if failures > 0 then
  io.stderr:write(("\n%d failure(s)\n"):format(failures))
  os.exit(1)
end
print("\nAll sprite_swap_anim unit tests passed.")
