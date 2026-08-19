-- Optional overworld Poké Ball catching for Wilds of Kanto.
-- Extends existing wild entity / battle / occupancy lifecycle — no second
-- encounter manager. Safari sessions disable throws (native Safari only).
local V = ...
local Config = V.require("config")
local Behavior = V.require("behavior")
local Movement = V.require("movement")
local SafariCompat = V.require("safari_compat")
local GameCompat = V.require("game_compat")
local CatchMath = V.require("catching/catch_math")
local Target = V.require("catching/target")
local Projectile = V.require("catching/projectile")
local RangePreview = V.require("catching/range_preview")
local BallHud = V.require("catching/hud")
local CatchInput = V.require("catching/input")
local CatchBindings = V.require("catching/bindings")
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

-- HUD uses full Ball art. World projectile uses throw/ canvases (22x22 source
-- nearest-neighbor packed as ~8x8 art in a 16x16 SpriteDef canvas).
local BALL_ASSET = {
  POKE_BALL = "assets/balls/poke_ball.png",
  GREAT_BALL = "assets/balls/great_ball.png",
  ULTRA_BALL = "assets/balls/ultra_ball.png",
  MASTER_BALL = "assets/balls/master_ball.png",
}
local BALL_ASSET_THROW = {
  POKE_BALL = "assets/balls/throw/poke_ball.png",
  GREAT_BALL = "assets/balls/throw/great_ball.png",
  ULTRA_BALL = "assets/balls/throw/ultra_ball.png",
  MASTER_BALL = "assets/balls/throw/master_ball.png",
}
OverworldCatching.BALL_ASSET = BALL_ASSET
OverworldCatching.BALL_ASSET_THROW = BALL_ASSET_THROW
-- 22x22 source art; SpriteRenderer canvas stays 16x16 with ~8x8 visible art.
OverworldCatching.THROW_SOURCE_PX = 22
OverworldCatching.THROW_CANVAS_PX = 16
OverworldCatching.THROW_ART_PX = 8
OverworldCatching.THROW_ART_OFFSET =
  math.floor((OverworldCatching.THROW_CANVAS_PX - OverworldCatching.THROW_ART_PX) / 2)

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
  local ok = pcall(GameCompat.presentText, mod, game, nil, msg, finish)
  if not ok then
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
  if self.mod.world and self.mod.world.game then return self.mod.world.game end
  return self.mod.game
end

function OverworldCatching:overworld()
  return GameCompat.catchWorld(self.mod, self:game())
end

function OverworldCatching:catchPlayer(game, ow)
  return GameCompat.catchPlayer(game or self:game(), ow or self:overworld())
end

function OverworldCatching:registerContent()
  if self._contentRegistered then return true end
  local mod = self.mod
  if not (mod.content and mod.content.sprites and mod.content.sprites.register) then
    return false, "sprites registry unavailable"
  end
  for _, ballType in ipairs(OverworldCatching.BALL_TYPES) do
    local id = "SPRITE_WILDS_BALL_" .. ballType
    local rel = BALL_ASSET_THROW[ballType] or BALL_ASSET[ballType]
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
  -- Throw canvases (16×16, ~8px opaque from 22×22 source) for world projectile.
  local rel = BALL_ASSET_THROW[ballType] or BALL_ASSET[ballType]
  if not rel then
    self._ballImages[ballType] = false
    return nil
  end
  if not (love and love.graphics and love.graphics.newImage) then
    self._ballImages[ballType] = false
    return nil
  end
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

