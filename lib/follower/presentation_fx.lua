-- Follower RELEASE / RECALL presentation (Poké Ball light/tint/scale).
--
-- GAMEPLAY STATE and PRESENTATION STATE are separate:
--   * Intentional Follow / Dismiss / count / switch update selection immediately.
--   * Visual FX are transient overlays / ghosts that never own trail, collision,
--     occupancy, talk, or selection.
--
-- Technical rebuilds (map seam, battle return, sprite style, water rebind, …)
-- must leave `_presentationIntent` nil so this module does nothing.
local V = ...

local PresentationFx = {}
PresentationFx.__index = PresentationFx

PresentationFx.DURATION = 0.25
PresentationFx.SCALE_MIN = 0.15
PresentationFx.STAGGER_S = 0.05
PresentationFx.ALPHA_MIN = 0.28

local NO_UPDATE = function() end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function easeOutCubic(t)
  t = clamp(t, 0, 1)
  local u = 1 - t
  return 1 - u * u * u
end

local function easeInCubic(t)
  t = clamp(t, 0, 1)
  return t * t * t
end

-- Tint keyframes (linear RGB). Release uses t ascending; recall uses (1 - t).
local TINT_KEYS = {
  { t = 0.00, r = 1.00, g = 1.00, b = 1.00 }, -- white
  { t = 0.25, r = 1.00, g = 0.78, b = 0.86 }, -- pale pink
  { t = 0.50, r = 1.00, g = 0.42, b = 0.48 }, -- strong red/pink
  { t = 0.75, r = 1.00, g = 0.82, b = 0.84 }, -- mostly normal
  { t = 1.00, r = 1.00, g = 1.00, b = 1.00 }, -- normal (no tint multiply)
}

local function lerp(a, b, u)
  return a + (b - a) * u
end

local function sampleTint(t)
  t = clamp(t, 0, 1)
  local prev = TINT_KEYS[1]
  for i = 2, #TINT_KEYS do
    local cur = TINT_KEYS[i]
    if t <= cur.t then
      local span = cur.t - prev.t
      local u = span > 0 and ((t - prev.t) / span) or 0
      return lerp(prev.r, cur.r, u), lerp(prev.g, cur.g, u), lerp(prev.b, cur.b, u)
    end
    prev = cur
  end
  return 1, 1, 1
end

--- Pure sample of release/recall visual parameters at normalized time t ∈ [0,1].
-- Release: t=0 tiny/bright → t=1 full/normal.
-- Recall:  t=0 full/normal → t=1 tiny/bright/gone.
function PresentationFx.sample(kind, t)
  t = clamp(tonumber(t) or 0, 0, 1)
  local isRecall = kind == "recall"
  local eased = isRecall and easeInCubic(t) or easeOutCubic(t)
  local tintT = isRecall and (1 - t) or t
  local r, g, b = sampleTint(tintT)
  local scaleMin = PresentationFx.SCALE_MIN
  local scale, alpha, light
  if isRecall then
    scale = lerp(1.0, scaleMin, eased)
    alpha = lerp(1.0, 0.0, eased)
    light = clamp((t - 0.55) / 0.45, 0, 1) * (1 - alpha * 0.35)
  else
    scale = lerp(scaleMin, 1.0, eased)
    alpha = lerp(PresentationFx.ALPHA_MIN, 1.0, eased)
    light = clamp(1 - t / 0.45, 0, 1) * (1.15 - alpha * 0.4)
  end
  -- At completion, guarantee identity (no leftover tint / scale / alpha).
  if t >= 1 then
    if isRecall then
      return {
        scale = scaleMin, alpha = 0, r = 1, g = 1, b = 1, light = 0, done = true,
      }
    end
    return {
      scale = 1, alpha = 1, r = 1, g = 1, b = 1, light = 0, done = true,
    }
  end
  return {
    scale = scale,
    alpha = alpha,
    r = r, g = g, b = b,
    light = light,
    done = false,
  }
end

PresentationFx.easeOutCubic = easeOutCubic
PresentationFx.easeInCubic = easeInCubic

local function monKey(selection, mon, fallback)
  if selection and type(selection.monFingerprint) == "function" and mon then
    local ok, key = pcall(selection.monFingerprint, mon)
    if ok and type(key) == "string" and key ~= "" then return key end
  end
  if mon and mon.species then
    return tostring(mon.species) .. ":" .. tostring(fallback or "?")
  end
  return tostring(fallback or "unknown")
