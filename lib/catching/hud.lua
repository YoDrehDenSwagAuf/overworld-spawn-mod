-- Small top-right Poké Ball inventory HUD + throw power meter.
-- Draws onto the render-pipeline canvas (must setCanvas), matching DebugHud.
-- catch_hud_size scales this UI component only — thrown Balls stay ~6px.
local V = ...
local Config = V.require("config")
local CatchMath = V.require("catching/catch_math")
local GameCompat = V.require("game_compat")

local BallHud = {}
BallHud.__index = BallHud

BallHud.PIPELINE_ID = "owwild_ball_hud"
-- Default icon px when setting is 5 (~1.08× of 14). Thrown Balls stay ~6px.
BallHud.ICON_PX = 15
BallHud.ICON_PX_MIN = 8
BallHud.ICON_PX_MAX = 24
-- Gold-only logical origin (160×144). Gen1 keeps the historic top-right row.
BallHud.GOLD_LOGICAL_X = 4
BallHud.GOLD_LOGICAL_Y = 2

local BALL_ORDER = { "POKE_BALL", "GREAT_BALL", "ULTRA_BALL", "MASTER_BALL" }
local BALL_SHORT = {
  POKE_BALL = "POKE",
  GREAT_BALL = "GREAT",
  ULTRA_BALL = "ULTRA",
  MASTER_BALL = "MASTER",
}

local function now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

function BallHud.iconPx(mod)
  local px = Config.catchHudIconPx(mod)
  if px < BallHud.ICON_PX_MIN then return BallHud.ICON_PX_MIN end
  if px > BallHud.ICON_PX_MAX then return BallHud.ICON_PX_MAX end
  return px
end

--- Layout metrics for the current Catch HUD Size (nearest-neighbor icons).
--- Scales the compact HUD as one component: icons, gaps, quantity, meter Y.
--- Optional `anchor`:
---   nil / "topright" — Gen1: row against the right edge of the 160px canvas
---   "topleft"        — Gold: same component, origin at GOLD_LOGICAL_X/Y
function BallHud.layout(mod, canvasW, anchor)
  canvasW = canvasW or 160
  if canvasW > 200 then canvasW = 160 end
  local scale = Config.catchHudScale(mod)
  local iconW = BallHud.iconPx(mod)
  -- Keep four icons + gaps inside the 160px canvas; shrink gap as icons grow.
  local gap = math.max(1, math.floor(3 * scale + 0.5))
  if iconW >= 16 then
    gap = math.min(gap, 2)
  end
  if iconW >= 20 then
    gap = 1
  end
  local rowW = #BALL_ORDER * iconW + (#BALL_ORDER - 1) * gap
  local startX = canvasW - 4 - rowW
  if startX < 2 then
    gap = 1
    rowW = #BALL_ORDER * iconW + (#BALL_ORDER - 1) * gap
    startX = math.max(2, canvasW - 4 - rowW)
  end
  -- If size 10 still overflows, shrink icon slightly so four balls fit.
  while startX < 2 and iconW > BallHud.ICON_PX_MIN do
    iconW = iconW - 1
    rowW = #BALL_ORDER * iconW + (#BALL_ORDER - 1) * gap
    startX = canvasW - 4 - rowW
  end
  if startX + rowW > canvasW - 2 then
    startX = math.max(2, canvasW - 2 - rowW)
  end
  local iconY = 2
  local qtyPad = math.max(1, math.floor(scale + 0.5))
  local qtyY = iconY + iconW + qtyPad
  -- Power meter sits below icons + quantity line; modest spacing with scale.
  local meterY = qtyY + math.max(8, math.floor(10 * scale + 0.5))
  local meterX = canvasW - 22
  local border = iconW + 2
  -- Gold: translate the whole block (icons + qty + meter) to the top-left
  -- logical origin. Do not re-layout pieces independently.
  if anchor == "topleft" then
    local dx = BallHud.GOLD_LOGICAL_X - startX
    local dy = BallHud.GOLD_LOGICAL_Y - iconY
    startX = startX + dx
    iconY = iconY + dy
    qtyY = qtyY + dy
    meterY = meterY + dy
    meterX = meterX + dx
  end
  return {
    canvasW = canvasW,
    scale = scale,
    iconW = iconW,
    gap = gap,
    startX = startX,
    iconY = iconY,
    qtyY = qtyY,
    meterY = meterY,
    meterX = meterX,
    hudOriginX = startX,
    hudOriginY = iconY,
    selectedBorder = border,
    anchor = anchor or "topright",
  }