--- HUD-only Ball image. Uses full-res assets (~13px opaque) so Catch HUD Size
--- scaling is visible. Independent cache from world projectile images.
function OverworldCatching:ballHudImage(ballType)
  self._ballHudImages = self._ballHudImages or {}
  if self._ballHudImages[ballType] ~= nil then
    return self._ballHudImages[ballType] or nil
  end
  local rel = BALL_ASSET[ballType] or BALL_ASSET_THROW[ballType]
  if not rel then
    self._ballHudImages[ballType] = false
    return nil
  end
  if not (love and love.graphics and love.graphics.newImage) then
    self._ballHudImages[ballType] = false
    return nil
  end
  local path = self.mod.assets and self.mod.assets.path and self.mod.assets:path(rel) or rel
  local ok, img = pcall(love.graphics.newImage, path)
  if (not ok or not img) and BALL_ASSET_THROW[ballType] then
    local throw = self.mod.assets and self.mod.assets.path
      and self.mod.assets:path(BALL_ASSET_THROW[ballType]) or BALL_ASSET_THROW[ballType]
    ok, img = pcall(love.graphics.newImage, throw)
  end
  if ok and img and img.setFilter then
    pcall(img.setFilter, img, "nearest", "nearest")
  end
  self._ballHudImages[ballType] = ok and img or false
  return ok and img or nil
end

function OverworldCatching:ballCount(game, ballType)
  return GameCompat.ballCount(game, ballType)
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
  return GameCompat.consumeBall(game, ballType)
end

function OverworldCatching:anyBalls(game)
  for _, ball in ipairs(OverworldCatching.BALL_TYPES) do
    if self:ballCount(game, ball) > 0 then return true end
  end
  return false
end

--- Stack / dialogue / battle / script guards (generation-specific via GameCompat).
function OverworldCatching:playerHasControl(game, ow)
  return GameCompat.catchPlayerHasControl(game, ow, self.logic)
end

function OverworldCatching:safariBlocks(game, ow)
  local mapId = ow and ow.map and ow.map.id
  local status = SafariCompat.status(game, ow, mapId)
  if status == SafariCompat.STATUS.ACTIVE then return true end
  return GameCompat.specialCatchSessionBlocks(game, ow) == true
end

function OverworldCatching:isBlockedByUi(game, ow)
  return GameCompat.catchUiBlocked(game, ow, self.logic)
end

function OverworldCatching:canShowHud(game, ow)
  if not Config.overworldCatchingEnabled(self.mod) then return false end
  if not Config.isEnabled(self.mod) then return false end
  local player = GameCompat.catchPlayer(game, ow)
  if not game or not ow or not player then return false end
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

function OverworldCatching:_goldCatchLog(fmt, ...)
  if not GameCompat.isGen2(self.mod, self:game()) then return end
  if not (Config.devOverlay(self.mod) or Config.debug(self.mod)) then
    return
  end
  local ok, msg = pcall(string.format, fmt, ...)
  print("[Wilds][Catch][Gold] " .. (ok and msg or tostring(fmt)))
end

--- Gold crash-bisect stages. Once per throw; not per-frame.
function OverworldCatching:_goldCatchStage(stage)
  if not GameCompat.isGen2(self.mod, self:game()) then return end
  print("[GoldCatch] " .. tostring(stage))
end

--- Registered throw SpriteDef (16×16 canvas, ~8×8 visible art). Never a sprite id only.
function OverworldCatching:ballSpriteDef(ballType)
  local id = "SPRITE_WILDS_BALL_" .. tostring(ballType)
  local sprites = self.mod and self.mod.content and self.mod.content.sprites
  if sprites and type(sprites.get) == "function" then
    local def = sprites:get(id)
    if type(def) == "table" and def.image then return def end
  end
  local game = self:game()
  local dataSprites = game and game.data and game.data.sprites
  if dataSprites and type(dataSprites[id]) == "table" and dataSprites[id].image then
    return dataSprites[id]
  end
  local rel = BALL_ASSET_THROW[ballType] or BALL_ASSET[ballType]
  if not rel then
    return nil
  end
  local path = self.mod.assets and self.mod.assets.path and self.mod.assets:path(rel) or rel
  return {
    id = id,
    image = path,
    frames = 1,
    walker = false,
    trueColor = true,
  }
end

local function ballId(selfOrType, ballType)
  if type(selfOrType) == "string" then
    return selfOrType
  end
  return ballType
end

