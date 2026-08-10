-- Temporary Poké Ball projectile + wobble on the target tile.
-- Uses native SpriteRenderer-compatible entities (Flat 2D + Voxel pose path).
--
-- Lifecycle contract: every Ball entity created here MUST be removed via
-- Projectile:cleanup() (idempotent). Flight update clears `active` only after
-- stashing the Ball so miss/hit/cancel paths cannot orphan it.
local V = ...
local Tile = V.require("tile")
local CatchMath = V.require("catching/catch_math")

local Projectile = {}
Projectile.__index = Projectile

local CELL = Tile.CELL or 16
local WOBBLE_INTERVAL = 0.55
local RESOLVE_HOLD = 0.35
local MISS_LAND_HOLD = 0.18

local function tryRequire(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil
end

local function playSfx(game, name)
  pcall(function()
    if game and game.audio and game.audio.playSfx then
      game.audio:playSfx(name)
    end
  end)
end

local function removeEntityFromOw(ow, entity)
  if not ow or not entity then return end
  for _, listName in ipairs({ "entities", "npcs" }) do
    local list = ow[listName]
    if list then
      for i = #list, 1, -1 do
        if list[i] == entity then table.remove(list, i) end
      end
    end
  end
  entity.registeredInWorld = false
end

local function makeBallEntity(game, ow, ballType, cellX, cellY, spriteId)
  local data = game and game.data
  local NPC = tryRequire("src.world.NPC")
  local entity
  if NPC and NPC.new and data then
    local ok, created = pcall(NPC.new, data, ow and ow.map and ow.map.id or 1, {
      index = 480 + math.random(1, 40),
      name = "WILDS_BALL_" .. tostring(ballType),
      sprite = spriteId,
      movement = "NONE",
      x = cellX,
      y = cellY,
    })
    if ok then entity = created end
  end
  if not entity then
    entity = {
      cellX = cellX,
      cellY = cellY,
      px = cellX * CELL,
      py = cellY * CELL,
      facing = "down",
      sprite = spriteId,
      movement = "NONE",
      passable = true,
    }
    function entity:pose()
      return self.sprite, self.px, self.py, self.facing or "down", 0, false
    end
  end
  entity.isPokeBallEntity = true
  entity.wildsProjectile = true
  entity.passable = true
  entity.blocking = false
  entity.wildsCatchProjectile = true
  -- Lightweight draw for flat 2D if SpriteRenderer pose path is absent.
  if type(entity.draw) ~= "function" then
    function entity:draw()
      -- Engine NPC draw path preferred; no-op fallback.
    end
  end
  return entity
end

--- Axis-aligned land cell from player toward facing for `tiles` steps.
function Projectile.landCell(startX, startY, facing, tiles)
  tiles = math.max(1, math.min(CatchMath.MAX_RANGE, math.floor((tonumber(tiles) or 1) + 0.5)))
  local dx, dy = 0, 0
  if facing == "up" then dy = -1
  elseif facing == "down" then dy = 1
  elseif facing == "left" then dx = -1
  elseif facing == "right" then dx = 1
  end
  return startX + dx * tiles, startY + dy * tiles, tiles
end

function Projectile.new()
  local self = setmetatable({}, Projectile)
  self.active = nil
  self.wobble = nil
  self._trackedBall = nil -- authoritative Ball entity for cleanup
  self._missHold = nil
  return self
end

function Projectile:isBusy()
  return self.active ~= nil or self.wobble ~= nil or self._missHold ~= nil
end

--- Idempotent removal from ow.entities/npcs + voxel + internal state.
function Projectile:cleanup(ow, voxel, ballEntity)
  local victims = {}
  local function track(e)
    if e then victims[#victims + 1] = e end
  end
  track(ballEntity)
  track(self._trackedBall)
  if self.active then track(self.active.ballEntity) end
  if self.wobble then track(self.wobble.ballEntity) end
  if self._missHold then track(self._missHold.ballEntity) end

  local seen = {}
  for _, e in ipairs(victims) do
    if not seen[e] then
      seen[e] = true
      removeEntityFromOw(ow, e)
      if voxel and voxel.unregister then
        pcall(voxel.unregister, voxel, e)
      end
    end
  end

  self.active = nil
  self.wobble = nil
  self._missHold = nil
  self._trackedBall = nil
end

-- Back-compat alias used by older call sites.
function Projectile:cancel(ow, voxel)
  self:cleanup(ow, voxel)
end

function Projectile:startFlight(game, ow, opts)
  opts = opts or {}
  if self:isBusy() then
    self:cleanup(ow, opts.voxel)
  end
  local ballType = opts.ballType or "POKE_BALL"
  local spriteId = opts.spriteId or ("SPRITE_WILDS_BALL_" .. ballType)
  local startX = opts.startX
  local startY = opts.startY
  local facing = opts.facing or "down"
  local power = opts.power or opts.totalDist or 1
  local isMiss = opts.miss == true

  -- Projectile ALWAYS travels the selected power distance along facing.
  local endX, endY, travel = Projectile.landCell(startX, startY, facing, power)

  local ballEntity = makeBallEntity(game, ow, ballType, startX, startY, spriteId)
  if ow and ow.entities then
    table.insert(ow.entities, ballEntity)
  end
  self._trackedBall = ballEntity

  local speed = math.max(2.2, 4.2 / (travel * 0.45))
  self.active = {
    startX = startX,
    startY = startY,
    targetX = endX,
    targetY = endY,
    progress = 0,
    speed = speed,
    ballType = ballType,
    ballEntity = ballEntity,
    totalDist = travel,
    facing = facing,
    power = power,
    miss = isMiss,
    onImpact = opts.onImpact,
    meta = opts.meta,
  }
  playSfx(game, "SFX_BALL_TOSS")
  return true, endX, endY, travel
end

function Projectile:beginWobble(game, ow, opts)
  opts = opts or {}
  local ballEntity = opts.ballEntity or self._trackedBall
  self._trackedBall = ballEntity
  self.wobble = {
    x = opts.x,
    y = opts.y,
    ballEntity = ballEntity,
    caught = opts.caught == true,
    totalShakes = math.max(0, tonumber(opts.totalShakes) or 0),
    currentShake = 0,
    timer = 0,
    phase = "WOBBLE",
    onResolve = opts.onResolve,
    game = game,
    ow = ow,
  }
  if ballEntity then
    ballEntity.cellX = opts.x
    ballEntity.cellY = opts.y
    ballEntity.px = opts.x * CELL
    ballEntity.py = opts.y * CELL
  end
end

function Projectile:update(game, ow, dt, voxel)
  dt = dt or 0.016

  if self._missHold then
    self._missHold.timer = self._missHold.timer + dt
    if self._missHold.timer >= MISS_LAND_HOLD then
      local cb = self._missHold.onDone
      local ball = self._missHold.ballEntity
      self._missHold = nil
      self:cleanup(ow, voxel, ball)
      if cb then cb() end
    end
    return
  end

  if self.active then
    local proj = self.active
    proj.progress = proj.progress + proj.speed * dt
    local p = math.min(1, proj.progress)
    local curX = proj.startX + (proj.targetX - proj.startX) * p
    local curY = proj.startY + (proj.targetY - proj.startY) * p
    local arcHeight = 14 + math.min(16, proj.totalDist * 3)
    local arcY = math.sin(p * math.pi) * arcHeight

    if proj.ballEntity then
      proj.ballEntity.cellX = math.floor(curX + 0.5)
      proj.ballEntity.cellY = math.floor(curY + 0.5)
      proj.ballEntity.px = curX * CELL
      proj.ballEntity.py = (curY * CELL) - arcY
    end

    if proj.progress >= 1.0 then
      local finished = proj
      -- Keep Ball tracked; do NOT drop the entity reference when clearing active.
      self._trackedBall = finished.ballEntity
      self.active = nil
      if finished.miss then
        -- Brief land pause, then guaranteed cleanup.
        self._missHold = {
          timer = 0,
          ballEntity = finished.ballEntity,
          onDone = function()
            if finished.onImpact then finished.onImpact(finished) end
          end,
        }
      else
        if finished.onImpact then
          finished.onImpact(finished)
        end
      end
    end
  end

  if self.wobble then
    local wob = self.wobble
    wob.timer = wob.timer + dt
    local ballEntity = wob.ballEntity

    if wob.phase == "WOBBLE" then
      if wob.totalShakes <= 0 then
        wob.phase = "RESOLVE"
        wob.timer = 0
      elseif wob.timer >= WOBBLE_INTERVAL then
        wob.timer = 0
        wob.currentShake = wob.currentShake + 1
        playSfx(game, "SFX_BALL_POOF")
        if wob.currentShake >= wob.totalShakes then
          wob.phase = "RESOLVE"
          wob.timer = 0
        end
      else
        local nudgeX = math.sin(wob.timer * 22) * 2.5
        if ballEntity then
          ballEntity.px = wob.x * CELL + nudgeX
          ballEntity.py = wob.y * CELL
        end
      end
    elseif wob.phase == "RESOLVE" then
      if wob.timer >= RESOLVE_HOLD then
        local done = wob
        local ball = done.ballEntity
        self.wobble = nil
        -- Resolve callback may start success/fail logic; Ball removed after.
        if done.onResolve then
          done.onResolve(done)
        end
        self:cleanup(ow, voxel, ball)
      end
    end
  end
end

return Projectile
