-- Frame tick for wild behaviour via a present-only render_pipeline.
-- Gen1Recomp has no world.tick mod event; NPC:update only runs for ow.npcs.
-- A present pipeline runs every drawn frame and is an established public path
-- (same mechanism as the debug HUD).
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

local BehaviorTick = {}
BehaviorTick.__index = BehaviorTick

BehaviorTick.PIPELINE_ID = "owwild_behavior_tick"

local function now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

function BehaviorTick.new(mod, logic)
  local self = setmetatable({}, BehaviorTick)
  self.mod = mod
  self.logic = logic
  self.voxel = VoxelAdapter.new(mod)
  self._registered = false
  self._lastT = now()
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
    end,
    present = function(canvas, ctx)
      tick:step(ctx)
      tick:drawFx(canvas, ctx)
      return canvas
    end,
  })

  self._registered = true
  self:syncPipelineLevel()
end

function BehaviorTick:syncPipelineLevel()
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or not Pipelines or not Pipelines.setLevel then return end
  if Config.isEnabled(self.mod) then
    Pipelines.setLevel(BehaviorTick.PIPELINE_ID, 1)
  else
    Pipelines.setLevel(BehaviorTick.PIPELINE_ID, 0)
  end
end

function BehaviorTick:step(ctx)
  if not Config.isEnabled(self.mod) then return end
  local logic = self.logic
  if not logic or not logic.state or not logic.state.initialized then return end

  local t = now()
  local dt = t - (self._lastT or t)
  if dt < 0 then dt = 0 end
  if dt > 0.1 then dt = 0.1 end
  self._lastT = t

  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if not ow or not ow.map or not ow.player then return end

  -- PaletteFX COLORS mode watcher: on a redpp <-> non-redpp flip, re-resolve
  -- sprite art so the colored/-grayscale switch lands without a restart.
  if not self._paletteWatch then
    self._paletteWatch = PaletteWatch.new(self.mod, logic)
  end
  self._paletteWatch:tick(world and world.game, ow)

  self.voxel:refreshPresence()

  if logic.spawnFx then
    logic.spawnFx:update(dt)
  end

  local occupancy = logic.rebuildOccupancy and logic:rebuildOccupancy(ow) or logic.occupancy

  -- Optional Followers EX water sprite swap (once per state change).
  if logic.followersWater and logic.resolveWaterSprite then
    local game = world and world.game
    pcall(function()
      logic.followersWater:tick(game, ow, function(speciesId, shiny, form, opts)
        return logic:resolveWaterSprite(speciesId, shiny, form, opts)
      end)
    end)
  end

  local holdAi = false
  if ow.engaging then
    holdAi = true
  elseif ow.emote then
    holdAi = true
  end

  local sight = Config.get(self.mod, "aggressive_sight_range")
                or Config.DEFAULTS.aggressive_sight_range
  local react = Config.get(self.mod, "aggressive_reaction_delay")
                or Config.DEFAULTS.aggressive_reaction_delay
  local chaseStep = Config.get(self.mod, "aggressive_step_seconds")
                    or Config.DEFAULTS.aggressive_step_seconds

  local game = world and world.game
  local safariActive = SafariCompat.isActive(game, ow, ow.map and ow.map.id)
  -- Strip Safari flee state when the session ends mid-map.
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

  local function behaviorCtx(extraDt, entity)
    local caveCells = logic.caveReachability
      and logic.caveReachability.status ~= "FAILED"
      and logic.caveReachability.reachable
      or nil
    if entity and entity.caveScenery and entity.caveHomeCells then
      caveCells = entity.caveHomeCells
    elseif entity and entity.caveHomeCells then
      caveCells = entity.caveHomeCells
    end
    return {
      map = ow.map,
      entities = ow.entities,
      player = ow.player,
      dt = extraDt,
      sightRange = sight,
      reactionDelay = react,
      chaseStepSeconds = chaseStep,
      waterSightRange = Config.get(self.mod, "water_aggressive_sight_range")
        or Config.DEFAULTS.water_aggressive_sight_range,
      waterMonsEnabled = Config.waterMons(self.mod),
      waterRegions = logic.waterRegions,
      shoreMap = logic.shoreDistance,
      landWaterPlayerMax = Config.get(self.mod, "land_water_chase_player_max")
        or Config.DEFAULTS.land_water_chase_player_max,
      game = game,
      logic = logic,
      occupancy = occupancy,
      reachableCaveCells = caveCells,
      -- Scenery cannot aggro / battle across components.
      suppressAggressive = entity and entity.caveScenery == true,
      hasWaterSprite = function(e)
        return logic:_entityHasCompatibleWaterSprite(e)
      end,
      safariActive = safariActive,
      safariSightRange = SafariCompat.SIGHT_RANGE,
    }
  end

  for id, entity in pairs(logic.entities or {}) do
    local record = logic.spawns[id]
    if record and record.state == Config.STATE.AVAILABLE and entity then
      local okVoxel, voxelErr = pcall(function()
        self.voxel:updateEntity(entity)
      end)
      if not okVoxel then
        self.voxel:markFallback(entity, voxelErr)
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

      local alreadyMoved = false
      if Movement.isBusy(entity) and not (holdAi and bx
         and (bx.state == Behavior.STATE.ALERT
              or bx.state == Behavior.STATE.PLAYER_DETECTED
              or bx.state == Behavior.STATE.PLAYER_NOTICED)) then
        local done = Movement.update(entity, dt)
        alreadyMoved = true
        if done then
          if occupancy then occupancy:commitMove(entity) end
          Movement.refreshGrassFlag(entity, self.mod)
        end
      end

      -- Per-entity spawn / reveal FX.
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

      if not SpawnFx.canAct(entity) then
        -- Spawn pop in progress: no wander/chase planning.
        -- Contact during an in-progress chase step still needs the busy branch.
        if bx and (bx.chasing or bx.state == Behavior.STATE.CHASING) then
          local event = Behavior.tick(entity, behaviorCtx(0, entity))
          if event == "contact" or event == "battle_pending" then
            if SpawnFx.canBattle(entity) and not entity.caveScenery then
              logic:_startBattle(record)
            end
          end
        end
      elseif holdAi and not activeSpecial then
        -- freeze (Safari flee alert owns the emote; keep ticking that entity)
        if bx and (bx.state == Behavior.STATE.ALERT
                   or bx.state == Behavior.STATE.PLAYER_NOTICED)
           and Behavior.isSafariFlee(bx.behavior) then
          local event = Behavior.tick(entity, behaviorCtx(0, entity))
          if event == "alert" then
            logic:_onAggressiveAlert(entity, record)
          end
        end
      else
        local event = Behavior.tick(entity, behaviorCtx(alreadyMoved and 0 or dt, entity))
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
          -- Sprite already prepared before beginStep; refresh once more to sync.
          if logic.refreshEntitySprite then
            pcall(logic.refreshEntitySprite, logic, entity, {
              reason = "entered_water",
              surface = Surface.WATER,
              spriteState = "water",
              game = game,
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

      if logic.render and logic.render.syncEntityAnimation then
        local okAnim, animErr = pcall(logic.render.syncEntityAnimation,
                                      logic.render, entity, dt)
        if not okAnim then
          DebugLog.warn(self.mod, "animation sync failed for %s: %s",
                        tostring(id), tostring(animErr))
        end
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
    end
  end
end

function BehaviorTick:drawFx(canvas, ctx)
  if not (love and love.graphics) then return end
  if Config.get(self.mod, "enable_grass_movement_effects") == false then return end
  local logic = self.logic
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if not ow or not ow.map then return end

  if logic.spawnFx then
    logic.spawnFx:drawPresent(canvas, ctx, ow)
    logic.spawnFx:drawWaterSplashes(canvas, ctx, ow, logic.entities)
  end
end

return BehaviorTick
