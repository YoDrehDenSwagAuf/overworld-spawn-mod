-- Frame tick for wild behaviour via a present-only render_pipeline.
-- Gen1Recomp has no world.tick mod event; NPC:update only runs for ow.npcs.
-- A present pipeline runs every drawn frame and is an established public path
-- (same mechanism as the debug HUD).
--
-- Visual work (Movement interpolation, SpawnFx, animation sync) and
-- battle-return lifecycle checks run every rendered frame. AI decisions /
-- occupancy rebuild / cave rebuild checks run at a fixed AI rate so cost
-- does not scale with 144/240 Hz displays.
local V = ...
local Config = V.require("config")
local Behavior = V.require("behavior")
local Movement = V.require("movement")
local VoxelAdapter = V.require("voxel_adapter")
local DebugLog = V.require("debug_log")
local SpawnFx = V.require("spawn_fx")
local Surface = V.require("surface")
local WaterSpawn = V.require("water_spawn")
local SafariCompat = V.require("safari_compat")
local Grass = V.require("grass")
local PaletteWatch = V.require("palette_watch")
local GameCompat = V.require("game_compat")
local PerfStats = V.require("perf_stats")

local BehaviorTick = {}
BehaviorTick.__index = BehaviorTick

BehaviorTick.PIPELINE_ID = "owwild_behavior_tick"
-- Fixed AI decision rate. Visual interpolation stays per render frame.
BehaviorTick.AI_HZ = 30
BehaviorTick.AI_STEP = 1 / BehaviorTick.AI_HZ
BehaviorTick.AI_MAX_CATCHUP = 2
BehaviorTick.VOXEL_PRESENCE_INTERVAL = 0.5
BehaviorTick.PALETTE_POLL_INTERVAL = 0.1

local function now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

-- Shared Behavior.tick. On Gold, wrap in pcall so a chase primitive error
-- is logged with coordinates instead of taking down the overworld. The
-- high-level state machine stays in lib/behavior.lua.
local function tickBehavior(mod, entity, ctx, record, ow)
  if not GameCompat.isGen2(mod) then
    return Behavior.tick(entity, ctx)
  end
  local ok, eventOrErr = pcall(Behavior.tick, entity, ctx)
  local bx = entity and entity.behaviorState
  local state = bx and bx.state
  if state and entity._wildsAggroLogState ~= state then
    entity._wildsAggroLogState = state
    local player = ow and ow.player
    GameCompat.logGoldAggro(mod, {
      species = (record and record.species) or (entity and entity.species),
      state = state,
      entityX = entity and entity.cellX,
      entityY = entity and entity.cellY,
      playerX = player and player.cellX,
      playerY = player and player.cellY,
      mapId = ow and ow.map and ow.map.id,
      surface = entity and entity.surface,
      op = (state == Behavior.STATE.CHASING or state == Behavior.STATE.CHASE_START)
        and "stepToward" or "Behavior.tick",
    })
  end
  if not ok then
    local player = ow and ow.player
    GameCompat.logGoldAggroError(mod, {
      op = "Behavior.tick",
      err = eventOrErr,
      mapId = ow and ow.map and ow.map.id,
      species = (record and record.species) or (entity and entity.species),
      entityX = entity and entity.cellX,
      entityY = entity and entity.cellY,
      playerX = player and player.cellX,
      playerY = player and player.cellY,
      surface = entity and entity.surface,
      state = state,
    })
    return nil
  end
  return eventOrErr
end

