-- Per-entity spawn animations for visible grass and water Pokémon.
-- No periodic grass rustle, no Hidden Idle reveal, no tile-capture FX.
local V = ...
local Tile = V.require("tile")

local SpawnFx = {}
SpawnFx.__index = SpawnFx

SpawnFx.KIND = {
  GRASS = "grass",
  WATER = "water",
}

local CELL = Tile.CELL

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Visible grass: body hidden briefly → appear with small lift → act.
local GRASS_SPAWN = {
  duration = 0.45,
  bodyAt = 0.10,
  actAt = 0.45,
}

local WATER_SPAWN = {
  duration = 0.60,
  bodyAt = 0.18,
  settleAt = 0.45,
  actAt = 0.60,
}

SpawnFx.GRASS_SPAWN = GRASS_SPAWN
SpawnFx.WATER_SPAWN = WATER_SPAWN

function SpawnFx.new(mod)
  local self = setmetatable({}, SpawnFx)
  self.mod = mod
  return self
end

function SpawnFx.begin(entity, kind, opts)
  if not entity then return nil end
  opts = opts or {}
  kind = kind or SpawnFx.KIND.GRASS
  local profile = GRASS_SPAWN
  if kind == SpawnFx.KIND.WATER then
    profile = WATER_SPAWN
  end
  entity.spawnFx = {
    kind = kind,
    elapsed = 0,
    duration = opts.duration or profile.duration,
    bodyVisibleAt = opts.bodyVisibleAt or profile.bodyAt,
    actAt = opts.actAt or profile.actAt or profile.duration,
    settleAt = profile.settleAt,
    done = false,
    bodyShown = false,
    splashFired = false,
  }
  entity.hiddenBody = true
  entity.canTriggerBattle = false
  entity._spawnLiftPx = 0
  return entity.spawnFx
end

function SpawnFx.bodyVisible(entity)
  if not entity then return true end
  SpawnFx.ensureProgress(entity)
  if entity.hiddenBody == true then
    return false
  end
  local fx = entity.spawnFx
  if fx and not fx.done and not fx.bodyShown then
    return false
  end
  -- Legacy HIDDEN_GRASS / HIDDEN_CAVE markers (not Hidden Idle).
  if entity.hiddenEncounter and entity.visibleSprite == false then
    return false
  end
  return true
end

function SpawnFx.visualLift(entity)
  if not entity then return 0 end
  return tonumber(entity._spawnLiftPx or entity._revealHopPx) or 0
end

-- Fail-safe: never leave an entity frozen because FX stalled.
function SpawnFx.ensureProgress(entity)
  if not entity then return end
  local fx = entity.spawnFx
  if not fx then
    if entity.canTriggerBattle == nil then
      entity.canTriggerBattle = true
    end
    return
  end
  if fx.done then return end
  local dur = tonumber(fx.duration) or 0.6
  local actAt = tonumber(fx.actAt) or dur
  local elapsed = tonumber(fx.elapsed) or 0
  local tolerance = 0.35
  -- Unlock as soon as actAt is reached, or after duration+tolerance.
  if elapsed >= actAt or elapsed >= dur + tolerance or dur <= 0 then
    fx.done = true
    fx.bodyShown = true
    entity.hiddenBody = false
    entity.canTriggerBattle = true
    entity.hopping = false
    if fx.kind == SpawnFx.KIND.WATER then
      entity._spawnLiftPx = tonumber(entity.surfaceVisualOffset) or 2
    else
      entity._spawnLiftPx = 0
      entity._revealHopPx = 0
    end
  end
end

function SpawnFx.canAct(entity)
  if not entity then return true end
  SpawnFx.ensureProgress(entity)
  local fx = entity.spawnFx
  if not fx then return true end
  if fx.done then return true end
  return false
end

function SpawnFx.canBattle(entity)
  if not entity then return false end
  SpawnFx.ensureProgress(entity)
  if entity.canTriggerBattle == false then return false end
  local fx = entity.spawnFx
  if fx and not fx.done then return false end
  return true
end

function SpawnFx.debugState(entity)
  local fx = entity and entity.spawnFx
  if not fx then
    return {
      id = entity and entity.id,
      spawnFx = "none",
      canAct = true,
      canBattle = entity and entity.canTriggerBattle ~= false,
      bodyVisible = true,
    }
  end
  return {
    id = entity and entity.id,
    kind = fx.kind,
    phase = fx.done and "done" or "active",
    elapsed = fx.elapsed,
    duration = fx.duration,
    bodyVisible = SpawnFx.bodyVisible(entity),
    canAct = SpawnFx.canAct(entity),
    canBattle = SpawnFx.canBattle(entity),
  }
