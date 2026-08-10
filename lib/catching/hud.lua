-- Small top-right Poké Ball inventory HUD + throw power meter.
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
  if not Config.overworldCatchingEnabled(self.mod) then return false end
  if not game or not ow then return false end
  if not self.catching or not self.catching:canShowHud(game, ow) then
    return false
  end
  return true
end

local function ballCount(game, ballType)
  local inv = game and game.save and game.save.inventory
  if not inv then return 0 end
  return tonumber(inv[ballType]) or 0
end

function BallHud:draw(canvas, ctx)
  if not (love and love.graphics) then return canvas end
  local catching = self.catching
  local game = catching and catching:game()
  local ow = catching and catching:overworld()
  if not self:shouldDraw(game, ow) then return canvas end

  local lg = love.graphics
  local Font = self.mod.ui and self.mod.ui.Font
  local selected = catching:getSelectedBall(game)
  local scale = 1
  if ctx and ctx.scale then
    scale = math.max(1, math.floor((ctx.scale or 1) * 0.5 + 0.5))
  end

  -- Top-right corner of the 160×144 Game Boy canvas.
  local canvasW = 160
  local xRight = canvasW - 4
  local y = 4
  local iconW = 10
  local gap = 2

  lg.push("all")
  lg.setColor(1, 1, 1, 1)

  local startX = xRight - (#BALL_ORDER * (iconW + gap))
  for i, ballType in ipairs(BALL_ORDER) do
    local count = ballCount(game, ballType)
    local bx = startX + (i - 1) * (iconW + gap)
    local selectedHere = ballType == selected
    local alpha = 1.0
    if count <= 0 then
      alpha = 0.22
    elseif not selectedHere then
      alpha = 0.45
    end
    lg.setColor(1, 1, 1, alpha)

    local img = catching:ballImage(ballType)
    if img then
      local iw, ih = img:getDimensions()
      local s = iconW / math.max(iw, ih)
      lg.draw(img, bx, y, 0, s, s)
    else
      -- Fallback: tiny filled square
      if selectedHere then
        lg.setColor(0.9, 0.2, 0.2, alpha)
      else
        lg.setColor(0.5, 0.5, 0.5, alpha)
      end
      lg.rectangle("fill", bx + 1, y + 1, iconW - 2, iconW - 2)
    end

    if selectedHere then
      lg.setColor(0, 0, 0, 1)
      lg.rectangle("line", bx, y, iconW, iconW)
      local qty = "x" .. tostring(count)
      if Font and Font.draw then
        Font.draw(qty, bx - 2, y + iconW + 1)
      else
        lg.setColor(0, 0, 0, 1)
        lg.print(qty, bx - 2, y + iconW + 1)
      end
    end
  end

  -- Power meter (while charging throw).
  local meter = catching:meterState()
  if meter and meter.active then
    local mx = canvasW - 14
    local my = 28
    local mh = 48
    lg.setColor(0, 0, 0, 0.55)
    lg.rectangle("fill", mx - 1, my - 1, 8, mh + 2)
    lg.setColor(1, 1, 1, 0.9)
    lg.rectangle("line", mx, my, 6, mh)
    -- Marker: power 1..6 maps bottom→top
    local t = (meter.power - 1) / 5
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local myPos = my + mh - (t * mh)
    lg.setColor(0.9, 0.15, 0.15, 1)
    lg.rectangle("fill", mx - 1, myPos - 1, 8, 3)
    if Font and Font.draw then
      lg.setColor(0, 0, 0, 1)
      Font.draw(tostring(math.floor(meter.power + 0.5)), mx - 10, myPos - 4)
    end
  end

  -- Compact feedback
  if self.feedbackText and now() < self.feedbackUntil then
    local text = self.feedbackText
    local tx = 8
    local ty = 8
    if Font and Font.draw then
      lg.setColor(0, 0, 0, 1)
      Font.draw(text, tx, ty)
    else
      lg.setColor(0, 0, 0, 1)
      lg.print(text, tx, ty)
    end
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
        if Font and Font.draw then
          Font.draw(line, 4, dy)
        else
          lg.print(line, 4, dy)
        end
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
  if Config.overworldCatchingEnabled(self.mod) then
    Pipelines.setLevel(BallHud.PIPELINE_ID, 1)
  else
    Pipelines.setLevel(BallHud.PIPELINE_ID, 0)
  end
end

BallHud.BALL_ORDER = BALL_ORDER
BallHud.BALL_SHORT = BALL_SHORT

return BallHud