local function occupancyFingerprint(ow)
  -- Numeric fingerprint (no string alloc). Player + trailers + NPCs.
  -- Wild cells are maintained incrementally via reserve/commit/cancel.
  local p = ow and ow.player
  local h = 0
  if p then
    h = (tonumber(p.cellX) or 0) * 73856093
      + (tonumber(p.cellY) or 0) * 19349663
      + (tonumber(p.targetX) or 0) * 83492791
      + (tonumber(p.targetY) or 0) * 483271
  end
  local trailers = ow and ow.pokepcTrailers
  if type(trailers) == "table" then
    h = h + (#trailers) * 9973
    for i = 1, #trailers do
      local t = trailers[i]
      if t then
        h = h + (tonumber(t.cellX) or 0) * (31 * i)
          + (tonumber(t.cellY) or 0) * (57 * i)
          + (tonumber(t.targetX) or 0) * (91 * i)
          + (tonumber(t.targetY) or 0) * (13 * i)
      end
    end
  end
  local npcs = ow and ow.npcs
  if type(npcs) == "table" then
    if npcs[1] ~= nil or #npcs > 0 then
      for i = 1, #npcs do
        local n = npcs[i]
        if n then
          h = h + (tonumber(n.cellX) or 0) * (101 + i)
            + (tonumber(n.cellY) or 0) * (103 + i)
            + (tonumber(n.targetX) or 0) * (107 + i)
            + (tonumber(n.targetY) or 0) * (109 + i)
        end
      end
    else
      local i = 0
      for _, n in pairs(npcs) do
        i = i + 1
        if n then
          h = h + (tonumber(n.cellX) or 0) * (101 + i)
            + (tonumber(n.cellY) or 0) * (103 + i)
        end
      end
    end
  end
  return h
end

function BehaviorTick.new(mod, logic)
  local self = setmetatable({}, BehaviorTick)
  self.mod = mod
  self.logic = logic
  self.voxel = VoxelAdapter.new(mod)
  self.perf = PerfStats.new(mod)
  self._registered = false
  self._lastT = now()
  self._aiAccum = 0
  self._voxelPresenceAt = 0
  self._palettePollAt = 0
  self._reuseCtx = nil
  self._occFp = nil
  return self
end

function BehaviorTick:register()
  if self._registered then return end
  local mod = self.mod
  local tick = self

  mod.content.render_pipelines:register(BehaviorTick.PIPELINE_ID, {
    label = "WILDS AI",
    levels = { "OFF", "ON" },
    priority = 1,
    available = function()
      return Config.isEnabled(mod) == true
        and Config.get(mod, "wilds_ai") ~= false
    end,
    present = function(canvas, ctx)
      tick:step(ctx)
      tick:drawFx(canvas, ctx)
      return canvas
    end,
  })

  self._registered = true
  self:syncPipelineLevel()
  self:hideFromEngineOptions()
end

--- The WILDS AI toggle lives in the Wilds of Kanto submenu, so drop the
-- redundant "WILDS AI" row from the engine's main Options → Display list
-- (every registered render pipeline otherwise gets a row there).  The
-- pipeline itself stays registered — it is the per-frame AI driver — only
-- its options row is filtered out.
function BehaviorTick:hideFromEngineOptions()
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or not Pipelines or type(Pipelines.rows) ~= "function" then return end
  if self._rowsPatched then return end
  local origRows = Pipelines.rows
  Pipelines.rows = function(game)
    local rows = origRows(game)
    local out = {}
    for _, row in ipairs(rows or {}) do
      if not (row and row.id == "pipeline:" .. BehaviorTick.PIPELINE_ID) then
        out[#out + 1] = row
      end
    end
    return out
  end
  self._rowsPatched = true
  self._origRows = origRows
end

function BehaviorTick:restoreEngineOptionsRow()
  if not self._rowsPatched then return end
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if ok and Pipelines and self._origRows then
    Pipelines.rows = self._origRows
  end
  self._rowsPatched = false
  self._origRows = nil
end

function BehaviorTick:syncPipelineLevel()
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or not Pipelines or not Pipelines.setLevel then return end
  if Config.isEnabled(self.mod) and Config.get(self.mod, "wilds_ai") ~= false then
    Pipelines.setLevel(BehaviorTick.PIPELINE_ID, 1)
  else
    Pipelines.setLevel(BehaviorTick.PIPELINE_ID, 0)
  end
end

-- Re-assert WILDS AI after OPTIONS / Pipelines.applyOptions restores saved
-- pipeline levels (typically OFF because the row is hidden). Cheap table write.
function BehaviorTick:ensurePipeline()
  self:syncPipelineLevel()
end

function BehaviorTick:_ensureReuseCtx()
  if self._reuseCtx then return self._reuseCtx end
  self._reuseCtx = {}
  return self._reuseCtx
end

function BehaviorTick:_fillBehaviorCtx(ctx, ow, game, logic, occupancy, cfg, safariActive, entity, extraDt)
  local caveCells = logic.caveReachability
    and logic.caveReachability.status ~= "FAILED"
    and logic.caveReachability.reachable
    or nil
  if entity and entity.caveScenery and entity.caveHomeCells then
    caveCells = entity.caveHomeCells
  elseif entity and entity.caveHomeCells then
    caveCells = entity.caveHomeCells
  end
  ctx.map = ow.map
  ctx.entities = ow.entities
  ctx.player = ow.player
  ctx.dt = extraDt
  ctx.sightRange = cfg.sight
  ctx.reactionDelay = cfg.react
  ctx.chaseStepSeconds = cfg.chaseStep
  ctx.waterSightRange = cfg.waterSight
  ctx.waterMonsEnabled = cfg.waterMons
  ctx.waterRegions = logic.waterRegions
  ctx.shoreMap = logic.shoreDistance
  ctx.landWaterPlayerMax = cfg.landWaterMax
  ctx.game = game
  ctx.logic = logic
  ctx.occupancy = occupancy
  ctx.mapId = ow.map and ow.map.id
  ctx.reachableCaveCells = caveCells
  ctx.suppressAggressive = entity and entity.caveScenery == true
  ctx.hasWaterSprite = cfg.hasWaterSprite
  ctx.safariActive = safariActive
  ctx.safariSightRange = SafariCompat.SIGHT_RANGE
  ctx.rng = nil
  return ctx
end

function BehaviorTick:step(ctx)
  if not Config.isEnabled(self.mod) then return end
  if Config.get(self.mod, "wilds_ai") == false then return end
  local logic = self.logic
  if not logic or not logic.state or not logic.state.initialized then return end

  local perf = self.perf
  local frameStart = perf:beginFrame()

  local t = now()
  local dt = t - (self._lastT or t)
  if dt < 0 then dt = 0 end
  if dt > 0.1 then dt = 0.1 end
  self._lastT = t

  local world = self.mod.world
  local ow = GameCompat.liveOverworld(self.mod, world and world.game)
  if not ow or not ow.map or not ow.player then
    perf:endFrame(frameStart)
    return
  end

  GameCompat.pollWildAlertEmote(ow)

  -- PaletteFX gate: poll slowly; flips are rare. Still applies immediately
  -- on the next poll after a COLORS mode change.
  if not self._paletteWatch then
    self._paletteWatch = PaletteWatch.new(self.mod, logic)
  end
  if (t - (self._palettePollAt or 0)) >= BehaviorTick.PALETTE_POLL_INTERVAL then
    self._palettePollAt = t
    self._paletteWatch:tick(world and world.game, ow)
  end

  -- Voxel presence / adapter install: rare. Throttle safety poll.
  do
    local vpStart = perf.enabled and now() or nil
    if (t - (self._voxelPresenceAt or 0)) >= BehaviorTick.VOXEL_PRESENCE_INTERVAL
       or self.voxel.present == nil then
      self._voxelPresenceAt = t
      self.voxel:refreshPresence()
      perf:count("voxelPresenceRefreshes", 1)
    else
      -- Keep voxelActive fresh without rescanning mods every frame.
      self.voxel.voxelActive = self.voxel:_probeVoxelActive()
    end
    perf:addMs("msVoxelPresence", vpStart)
  end

  if logic.spawnFx then
    local fxStart = perf.enabled and now() or nil
    logic.spawnFx:update(dt)
    perf:addMs("msFx", fxStart)
  end

  -- Battle-return reattach is a live-world lifecycle check, not an AI
  -- decision. Run every rendered frame so followers / Wilds / town Pokémon
  -- return immediately. Occupancy is rebuilt inside reconcile when guests
  -- actually reattach; dirty is also marked so the next AI tick cannot skip.
  if logic._pendingBattleReturnReconcile and not logic._battleReturnFlushedOnce then
    pcall(function() logic:flushBattleReturnReconcile("tick") end)
  end
  local ambient = self.mod.exports and self.mod.exports.ambient
  if ambient and ambient._pendingBattleReturnReconcile
     and not ambient._battleReturnFlushedOnce then
    pcall(function() ambient:onBattleEnded({ source = "tick" }) end)
  end
  local follower = logic.follower or (self.mod.exports and self.mod.exports.follower)
  if follower and follower.control
     and follower.control._battleReturnPhase == "pending" then
    pcall(function() follower:onBattleEnded({ source = "tick" }) end)
  end

  --------------------------------------------------------------------
  -- Fixed-rate AI decision accumulator (does not drive interpolation).
  --------------------------------------------------------------------
  self._aiAccum = (self._aiAccum or 0) + dt
  local aiSteps = 0
  local aiDt = 0
  while self._aiAccum >= BehaviorTick.AI_STEP
     and aiSteps < BehaviorTick.AI_MAX_CATCHUP do
    self._aiAccum = self._aiAccum - BehaviorTick.AI_STEP
    aiDt = aiDt + BehaviorTick.AI_STEP
    aiSteps = aiSteps + 1
  end
  -- Spiral-of-death guard after long pauses: drop leftover time.
  if self._aiAccum > BehaviorTick.AI_STEP * BehaviorTick.AI_MAX_CATCHUP then
    self._aiAccum = 0
  end
  local ranAi = aiSteps > 0
  if ranAi then
    perf:count("aiTicks", aiSteps)
  end

  local occupancy = logic.occupancy
  local game = world and world.game
  local safariActive = false
  local cfg = self._cfgSnapshot

  if ranAi then
    local aiBlockStart = perf.enabled and now() or nil

    -- Occupancy: rebuild only when dirty or player/trailer cells changed.
    -- Wild reserve/commit/cancel already update occupancy incrementally.
    -- Battle-return reattach marks dirty and may already have rebuilt once.
    if logic.rebuildOccupancy then
      local fp = occupancyFingerprint(ow)
      local dirty = logic._occupancyDirty == true or self._occFp ~= fp
        or logic.occupancy == nil
      if dirty then
        local occStart = perf.enabled and now() or nil
        occupancy = logic:rebuildOccupancy(ow)
        self._occFp = fp
        perf:addMs("msOccupancy", occStart)
        perf:count("occupancyRebuilds", 1)
      else
        occupancy = logic.occupancy
      end
    else
      occupancy = logic.occupancy
    end

    -- Optional Followers EX water sprite swap (once per state change).
    if logic.followersWater and logic.resolveWaterSprite then
      pcall(function()
        logic.followersWater:tick(game, ow, function(speciesId, shiny, form, opts)
          return logic:resolveWaterSprite(speciesId, shiny, form, opts)
        end)
      end)
    end

    safariActive = SafariCompat.isActive(game, ow, ow.map and ow.map.id)
    if not safariActive and logic.safariStatus == SafariCompat.STATUS.ACTIVE then
      for _, entity in pairs(logic.entities or {}) do
        if entity and entity.behaviorState and Behavior.isSafari(entity.behavior) then
          Behavior.clearSafariFlee(entity)
        end
      end
    end
    logic.safariStatus = SafariCompat.status(game, ow, ow.map and ow.map.id)

    -- Rebuild cave reachability when the player warps into a new component.
    if logic.caveReachability and ow.map and ow.player then
      local CaveReachability = V.require("cave_reachability")
      if CaveReachability.needsRebuild(logic.caveReachability, ow.map, ow.player) then
        logic.caveReachability = CaveReachability.build(ow.map, ow.player)
        logic._caveRebuilds = (logic._caveRebuilds or 0) + 1
        if logic.caveMode == "mixed" then
          local caveAll = Grass.caveCells(ow.map)
          local reachable, unreachable = CaveReachability.partitionCells(
            caveAll, ow.map, logic.caveReachability)
          logic.eligibleCache = reachable
          logic.caveSceneryCache = unreachable
        else
          local filtered = select(1, CaveReachability.filterCells(
            Grass.caveCells(ow.map), logic.caveReachability))
          logic.eligibleCache = filtered
          logic.caveSceneryCache = {}
        end
      end
    end

    -- Snapshot config once per AI tick (not per entity).
    cfg = {
      sight = Config.get(self.mod, "aggressive_sight_range")
        or Config.DEFAULTS.aggressive_sight_range,
      react = Config.get(self.mod, "aggressive_reaction_delay")
        or Config.DEFAULTS.aggressive_reaction_delay,
      chaseStep = Config.get(self.mod, "aggressive_step_seconds")
        or Config.DEFAULTS.aggressive_step_seconds,
      waterSight = Config.get(self.mod, "water_aggressive_sight_range")
        or Config.DEFAULTS.water_aggressive_sight_range,
      waterMons = Config.waterMons(self.mod),
      landWaterMax = Config.get(self.mod, "land_water_chase_player_max")
        or Config.DEFAULTS.land_water_chase_player_max,
      hasWaterSprite = function(e)
        return logic:_entityHasCompatibleWaterSprite(e)
      end,
    }
    self._cfgSnapshot = cfg
    self._safariActive = safariActive

    perf:addMs("msAi", aiBlockStart)
  else
    safariActive = self._safariActive == true
    if not cfg then
      cfg = {
        sight = Config.DEFAULTS.aggressive_sight_range,
        react = Config.DEFAULTS.aggressive_reaction_delay,
        chaseStep = Config.DEFAULTS.aggressive_step_seconds,
        waterSight = Config.DEFAULTS.water_aggressive_sight_range,
        waterMons = Config.waterMons(self.mod),
        landWaterMax = Config.DEFAULTS.land_water_chase_player_max,
        hasWaterSprite = function(e)
          return logic:_entityHasCompatibleWaterSprite(e)
        end,
      }
      self._cfgSnapshot = cfg
    end
  end

  local holdAi = false
  if ow.engaging then
    holdAi = true
  elseif ow.emote then
    holdAi = true
  end

  local reuseCtx = self:_ensureReuseCtx()
  local followerN = 0
  if ow.pokepcTrailers then followerN = #ow.pokepcTrailers end
  perf:sampleCounts(logic.entities, followerN)

  for id, entity in pairs(logic.entities or {}) do
    local record = logic.spawns[id]
    if record and record.state == Config.STATE.AVAILABLE and entity then
      if entity.wildsCatchLocked
         or entity.wildsCatchPending
         or entity.wildsCatchState == "capturing"
         or entity.wildsCatchState == "pending" then
        -- Keep occupancy; skip behavior / battle triggers.
      else
      do
        local veStart = perf.enabled and now() or nil
        local okVoxel, voxelErr = pcall(function()
          self.voxel:updateEntity(entity)
        end)
        if not okVoxel then
          self.voxel:markFallback(entity, voxelErr)
        end
        perf:addMs("msVoxelEntity", veStart)
      end

      -- Repair stuck movement before AI decides anything.
      if Movement.healBusy(entity) then
        if occupancy then occupancy:commitMove(entity) end
      end
      if entity.movementReservationCancelled and occupancy then
        occupancy:cancelMove(entity)
        entity.movementReservationCancelled = nil
      end
      SpawnFx.ensureProgress(entity)

      local bx = entity.behaviorState
      local chasing = bx and (bx.chasing or bx.state == Behavior.STATE.CHASING
                              or bx.state == Behavior.STATE.CHASE_START)
      local fleeing = bx and Behavior.isSafariFlee(bx.behavior)
        and (bx.fleeReady or bx.state == Behavior.STATE.FLEEING
             or bx.state == Behavior.STATE.FLEE_START
             or (bx.safariFlee and bx.safariFlee.active))
      local activeSpecial = chasing or fleeing

      -- Visual interpolation: every rendered frame (smooth at any FPS).
      local alreadyMoved = false
      if Movement.isBusy(entity) and not (holdAi and bx
         and (bx.state == Behavior.STATE.ALERT
              or bx.state == Behavior.STATE.PLAYER_DETECTED
              or bx.state == Behavior.STATE.PLAYER_NOTICED)) then
        local mvStart = perf.enabled and now() or nil
        local done = Movement.update(entity, dt)
        perf:addMs("msMovement", mvStart)
        alreadyMoved = true
        if done then
          if occupancy then occupancy:commitMove(entity) end
          Movement.refreshGrassFlag(entity, self.mod)
          -- Surface presentation is immediate. AI planning stays on the
          -- ~30 Hz path; pendingWaterEnter is left for Behavior.tick.
          if bx and bx.pendingWaterEnter
             and Behavior.commitPendingSurfaceTransition then
            local bctx = self:_fillBehaviorCtx(
              reuseCtx, ow, game, logic, occupancy, cfg, safariActive, entity, 0)
            pcall(Behavior.commitPendingSurfaceTransition, entity, bctx)
          end
        end
      end

      -- Per-entity spawn / reveal FX (visual; every frame).
      local fxEvent = SpawnFx.updateEntity(entity, dt, {
        map = ow.map,
        spawnFx = logic.spawnFx,
      })
      if fxEvent == "spawn_visible" then
        entity.hiddenBody = false
        entity.visibleSprite = true
        pcall(function() logic:_attach(entity) end)
      elseif fxEvent == "spawn_done" then
        if not entity.caveScenery then
          entity.canTriggerBattle = true
        else
          entity.canTriggerBattle = false
        end
        entity.hiddenBody = false
        pcall(function() logic:_attach(entity) end)
      end
      SpawnFx.ensureProgress(entity)

      local function runBehavior(extraDt)
        local bctx = self:_fillBehaviorCtx(
          reuseCtx, ow, game, logic, occupancy, cfg, safariActive, entity, extraDt)
        return tickBehavior(self.mod, entity, bctx, record, ow)
      end

      local function handleEvent(event)
        if event == "alert" then
          logic:_onAggressiveAlert(entity, record)
        elseif event == "entered_water" then
          record.behavior = entity.behavior
          record.surface = Surface.WATER
          record.waterEnteredByChase = true
          record.originSurface = entity.originSurface or record.originSurface
          record.encounterKind = record.encounterKind or "water"
          if entity.cellX and entity.cellY and logic.shoreDistance then
            record.shoreDistance = WaterSpawn.distanceAt(
              logic.shoreDistance, entity.cellX, entity.cellY)
            record.waterZone = WaterSpawn.zoneForDistance(record.shoreDistance)
            entity.shoreDistance = record.shoreDistance
            entity.waterZone = record.waterZone
          end
          local alreadyPresented = entity.surface == Surface.WATER
            and entity.spriteState == "water"
            and entity._wildsPresSpriteState == "water"
            and (entity.spriteKind == "swimming"
              or entity.spriteKind == "levitates"
              or entity.spriteKind == "levitate"
              or entity.spriteKind == "submerged"
              or entity.waterSpriteApplied)
          if logic.refreshEntitySprite and not alreadyPresented then
            pcall(logic.refreshEntitySprite, logic, entity, {
              reason = "entered_water",
              surface = Surface.WATER,
              spriteState = "water",
              game = game,
              forcePresentationRefresh = true,
            })
          end
          DebugLog.info(self.mod, "land→water chase id=%s species=%s",
                        tostring(id), tostring(record.species))
        elseif event == "contact" or event == "battle_pending" then
          if SpawnFx.canBattle(entity) and not entity.caveScenery then
            logic:_startBattle(record)
          end
        elseif event == "flee_start" or event == "flee_done" then
          record.behavior = entity.behavior
        end
      end

      if not SpawnFx.canAct(entity) then
        -- Spawn pop in progress: no wander/chase planning.
        -- Contact during an in-progress chase step still needs every frame.
        if bx and (bx.chasing or bx.state == Behavior.STATE.CHASING) then
          local event = runBehavior(0)
          handleEvent(event)
        end
      elseif holdAi and not activeSpecial then
        if bx and (bx.state == Behavior.STATE.ALERT
                   or bx.state == Behavior.STATE.PLAYER_NOTICED)
           and Behavior.isSafariFlee(bx.behavior) then
          -- Safari alert ownership: keep ticking while emote holds the world.
          local event = runBehavior(0)
          handleEvent(event)
        end
      elseif alreadyMoved or (Movement.isBusy(entity) and activeSpecial) then
        -- Mid-step: contact / interrupt checks every render frame (dt=0).
        -- Planning waits for the next free AI decision tick.
        local event = runBehavior(0)
        handleEvent(event)
      elseif ranAi then
        -- Decision tick: time-based wander / chase / flee planning.
        local event = runBehavior(aiDt)
        handleEvent(event)
      end

      if logic.render and logic.render.syncEntityAnimation then
        local animStart = perf.enabled and now() or nil
        local okAnim, animErr = pcall(logic.render.syncEntityAnimation,
                                      logic.render, entity, dt)
        if not okAnim then
          DebugLog.warn(self.mod, "animation sync failed for %s: %s",
                        tostring(id), tostring(animErr))
        end
        perf:addMs("msAnim", animStart)
      end

      if entity.cellX and entity.cellY then
        record.x, record.y = entity.cellX, entity.cellY
      end

      if entity.registeredInWorld and entity.sprite == nil
         and not entity.hiddenEncounter then
        self.voxel:markFallback(entity, "sprite became nil")
        logic:_detachFromWorld(entity)
        entity.render2DFallback = true
      end
      end -- else (not catch-locked)
    end
  end

  perf:endFrame(frameStart)
end

function BehaviorTick:drawFx(canvas, ctx)
  if not (love and love.graphics) then return end
  if Config.get(self.mod, "enable_grass_movement_effects") == false then return end
  local logic = self.logic
  local world = self.mod.world
  local ow = GameCompat.liveOverworld(self.mod, world and world.game)
  if not ow or not ow.map then return end

  if logic.spawnFx then
    logic.spawnFx:drawPresent(canvas, ctx, ow)
    logic.spawnFx:drawWaterSplashes(canvas, ctx, ow, logic.entities)
  end
end

-- Gold present pipelines should tick AI every frame. If present is skipped,
-- world.stepped still drives the same BehaviorTick (no second AI).
-- Keep a ~AI_STEP floor so world.stepped cannot double-run decisions when
-- present already advanced _lastT this frame.
function BehaviorTick:stepFromWorld(ctx)
  -- Recover if the present pipeline was wiped while settings were open.
  self:ensurePipeline()
  local t = now()
  if (t - (self._lastT or 0)) < (BehaviorTick.AI_STEP * 0.9) then
    return
  end
  self:step(ctx)
end

return BehaviorTick
