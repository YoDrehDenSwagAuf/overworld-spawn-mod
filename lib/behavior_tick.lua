-- Frame tick for wild behaviour via a present-only render_pipeline.
-- Gen1Recomp has no world.tick mod event; NPC:update only runs for ow.npcs.
-- A present pipeline runs every drawn frame and is an established public path
-- (same mechanism as the debug HUD).
--
-- Hidden Idle rustle uses SpawnFx tile-capture blit (real grass art) in the
-- present pipeline with correct letterbox scale — not raw drawCellBottom in
-- window space (that was invisible).
local V = ...
local Config = V.require("config")
local Behavior = V.require("behavior")
local Movement = V.require("movement")
local VoxelAdapter = V.require("voxel_adapter")
local DebugLog = V.require("debug_log")
local HiddenIdle = V.require("hidden_idle")
local SpawnFx = V.require("spawn_fx")

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

  self.voxel:refreshPresence()

  if logic.spawnFx then
    logic.spawnFx:update(dt)
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

  for id, entity in pairs(logic.entities or {}) do
    local record = logic.spawns[id]
    if record and record.state == Config.STATE.AVAILABLE and entity then
      local okVoxel, voxelErr = pcall(function()
        self.voxel:updateEntity(entity)
      end)
      if not okVoxel then
        self.voxel:markFallback(entity, voxelErr)
      end

      local bx = entity.behaviorState
      local chasing = bx and (bx.chasing or bx.state == Behavior.STATE.CHASING
                              or bx.state == Behavior.STATE.CHASE_START)

      if Movement.isBusy(entity) and not (holdAi and bx
         and (bx.state == Behavior.STATE.ALERT
              or bx.state == Behavior.STATE.PLAYER_DETECTED)) then
        local done = Movement.update(entity, dt)
        if done then
          Movement.refreshGrassFlag(entity, self.mod)
        end
      end

      -- Per-entity spawn / reveal FX.
      local fxEvent = SpawnFx.updateEntity(entity, dt, {
        map = ow.map,
        spawnFx = logic.spawnFx,
      })
      if fxEvent == "reveal_visible" or fxEvent == "spawn_visible" then
        if HiddenIdle.isEntity(entity) then
          logic:_onHiddenRevealVisible(entity, record)
        else
          entity.hiddenBody = false
          entity.visibleSprite = true
          -- Attach now that the body may be posed safely.
          pcall(function() logic:_attach(entity) end)
        end
      elseif fxEvent == "reveal_battle" then
        logic:_onHiddenRevealBattle(entity, record)
      elseif fxEvent == "spawn_done" then
        entity.canTriggerBattle = true
        entity.hiddenBody = false
        pcall(function() logic:_attach(entity) end)
      end

      -- Hidden Idle periodic rustle (when not revealing).
      if HiddenIdle.isEntity(entity)
         and entity.hiddenIdle
         and entity.hiddenIdle.active
         and not entity.hiddenIdle.revealStarted
         and not entity.hiddenIdle.revealed then
        local hi = entity.hiddenIdle
        hi.rustleElapsed = (hi.rustleElapsed or hi.rustleTimer or 0) + dt
        local nextR = hi.nextRustle or 2.5
        if hi.rustleElapsed >= nextR then
          hi.rustleElapsed = 0
          hi.rustleTimer = 0
          hi.nextRustle = HiddenIdle.randomRustleDelay()
          entity.grassEffectActive = true
          entity.grassEffectUntil = now() + 0.35
          if logic.spawnFx then
            logic.spawnFx:grassRustle(ow.map, entity.cellX, entity.cellY, "small")
          end
          if bx then
            bx.shakePhase = (bx.shakePhase or 0) + 1
          end
        end
        if entity.grassEffectUntil and now() > entity.grassEffectUntil then
          entity.grassEffectActive = false
        end
      elseif HiddenIdle.isEntity(entity) then
        -- Reveal timeline owned by SpawnFx.updateEntity above.
      elseif not SpawnFx.canAct(entity) then
        -- Spawn pop in progress: no AI.
      elseif holdAi and not chasing then
        -- freeze
      else
        if bx and bx.chasing and Movement.isBusy(entity) then
          -- wait
        else
          local event = Behavior.tick(entity, {
            map = ow.map,
            entities = ow.entities,
            player = ow.player,
            dt = dt,
            sightRange = sight,
            reactionDelay = react,
            chaseStepSeconds = chaseStep,
          })
          if event == "alert" then
            logic:_onAggressiveAlert(entity, record)
          elseif event == "contact" or event == "battle_pending" then
            if SpawnFx.canBattle(entity) then
              logic:_startBattle(record)
            end
          end
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
        if entity.hiddenIdle then
          entity.hiddenIdle.cellX = entity.cellX
          entity.hiddenIdle.cellY = entity.cellY
        end
      end

      if entity.registeredInWorld and entity.sprite == nil
         and not entity.hiddenEncounter
         and not HiddenIdle.isEntity(entity) then
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
