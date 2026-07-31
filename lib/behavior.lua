-- Behaviour types and per-entity state machines for overworld wild Pokemon.
-- Selection is weighted (optionally species / surface aware). Never uses Pokédex.
local V = ...
local Config = V.require("config")
local Surface = V.require("surface")
local SpawnRegions = V.require("spawn_regions")
local Movement = V.require("movement")

local Behavior = {}

Behavior.IDLE_LOOK = "IDLE_LOOK"
Behavior.GRASS_WANDER = "GRASS_WANDER"
Behavior.AGGRESSIVE = "AGGRESSIVE"
Behavior.HIDDEN_GRASS = "HIDDEN_GRASS"
Behavior.HIDDEN_CAVE = "HIDDEN_CAVE"

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
}

local FACINGS = { "down", "up", "left", "right" }

local DEFAULT_WEIGHTS = {
  [Behavior.IDLE_LOOK] = 30,
  [Behavior.GRASS_WANDER] = 35,
  [Behavior.AGGRESSIVE] = 15,
  [Behavior.HIDDEN_GRASS] = 20,
  [Behavior.HIDDEN_CAVE] = 20,
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
  MAGIKARP = { IDLE_LOOK = 1.6, GRASS_WANDER = 0.6, AGGRESSIVE = 0.1 },
  TENTACOOL = { GRASS_WANDER = 1.3, AGGRESSIVE = 1.2 },
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
  elseif surface == Surface.WATER then
    weights[Behavior.HIDDEN_GRASS] = 0
    weights[Behavior.HIDDEN_CAVE] = 0
    weights[Behavior.AGGRESSIVE] = weights[Behavior.AGGRESSIVE] * 0.5
  else
    weights[Behavior.HIDDEN_CAVE] = 0
  end

  if opts.enable_idle == false then weights[Behavior.IDLE_LOOK] = 0 end
  if opts.enable_wander == false then weights[Behavior.GRASS_WANDER] = 0 end
  if opts.enable_aggressive == false then weights[Behavior.AGGRESSIVE] = 0 end
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

  local allowedSet = {}
  for _, b in ipairs(allowed) do allowedSet[b] = true end
  for b in pairs(weights) do
    if not allowedSet[b] then weights[b] = 0 end
  end

  return weights
end

function Behavior.pick(species, surface, opts, rng)
  rng = rngOf(rng)
  local weights = Behavior.weightsFor(species, surface, opts)
  local total = 0
  local order = {
    Behavior.IDLE_LOOK, Behavior.GRASS_WANDER, Behavior.AGGRESSIVE,
    Behavior.HIDDEN_GRASS, Behavior.HIDDEN_CAVE,
  }
  for _, b in ipairs(order) do
    total = total + (weights[b] or 0)
  end
  if total <= 0 then
    return Behavior.IDLE_LOOK
  end
  local roll = rng() * total
  if type(roll) ~= "number" then roll = (rng(10000) / 10000) * total end
  local acc = 0
  for _, b in ipairs(order) do
    acc = acc + (weights[b] or 0)
    if roll <= acc then return b end
  end
  return Behavior.IDLE_LOOK
end

function Behavior.isHidden(behavior)
  return behavior == Behavior.HIDDEN_GRASS or behavior == Behavior.HIDDEN_CAVE
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
    shakeNextAt = now() + (2.0 + rng() * 3.0),
    leftHome = false,
    battleStarted = false,
    battlePending = false,
    sightDisabled = false,
  }
  return st
end

local function occupiedBlocked(entities, x, y, ignore)
  for _, e in ipairs(entities or {}) do
    if e ~= ignore then
      local same = (e.cellX == x and e.cellY == y)
                or (e.targetX == x and e.targetY == y)
      if same then
        if e.overworldWildSpawn then return true, "pokemon" end
        if not e.passable then return true, "npc" end
      end
    end
  end
  return false
end

local function canStep(map, entities, entity, player, nx, ny, region, allowLeaveHome)
  if not map then return false end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  if nx < 0 or ny < 0 or nx >= w or ny >= h then return false end
  if map.inBounds and not map:inBounds(nx, ny) then return false end
  if map.warpAtCell and map:warpAtCell(nx, ny) then return false end
  if player and player.cellX == nx and player.cellY == ny then
    return false, "player"
  end
  local blocked = occupiedBlocked(entities, nx, ny, entity)
  if blocked then return false, "occupied" end

  if allowLeaveHome then
    if map.isWalkableCell and not map:isWalkableCell(nx, ny) then
      if entity.surface == Surface.WATER then
        if not (map.isWaterCell and map:isWaterCell(nx, ny)) then return false end
      else
        return false
      end
    end
    return true
  end

  if region and not SpawnRegions.contains(region, nx, ny) then
    return false, "outside_region"
  end
  if entity.surface == Surface.WATER then
    if not (map.isWaterCell and map:isWaterCell(nx, ny)) then return false end
  elseif entity.surface == Surface.GRASS then
    if not (map.isGrassCell and map:isGrassCell(nx, ny)) then return false end
    if map.isWalkableCell and not map:isWalkableCell(nx, ny) then return false end
  else
    if map.isWalkableCell and not map:isWalkableCell(nx, ny) then return false end
  end
  return true
