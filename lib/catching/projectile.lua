-- Temporary Poké Ball projectile + wobble / click / break on the target tile.
-- Uses native SpriteRenderer-compatible entities (Flat 2D + Voxel pose path).
--
-- Lifecycle contract: every Ball entity created here MUST be removed via
-- Projectile:cleanup() (idempotent). Presentation phases owned here:
--   FLYING → MISS_HOLD | WOBBLE → SUCCESS_CLICK | FAIL_BREAK → DONE
local V = ...
local Tile = V.require("tile")
local CatchMath = V.require("catching/catch_math")

local Projectile = {}
Projectile.__index = Projectile

local CELL = Tile.CELL or 16
local WOBBLE_INTERVAL = 0.55
local SUCCESS_CLICK_SEC = 0.20
local FAIL_BREAK_SEC = 0.28
local MISS_LAND_HOLD = 0.18
-- Visual size on the 160×144 canvas (~6px). Source PNGs stay 16×16; *_sm are 6×6.
local BALL_VISUAL_PX = 6

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

local function applyBallPresentation(ballEntity)
  if not ballEntity then return end
  local scale = ballEntity.wildsBallPresentScale or 1
  local alpha = ballEntity.wildsBallAlpha
  if alpha == nil then alpha = 1 end
  local flash = ballEntity.wildsBallFlash or 0
  local basePx = ballEntity._wildsBallBasePx or ballEntity.px or 0
  local basePy = ballEntity._wildsBallBasePy or ballEntity.py or 0
  local nudgeX = ballEntity.wildsBallNudgeX or 0
  local nudgeY = ballEntity.wildsBallNudgeY or 0
  -- Keep cell anchors; presentation offsets live in pixel space.
  ballEntity.px = basePx + nudgeX
  ballEntity.py = basePy + nudgeY
  ballEntity.wildsBallScale = (BALL_VISUAL_PX / CELL) * scale
  ballEntity.wildsBallAlpha = alpha
  ballEntity.wildsBallFlash = flash
end

local function bindBallDraw(entity, image)
  entity.wildsBallImage = image
  entity.wildsBallPresentScale = 1
  entity.wildsBallAlpha = 1
  entity.wildsBallFlash = 0
  entity.wildsBallNudgeX = 0
  entity.wildsBallNudgeY = 0
  entity.wildsBallScale = BALL_VISUAL_PX / CELL
  entity._wildsBallBasePx = entity.px
  entity._wildsBallBasePy = entity.py
  -- Suppress full-size SpriteRenderer sheet; custom draw paints the small Ball.
  function entity:pose()
    if self.wildsBallImage then
      return nil
    end
    return self.sprite, self.px, self.py, self.facing or "down", 0, false
  end
  function entity:draw(camX, camY)
    local img = self.wildsBallImage
    if not (img and love and love.graphics) then return end
    local lg = love.graphics
    local iw, ih = img:getDimensions()
    local present = self.wildsBallPresentScale or 1
    local visual = (BALL_VISUAL_PX * present)
    local drawScale = visual / math.max(iw, ih)
    local alpha = self.wildsBallAlpha
    if alpha == nil then alpha = 1 end
    local flash = self.wildsBallFlash or 0
    local px = (self.px or 0) - (camX or 0) + CELL * 0.5 - (iw * drawScale) * 0.5
    local py = (self.py or 0) - (camY or 0) + CELL * 0.5 - (ih * drawScale) * 0.5
    lg.push("all")
    if img.setFilter then img:setFilter("nearest", "nearest") end
    if flash > 0 then
      lg.setColor(1, 1, 1, math.min(1, alpha))
    else
      lg.setColor(1, 1, 1, math.min(1, alpha))
    end
    lg.draw(img, px, py, 0, drawScale, drawScale)
    if flash > 0 then
      lg.setColor(1, 1, 1, 0.55 * flash * alpha)
      lg.rectangle("fill", px, py, iw * drawScale, ih * drawScale)
    end
    lg.pop()
  end
