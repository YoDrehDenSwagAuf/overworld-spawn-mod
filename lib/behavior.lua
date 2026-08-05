-- Behaviour types and per-entity state machines for overworld wild Pokemon.
-- Selection is weighted (optionally species / surface aware). Never uses Pokédex.
local V = ...
local Config = V.require("config")
local Surface = V.require("surface")
local SpawnRegions = V.require("spawn_regions")
local Movement = V.require("movement")
local CellOccupancy = V.require("cell_occupancy")
local SafariCompat = V.require("safari_compat")

local Behavior = {}

Behavior.IDLE_LOOK = "IDLE_LOOK"
Behavior.GRASS_WANDER = "GRASS_WANDER"
Behavior.AGGRESSIVE = "AGGRESSIVE"
Behavior.HIDDEN_GRASS = "HIDDEN_GRASS"
Behavior.HIDDEN_CAVE = "HIDDEN_CAVE"
Behavior.WATER_IDLE = "WATER_IDLE"
Behavior.WATER_WANDER = "WATER_WANDER"
Behavior.WATER_AGGRESSIVE = "WATER_AGGRESSIVE"
-- Safari-session land behaviours (replace AGGRESSIVE; reuse idle/wander ticks).
Behavior.SAFARI_IDLE = "SAFARI_IDLE"
Behavior.SAFARI_WANDER = "SAFARI_WANDER"
Behavior.SAFARI_FLEE = "SAFARI_FLEE"

Behavior.STATE = {
  IDLE = "IDLE",
  LOOKING = "LOOKING",
  PAUSED = "PAUSED",
  MOVING = "MOVING",
  PLAYER_DETECTED = "PLAYER_DETECTED",
  ALERT = "ALERT",
  CHASE_START = "CHASE_START",
  CHASING = "CHASING",
  BATTLE_PENDING = "BATTLE_PENDING",
  IN_BATTLE = "IN_BATTLE",
  CLEANUP = "CLEANUP",
  HIDDEN = "HIDDEN",
  LOCKED = "LOCKED",
  -- Safari flee sub-states (only evaluated in an active Safari session).
  PLAYER_NOTICED = "PLAYER_NOTICED",
  FLEE_START = "FLEE_START",
  FLEEING = "FLEEING",
  FLEE_DONE = "FLEE_DONE",
}

-- AGGRESSIVE / WATER_AGGRESSIVE search-phase wander (not a new public behaviour).
-- Slightly rarer than GRASS_WANDER so search feels alive without looking frantic.
Behavior.AGGRESSIVE_SEARCH_WANDER_MIN_S = 1.5
Behavior.AGGRESSIVE_SEARCH_WANDER_MAX_S = 3.5
Behavior.AGGRESSIVE_SEARCH_WANDER_STEP_CHANCE = 0.60

local FACINGS = { "down", "up", "left", "right" }

-- Forward declarations for land→water helpers used by stepToward.
local entityHasWaterSprite
local prepareWaterSprite
local applyWaterSurfaceTransition
local beginLandToWaterChaseStep
local rollbackLandToWaterEntry
local restoreLandSprite

local DEFAULT_WEIGHTS = {
  [Behavior.IDLE_LOOK] = 30,
  [Behavior.GRASS_WANDER] = 35,
  [Behavior.AGGRESSIVE] = 15,
  [Behavior.HIDDEN_GRASS] = 20,
  [Behavior.HIDDEN_CAVE] = 20,
  [Behavior.WATER_IDLE] = 40,
  [Behavior.WATER_WANDER] = 45,
  [Behavior.WATER_AGGRESSIVE] = 15,
  [Behavior.SAFARI_IDLE] = SafariCompat.LAND_WEIGHTS.SAFARI_IDLE,
  [Behavior.SAFARI_WANDER] = SafariCompat.LAND_WEIGHTS.SAFARI_WANDER,
  [Behavior.SAFARI_FLEE] = SafariCompat.LAND_WEIGHTS.SAFARI_FLEE,
}

local SPECIES_AFFINITY = {
  PIDGEY = { IDLE_LOOK = 1.4, GRASS_WANDER = 1.3, AGGRESSIVE = 0.4, HIDDEN_GRASS = 0.7 },
  PIDGEOTTO = { IDLE_LOOK = 1.2, GRASS_WANDER = 1.2, AGGRESSIVE = 0.6 },
  SPEAROW = { IDLE_LOOK = 0.8, GRASS_WANDER = 1.0, AGGRESSIVE = 1.6, HIDDEN_GRASS = 0.5 },
  FEAROW = { AGGRESSIVE = 1.8, IDLE_LOOK = 0.7 },
  CATERPIE = { HIDDEN_GRASS = 1.8, AGGRESSIVE = 0.3, IDLE_LOOK = 0.9 },
  WEEDLE = { HIDDEN_GRASS = 1.8, AGGRESSIVE = 0.3 },
  METAPOD = { IDLE_LOOK = 2.0, GRASS_WANDER = 0.2, AGGRESSIVE = 0.1, HIDDEN_GRASS = 1.2 },
  KAKUNA = { IDLE_LOOK = 2.0, GRASS_WANDER = 0.2, AGGRESSIVE = 0.1, HIDDEN_GRASS = 1.2 },
  EKANS = { AGGRESSIVE = 1.7, HIDDEN_GRASS = 1.2 },
  ARBOK = { AGGRESSIVE = 2.0 },
  MANKEY = { AGGRESSIVE = 1.8, GRASS_WANDER = 1.1 },
  GROWLITHE = { AGGRESSIVE = 1.6 },
  MAGIKARP = { IDLE_LOOK = 1.6, GRASS_WANDER = 0.6, AGGRESSIVE = 0.1, WATER_AGGRESSIVE = 0.15, WATER_IDLE = 1.4 },
  TENTACOOL = { GRASS_WANDER = 1.3, AGGRESSIVE = 1.2, WATER_AGGRESSIVE = 1.6, WATER_WANDER = 1.1 },
  TENTACRUEL = { WATER_AGGRESSIVE = 1.8, WATER_WANDER = 0.9 },
  GYARADOS = { WATER_AGGRESSIVE = 2.0, WATER_IDLE = 0.6 },
  ZUBAT = { GRASS_WANDER = 1.4, AGGRESSIVE = 1.3, HIDDEN_CAVE = 1.2 },
  GEODUDE = { IDLE_LOOK = 1.5, HIDDEN_CAVE = 1.5, AGGRESSIVE = 0.8 },
  ONIX = { IDLE_LOOK = 1.2, AGGRESSIVE = 1.4 },
}

local function rngOf(rng)
  if type(rng) == "function" then return rng end
  if love and love.math and love.math.random then return love.math.random end
  return math.random
end

local function now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

function Behavior.defaultWeights()
  local copy = {}
  for k, v in pairs(DEFAULT_WEIGHTS) do copy[k] = v end
  return copy
end

function Behavior.weightsFor(species, surface, opts)
  opts = opts or {}
  local weights = Behavior.defaultWeights()
  local allowed = Surface.BEHAVIORS[surface] or Surface.BEHAVIORS[Surface.GRASS]

  if surface == Surface.CAVE then
    weights[Behavior.HIDDEN_GRASS] = 0
    weights[Behavior.HIDDEN_CAVE] = DEFAULT_WEIGHTS[Behavior.HIDDEN_CAVE]
    weights[Behavior.WATER_IDLE] = 0
    weights[Behavior.WATER_WANDER] = 0
  elseif surface == Surface.WATER then
    weights[Behavior.HIDDEN_GRASS] = 0
    weights[Behavior.HIDDEN_CAVE] = 0
    weights[Behavior.IDLE_LOOK] = 0
    weights[Behavior.GRASS_WANDER] = 0
    weights[Behavior.AGGRESSIVE] = 0
    weights[Behavior.WATER_IDLE] = DEFAULT_WEIGHTS[Behavior.WATER_IDLE]
    weights[Behavior.WATER_WANDER] = DEFAULT_WEIGHTS[Behavior.WATER_WANDER]
    weights[Behavior.WATER_AGGRESSIVE] = DEFAULT_WEIGHTS[Behavior.WATER_AGGRESSIVE]
  else
    weights[Behavior.HIDDEN_CAVE] = 0
    weights[Behavior.WATER_IDLE] = 0
    weights[Behavior.WATER_WANDER] = 0
    weights[Behavior.WATER_AGGRESSIVE] = 0
  end

  if opts.enable_idle == false then weights[Behavior.IDLE_LOOK] = 0 end
  if opts.enable_wander == false then
    weights[Behavior.GRASS_WANDER] = 0
    weights[Behavior.WATER_WANDER] = 0
  end
  if opts.enable_aggressive == false then
    weights[Behavior.AGGRESSIVE] = 0
    weights[Behavior.WATER_AGGRESSIVE] = 0
  end
  if opts.enable_water_aggressive == false then
    weights[Behavior.WATER_AGGRESSIVE] = 0
  end
  if opts.enable_hidden == false then
    weights[Behavior.HIDDEN_GRASS] = 0
    weights[Behavior.HIDDEN_CAVE] = 0
  end
  if opts.hiddenCaveAvailable == false then
    weights[Behavior.HIDDEN_CAVE] = 0
  end

  local affinity = SPECIES_AFFINITY[species]
  if affinity then
    for b, mul in pairs(affinity) do
      if weights[b] then weights[b] = weights[b] * mul end
    end
  end

  local aggMul = tonumber(opts.aggressive_frequency) or 1.0
  weights[Behavior.AGGRESSIVE] = weights[Behavior.AGGRESSIVE] * aggMul
  local waterAggChance = tonumber(opts.water_aggressive_chance)
  if waterAggChance ~= nil then
    -- Scale WATER_AGGRESSIVE relative to idle+wander so chance ≈ waterAggChance.
    local base = (weights[Behavior.WATER_IDLE] or 0)
               + (weights[Behavior.WATER_WANDER] or 0)
    if waterAggChance <= 0 then
      weights[Behavior.WATER_AGGRESSIVE] = 0
    elseif base > 0 then
      local target = base * (waterAggChance / math.max(0.01, 1 - waterAggChance))
      weights[Behavior.WATER_AGGRESSIVE] = target * aggMul
    else
      weights[Behavior.WATER_AGGRESSIVE] = weights[Behavior.WATER_AGGRESSIVE] * aggMul
    end
  else
    weights[Behavior.WATER_AGGRESSIVE] = weights[Behavior.WATER_AGGRESSIVE] * aggMul
  end

  local allowedSet = {}
  for _, b in ipairs(allowed) do allowedSet[b] = true end
  for b in pairs(weights) do
    if not allowedSet[b] then weights[b] = 0 end
  end

  return weights
