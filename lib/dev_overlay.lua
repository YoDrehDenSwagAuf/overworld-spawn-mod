-- Read-only World debug overlay: compact behaviour + facing labels above
-- each visible wild Pokémon. Does not touch SpriteDefs, poses, collision,
-- or the native SpriteRenderer pipeline.
--
-- Drawn via a present-only render pipeline (behind UI, over the world).
local V = ...
local Config = V.require("config")
local Behavior = V.require("behavior")
local DebugLog = V.require("debug_log")

local DevOverlay = {}
DevOverlay.__index = DevOverlay

DevOverlay.PIPELINE_ID = "owwild_dev_overlay"

-- Behaviour display groups + RGBA colours.
local BEHAVIOUR_META = {
  [Behavior.IDLE_LOOK] = { label = "IDLE", color = { 0.85, 0.85, 0.85, 1 } },
  [Behavior.GRASS_WANDER] = { label = "WANDER", color = { 0.35, 0.55, 0.95, 1 } },
  [Behavior.AGGRESSIVE] = { label = "AGGRO", color = { 0.95, 0.25, 0.22, 1 } },
  [Behavior.WATER_IDLE] = { label = "WATER IDLE", color = { 0.25, 0.85, 0.85, 1 } },
  [Behavior.WATER_WANDER] = { label = "WATER WANDER", color = { 0.35, 0.30, 0.75, 1 } },
  [Behavior.WATER_AGGRESSIVE] = { label = "WATER AGGRO", color = { 0.95, 0.55, 0.15, 1 } },
  [Behavior.SAFARI_IDLE] = { label = "SAFARI IDLE", color = { 0.85, 0.85, 0.85, 1 } },
  [Behavior.SAFARI_WANDER] = { label = "SAFARI WANDER", color = { 0.35, 0.55, 0.95, 1 } },
  [Behavior.SAFARI_FLEE] = { label = "SAFARI FLEE", color = { 0.95, 0.70, 0.20, 1 } },
  IDLE = { label = "IDLE", color = { 0.85, 0.85, 0.85, 1 } },
  WANDER = { label = "WANDER", color = { 0.35, 0.55, 0.95, 1 } },
  AGGRESSIVE = { label = "AGGRO", color = { 0.95, 0.25, 0.22, 1 } },
  SAFARI_IDLE = { label = "SAFARI IDLE", color = { 0.85, 0.85, 0.85, 1 } },
  SAFARI_WANDER = { label = "SAFARI WANDER", color = { 0.35, 0.55, 0.95, 1 } },
  SAFARI_FLEE = { label = "SAFARI FLEE", color = { 0.95, 0.70, 0.20, 1 } },
}

local FACING_ARROW = {
  up = "↑ UP",
  down = "↓ DOWN",
  left = "← LEFT",
  right = "→ RIGHT",
}

local CELL = 16

function DevOverlay.behaviourMeta(behavior)
  if not behavior then
    return { label = "?", color = { 1, 1, 1, 1 } }
  end
  local hit = BEHAVIOUR_META[behavior]
  if hit then return hit end
  local upper = tostring(behavior):upper()
  if BEHAVIOUR_META[upper] then return BEHAVIOUR_META[upper] end
  if upper:find("WATER") and upper:find("AGGRO") then
    return BEHAVIOUR_META[Behavior.WATER_AGGRESSIVE]
  end
  if upper:find("WATER") and upper:find("WANDER") then
    return BEHAVIOUR_META[Behavior.WATER_WANDER]
  end
  if upper:find("WATER") then
    return BEHAVIOUR_META[Behavior.WATER_IDLE]
  end
  if upper:find("AGGRO") or upper:find("AGGRESSIVE") then
    return BEHAVIOUR_META[Behavior.AGGRESSIVE]
  end
  if upper:find("WANDER") then
    return BEHAVIOUR_META[Behavior.GRASS_WANDER]
  end
  return { label = upper, color = { 1, 1, 1, 1 } }
end

function DevOverlay.facingLabel(facing)
  facing = tostring(facing or "down"):lower()
  return FACING_ARROW[facing] or ("? " .. facing:upper())
end

function DevOverlay.stateSuffix(entity)
  local bx = entity and entity.behaviorState
  if not bx then return nil end
  local st = bx.state or bx.phase or bx.mode
  if not st then return nil end
  st = tostring(st):upper()
  if st == "" or st == "IDLE" or st == "LOOK" then return nil end
  -- Keep short: CHASING / ALERT / FLEEING …
  if #st > 10 then st = st:sub(1, 10) end
  return st
