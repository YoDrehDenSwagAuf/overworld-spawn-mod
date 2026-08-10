-- Temporary green throw-distance overlay on overworld cells while metering.
-- Visual only: does not mutate map tiles, collision, occupancy, or walkability.
local V = ...
local Tile = V.require("tile")
local CatchMath = V.require("catching/catch_math")
local Target = V.require("catching/target")

local RangePreview = {}

local CELL = Tile.CELL or 16
local MAX = CatchMath.MAX_RANGE or 6

local COLOR_NORMAL = { 0.20, 0.85, 0.35, 0.32 }
local COLOR_TARGET = { 0.15, 0.95, 0.40, 0.48 }
local OUTLINE_TARGET = { 0.05, 0.55, 0.15, 0.85 }

--- Shared rounding with landCell / HUD marker.
function RangePreview.tilesFromPower(power)
  return CatchMath.roundedPower(power)
end

--- Cells 1..tiles along facing from the player. No walkability filtering.
-- Returns list of { x=, y=, step=, hasTarget= }.
function RangePreview.cells(player, power, logic, ow)
  if not player then return {} end
  local px, py = player.cellX, player.cellY
  if px == nil or py == nil then return {} end
  local facing = Target.facingOf(player)
  local d = Target.DIR[facing]
  if not d then return {} end
  local tiles = RangePreview.tilesFromPower(power)
  local out = {}
  for step = 1, tiles do
    local x = px + d[1] * step
    local y = py + d[2] * step
    local hasTarget = false
    if logic or ow then
      -- Soft visual only — reuse catchable filter, do not change gameplay.
      if logic and logic.entities then
        for _, entity in pairs(logic.entities) do
          if entity and entity.cellX == x and entity.cellY == y
             and Target.isCatchableWild(entity) then
            hasTarget = true
            break
          end
        end
      end
    end
    out[#out + 1] = { x = x, y = y, step = step, hasTarget = hasTarget }
  end
  return out
end

local function cameraOf(ow, ctx)
  if ctx and ctx.cam then return ctx.cam end
  return ow and ow.camera or nil
end

local function drawCellFlat(lg, cell, cam, scale, offX, offY)
  local camX = cam and (cam.x or 0) or 0
  local camY = cam and (cam.y or 0) or 0
  local wx = cell.x * CELL - camX
  local wy = cell.y * CELL - camY
  local sx = offX + wx * scale
  local sy = offY + wy * scale
  local size = CELL * scale
  local col = cell.hasTarget and COLOR_TARGET or COLOR_NORMAL
  lg.setColor(col[1], col[2], col[3], col[4])
  lg.rectangle("fill", sx, sy, size, size)
  if cell.hasTarget then
    lg.setColor(OUTLINE_TARGET[1], OUTLINE_TARGET[2], OUTLINE_TARGET[3], OUTLINE_TARGET[4])
    lg.rectangle("line", sx + 0.5, sy + 0.5, size - 1, size - 1)
  end
end

local function drawCellProjected(lg, cell, project)
  local wx = cell.x * CELL + CELL * 0.5
  local wy = cell.y * CELL + CELL * 0.5
  local ok, sx, sy = pcall(project, wx, wy)
  if not ok or sx == nil then return false end
  local half = 5
  local col = cell.hasTarget and COLOR_TARGET or COLOR_NORMAL
  lg.setColor(col[1], col[2], col[3], col[4])
  lg.rectangle("fill", sx - half, sy - half, half * 2, half * 2)
  if cell.hasTarget then
    lg.setColor(OUTLINE_TARGET[1], OUTLINE_TARGET[2], OUTLINE_TARGET[3], OUTLINE_TARGET[4])
    lg.rectangle("line", sx - half, sy - half, half * 2, half * 2)
  end
  return true
end

--- Draw preview while metering. Safe no-op when inactive / no graphics.
function RangePreview.draw(canvas, ctx, catching)
  if not catching or not catching.meter or not catching.meter.active then
    return
  end
  if catching.phase ~= "metering" then return end
  if not (love and love.graphics) then return end

  local game = catching.game and catching:game() or nil
  local ow = catching.overworld and catching:overworld() or nil
  if not ow or not ow.player then return end
  if catching.canShowHud and not catching:canShowHud(game, ow) then
    return
  end

  local cells = RangePreview.cells(ow.player, catching.meter.power, catching.logic, ow)
  if #cells == 0 then return end

  local lg = love.graphics
  local cam = cameraOf(ow, ctx)
  local scale = (ctx and tonumber(ctx.scale)) or 1
  if scale < 1 then scale = 1 end
  local offX = (ctx and tonumber(ctx.offsetX or ctx.x)) or 0
  local offY = (ctx and tonumber(ctx.offsetY or ctx.y)) or 0
  local project = ctx and ctx.project

  lg.push("all")
  if canvas then lg.setCanvas(canvas) end

  local usedProject = false
  if type(project) == "function" then
    usedProject = true
    for _, cell in ipairs(cells) do
      if not drawCellProjected(lg, cell, project) then
        usedProject = false
        break
      end
    end
  end

  if not usedProject then
    -- Flat 2D world-space rects (and Voxel fallback when no project helper).
    for _, cell in ipairs(cells) do
      drawCellFlat(lg, cell, cam, scale, offX, offY)
    end
  end

  lg.setColor(1, 1, 1, 1)
  lg.pop()
end

RangePreview.MAX = MAX
RangePreview.CELL = CELL

return RangePreview
