-- Temporary Poké Ball projectile + wobble on the target tile.
-- Uses native SpriteRenderer-compatible entities (Flat 2D + Voxel pose path).
local V = ...
local Tile = V.require("tile")
local CatchMath = V.require("catching/catch_math")

local Projectile = {}
Projectile.__index = Projectile

local CELL = Tile.CELL or 16
local WOBBLE_INTERVAL = 0.55
local RESOLVE_HOLD = 0.35

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
  return entity
end

--- Axis-aligned land cell from player toward facing for `tiles` steps.
local function landCell(startX, startY, facing, tiles)
  tiles = math.max(1, math.min(CatchMath.MAX_RANGE, math.floor(tiles + 0.5)))
  local dx, dy = 0, 0
  if facing == "up" then dy = -1
  elseif facing == "down" then dy = 1
  elseif facing == "left" then dx = -1
  elseif facing == "right" then dx = 1
  end
  return startX + dx * tiles, startY + dy * tiles
end

function Projectile.new()
  local self = setmetatable({}, Projectile)
  self.active = nil
  self.wobble = nil
  return self
end

function Projectile:isBusy()
  return self.active ~= nil or self.wobble ~= nil
end

function Projectile:cancel(ow, voxel)
  if self.active and self.active.ballEntity then
    removeEntityFromOw(ow, self.active.ballEntity)
    if voxel and voxel.unregister then
      pcall(voxel.unregister, voxel, self.active.ballEntity)
    end
  end
  if self.wobble and self.wobble.ballEntity then
    removeEntityFromOw(ow, self.wobble.ballEntity)
    if voxel and voxel.unregister then
      pcall(voxel.unregister, voxel, self.wobble.ballEntity)
    end
  end
  self.active = nil
  self.wobble = nil
end

function Projectile:startFlight(game, ow, opts)
  opts = opts or {}
  -- Replace any in-flight Ball cleanly before starting another.
  if self.active or self.wobble then
    self:cancel(ow, opts.voxel)
  end
  local ballType = opts.ballType or "POKE_BALL"
  local spriteId = opts.spriteId or ("SPRITE_WILDS_BALL_" .. ballType)
  local startX = opts.startX
  local startY = opts.startY
  local targetX = opts.targetX
  local targetY = opts.targetY
  local totalDist = math.max(1, opts.totalDist or 1)
  local facing = opts.facing or "down"
  local power = opts.power or totalDist
  local isMiss = opts.miss == true

  local endX, endY = targetX, targetY
  if isMiss then
    endX, endY = landCell(startX, startY, facing, power)
  end

  local ballEntity = makeBallEntity(game, ow, ballType, startX, startY, spriteId)
  if ow and ow.entities then
    table.insert(ow.entities, ballEntity)
  end

  local travel = math.max(1, math.abs(endX - startX) + math.abs(endY - startY))
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
    miss = isMiss,
    onImpact = opts.onImpact,
    meta = opts.meta,
  }
  playSfx(game, "SFX_BALL_TOSS")
  return true
end

function Projectile:beginWobble(game, ow, opts)
  opts = opts or {}
  local ballEntity = opts.ballEntity
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
      self.active = nil
      if finished.onImpact then
        finished.onImpact(finished)
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
        self.wobble = nil
        removeEntityFromOw(ow, done.ballEntity)
        if voxel and voxel.unregister and done.ballEntity then
          pcall(voxel.unregister, voxel, done.ballEntity)
        end
        if done.onResolve then
          done.onResolve(done)
        end
      end
    end
  end
end

return Projectile
