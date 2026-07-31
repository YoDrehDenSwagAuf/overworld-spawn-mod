-- Frame tick for wild behaviour via a present-only render_pipeline.
-- Gen1Recomp has no world.tick mod event; NPC:update only runs for ow.npcs.
-- A present pipeline runs every drawn frame and is an established public path
-- (same mechanism as the debug HUD).
local V = ...
local Config = V.require("config")
local Behavior = V.require("behavior")
local DebugLog = V.require("debug_log")

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
  self._registered = false
  self._lastT = now()
  return self
end

function BehaviorTick:register()
  if self._registered then return end
  local mod = self.mod
  local tick = self

  mod.content.render_pipelines:register(BehaviorTick.PIPELINE_ID, {
    label = "OW SPAWN AI",
    levels = { "OFF", "ON" },
    priority = 1,
    available = function()
      return Config.isEnabled(mod) == true
    end,
    present = function(canvas, ctx)
      tick:step(ctx)
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
  if ow.emote or ow.engaging then
    -- Hold AI while an emotion bubble / trainer approach owns the world.
    -- Our own aggressive alert sets ow.emote; chase resumes after.
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
      -- Pace chase steps with nextActionAt.
      local bx = entity.behaviorState
      if bx and bx.chasing and t < (bx.nextActionAt or 0) then
        -- waiting
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
        elseif event == "contact" then
          logic:_startBattle(record)
        end
      end

      -- Keep record coords in sync after movement.
      if entity.cellX and entity.cellY then
        record.x, record.y = entity.cellX, entity.cellY
      end
    end
  end
end

return BehaviorTick
