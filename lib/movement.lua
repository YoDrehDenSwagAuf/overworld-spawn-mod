-- Central tile-step movement for wild overworld entities.
-- Matches Gen1Recomp NPC semantics:
--   * cellX/cellY stay at the origin until the step completes
--   * px/py interpolate from previous → target during the step
--   * Voxel / 2D renderers only READ these fields
-- Tile coordinates and pixel coordinates are never mixed.
local V = ...
local Tile = V.require("tile")
local Config = V.require("config")

local Movement = {}

Movement.STATE = {
  IDLE = "IDLE",
  ALERT = "ALERT",
  MOVING = "MOVING",
  CHASING = "CHASING",
  BATTLE_PENDING = "BATTLE_PENDING",
}

local FACING_DELTA = {
  up = { 0, -1 },
  down = { 0, 1 },
  left = { -1, 0 },
  right = { 1, 0 },
}

local function ensureTables(entity)
  if type(entity.position) ~= "table" then
    local px = entity.px
    local py = entity.py
    if px == nil or py == nil then
      px, py = Tile.pixelsForCell(entity.cellX or 0, entity.cellY or 0)
    end
    entity.position = {
      tileX = entity.cellX or 0,
      tileY = entity.cellY or 0,
      previousTileX = entity.cellX or 0,
      previousTileY = entity.cellY or 0,
      pixelX = px,
      pixelY = py,
      previousPixelX = px,
      previousPixelY = py,
    }
  end
  if type(entity.movement) ~= "table" then
    entity.movement = {
      state = Movement.STATE.IDLE,
      facing = entity.facing or "down",
      progress = 0,
      duration = Config.DEFAULTS.wild_step_seconds or 0.28,
      targetTileX = nil,
      targetTileY = nil,
    }
  end
  if entity.stepFlip == nil then
    entity.stepFlip = false
  end
end

function Movement.syncLegacyFields(entity)
  ensureTables(entity)
  local p = entity.position
  local m = entity.movement
  entity.cellX = p.tileX
  entity.cellY = p.tileY
  entity.px = p.pixelX
  entity.py = p.pixelY
  entity.facing = m.facing or entity.facing or "down"
  if m.targetTileX ~= nil then
    entity.targetX, entity.targetY = m.targetTileX, m.targetTileY
    entity.moving = (m.state == Movement.STATE.MOVING
                     or m.state == Movement.STATE.CHASING)
                   and m.progress < (m.duration or 0)
  else
    entity.targetX, entity.targetY = nil, nil
    entity.moving = false
  end
  entity.moveProgress = m.progress or 0
  -- NPC-compatible aliases used by pose() / SpriteRenderer.
  entity.walkFlip = entity.stepFlip == true
  entity.flip = entity.stepFlip == true
  entity.phase = Movement.walkPhase(entity)
  entity.hopping = false
end

function Movement.init(entity, tileX, tileY, facing)
  local px, py = Tile.pixelsForCell(tileX, tileY)
  entity.position = {
    tileX = tileX,
    tileY = tileY,
    previousTileX = tileX,
    previousTileY = tileY,
    pixelX = px,
    pixelY = py,
    previousPixelX = px,
    previousPixelY = py,
  }
  entity.movement = {
    state = Movement.STATE.IDLE,
    facing = facing or "down",
    progress = 0,
    duration = Config.DEFAULTS.wild_step_seconds or 0.28,
    targetTileX = nil,
    targetTileY = nil,
  }
  entity.stepFlip = false
  entity.walkFlip = false
  entity.flip = false
  entity.phase = 0
  entity.hopping = false
  Movement.syncLegacyFields(entity)
end

-- Match Gen1Recomp NPC:walkPhase — stand outside [4,12) of a 16-tick cycle.
function Movement.walkPhase(entity)
  if not entity then return 0 end
  if not Movement.isBusy(entity) then return 0 end
  local m = entity.movement
  if not m then return 0 end
  local dur = m.duration or 0.28
  if dur <= 0 then dur = 0.01 end
  local p = math.floor(((m.progress or 0) / dur) * 16) % 16
  return (p >= 4 and p < 12) and 1 or 0
end

function Movement.setFacing(entity, facing)
  ensureTables(entity)
  if FACING_DELTA[facing] then
    local prev = entity.movement.facing or entity.facing
    entity.movement.facing = facing
    entity.facing = facing
    if entity.behaviorState then
      entity.behaviorState.facing = facing
    end
    if prev ~= facing then
      entity.renderDirty = entity.renderDirty or {}
      entity.renderDirty.direction = true
      if entity.animation then
        entity.animation.directionChanged = true
      end
    end
  end
end

function Movement.isBusy(entity)
  ensureTables(entity)
  local m = entity.movement
  return m.targetTileX ~= nil and m.progress < (m.duration or 0)
end