end

local function lineOfSight(map, entities, x0, y0, x1, y1)
  if x0 ~= x1 and y0 ~= y1 then return false end
  local dx = x1 > x0 and 1 or x1 < x0 and -1 or 0
  local dy = y1 > y0 and 1 or y1 < y0 and -1 or 0
  local x, y = x0 + dx, y0 + dy
  while x ~= x1 or y ~= y1 do
    if map.isWalkableCell and not map:isWalkableCell(x, y) then
      return false
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

function Behavior.playerInSight(entity, player, map, entities, range)
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
  return lineOfSight(map, entities, ex, ey, px, py)
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

local function stepToward(entity, map, entities, player, tx, ty, region, allowLeave, chase)
  if Movement.isBusy(entity) then return false, "busy" end
  local ex, ey = entity.cellX, entity.cellY
  if ex == tx and ey == ty then return false, "arrived" end
  local options = {}
  if math.abs(tx - ex) >= math.abs(ty - ey) then
    if tx ~= ex then options[#options + 1] = { tx > ex and 1 or -1, 0 } end
    if ty ~= ey then options[#options + 1] = { 0, ty > ey and 1 or -1 } end
  else
    if ty ~= ey then options[#options + 1] = { 0, ty > ey and 1 or -1 } end
    if tx ~= ex then options[#options + 1] = { tx > ex and 1 or -1, 0 } end
  end
  for _, d in ipairs(options) do
    local nx, ny = ex + d[1], ey + d[2]
    local ok, reason = canStep(map, entities, entity, player, nx, ny, region, allowLeave)
    if ok then
      local facing
      if d[1] > 0 then facing = "right"
      elseif d[1] < 0 then facing = "left"
      elseif d[2] > 0 then facing = "down"
      else facing = "up" end
      local started = Movement.beginStep(entity, nx, ny, {
        facing = facing,
        chase = chase == true,
        duration = chase and (Config.DEFAULTS.aggressive_step_seconds or 0.18)
                   or (Config.DEFAULTS.wild_step_seconds or 0.28),
      })
      if started then return true end
    elseif reason == "player" then
      return false, "contact"
    end
  end
  return false, "blocked"
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

local function tickAggressive(entity, ctx, bx, t)
  local map = ctx.map
  local entities = ctx.entities
  local player = ctx.player
  local region = entity.homeRegion
  local range = ctx.sightRange or Config.DEFAULTS.aggressive_sight_range or 4

  if bx.state == Behavior.STATE.BATTLE_PENDING
     or bx.state == Behavior.STATE.IN_BATTLE
     or bx.state == Behavior.STATE.CLEANUP
     or bx.battlePending or bx.battleStarted then
    Movement.stop(entity, Movement.STATE.BATTLE_PENDING)
    bx.sightDisabled = true
    return bx.battleStarted and nil or "battle_pending"
  end

  -- Advance in-progress chase/wander steps first (central movement).
  if Movement.isBusy(entity) then
    local completed = Movement.update(entity, ctx.dt or 0.016)
    if completed then
      Movement.refreshGrassFlag(entity, entity.mod)
    end
    if bx.state == Behavior.STATE.CHASING or bx.chasing then
      if contactWithPlayer(entity, player) then
        bx.state = Behavior.STATE.BATTLE_PENDING
        bx.battlePending = true
        bx.sightDisabled = true
        Movement.stop(entity, Movement.STATE.BATTLE_PENDING)
        return "contact"
      end
    end
    return nil
  end

  if bx.state == Behavior.STATE.CHASING or bx.chasing then
    bx.chasing = true
    bx.state = Behavior.STATE.CHASING
    bx.leftHome = true
    bx.sightDisabled = true
    if entity.movement then entity.movement.state = Movement.STATE.CHASING end
    if not player then return nil end
    if contactWithPlayer(entity, player) then
      bx.state = Behavior.STATE.BATTLE_PENDING
      bx.battlePending = true
      Movement.stop(entity, Movement.STATE.BATTLE_PENDING)
      return "contact"
    end
    local moved, why = stepToward(
      entity, map, entities, player,
      player.cellX, player.cellY, region, true, true)
    if why == "contact" then
      bx.state = Behavior.STATE.BATTLE_PENDING
      bx.battlePending = true
      Movement.stop(entity, Movement.STATE.BATTLE_PENDING)
      return "contact"
    end
    if not moved then
      bx.chaseFailCount = (bx.chaseFailCount or 0) + 1
      if bx.chaseFailCount > 24 then
        bx.chasing = false
        bx.playerDetected = false
        bx.chaseReady = false
        bx.sightDisabled = false
        bx.state = Behavior.STATE.IDLE
        bx.chaseFailCount = 0
        bx.nextActionAt = t + 2.0
        Movement.stop(entity, Movement.STATE.IDLE)
      end
    else
      bx.chaseFailCount = 0
      Movement.refreshGrassFlag(entity, entity.mod)
    end
    return nil
  end

  if bx.state == Behavior.STATE.CHASE_START then
    bx.chasing = true
    bx.leftHome = true
    bx.sightDisabled = true
    bx.state = Behavior.STATE.CHASING
    if entity.movement then entity.movement.state = Movement.STATE.CHASING end
    return "chase_start"
  end

  if bx.state == Behavior.STATE.ALERT or bx.state == Behavior.STATE.PLAYER_DETECTED then
    -- Hold still for the engine emotion bubble. Chase begins only when
    -- chaseReady is set (emote onDone) — never from a parallel timer.
    Movement.stop(entity, Movement.STATE.ALERT)
    bx.sightDisabled = true
    bx.state = Behavior.STATE.ALERT
    if entity.movement then entity.movement.state = Movement.STATE.ALERT end
    if bx.chaseReady then
      bx.state = Behavior.STATE.CHASE_START
      bx.alertEmoteSpawned = true
      return nil
    end
    return nil
  end

  -- Idle / look while waiting; still scan sight.
  if Movement.isBusy(entity) then
    Movement.update(entity, ctx.dt or 0.016)
    return nil
  end

  if t >= (bx.nextActionAt or 0) and not bx.playerDetected then
    tryFace(entity, ctx.rng)
  end

  if Behavior.playerInSight(entity, player, map, entities, range) then
    -- PLAYER_DETECTED → ALERT once.
    bx.playerDetected = true
    bx.sightDisabled = true
    bx.alertEmoteSpawned = false
    bx.chaseReady = false
    bx.state = Behavior.STATE.PLAYER_DETECTED
    Movement.stop(entity, Movement.STATE.ALERT)
    bx.state = Behavior.STATE.ALERT
    return "alert"
  end
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

  if bx.behavior == Behavior.IDLE_LOOK then
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

  if bx.behavior == Behavior.GRASS_WANDER then
    if Movement.isBusy(entity) then
      local done = Movement.update(entity, ctx.dt or 0.016)
      if done then
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
    for _, d in ipairs(dirs) do
      local nx, ny = entity.cellX + d[1], entity.cellY + d[2]
      if canStep(map, entities, entity, player, nx, ny, region, false) then
        if Movement.beginStep(entity, nx, ny, { facing = d[3] }) then
          bx.state = Behavior.STATE.MOVING
          bx.nextActionAt = t + (0.55 + rng() * 1.2)
          return nil
        end
      end
    end
    bx.nextActionAt = t + (0.8 + rng() * 1.5)
    bx.state = Behavior.STATE.PAUSED
    return nil
  end

  if bx.behavior == Behavior.AGGRESSIVE then
    return tickAggressive(entity, ctx, bx, t)
  end

  return nil
end

function Behavior.attach(entity, behavior, region, rng)
  entity.behavior = behavior
  entity.behaviorState = Behavior.initState(behavior, rng)
  entity.homeRegion = region
  entity.homeRegionId = region and region.id or nil
  entity.facing = entity.behaviorState.facing
  entity.visibleSprite = not Behavior.isHidden(behavior)
  entity.grassEffectActive = false
  if Behavior.isHidden(behavior) then
    entity.passable = true
    entity.hiddenEncounter = true
  end
  if entity.cellX and entity.cellY then
    Movement.init(entity, entity.cellX, entity.cellY, entity.facing)
  end
end

function Behavior.markChaseReady(entity)
  local bx = entity and entity.behaviorState
  if not bx then return end
  if bx.battleStarted or bx.battlePending then return end
  bx.chaseReady = true
  if bx.state == Behavior.STATE.ALERT
     or bx.state == Behavior.STATE.PLAYER_DETECTED then
    bx.state = Behavior.STATE.CHASE_START
  end
  bx.chasing = true
  bx.leftHome = true
  bx.sightDisabled = true
end

return Behavior