--- Resolve the packaged throw-asset path for a stable internal Ball ID.
function OverworldCatching.ballThrowAsset(selfOrType, ballType)
  return BALL_ASSET_THROW[ballId(selfOrType, ballType)]
end

--- Resolve the packaged HUD-asset path for a stable internal Ball ID.
function OverworldCatching.ballHudAsset(selfOrType, ballType)
  return BALL_ASSET[ballId(selfOrType, ballType)]
end

function OverworldCatching:_refundBall(game, ballType)
  local save = game and game.save
  if not save or not ballType then return end
  save.inventory = save.inventory or {}
  save.inventory[ballType] = (tonumber(save.inventory[ballType]) or 0) + 1
end

function OverworldCatching:_startCatchProjectile(game, ow, ballType, opts)
  opts = opts or {}
  opts.spriteDef = opts.spriteDef or self:ballSpriteDef(ballType)
  local ok, err = self.projectile:startFlight(game, ow, opts)
  if ok then return true end
  self:_goldCatchStage("PROJECTILE_CREATE failed: " .. tostring(err))
  self:_refundBall(game, ballType)
  if self.activeCapture and self.activeCapture.entity then
    self:_unlockTarget(self.activeCapture.entity, { reattach = true, restoreVisible = true })
  end
  self.activeCapture = nil
  self.phase = "idle"
  return false
end

function OverworldCatching:_catchBlocker(game, ow)
  if not Config.overworldCatchingEnabled(self.mod) then return "CONFIG_DISABLED" end
  if not Config.isEnabled(self.mod) then return "WILDS_DISABLED" end
  if not game then return "NO_GAME" end
  if not GameCompat.supportsFeature("catching", self.mod, game) then
    return "CAPABILITY_DISABLED"
  end
  if not ow then return "NO_WORLD" end
  if not GameCompat.catchPlayer(game, ow) then return "NO_PLAYER" end
  if self:safariBlocks(game, ow) then return "SPECIAL_SESSION" end
  if self.logic and self.logic.pendingBattle then return "PENDING_BATTLE" end
  if self.projectile and self.projectile:isBusy() then return "PROJECTILE_BUSY" end
  if self:isBlockedByUi(game, ow) then return "UI_BLOCKED" end
  if not self:playerHasControl(game, ow) then return "NO_CONTROL" end
  return nil
end

--- Once / on blocker change (throttled). Never per-frame.
function OverworldCatching:_catchBootLog(game, ow)
  if not (Config.devOverlay(self.mod) or Config.debug(self.mod)) then
    return
  end
  local blocker = self:_catchBlocker(game, ow)
  local t = now()
  if self._bootLogged and self._bootBlocker == blocker then
    return
  end
  if self._bootLogged and (t - (self._bootLogAt or 0)) < 2 then
    return
  end
  self._bootLogged = true
  self._bootBlocker = blocker
  self._bootLogAt = t

  local modWorld = self.mod and self.mod.world
  local apiOw
  if modWorld and type(modWorld.overworld) == "function" then
    local ok, result = pcall(modWorld.overworld, modWorld)
    if ok then apiOw = result end
  end
  local worldPlayer = game and game.world and game.world.player
  local player = GameCompat.catchPlayer(game, ow)
  print(string.format(
    "[Wilds][CatchBoot] generation=%s capability=%s owCatch=%s wilds=%s game=%s mod.world=%s mod.world:overworld()=%s game.world=%s ow=%s ow.player=%s game.world.player=%s game.world.playerState=%s canShowHud=%s canAcceptInput=%s blocker=%s",
    tostring(GameCompat.generation(self.mod, game)),
    tostring(GameCompat.supportsFeature("catching", self.mod, game)),
    tostring(Config.overworldCatchingEnabled(self.mod)),
    tostring(Config.isEnabled(self.mod)),
    tostring(game ~= nil),
    tostring(modWorld ~= nil),
    tostring(apiOw ~= nil),
    tostring(game and game.world ~= nil),
    tostring(ow ~= nil),
    tostring(ow and ow.player ~= nil),
    tostring(worldPlayer ~= nil),
    tostring(game and game.world and game.world.playerState),
    tostring(self:canShowHud(game, ow)),
    tostring(self:canAcceptInput(game, ow)),
    tostring(blocker or "NONE")
  ))
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