end

local function makeBallEntity(game, ow, ballType, cellX, cellY, spriteId, image)
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
  end
  entity.cellX = cellX
  entity.cellY = cellY
  entity.px = cellX * CELL
  entity.py = cellY * CELL
  entity.isPokeBallEntity = true
  entity.wildsProjectile = true
  entity.passable = true
  entity.blocking = false
  entity.wildsCatchProjectile = true
  entity.hiddenBody = false
  bindBallDraw(entity, image)
  return entity
end

--- Axis-aligned land cell from player toward facing for `tiles` steps.
function Projectile.landCell(startX, startY, facing, tiles)
  tiles = CatchMath.roundedPower(tiles)
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
  self._trackedBall = nil
  self._missHold = nil
  self.phase = "DONE"
  return self
end

function Projectile:isBusy()
  return self.active ~= nil or self.wobble ~= nil or self._missHold ~= nil
end

function Projectile:visualPhase()
  if self.active then return "FLYING" end
  if self._missHold then return "MISS_HOLD" end
  if self.wobble then return self.wobble.phase or "WOBBLE" end
  return "DONE"
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
  self.phase = "DONE"
end

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

  local endX, endY, travel = Projectile.landCell(startX, startY, facing, power)

  local ballEntity = makeBallEntity(game, ow, ballType, startX, startY, spriteId, opts.image)
  if ow and ow.entities then
    table.insert(ow.entities, ballEntity)
  end
  self._trackedBall = ballEntity
  self.phase = "FLYING"

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
  self.phase = "WOBBLE"
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
    onEscapeReveal = opts.onEscapeReveal,
    game = game,
    ow = ow,
    escapeRevealed = false,
  }
  if ballEntity then
    ballEntity.cellX = opts.x
    ballEntity.cellY = opts.y
    ballEntity.px = opts.x * CELL
    ballEntity.py = opts.y * CELL
    ballEntity._wildsBallBasePx = ballEntity.px
    ballEntity._wildsBallBasePy = ballEntity.py
    ballEntity.wildsBallPresentScale = 1
    ballEntity.wildsBallAlpha = 1
    ballEntity.wildsBallFlash = 0
    ballEntity.wildsBallNudgeX = 0
    ballEntity.wildsBallNudgeY = 0
  end
end

local function finishVisual(self, ow, voxel, done)
  local ball = done.ballEntity
  self.wobble = nil
  self.phase = "DONE"
  if done.onResolve then
    done.onResolve(done)
  end
  self:cleanup(ow, voxel, ball)
end

local function updateSuccessClick(self, wob, dt, ow, voxel)
  wob.timer = wob.timer + dt
  local t = math.min(1, wob.timer / SUCCESS_CLICK_SEC)
  local ball = wob.ballEntity
  -- 1.0 → 0.85 → 1.0 over the click window + brief white flash.
  local scale
  if t < 0.45 then
    scale = 1.0 - 0.15 * (t / 0.45)
  else
    scale = 0.85 + 0.15 * ((t - 0.45) / 0.55)
  end
  if ball then
    ball._wildsBallBasePx = wob.x * CELL
    ball._wildsBallBasePy = wob.y * CELL
    ball.wildsBallPresentScale = scale
    ball.wildsBallFlash = (t < 0.35) and (1 - t / 0.35) or 0
    ball.wildsBallAlpha = 1
    ball.wildsBallNudgeX = 0
    ball.wildsBallNudgeY = 0
    applyBallPresentation(ball)
  end
  if t >= 1 then
    finishVisual(self, ow, voxel, wob)
  end
end