end

function DevOverlay.labelLines(entity)
  -- Ambient Town Pokémon: never show as WILD / AGGRO.
  if entity and entity.wildsAmbientPokemon then
    local beh = tostring(entity.ambientBehavior or "IDLE"):upper()
    if beh ~= "WANDER" then beh = "IDLE" end
    return "AMBIENT", beh, { 0.55, 0.85, 0.45, 1 }
  end

  local meta = DevOverlay.behaviourMeta(entity.behavior or entity.behaviour)
  local line1 = meta.label
  local facing = (entity.behaviorState and entity.behaviorState.facing)
              or entity.facing
              or "down"
  local line2 = DevOverlay.facingLabel(facing)
  local bx = entity and entity.behaviorState
  local beh = entity and (entity.behavior or entity.behaviour)

  -- Cave reachability tags (Reachable / Scenery).
  if entity and (entity.caveReachClass or entity.caveScenery) then
    local faceWord = tostring(facing or "down"):upper()
    local behShort = meta.label
    if entity.caveScenery
       or entity.caveReachClass == "UNREACHABLE_VALID" then
      return "CAVE · SCENERY",
             (behShort .. " · " .. faceWord),
             { 0.55, 0.40, 0.75, 1 }
    elseif entity.caveReachClass == "REACHABLE" then
      return "CAVE · REACHABLE",
             (behShort .. " · " .. faceWord),
             meta.color
    end
  end
  -- Safari flee overlay: SAFARI FLEE · LEFT / STATE: FLEEING / STEPS: 2/4
  if beh == Behavior.SAFARI_FLEE or beh == "SAFARI_FLEE" then
    local faceWord = tostring(facing or "down"):upper()
    line1 = "SAFARI FLEE · " .. faceWord
    local st = bx and bx.state or "IDLE"
    line2 = "STATE: " .. tostring(st):upper()
    local sf = bx and bx.safariFlee
    local line3 = nil
    if sf and (sf.active or (sf.fleeStepsTarget or 0) > 0) then
      line3 = ("STEPS: %d/%d"):format(
        sf.fleeStepsTaken or 0, sf.fleeStepsTarget or 0)
    end
    return line1, line2, meta.color, line3
  end
  local suffix = DevOverlay.stateSuffix(entity)
  if suffix then
    line1 = meta.label .. " · " .. suffix
  end
  return line1, line2, meta.color
end

function DevOverlay.new(mod, logic)
  local self = setmetatable({}, DevOverlay)
  self.mod = mod
  self.logic = logic
  self._registered = false
  return self
end

function DevOverlay:enabled()
  return Config.devOverlay(self.mod) == true
end

function DevOverlay:register()
  if self._registered then return end
  --- "WILDS OVERLAY" only appears in the pipeline menu when dev mode is on.
  if not Config.debug(self.mod) then self._registered = true; return end
  local mod = self.mod
  local overlay = self

  if not (mod.content and mod.content.render_pipelines
          and mod.content.render_pipelines.register) then
    return
  end

  mod.content.render_pipelines:register(DevOverlay.PIPELINE_ID, {
    label = "WILDS OVERLAY",
    levels = { "OFF", "ON" },
    priority = 40, -- behind UI pipelines, over world
    available = function()
      return overlay:enabled()
    end,
    present = function(canvas, ctx)
      if overlay:enabled() then
        overlay:draw(canvas, ctx)
      end
      return canvas
    end,
  })

  self._registered = true
  self:syncPipelineLevel()
  if Config.debug(mod) then
    DebugLog.info(mod, "dev overlay pipeline registered")
  end
end

function DevOverlay:syncPipelineLevel()
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or not Pipelines or not Pipelines.setLevel then return end
  if self:enabled() then
    Pipelines.setLevel(DevOverlay.PIPELINE_ID, 1)
  else
    Pipelines.setLevel(DevOverlay.PIPELINE_ID, 0)
  end
end

local function spriteHeight(entity)
  local h = CELL
  if entity._spriteH then return entity._spriteH end
  local sprite = entity.getWorldSprite and entity:getWorldSprite() or entity.sprite
  local def = sprite and sprite.def
  if def and def.image and love and love.graphics and love.graphics.newImage then
    -- Prefer cached frame height when present.
  end
  if entity.spriteHeight then return entity.spriteHeight end
  -- Water sink / spawn lift already baked into visualY; label above top of tile.
  return h