-- Desktop throw/cycle keys come from CatchBindings (defaults C / Q).
-- Engine/mod aliases stay as fallbacks so existing mappings still work.
-- Logical controller/touch combos live in CatchInput (defaults B+A / B+Dpad).
local THROW_ALIASES = { "throw_ball", "ow_catch_throw" }
local CYCLE_ALIASES = { "cycle_ball", "ow_catch_cycle" }
-- Compat: default desktop aliases (tests / docs). Live keys are resolved below.
local THROW_KEYS = { CatchBindings.DEFAULT_THROW_KEY, "throw_ball", "ow_catch_throw" }
local CYCLE_KEYS = { CatchBindings.DEFAULT_CYCLE_KEY, "cycle_ball", "ow_catch_cycle" }

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
  if GameCompat.isGen2(self.mod, self:game()) then
    print("[Wilds][GoldCatch] beginMeter ENTER")
    self:_goldCatchStage("METER")
    self:_goldCatchFrameLog("beginMeter")
  end
  self.meter.active = true
  self.meter.t = 0
  self.meter.power = METER_MIN
  self.meter.rising = true
  self.phase = "metering"
  RangePreview._goldSyncTraced = nil
  RangePreview._goldUnsupportedTraced = nil
  RangePreview._goldWorldTraced = nil
  RangePreview._goldVoxelTraced = nil
  RangePreview._goldCellsTraced = nil
  self._goldStepTraced = nil
  self:_catchLog("begin meter")
  self:_catchLog("phase=metering source=%s", tostring(self.meterSource or "desktop"))
  if GameCompat.isGen2(self.mod, self:game()) then
    print("[Wilds][GoldCatch] beginMeter OK")
  end
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
  self:_goldCatchStage("RELEASE")
  local power = self.meter.power or METER_MIN
  self:_cancelMeter()
  RangePreview.clear()

  local ballType = self:getSelectedBall(game)
  if self:ballCount(game, ballType) <= 0 then
    pushText(game, self.mod, "You don't have any\nPOKé BALLs!")
    self.phase = "idle"
    return
  end

  local player = GameCompat.catchPlayer(game, ow)
  if not player then
    self:_catchLog("release aborted NO_PLAYER")
    self.phase = "idle"
    return
  end
  local px, py = GameCompat.playerCell(game, ow)
  px, py = px or player.cellX, py or player.cellY
  local hit = Target.scanThrowPath(self.logic, ow, player, power)
  self:_goldCatchStage("TARGET_SCAN")
  local Hit = Target.HitKind
  local facing = hit.facing or Target.facingOf(player)
  local wildCount = 0
  if self.logic and self.logic.entities then
    for _, ent in pairs(self.logic.entities) do
      if Target.isCatchableWild(ent) then wildCount = wildCount + 1 end
    end
  end
  self:_catchLog("release")
  self:_catchLog("player cell=(%s,%s) facing=%s power=%.2f wilds=%d",
    tostring(px), tostring(py), tostring(facing), power, wildCount)
  self:_catchLog("target=%s distance=%s kind=%s",
    tostring(hit.entity and (hit.entity.species or hit.entity.wildSpecies) or "none"),
    tostring(hit.distance),
    tostring(hit.kind))

  -- Consume on commit (hit, easter egg, or miss).
  if not self:consumeBall(game, ballType) then
    pushText(game, self.mod, "You don't have any\nPOKé BALLs!")
    self.phase = "idle"
    return
  end
  self:_goldCatchLog("consumed=true")
  self:_goldCatchLog("inventory count=%s", tostring(self:ballCount(game, ballType)))
  self:_goldCatchStage("BALL_CONSUMED")

  local landX, landY = Projectile.landCell(px, py, facing, power)
  self:_catchLog("throw released power=%.2f land=(%d,%d) facing=%s first=%s@%s",
    power, landX, landY, tostring(facing), tostring(hit.kind), tostring(hit.distance))

  local ballImage = self:ballImage(ballType)

  local function startMissFlight(feedback)
    self.phase = "flying"
    if feedback then self.hud:showFeedback(feedback, 0.7) end
    if not self:_startCatchProjectile(game, ow, ballType, {
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
    }) then
      return
    end
    self:_catchLog("projectile")
    self:_catchLog("projectile started (miss)")
  end

  -- Easter eggs: first physical Town/NPC along the throw distance.
  if hit.kind == Hit.NPC or hit.kind == Hit.TOWN_MON then
    self.phase = "flying"
    self._lastDebug = {
      target = hit.kind, ball = ballType, dist = hit.distance,
      power = string.format("%.2f", power), quality = "easter", angle = nil,
    }
    if not self:_startCatchProjectile(game, ow, ballType, {
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
    }) then
      return
    end
    self:_catchLog("projectile")
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

  local species = GameCompat.captureSpecies(entity, record) or "PIDGEY"
  local level = GameCompat.captureLevel(entity, record) or 5

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

  if not self:_startCatchProjectile(game, ow, ballType, {
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
  }) then
    return
  end
  self:_catchLog("projectile")
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
  self:_goldCatchStage("IMPACT")
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

  local nativeRate, targetDef = GameCompat.catchRate(game, species)
  targetDef = targetDef or { catchRate = nativeRate, name = species }
  local rateOverride = CatchMath.effectiveCatchRate(nativeRate, level, quality, angle)
  self:_goldCatchStage("CATCH_RATE")

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
  self:_goldCatchLog("inventory count=%s", tostring(self:ballCount(game, ballType)))
  -- Ball multipliers live inside the generation Catching API.
  -- Do not pre-multiply them into rateOverride.
  caught, shakes = GameCompat.attemptCatch(game, {
    ballType = ballType,
    mon = tempMon,
    def = targetDef,
    rng = rng,
    rateOverride = rateOverride,
    species = species,
    level = level,
  })
  self:_goldCatchStage("ATTEMPT")
  self:_catchLog("result caught=%s shakes=%s", tostring(caught), tostring(shakes))
  self:_goldCatchLog("attempt=%s", tostring(caught == true))

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
  self:_goldCatchStage("WOBBLE")
