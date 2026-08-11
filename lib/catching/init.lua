-- Optional overworld Poké Ball catching for Wilds of Kanto.
-- Extends existing wild entity / battle / occupancy lifecycle — no second
-- encounter manager. Safari sessions disable throws (native Safari only).
local V = ...
local Config = V.require("config")
local Behavior = V.require("behavior")
local Movement = V.require("movement")
local SafariCompat = V.require("safari_compat")
local CatchMath = V.require("catching/catch_math")
local Target = V.require("catching/target")
local Projectile = V.require("catching/projectile")
local RangePreview = V.require("catching/range_preview")
local BallHud = V.require("catching/hud")
local CatchInput = V.require("catching/input")
local CatchSfx = V.require("catching/catch_sfx")
local DebugLog = V.require("debug_log")

local OverworldCatching = {}
OverworldCatching.__index = OverworldCatching

OverworldCatching.BALL_TYPES = BallHud.BALL_ORDER
OverworldCatching.PIPELINE_ID = "owwild_catching_tick"

-- Full up/down meter cycle ≈ 1.75s (responsive, not frustrating).
local METER_CYCLE_SECONDS = 1.75
local METER_MIN = 1
local METER_MAX = 6

-- Keep full-res sources; runtime / sprite registration prefers compact *_sm.
local BALL_ASSET = {
  POKE_BALL = "assets/balls/poke_ball.png",
  GREAT_BALL = "assets/balls/great_ball.png",
  ULTRA_BALL = "assets/balls/ultra_ball.png",
  MASTER_BALL = "assets/balls/master_ball.png",
}
local BALL_ASSET_SM = {
  POKE_BALL = "assets/balls/poke_ball_sm.png",
  GREAT_BALL = "assets/balls/great_ball_sm.png",
  ULTRA_BALL = "assets/balls/ultra_ball_sm.png",
  MASTER_BALL = "assets/balls/master_ball_sm.png",
}

