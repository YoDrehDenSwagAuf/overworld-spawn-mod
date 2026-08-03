-- World FX for grass rustle, hidden reveal, visible spawn pop, water splash.
-- Uses real map tile art via TileRenderer:drawCellBottom captured to a small
-- canvas, then blit in the present pipeline with correct letterbox scale.
-- Never invents grass/water palette colors.
local V = ...
local Tile = V.require("tile")
local Config = V.require("config")
local DebugLog = V.require("debug_log")

local SpawnFx = {}
SpawnFx.__index = SpawnFx

SpawnFx.KIND = {
  GRASS = "grass",
  HIDDEN_REVEAL = "hidden_reveal",
  WATER = "water",
  RUSTLE = "rustle",
}

local CELL = Tile.CELL

local function now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function SpawnFx.new(mod)
  local self = setmetatable({}, SpawnFx)
  self.mod = mod
  self._rustles = {} -- ephemeral cell FX { cellX, cellY, elapsed, duration, intensity, amp }
  self._tileCache = {} -- "mapId:x:y" -> Canvas (native 16x16 grass bottom)
  self.rustleEvents = 0
  self.lastRustleAt = nil
  self.rustleRenderer = "NONE"
  return self
end

function SpawnFx:invalidateTileCache()
  self._tileCache = {}
end

-- Capture the real grass bottom tile into a 16x16 canvas (native art).
function SpawnFx:_captureGrassTile(map, cellX, cellY)
  if not (love and love.graphics and love.graphics.newCanvas) then
    return nil
  end
  local renderer = map and map.renderer
  if not renderer or type(renderer.drawCellBottom) ~= "function" then
    return nil
  end
  local mapId = tostring(map.id or "?")
  local key = mapId .. ":" .. tostring(cellX) .. ":" .. tostring(cellY)
  local hit = self._tileCache[key]
  if hit then return hit end

  local ok, canvas = pcall(love.graphics.newCanvas, CELL, CELL)
  if not ok or not canvas then return nil end
  if canvas.setFilter then canvas:setFilter("nearest", "nearest") end

  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.origin()
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(1, 1, 1, 1)
  -- drawCellBottom draws at (cell*16 - cam). Cam = cell*16 → draw at (0,0).
  local camX = (cellX or 0) * CELL
  local camY = (cellY or 0) * CELL
  pcall(renderer.drawCellBottom, renderer, cellX, cellY, camX, camY)
  love.graphics.setCanvas()
  love.graphics.pop()

  self._tileCache[key] = canvas
  self.rustleRenderer = "TILE_CAPTURE"
  return canvas
end

-- intensity: "small" | "strong"
function SpawnFx:grassRustle(map, cellX, cellY, intensity)
  if cellX == nil or cellY == nil then return false end
  intensity = intensity or "small"
  local duration = (intensity == "strong") and 0.40 or 0.30
  local amp = (intensity == "strong") and 3 or 2
  self._rustles[#self._rustles + 1] = {
    map = map,
    cellX = cellX,
    cellY = cellY,
    elapsed = 0,
    duration = duration,
    intensity = intensity,
    amp = amp,
    phase = 0,
  }
  self.rustleEvents = (self.rustleEvents or 0) + 1
  self.lastRustleAt = now()
  if map and map.renderer and type(map.renderer.drawCellBottom) == "function" then
    self.rustleRenderer = self.rustleRenderer ~= "NONE" and self.rustleRenderer or "DRAW_CELL_BOTTOM"
    self:_captureGrassTile(map, cellX, cellY)
  end
  return true
end