end

--- Gold render.hud is window-space. Reuse Game2:viewport letterbox fields
--- (gameX / gameY / scale) rather than re-deriving Chrome.fitScale.
function BallHud.playfieldTransform(viewport)
  viewport = viewport or {}
  return {
    x = viewport.gameX or 0,
    y = viewport.gameY or 0,
    scale = viewport.scale or 1,
    logicalW = 160,
    logicalH = 144,
  }
end

function BallHud.projectLogical(viewport, logicalX, logicalY)
  local t = BallHud.playfieldTransform(viewport)
  return t.x + (logicalX or 0) * t.scale, t.y + (logicalY or 0) * t.scale
end

function BallHud.new(mod, catching)
  local self = setmetatable({}, BallHud)
  self.mod = mod
  self.catching = catching
  self._registered = false
  self.feedbackText = nil
  self.feedbackUntil = 0
  return self
end

function BallHud:showFeedback(text, seconds)
  self.feedbackText = text
  self.feedbackUntil = now() + (seconds or 0.9)
end

function BallHud:shouldDraw(game, ow)
  if not self.catching then return false end
  -- Size 0 hides this HUD only. Catching / meter / range tiles stay active.
  if not Config.catchHudEnabled(self.mod) then return false end
  if self.catching.canShowHud then
    return self.catching:canShowHud(game, ow) == true
  end
  if not Config.overworldCatchingEnabled(self.mod) then return false end
  if not Config.isEnabled(self.mod) then return false end
  if not game or not ow or not GameCompat.catchPlayer(game, ow) then return false end
  if self.catching.safariBlocks and self.catching:safariBlocks(game, ow) then
    return false
  end
  if self.catching.logic and self.catching.logic.pendingBattle then
    return false
  end
  return true
end

local function ballCount(catching, game, ballType)
  if catching and catching.ballCount then
    return catching:ballCount(game, ballType)
  end
  local inv = game and game.save and game.save.inventory
  if not inv then return 0 end
  return tonumber(inv[ballType]) or 0
end

local function drawText(Font, lg, text, x, y)
  if Font and Font.draw then
    Font.draw(text, x, y)
  elseif lg and lg.print then
    lg.setColor(0, 0, 0, 1)
    lg.print(text, x, y)
  end
end