local function tryRequire(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil
end

local function now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

local function playCatch(game, role)
  CatchSfx.playNativeCatchSfx(game, role)
end

local function pushText(game, mod, msg, onDone)
  if not game or not msg then
    if onDone then onDone() end
    return
  end
  local finished = false
  local function finish()
    if finished then return end
    finished = true
    if onDone then onDone() end
  end
  local TextBox = (mod and mod.ui and mod.ui.TextBox) or tryRequire("src.render.TextBox")
  if not (TextBox and TextBox.new and game.stack and game.stack.push) then
    finish()
    return
  end
  local ok, box = pcall(TextBox.new, game, msg, finish)
  if ok and box then
    local pushOk = pcall(function() game.stack:push(box) end)
    if not pushOk then
      finish()
    end
  else
    finish()
  end
end

function OverworldCatching.new(mod, logic)
  local self = setmetatable({}, OverworldCatching)
  self.mod = mod
  self.logic = logic
  self.projectile = Projectile.new()
  self.hud = BallHud.new(mod, self)
  self.selectedBallIndex = 1
  self.meter = { active = false, t = 0, power = 1, rising = true }
  self.meterSource = nil -- "desktop" (C) | "modifier" (B+A) | nil
  self.throwHeld = false
  self.cycleHeld = false
  self.phase = "idle" -- idle | metering | flying | capturing | resolving
  self.activeCapture = nil
  self._lastDebug = nil
  self._ballImages = {}
  self._registered = false
  self._contentRegistered = false
  -- Mobile/controller B-modifier adapter (additional to desktop C/Q).
  self.catchInput = CatchInput.new(self)
  return self
end

function OverworldCatching:game()
  return self.mod.world and self.mod.world.game
end

function OverworldCatching:overworld()
  local world = self.mod.world
  if not world or not world.overworld then return nil end
  return world:overworld()
end

function OverworldCatching:registerContent()
  if self._contentRegistered then return true end
  local mod = self.mod
  if not (mod.content and mod.content.sprites and mod.content.sprites.register) then
    return false, "sprites registry unavailable"
  end
  for _, ballType in ipairs(OverworldCatching.BALL_TYPES) do
    local id = "SPRITE_WILDS_BALL_" .. ballType
    local rel = BALL_ASSET_SM[ballType] or BALL_ASSET[ballType]
    local path = mod.assets and mod.assets.path and mod.assets:path(rel) or rel
    if not mod.content.sprites:get(id) then
      local ok, err = pcall(function()
        mod.content.sprites:register(id, {
          image = path,
          frames = 1,
          walker = false,
          trueColor = true,
        })
      end)
      if not ok then
        DebugLog.warn(mod, "ball sprite %s: %s", id, tostring(err))
      end
    end
  end
  self._contentRegistered = true
  return true
end

function OverworldCatching:ballImage(ballType)
  if self._ballImages[ballType] ~= nil then
    return self._ballImages[ballType] or nil
  end
  if not (love and love.graphics and love.graphics.newImage) then
    self._ballImages[ballType] = false
    return nil
  end
  -- Prefer compact nearest-neighbor assets for projectile + HUD.
  local rel = BALL_ASSET_SM[ballType] or BALL_ASSET[ballType]
  local path = self.mod.assets and self.mod.assets.path and self.mod.assets:path(rel) or rel
  local ok, img = pcall(love.graphics.newImage, path)
  if (not ok or not img) and BALL_ASSET[ballType] then
    local full = self.mod.assets and self.mod.assets.path
      and self.mod.assets:path(BALL_ASSET[ballType]) or BALL_ASSET[ballType]
    ok, img = pcall(love.graphics.newImage, full)
  end
  if ok and img and img.setFilter then
    pcall(img.setFilter, img, "nearest", "nearest")
  end
  self._ballImages[ballType] = ok and img or false
  return ok and img or nil
end

function OverworldCatching:ballCount(game, ballType)
  local inv = game and game.save and game.save.inventory
  if not inv then return 0 end
  return tonumber(inv[ballType]) or 0
end

function OverworldCatching:getSelectedBall(game)
  local types = OverworldCatching.BALL_TYPES
  local current = types[self.selectedBallIndex] or types[1]
  if self:ballCount(game, current) > 0 then
    return current
  end
  for i, ball in ipairs(types) do
    if self:ballCount(game, ball) > 0 then
      self.selectedBallIndex = i
      return ball
    end
  end
  return current
end

function OverworldCatching:cycleSelectedBall(game, direction)
  direction = direction or 1
  if direction >= 0 then direction = 1 else direction = -1 end
  local types = OverworldCatching.BALL_TYPES
  local total = #types
  local start = self.selectedBallIndex
  for _ = 1, total do
    self.selectedBallIndex = ((self.selectedBallIndex - 1 + direction) % total) + 1
    local ball = types[self.selectedBallIndex]
    if self:ballCount(game, ball) > 0 then
      self:_catchLog("selected=%s count=%d", tostring(ball), self:ballCount(game, ball))
      return ball
    end
  end
  -- All zero: keep selection stable (do not crash / spin).
  self.selectedBallIndex = start
  return types[self.selectedBallIndex]
end

function OverworldCatching:consumeBall(game, ballType)
  local Bag = tryRequire("src.inventory.Bag")
  local save = game and game.save
  if not save or not save.inventory then return false end
  if self:ballCount(game, ballType) <= 0 then return false end
  if Bag and Bag.remove then
    Bag.remove(save, ballType, 1)
  else
    local n = (save.inventory[ballType] or 0) - 1
    if n <= 0 then save.inventory[ballType] = nil
    else save.inventory[ballType] = n end
  end
  return true
end

function OverworldCatching:anyBalls(game)
  for _, ball in ipairs(OverworldCatching.BALL_TYPES) do
    if self:ballCount(game, ball) > 0 then return true end
  end
  return false
end

--- Stack / dialogue / battle / script guards.
function OverworldCatching:playerHasControl(game, ow)
  if not game or not ow or not ow.player then return false end
  if ow.runner and ow.runner.isRunning and ow.runner:isRunning() then
    return false
  end
  if ow.textbox and ow.textbox.active and ow.textbox:active() then
    return false
  end
  if ow.engaging then return false end
  if self.logic and self.logic.pendingBattle then return false end

  local stack = game.stack
  if stack and stack.top then
    local top = stack:top()
    if top and top ~= ow then
      -- Allow only when overworld is top of stack.
      local opaque = top.isOpaque == true
        or (type(top.isOpaque) == "function" and top:isOpaque())
      if opaque or top.battle or top.isBattle then
        return false
      end
      -- Menus / party / PC / options typically sit above overworld.
      if top ~= ow then return false end
    end
  end
  return true
end

function OverworldCatching:safariBlocks(game, ow)
  local mapId = ow and ow.map and ow.map.id
  local status = SafariCompat.status(game, ow, mapId)
  return status == SafariCompat.STATUS.ACTIVE
end

function OverworldCatching:isBlockedByUi(game, ow)
  if not game then return true end
  if self.logic and self.logic.pendingBattle then return true end
  if ow and ow.runner and ow.runner.isRunning and ow.runner:isRunning() then
    return true
  end
  if ow and ow.textbox and ow.textbox.active and ow.textbox:active() then
    return true
  end
  local stack = game.stack
  if stack and stack.top then
    local top = stack:top()
    if top and ow and top ~= ow then
      local opaque = top.isOpaque == true
        or (type(top.isOpaque) == "function" and top:isOpaque())
      if opaque or top.battle or top.isBattle then
        return true
      end
      return true
    end
  end
  return false
end

function OverworldCatching:canShowHud(game, ow)
  if not Config.overworldCatchingEnabled(self.mod) then return false end
  if not Config.isEnabled(self.mod) then return false end
  if not game or not ow or not ow.player then return false end
  if self:safariBlocks(game, ow) then return false end
  if self.logic and self.logic.pendingBattle then return false end
  -- Meter / flight / capture must keep HUD+meter visible even if control flickers.
  if self.phase == "metering" or self.phase == "flying"
     or self.phase == "capturing" or self.phase == "resolving" then
    return true
  end
  if self:isBlockedByUi(game, ow) then return false end
  return true
end

function OverworldCatching:canAcceptInput(game, ow)
  if not Config.overworldCatchingEnabled(self.mod) then return false end
  if not Config.isEnabled(self.mod) then return false end
  if not self:playerHasControl(game, ow) then return false end
  if self:safariBlocks(game, ow) then return false end
  if self.projectile:isBusy() then return false end
  if self.phase == "capturing" or self.phase == "resolving" or self.phase == "flying" then
    return false
  end
  return true
end

function OverworldCatching:meterState()
  -- Always return the meter table so HUD can read .active reliably.
  return self.meter
end

function OverworldCatching:debugSnapshot()
  if self.phase == "idle" and not self.meter.active then
    return nil
  end
  return self._lastDebug
end

function OverworldCatching:_catchLog(fmt, ...)
  if not (Config.devOverlay(self.mod) or Config.debug(self.mod)) then
    return
  end
  local ok, msg = pcall(string.format, fmt, ...)
  print("[Wilds][Catch] " .. (ok and msg or tostring(fmt)))
end

local function inputDown(game, aliases)
  local input = game and game.input
  if input then
    local downFunc = type(input.down) == "function" and function(k) return input:down(k) end
                  or type(input.isDown) == "function" and function(k) return input:isDown(k) end
    if downFunc then
      for _, a in ipairs(aliases) do
        local ok, v = pcall(downFunc, a)
        if ok and v then return true end
      end
    end
  end
  if love and love.keyboard and love.keyboard.isDown then
    for _, a in ipairs(aliases) do
      if #a == 1 or a == "lshift" or a == "rshift" then
        if love.keyboard.isDown(a) then return true end
      end
    end
  end
  return false
end

-- Throw: hold C. Cycle: Q (NOT E).
-- Binding audit vs Gen1Recomp defaults + Wilds:
--   Move WASD/arrows | A=Z/Enter/Space | B=X/Backspace | Start=Esc | Select=Tab/Shift
--   Hotkeys 2–5, -/=, F1/F2/F10 | Throw=C (OW Catch)
--   E rejected by requirement; Q unused in engine CONTROLS and this mod.
-- Gen1Recomp OPTIONS→CONTROLS only rebinds stock actions; no safe custom-action
-- registration API was found, so Throw/Cycle stay hardcoded defaults.
local THROW_KEYS = { "c", "throw_ball", "ow_catch_throw" }
local CYCLE_KEYS = { "q", "cycle_ball", "ow_catch_cycle" }

function OverworldCatching:_updateMeter(dt)
  local m = self.meter
  if not m.active then return end
  -- Triangle wave 1↔6 over METER_CYCLE_SECONDS for a full up+down.
  local half = METER_CYCLE_SECONDS * 0.5
  local speed = (METER_MAX - METER_MIN) / half
  if m.rising then
    m.power = m.power + speed * dt
    if m.power >= METER_MAX then
      m.power = METER_MAX
      m.rising = false
    end
  else
    m.power = m.power - speed * dt
    if m.power <= METER_MIN then
      m.power = METER_MIN
      m.rising = true
    end
  end
end

function OverworldCatching:_beginMeter()
  self.meter.active = true
  self.meter.t = 0
  self.meter.power = METER_MIN
  self.meter.rising = true
  self.phase = "metering"
  self:_catchLog("phase=metering source=%s", tostring(self.meterSource or "desktop"))
end

function OverworldCatching:_cancelMeter()
  self.meter.active = false
  self.meter.power = METER_MIN
  if self.phase == "metering" then self.phase = "idle" end
  self.meterSource = nil
end

function OverworldCatching:_clearPreview()
  RangePreview.clear()
end

function OverworldCatching:_pushNoBalls(game)
  pushText(game, self.mod, "You don't have any\nPOKé BALLs!")
end

--- Freeze wild during flight but KEEP IT VISIBLE until impact.
function OverworldCatching:_freezeTargetForThrow(entity)
  if not entity then return end
  entity.wildsCatchState = "pending"
  entity.wildsCatchPending = true
  entity.wildsCatchLocked = false
  entity._catchPrevVisible = entity.visible
  entity._catchPrevVisibleSprite = entity.visibleSprite
  entity._catchPrevCanBattle = entity.canTriggerBattle
  entity.visible = true
  entity.visibleSprite = true
  entity.canTriggerBattle = false
  entity.movementLocked = true
  if entity.behaviorState then
    entity.behaviorState.sightDisabled = true
    entity.behaviorState.catchLocked = true
  end
  Movement.stop(entity, "CATCHING")
  -- Do NOT detach from world yet — player must see the mon until impact.
end

--- At Ball impact: hide Pokémon into the Ball and detach for Voxel safety.
function OverworldCatching:_lockTarget(entity)
  if not entity then return end
  entity.wildsCatchState = "capturing"
  entity.wildsCatchLocked = true
  entity.wildsCatchPending = nil
  if entity._catchPrevVisible == nil then
    entity._catchPrevVisible = entity.visible
  end
  if entity._catchPrevVisibleSprite == nil then
    entity._catchPrevVisibleSprite = entity.visibleSprite
  end
  if entity._catchPrevCanBattle == nil then
    entity._catchPrevCanBattle = entity.canTriggerBattle
  end
  entity.visible = false
  entity.visibleSprite = false
  entity.canTriggerBattle = false
  entity.movementLocked = true
  if entity.behaviorState then
    entity.behaviorState.sightDisabled = true
    entity.behaviorState.catchLocked = true
  end
  Movement.stop(entity, "CATCHING")
  -- Detach from ow.entities while capturing (Voxel-safe); keep logic + occupancy.
  if self.logic and self.logic._detachFromWorld then
    self.logic:_detachFromWorld(entity)
  end
end

function OverworldCatching:_unlockTarget(entity, opts)
  opts = opts or {}
  if not entity then return end
  entity.wildsCatchState = nil
  entity.wildsCatchLocked = false
  entity.wildsCatchPending = nil
  entity.movementLocked = false
  if opts.restoreVisible ~= false then
    entity.visible = (entity._catchPrevVisible ~= false)
    entity.visibleSprite = (entity._catchPrevVisibleSprite ~= false)
  end
  if opts.restoreBattle ~= false then
    entity.canTriggerBattle = entity._catchPrevCanBattle ~= false
  end
  entity._catchPrevVisible = nil
  entity._catchPrevVisibleSprite = nil
  entity._catchPrevCanBattle = nil
  if entity.behaviorState then
    entity.behaviorState.catchLocked = false
    -- Do not leave a permanent catch-only sight lock; aggro path re-applies its own.
    if opts.clearSightLock ~= false then
      entity.behaviorState.sightDisabled = false
    end
  end
  if opts.reattach ~= false and self.logic and self.logic._attach
     and entity.registeredInWorld ~= true then
    pcall(function() self.logic:_attach(entity) end)
  end
end

--- Mid-break reveal: Pokémon pops out of the Ball before cleanup/aggro.
function OverworldCatching:_revealEscapingPokemon(entity)
  if not entity then return end
  self:_unlockTarget(entity)
  entity.visible = true
  entity.visibleSprite = true
  entity.canTriggerBattle = true
  entity.wildsCatchState = nil
  entity.wildsCatchLocked = false
  entity.wildsCatchPending = nil
  entity.movementLocked = false
end

function OverworldCatching:_onEasterEggImpact(game, ow, kind, entity)
  -- Impact/poof only — no wobble / Caught_Mon fanfare for NPC or Town mons.
  playCatch(game, "impact")
  self.projectile:cleanup(ow, self.logic and self.logic.voxel)
  self.phase = "idle"
  self.activeCapture = nil
  local msg
  if kind == Target.HitKind.NPC then
    msg = "Ouch, yo, WTF"
  else
    msg = "Grrrr..."
  end
  self:_catchLog("easter egg kind=%s entity=%s", tostring(kind),
    tostring(entity and (entity.name or entity.ambientSpecies or entity.id) or "?"))
  pushText(game, self.mod, msg)
end

function OverworldCatching:_releaseThrow(game, ow)
  local power = self.meter.power or METER_MIN
  self:_cancelMeter()
  RangePreview.clear()

  local ballType = self:getSelectedBall(game)
  if self:ballCount(game, ballType) <= 0 then
    pushText(game, self.mod, "You don't have any\nPOKé BALLs!")
    self.phase = "idle"
    return
  end

  local player = ow.player
  local px, py = player.cellX, player.cellY
  local hit = Target.scanThrowPath(self.logic, ow, player, power)
  local Hit = Target.HitKind
  local facing = hit.facing or Target.facingOf(player)

  -- Consume on commit (hit, easter egg, or miss).
  if not self:consumeBall(game, ballType) then
    pushText(game, self.mod, "You don't have any\nPOKé BALLs!")
    self.phase = "idle"
    return
  end

  local landX, landY = Projectile.landCell(px, py, facing, power)
  self:_catchLog("throw released power=%.2f land=(%d,%d) facing=%s first=%s@%s",
    power, landX, landY, tostring(facing), tostring(hit.kind), tostring(hit.distance))

  local ballImage = self:ballImage(ballType)

  local function startMissFlight(feedback)
    self.phase = "flying"
    if feedback then self.hud:showFeedback(feedback, 0.7) end
    self.projectile:startFlight(game, ow, {
      ballType = ballType,
      spriteId = "SPRITE_WILDS_BALL_" .. ballType,
      image = ballImage,
      startX = px, startY = py,
      facing = facing,
      power = power,
      miss = true,
      hitKind = Hit.NONE,
      onImpact = function()
        -- Native clean miss ends after the ball poof (no wobble/fanfare).
        playCatch(game, "impact")
        self.projectile:cleanup(ow, self.logic and self.logic.voxel)
        self.phase = "idle"
        self:_catchLog("miss complete / projectile cleaned")
      end,
    })
    self:_catchLog("projectile started (miss)")
  end

  -- Easter eggs: first physical Town/NPC along the throw distance.
  if hit.kind == Hit.NPC or hit.kind == Hit.TOWN_MON then
    self.phase = "flying"
    self._lastDebug = {
      target = hit.kind, ball = ballType, dist = hit.distance,
      power = string.format("%.2f", power), quality = "easter", angle = nil,
    }
    self.projectile:startFlight(game, ow, {
      ballType = ballType,
      spriteId = "SPRITE_WILDS_BALL_" .. ballType,
      image = ballImage,
      startX = px, startY = py,
      facing = facing,
      power = hit.distance,
      destX = hit.x, destY = hit.y,
      travel = hit.distance,
      miss = true, -- land-hold then cleanup via onImpact
      hitKind = hit.kind,
      onImpact = function()
        self:_onEasterEggImpact(game, ow, hit.kind, hit.entity)
      end,
    })
    self:_catchLog("projectile started (%s)", tostring(hit.kind))
    return
  end

  if hit.kind ~= Hit.WILD or not hit.entity then
    self._lastDebug = {
      target = nil, ball = ballType, dist = nil,
      power = string.format("%.2f", power), quality = "miss", angle = nil,
    }
    startMissFlight("MISS!")
    return
  end

  local entity = hit.entity
  local dist = hit.distance
  local tx, ty = hit.x, hit.y
  local quality = CatchMath.throwQuality(power, dist)
  local monFacing = entity.facing or (entity.behaviorState and entity.behaviorState.facing)
  local angle = CatchMath.facingAngle(px, py, entity.cellX, entity.cellY, monFacing)
  local feedback = CatchMath.feedbackLabel(quality, angle)
  if feedback then self.hud:showFeedback(feedback, 0.85) end

  self._lastDebug = {
    target = entity.species or (entity.wildSpecies) or "?",
    ball = ballType,
    dist = dist,
    power = string.format("%.2f", power),
    quality = quality,
    angle = angle,
  }
  self:_catchLog("target species=%s distance=%s quality=%s",
    tostring(entity.species or entity.wildSpecies or "?"),
    tostring(dist),
    tostring(quality))

  local record = nil
  if self.logic and entity.id then
    record = self.logic.spawns and self.logic.spawns[entity.id]
  end

  local species = (record and record.species) or entity.species or entity.wildSpecies or "PIDGEY"
  local level = (record and record.level) or entity.level or entity.wildLevel or 5

  if quality == CatchMath.QUALITY.MISS then
    -- Aim too far/short: Ball still travels full power distance; mon unaffected.
    startMissFlight(nil)
    return
  end

  -- HIT path: freeze (visible) during flight; hide only on impact.
  -- Ball ALWAYS travels the selected power distance along facing (not auto-aimed).
  self:_freezeTargetForThrow(entity)
  self.phase = "flying"
  self.activeCapture = {
    entity = entity,
    record = record,
    species = species,
    level = level,
    ballType = ballType,
    quality = quality,
    angle = angle,
    dist = dist,
    tx = tx, ty = ty,
    landX = landX, landY = landY,
  }

  self.projectile:startFlight(game, ow, {
    ballType = ballType,
    spriteId = "SPRITE_WILDS_BALL_" .. ballType,
    image = ballImage,
    startX = px, startY = py,
    facing = facing,
    power = power,
    miss = false,
    hitKind = Hit.WILD,
    onImpact = function(proj)
      self:_onBallImpact(game, ow, proj)
    end,
  })
  self:_catchLog("projectile started (hit)")
end

function OverworldCatching:_onBallImpact(game, ow, proj)
  local cap = self.activeCapture
  if not cap or not cap.entity then
    self.projectile:cleanup(ow, self.logic and self.logic.voxel)
    self.phase = "idle"
    return
  end

  self:_catchLog("impact")
  local entity = cap.entity
  -- Native POOF_ANIM / Ball_Poof when the mon enters the Ball.
  playCatch(game, "impact")
  -- Hide / lock only now (Pokémon stays visible for the whole flight).
  self:_lockTarget(entity)
  self:_catchLog("target locked")

  local species = cap.species
  local level = cap.level
  local ballType = cap.ballType
  local quality = cap.quality
  local angle = cap.angle

  local Catching = tryRequire("src.battle.Catching")
  local targetDef = (game.data and game.data.pokemon and game.data.pokemon[species])
    or { catchRate = 255, name = species }
  local nativeRate = targetDef.catchRate or 255
  local rateOverride = CatchMath.effectiveCatchRate(nativeRate, level, quality, angle)

  local maxHp = math.max(1, math.floor(level * 2.5 + 10))
  local tempMon = {
    species = species,
    hp = maxHp,
    stats = { hp = maxHp },
    status = nil,
  }
  local rng = love and love.math and love.math.random or math.random
  local caught, shakes = false, 3
  self:_catchLog("catch attempt ball=%s rate=%s quality=%s",
    tostring(ballType), tostring(rateOverride), tostring(quality))
  if Catching and Catching.attempt then
    -- Gen1Recomp: Catching.attempt(ballType, mon, pokemonDef, rng[, rateOverride])
    -- Ball multipliers live inside the API — do not pre-multiply into rateOverride.
    caught, shakes = Catching.attempt(ballType, tempMon, targetDef, rng, rateOverride)
  else
    -- Headless / missing API: Master Ball always; else use rate heuristic.
    if ballType == "MASTER_BALL" then
      caught, shakes = true, 3
    else
      local roll = rng(0, 255)
      caught = roll <= rateOverride
      shakes = caught and 3 or 1
    end
  end
  self:_catchLog("result caught=%s shakes=%s", tostring(caught), tostring(shakes))

  -- Place Ball on the target tile for wobble (even if land cell was rounded nearby).
  local wobX = cap.tx or (proj and proj.targetX) or entity.cellX
  local wobY = cap.ty or (proj and proj.targetY) or entity.cellY

  self.phase = "capturing"
  self.projectile:beginWobble(game, ow, {
    x = wobX, y = wobY,
    ballEntity = (proj and proj.ballEntity) or self.projectile._trackedBall,
    caught = caught,
    totalShakes = shakes or 0,
    onEscapeReveal = function()
      -- Pokémon pops out near the end of FAIL_BREAK (before Ball cleanup).
      local capNow = self.activeCapture
      if capNow and capNow.entity then
        self:_revealEscapingPokemon(capNow.entity)
        capNow.escapedVisible = true
        self:_catchLog("escape reveal")
      end
    end,
    onResolve = function(wob)
      self:_resolveCapture(game, ow, caught == true)
    end,
  })
  self:_catchLog("wobble")
end

function OverworldCatching:_resolveCapture(game, ow, caught)
  local cap = self.activeCapture
  self.phase = "resolving"
  if not cap then
    self.phase = "idle"
    return
  end
  local entity = cap.entity
  local species = cap.species
  local level = cap.level
  local speciesDef = game and game.data and game.data.pokemon and game.data.pokemon[species]
  local speciesName = (speciesDef and speciesDef.name) or species

  if caught then
    self:_catchLog("resolving success")
    -- Catch SFX already played at SUCCESS_CLICK start.
    local Pokemon = tryRequire("src.pokemon.Pokemon")
    local Party = tryRequire("src.pokemon.Party")
    local Boxes = tryRequire("src.pokemon.Boxes")
    local newMon
    if Pokemon and Pokemon.new and game and game.data then
      local ok, mon = pcall(Pokemon.new, game.data, species, level)
      if ok then newMon = mon end
    end
    if not newMon then
      newMon = { species = species, level = level, hp = 1, stats = { hp = 1 } }
    end
    -- Preserve shiny/variant metadata when present and accepted.
    if entity and entity.shiny then newMon.shiny = true end
    if entity and entity.variant then newMon.variant = entity.variant end

    local msg = "All right!\n" .. tostring(speciesName) .. " was caught!"
    local added = false
    if Party and Party.add and game.save and game.save.party then
      added = Party.add(game.save.party, newMon) == true
    end
    if not added and Boxes and Boxes.deposit and game.save then
      local boxNum = Boxes.deposit(game.save, newMon)
      if boxNum then
        msg = msg .. "\fTransferred to\nBox " .. tostring(boxNum) .. "."
      else
        msg = msg .. "\fBox is full!"
      end
    elseif not added then
      if game.save and game.save.party and #(game.save.party) < 6 then
        table.insert(game.save.party, newMon)
      end
    end

    -- Stay hidden; despawn via Wilds canonical path (no reappear).
    if self.logic and entity and entity.id then
      self.logic:_despawn(entity.id, true)
    else
      self:_unlockTarget(entity, { reattach = false, restoreVisible = false })
    end
    self.activeCapture = nil
    self.phase = "idle"
    pushText(game, self.mod, msg)
    return
  end

  -- FAILURE after FAIL_BREAK visuals: Ball already cleaned by Projectile.
  -- Do NOT force BattleState here — only ! → AGGRESSIVE/chase; contact starts battle.
  self:_catchLog("resolving failure")
  if not cap.escapedVisible then
    self:_revealEscapingPokemon(entity)
  elseif entity then
    entity.visible = true
    entity.visibleSprite = true
    entity.canTriggerBattle = true
    entity.wildsCatchLocked = false
    entity.wildsCatchPending = nil
    entity.wildsCatchState = nil
    entity.movementLocked = false
  end

  local freeMsg = "Oh no!\n" .. tostring(speciesName) .. " broke free!"
  local logic = self.logic
  local record = cap.record
  if (not record) and logic and entity and entity.id then
    record = logic.spawns and logic.spawns[entity.id]
  end

  self.activeCapture = nil
  self.phase = "idle"

  -- TextBox onDone (or immediate fallback inside pushText) starts aggro/chase only.
  pushText(game, self.mod, freeMsg, function()
    self:_beginAggroAfterBreak(entity, record)
  end)
end

function OverworldCatching:_beginAggroAfterBreak(entity, record)
  if not entity or not self.logic then return end
  local logic = self.logic
  record = record or (entity.id and logic.spawns and logic.spawns[entity.id])
  if not record or record.state ~= Config.STATE.AVAILABLE then return end

  local water = Behavior.isWater(entity.behavior or record.behavior)
  local newBeh = water and Behavior.WATER_AGGRESSIVE or Behavior.AGGRESSIVE
  local region = entity.homeRegion
  Behavior.attach(entity, newBeh, region, math.random)
  entity.behavior = newBeh
  if record then record.behavior = newBeh end

  -- Ensure catch locks are fully clear so a second throw can target this mon.
  entity.wildsCatchState = nil
  entity.wildsCatchLocked = false
  entity.wildsCatchPending = nil
  entity.movementLocked = false
  entity.canTriggerBattle = true
  entity.visible = true
  entity.visibleSprite = true

  local ow = self:overworld()
  local player = ow and ow.player
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

  local bx = entity.behaviorState
  if bx then
    bx.playerDetected = true
    bx.alertEmoteSpawned = false
    bx.chaseReady = false
    bx.battleStarted = false
    bx.battlePending = false
    bx.catchLocked = false
    bx.sightDisabled = true
    bx.alertAt = now()
    bx.state = Behavior.STATE.ALERT
  end
  -- Existing ! emote + chase pipeline (battle only on later contact).
  logic:_onAggressiveAlert(entity, record)
end

function OverworldCatching:cancelAll(reason)
  local ow = self:overworld()
  local entity = self.activeCapture and self.activeCapture.entity
  if entity and (entity.wildsCatchLocked or entity.wildsCatchPending
                 or entity.wildsCatchState == "pending"
                 or entity.wildsCatchState == "capturing") then
    self:_unlockTarget(entity)
    entity.visible = true
    entity.canTriggerBattle = true
  end
  self.projectile:cleanup(ow, self.logic and self.logic.voxel)
  self:_cancelMeter()
  RangePreview.clear()
  self.activeCapture = nil
  self.phase = "idle"
  self.throwHeld = false
  self.meterSource = nil
  if self.catchInput then
    -- Meter/preview already cleared above.
    self.catchInput:reset(reason or "cancelAll", false)
  end
  self:_catchLog("cancel: %s", tostring(reason or "?"))
  if Config.debug(self.mod) and reason then
    DebugLog.info(self.mod, "overworld catch cancelled (%s)", tostring(reason))
  end
end

function OverworldCatching:onOptionsChanged(payload)
  if not payload or payload.mod ~= self.mod.id then return end
  if payload.key == "overworld_catching" then
    self.hud:syncPipelineLevel()
    self:syncPipelineLevel()
    if payload.value == false then
      self:cancelAll("option off")
    end
  elseif payload.key == "enabled" and payload.value == false then
    self:cancelAll("wilds off")
  end
end

function OverworldCatching:onMapExited()
  self:cancelAll("map exited")
end

function OverworldCatching:pollInput(game, ow, dt)
  if not Config.overworldCatchingEnabled(self.mod) then
    if self.meter.active or self.phase ~= "idle" or self.activeCapture then
      self:cancelAll("option off")
    end
    return
  end

  -- Always advance projectile / wobble while active.
  self.projectile:update(game, ow, dt, self.logic and self.logic.voxel)

  if self.meter.active then
    self:_updateMeter(dt)
  end

  if not ow or not game then return end

  -- Cycle ball (edge-triggered only). Allowed whenever HUD can show.
  -- Desktop Q path — B+LEFT/RIGHT is handled by catchInput on input.step.
  local cycleDown = inputDown(game, CYCLE_KEYS)
  if cycleDown and not self.cycleHeld then
    if self:canShowHud(game, ow) and (self.phase == "idle" or self.phase == "metering") then
      self:cycleSelectedBall(game, 1)
    end
  end
  self.cycleHeld = cycleDown

  local throwDown = inputDown(game, THROW_KEYS)

  -- Modifier (B+A) owns release/cancel on input.step — do not treat missing C
  -- as a throw release while that path is metering.
  if self.phase == "metering" and self.meterSource == "modifier" then
    self.throwHeld = throwDown
    return
  end

  if self.phase == "metering" then
    if throwDown then
      -- keep metering (desktop C held)
    else
      -- desktop C release
      self.throwHeld = false
      self.meterSource = nil
      self:_releaseThrow(game, ow)
    end
    return
  end

  if throwDown and not self.throwHeld and self:canAcceptInput(game, ow) then
    if not self:anyBalls(game) then
      -- Edge-only feedback (do not spam while held).
      self:_pushNoBalls(game)
    else
      self.meterSource = "desktop"
      self:_beginMeter()
    end
  end
  self.throwHeld = throwDown
end

function OverworldCatching:step(ctx)
  local game = self:game()
  local ow = self:overworld()
  local t = now()
  local dt = t - (self._lastT or t)
  if dt < 0 then dt = 0 end
  if dt > 0.1 then dt = 0.1 end
  self._lastT = t
  if self.hud then
    self.hud._frame = (self.hud._frame or 0) + 1
  end
  self:pollInput(game, ow, dt)
  -- Flat ground preview pending (clears when not metering or when Voxel active).
  RangePreview.sync(self)
end

function OverworldCatching:register()
  if self._registered then return end
  local mod = self.mod
  self.hud:register()

  -- B-modifier path must run on input.step (before Overworld handleInput).
  if self.catchInput then
    self.catchInput:installHook(mod)
  end

  if not (mod.content and mod.content.render_pipelines
          and mod.content.render_pipelines.register) then
    return
  end
  local catching = self
  -- Flat green tiles: draw in OverworldState.drawWorld (native worldCanvas)
  -- BEFORE survey zoom blit. Never paint them from present() (post-zoom).
  RangePreview.installFlatWorldHook(catching)
  mod.content.render_pipelines:register(OverworldCatching.PIPELINE_ID, {
    label = "OW CATCH",
    levels = { "OFF", "ON" },
    priority = 2,
    available = function()
      return Config.overworldCatchingEnabled(mod) == true
        and Config.isEnabled(mod) == true
    end,
    present = function(canvas, ctx)
      catching:step(ctx)
      -- Reassert world-pass hook (mods / reloads); do not draw tiles here.
      RangePreview.installFlatWorldHook(catching)
      -- Ball HUD stays on present (UI/screen space, not world tiles).
      if catching.hud then
        return catching.hud:draw(canvas, ctx)
      end
      return canvas
    end,
  })
  self._registered = true
  self:syncPipelineLevel()
  self:hideFromEngineOptions()
end

function OverworldCatching:hideFromEngineOptions()
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or not Pipelines or type(Pipelines.rows) ~= "function" then return end
  if self._rowsPatched then return end
  local origRows = Pipelines.rows
  Pipelines.rows = function(game)
    local rows = origRows(game)
    local out = {}
    for _, row in ipairs(rows or {}) do
      if not (row and row.id == "pipeline:" .. OverworldCatching.PIPELINE_ID) then
        out[#out + 1] = row
      end
    end
    return out
  end
  self._rowsPatched = true
end

function OverworldCatching:syncPipelineLevel()
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or not Pipelines or not Pipelines.setLevel then return end
  if Config.overworldCatchingEnabled(self.mod) and Config.isEnabled(self.mod) then
    Pipelines.setLevel(OverworldCatching.PIPELINE_ID, 1)
  else
    Pipelines.setLevel(OverworldCatching.PIPELINE_ID, 0)
  end
  if self.hud then self.hud:syncPipelineLevel() end
end

-- Test / export helpers
OverworldCatching.Target = Target
OverworldCatching.CatchMath = CatchMath
OverworldCatching.RangePreview = RangePreview
OverworldCatching.CatchInput = CatchInput
OverworldCatching.THROW_KEYS = THROW_KEYS
OverworldCatching.CYCLE_KEYS = CYCLE_KEYS
OverworldCatching.METER_CYCLE_SECONDS = METER_CYCLE_SECONDS

return OverworldCatching
