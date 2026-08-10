-- Temporary green throw-distance overlay on overworld cells while metering.
-- Visual only: does not mutate map tiles, collision, occupancy, or walkability.
--
-- Coordinate contract (critical for Dramatic Shape zoom):
--   Flat:  native overworld canvas space = cell*CELL - camera  (NO ctx.scale)
--   Voxel: Dramatic Shape project(wx,wy) from drawFx only (tile-center markers)
-- Never mix camera-subtract Flat math with window/Voxel zoom scale.
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

-- Latest metering snapshot for Voxel drawFx (resolved every draw; never stale zoom).
RangePreview._pending = nil

--- Shared rounding with landCell / HUD marker.
function RangePreview.tilesFromPower(power)
  return CatchMath.roundedPower(power)
end

function RangePreview.isVoxelActive(mod)
  if not mod then return false end
  local ok, WaterDisplay = pcall(function() return V.require("water_display") end)
  if ok and WaterDisplay and type(WaterDisplay.isVoxelCameraActive) == "function" then
    local ok2, active = pcall(WaterDisplay.isVoxelCameraActive, mod)
    if ok2 then return active == true end
  end
  local world = mod.world
  local ow = world and world.overworld and world:overworld()
  if not ow then return false end
  if ow.cameraMode == "VOXEL" or ow.cameraMode == "voxel" then return true end
  if ow.renderer == "DRAMATIC_SHAPE" or ow.worldRenderer == "DRAMATIC_SHAPE" then
    return true
  end
  return false
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
    if logic and logic.entities then
      for _, entity in pairs(logic.entities) do
        if entity and entity.cellX == x and entity.cellY == y
           and Target.isCatchableWild(entity) then
          hasTarget = true
          break
        end
      end
    end
    out[#out + 1] = { x = x, y = y, step = step, hasTarget = hasTarget }
  end
  return out
end

--- Flat world→canvas: camera-relative native pixels. Do NOT apply ctx.scale.
function RangePreview.worldToScreenFlat(cellX, cellY, cam)
  local camX = (cam and cam.x) or 0
  local camY = (cam and cam.y) or 0
  local sx = (cellX or 0) * CELL - camX
  local sy = (cellY or 0) * CELL - camY
  return sx, sy, CELL, CELL
end

--- Voxel world→screen via Dramatic Shape project(wx, wy).
-- Returns sx, sy (marker center) or nil.
function RangePreview.worldToScreenProject(cellX, cellY, project)
  if type(project) ~= "function" then return nil end
  local wx = (cellX or 0) * CELL + CELL * 0.5
  local wy = (cellY or 0) * CELL + CELL * 0.5
  local ok, sx, sy = pcall(project, wx, wy)
  if not ok or sx == nil then return nil end
  return sx, sy
end

function RangePreview.clear()
  RangePreview._pending = nil
end

--- Refresh pending cells while metering (call from catching tick).
function RangePreview.sync(catching)
  if not catching or not catching.meter or not catching.meter.active
     or catching.phase ~= "metering" then
    RangePreview.clear()
    return nil
  end
  local game = catching.game and catching:game() or nil
  local ow = catching.overworld and catching:overworld() or nil
  if not ow or not ow.player then
    RangePreview.clear()
    return nil
  end
  if catching.canShowHud and not catching:canShowHud(game, ow) then
    RangePreview.clear()
    return nil
  end
  local cells = RangePreview.cells(ow.player, catching.meter.power, catching.logic, ow)
  RangePreview._pending = {
    cells = cells,
    mod = catching.mod,
    cam = (ow.camera) or nil,
  }
  return cells
end

local function drawFlatCells(lg, cells, cam)
  for _, cell in ipairs(cells) do
    local sx, sy, w, h = RangePreview.worldToScreenFlat(cell.x, cell.y, cam)
    local col = cell.hasTarget and COLOR_TARGET or COLOR_NORMAL
    lg.setColor(col[1], col[2], col[3], col[4])
    lg.rectangle("fill", sx, sy, w, h)
    if cell.hasTarget then
      lg.setColor(OUTLINE_TARGET[1], OUTLINE_TARGET[2], OUTLINE_TARGET[3], OUTLINE_TARGET[4])
      lg.rectangle("line", sx + 0.5, sy + 0.5, w - 1, h - 1)
    end
  end
end

local function drawProjectedMarkers(lg, cells, project)
  local any = false
  for _, cell in ipairs(cells) do
    local sx, sy = RangePreview.worldToScreenProject(cell.x, cell.y, project)
    if sx then
      any = true
      local half = cell.hasTarget and 4 or 3
      local col = cell.hasTarget and COLOR_TARGET or COLOR_NORMAL
      lg.setColor(col[1], col[2], col[3], col[4])
      -- Small world-projected marker (not a fake Flat 16×16 screen rect).
      lg.polygon("fill",
        sx, sy - half,
        sx + half, sy,
        sx, sy + half,
        sx - half, sy)
      if cell.hasTarget then
        lg.setColor(OUTLINE_TARGET[1], OUTLINE_TARGET[2], OUTLINE_TARGET[3], OUTLINE_TARGET[4])
        lg.polygon("line",
          sx, sy - half,
          sx + half, sy,
          sx, sy + half,
          sx - half, sy)
      end
    end
  end
  return any
end

--- Flat / non-Voxel draw from catching present(). Skips when Voxel camera active.
function RangePreview.draw(canvas, ctx, catching)
  RangePreview.sync(catching)
  local pending = RangePreview._pending
  if not pending or not pending.cells or #pending.cells == 0 then return end
  if not (love and love.graphics) then return end

  -- Voxel uses drawFx/project exclusively — never Flat cam*scale fallback.
  if RangePreview.isVoxelActive(pending.mod or (catching and catching.mod)) then
    return
  end

  local cam = (ctx and ctx.cam) or pending.cam
  local lg = love.graphics
  lg.push("all")
  if canvas then lg.setCanvas(canvas) end
  -- Native canvas space; do not multiply by ctx.scale / window zoom.
  drawFlatCells(lg, pending.cells, cam)
  lg.setColor(1, 1, 1, 1)
  lg.pop()
end

--- Voxel / Dramatic Shape path — called from voxel_adapter drawFx with live project().
function RangePreview.drawVoxel(project, _scale)
  local pending = RangePreview._pending
  if not pending or not pending.cells or #pending.cells == 0 then return end
  if type(project) ~= "function" then return end
  if not (love and love.graphics) then return end
  local lg = love.graphics
  lg.push("all")
  drawProjectedMarkers(lg, pending.cells, project)
  lg.setColor(1, 1, 1, 1)
  lg.pop()
end

RangePreview.MAX = MAX
RangePreview.CELL = CELL

return RangePreview