function BallHud:draw(canvas, ctx, opts)
  opts = opts or {}
  -- Hidden HUD: skip layout / images / meter / feedback before any draw work.
  if not Config.catchHudEnabled(self.mod) then return canvas end
  local catching = self.catching
  local game = catching and catching.game and catching:game()
  local ow = catching and catching.overworld and catching:overworld()
  if not self:shouldDraw(game, ow) then return canvas end
  if not (love and love.graphics) then return canvas end
  -- Gen1: owwild_ball_hud is the sole render owner. Gen2: drawScreen via
  -- render.hud → presentGold. No cross-pipeline frame dedup.
  self._hudDrawCount = (self._hudDrawCount or 0) + 1

  local lg = love.graphics
  local Font = self.mod.ui and self.mod.ui.Font
  local selected = catching:getSelectedBall(game)

  if not opts.skipPush then
    lg.push("all")
  end
  if canvas and not opts.skipCanvas then
    lg.setCanvas(canvas)
  end
  if not opts.skipOrigin then
    lg.origin()
  end
  lg.setColor(1, 1, 1, 1)

  -- Top-right of the 160×144 Game Boy canvas (Gen1). Gold drawScreen
  -- passes anchor="topleft" so the same component sits at GOLD_LOGICAL_*.
  local canvasW = (ctx and ctx.width) or 160
  local layout = opts.layout or BallHud.layout(self.mod, canvasW, opts.anchor)
  local y = layout.iconY
  local iconW = layout.iconW
  local gap = layout.gap
  local startX = layout.startX

  for i, ballType in ipairs(BALL_ORDER) do
    local count = ballCount(catching, game, ballType)
    local bx = startX + (i - 1) * (iconW + gap)
    local selectedHere = ballType == selected
    local alpha = 1.0
    if count <= 0 then
      alpha = 0.20
    elseif not selectedHere then
      alpha = 0.42
    end

    -- HUD-only image path (full Ball art). World projectile uses ballImage().
    local img = (catching.ballHudImage and catching:ballHudImage(ballType))
      or catching:ballImage(ballType)
    if img then
      if img.setFilter then img:setFilter("nearest", "nearest") end
      lg.setColor(1, 1, 1, alpha)
      local iw, ih = img:getDimensions()
      local s = iconW / math.max(1, math.max(iw, ih))
      lg.draw(img, bx, y, 0, s, s)
    else
      if selectedHere then
        lg.setColor(0.85, 0.15, 0.15, alpha)
      else
        lg.setColor(0.35, 0.35, 0.35, alpha)
      end
      lg.rectangle("fill", bx + 1, y + 1, iconW - 2, iconW - 2)
    end

    if selectedHere then
      lg.setColor(0, 0, 0, 1)
      local border = layout.selectedBorder or (iconW + 2)
      lg.rectangle("line", bx - 1, y - 1, border, border)
      drawText(Font, lg, "x" .. tostring(count), bx - 1, layout.qtyY)
    end
  end

  -- Power / distance meter: readable 1–6 ladder while charging.
  local meter = catching:meterState()
  if meter and meter.active then
    local mx = layout.meterX or (canvasW - 22)
    local my = layout.meterY
    local rowH = 9
    local power = meter.power or 1
    local marked = CatchMath.roundedPower(power)

    -- Panel background
    lg.setColor(1, 1, 1, 1)
    if Font and Font.drawBox then
      -- tile coords: ~2 tiles wide near right edge
      local tx = math.floor(mx / 8)
      local ty = math.floor(my / 8)
      pcall(Font.drawBox, tx - 1, ty - 1, 4, 8)
    else
      lg.setColor(0, 0, 0, 0.7)
      lg.rectangle("fill", mx - 10, my - 4, 28, rowH * 6 + 8)
      lg.setColor(1, 1, 1, 1)
      lg.rectangle("line", mx - 10, my - 4, 28, rowH * 6 + 8)
    end

    for dist = 6, 1, -1 do
      local row = 6 - dist
      local ry = my + row * rowH
      local label = tostring(dist)
      if dist == marked then
        lg.setColor(0.9, 0.1, 0.1, 1)
        drawText(Font, lg, label .. " <", mx - 6, ry)
      else
        lg.setColor(0, 0, 0, 1)
        drawText(Font, lg, label, mx, ry)
      end
    end
  end

  -- Compact feedback
  if self.feedbackText and now() < self.feedbackUntil then
    lg.setColor(0, 0, 0, 1)
    drawText(Font, lg, self.feedbackText, 8, 8)
  elseif self.feedbackText and now() >= self.feedbackUntil then
    self.feedbackText = nil
  end

  -- Dev overlay catch lines
  if Config.devOverlay(self.mod) then
    local dbg = catching:debugSnapshot()
    if dbg then
      local lines = {
        "CATCH",
        "TARGET=" .. tostring(dbg.target or "-"),
        "BALL=" .. tostring(dbg.ball or "-"),
        "DIST=" .. tostring(dbg.dist or "-"),
        "POWER=" .. tostring(dbg.power or "-"),
        "QUALITY=" .. tostring(dbg.quality or "-"),
        "ANGLE=" .. tostring(dbg.angle or "-"),
      }
      local dy = 56
      for _, line in ipairs(lines) do
        drawText(Font, lg, line, 4, dy)
        dy = dy + 8
      end
    end
  end

  if not opts.skipPush then
    lg.pop()
  end
  return canvas
end

