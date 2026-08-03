-- Frame tick for wild behaviour via a present-only render_pipeline.
-- Gen1Recomp has no world.tick mod event; NPC:update only runs for ow.npcs.
-- A present pipeline runs every drawn frame and is an established public path
-- (same mechanism as the debug HUD).
--
-- Also draws hidden-encounter effects (legacy markers + native Hidden Idle
-- grass rustle). Hidden entities stay out of ow.entities so Dramatic Shape
-- never poses a nil sprite.
local V = ...
local Config = V.require("config")
local Behavior = V.require("behavior")
local Movement = V.require("movement")
local VoxelAdapter = V.require("voxel_adapter")
local Tile = V.require("tile")
local DebugLog = V.require("debug_log")
local HiddenIdle = V.require("hidden_idle")

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
      tick:drawHiddenEffects(ctx)
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

local function emoteBelongsToWild(ow, logic)
  if not ow or not ow.emote or not ow.emote.npc then return false end
  local npc = ow.emote.npc
  if npc.overworldWildSpawn then return true end
  for _, entity in pairs(logic.entities or {}) do
    if entity == npc then return true end
  end
  return false
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

  local holdAi = false
  if ow.engaging then
    holdAi = true
  elseif ow.emote then
    -- Hold decision AI while any emotion bubble owns the world. Our own
    -- aggressive alert uses ow.emote; chase starts only via emote onDone.
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
      -- Keep entity presentation flags synced for Voxel overlay / HUD.
      local okVoxel, voxelErr = pcall(function()
        self.voxel:updateEntity(entity)
      end)
      if not okVoxel then
        self.voxel:markFallback(entity, voxelErr)
      end

      local bx = entity.behaviorState
      local chasing = bx and (bx.chasing or bx.state == Behavior.STATE.CHASING
                              or bx.state == Behavior.STATE.CHASE_START)

      -- Mid-step interpolation always advances (NPC-compatible), even during
      -- a foreign emote, so renderers never see a torn movement state.
      -- During OUR alert emote, movement is stopped by the ALERT state.
      if Movement.isBusy(entity) and not (holdAi and bx
         and (bx.state == Behavior.STATE.ALERT
              or bx.state == Behavior.STATE.PLAYER_DETECTED)) then
        local done = Movement.update(entity, dt)
        if done then
          Movement.refreshGrassFlag(entity, self.mod)
        end
      end

      -- Hidden Idle: rustle / reveal timeline (independent of holdAi).
      if HiddenIdle.isEntity(entity) then
        local event = HiddenIdle.tick(entity, dt)
        if event == "reveal_visible" then
          logic:_onHiddenRevealVisible(entity, record)
        elseif event == "reveal_battle" then
          logic:_onHiddenRevealBattle(entity, record)
        end
      elseif holdAi and not chasing then
        -- Freeze new decisions / sight while a bubble or trainer approach owns
        -- the world. Chase already in progress continues after our emote ends.
      else
        if bx and bx.chasing and Movement.isBusy(entity) then
          -- Wait for the current chase step to finish.
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
            logic:_startBattle(record)
          end
        end
      end

      -- Shared animation state for flat 2D and post-voxel 2D overlay.
      if logic.render and logic.render.syncEntityAnimation then
        local okAnim, animErr = pcall(logic.render.syncEntityAnimation,
                                      logic.render, entity, dt)
        if not okAnim then
          DebugLog.warn(self.mod, "animation sync failed for %s: %s",
                        tostring(id), tostring(animErr))
        end
      end

      -- Keep record coords in sync after movement (committed tile only).
      if entity.cellX and entity.cellY then
        record.x, record.y = entity.cellX, entity.cellY
      end

      -- Hidden markers must stay out of ow.entities; visible wilds stay in
      -- for simulation and are filtered only from DS billboard posing.
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

local function drawNativeGrassRustle(map, entity, camX, camY)
  if not map then return false end
  local renderer = map.renderer
  if not renderer or type(renderer.drawCellBottom) ~= "function" then
    return false
  end
  if not (love and love.graphics) then return false end
  local hi = entity.hiddenIdle or {}
  local active = entity.grassEffectActive == true
  if not active then return true end -- still "handled" (no custom art)
  local amp = hi.strongRustle and 2 or 1
  local phase = (entity.behaviorState and entity.behaviorState.shakePhase) or 0
  local ox = (phase % 2 == 0) and amp or -amp
  love.graphics.setColor(1, 1, 1, 1)
  pcall(renderer.drawCellBottom, renderer,
        entity.cellX, entity.cellY, (camX or 0) - ox, camY or 0)
  return true
end

function BehaviorTick:drawHiddenEffects(ctx)
  if not (love and love.graphics) then return end
  if Config.get(self.mod, "enable_grass_movement_effects") == false then return end
  local logic = self.logic
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if not ow or not ow.map then return end
  local cam = ow.camera
  local camX = cam and cam.x or 0
  local camY = cam and cam.y or 0
  for id, entity in pairs(logic.entities or {}) do
    local record = logic.spawns[id]
    if record and record.state == Config.STATE.AVAILABLE
       and entity and (entity.hiddenEncounter or not entity.visibleSprite
                      or HiddenIdle.isEntity(entity)) then
      if HiddenIdle.isEntity(entity) then
        -- Prefer native tall-grass redraw with a slight offset (no custom colour).
        drawNativeGrassRustle(ow.map, entity, camX, camY)
      elseif entity.behavior == Behavior.HIDDEN_GRASS
         or entity.surface == "GRASS" then
        local cell = Tile.CELL
        local x = math.floor((entity.px or (entity.cellX * cell)) - camX)
        local y = math.floor((entity.py or (entity.cellY * cell)) - camY)
        local active = entity.grassEffectActive == true
        local amp = active and 2 or 0
        local phase = (entity.behaviorState and entity.behaviorState.shakePhase) or 0
        local ox = (phase % 2 == 0) and amp or -amp
        love.graphics.setColor(0.25, 0.65, 0.28, active and 0.55 or 0.22)
        love.graphics.rectangle("fill", x + 3 + ox, y + 10, 10, 5)
        love.graphics.setColor(0.18, 0.5, 0.2, active and 0.7 or 0.3)
        love.graphics.rectangle("fill", x + 5 + ox, y + 8, 6, 3)
        love.graphics.setColor(1, 1, 1, 1)
      else
        local cell = Tile.CELL
        local x = math.floor((entity.px or (entity.cellX * cell)) - camX)
        local y = math.floor((entity.py or (entity.cellY * cell)) - camY)
        local active = entity.grassEffectActive == true
        local a = active and 0.45 or 0.18
        love.graphics.setColor(0.15, 0.12, 0.1, a)
        love.graphics.ellipse("fill", x + 8, y + 12, active and 6 or 4, active and 3 or 2)
        love.graphics.setColor(1, 1, 1, 1)
      end
    end
  end
end

return BehaviorTick