end

function Behavior.pick(species, surface, opts, rng)
  opts = opts or {}
  if opts.safari == true then
    return Behavior.pickSafari(species, surface, opts, rng)
  end
  rng = rngOf(rng)
  local weights = Behavior.weightsFor(species, surface, opts)
  local total = 0
  local order = {
    Behavior.IDLE_LOOK, Behavior.GRASS_WANDER, Behavior.AGGRESSIVE,
    Behavior.HIDDEN_GRASS, Behavior.HIDDEN_CAVE,
    Behavior.WATER_IDLE, Behavior.WATER_WANDER, Behavior.WATER_AGGRESSIVE,
  }
  for _, b in ipairs(order) do
    total = total + (weights[b] or 0)
  end
  if total <= 0 then
    if surface == Surface.WATER then
      return Behavior.WATER_IDLE
    end
    return Behavior.IDLE_LOOK
  end
  local roll = rng() * total
  if type(roll) ~= "number" then roll = (rng(10000) / 10000) * total end
  local acc = 0
  for _, b in ipairs(order) do
    acc = acc + (weights[b] or 0)
    if roll <= acc then return b end
  end
  if surface == Surface.WATER then
    return Behavior.WATER_IDLE
  end
  return Behavior.IDLE_LOOK
end

-- Safari-session behaviour selection. Never returns AGGRESSIVE / WATER_AGGRESSIVE.
-- Land: SAFARI_IDLE / SAFARI_WANDER / SAFARI_FLEE. Water: WATER_IDLE / WATER_WANDER.
function Behavior.weightsForSafari(species, surface, opts)
  opts = opts or {}
  local weights = {
    [Behavior.SAFARI_IDLE] = 0,
    [Behavior.SAFARI_WANDER] = 0,
    [Behavior.SAFARI_FLEE] = 0,
    [Behavior.WATER_IDLE] = 0,
    [Behavior.WATER_WANDER] = 0,
  }

  if surface == Surface.WATER then
    weights[Behavior.WATER_IDLE] = SafariCompat.WATER_WEIGHTS.WATER_IDLE
    weights[Behavior.WATER_WANDER] = SafariCompat.WATER_WEIGHTS.WATER_WANDER
  else
    weights[Behavior.SAFARI_IDLE] = SafariCompat.LAND_WEIGHTS.SAFARI_IDLE
    weights[Behavior.SAFARI_WANDER] = SafariCompat.LAND_WEIGHTS.SAFARI_WANDER
    weights[Behavior.SAFARI_FLEE] = SafariCompat.LAND_WEIGHTS.SAFARI_FLEE

    -- Species affinity: map land temperaments onto Safari behaviours.
    local affinity = SPECIES_AFFINITY[species]
    if affinity then
      if affinity.IDLE_LOOK then
        weights[Behavior.SAFARI_IDLE] =
          weights[Behavior.SAFARI_IDLE] * affinity.IDLE_LOOK
      end
      if affinity.GRASS_WANDER then
        weights[Behavior.SAFARI_WANDER] =
          weights[Behavior.SAFARI_WANDER] * affinity.GRASS_WANDER
      end
      -- Aggressive affinity boosts SAFARI_FLEE (skittish / reactive species).
      if affinity.AGGRESSIVE then
        weights[Behavior.SAFARI_FLEE] =
          weights[Behavior.SAFARI_FLEE] * affinity.AGGRESSIVE
      end
    end
    local fleeMul = SafariCompat.fleeAffinity(species)
    weights[Behavior.SAFARI_FLEE] = weights[Behavior.SAFARI_FLEE] * fleeMul

    if opts.enable_idle == false then weights[Behavior.SAFARI_IDLE] = 0 end
    if opts.enable_wander == false then weights[Behavior.SAFARI_WANDER] = 0 end
    if opts.enable_safari_flee == false or opts.enable_flee == false then
      weights[Behavior.SAFARI_FLEE] = 0
    end
  end

  return weights
end

function Behavior.pickSafari(species, surface, opts, rng)
  rng = rngOf(rng)
  local weights = Behavior.weightsForSafari(species, surface, opts)
  local order
  if surface == Surface.WATER then
    order = { Behavior.WATER_IDLE, Behavior.WATER_WANDER }
  else
    order = { Behavior.SAFARI_IDLE, Behavior.SAFARI_WANDER, Behavior.SAFARI_FLEE }
  end
  local total = 0
  for _, b in ipairs(order) do
    total = total + (weights[b] or 0)
  end
  if total <= 0 then
    if surface == Surface.WATER then return Behavior.WATER_IDLE end
    return Behavior.SAFARI_IDLE
  end
  local roll = rng() * total
  if type(roll) ~= "number" then roll = (rng(10000) / 10000) * total end
  local acc = 0
  for _, b in ipairs(order) do
    acc = acc + (weights[b] or 0)
    if roll <= acc then return b end
  end
  if surface == Surface.WATER then return Behavior.WATER_IDLE end
  return Behavior.SAFARI_IDLE
end

function Behavior.isHidden(behavior)
  return behavior == Behavior.HIDDEN_GRASS
      or behavior == Behavior.HIDDEN_CAVE
end

function Behavior.isSafari(behavior)
  return behavior == Behavior.SAFARI_IDLE
      or behavior == Behavior.SAFARI_WANDER
      or behavior == Behavior.SAFARI_FLEE
end

function Behavior.isSafariFlee(behavior)
  return behavior == Behavior.SAFARI_FLEE
end