local function updateFailBreak(self, wob, dt, ow, voxel)
  wob.timer = wob.timer + dt
  local t = math.min(1, wob.timer / FAIL_BREAK_SEC)
  local ball = wob.ballEntity

  if (not wob.escapeRevealed) and t >= 0.45 then
    wob.escapeRevealed = true
    if wob.onEscapeReveal then
      pcall(wob.onEscapeReveal, wob)
    end
  end

  if ball then
    ball._wildsBallBasePx = wob.x * CELL
    ball._wildsBallBasePy = wob.y * CELL
    if t < 0.35 then
      ball.wildsBallPresentScale = 1.0 + 0.15 * (t / 0.35)
      ball.wildsBallNudgeX = math.sin(t * 40) * 1.5
      ball.wildsBallAlpha = 1
      ball.wildsBallFlash = 0.7 * (1 - t / 0.35)
    else
      local fade = (t - 0.35) / 0.65
      ball.wildsBallPresentScale = 1.15
      ball.wildsBallNudgeX = (fade < 0.5 and 2 or -2)
      ball.wildsBallAlpha = math.max(0, 1 - fade)
      ball.wildsBallFlash = 0
    end
    applyBallPresentation(ball)
  end

  if t >= 1 then
    finishVisual(self, ow, voxel, wob)
  end
end

function Projectile:update(game, ow, dt, voxel)
  dt = dt or 0.016

  if self._missHold then
    self.phase = "MISS_HOLD"
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
    self.phase = "FLYING"
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
      proj.ballEntity._wildsBallBasePx = proj.ballEntity.px
      proj.ballEntity._wildsBallBasePy = proj.ballEntity.py
      proj.ballEntity.wildsBallPresentScale = 1
      proj.ballEntity.wildsBallAlpha = 1
      applyBallPresentation(proj.ballEntity)
    end

    if proj.progress >= 1.0 then
      local finished = proj
      self._trackedBall = finished.ballEntity
      self.active = nil
      if finished.miss then
        self.phase = "MISS_HOLD"
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
    local ballEntity = wob.ballEntity

    if wob.phase == "WOBBLE" then
      self.phase = "WOBBLE"
      wob.timer = wob.timer + dt
      if wob.totalShakes <= 0 then
        if wob.caught then
          wob.phase = "SUCCESS_CLICK"
          wob.timer = 0
          playSfx(wob.game or game, "SFX_CAUGHT_MON")
        else
          wob.phase = "FAIL_BREAK"
          wob.timer = 0
          playSfx(wob.game or game, "SFX_BALL_POOF")
        end
      elseif wob.timer >= WOBBLE_INTERVAL then
        wob.timer = 0
        wob.currentShake = wob.currentShake + 1
        playSfx(wob.game or game, "SFX_BALL_POOF")
        if wob.currentShake >= wob.totalShakes then
          if wob.caught then
            wob.phase = "SUCCESS_CLICK"
            wob.timer = 0
            playSfx(wob.game or game, "SFX_CAUGHT_MON")
          else
            wob.phase = "FAIL_BREAK"
            wob.timer = 0
            playSfx(wob.game or game, "SFX_BALL_POOF")
          end
        end
      else
        local nudgeX = math.sin(wob.timer * 22) * 2.5
        if ballEntity then
          ballEntity._wildsBallBasePx = wob.x * CELL
          ballEntity._wildsBallBasePy = wob.y * CELL
          ballEntity.wildsBallNudgeX = nudgeX
          ballEntity.wildsBallNudgeY = 0
          ballEntity.wildsBallPresentScale = 1
          ballEntity.wildsBallAlpha = 1
          applyBallPresentation(ballEntity)
        end
      end
    elseif wob.phase == "SUCCESS_CLICK" then
      self.phase = "SUCCESS_CLICK"
      updateSuccessClick(self, wob, dt, ow, voxel)
    elseif wob.phase == "FAIL_BREAK" then
      self.phase = "FAIL_BREAK"
      updateFailBreak(self, wob, dt, ow, voxel)
    end
  end
end

Projectile.BALL_VISUAL_PX = BALL_VISUAL_PX
Projectile.SUCCESS_CLICK_SEC = SUCCESS_CLICK_SEC
Projectile.FAIL_BREAK_SEC = FAIL_BREAK_SEC

return Projectile