end

local function screenPosFlat(entity, cam)
  local camX = (cam and cam.x) or 0
  local camY = (cam and cam.y) or 0
  local px = entity.px or ((entity.cellX or 0) * CELL)
  local py = entity._lastVisualY or entity.py or ((entity.cellY or 0) * CELL)
  local h = spriteHeight(entity)
  local sx = px - camX + CELL / 2
  local sy = py - camY - 4 -- just above sprite top
  -- Account for taller sheets / water sink: lift further when visualY < py.
  if entity._lastLift and entity._lastLift > 0 then
    sy = sy - entity._lastLift
  end
  if h > CELL then
    sy = sy - (h - CELL)
  end
  return sx, sy
end

function DevOverlay:collectEntities(ctx)
  local list = {}
  local seen = {}
  local logic = self.logic
  if logic and logic.entities then
    for _, e in pairs(logic.entities) do
      if e and e.overworldWildSpawn and e.state ~= "removed"
         and not e.hiddenEncounter and e.visibleSprite ~= false then
        list[#list + 1] = e
        seen[e] = true
      end
    end
  end
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if ow and ow.entities then
    local haveWilds = #list > 0
    for _, e in ipairs(ow.entities) do
      if e and not seen[e] then
        if e.wildsAmbientPokemon then
          list[#list + 1] = e
          seen[e] = true
        elseif (not haveWilds) and e.overworldWildSpawn and e.state ~= "removed"
           and not e.hiddenEncounter and e.visibleSprite ~= false then
          list[#list + 1] = e
          seen[e] = true
        end
      end
    end
  end
  return list
end

function DevOverlay:draw(_canvas, ctx)
  if not (love and love.graphics and love.graphics.print) then return end
  local cam = ctx and ctx.cam
  if not cam then
    local world = self.mod.world
    local ow = world and world.overworld and world:overworld()
    cam = ow and ow.camera
  end

  local entities = self:collectEntities(ctx)
  for _, entity in ipairs(entities) do
    local line1, line2, color, line3 = DevOverlay.labelLines(entity)
    local sx, sy

    -- Prefer a projection helper when Dramatic Shape / First Person expose one.
    local project = ctx and ctx.project
    if type(project) == "function" then
      local wx = (entity.px or 0) + CELL / 2
      local wy = (entity._lastVisualY or entity.py or 0)
      local px, py = project(wx, wy)
      if px then
        sx, sy = px, py - 10
      end
    end
    if not sx then
      sx, sy = screenPosFlat(entity, cam)
    end

    love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
    local font = love.graphics.getFont and love.graphics.getFont()
    local tw = 0
    local lines = { line1, line2 }
    if line3 then lines[#lines + 1] = line3 end
    if font and font.getWidth then
      for _, ln in ipairs(lines) do
        tw = math.max(tw, font:getWidth(ln))
      end
    else
      for _, ln in ipairs(lines) do
        tw = math.max(tw, #ln * 6)
      end
    end
    local x = math.floor(sx - tw / 2)
    local y = math.floor(sy - 14)
    for i, ln in ipairs(lines) do
      love.graphics.print(ln, x, y + (i - 1) * 10)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- Optional inline draw from entity:draw (Flat 2D fallback when pipeline absent).
function DevOverlay.drawOnEntity(entity, camX, camY)
  if not entity or not entity.mod then return end
  if not Config.devOverlay(entity.mod) then return end
  if not (love and love.graphics and love.graphics.print) then return end
  local line1, line2, color = DevOverlay.labelLines(entity)
  local sx = (entity.px or 0) - (camX or 0) + CELL / 2
  local sy = (entity._lastVisualY or entity.py or 0) - (camY or 0) - 4
  if entity._lastLift and entity._lastLift > 0 then
    sy = sy - entity._lastLift
  end
  love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
  local font = love.graphics.getFont and love.graphics.getFont()
  local tw = 0
  if font and font.getWidth then
    tw = math.max(font:getWidth(line1), font:getWidth(line2))
  else
    tw = math.max(#line1, #line2) * 6
  end
  love.graphics.print(line1, math.floor(sx - tw / 2), math.floor(sy - 14))
  love.graphics.print(line2, math.floor(sx - tw / 2), math.floor(sy - 4))
  love.graphics.setColor(1, 1, 1, 1)
end

DevOverlay.BEHAVIOUR_META = BEHAVIOUR_META
DevOverlay.FACING_ARROW = FACING_ARROW

return DevOverlay
