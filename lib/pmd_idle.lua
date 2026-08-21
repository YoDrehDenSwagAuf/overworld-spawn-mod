-- Presentation-only occasional Idle animation for PMDCollab overworld sprites.
-- Does NOT drive AI, pathfinding, occupancy, or movement timing.
local V = ...

local PmdIdle = {}

PmdIdle.DELAY_MIN = 3.0
PmdIdle.DELAY_MAX = 8.0
PmdIdle.PLAY_CHANCE = 0.65
-- Upstream AnimData durations are engine ticks at 60 Hz.
PmdIdle.TICK_HZ = 60

local IDLE_DIRS = { "down", "up", "left", "right" }
local DIR_INDEX = { down = 0, up = 1, left = 2, right = 3 }

local function rng01(rng)
  if type(rng) == "function" then
    local v = rng()
    if type(v) == "number" then
      if v < 0 then return 0 end
      if v > 1 then return 1 end
      return v
    end
  end
  return math.random()
end

local function facingKey(facing)
  if facing == "right" or facing == "left"
     or facing == "up" or facing == "down" then
    return facing
  end
  return "down"
end

function PmdIdle.idleFrameBase(idleFrameCount, facing)
  idleFrameCount = tonumber(idleFrameCount) or 0
  if idleFrameCount <= 0 then return nil end
  local idx = DIR_INDEX[facingKey(facing)] or 0
  return 6 + idx * idleFrameCount
end

function PmdIdle.schedule(entity, rng)
  if not entity then return end
  local state = entity._pmdIdle
  if type(state) ~= "table" then
    state = {}
    entity._pmdIdle = state
  end
  local span = PmdIdle.DELAY_MAX - PmdIdle.DELAY_MIN
  state.delay = PmdIdle.DELAY_MIN + rng01(rng) * span
  state.elapsed = 0
  state.playing = false
  state.frame = 0
  state.frameElapsed = 0
  state.facing = nil
end

function PmdIdle.reset(entity)
  if not entity then return end
  entity._pmdIdle = nil
end

local function fxBusy(entity)
  if entity._presentationIntent ~= nil then return true end
  if entity._wildsPresentationFx == true then return true end
  if entity.wildsRecallFx == true or entity.wildsReleaseFx == true then return true end
  return false
end

function PmdIdle.isEligible(entity)
  if not entity then return false end
  if entity.hidden == true or entity.hiddenEncounter == true then return false end
  if entity.visibleSprite == false then return false end
  -- Town/follower talk freezes the NPC — do not idle during interaction.
  if entity.frozen == true then return false end
  if entity.talking == true or entity._inTalk == true then return false end
  if fxBusy(entity) then return false end
  if entity.spriteState == "water" then return false end
  if entity._waterTransition == true then return false end

  local okM, Movement = pcall(function() return V.require("movement") end)
  if okM and Movement and type(Movement.isBusy) == "function" then
    local okBusy, busy = pcall(Movement.isBusy, entity)
    if okBusy and busy then
      return false
    end
  end
  if entity.moving == true or entity.marching == true then return false end
  if entity.isMoving == true then return false end

  local mov = entity.movement
  if type(mov) == "table" then
    local st = mov.state
    if st == "MOVING" or st == "CHASING" or st == "BATTLE_PENDING" or st == "ALERT" then
      return false
    end
  end
  if entity.behavior == "CHASE" or entity.behavior == "AGGRESSIVE_CHASE" then
    if entity.chasing == true then return false end
  end
  return true
end

function PmdIdle.frameOverride(entity)
  local state = entity and entity._pmdIdle
  if not (state and state.playing) then return nil end
  local base = state.base
  local frame = tonumber(state.frame) or 0
  if base == nil then return nil end
  return base + frame
end

function PmdIdle.attachDrawWrap(sprite, entity)
  if type(sprite) ~= "table" or type(sprite.draw) ~= "function" then
    return false
  end
  if sprite._pmdIdleWrapped then
    sprite._pmdIdleEntity = entity
    return true
  end
  local orig = sprite.draw
  sprite._pmdIdleOrigDraw = orig
  sprite._pmdIdleEntity = entity
  sprite._pmdIdleWrapped = true
  function sprite:draw(px, py, camX, camY, facing, walkPhase, stepFlip, topHalf, forceFlip, frameOverride)
    local ent = self._pmdIdleEntity or entity
    local override = PmdIdle.frameOverride(ent)
    if override == nil then
      local okW, PmdWalk = pcall(function() return V.require("pmd_walk") end)
      if okW and PmdWalk and PmdWalk.frameOverride then
        override = PmdWalk.frameOverride(ent)
      end
    end
    if override ~= nil then
      -- Dedicated directional frames (including real right) — never mirror.
      return orig(self, px, py, camX, camY, facing, walkPhase, stepFlip, topHalf, false, override)
    end
    return orig(self, px, py, camX, camY, facing, walkPhase, stepFlip, topHalf, forceFlip, frameOverride)
  end
  return true
end

local function idleDurations(entity)
  local meta = entity and entity._pmdIdleMeta
  if type(meta) == "table" and type(meta.idleDurations) == "table" then
    return meta.idleDurations, tonumber(meta.idleFrameCount) or 0
  end
  local def = entity and entity.sprite and entity.sprite.def
  if type(def) == "table" and type(def.idleDurations) == "table" then
    return def.idleDurations, tonumber(def.idleFrameCount) or 0
  end
  return nil, 0
end

function PmdIdle.update(entity, dt, rng)
  if not entity then return end
  dt = tonumber(dt) or 0
  if dt < 0 then dt = 0 end

  local count
  local durs
  durs, count = idleDurations(entity)
  if not count or count <= 0 then
    return
  end

  if not PmdIdle.isEligible(entity) then
    if entity._pmdIdle and entity._pmdIdle.playing then
      entity._pmdIdle.playing = false
      entity._pmdIdle.frame = 0
    end
    -- Keep delay clock paused while busy so we don't sync-burst after movement.
    return
  end

  if type(entity._pmdIdle) ~= "table" then
    PmdIdle.schedule(entity, rng)
  end
  local state = entity._pmdIdle

  if state.playing then
    state.frameElapsed = (state.frameElapsed or 0) + dt
    local durTicks = 4
    if type(durs) == "table" then
      durTicks = tonumber(durs[(state.frame or 0) + 1]) or durTicks
    end
    local durSec = durTicks / PmdIdle.TICK_HZ
    if durSec < 1 / 60 then durSec = 1 / 60 end
    if state.frameElapsed >= durSec then
      state.frameElapsed = state.frameElapsed - durSec
      state.frame = (state.frame or 0) + 1
      if state.frame >= count then
        state.playing = false
        state.frame = 0
        PmdIdle.schedule(entity, rng)
      end
    end
    return
  end

  state.elapsed = (state.elapsed or 0) + dt
  local delay = tonumber(state.delay) or PmdIdle.DELAY_MIN
  if state.elapsed < delay then
    return
  end
  -- Chance gate so not every Pokémon animates on every timer fire.
  if rng01(rng) > PmdIdle.PLAY_CHANCE then
    PmdIdle.schedule(entity, rng)
    return
  end
  local facing = facingKey(entity.facing or "down")
  local base = PmdIdle.idleFrameBase(count, facing)
  if base == nil then
    PmdIdle.schedule(entity, rng)
    return
  end
  state.playing = true
  state.frame = 0
  state.frameElapsed = 0
  state.facing = facing
  state.base = base
end

return PmdIdle
