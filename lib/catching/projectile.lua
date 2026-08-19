-- Temporary Poké Ball projectile + wobble / click / break on the target tile.
-- Uses native SpriteRenderer entities (Flat 2D + Voxel / Dramatic Shape pose path).
--
-- CRITICAL CONTRACT:
--   Ball entities may be inserted into ow.entities. Therefore entity:pose() MUST
--   remain the native SpriteRenderer pose — never return nil to suppress drawing.
--   Small visual size comes from ~8×8 throw art centered in a 16×16 transparent
--   canvas (SPRITE_WILDS_BALL_* / assets/balls/throw/*.png). No custom draw()/pose().
--
-- Lifecycle: every Ball MUST be removed via Projectile:cleanup() (idempotent).
-- Presentation phases: FLYING → MISS_HOLD | WOBBLE → SUCCESS_CLICK | FAIL_BREAK → DONE
local V = ...
local Tile = V.require("tile")
local CatchMath = V.require("catching/catch_math")
local CatchSfx = V.require("catching/catch_sfx")
local GameCompat = V.require("game_compat")

local Projectile = {}
Projectile.__index = Projectile

local CELL = Tile.CELL or 16
local WOBBLE_INTERVAL = 0.55
local SUCCESS_CLICK_SEC = 0.20
local FAIL_BREAK_SEC = 0.28
local MISS_LAND_HOLD = 0.18
-- Artwork is ~8px inside a 16×16 transparent SpriteDef canvas (engine contract).
-- BALL_VISUAL_PX is a HUD-independence sentinel, not the packaged art size.
local BALL_VISUAL_PX = 6
local NUDGE_MAX = 2

local function playCatch(game, role)
  CatchSfx.playNativeCatchSfx(game, role)
end

local function goldCatchStage(game, stage)
  if not GameCompat.isGen2(nil, game) then return end
  print("[GoldCatch] " .. tostring(stage))
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

local function clampNudge(v)
  v = tonumber(v) or 0
  if v > NUDGE_MAX then return NUDGE_MAX end
  if v < -NUDGE_MAX then return -NUDGE_MAX end
  return v
end

-- Positional presentation only. Never scale the SpriteRenderer entity.
local function applyBallPresentation(ballEntity)
  if not ballEntity then return end
  local basePx = ballEntity._wildsBallBasePx or ballEntity.px or 0
  local basePy = ballEntity._wildsBallBasePy or ballEntity.py or 0
  local nudgeX = clampNudge(ballEntity.wildsBallNudgeX)
  local nudgeY = clampNudge(ballEntity.wildsBallNudgeY)
  ballEntity.px = basePx + nudgeX
  ballEntity.py = basePy + nudgeY
end

local function tagBallEntity(entity, ballType, cellX, cellY, spriteId)
  entity.cellX = cellX
  entity.cellY = cellY
  entity.px = cellX * CELL
  entity.py = cellY * CELL
  entity._wildsBallBasePx = entity.px
  entity._wildsBallBasePy = entity.py
  entity.wildsBallNudgeX = 0
  entity.wildsBallNudgeY = 0
  entity.isPokeBallEntity = true
  entity.wildsProjectile = true
  entity.wildsCatchProjectile = true
  entity.passable = true
  entity.blocking = false
  entity.hiddenBody = false
  entity.visible = true
  -- Must NEVER look like a Wild / Town / water-shadow entity to VoxelAdapter.
  entity.overworldWildSpawn = false
  entity.townPokemon = false
  entity.isAmbient = false
  entity.isFollower = false
  entity.pokemonRenderer = nil
  entity.wildsBallType = ballType
  entity.spriteName = spriteId
  -- Do NOT override pose() or draw(). Native SpriteRenderer / NPC pose only.
  return entity
end

local function wrapGoldDrawTrace(game, entity)
  if not entity or type(entity.draw) ~= "function" then return end
  if entity._goldCatchDrawWrapped then return end
  entity._goldCatchDrawWrapped = true
  local orig = entity.draw
  function entity:draw(ox, oy, scale)
    if not self._goldCatchDrawTraced then
      self._goldCatchDrawTraced = true
      goldCatchStage(game, "PROJECTILE_DRAW")
    end
    return orig(self, ox, oy, scale)
  end
end

local function makeBallEntity(game, ow, ballType, cellX, cellY, spriteId, image, spriteDef)
  local entity, err = GameCompat.makeCatchProjectile(game, ow, {
    ballType = ballType,
    spriteId = spriteId,
    spriteDef = spriteDef,
    image = image,
    x = cellX,
    y = cellY,
  })
  if GameCompat.isGen2(nil, game) then
    goldCatchStage(game, "PROJECTILE_CREATE")
    if not entity then
      return nil, err or "Gold projectile construction failed"
    end
  elseif not entity then
    -- Gen1 test / headless stub. Still exposes a non-nil pose() contract so
    -- accidental Voxel traversal cannot poison shared billboard lists.
    entity = {
      cellX = cellX,
      cellY = cellY,
      px = cellX * CELL,
      py = cellY * CELL,
      facing = "down",
      sprite = spriteId,
      movement = "NONE",
      passable = true,
      pose = function(self)
        return self.sprite, self.px, self.py, self.facing or "down", 0, false
      end,
    }
  end
  return tagBallEntity(entity, ballType, cellX, cellY, spriteId)
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

--- Idempotent removal from ow.entities/npcs + internal state.
-- Does NOT call VoxelAdapter:unregister — that path is for emergency wild
-- fallback bookkeeping and must not touch shared renderer state for Ball NPCs.
function Projectile:cleanup(ow, _voxel, ballEntity)
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
  local hitKind = opts.hitKind or "NONE"

  local endX, endY, travel
  if opts.destX ~= nil and opts.destY ~= nil then
    endX = opts.destX
    endY = opts.destY
    travel = math.max(1, math.floor(tonumber(opts.travel) or power))
  else
    endX, endY, travel = Projectile.landCell(startX, startY, facing, power)
  end

  -- image arg is SpriteDef.image fallback on Gold; size stays throw canvas art.
  local ballEntity, createErr = makeBallEntity(
    game, ow, ballType, startX, startY, spriteId, opts.image, opts.spriteDef)
  if not ballEntity then
    return false, createErr
  end
  if opts.image then ballEntity.image = opts.image end
  wrapGoldDrawTrace(game, ballEntity)
  local attached = GameCompat.attachCatchProjectile(ow, ballEntity, game)
  if GameCompat.isGen2(nil, game) then
    goldCatchStage(game, "PROJECTILE_ATTACH")
    if attached == "none" then
      removeEntityFromOw(ow, ballEntity)
      return false, "Gold projectile attach failed"
    end
  end
  self._trackedBall = ballEntity
  self.phase = "FLYING"
  self._goldUpdateTraced = nil

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
    hitKind = hitKind,
    onImpact = opts.onImpact,
    meta = opts.meta,
  }
  playCatch(game, "throw")
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
    ballEntity.wildsBallNudgeX = 0
    ballEntity.wildsBallNudgeY = 0
    ballEntity.visible = true
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
  -- Brief one-pixel lift — no entity scale (SpriteRenderer contract).
  if ball then
    ball._wildsBallBasePx = wob.x * CELL
    ball._wildsBallBasePy = wob.y * CELL
    ball.wildsBallNudgeX = 0
    ball.wildsBallNudgeY = (t < 0.45) and -1 or 0
    ball.visible = true
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
      ball.wildsBallNudgeX = math.sin(t * 40) * NUDGE_MAX
      ball.wildsBallNudgeY = 0
      ball.visible = true
    else
      local fade = (t - 0.35) / 0.65
      ball.wildsBallNudgeX = (fade < 0.5 and NUDGE_MAX or -NUDGE_MAX)
      ball.wildsBallNudgeY = 1
      -- Hide mid-break instead of alpha-scaling the sprite sheet.
      if fade >= 0.35 then
        ball.visible = false
      end
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
    if not self._goldUpdateTraced then
      self._goldUpdateTraced = true
      goldCatchStage(game, "PROJECTILE_UPDATE")
    end
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
      proj.ballEntity.wildsBallNudgeX = 0
      proj.ballEntity.wildsBallNudgeY = 0
      proj.ballEntity.visible = true
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
          -- Gen1 has no separate lock-click SFX; play Caught_Mon fanfare only.
          playCatch(wob.game or game, "caught")
        else
          wob.phase = "FAIL_BREAK"
          wob.timer = 0
          playCatch(wob.game or game, "break")
        end
      elseif wob.timer >= WOBBLE_INTERVAL then
        wob.timer = 0
        wob.currentShake = wob.currentShake + 1
        playCatch(wob.game or game, "wobble")
        if wob.currentShake >= wob.totalShakes then
          if wob.caught then
            wob.phase = "SUCCESS_CLICK"
            wob.timer = 0
            playCatch(wob.game or game, "caught")
          else
            wob.phase = "FAIL_BREAK"
            wob.timer = 0
            playCatch(wob.game or game, "break")
          end
        end
      else
        local nudgeX = math.sin(wob.timer * 22) * NUDGE_MAX
        if ballEntity then
          ballEntity._wildsBallBasePx = wob.x * CELL
          ballEntity._wildsBallBasePy = wob.y * CELL
          ballEntity.wildsBallNudgeX = nudgeX
          ballEntity.wildsBallNudgeY = 0
          ballEntity.visible = true
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