function Behavior.initState(behavior, rng)
  rng = rngOf(rng)
  local lookMin = Config.DEFAULTS.idle_look_min_s or 5
  local lookMax = Config.DEFAULTS.idle_look_max_s or 10
  local interval = lookMin + (rng() * (lookMax - lookMin))
  if type(interval) ~= "number" or interval ~= interval then
    interval = lookMin + ((rng(100) - 1) / 100) * (lookMax - lookMin)
  end
  local facing = FACINGS[rng(#FACINGS)]
  local rustleMin = 1.5
  local rustleMax = 4.0
  local rustleInterval = rustleMin + (rng() * (rustleMax - rustleMin))
  if type(rustleInterval) ~= "number" or rustleInterval ~= rustleInterval then
    rustleInterval = rustleMin + ((rng(100) - 1) / 100) * (rustleMax - rustleMin)
  end
  local st = {
    behavior = behavior,
    state = Behavior.isHidden(behavior) and Behavior.STATE.HIDDEN or Behavior.STATE.IDLE,
    facing = facing,
    nextActionAt = now() + interval,
    lookInterval = interval,
    moveCooldown = 0.6 + (rng() * 1.4),
    playerDetected = false,
    chasing = false,
    chaseReady = false,
    alertEmoteSpawned = false,
    alertAt = nil,
    chaseFailCount = 0,
    path = nil,
    shakePhase = 0,
    shakeNextAt = now() + rustleInterval,
    leftHome = false,
    battleStarted = false,
    battlePending = false,
    sightDisabled = true,
    fleeReady = false,
    safariFlee = nil,
  }
  if Behavior.isSafari(behavior) then
    st.safariFlee = Behavior.newSafariFleeState()
    -- Only SAFARI_FLEE watches the player; idle/wander keep sight off for aggro.
    if behavior == Behavior.SAFARI_FLEE then
      st.sightDisabled = false
    else
      st.sightDisabled = true
    end
  elseif Behavior.isAggressive(behavior) then
    st.sightDisabled = false
    -- Search wander uses a shorter cadence than IDLE_LOOK.
    local lo = Behavior.AGGRESSIVE_SEARCH_WANDER_MIN_S
    local hi = Behavior.AGGRESSIVE_SEARCH_WANDER_MAX_S
    st.nextActionAt = now() + lo + (rng() * (hi - lo))
  elseif not Behavior.isHidden(behavior) then
    st.sightDisabled = false
  end
  return st
end

function Behavior.newSafariFleeState()
  return {
    active = false,
    noticedPlayer = false,
    alertStarted = false,
    fleeStepsTaken = 0,
    fleeStepsTarget = 0,
    fleeStartedAt = nil,
    fleeCooldownUntil = nil,
  }
end

function Behavior.clearSafariFlee(entity)
  local bx = entity and entity.behaviorState
  if not bx then return end
  bx.fleeReady = false
  bx.safariFlee = nil
  if bx.state == Behavior.STATE.PLAYER_NOTICED
     or bx.state == Behavior.STATE.FLEE_START
     or bx.state == Behavior.STATE.FLEEING
     or bx.state == Behavior.STATE.FLEE_DONE then
    bx.state = Behavior.STATE.IDLE
  end
end

local function occupiedBlocked(entities, x, y, ignore, occupancy)
  if occupancy then
    if occupancy:isOccupied(x, y, ignore) then return true, "occupied" end
    if occupancy:isReserved(x, y, ignore) then return true, "reserved" end
  end
  for _, e in ipairs(entities or {}) do
    if e ~= ignore then
      local same = (e.cellX == x and e.cellY == y)
                or (e.targetX == x and e.targetY == y)
      if same then
        if e.overworldWildSpawn then return true, "pokemon" end
        if CellOccupancy.isFollowerEntity(e) then return true, "follower" end
        if not e.passable then return true, "npc" end
      end
    end
  end
  return false
end

local function isTemporaryOccupancyBlock(reason)
  return reason == "occupied"
      or reason == "reserved"
      or reason == "swap_blocked"
      or reason == "follower"
      or reason == "npc"
      or reason == "pokemon"
      or reason == "blocked"
end

local function canStep(map, entities, entity, player, nx, ny, region, allowLeaveHome, opts)
  opts = opts or {}
  if not map then return false end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  if nx < 0 or ny < 0 or nx >= w or ny >= h then return false, "oob" end
  if map.inBounds and not map:inBounds(nx, ny) then return false, "oob" end
  if map.warpAtCell and map:warpAtCell(nx, ny) then return false, "warp" end
  if player and player.cellX == nx and player.cellY == ny then
    return false, "player"
  end
  -- Hard occupancy first (canStep is read-only; never writes reservations).
  local blocked, blockWhy = occupiedBlocked(entities, nx, ny, entity, opts.occupancy)
  if blocked then return false, blockWhy or "occupied" end

  -- Water-surface entities stay on water. Land aggro must never inherit
  -- water-only from behaviour name alone (shared tick must not leak).
  -- Committed surface only — pendingSurface must not force water-only yet.
  local onWater = entity.surface == Surface.WATER
  local forceWaterOnly = opts.waterOnly == true or onWater

  if forceWaterOnly then
    if not (map.isWaterCell and map:isWaterCell(nx, ny)) then
      return false, "not_water"
    end
    if not allowLeaveHome and region and not SpawnRegions.contains(region, nx, ny) then
      return false, "outside_region"
    end
    return true
  end

  -- Land entity entering adjacent water (controlled land→water chase).
  -- Terrain exception only: occupancy already passed above.
  if opts.allowEnterWater and map.isWaterCell and map:isWaterCell(nx, ny) then
    return true, "enter_water"
  end

  if allowLeaveHome then
    if map.isWalkableCell and not map:isWalkableCell(nx, ny) then
      return false, "not_walkable"
    end
    -- Cave entities may leave home region when aggressive, but never enter
    -- unreachable / cut-off cave pockets.
    if opts.reachableCaveCells then
      local key = tostring(nx) .. ":" .. tostring(ny)
      if not opts.reachableCaveCells[key] then
        return false, "unreachable_cave"
      end
    end
    return true
  end

  if region and not SpawnRegions.contains(region, nx, ny) then
    return false, "outside_region"
  end
  if entity.surface == Surface.GRASS then
    if not (map.isGrassCell and map:isGrassCell(nx, ny)) then
      return false, "not_grass"
    end
    if map.isWalkableCell and not map:isWalkableCell(nx, ny) then
      return false, "not_walkable"
    end
  else
    if map.isWalkableCell and not map:isWalkableCell(nx, ny) then
      return false, "not_walkable"
    end
    if opts.reachableCaveCells then
      local key = tostring(nx) .. ":" .. tostring(ny)
      if not opts.reachableCaveCells[key] then
        return false, "unreachable_cave"
      end
    end
  end
  return true
end

local function lineOfSight(map, entities, x0, y0, x1, y1, opts)
  opts = opts or {}
  if x0 ~= x1 and y0 ~= y1 then return false end
  local dx = x1 > x0 and 1 or x1 < x0 and -1 or 0
  local dy = y1 > y0 and 1 or y1 < y0 and -1 or 0
  local x, y = x0 + dx, y0 + dy
  while x ~= x1 or y ~= y1 do
    if opts.waterOnly then
      if not (map.isWaterCell and map:isWaterCell(x, y)) then
        return false
      end
    elseif map.isWalkableCell and not map:isWalkableCell(x, y) then
      -- Allow water cells when checking land→water sight along a water corridor.
      if not (opts.allowWater and map.isWaterCell and map:isWaterCell(x, y)) then
        return false
      end
    end
    for _, e in ipairs(entities or {}) do
      if not e.passable and not e.overworldWildSpawn
         and e.cellX == x and e.cellY == y then
        return false
      end
    end
    x, y = x + dx, y + dy
  end
  return true
end

function Behavior.playerInSight(entity, player, map, entities, range, opts)
  opts = opts or {}
  if not entity or not player or not map then return false end
  local bx = entity.behaviorState
  if not bx then return false end
  if bx.sightDisabled or bx.playerDetected or bx.chasing
     or bx.battlePending or bx.battleStarted then
    return false
  end
  local facing = bx.facing or entity.facing or "down"
  local ex, ey = entity.cellX, entity.cellY
  local px, py = player.cellX, player.cellY
  local dx, dy = 0, 0
  if facing == "up" then dy = -1
  elseif facing == "down" then dy = 1
  elseif facing == "left" then dx = -1
  elseif facing == "right" then dx = 1
  end
  if dx ~= 0 and ey ~= py then return false end
  if dy ~= 0 and ex ~= px then return false end
  local dist
  if dx ~= 0 then
    dist = (px - ex) * dx
  else
    dist = (py - ey) * dy
  end
  if not dist or dist < 1 or dist > range then return false end
  return lineOfSight(map, entities, ex, ey, px, py, opts)
end

local function playerSurfing(player, map)
  if not player then return false end
  if player.surfing == true then return true end
  if player.surface == Surface.WATER or player.surface == "water" then
    return true
  end
  -- Require explicit surf state when available; never treat bridge/coast as water.
  if player.surfing == false then return false end
  return false
end

local function sameWaterComponent(map, waterRegions, x0, y0, x1, y1)
  if not map then return false end
  if not (map.isWaterCell and map:isWaterCell(x0, y0) and map:isWaterCell(x1, y1)) then
    return false
  end
  if waterRegions and #waterRegions > 0 then
    local r0 = SpawnRegions.regionForCell(waterRegions, x0, y0)
    local r1 = SpawnRegions.regionForCell(waterRegions, x1, y1)
    if r0 and r1 then return r0.id == r1.id end
  end
  return true
end

local function tryFace(entity, rng)
  rng = rngOf(rng)
  local bx = entity.behaviorState
  local cur = bx.facing or entity.facing or "down"
  local choices = {}
  for _, f in ipairs(FACINGS) do
    if f ~= cur then choices[#choices + 1] = f end
  end
  if #choices == 0 then choices = FACINGS end
  local nextFacing = choices[rng(#choices)]
  Movement.setFacing(entity, nextFacing)
  bx.state = Behavior.STATE.LOOKING
  local lookMin = Config.DEFAULTS.idle_look_min_s or 5
  local lookMax = Config.DEFAULTS.idle_look_max_s or 10
  local interval = lookMin + (rng() * (lookMax - lookMin))
  if type(interval) ~= "number" or interval ~= interval then
    interval = lookMin + ((rng(100) - 1) / 100) * (lookMax - lookMin)
  end
  bx.lookInterval = interval
  bx.nextActionAt = now() + interval
end

local function manhattan(ax, ay, bx, by)
  return math.abs((ax or 0) - (bx or 0)) + math.abs((ay or 0) - (by or 0))
end

local function facingForDelta(dx, dy)
  if dx > 0 then return "right" end
  if dx < 0 then return "left" end
  if dy > 0 then return "down" end
  return "up"
end

-- Build orthogonal chase candidates. When allowEnterWater / waterOnly chase,
-- expand beyond the primary axis so a free alternate shore/water cell can win.
local function chaseStepCandidates(ex, ey, tx, ty, opts)
  opts = opts or {}
  local primary = {}
  if math.abs(tx - ex) >= math.abs(ty - ey) then
    if tx ~= ex then primary[#primary + 1] = { tx > ex and 1 or -1, 0 } end
    if ty ~= ey then primary[#primary + 1] = { 0, ty > ey and 1 or -1 } end
  else
    if ty ~= ey then primary[#primary + 1] = { 0, ty > ey and 1 or -1 } end
    if tx ~= ex then primary[#primary + 1] = { tx > ex and 1 or -1, 0 } end
  end

  if not (opts.allowEnterWater or opts.expandOrthogonal) then
    return primary
  end

  local seen = {}
  local out = {}
  local function push(dx, dy)
    local key = dx .. ":" .. dy
    if seen[key] then return end
    seen[key] = true
    out[#out + 1] = { dx, dy }
  end
  for _, d in ipairs(primary) do push(d[1], d[2]) end
  for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    push(d[1], d[2])
  end
  return out
end

local function scoreChaseCandidate(nx, ny, player, occupancy, opts, map)
  local px = player and player.cellX or nx
  local py = player and player.cellY or ny
  local score = manhattan(nx, ny, px, py)
  if occupancy and occupancy:isOccupied(nx, ny) then
    score = score + 100
  elseif occupancy and occupancy:isReserved(nx, ny) then
    score = score + 50
  end
  -- Prefer staying in / entering the player's water region when known.
  if opts and opts.preferPlayerWaterRegion and map and opts.waterRegions then
    local playerRegion = SpawnRegions.regionForCell(
      opts.waterRegions, px, py)
    local candRegion = SpawnRegions.regionForCell(
      opts.waterRegions, nx, ny)
    if playerRegion and candRegion and playerRegion.id ~= candRegion.id then
      score = score + 20
    elseif playerRegion and not candRegion then
      score = score + 10
    end
  end
  return score
end

local function stepToward(entity, map, entities, player, tx, ty, region, allowLeave, chase, opts)
  opts = opts or {}
  if Movement.isBusy(entity) then return false, "busy" end
  local ex, ey = entity.cellX, entity.cellY
  if ex == tx and ey == ty then return false, "arrived" end
  local occupancy = opts.occupancy

  local raw = chaseStepCandidates(ex, ey, tx, ty, opts)
  local scored = {}
  local sawPlayerContact = false
  for _, d in ipairs(raw) do
    local nx, ny = ex + d[1], ey + d[2]
    local ok, reason = canStep(map, entities, entity, player, nx, ny, region, allowLeave, opts)
    if ok then
      local enterWater = reason == "enter_water"
      -- For land→water, only keep true water candidates.
      if enterWater or not opts.allowEnterWater or not (map.isWaterCell and map:isWaterCell(nx, ny)) then
        local score = scoreChaseCandidate(nx, ny, player, occupancy, {
          preferPlayerWaterRegion = enterWater or opts.waterOnly,
          waterRegions = opts.waterRegions,
        }, map)
        -- Prefer primary axis (lower index in raw list) on ties via tiny bias.
        score = score + (#scored) * 0.01
        -- When a surfing chase may enter water, prefer the free water cell over
        -- an equally good land sidestep so the shore transition actually starts.
        if enterWater then
          score = score - 0.5
        end
        scored[#scored + 1] = {
          dx = d[1], dy = d[2], nx = nx, ny = ny,
          reason = reason, enterWater = enterWater, score = score,
        }
      end
    elseif reason == "player" then
      -- Never step onto the player; prefer another free water cell first.
      sawPlayerContact = true
      entity.movementBlockedBy = "player"
    else
      entity.movementBlockedBy = reason or "blocked"
    end
  end

  table.sort(scored, function(a, b) return a.score < b.score end)

  for _, cand in ipairs(scored) do
    local nx, ny = cand.nx, cand.ny
    local d = { cand.dx, cand.dy }
    if cand.enterWater then
      local started, why = beginLandToWaterChaseStep(
        entity, map, player, nx, ny, opts, d)
      if started then
        entity.movementBlockedBy = nil
        return true, "enter_water"
      end
      entity.movementBlockedBy = why or "blocked"
      -- try next candidate
    else
      if occupancy then
        local reserved, why = occupancy:reserveMove(entity, ex, ey, nx, ny)
        if not reserved then
          entity.movementBlockedBy = why or "occupied"
        else
          local facing = facingForDelta(d[1], d[2])
          local started = Movement.beginStep(entity, nx, ny, {
            facing = facing,
            chase = chase == true,
            duration = chase and (Config.DEFAULTS.aggressive_step_seconds or 0.18)
                       or (Config.DEFAULTS.wild_step_seconds or 0.28),
          })
          if started then
            entity.movementBlockedBy = nil
            return true, nil
          end
          occupancy:cancelMove(entity)
          entity.movementBlockedBy = "begin_failed"
        end
      else
        local facing = facingForDelta(d[1], d[2])
        local started = Movement.beginStep(entity, nx, ny, {
          facing = facing,
          chase = chase == true,
          duration = chase and (Config.DEFAULTS.aggressive_step_seconds or 0.18)
                     or (Config.DEFAULTS.wild_step_seconds or 0.28),
        })
        if started then
          entity.movementBlockedBy = nil
          return true, nil
        end
        entity.movementBlockedBy = "begin_failed"
      end
    end
  end
  if sawPlayerContact and #scored == 0 then
    return false, "contact"
  end
  return false, entity.movementBlockedBy or "blocked"
end

local function contactWithPlayer(entity, player)
  if not player then return false end
  if entity.cellX == player.cellX and entity.cellY == player.cellY then
    return true
  end
  local adx = math.abs(entity.cellX - player.cellX)
  local ady = math.abs(entity.cellY - player.cellY)
  return adx + ady == 1
end

local function resetAggro(bx, t)
  if not bx then return end
  bx.chasing = false
  bx.playerDetected = false
  bx.chaseReady = false
  bx.sightDisabled = false
  bx.chaseFailCount = 0
  bx.battlePending = false
  bx.alertEmoteSpawned = false
  bx.alertAt = nil
  bx.battlePendingAt = nil
  bx.pendingWaterEnter = false
  bx.waterChase = false
  bx.state = Behavior.STATE.IDLE
  bx.nextActionAt = (t or now()) + 1.5
end

local function enterDetected(entity, bx, player)
  bx.playerDetected = true
  bx.sightDisabled = true
  bx.alertEmoteSpawned = false
  bx.chaseReady = false
  bx.alertAt = now()
  bx.state = Behavior.STATE.PLAYER_DETECTED
  if player and entity.cellX and entity.cellY then
    local fdx = (player.cellX or 0) - entity.cellX
    local fdy = (player.cellY or 0) - entity.cellY
    local face
    if math.abs(fdx) >= math.abs(fdy) then
      face = (fdx >= 0) and "right" or "left"
    else
      face = (fdy >= 0) and "down" or "up"
    end
    Movement.setFacing(entity, face)
  end
  Movement.stop(entity, Movement.STATE.ALERT)
  bx.state = Behavior.STATE.ALERT
end

local function enterAlert(bx)
  bx.state = Behavior.STATE.ALERT
  bx.sightDisabled = true
  if not bx.alertAt then bx.alertAt = now() end
end

local function enterChase(entity, bx)
  bx.chasing = true
  bx.leftHome = true
  bx.sightDisabled = true
  bx.chaseReady = true
  bx.state = Behavior.STATE.CHASING
  if entity.movement then entity.movement.state = Movement.STATE.CHASING end
end

local function leaveChase(entity, bx, t)
  resetAggro(bx, t)
  Movement.stop(entity, Movement.STATE.IDLE)
end

local function enterBattlePending(entity, bx)
  bx.state = Behavior.STATE.BATTLE_PENDING
  bx.battlePending = true
  bx.battlePendingAt = now()
  bx.sightDisabled = true
  bx.chasing = true
  Movement.stop(entity, Movement.STATE.BATTLE_PENDING)
end

-- Shared GRASS_WANDER / WATER_WANDER / aggressive-search step planner.
-- Uses the same canStep + occupancy + Movement.beginStep contract.
local function planWanderStep(entity, ctx, bx, t, opts)
  opts = opts or {}
  local map = ctx.map
  local entities = ctx.entities
  local player = ctx.player
  local region = entity.homeRegion
  local rng = rngOf(ctx.rng)
  local waterOnly = opts.waterOnly == true
    or entity.surface == Surface.WATER

  local dirs = { { 0, -1, "up" }, { 0, 1, "down" }, { -1, 0, "left" }, { 1, 0, "right" } }
  for i = #dirs, 2, -1 do
    local j = rng(i)
    dirs[i], dirs[j] = dirs[j], dirs[i]
  end

  local faceOnlyChance = opts.faceOnlyChance
  if faceOnlyChance == nil then faceOnlyChance = 0.35 end
  if rng() < faceOnlyChance then
    Movement.setFacing(entity, dirs[rng(#dirs)][3])
    bx.state = Behavior.STATE.LOOKING
    return false, "look"
  end

  local stepOpts = {
    occupancy = ctx.occupancy,
    waterOnly = waterOnly,
    reachableCaveCells = (entity.surface == Surface.CAVE) and ctx.reachableCaveCells or nil,
  }
  for _, d in ipairs(dirs) do
    local nx, ny = entity.cellX + d[1], entity.cellY + d[2]
    if canStep(map, entities, entity, player, nx, ny, region, false, stepOpts) then
      local reserved = true
      if ctx.occupancy then
        reserved = ctx.occupancy:reserveMove(entity, entity.cellX, entity.cellY, nx, ny)
      end
      if reserved and Movement.beginStep(entity, nx, ny, { facing = d[3] }) then
        entity.movementBlockedBy = nil
        bx.state = Behavior.STATE.MOVING
        return true, nil
      end
      if ctx.occupancy then ctx.occupancy:cancelMove(entity) end
      entity.movementBlockedBy = "occupied"
    end
  end
  return false, "blocked"
end

local function searchWanderCooldown(rng)
  rng = rngOf(rng)
  local lo = Behavior.AGGRESSIVE_SEARCH_WANDER_MIN_S
  local hi = Behavior.AGGRESSIVE_SEARCH_WANDER_MAX_S
  return lo + rng() * (hi - lo)
end

-- Aggressive search phase: occasional wander + look, never leaves AGGRESSIVE.
local function tryAggressiveSearchWander(entity, ctx, bx, t, opts)
  opts = opts or {}
  if bx.playerDetected or bx.chasing or bx.sightDisabled then
    return false
  end
  if Movement.isBusy(entity) then
    return false
  end
  if t < (bx.nextActionAt or 0) then
    bx.state = bx.state or Behavior.STATE.IDLE
    return false
  end

  local rng = rngOf(ctx.rng)
  local stepChance = opts.stepChance or Behavior.AGGRESSIVE_SEARCH_WANDER_STEP_CHANCE
  if rng() < stepChance then
    local moved = planWanderStep(entity, ctx, bx, t, {
      waterOnly = opts.waterOnly,
      faceOnlyChance = 0.25,
    })
    bx.nextActionAt = t + searchWanderCooldown(rng)
    return moved == true
  end

  tryFace(entity, rng)
  -- Search cadence is intentionally shorter than IDLE_LOOK intervals.
  bx.nextActionAt = t + searchWanderCooldown(rng)
  return false
end

-- Sight check during a search wander step. Detection stops the step safely.
local function interruptSearchWanderOnSight(entity, ctx, bx, player, range, sightOpts)
  if bx.playerDetected or bx.chasing or bx.sightDisabled then
    return false
  end
  if not Behavior.playerInSight(entity, player, ctx.map, ctx.entities, range, sightOpts) then
    return false
  end
  if Movement.isBusy(entity) then
    Movement.stop(entity, Movement.STATE.ALERT)
    if ctx.occupancy then
      ctx.occupancy:cancelMove(entity)
    end
  end
  enterDetected(entity, bx, player)
  return true
end

-- Heal inconsistent aggro flags so sight/chase cannot soft-lock.
local function healAggroFlags(entity, bx, t)
  if not bx then return end
  if bx.battleStarted then return end

  if bx.battlePending and not bx.battleStarted then
    local started = bx.battlePendingAt or bx.alertAt or t
    if (t - started) > 5.0 then
      -- Battle never started — release so AI/sight can recover.
      bx.battlePending = false
      bx.battlePendingAt = nil
      if bx.state == Behavior.STATE.BATTLE_PENDING then
        leaveChase(entity, bx, t)
      end
    end
  end

  if bx.playerDetected and bx.state == Behavior.STATE.IDLE and not bx.alertAt
     and not bx.chasing and not bx.chaseReady then
    bx.playerDetected = false
    bx.sightDisabled = false
  end

  if bx.chasing
     and bx.state ~= Behavior.STATE.CHASING
     and bx.state ~= Behavior.STATE.CHASE_START
     and bx.state ~= Behavior.STATE.ALERT
     and bx.state ~= Behavior.STATE.PLAYER_DETECTED
     and bx.state ~= Behavior.STATE.BATTLE_PENDING then
    bx.chasing = false
    bx.sightDisabled = false
  end

  -- Alert without chaseReady: fail-safe after reaction window.
  if (bx.state == Behavior.STATE.ALERT or bx.state == Behavior.STATE.PLAYER_DETECTED)
     and not bx.chaseReady and not bx.battlePending then
    local alertAt = bx.alertAt or t
    if (t - alertAt) >= 2.5 then
      Behavior.markChaseReady(entity)
    end
  end
end

local function abortWaterChase(entity, bx, t)
  leaveChase(entity, bx, t)
  local idle = (math.random() < 0.45) and Behavior.WATER_IDLE or Behavior.WATER_WANDER
  -- Stay on water; never return to land behaviour.
  if Behavior.isWater(bx.behavior) or entity.surface == Surface.WATER then
    bx.behavior = idle
    entity.behavior = idle
  end
end

entityHasWaterSprite = function(entity, ctx)
  if entity.hasWaterSprite == true then return true end
  if entity.hasWaterSprite == false then return false end
  local check = ctx and ctx.hasWaterSprite
  if type(check) == "function" then
    local ok, result = pcall(check, entity)
    if ok then
      entity.hasWaterSprite = result == true
      return entity.hasWaterSprite
    end
  end
  -- Unknown: deny land→water rather than showing a land sprite on water.
  return false
end

restoreLandSprite = function(entity, ctx)
  if not entity then return end
  local committed = entity.originSurface or entity.surface or Surface.GRASS
  if committed == Surface.WATER then
    committed = Surface.GRASS
  end
  entity.surface = committed
  entity.spriteState = "land"
  entity.pendingSurface = nil
  entity.waterSpritePrepared = false
  entity.waterSpriteApplied = false
  entity.waterEntryReserved = false
  local logic = ctx and ctx.logic
  local game = ctx and ctx.game
  if not game and entity.mod and entity.mod.world then
    game = entity.mod.world.game
  end
  if logic and logic.refreshEntitySprite then
    pcall(logic.refreshEntitySprite, logic, entity, {
      reason = "entered_land",
      surface = committed,
      spriteState = "land",
      game = game,
    })
  elseif entity.render and entity.render.applyProviderSprite then
    pcall(entity.render.applyProviderSprite, entity.render, entity, game)
  end
end

rollbackLandToWaterEntry = function(entity, ctx, reason)
  if not entity then return end
  local occupancy = ctx and ctx.occupancy
  if occupancy then
    occupancy:cancelMove(entity)
  end
  entity.pendingSurface = nil
  entity.waterEntryReserved = false
  entity.waterSpritePrepared = false
  entity.waterSpriteApplied = false
  entity.movementBlockedBy = reason or entity.movementBlockedBy
  restoreLandSprite(entity, ctx)
end

-- Prepare water sprite AFTER a successful reservation.
-- Committed surface stays land until tile commit; only spriteState/pendingSurface
-- flip so rendering can show swimming without routing AI onto water-only logic.
prepareWaterSprite = function(entity, ctx)
  if not entity then return false end
  if not entityHasWaterSprite(entity, ctx) then
    return false, "no_water_sprite"
  end
  local logic = ctx and ctx.logic
  local game = ctx and ctx.game
  if not game and entity.mod and entity.mod.world then
    game = entity.mod.world.game
  end
  entity.originSurface = entity.originSurface or entity.surface or Surface.GRASS
  entity.pendingSurface = Surface.WATER
  local prevSurface = entity.surface
  local prevState = entity.spriteState
  -- Temporarily expose water surface so the central resolver picks swimming /
  -- levitates, then restore the committed land surface for movement/AI.
  entity.surface = Surface.WATER
  entity.spriteState = "water"
  local ok = false
  if logic and logic.refreshEntitySprite then
    ok = select(1, logic:refreshEntitySprite(entity, {
      reason = "prepare_water_entry",
      surface = Surface.WATER,
      spriteState = "water",
      pendingSurface = Surface.WATER,
      game = game,
    }))
  elseif entity.render and entity.render.applyProviderSprite then
    ok = select(1, pcall(entity.render.applyProviderSprite, entity.render, entity, game))
  else
    -- Unit-test / headless path: mark prepared without a renderer.
    ok = true
  end
  -- Always restore committed surface so tickAggressive keeps land chase path.
  entity.surface = prevSurface
  if not ok then
    entity.spriteState = prevState
    entity.pendingSurface = nil
    entity.waterSpritePrepared = false
    entity.waterSpriteApplied = false
    return false, "sprite_apply_failed"
  end
  entity.spriteState = "water"
  entity.pendingSurface = Surface.WATER
  entity.waterSpritePrepared = true
  entity.waterSpriteApplied = true
  entity.lastSpriteRefreshReason = "prepare_water_entry"
  return true
end

beginLandToWaterChaseStep = function(entity, map, player, nx, ny, ctx, delta)
  ctx = ctx or {}
  local occupancy = ctx.occupancy
  local ex, ey = entity.cellX, entity.cellY
  delta = delta or { nx - ex, ny - ey }

  -- Eligibility (terrain exception only; occupancy checked by canStep + reserve).
  if not entityHasWaterSprite(entity, ctx) then
    return false, "no_water_sprite"
  end
  if not (map and map.isWaterCell and map:isWaterCell(nx, ny)) then
    return false, "not_water"
  end
  if player and player.cellX == nx and player.cellY == ny then
    return false, "player"
  end
  if math.abs(nx - ex) + math.abs(ny - ey) ~= 1 then
    return false, "not_adjacent"
  end

  -- 1) Atomic reserve first (before any sprite change).
  if occupancy then
    local reserved, why = occupancy:reserveMove(entity, ex, ey, nx, ny, {
      kind = "land_to_water_chase",
    })
    if not reserved then
      entity.movementBlockedBy = why or "occupied"
      return false, why or "occupied"
    end
    entity.waterEntryReserved = true
  end

  -- 2) Prepare / apply water sprite only after reservation succeeded.
  local prepared, prepErr = prepareWaterSprite(entity, ctx)
  if not prepared then
    rollbackLandToWaterEntry(entity, ctx, prepErr or "water_sprite_failed")
    return false, prepErr or "water_sprite_failed"
  end

  -- 3) Begin interpolated step while committed surface is still land.
  local facing = facingForDelta(delta[1], delta[2])
  local started = Movement.beginStep(entity, nx, ny, {
    facing = facing,
    chase = true,
    duration = Config.DEFAULTS.aggressive_step_seconds or 0.18,
  })
  if not started then
    rollbackLandToWaterEntry(entity, ctx, "begin_failed")
    return false, "begin_failed"
  end

  entity.pendingSurface = Surface.WATER
  entity.waterEntryReserved = true
  entity.movementBlockedBy = nil
  return true, "enter_water"
end

applyWaterSurfaceTransition = function(entity, ctx)
  if not entity then return end
  local bx = entity.behaviorState
  entity.originSurface = entity.originSurface or entity.surface or Surface.GRASS
  entity.surface = Surface.WATER
  entity.spriteState = "water"
  entity.surfaceVisualOffset = 2
  entity.waterSink = 2
  entity.waterEnteredByChase = true
  entity.pendingSurface = nil
  entity.waterEntryReserved = false
  if bx then
    bx.behavior = Behavior.WATER_AGGRESSIVE
    bx.waterChase = true
    entity.behavior = Behavior.WATER_AGGRESSIVE
  end
  -- Ensure swimming/levitates via the same central refresh path as water spawns.
  local logic = ctx and ctx.logic
  local game = ctx and ctx.game
  if not game and entity.mod and entity.mod.world then
    game = entity.mod.world.game
  end
  if logic and logic.refreshEntitySprite then
    pcall(function()
      logic:refreshEntitySprite(entity, {
        reason = "entered_water",
        surface = Surface.WATER,
        spriteState = "water",
        game = game,
      })
    end)
  elseif entity.render and entity.render.applyProviderSprite then
    pcall(entity.render.applyProviderSprite, entity.render, entity, game)
  end
  entity.waterSpriteApplied = true
  entity.waterSpritePrepared = true
  entity.lastSpriteRefreshReason = "entered_water"
end

local function landAdjacentToWater(map, x, y)
  if not map or not map.isWaterCell then return false end
  for _, d in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
    if map:isWaterCell(x + d[1], y + d[2]) then return true end
  end
  return false
end

local function shoreDistanceOfPlayer(map, player, shoreMap)
  if not player then return nil end
  if shoreMap and shoreMap.distance then
    local k = player.cellX .. ":" .. player.cellY
    return shoreMap.distance[k]
  end
  -- Fallback BFS-lite: manhattan to nearest walkable land.
  if not map then return nil end
  local best = nil
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  for cy = math.max(0, player.cellY - 8), math.min(h - 1, player.cellY + 8) do
    for cx = math.max(0, player.cellX - 8), math.min(w - 1, player.cellX + 8) do
      local isLand = true
      if map.isWaterCell and map:isWaterCell(cx, cy) then isLand = false end
      if isLand and map.isWalkableCell and not map:isWalkableCell(cx, cy) then
        isLand = false
      end
      if isLand then
        local d = math.abs(cx - player.cellX) + math.abs(cy - player.cellY)
        if not best or d < best then best = d end
      end
    end
  end
  return best
end

-- Land chase restored from f457d26. Water opts must not alter this path.
local function tickLandAggressive(entity, ctx, bx, t)
  local map = ctx.map
  local entities = ctx.entities
  local player = ctx.player
  local region = entity.homeRegion
  local range = ctx.sightRange or Config.DEFAULTS.aggressive_sight_range or 4

  healAggroFlags(entity, bx, t)

  if bx.state == Behavior.STATE.BATTLE_PENDING
     or bx.state == Behavior.STATE.IN_BATTLE
     or bx.state == Behavior.STATE.CLEANUP
     or bx.battlePending or bx.battleStarted then
    Movement.stop(entity, Movement.STATE.BATTLE_PENDING)
    bx.sightDisabled = true
    return bx.battleStarted and nil or "battle_pending"
  end

  if Movement.isBusy(entity) then
    local completed = Movement.update(entity, ctx.dt or 0.016)
    if completed then
      if ctx.occupancy then ctx.occupancy:commitMove(entity) end
      Movement.refreshGrassFlag(entity, entity.mod)
      if bx.pendingWaterEnter and map and map.isWaterCell
         and map:isWaterCell(entity.cellX, entity.cellY) then
        bx.pendingWaterEnter = false
        applyWaterSurfaceTransition(entity, ctx)
        return "entered_water"
      end
    end
    if bx.state == Behavior.STATE.CHASING or bx.chasing then
      if contactWithPlayer(entity, player) then
        enterBattlePending(entity, bx)
        return "contact"
      end
      return nil
    end
    -- Search wander mid-step: detection has priority over finishing aimlessly.
    local sightOptsBusy = {}
    if ctx.waterMonsEnabled ~= false
       and playerSurfing(player, map)
       and entityHasWaterSprite(entity, ctx)
       and landAdjacentToWater(map, entity.cellX, entity.cellY) then
      local pDist = shoreDistanceOfPlayer(map, player, ctx.shoreMap)
      local maxPlayer = ctx.landWaterPlayerMax
                     or Config.DEFAULTS.land_water_chase_player_max or 5
      if pDist ~= nil and pDist <= maxPlayer then
        sightOptsBusy.allowWater = true
      end
    end
    if interruptSearchWanderOnSight(entity, ctx, bx, player, range, sightOptsBusy) then
      return "alert"
    end
    return nil
  end

  -- Step may have completed in BehaviorTick before this AI tick.
  if bx.pendingWaterEnter and map and map.isWaterCell
     and map:isWaterCell(entity.cellX, entity.cellY)
     and not Movement.isBusy(entity) then
    bx.pendingWaterEnter = false
    applyWaterSurfaceTransition(entity, ctx)
    return "entered_water"
  end

  if bx.state == Behavior.STATE.CHASING or bx.chasing then
    enterChase(entity, bx)
    if not player then return nil end
    if contactWithPlayer(entity, player) then
      enterBattlePending(entity, bx)
      return "contact"
    end

    local stepOpts = {
      occupancy = ctx.occupancy,
      logic = ctx.logic,
      game = ctx.game,
      hasWaterSprite = ctx.hasWaterSprite,
      waterRegions = ctx.waterRegions,
      reachableCaveCells = (entity.surface == Surface.CAVE) and ctx.reachableCaveCells or nil,
    }
    -- Optional controlled land→water chase (does not change land canStep defaults).
    if ctx.waterMonsEnabled ~= false
       and playerSurfing(player, map)
       and entityHasWaterSprite(entity, ctx)
       and landAdjacentToWater(map, entity.cellX, entity.cellY) then
      local pDist = shoreDistanceOfPlayer(map, player, ctx.shoreMap)
      local maxPlayer = ctx.landWaterPlayerMax
                     or Config.DEFAULTS.land_water_chase_player_max or 5
      if pDist ~= nil and pDist <= maxPlayer then
        stepOpts.allowEnterWater = true
      end
    end

    local moved, why = stepToward(
      entity, map, entities, player,
      player.cellX, player.cellY, region, true, true, stepOpts)
    if why == "contact" then
      enterBattlePending(entity, bx)
      return "contact"
    end
    if why == "enter_water" then
      bx.pendingWaterEnter = true
      if map.isWaterCell and map:isWaterCell(entity.cellX, entity.cellY)
         and not Movement.isBusy(entity) then
        bx.pendingWaterEnter = false
        applyWaterSurfaceTransition(entity, ctx)
        return "entered_water"
      end
    end
    if not moved then
      local block = entity.movementBlockedBy or why
      if isTemporaryOccupancyBlock(block) then
        -- Temporary blocker at shore: wait briefly, keep chase alive.
        bx.nextActionAt = now() + 0.1
      else
        bx.chaseFailCount = (bx.chaseFailCount or 0) + 1
        if bx.chaseFailCount > 24 then
          leaveChase(entity, bx, t)
        end
      end
    else
      bx.chaseFailCount = 0
      Movement.refreshGrassFlag(entity, entity.mod)
    end
    return nil
  end

  if bx.state == Behavior.STATE.CHASE_START then
    enterChase(entity, bx)
    return "chase_start"
  end

  if bx.state == Behavior.STATE.ALERT or bx.state == Behavior.STATE.PLAYER_DETECTED then
    enterAlert(bx)
    Movement.stop(entity, Movement.STATE.ALERT)
    if entity.movement then entity.movement.state = Movement.STATE.ALERT end
    if bx.chaseReady then
      bx.state = Behavior.STATE.CHASE_START
      bx.alertEmoteSpawned = true
      return nil
    end
    return nil
  end

  local sightOpts = {}
  if ctx.waterMonsEnabled ~= false
     and playerSurfing(player, map)
     and entityHasWaterSprite(entity, ctx)
     and landAdjacentToWater(map, entity.cellX, entity.cellY) then
    local pDist = shoreDistanceOfPlayer(map, player, ctx.shoreMap)
    local maxPlayer = ctx.landWaterPlayerMax
                   or Config.DEFAULTS.land_water_chase_player_max or 5
    if pDist ~= nil and pDist <= maxPlayer then
      sightOpts.allowWater = true
    end
  end

  -- Sight first: never start a new search wander after detection.
  if Behavior.playerInSight(entity, player, map, entities, range, sightOpts) then
    enterDetected(entity, bx, player)
    return "alert"
  end

  tryAggressiveSearchWander(entity, ctx, bx, t, { waterOnly = false })
  return nil
end

-- Water aggressive: same state machine as land, water-only steps + surf gate.
local function tickWaterAggressive(entity, ctx, bx, t)
  local map = ctx.map
  local entities = ctx.entities
  local player = ctx.player
  local region = entity.homeRegion
  local range = ctx.waterSightRange
             or Config.DEFAULTS.water_aggressive_sight_range
             or ctx.sightRange
             or Config.DEFAULTS.aggressive_sight_range
             or 4

  healAggroFlags(entity, bx, t)

  if bx.state == Behavior.STATE.BATTLE_PENDING
     or bx.state == Behavior.STATE.IN_BATTLE
     or bx.state == Behavior.STATE.CLEANUP
     or bx.battlePending or bx.battleStarted then
    Movement.stop(entity, Movement.STATE.BATTLE_PENDING)
    bx.sightDisabled = true
    return bx.battleStarted and nil or "battle_pending"
  end

  if bx.chasing then
    if not player or not playerSurfing(player, map) then
      abortWaterChase(entity, bx, t)
      return "chase_abort"
    end
    if not sameWaterComponent(map, ctx.waterRegions,
                              entity.cellX, entity.cellY,
                              player.cellX, player.cellY) then
      abortWaterChase(entity, bx, t)
      return "chase_abort"
    end
  end

  if Movement.isBusy(entity) then
    local completed = Movement.update(entity, ctx.dt or 0.016)
    if completed then
      if ctx.occupancy then ctx.occupancy:commitMove(entity) end
      Movement.refreshGrassFlag(entity, entity.mod)
    end
    if bx.state == Behavior.STATE.CHASING or bx.chasing then
      if contactWithPlayer(entity, player) then
        enterBattlePending(entity, bx)
        return "contact"
      end
      return nil
    end
    if interruptSearchWanderOnSight(entity, ctx, bx, player, range, { waterOnly = true }) then
      return "alert"
    end
    return nil
  end

  if bx.state == Behavior.STATE.CHASING or bx.chasing then
    enterChase(entity, bx)
    if not player then return nil end
    if contactWithPlayer(entity, player) then
      enterBattlePending(entity, bx)
      return "contact"
    end
    local moved, why = stepToward(
      entity, map, entities, player,
      player.cellX, player.cellY, region, true, true, {
        waterOnly = true,
        expandOrthogonal = true,
        occupancy = ctx.occupancy,
        logic = ctx.logic,
        game = ctx.game,
        hasWaterSprite = ctx.hasWaterSprite,
        waterRegions = ctx.waterRegions,
      })
    if why == "contact" then
      enterBattlePending(entity, bx)
      return "contact"
    end
    if not moved then
      local block = entity.movementBlockedBy or why
      if isTemporaryOccupancyBlock(block) then
        bx.nextActionAt = now() + 0.1
      else
        bx.chaseFailCount = (bx.chaseFailCount or 0) + 1
        if bx.chaseFailCount > 24 then
          abortWaterChase(entity, bx, t)
          return "chase_abort"
        end
      end
    else
      bx.chaseFailCount = 0
    end
    return nil
  end

  if bx.state == Behavior.STATE.CHASE_START then
    enterChase(entity, bx)
    return "chase_start"
  end

  if bx.state == Behavior.STATE.ALERT or bx.state == Behavior.STATE.PLAYER_DETECTED then
    enterAlert(bx)
    Movement.stop(entity, Movement.STATE.ALERT)
    if entity.movement then entity.movement.state = Movement.STATE.ALERT end
    if bx.chaseReady then
      bx.state = Behavior.STATE.CHASE_START
      bx.alertEmoteSpawned = true
      return nil
    end
    return nil
  end

  -- Water search: only watch / wander while the player shares this water body.
  if playerSurfing(player, map)
     and sameWaterComponent(map, ctx.waterRegions,
                            entity.cellX, entity.cellY,
                            player.cellX, player.cellY)
     and Behavior.playerInSight(entity, player, map, entities, range, { waterOnly = true }) then
    enterDetected(entity, bx, player)
    return "alert"
  end

  -- Water search wander uses WATER_WANDER-compatible cells only.
  tryAggressiveSearchWander(entity, ctx, bx, t, { waterOnly = true })
  return nil
end

local function tickAggressive(entity, ctx, bx, t)
  -- Hard split: committed water surface / water behaviour only.
  -- pendingSurface during land→water interpolation must NOT route here early.
  if entity.surface == Surface.WATER or bx.behavior == Behavior.WATER_AGGRESSIVE then
    return tickWaterAggressive(entity, ctx, bx, t)
  end
  return tickLandAggressive(entity, ctx, bx, t)
end

local function ensureSafariFlee(bx)
  if not bx.safariFlee then
    bx.safariFlee = Behavior.newSafariFleeState()
  end
  return bx.safariFlee
end

local function scoreFleeCandidate(nx, ny, player, ex, ey)
  local px = player and player.cellX or ex
  local py = player and player.cellY or ey
  local dist = math.abs(nx - px) + math.abs(ny - py)
  -- Prefer moving away from the player (increase manhattan distance).
  local cur = math.abs(ex - px) + math.abs(ey - py)
  local score = dist
  if dist > cur then
    score = score + 2 -- direction bonus
  elseif dist < cur then
    score = score - 4 -- strongly discourage approaching
  end
  -- Tiny axis preference: pure opposite axis over sideways when tied.
  local awayDx = ex - px
  local awayDy = ey - py
  local stepDx = nx - ex
  local stepDy = ny - ey
  if awayDx ~= 0 and stepDx ~= 0 and ((awayDx > 0) == (stepDx > 0)) then
    score = score + 0.5
  end
  if awayDy ~= 0 and stepDy ~= 0 and ((awayDy > 0) == (stepDy > 0)) then
    score = score + 0.5
  end
  return score
end

-- One orthogonal flee step away from the player. Uses the same occupancy
-- reservation + canStep gates as wander/chase (no teleports / swaps).
local function stepAwayFrom(entity, map, entities, player, region, opts)
  opts = opts or {}
  if Movement.isBusy(entity) then return false, "busy" end
  if not player then return false, "no_player" end
  local ex, ey = entity.cellX, entity.cellY
  local occupancy = opts.occupancy
  local dirs = {
    { 0, -1, "up" }, { 0, 1, "down" },
    { -1, 0, "left" }, { 1, 0, "right" },
  }
  local scored = {}
  for _, d in ipairs(dirs) do
    local nx, ny = ex + d[1], ey + d[2]
    local ok, reason = canStep(map, entities, entity, player, nx, ny, region, false, opts)
    if ok then
      local score = scoreFleeCandidate(nx, ny, player, ex, ey)
      scored[#scored + 1] = {
        nx = nx, ny = ny, facing = d[3], score = score,
      }
    else
      entity.movementBlockedBy = reason or "blocked"
    end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  for _, cand in ipairs(scored) do
    local reserved = true
    if occupancy then
      reserved = occupancy:reserveMove(entity, ex, ey, cand.nx, cand.ny)
    end
    if reserved then
      local started = Movement.beginStep(entity, cand.nx, cand.ny, {
        facing = cand.facing,
        duration = Config.DEFAULTS.wild_step_seconds or 0.28,
      })
      if started then
        entity.movementBlockedBy = nil
        return true, nil
      end
      if occupancy then occupancy:cancelMove(entity) end
      entity.movementBlockedBy = "begin_failed"
    else
      entity.movementBlockedBy = "occupied"
    end
  end
  return false, entity.movementBlockedBy or "blocked"
end

local function enterSafariNoticed(entity, bx, player)
  local sf = ensureSafariFlee(bx)
  sf.active = true
  sf.noticedPlayer = true
  sf.alertStarted = false
  bx.playerDetected = true
  bx.sightDisabled = true
  bx.fleeReady = false
  bx.alertEmoteSpawned = false
  bx.alertAt = now()
  bx.state = Behavior.STATE.PLAYER_NOTICED
  if player and entity.cellX and entity.cellY then
    local fdx = (player.cellX or 0) - entity.cellX
    local fdy = (player.cellY or 0) - entity.cellY
    local face
    if math.abs(fdx) >= math.abs(fdy) then
      face = (fdx >= 0) and "right" or "left"
    else
      face = (fdy >= 0) and "down" or "up"
    end
    Movement.setFacing(entity, face)
  end
  Movement.stop(entity, Movement.STATE.ALERT)
  bx.state = Behavior.STATE.ALERT
end

local function beginSafariFlee(entity, bx, rng)
  local sf = ensureSafariFlee(bx)
  rng = rngOf(rng)
  sf.active = true
  sf.fleeStepsTaken = 0
  sf.fleeStepsTarget = SafariCompat.randomRangeInt(
    rng, SafariCompat.FLEE_STEPS_MIN, SafariCompat.FLEE_STEPS_MAX)
  sf.fleeStartedAt = now()
  sf.fleeCooldownUntil = nil
  bx.fleeReady = true
  bx.sightDisabled = true
  bx.state = Behavior.STATE.FLEE_START
end

local function finishSafariFlee(entity, bx, rng)
  local sf = ensureSafariFlee(bx)
  rng = rngOf(rng)
  sf.active = false
  sf.noticedPlayer = false
  sf.alertStarted = false
  sf.fleeStepsTaken = 0
  sf.fleeStepsTarget = 0
  sf.fleeStartedAt = nil
  local cool = SafariCompat.randomRangeFloat(
    rng, SafariCompat.FLEE_COOLDOWN_MIN, SafariCompat.FLEE_COOLDOWN_MAX)
  sf.fleeCooldownUntil = now() + cool
  bx.fleeReady = false
  bx.playerDetected = false
  bx.alertEmoteSpawned = false
  bx.alertAt = nil
  bx.sightDisabled = false
  bx.state = Behavior.STATE.FLEE_DONE

  -- Return to idle or wander after a short escape (never despawn).
  local nextBeh = (rng() < 0.45) and Behavior.SAFARI_IDLE or Behavior.SAFARI_WANDER
  bx.behavior = nextBeh
  entity.behavior = nextBeh
  bx.state = Behavior.STATE.IDLE
  bx.nextActionAt = now() + (0.4 + rng() * 1.0)
  Movement.stop(entity, Movement.STATE.IDLE)
end

local function tickSafariFlee(entity, ctx, bx, t)
  -- Hard gate: never evaluate flee state outside an active Safari session.
  if not ctx or not ctx.safariActive then
    Behavior.clearSafariFlee(entity)
    return nil
  end

  local map = ctx.map
  local entities = ctx.entities
  local player = ctx.player
  local region = entity.homeRegion
  local rng = rngOf(ctx.rng)
  local sf = ensureSafariFlee(bx)
  local range = ctx.safariSightRange or SafariCompat.SIGHT_RANGE

  if bx.battlePending or bx.battleStarted
     or bx.state == Behavior.STATE.BATTLE_PENDING
     or bx.state == Behavior.STATE.IN_BATTLE then
    Movement.stop(entity, Movement.STATE.BATTLE_PENDING)
    sf.active = false
    return bx.battleStarted and nil or "battle_pending"
  end

  -- Cooldown after a completed flee: idle/wander-like facing only.
  if sf.fleeCooldownUntil and t < sf.fleeCooldownUntil
     and not sf.active
     and bx.state ~= Behavior.STATE.ALERT
     and bx.state ~= Behavior.STATE.PLAYER_NOTICED
     and bx.state ~= Behavior.STATE.FLEE_START
     and bx.state ~= Behavior.STATE.FLEEING then
    if Movement.isBusy(entity) then
      Movement.update(entity, ctx.dt or 0.016)
      return nil
    end
    if t >= (bx.nextActionAt or 0) then
      tryFace(entity, rng)
    end
    return nil
  end

  if Movement.isBusy(entity) then
    local done = Movement.update(entity, ctx.dt or 0.016)
    if done then
      if ctx.occupancy then ctx.occupancy:commitMove(entity) end
      Movement.refreshGrassFlag(entity, entity.mod)
      if bx.state == Behavior.STATE.FLEEING or sf.active then
        sf.fleeStepsTaken = (sf.fleeStepsTaken or 0) + 1
        if sf.fleeStepsTaken >= (sf.fleeStepsTarget or 0) then
          finishSafariFlee(entity, bx, rng)
          return "flee_done"
        end
      end
    end
    return nil
  end

  -- Alert / noticed: freeze, face player, wait for fleeReady (emote onDone).
  if bx.state == Behavior.STATE.ALERT
     or bx.state == Behavior.STATE.PLAYER_NOTICED
     or bx.state == Behavior.STATE.PLAYER_DETECTED then
    Movement.stop(entity, Movement.STATE.ALERT)
    bx.sightDisabled = true
    if bx.fleeReady then
      beginSafariFlee(entity, bx, rng)
      bx.state = Behavior.STATE.FLEEING
      return "flee_start"
    end
    -- Fail-safe if emote never completes.
    local alertAt = bx.alertAt or t
    if (t - alertAt) >= (SafariCompat.ALERT_TIMEOUT or 1.2) then
      Behavior.markFleeReady(entity)
      beginSafariFlee(entity, bx, rng)
      bx.state = Behavior.STATE.FLEEING
      return "flee_start"
    end
    return nil
  end

  if bx.state == Behavior.STATE.FLEE_START then
    -- markFleeReady already armed us; finish bookkeeping and report once.
    if (sf.fleeStepsTarget or 0) <= 0 then
      beginSafariFlee(entity, bx, rng)
    end
    bx.state = Behavior.STATE.FLEEING
    sf.active = true
    local moved = stepAwayFrom(entity, map, entities, player, region, {
      occupancy = ctx.occupancy,
      reachableCaveCells = (entity.surface == Surface.CAVE) and ctx.reachableCaveCells or nil,
    })
    if not moved then
      bx.nextActionAt = t + 0.15
    end
    return "flee_start"
  end

  if bx.state == Behavior.STATE.FLEEING or (sf.active and bx.fleeReady) then
    bx.state = Behavior.STATE.FLEEING
    sf.active = true
    if (sf.fleeStepsTaken or 0) >= (sf.fleeStepsTarget or 0)
       and (sf.fleeStepsTarget or 0) > 0 then
      finishSafariFlee(entity, bx, rng)
      return "flee_done"
    end
    local moved, why = stepAwayFrom(entity, map, entities, player, region, {
      occupancy = ctx.occupancy,
      reachableCaveCells = (entity.surface == Surface.CAVE) and ctx.reachableCaveCells or nil,
    })
    if not moved then
      -- All candidates blocked: wait briefly, retry (no teleport).
      bx.nextActionAt = t + 0.15
      entity.movementBlockedBy = why or entity.movementBlockedBy
      -- If stuck for many attempts, end flee early rather than soft-lock.
      sf._blockCount = (sf._blockCount or 0) + 1
      if sf._blockCount > 12 then
        finishSafariFlee(entity, bx, rng)
        return "flee_done"
      end
    else
      sf._blockCount = 0
    end
    return nil
  end

  -- Idle watching: detect player in sight once.
  if Movement.isBusy(entity) then
    Movement.update(entity, ctx.dt or 0.016)
    return nil
  end
  if t >= (bx.nextActionAt or 0) and not sf.noticedPlayer then
    tryFace(entity, rng)
  end

  if sf.noticedPlayer or bx.playerDetected or bx.sightDisabled then
    return nil
  end
  if sf.fleeCooldownUntil and t < sf.fleeCooldownUntil then
    return nil
  end

  if Behavior.playerInSight(entity, player, map, entities, range) then
    enterSafariNoticed(entity, bx, player)
    return "alert"
  end
  return nil
end

local function tickSafariIdle(entity, ctx, bx, t)
  -- Reuse land idle look; Safari idle never detects/chases.
  if Movement.isBusy(entity) then
    Movement.update(entity, ctx.dt or 0.016)
    return nil
  end
  local rng = rngOf(ctx.rng)
  if t >= (bx.nextActionAt or 0) then
    tryFace(entity, rng)
  else
    bx.state = Behavior.STATE.IDLE
  end
  return nil
end

local function tickSafariWander(entity, ctx, bx, t)
  -- Same movement path as GRASS_WANDER (occupancy + region + canStep).
  local map = ctx.map
  local entities = ctx.entities
  local player = ctx.player
  local region = entity.homeRegion
  local rng = rngOf(ctx.rng)

  if Movement.isBusy(entity) then
    local done = Movement.update(entity, ctx.dt or 0.016)
    if done then
      if ctx.occupancy then ctx.occupancy:commitMove(entity) end
      bx.state = Behavior.STATE.PAUSED
      bx.nextActionAt = t + (0.4 + rng() * 1.6)
      Movement.refreshGrassFlag(entity, entity.mod)
    end
    return nil
  end
  if t < (bx.nextActionAt or 0) then
    bx.state = Behavior.STATE.PAUSED
    return nil
  end
  local dirs = { { 0, -1, "up" }, { 0, 1, "down" }, { -1, 0, "left" }, { 1, 0, "right" } }
  for i = #dirs, 2, -1 do
    local j = rng(i)
    dirs[i], dirs[j] = dirs[j], dirs[i]
  end
  if rng() < 0.35 then
    Movement.setFacing(entity, dirs[rng(#dirs)][3])
    bx.state = Behavior.STATE.PAUSED
    bx.nextActionAt = t + (0.5 + rng() * 2.0)
    return nil
  end
  local stepOpts = {
    occupancy = ctx.occupancy,
    reachableCaveCells = (entity.surface == Surface.CAVE) and ctx.reachableCaveCells or nil,
  }
  for _, d in ipairs(dirs) do
    local nx, ny = entity.cellX + d[1], entity.cellY + d[2]
    if canStep(map, entities, entity, player, nx, ny, region, false, stepOpts) then
      local reserved = true
      if ctx.occupancy then
        reserved = ctx.occupancy:reserveMove(entity, entity.cellX, entity.cellY, nx, ny)
      end
      if reserved and Movement.beginStep(entity, nx, ny, { facing = d[3] }) then
        entity.movementBlockedBy = nil
        bx.state = Behavior.STATE.MOVING
        bx.nextActionAt = t + (0.55 + rng() * 1.2)
        return nil
      end
      if ctx.occupancy then ctx.occupancy:cancelMove(entity) end
      entity.movementBlockedBy = "occupied"
    end
  end
  bx.nextActionAt = t + (0.8 + rng() * 1.5)
  bx.state = Behavior.STATE.PAUSED
  return nil
end

function Behavior.tickSafari(entity, ctx)
  if not entity or not entity.behaviorState then return nil end
  local bx = entity.behaviorState
  if not ctx or not ctx.safariActive then
    Behavior.clearSafariFlee(entity)
    return nil
  end
  local t = now()
  if bx.behavior == Behavior.SAFARI_FLEE then
    return tickSafariFlee(entity, ctx, bx, t)
  end
  if bx.behavior == Behavior.SAFARI_IDLE then
    return tickSafariIdle(entity, ctx, bx, t)
  end
  if bx.behavior == Behavior.SAFARI_WANDER then
    return tickSafariWander(entity, ctx, bx, t)
  end
  -- Water Safari reuses normal water idle/wander ticks via Behavior.tick.
  return nil
end

function Behavior.tick(entity, ctx)
  if not entity or not entity.behaviorState then return nil end
  local bx = entity.behaviorState
  if bx.battleStarted or entity.state == Config.STATE.REMOVED
     or entity.state == Config.STATE.ENCOUNTER_STARTING
     or entity.state == Config.STATE.IN_BATTLE then
    return nil
  end

  local map = ctx.map
  local entities = ctx.entities
  local player = ctx.player
  local region = entity.homeRegion
  local rng = rngOf(ctx.rng)
  ctx.rng = rng
  local t = now()

  -- Cave scenery (Mixed unreachable): never aggro / chase through walls.
  if ctx.suppressAggressive or entity.caveScenery then
    bx.sightDisabled = true
    bx.playerDetected = false
    bx.chasing = false
    if bx.behavior == Behavior.AGGRESSIVE then
      bx.behavior = Behavior.IDLE_LOOK
      entity.behavior = Behavior.IDLE_LOOK
    end
  end

  if Behavior.isHidden(bx.behavior) then
    bx.state = Behavior.STATE.HIDDEN
    if t >= (bx.shakeNextAt or 0) then
      bx.shakePhase = (bx.shakePhase or 0) + 1
      bx.shakeNextAt = t + (2.5 + rng() * 3.5)
      entity.grassEffectActive = true
      entity.grassEffectUntil = t + 0.45
    end
    if entity.grassEffectUntil and t > entity.grassEffectUntil then
      entity.grassEffectActive = false
    end
    return nil
  end

  -- Safari land behaviours are isolated; never leak into normal maps.
  if Behavior.isSafari(bx.behavior) then
    if ctx.safariActive then
      return Behavior.tickSafari(entity, ctx)
    end
    -- Session ended / left Safari: strip flee state and idle safely.
    Behavior.clearSafariFlee(entity)
    bx.behavior = Behavior.IDLE_LOOK
    entity.behavior = Behavior.IDLE_LOOK
    bx.state = Behavior.STATE.IDLE
    return nil
  end

  if bx.behavior == Behavior.IDLE_LOOK or bx.behavior == Behavior.WATER_IDLE
     or bx.behavior == Behavior.SAFARI_IDLE then
    if Movement.isBusy(entity) then
      Movement.update(entity, ctx.dt or 0.016)
      return nil
    end
    if t >= (bx.nextActionAt or 0) then
      tryFace(entity, rng)
    else
      bx.state = Behavior.STATE.IDLE
    end
    return nil
  end

  if bx.behavior == Behavior.GRASS_WANDER or bx.behavior == Behavior.WATER_WANDER then
    if Movement.isBusy(entity) then
      local done = Movement.update(entity, ctx.dt or 0.016)
      if done then
        if ctx.occupancy then ctx.occupancy:commitMove(entity) end
        bx.state = Behavior.STATE.PAUSED
        bx.nextActionAt = t + (0.4 + rng() * 1.6)
        Movement.refreshGrassFlag(entity, entity.mod)
      end
      return nil
    end
    if t < (bx.nextActionAt or 0) then
      bx.state = Behavior.STATE.PAUSED
      return nil
    end
    local dirs = { { 0, -1, "up" }, { 0, 1, "down" }, { -1, 0, "left" }, { 1, 0, "right" } }
    for i = #dirs, 2, -1 do
      local j = rng(i)
      dirs[i], dirs[j] = dirs[j], dirs[i]
    end
    if rng() < 0.35 then
      Movement.setFacing(entity, dirs[rng(#dirs)][3])
      bx.state = Behavior.STATE.PAUSED
      bx.nextActionAt = t + (0.5 + rng() * 2.0)
      return nil
    end
    local stepOpts = {
      occupancy = ctx.occupancy,
      waterOnly = bx.behavior == Behavior.WATER_WANDER or entity.surface == Surface.WATER,
      reachableCaveCells = (entity.surface == Surface.CAVE) and ctx.reachableCaveCells or nil,
    }
    for _, d in ipairs(dirs) do
      local nx, ny = entity.cellX + d[1], entity.cellY + d[2]
      if canStep(map, entities, entity, player, nx, ny, region, false, stepOpts) then
        local reserved = true
        if ctx.occupancy then
          reserved = ctx.occupancy:reserveMove(entity, entity.cellX, entity.cellY, nx, ny)
        end
        if reserved and Movement.beginStep(entity, nx, ny, { facing = d[3] }) then
          entity.movementBlockedBy = nil
          bx.state = Behavior.STATE.MOVING
          bx.nextActionAt = t + (0.55 + rng() * 1.2)
          return nil
        end
        if ctx.occupancy then ctx.occupancy:cancelMove(entity) end
        entity.movementBlockedBy = "occupied"
      end
    end
    -- Blocked wander: short cooldown, retry later (no teleport / shove).
    bx.nextActionAt = t + (0.8 + rng() * 1.5)
    bx.state = Behavior.STATE.PAUSED
    return nil
  end

  if bx.behavior == Behavior.AGGRESSIVE
     or bx.behavior == Behavior.WATER_AGGRESSIVE then
    return tickAggressive(entity, ctx, bx, t)
  end

  return nil
end

function Behavior.isWater(behavior)
  return behavior == Behavior.WATER_IDLE
      or behavior == Behavior.WATER_WANDER
      or behavior == Behavior.WATER_AGGRESSIVE
end

function Behavior.isAggressive(behavior)
  return behavior == Behavior.AGGRESSIVE
      or behavior == Behavior.WATER_AGGRESSIVE
end

function Behavior.attach(entity, behavior, region, rng)
  entity.behavior = behavior
  entity.behaviorState = Behavior.initState(behavior, rng)
  entity.homeRegion = region
  entity.homeRegionId = region and region.id or nil
  entity.facing = entity.behaviorState.facing
  entity.visibleSprite = not Behavior.isHidden(behavior)
  entity.grassEffectActive = false
  entity.canTriggerBattle = not Behavior.isHidden(behavior)
  entity.hiddenBody = false
  if Behavior.isHidden(behavior) then
    entity.passable = true
    entity.hiddenEncounter = true
  end
  if Behavior.isWater(behavior) then
    entity.surface = Surface.WATER
    entity.spriteState = entity.spriteState or "water"
    entity.surfaceVisualOffset = 2
    entity.waterSink = 2
    -- Swap to water sprites once when behaviour attaches (preserves entity id).
    if entity.render and entity.render.applyProviderSprite
       and not entity.hiddenEncounter and entity.visibleSprite ~= false then
      local game = entity.mod and entity.mod.world and entity.mod.world.game
      pcall(entity.render.applyProviderSprite, entity.render, entity, game)
    end
  elseif entity.surface == Surface.WATER then
    -- Leaving water behaviour: clear water visual offsets; sprite refresh
    -- happens when surface is updated by the caller.
    entity.surfaceVisualOffset = nil
    entity.waterSink = 0
  end
  if entity.cellX and entity.cellY then
    Movement.init(entity, entity.cellX, entity.cellY, entity.facing)
  end
end

function Behavior.markChaseReady(entity)
  local bx = entity and entity.behaviorState
  if not bx then return end
  if bx.battleStarted or bx.battlePending then return end
  -- Safari flee alerts must never arm chase.
  if Behavior.isSafariFlee(bx.behavior) or Behavior.isSafari(bx.behavior) then
    return Behavior.markFleeReady(entity)
  end
  bx.chaseReady = true
  if bx.state == Behavior.STATE.ALERT
     or bx.state == Behavior.STATE.PLAYER_DETECTED then
    bx.state = Behavior.STATE.CHASE_START
  end
  bx.chasing = true
  bx.leftHome = true
  bx.sightDisabled = true
end

-- Arm overworld Safari flee after the shared emote bubble finishes.
function Behavior.markFleeReady(entity)
  local bx = entity and entity.behaviorState
  if not bx then return end
  if bx.battleStarted or bx.battlePending then return end
  local sf = ensureSafariFlee(bx)
  sf.active = true
  sf.noticedPlayer = true
  sf.alertStarted = true
  bx.fleeReady = true
  bx.chaseReady = false
  bx.chasing = false
  bx.sightDisabled = true
  if bx.state == Behavior.STATE.ALERT
     or bx.state == Behavior.STATE.PLAYER_NOTICED
     or bx.state == Behavior.STATE.PLAYER_DETECTED then
    bx.state = Behavior.STATE.FLEE_START
  end
end

return Behavior