end

local function geometryOf(npc)
  local def = (npc and npc.sprite and npc.sprite.def) or (npc and npc.spriteDef) or {}
  return {
    frameWidth = tonumber(def.frameWidth) or 16,
    frameHeight = tonumber(def.frameHeight) or 16,
    anchorX = tonumber(def.anchorX),
    anchorY = tonumber(def.anchorY),
  }
end

local function feetScreenOffset(geom)
  -- Feet stay planted on the tile floor while the sprite scales up/down.
  -- Classic 16×16: feet at (+8, +16) from cell origin (px, py).
  -- True Size: prefer SpriteDef anchor when present; else bottom-center of frame.
  local fw = geom.frameWidth or 16
  local fh = geom.frameHeight or 16
  local ax = geom.anchorX
  local ay = geom.anchorY
  if ax == nil then ax = fw * 0.5 end
  if ay == nil then ay = fh end
  -- SpriteRenderer typically places the anchor on the cell; feet ≈ cell bottom.
  -- Use cell-centered feet so scale growth does not lift the contact point.
  return 8, 16
end

local function setColor(r, g, b, a)
  if love and love.graphics and love.graphics.setColor then
    love.graphics.setColor(r, g, b, a)
  end
end

local function resetColor()
  setColor(1, 1, 1, 1)
end

local function drawLightCore(feetX, feetY, light, scale)
  if not (love and love.graphics and light and light > 0.02) then return end
  local a = clamp(light, 0, 1)
  local G = love.graphics
  setColor(1, 1, 1, a)
  local s = math.max(1, math.floor(1 + scale * 0.5))
  if G.rectangle then
    G.rectangle("fill", feetX - s, feetY - s - 1, s * 2, s * 2)
  end
  setColor(1, 0.85, 0.9, a * 0.55)
  if G.rectangle then
    G.rectangle("fill", feetX - 1, feetY - s * 2 - 1, 2, s * 2 + 1)
    G.rectangle("fill", feetX - s - 1, feetY - 1, s * 2 + 1, 2)
  end
  resetColor()
end

--- Install a one-time sprite.draw / npc.draw wrap that reads `_wildsPresentationFx`.
function PresentationFx.installDrawWrap(npc)
  if not npc or npc._wildsPresentationDrawWrapped then return npc end
  npc._wildsPresentationDrawWrapped = true

  local function activeSample(ent)
    local fx = ent and ent._wildsPresentationFx
    if not fx or fx.done then return nil end
    -- Stagger: still invisible / unscaled until delay elapses.
    if (tonumber(fx.delay) or 0) > 0 and fx.kind == "release" then
      return PresentationFx.sample("release", 0)
    end
    local dur = tonumber(fx.duration) or PresentationFx.DURATION
    if dur <= 0 then return PresentationFx.sample(fx.kind, 1) end
    local t = clamp((tonumber(fx.elapsed) or 0) / dur, 0, 1)
    return PresentationFx.sample(fx.kind, t)
  end

  local function wrapSpriteDraw(ent, sprite)
    if not (sprite and type(sprite.draw) == "function" and not sprite._wildsFxDrawWrapped) then
      return
    end
    sprite._wildsFxDrawWrapped = true
    local orig = sprite.draw
    sprite._wildsFxOrigDraw = orig
    function sprite:draw(px, py, camX, camY, facing, phase, flip)
      -- Outer Gen2 draw already applied FX transforms.
      if ent._wildsFxDrawing then
        return orig(self, px, py, camX, camY, facing, phase, flip)
      end
      local sample = activeSample(ent)
      if not sample then
        return orig(self, px, py, camX, camY, facing, phase, flip)
      end
      local G = love and love.graphics
      local geom = geometryOf(ent)
      local fox, foy = feetScreenOffset(geom)
      local sx = (tonumber(px) or 0) - (tonumber(camX) or 0) + fox
      local sy = (tonumber(py) or 0) - (tonumber(camY) or 0) + foy
      if G and G.push then
        G.push()
        setColor(sample.r, sample.g, sample.b, sample.alpha)
        G.translate(sx, sy)
        G.scale(sample.scale, sample.scale)
        G.translate(-sx, -sy)
        ent._wildsFxDrawing = true
        orig(self, px, py, camX, camY, facing, phase, flip)
        ent._wildsFxDrawing = false
        drawLightCore(sx, sy - 2, sample.light, sample.scale)
        resetColor()
        G.pop()
      else
        setColor(sample.r, sample.g, sample.b, sample.alpha)
        orig(self, px, py, camX, camY, facing, phase, flip)
        resetColor()
      end
    end
  end

  if npc.sprite then
    wrapSpriteDraw(npc, npc.sprite)
  end

  -- Gen2 World:drawPeople → npc:draw(ox, oy, scale).
  local baseDraw = npc.draw
  if type(baseDraw) == "function" then
    function npc:draw(ox, oy, scale)
      local sample = activeSample(self)
      if not sample then
        return baseDraw(self, ox, oy, scale)
      end
      if self.sprite and not self.sprite._wildsFxDrawWrapped then
        wrapSpriteDraw(self, self.sprite)
      end
      local G = love and love.graphics
      if scale ~= nil and G and G.push then
        G.push()
        G.translate(ox or 0, oy or 0)
        G.scale(scale, scale)
        setColor(sample.r, sample.g, sample.b, sample.alpha)
        local geom = geometryOf(self)
        local fox, foy = feetScreenOffset(geom)
        local feetX = (self.px or 0) + fox
        local feetY = (self.py or 0) + foy
        G.translate(feetX, feetY)
        G.scale(sample.scale, sample.scale)
        G.translate(-feetX, -feetY)
        local phase = 0
        if type(self.walkPhase) == "function" then
          phase = self:walkPhase() or 0
        end
        local raw = self.sprite and (self.sprite._wildsFxOrigDraw or self.sprite.draw)
        self._wildsFxDrawing = true
        if raw then
          raw(self.sprite, self.px or 0, self.py or 0, 0, 0,
            self.facing or "down", phase, self.stepFlip)
        else
          baseDraw(self, 0, 0, nil)
        end
        self._wildsFxDrawing = false
        drawLightCore(feetX, feetY - 2, sample.light, sample.scale)
        resetColor()
        G.pop()
        return
      end
      return baseDraw(self, ox, oy, scale)
    end
  end

  -- If sprite is rebound later, re-wrap on next pose/draw.
  local basePose = npc.pose
  if type(basePose) == "function" then
    npc.pose = function(ent)
      if ent.sprite and not ent.sprite._wildsFxDrawWrapped then
        wrapSpriteDraw(ent, ent.sprite)
      end
      return basePose(ent)
    end
  end

  return npc