end

function OverworldCatching:_resolveCapture(game, ow, caught)
  self:_goldCatchStage("RESOLVE")
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
    -- species is the Wilds entity/record id — never a canonical asset id.
    local newMon, createErr = GameCompat.createCaughtPokemon(game, species, level, {
      shiny = entity and entity.shiny,
      variant = entity and entity.variant,
      entity = entity,
    })
    if not newMon then
      -- Never invent a fake party member. Fail safely and keep the wild.
      self:_catchLog("create failed err=%s — wild remains", tostring(createErr))
      self:_goldCatchLog("created species=nil")
    else
      self:_goldCatchLog("created species=%s", tostring(newMon.species or species))
      local msg = "All right!\n" .. tostring(speciesName) .. " was caught!"
      local result = GameCompat.giveCaughtPokemon(game, newMon, {
        species = species,
        entity = entity,
      }) or {}
      local dexOk = GameCompat.markSpeciesCaught(game, species, newMon)
      self:_goldCatchLog("destination=%s", tostring(result.destination or "none"))
      self:_goldCatchLog("dex updated=%s", tostring(dexOk == true))
      if result.destination == "box" then
        if result.boxNum then
          msg = msg .. "\fTransferred to\nBox " .. tostring(result.boxNum) .. "."
        elseif result.boxFull then
          msg = msg .. "\fBox is full!"
        end
      end

      -- Stay hidden; despawn via Wilds canonical path (no reappear).
      if self.logic and entity and entity.id then
        self.logic:_despawn(entity.id, true)
        self:_goldCatchLog("entity removed=true")
      else
        self:_unlockTarget(entity, { reattach = false, restoreVisible = false })
        self:_goldCatchLog("entity removed=true")
      end
      self.activeCapture = nil
      self.phase = "idle"
      pushText(game, self.mod, msg)
      return
    end
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
  local player = GameCompat.catchPlayer(self:game(), ow)
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
  elseif CatchBindings.isBindingOption(payload.key) then
    -- Live rebind: drop an in-progress meter/preview without consuming a Ball.
    if self.meter and self.meter.active then
      self:_cancelMeter()
    end
    self:_clearPreview()
    self.meterSource = nil
    self.throwHeld = false
    self.cycleHeld = false
    if self.catchInput then
      self.catchInput:reset("options_changed", false)
    end
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

  if not ow or not game then
    self:_catchBootLog(game, ow)
    return
  end
  self:_catchBootLog(game, ow)

  -- Cycle ball (edge-triggered only). Allowed whenever HUD can show.
  -- Desktop key path — logical LEFT/RIGHT combos are handled by catchInput.
  -- Resolve live so Catch Key / Ball Switch Key apply without restart.
  local cycleKey = CatchBindings.keyboardCycle(self.mod)
  local cycleDown = inputDown(game, { cycleKey, CYCLE_ALIASES[1], CYCLE_ALIASES[2] })
  if cycleDown and not self.cycleHeld then
    if self:canShowHud(game, ow) and (self.phase == "idle" or self.phase == "metering") then
      self:cycleSelectedBall(game, 1)
    end
  end
  self.cycleHeld = cycleDown

  local throwKey = CatchBindings.keyboardThrow(self.mod)
  local throwDown = inputDown(game, { throwKey, THROW_ALIASES[1], THROW_ALIASES[2] })

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

  if throwDown and not self.throwHeld then
    self:_catchLog("input desktop throw")
    if self:canAcceptInput(game, ow) then
      if not self:anyBalls(game) then
        -- Edge-only feedback (do not spam while held).
        self:_pushNoBalls(game)
      else
        self.meterSource = "desktop"
        self:_beginMeter()
      end
    end
  end
  self.throwHeld = throwDown
