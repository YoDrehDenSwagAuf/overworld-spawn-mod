-- Presentation-only Walk cycle for PMDCollab overworld sprites.
-- Uses imported full Walk frames + durations via frameOverride.
-- Does NOT drive AI, pathfinding, occupancy, or movement timing.
local V = ...

local PmdWalk = {}

-- Upstream AnimData durations are engine ticks at 60 Hz.
PmdWalk.TICK_HZ = 60

local DIR_INDEX = { down = 0, up = 1, left = 2, right = 3 }

local function facingKey(facing)
  if facing == "right" or facing == "left"
     or facing == "up" or facing == "down" then
    return facing
  end
  return "down"
end

local function walkMeta(entity)
  local meta = entity and entity._pmdWalkMeta
  if type(meta) == "table" then return meta end
  local def = entity and entity.sprite and entity.sprite.def
  if type(def) == "table" and tonumber(def.walkFrameCount) then
    return def
  end
  return nil
end

local function isMoving(entity)
  if not entity then return false end
  if entity.moving == true or entity.marching == true or entity.isMoving == true then
    return true
  end
  local okM, Movement = pcall(function() return V.require("movement") end)
  if okM and Movement and type(Movement.isBusy) == "function" then
    local okBusy, busy = pcall(Movement.isBusy, entity)
    if okBusy and busy then return true end
  end
  local mov = entity.movement
  if type(mov) == "table" then
    local st = mov.state
    if st == "MOVING" or st == "CHASING" then return true end
  end
  return false
end

function PmdWalk.walkFrameBase(walkCycleBase, walkFrameCount, facing)
  walkCycleBase = tonumber(walkCycleBase)
  walkFrameCount = tonumber(walkFrameCount) or 0
  if not walkCycleBase or walkFrameCount <= 0 then return nil end
  local idx = DIR_INDEX[facingKey(facing)] or 0
  return walkCycleBase + idx * walkFrameCount
end

--- Absolute sheet frame while standing/moving, or nil if unavailable.
--- Yields nil while Idle is playing so PmdIdle owns the override.
function PmdWalk.frameOverride(entity)
  if not entity then return nil end
  if entity._pmdIdle and entity._pmdIdle.playing then
    return nil
  end
  local meta = walkMeta(entity)
  if not meta then return nil end
  local n = tonumber(meta.walkFrameCount) or 0
  local base = tonumber(meta.walkCycleBase)
  if n <= 0 or base == nil then return nil end

  local facing = facingKey(entity.facing or "down")
  local frameBase = PmdWalk.walkFrameBase(base, n, facing)
  if frameBase == nil then return nil end

  if isMoving(entity) then
    local state = entity._pmdWalk
    local fi = 0
    if type(state) == "table" then
      fi = tonumber(state.frame) or 0
    end
    if fi < 0 then fi = 0 end
    if fi >= n then fi = fi % n end
    return frameBase + fi
  end
  -- Standing: Walk anim frame 0 (includes real right-facing art).
  return frameBase + 0
end

function PmdWalk.update(entity, dt)
  if not entity then return end
  dt = tonumber(dt) or 0
  if dt < 0 then dt = 0 end

  local meta = walkMeta(entity)
  if not meta then return end
  local n = tonumber(meta.walkFrameCount) or 0
  if n <= 0 then return end
  local durs = meta.walkDurations
  if type(durs) ~= "table" then durs = nil end

  if type(entity._pmdWalk) ~= "table" then
    entity._pmdWalk = { frame = 0, frameElapsed = 0, facing = nil }
  end
  local state = entity._pmdWalk
  local facing = facingKey(entity.facing or "down")
  if state.facing ~= facing then
    state.facing = facing
    state.frame = 0
    state.frameElapsed = 0
  end

  if not isMoving(entity) then
    state.frame = 0
    state.frameElapsed = 0
    return
  end

  if n <= 1 then
    state.frame = 0
    return
  end

  state.frameElapsed = (state.frameElapsed or 0) + dt
  local durTicks = 4
  if durs then
    durTicks = tonumber(durs[(state.frame or 0) + 1]) or durTicks
  end
  local durSec = durTicks / PmdWalk.TICK_HZ
  if durSec < 1 / 60 then durSec = 1 / 60 end
  while state.frameElapsed >= durSec do
    state.frameElapsed = state.frameElapsed - durSec
    state.frame = ((state.frame or 0) + 1) % n
    if durs then
      durTicks = tonumber(durs[state.frame + 1]) or 4
      durSec = durTicks / PmdWalk.TICK_HZ
      if durSec < 1 / 60 then durSec = 1 / 60 end
    end
  end
end

return PmdWalk