end

function PresentationFx.new(mod, opts)
  opts = opts or {}
  local self = setmetatable({}, PresentationFx)
  self.mod = mod
  self.selection = opts.selection
  self.ghosts = {}
  return self
end

function PresentationFx:clearAll(ow)
  self:clearGhosts(ow)
  if ow then
    for _, listName in ipairs({ "npcs", "entities", "pokepcTrailers" }) do
      local list = ow[listName]
      if type(list) == "table" then
        for _, e in ipairs(list) do
          if e and e._wildsPresentationFx then
            e._wildsPresentationFx = nil
          end
        end
      end
    end
  end
end

function PresentationFx:clearGhosts(ow)
  for i = #self.ghosts, 1, -1 do
    local g = self.ghosts[i]
    if ow and g then
      self:_detach(ow, g)
    end
    self.ghosts[i] = nil
  end
end

function PresentationFx:_detach(ow, entity)
  if not (ow and entity) then return end
  local GameCompat = V.require("game_compat")
  if GameCompat and GameCompat.detachGuestEntity then
    pcall(GameCompat.detachGuestEntity, ow, entity)
  else
    local function strip(list)
      if type(list) ~= "table" then return end
      for i = #list, 1, -1 do
        if list[i] == entity then table.remove(list, i) end
      end
    end
    strip(ow.entities)
    strip(ow.npcs)
  end
end