end

function OverworldCatching:pipelineSnapshot()
  local snap = { level = nil, eligible = nil }
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if ok and type(Pipelines) == "table" then
    if type(Pipelines.level) == "function" then
      local okL, level = pcall(Pipelines.level, OverworldCatching.PIPELINE_ID)
      if okL then snap.level = level end
    end
    if type(Pipelines.eligible) == "function" then
      local okE, elig = pcall(Pipelines.eligible, OverworldCatching.PIPELINE_ID)
      if okE then snap.eligible = elig end
    end
  end
  return snap
end

function OverworldCatching:_goldCatchFrameLog(reason)
  if not GameCompat.isGen2(self.mod, self:game()) then return end
  local pipe = self:pipelineSnapshot()
  print(string.format(
    "[Wilds][GoldCatchFrame] %s pipelineLevel=%s pipelineEligible=%s catchStepFrames=%s hudDrawFrames=%s meterPower=%s phase=%s",
    tostring(reason or "tick"),
    tostring(pipe.level),
    tostring(pipe.eligible),
    tostring(self._catchUpdateCount or 0),
    tostring(self.hud and self.hud._hudDrawCount or 0),
    tostring(self.meter and self.meter.power),
    tostring(self.phase)))
end

--- One owner for meter / projectile / wobble / desktop C. Not the render pipeline.
-- input.step is the shared Gen1+Gold fixed-step seam. Pipeline present may
-- call this as a fallback; the tick guard prevents double-speed.
function OverworldCatching:update(dt, source)
  source = source or "unknown"
  if source == "input.step" then
    self._logicTick = (self._logicTick or 0) + 1
  end
  local tick = self._logicTick or 0
  if tick > 0 and self._lastLogicTick == tick then
    self._skippedDoubleUpdate = (self._skippedDoubleUpdate or 0) + 1
    return false
  end
  if tick > 0 then
    self._lastLogicTick = tick
  end

  if dt == nil then
    local t = now()
    dt = t - (self._lastT or t)
    self._lastT = t
  else
    self._lastT = now()
  end
  if dt < 0 then dt = 0 end
  if dt > 0.1 then dt = 0.1 end

  self._catchUpdateCount = (self._catchUpdateCount or 0) + 1

  local game = self:game()
  local ow = self:overworld()
  self:pollInput(game, ow, dt)
  RangePreview.sync(self)

  if self.meter.active and GameCompat.isGen2(self.mod, game) then
    if not self._goldStepTraced then
      self._goldStepTraced = true
      print("[Wilds][GoldCatch] step meter active")
    end
    local t = now()
    if not self._goldFrameLogAt or (t - self._goldFrameLogAt) >= 1 then
      self._goldFrameLogAt = t
      self:_goldCatchFrameLog("meter")
    end
  end
  return true
