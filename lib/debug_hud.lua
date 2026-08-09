-- On-screen spawn diagnostics via a present-only render_pipelines record.
-- Public Gen1Recomp API: mod.content.render_pipelines:register + present().
-- Visibility is gated by Developer mode; the pipeline level is synced live.
local V = ...
local Config = V.require("config")
local Diagnostics = V.require("diagnostics")

local DebugHud = {}
DebugHud.__index = DebugHud

DebugHud.PIPELINE_ID = "owwild_debug_hud"

local function now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

function DebugHud.new(mod, logic)
  local self = setmetatable({}, DebugHud)
  self.mod = mod
  self.logic = logic
  self._registered = false
  return self
end

function DebugHud:shouldShow()
  if not Config.devMode(self.mod) then return false end
  if Config.hudAlwaysVisible(self.mod) then return true end
  local shownAt = self.logic.state.hudShownAt
  if not shownAt then return false end
  return (now() - shownAt) < Config.HUD_SHOW_SECONDS
end

function DebugHud:markMapEnter()
  self.logic.state.hudShownAt = now()
end

function DebugHud:syncPipelineLevel()
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or not Pipelines or not Pipelines.setLevel then return end
  if Config.devMode(self.mod) then
    Pipelines.setLevel(DebugHud.PIPELINE_ID, 1)
  else
    Pipelines.setLevel(DebugHud.PIPELINE_ID, 0)
  end
end

function DebugHud:register()
  if self._registered then return end
  --- "WILDS HUD" only appears in the pipeline menu when dev mode is on.
  if not Config.debug(self.mod) then self._registered = true; return end
  local mod = self.mod
  local hud = self

  mod.content.render_pipelines:register(DebugHud.PIPELINE_ID, {
    label = "WILDS HUD",
    levels = { "OFF", "ON" },
    priority = 5,
    available = function()
      return Config.devMode(mod) == true
    end,
    present = function(canvas, ctx)
      if not hud:shouldShow() then return canvas end
      if not (love and love.graphics) then return canvas end
      local lines = Diagnostics.hudLines(hud.logic)
      local scale = 1
      if ctx and ctx.scale then
        scale = math.max(1, math.floor((ctx.scale or 1) * 0.5 + 0.5))
      end
      local lineH = 10
      local pad = 4
      local maxW = 0
      local Font = mod.ui and mod.ui.Font
      for _, line in ipairs(lines) do
        local w = Font and Font.width and Font.width(line) or (#line * 8)
        if w > maxW then maxW = w end
      end
      local boxW = maxW + pad * 2
      local boxH = (#lines * lineH) + pad * 2
      local ww = (ctx and ctx.width) or (love.graphics.getWidth and love.graphics.getWidth()) or 160
      local x = math.max(4, ww - (boxW * scale) - 8)
      local y = 8

      love.graphics.push("all")
      love.graphics.setCanvas(canvas)
      love.graphics.origin()
      love.graphics.setColor(0, 0, 0, 0.72)
      love.graphics.rectangle("fill", x, y, boxW * scale, boxH * scale)
      love.graphics.setColor(0.2, 0.85, 0.35, 0.9)
      love.graphics.rectangle("line", x, y, boxW * scale, boxH * scale)
      love.graphics.translate(x, y)
      love.graphics.scale(scale, scale)
      love.graphics.setColor(1, 1, 1, 1)
      for i, line in ipairs(lines) do
        local ly = pad + (i - 1) * lineH
        if Font and Font.draw then
          Font.draw(line, pad, ly)
        elseif love.graphics.print then
          love.graphics.print(line, pad, ly)
        end
      end
      love.graphics.pop()
      return canvas
    end,
  })

  self._registered = true
  self:syncPipelineLevel()
end

return DebugHud