--- Snapshot intentional follower visuals (trailers only; never stock Pikachu).
function PresentationFx:captureVisibleFollowers(ow)
  local out = {}
  if not ow then return out end
  local seen = {}
  local function consider(npc)
    if not npc or seen[npc] then return end
    -- Stock Yellow Pikachu is engine-owned; never capture for FX.
    if npc.pikachuFollower == true and npc.pokepcTrailer ~= true then
      return
    end
    if npc.pokepcTrailer ~= true and npc.wildsFollower ~= true then
      return
    end
    if npc.pokepcTrailerKind == "trainer" then return end
    seen[npc] = true
    local slot = tonumber(npc.wildsFollowerSlot) or (#out + 1)
    local key = monKey(self.selection, npc.pokepcMon, slot)
    out[#out + 1] = {
      key = key,
      slot = slot,
      npc = npc,
      px = tonumber(npc.px) or ((tonumber(npc.cellX) or 0) * 16),
      py = tonumber(npc.py) or ((tonumber(npc.cellY) or 0) * 16),
      cellX = tonumber(npc.cellX),
      cellY = tonumber(npc.cellY),
      facing = npc.facing or "down",
      stepFlip = npc.stepFlip == true,
      sprite = npc.sprite,
      spriteDef = npc.spriteDef,
      mon = npc.pokepcMon,
      geom = geometryOf(npc),
    }
  end
  for _, npc in ipairs(ow.pokepcTrailers or {}) do consider(npc) end
  for _, npc in ipairs(ow.npcs or {}) do consider(npc) end
  for _, npc in ipairs(ow.entities or {}) do consider(npc) end
  table.sort(out, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
  return out
end

local function indexByKey(list)
  local map = {}
  for _, row in ipairs(list or {}) do
    if row.key then map[row.key] = row end
  end
  return map
end

function PresentationFx:_beginOnEntity(npc, kind, delay)
  if not npc then return nil end
  -- Never FX stock Pikachu presentation.
  if npc.pikachuFollower == true and npc.pokepcTrailer ~= true then
    return nil
  end
  PresentationFx.installDrawWrap(npc)
  local fx = {
    kind = kind,
    elapsed = 0,
    duration = PresentationFx.DURATION,
    delay = math.max(0, tonumber(delay) or 0),
    done = false,
    sourceNpc = npc,
  }
  npc._wildsPresentationFx = fx
  return fx
end

function PresentationFx:_makeGhost(snap, delay)
  if not snap then return nil end
  local ghost = {
    id = "WILDS_FOLLOWER_RECALL_FX_" .. tostring(snap.slot or 0),
    fxOnly = true,
    pureFx = true,
    passable = true,
    overworldWildSpawn = false,
    wildsBattleable = false,
    -- Explicitly NOT a follower — no trail / talk / occupancy as follower.
    pokepcTrailer = false,
    wildsFollower = false,
    pikachuFollower = false,
    isFollower = false,
    follower = false,
    px = snap.px,
    py = snap.py,
    cellX = snap.cellX,
    cellY = snap.cellY,
    facing = snap.facing or "down",
    stepFlip = snap.stepFlip == true,
    sprite = snap.sprite,
    spriteDef = snap.spriteDef,
    pokepcMon = snap.mon,
    update = NO_UPDATE,
    _wildsRecallGhost = true,
    -- Gen1 OverworldState:checkTrainerSight indexes npc.def with no nil guard.
    def = {},
    frozen = true,
    wanders = false,
  }
  function ghost:walkPhase()
    return 0
  end
  function ghost:pose()
    return self.sprite, self.px, self.py, self.facing, 0, self.stepFlip
  end
  function ghost:draw(ox, oy, scale)
    if not (self.sprite and self.sprite.draw) then return end
    local sample = nil
    local fx = self._wildsPresentationFx
    if fx and not fx.done then
      local dur = tonumber(fx.duration) or PresentationFx.DURATION
      local t = dur > 0 and clamp((tonumber(fx.elapsed) or 0) / dur, 0, 1) or 1
      sample = PresentationFx.sample("recall", t)
    end
    local G = love and love.graphics
    local phase = 0
    if scale ~= nil and G and G.push then
      G.push()
      G.translate(ox or 0, oy or 0)
      G.scale(scale, scale)
      if sample then
        local geom = snap.geom or geometryOf(self)
        local fox, foy = feetScreenOffset(geom)
        local feetX = (self.px or 0) + fox
        local feetY = (self.py or 0) + foy
        setColor(sample.r, sample.g, sample.b, sample.alpha)
        G.translate(feetX, feetY)
        G.scale(sample.scale, sample.scale)
        G.translate(-feetX, -feetY)
        self.sprite:draw(self.px or 0, self.py or 0, 0, 0,
          self.facing or "down", phase, self.stepFlip)
        drawLightCore(feetX, feetY - 2, sample.light, sample.scale)
        resetColor()
      else
        self.sprite:draw(self.px or 0, self.py or 0, 0, 0,
          self.facing or "down", phase, self.stepFlip)
      end
      G.pop()
      return
    end
    -- Gen1 camera-arity: rely on sprite.draw wrap.
    self.sprite:draw(self.px or 0, self.py or 0, ox or 0, oy or 0,
      self.facing or "down", phase, self.stepFlip)
  end
  PresentationFx.installDrawWrap(ghost)
  self:_beginOnEntity(ghost, "recall", delay)
  return ghost
end

--- Diff capture → current trailers. Starts recall ghosts + release FX.
-- @param opts.stagger seconds between multiple release starts (default STAGGER_S)
function PresentationFx:reconcileAfterSync(ow, before, opts)
  opts = opts or {}
  if not ow then return { released = 0, recalled = 0 } end
  local afterList = self:captureVisibleFollowers(ow)
  local beforeMap = indexByKey(before)
  local afterMap = indexByKey(afterList)
  local stagger = tonumber(opts.stagger)
  if stagger == nil then stagger = PresentationFx.STAGGER_S end

  local released, recalled = 0, 0
  local releaseIndex = 0

  -- Removals → recall ghosts (presentation only).
  for _, snap in ipairs(before or {}) do
    if snap.key and not afterMap[snap.key] then
      local ghost = self:_makeGhost(snap, 0)
      if ghost then
        local GameCompat = V.require("game_compat")
        local game = self.mod and self.mod.world and self.mod.world.game
        if GameCompat and GameCompat.attachPresentationGhost then
          pcall(GameCompat.attachPresentationGhost, ow, ghost, game)
        elseif GameCompat and GameCompat.attachGuestEntity then
          pcall(GameCompat.attachGuestEntity, ow, ghost, game)
        else
          ow.entities = ow.entities or {}
          ow.entities[#ow.entities + 1] = ghost
        end
        self.ghosts[#self.ghosts + 1] = ghost
        recalled = recalled + 1
      end
    end
  end

  -- Additions → release on live trailer NPCs.
  for _, row in ipairs(afterList) do
    if row.key and not beforeMap[row.key] and row.npc then
      local delay = releaseIndex * stagger
      if self:_beginOnEntity(row.npc, "release", delay) then
        released = released + 1
        releaseIndex = releaseIndex + 1
      end
    end
  end

  return { released = released, recalled = recalled }
end

--- Advance all active FX. dt in seconds. Removes finished ghosts.
function PresentationFx:tick(ow, dt)
  dt = tonumber(dt) or 0
  if dt < 0 then dt = 0 end

  local function stepFx(ent, stepDt)
    local fx = ent and ent._wildsPresentationFx
    if not fx or fx.done then return false end
    local delay = tonumber(fx.delay) or 0
    local remain = stepDt
    if delay > 0 then
      fx.delay = delay - remain
      if fx.delay > 0 then return true end
      remain = -fx.delay -- leftover after delay
      fx.delay = 0
    end
    fx.elapsed = (tonumber(fx.elapsed) or 0) + remain
    local dur = tonumber(fx.duration) or PresentationFx.DURATION
    if fx.elapsed >= dur then
      fx.elapsed = dur
      fx.done = true
      if fx.kind == "release" then
        -- Guarantee no leftover tint/scale on the live follower.
        ent._wildsPresentationFx = nil
      end
      return false
    end
    return true
  end

  -- A trailer is often in pokepcTrailers + npcs + entities; step once.
  local seen = {}
  for _, listName in ipairs({ "pokepcTrailers", "npcs", "entities" }) do
    local list = ow and ow[listName]
    if type(list) == "table" then
      for _, e in ipairs(list) do
        if e and e._wildsPresentationFx and not e._wildsRecallGhost and not seen[e] then
          seen[e] = true
          stepFx(e, dt)
        end
      end
    end
  end

  for i = #self.ghosts, 1, -1 do
    local g = self.ghosts[i]
    local alive = g and stepFx(g, dt)
    if not alive then
      if ow and g then self:_detach(ow, g) end
      table.remove(self.ghosts, i)
    end
  end
end

function PresentationFx:activeGhostCount()
  return #self.ghosts
end

function PresentationFx:hasActiveFx(ow)
  if #self.ghosts > 0 then return true end
  if not ow then return false end
  for _, listName in ipairs({ "pokepcTrailers", "npcs", "entities" }) do
    local list = ow[listName]
    if type(list) == "table" then
      for _, e in ipairs(list) do
        if e and e._wildsPresentationFx and not e._wildsPresentationFx.done then
          return true
        end
      end
    end
  end
  return false
end

return PresentationFx