end

function OverworldCatching:installUpdateHook(mod)
  if self._updateHookInstalled then return true end
  if not (mod and mod.hooks and mod.hooks.wrap) then
    return false
  end
  local catching = self
  -- Outer wrap: CatchInput (B+A) runs inside nextFn, then logic advances once.
  mod.hooks:wrap("input.step", function(nextFn, game, dt)
    if nextFn then nextFn(game, dt) end
    catching:update(dt or (1 / 60), "input.step")
  end)
  self._updateHookInstalled = true
  return true
end

function OverworldCatching:installGoldPresentHook(mod)
  if self._goldPresentHookInstalled then return true end
  if not (mod and mod.hooks and mod.hooks.wrap) then
    return false
  end
  local catching = self
  mod.hooks:wrap("render.hud", function(nextFn, game, viewport)
    if nextFn then nextFn(game, viewport) end
    if not GameCompat.isGen2(catching.mod, game or catching:game()) then
      return
    end
    catching:presentGold(game, viewport)
  end)
  self._goldPresentHookInstalled = true
  return true
end

--- Gold screen-space presentation. HUD in logical 160×144 (top-left origin)
-- projected through Game2:viewport; range tiles in window space using World
-- camera * zoomScale. Exactly once per render.hud.
function OverworldCatching:presentGold(game, viewport)
  RangePreview.drawGoldOverlay(self)
  if self.hud then
    self.hud:drawScreen(viewport)
  end
end

function OverworldCatching:step(ctx)
  -- Fallback for unit tests / Gen1 present if input.step has not run.
  self:update(nil, "pipeline")
end

function OverworldCatching:register()
  if self._registered then return end
  local mod = self.mod
  self.hud:register()

  -- B-modifier path must run on input.step (before Overworld handleInput).
  if self.catchInput then
    self.catchInput:installHook(mod)
  end
  -- Catch logic (meter / projectile / wobble) also lives on input.step so a
  -- Gold pipeline reset cannot freeze power at 1.
  self:installUpdateHook(mod)
  self:installGoldPresentHook(mod)

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
      catching._catchPresentCount = (catching._catchPresentCount or 0) + 1
      catching:step(ctx)
      if GameCompat.isGen2(catching.mod, catching:game()) then
        -- Gold HUD + range overlay are render.hud, not this present pass.
        return canvas
      end
      -- Reassert world-pass hook (mods / reloads); do not draw tiles here.
      -- Gen1 Ball HUD is owned solely by owwild_ball_hud — do not paint here.
      RangePreview.installFlatWorldHook(catching)
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
OverworldCatching.CatchBindings = CatchBindings
OverworldCatching.THROW_KEYS = THROW_KEYS
OverworldCatching.CYCLE_KEYS = CYCLE_KEYS
OverworldCatching.METER_CYCLE_SECONDS = METER_CYCLE_SECONDS

return OverworldCatching