end

function SpawnFx.updateEntity(entity, dt, ctx)
  if not entity or not entity.spawnFx then return nil end
  local fx = entity.spawnFx
  if fx.done then return nil end
  dt = tonumber(dt) or 0.016
  fx.elapsed = (fx.elapsed or 0) + dt
  local t = fx.elapsed
  local event = nil

  if fx.kind == SpawnFx.KIND.WATER then
    if not fx.splashFired then
      fx.splashFired = true
      entity._waterSplash = {
        elapsed = 0,
        duration = 0.45,
        x = entity.cellX,
        y = entity.cellY,
      }
      event = "water_splash"
    end
    if t >= (fx.bodyVisibleAt or 0.18) and not fx.bodyShown then
      fx.bodyShown = true
      entity.hiddenBody = false
      entity.visibleSprite = true
      event = "spawn_visible"
    end
    local settle = fx.settleAt or 0.45
    if t < settle then
      local p = clamp(t / settle, 0, 1)
      entity._spawnLiftPx = (1 - p) * 4
    else
      entity._spawnLiftPx = tonumber(entity.surfaceVisualOffset) or 2
    end
    if t >= (fx.actAt or fx.duration or 0.60) then
      fx.done = true
      entity.hiddenBody = false
      entity.canTriggerBattle = true
      entity._spawnLiftPx = tonumber(entity.surfaceVisualOffset) or 2
      return "spawn_done"
    end
    return event
  end

  -- Default: visible grass / land spawn (lift only — no grass rustle).
  if t >= (fx.bodyVisibleAt or 0.10) and not fx.bodyShown then
    fx.bodyShown = true
    entity.hiddenBody = false
    entity.visibleSprite = true
    event = "spawn_visible"
  end
  local actAt = fx.actAt or 0.45
  if t >= (fx.bodyVisibleAt or 0.10) and t < actAt then
    local p = clamp(
      (t - (fx.bodyVisibleAt or 0.10)) / math.max(actAt - (fx.bodyVisibleAt or 0.10), 0.001),
      0, 1)
    entity._spawnLiftPx = math.sin(p * math.pi) * 3
    entity.hopping = true
    entity._revealHopPx = entity._spawnLiftPx
  end
  if t >= actAt then
    fx.done = true
    entity.hiddenBody = false
    entity.canTriggerBattle = true
    entity.hopping = false
    entity._spawnLiftPx = 0
    entity._revealHopPx = 0
    return "spawn_done"
  end
  return event
end

-- Draw water splash rings (alpha-only; no hardcoded modern blue).
function SpawnFx:drawWaterSplashes(canvas, ctx, ow, entities)
  if not (love and love.graphics) then return end
  local cam = ow and ow.camera
  local camX = cam and cam.x or 0
  local camY = cam and cam.y or 0
  local scale = (ctx and tonumber(ctx.scale)) or 1
  local offX = (ctx and tonumber(ctx.offsetX or ctx.x)) or 0
  local offY = (ctx and tonumber(ctx.offsetY or ctx.y)) or 0
  if scale < 1 then scale = 1 end

  love.graphics.push("all")
  if canvas then love.graphics.setCanvas(canvas) end
  for _, entity in pairs(entities or {}) do
    local splash = entity and entity._waterSplash
    if splash then
      splash.elapsed = (splash.elapsed or 0) + 0.016
      local p = clamp(splash.elapsed / (splash.duration or 0.45), 0, 1)
      if p >= 1 then
        entity._waterSplash = nil
      else
        local wx = (entity.px or ((entity.cellX or 0) * CELL)) - camX + CELL * 0.5
        local wy = (entity.py or ((entity.cellY or 0) * CELL)) - camY + CELL * 0.7
        local sx = offX + wx * scale
        local sy = offY + wy * scale
        local r = (2 + p * 8) * scale
        local a = (1 - p) * 0.55
        love.graphics.setColor(1, 1, 1, a)
        love.graphics.circle("line", sx, sy, r)
        love.graphics.setColor(1, 1, 1, a * 0.5)
        love.graphics.circle("line", sx, sy, r * 0.55)
      end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.pop()
end

-- No-op stubs kept so call sites that previously updated rustle FX stay safe.
function SpawnFx:update(dt) end
function SpawnFx:drawPresent(canvas, ctx, ow) end
function SpawnFx:activeRustleCount() return 0 end
function SpawnFx:statusLines() return {} end
function SpawnFx:invalidateTileCache() end

return SpawnFx