--- Gold screen-space HUD. Logical 160×144, top-left origin, then projected
-- through Game2:viewport (gameX/gameY/scale). render.hud is window-space.
function BallHud:drawScreen(viewport)
  if not Config.catchHudEnabled(self.mod) then return end
  local catching = self.catching
  local game = catching and catching.game and catching:game()
  local ow = catching and catching.overworld and catching:overworld()
  if not self:shouldDraw(game, ow) then return end
  if not (love and love.graphics) then return end
  viewport = viewport or {}
  local layout = BallHud.layout(self.mod, 160, "topleft")
  self:_logGoldHudSpace(viewport, layout)
  local t = BallHud.playfieldTransform(viewport)
  local lg = love.graphics
  lg.push("all")
  lg.origin()
  lg.translate(t.x, t.y)
  lg.scale(t.scale, t.scale)
  self:draw(nil, { width = 160, height = 144 }, {
    skipPush = true,
    skipOrigin = true,
    skipCanvas = true,
    anchor = "topleft",
    layout = layout,
  })
  lg.pop()
end

function BallHud:_logGoldHudSpace(viewport, layout)
  if self._goldHudSpaceLogged then return end
  if not Config.devOverlay(self.mod) then return end
  self._goldHudSpaceLogged = true
  local lg = love and love.graphics
  local loveW = (lg and lg.getWidth) and lg.getWidth() or nil
  local loveH = (lg and lg.getHeight) and lg.getHeight() or nil
  local canvasW, canvasH = "n/a", "n/a"
  print(string.format(
    "[Wilds][Catch][Gold][HUD] ctx.width=%s ctx.height=%s canvas:getWidth=%s canvas:getHeight=%s love.graphics.getWidth=%s love.graphics.getHeight=%s layout.canvasW=%s startX=%s iconY=%s hudOrigin=(%s,%s) meterX=%s viewport.gameX=%s gameY=%s scale=%s",
    tostring(viewport and viewport.width),
    tostring(viewport and viewport.height),
    tostring(canvasW), tostring(canvasH),
    tostring(loveW), tostring(loveH),
    tostring(layout.canvasW), tostring(layout.startX), tostring(layout.iconY),
    tostring(layout.hudOriginX), tostring(layout.hudOriginY),
    tostring(layout.meterX),
    tostring(viewport and viewport.gameX),
    tostring(viewport and viewport.gameY),
    tostring(viewport and viewport.scale)
  ))
end

function BallHud:register()
  if self._registered then return end
  local mod = self.mod
  if not (mod.content and mod.content.render_pipelines
          and mod.content.render_pipelines.register) then
    return
  end
  local hud = self
  mod.content.render_pipelines:register(BallHud.PIPELINE_ID, {
    label = "OW CATCH HUD",
    levels = { "OFF", "ON" },
    priority = 6,
    available = function()
      return Config.overworldCatchingEnabled(mod) == true
        and Config.isEnabled(mod) == true
    end,
    present = function(canvas, ctx)
      -- Gold HUD is render.hud (screen-space). Do not also paint present.
      local catching = hud.catching
      hud._ballHudPresentCount = (hud._ballHudPresentCount or 0) + 1
      if catching and GameCompat.isGen2(catching.mod, catching:game()) then
        return canvas
      end
      return hud:draw(canvas, ctx)
    end,
  })
  self._registered = true
  self:syncPipelineLevel()
  self:hideFromEngineOptions()
end

function BallHud:hideFromEngineOptions()
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or not Pipelines or type(Pipelines.rows) ~= "function" then return end
  if self._rowsPatched then return end
  local origRows = Pipelines.rows
  Pipelines.rows = function(game)
    local rows = origRows(game)
    local out = {}
    for _, row in ipairs(rows or {}) do
      if not (row and row.id == "pipeline:" .. BallHud.PIPELINE_ID) then
        out[#out + 1] = row
      end
    end
    return out
  end
  self._rowsPatched = true
  self._origRows = origRows
end

function BallHud:syncPipelineLevel()
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or not Pipelines or not Pipelines.setLevel then return end
  if Config.overworldCatchingEnabled(self.mod) and Config.isEnabled(self.mod) then
    Pipelines.setLevel(BallHud.PIPELINE_ID, 1)
  else
    Pipelines.setLevel(BallHud.PIPELINE_ID, 0)
  end
end

BallHud.BALL_ORDER = BALL_ORDER
BallHud.BALL_SHORT = BALL_SHORT

return BallHud