-- Repair inconsistent movement: target without progress budget, or MOVING with no target.
function Movement.healBusy(entity)
  if not entity then return false end
  ensureTables(entity)
  local m = entity.movement
  if m.targetTileX == nil and m.targetTileY == nil then
    if m.state == Movement.STATE.MOVING then
      m.state = Movement.STATE.IDLE
      Movement.syncLegacyFields(entity)
      return true
    end
    return false
  end
  local dur = m.duration or 0
  if dur <= 0 or (m.progress or 0) >= dur then
    -- Force-complete a stuck step so Behaviour can plan the next one.
    local p = entity.position
    if m.targetTileX ~= nil and m.targetTileY ~= nil then
      p.tileX = m.targetTileX
      p.tileY = m.targetTileY
      local px, py = Tile.pixelsForCell(p.tileX, p.tileY)
      p.pixelX, p.pixelY = px, py
      p.previousTileX, p.previousTileY = p.tileX, p.tileY
      p.previousPixelX, p.previousPixelY = px, py
    end
    m.targetTileX, m.targetTileY = nil, nil
    m.progress = 0
    if m.state == Movement.STATE.MOVING then
      m.state = Movement.STATE.IDLE
    end
    Movement.syncLegacyFields(entity)
    return true
  end
  return false
end

-- Begin a one-tile step. Cell stays at origin until complete (NPC-compatible).
function Movement.beginStep(entity, toTileX, toTileY, opts)
  opts = opts or {}
  ensureTables(entity)
  if Movement.isBusy(entity) then
    return false, "busy"
  end
  local p = entity.position
  local m = entity.movement
  if toTileX == p.tileX and toTileY == p.tileY then
    return false, "same_tile"
  end

  local dx = toTileX - p.tileX
  local dy = toTileY - p.tileY
  if math.abs(dx) + math.abs(dy) ~= 1 then
    return false, "not_adjacent"
  end

  local facing = opts.facing
  if not facing then
    if dx > 0 then facing = "right"
    elseif dx < 0 then facing = "left"
    elseif dy > 0 then facing = "down"
    else facing = "up" end
  end

  p.previousTileX = p.tileX
  p.previousTileY = p.tileY
  p.previousPixelX = p.pixelX
  p.previousPixelY = p.pixelY

  m.targetTileX = toTileX
  m.targetTileY = toTileY
  m.facing = facing
  m.progress = 0
  m.duration = opts.duration
    or (opts.chase and (Config.DEFAULTS.aggressive_step_seconds or 0.18))
    or (Config.DEFAULTS.wild_step_seconds or 0.28)
  m.state = opts.chase and Movement.STATE.CHASING or Movement.STATE.MOVING

  entity.facing = facing
  if entity.behaviorState then
    entity.behaviorState.facing = facing
  end
  Movement.syncLegacyFields(entity)
  return true
end

-- Advance interpolation. Call once per entity per tick from world simulation.
function Movement.update(entity, dt)
  ensureTables(entity)
  local m = entity.movement
  local p = entity.position
  if m.targetTileX == nil then
    return false
  end

  local dur = m.duration or 0.28
  if dur <= 0 then dur = 0.01 end
  m.progress = (m.progress or 0) + (dt or 0)
  local t = m.progress / dur
  if t > 1 then t = 1 end

  local destPx, destPy = Tile.pixelsForCell(m.targetTileX, m.targetTileY)
  p.pixelX = p.previousPixelX + (destPx - p.previousPixelX) * t
  p.pixelY = p.previousPixelY + (destPy - p.previousPixelY) * t

  if t >= 1 then
    p.tileX = m.targetTileX
    p.tileY = m.targetTileY
    p.pixelX = destPx
    p.pixelY = destPy
    p.previousTileX = p.tileX
    p.previousTileY = p.tileY
    p.previousPixelX = p.pixelX
    p.previousPixelY = p.pixelY
    m.targetTileX, m.targetTileY = nil, nil
    m.progress = 0
    -- Same as NPC.lua: alternate walk-frame mirror after each completed step.
    entity.stepFlip = not entity.stepFlip
    if m.state == Movement.STATE.CHASING then
      -- Stay in CHASING until the behaviour machine says otherwise.
    elseif m.state == Movement.STATE.MOVING then
      m.state = Movement.STATE.IDLE
    end
    Movement.syncLegacyFields(entity)
    return true -- step completed
  end

  Movement.syncLegacyFields(entity)
  return false
end

function Movement.stop(entity, state)
  ensureTables(entity)
  local p = entity.position
  local m = entity.movement
  -- Snap to current tile (never leave a half-step as the committed cell).
  local px, py = Tile.pixelsForCell(p.tileX, p.tileY)
  p.pixelX, p.pixelY = px, py
  p.previousPixelX, p.previousPixelY = px, py
  p.previousTileX, p.previousTileY = p.tileX, p.tileY
  m.targetTileX, m.targetTileY = nil, nil
  m.progress = 0
  m.state = state or Movement.STATE.IDLE
  Movement.syncLegacyFields(entity)
  -- Caller / BehaviorTick owns CellOccupancy:cancelMove; mark for clarity.
  entity.movementReservationCancelled = true
end

function Movement.refreshGrassFlag(entity, mod)
  local world = mod and mod.world
  local ow = world and world.overworld and world:overworld()
  local GrassOcclusion = V.require("grass_occlusion")
  local map = ow and ow.map
  GrassOcclusion.refreshEntity(entity, mod, map)
end

return Movement
