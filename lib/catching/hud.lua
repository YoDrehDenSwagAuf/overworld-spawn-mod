-- Small top-right Poké Ball inventory HUD + throw power meter.
-- Draws onto the render-pipeline canvas (must setCanvas), matching DebugHud.
local V = ...
local Config = V.require("config")

local BallHud = {}
BallHud.__index = BallHud

BallHud.PIPELINE_ID = "owwild_ball_hud"

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
  if self.catching.canShowHud then
    return self.catching:canShowHud(game, ow) == true
  end
  if not Config.overworldCatchingEnabled(self.mod) then return false end
  if not Config.isEnabled(self.mod) then return false end
  if not game or not ow or not ow.player then return false end
  if self.catching.safariBlocks and self.catching:safariBlocks(game, ow) then
    return false
  end
  if self.catching.logic and self.catching.logic.pendingBattle then
    return false
  end
  return true
end

local function ballCount(game, ballType)
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

function BallHud:draw(canvas, ctx)
  if not (love and love.graphics) then return canvas end
  -- Dedup when both owwild_catching_tick and owwild_ball_hud present run.
  local frame = self._frame or 0
  if self._drawnFrame == frame and frame > 0 then
    return canvas
  end
  self._drawnFrame = frame

  local catching = self.catching
  local game = catching and catching:game()
  local ow = catching and catching:overworld()
  if not self:shouldDraw(game, ow) then return canvas end

  local lg = love.graphics
  local Font = self.mod.ui and self.mod.ui.Font
  local selected = catching:getSelectedBall(game)

  lg.push("all")
  if canvas then
    lg.setCanvas(canvas)
  end
  lg.origin()
  lg.setColor(1, 1, 1, 1)

  -- Top-right of the 160×144 Game Boy canvas.
  local canvasW = (ctx and ctx.width) or 160
  if canvasW > 200 then canvasW = 160 end
  local y = 2
  local iconW = 12
  local gap = 2
  local startX = canvasW - 4 - (#BALL_ORDER * (iconW + gap))

  for i, ballType in ipairs(BALL_ORDER) do
    local count = ballCount(game, ballType)
    local bx = startX + (i - 1) * (iconW + gap)
    local selectedHere = ballType == selected
    local alpha = 1.0
    if count <= 0 then
      alpha = 0.20
    elseif not selectedHere then
      alpha = 0.42
    end

    local img = catching:ballImage(ballType)
    if img then
      lg.setColor(1, 1, 1, alpha)
      local iw, ih = img:getDimensions()
      local s = iconW / math.max(iw, ih)
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
      lg.rectangle("line", bx, y, iconW, iconW)
      drawText(Font, lg, "x" .. tostring(count), bx - 1, y + iconW + 1)
    end
  end

  -- Power / distance meter: readable 1–6 ladder while charging.
  local meter = catching:meterState()
  if meter and meter.active then
    local mx = canvasW - 22
    local my = 28
    local rowH = 9
    local power = meter.power or 1
    local marked = math.max(1, math.min(6, math.floor(power + 0.5)))

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

  lg.pop()
  return canvas
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