function SpawnFx:update(dt)
  dt = tonumber(dt) or 0.016
  if dt < 0 then dt = 0 end
  if dt > 0.1 then dt = 0.1 end
  local alive = {}
  for _, fx in ipairs(self._rustles) do
    fx.elapsed = (fx.elapsed or 0) + dt
    fx.phase = (fx.phase or 0) + dt * 18
    if fx.elapsed < fx.duration then
      alive[#alive + 1] = fx
    end
  end
  self._rustles = alive
end

function SpawnFx:activeRustleCount()
  return #(self._rustles or {})
end

-- Present-pipeline draw: convert world cells → letterboxed screen and blit
-- captured real grass tiles with a shake offset.
function SpawnFx:drawPresent(canvas, ctx, ow)
  if not (love and love.graphics) then return end
  if #(self._rustles or {}) == 0 then return end
  if not ow or not ow.map then return end

  local cam = ow.camera
  local camX = cam and cam.x or 0
  local camY = cam and cam.y or 0
  local scale = 1
  local offX, offY = 0, 0
  if ctx then
    scale = tonumber(ctx.scale) or scale
    offX = tonumber(ctx.offsetX or ctx.x) or 0
    offY = tonumber(ctx.offsetY or ctx.y) or 0
  end
  if scale < 1 then scale = 1 end

  love.graphics.push("all")
  if canvas then love.graphics.setCanvas(canvas) end
  love.graphics.setColor(1, 1, 1, 1)

  for _, fx in ipairs(self._rustles) do
    local tile = self:_captureGrassTile(ow.map, fx.cellX, fx.cellY)
    local t = fx.elapsed / math.max(fx.duration, 0.001)
    -- left → right → center
    local wave = math.sin(fx.phase) * (1.0 - t)
    local shake = wave * (fx.amp or 2)
    local worldX = (fx.cellX or 0) * CELL - camX
    local worldY = (fx.cellY or 0) * CELL - camY
    local sx = offX + worldX * scale
    local sy = offY + worldY * scale

    if tile then
      love.graphics.setColor(1, 1, 1, 0.95)
      love.graphics.draw(tile, sx + shake * scale, sy, 0, scale, scale)
    else
      -- Fallback: nudge drawCellBottom in present space is unreliable; skip
      -- inventing colours. Count as attempted.
      self.rustleRenderer = "UNAVAILABLE"
    end
  end

  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.pop()
end

-- ------- Per-entity spawn / reveal FX state -------

local GRASS_SPAWN = {
  duration = 0.50,
  bodyAt = 0.12,
  landAt = 0.25,
  actAt = 0.50,
}

local HIDDEN_REVEAL = {
  duration = 0.55,
  rustleEnd = 0.15,
  bodyAt = 0.15,
  hopStart = 0.30,
  hopEnd = 0.50,
  battleAt = 0.50,
}

local WATER_SPAWN = {
  duration = 0.60,
  bodyAt = 0.18,
  settleAt = 0.45,
  actAt = 0.60,
}

SpawnFx.GRASS_SPAWN = GRASS_SPAWN
SpawnFx.HIDDEN_REVEAL = HIDDEN_REVEAL
SpawnFx.WATER_SPAWN = WATER_SPAWN

function SpawnFx.begin(entity, kind, opts)
  if not entity then return nil end
  opts = opts or {}
  kind = kind or SpawnFx.KIND.GRASS
  local profile = GRASS_SPAWN
  if kind == SpawnFx.KIND.HIDDEN_REVEAL then
    profile = HIDDEN_REVEAL
  elseif kind == SpawnFx.KIND.WATER then
    profile = WATER_SPAWN
  end
  entity.spawnFx = {
    kind = kind,
    elapsed = 0,
    duration = opts.duration or profile.duration,
    bodyVisibleAt = opts.bodyVisibleAt or profile.bodyAt,
    actAt = opts.actAt or profile.actAt or profile.duration,
    battleAt = opts.battleAt or profile.battleAt,
    hopStart = profile.hopStart,
    hopEnd = profile.hopEnd,
    landAt = profile.landAt,
    settleAt = profile.settleAt,
    rustleEnd = profile.rustleEnd,
    done = false,
    bodyShown = false,
    rustleFired = false,
    splashFired = false,
  }
  entity.hiddenBody = true
  entity.canTriggerBattle = false
  entity._spawnLiftPx = 0
  return entity.spawnFx
end

function SpawnFx.bodyVisible(entity)
  if not entity then return true end
  local hi = entity.hiddenIdle
  if hi and hi.active and not hi.revealed then
    return false
  end
  if entity.hiddenBody == true then
    return false
  end
  local fx = entity.spawnFx
  if fx and not fx.done and not fx.bodyShown then
    return false
  end
  if entity.hiddenEncounter and entity.visibleSprite == false
     and not (hi and hi.revealed) then
    return false
  end
  return true
end

function SpawnFx.visualLift(entity)
  if not entity then return 0 end
  return tonumber(entity._spawnLiftPx or entity._revealHopPx) or 0
end

function SpawnFx.canAct(entity)
  if not entity then return true end
  local fx = entity.spawnFx
  if fx and not fx.done then
    return false
  end
  local hi = entity.hiddenIdle
  if hi and hi.active and (not hi.revealed or hi.revealStarted) then
    if hi.battleStarted then return false end
    if hi.revealStarted and not hi.revealed then return false end
    if hi.revealStarted then return false end
    return false -- hidden idle lurk: no wander/chase
  end
  return true
end

function SpawnFx.canBattle(entity)
  if not entity then return false end
  if entity.canTriggerBattle == false then return false end
  local fx = entity.spawnFx
  if fx and not fx.done then return false end
  local hi = entity.hiddenIdle
  if hi and hi.active and not hi.battleStarted then
    return false
  end
  return true
end

function SpawnFx.updateEntity(entity, dt, ctx)
  if not entity or not entity.spawnFx then return nil end
  local fx = entity.spawnFx
  if fx.done then return nil end
  dt = tonumber(dt) or 0.016
  fx.elapsed = (fx.elapsed or 0) + dt
  local t = fx.elapsed
  local event = nil

  if fx.kind == SpawnFx.KIND.HIDDEN_REVEAL then
    if not fx.rustleFired and ctx and ctx.spawnFx then
      ctx.spawnFx:grassRustle(ctx.map, entity.cellX, entity.cellY, "strong")
      fx.rustleFired = true
    end
    if t >= (fx.bodyVisibleAt or 0.15) and not fx.bodyShown then
      fx.bodyShown = true
      entity.hiddenBody = false
      entity.visibleSprite = true
      entity.hiddenEncounter = false
      if entity.hiddenIdle then entity.hiddenIdle.revealed = true end
      event = "reveal_visible"
    end
    if entity.hiddenIdle then
      entity.hiddenIdle.revealElapsed = t
    end
    local hopStart = fx.hopStart or 0.30
    local hopEnd = fx.hopEnd or 0.50
    if t >= hopStart and t < hopEnd then
      local p = (t - hopStart) / math.max(hopEnd - hopStart, 0.001)
      entity._spawnLiftPx = math.sin(clamp(p, 0, 1) * math.pi) * 3
      entity.hopping = true
      entity._revealHopPx = entity._spawnLiftPx
      if not fx.hopEvent then
        fx.hopEvent = true
        event = event or "reveal_hop"
      end
    else
      entity.hopping = false
      if t >= hopEnd then
        entity._spawnLiftPx = 0
        entity._revealHopPx = 0
      end
    end
    if t >= (fx.battleAt or 0.50) then
      fx.done = true
      entity.hiddenBody = false
      return "reveal_battle"
    end
    return event
  end

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

  -- Default: visible grass spawn
  if not fx.rustleFired and ctx and ctx.spawnFx then
    ctx.spawnFx:grassRustle(ctx.map, entity.cellX, entity.cellY, "small")
    fx.rustleFired = true
  end
  if t >= (fx.bodyVisibleAt or 0.12) and not fx.bodyShown then
    fx.bodyShown = true
    entity.hiddenBody = false
    entity.visibleSprite = true
    event = "spawn_visible"
  end
  local landAt = fx.landAt or 0.25
  local actAt = fx.actAt or 0.50
  if t >= (fx.bodyVisibleAt or 0.12) and t < actAt then
    local p = clamp((t - (fx.bodyVisibleAt or 0.12)) / math.max(actAt - (fx.bodyVisibleAt or 0.12), 0.001), 0, 1)
    entity._spawnLiftPx = math.sin(p * math.pi) * 3
    entity.hopping = t < landAt + 0.15
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
        -- Neutral highlight — no fixed water hue.
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

function SpawnFx:statusLines()
  return {
    ("Rustle FX: %s"):format(self:activeRustleCount() > 0 and "ACTIVE" or "IDLE"),
    ("Rustle Events: %d"):format(self.rustleEvents or 0),
    ("Rustle renderer: %s"):format(tostring(self.rustleRenderer or "NONE")),
    ("Reveal FX: %s"):format("READY"),
  }
end

return SpawnFx
