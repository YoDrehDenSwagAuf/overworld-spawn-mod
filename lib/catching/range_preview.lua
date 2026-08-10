-- Temporary green throw-distance overlay on overworld cells while metering.
-- Visual only: does not mutate map tiles, collision, occupancy, or walkability.
--
-- Flat coordinate contract (Architecture A):
--   Draw into the SAME native world canvas as tiles / player / NPCs, during
--   OverworldState:drawWorld, BEFORE Renderer:endFrame applies survey zoom
--   (Zoom.scale) when blitting worldCanvas to the window.
--
--   World-canvas math matches TileRenderer / entity draws:
--     sx = cellX * CELL - floor(cam.x)
--     sy = cellY * CELL - floor(cam.y)
--     size = CELL (16×16 world pixels)
--   No Zoom.scale / ctx.scale / window-size multiplication.
--
-- Voxel: ground preview DISABLED (HUD 1–6 meter remains).
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

-- Latest metering snapshot (tests / diagnostics). Live Flat draw syncs from ow.
RangePreview._pending = nil
-- When true, Voxel ground markers stay off (stability > decorative overlay).
RangePreview.VOXEL_GROUND_PREVIEW_ENABLED = false

RangePreview._worldHookInstalled = false
RangePreview._catching = nil
RangePreview._origDrawWorld = nil

--- Shared rounding with landCell / HUD marker.
function RangePreview.tilesFromPower(power)
  return CatchMath.roundedPower(power)
end

local function owLooksVoxel(ow)
  if not ow then return false end
  if ow.cameraMode == "VOXEL" or ow.cameraMode == "voxel" then return true end
  if ow.renderer == "DRAMATIC_SHAPE" or ow.worldRenderer == "DRAMATIC_SHAPE" then
    return true
  end
  return false
end

function RangePreview.isVoxelActive(mod, ow)
  if owLooksVoxel(ow) then return true end
  if not mod then return false end
  local ok, WaterDisplay = pcall(function() return V.require("water_display") end)
  if ok and WaterDisplay and type(WaterDisplay.isVoxelCameraActive) == "function" then
    local ok2, active = pcall(WaterDisplay.isVoxelCameraActive, mod)
    if ok2 then return active == true end
  end
  local world = mod.world
  local worldOw = world and world.overworld and world:overworld()
  return owLooksVoxel(worldOw)
end

--- True when a drawWorld pipeline (e.g. Dramatic Shape) owns the displayed world.
local function worldOwnedByPipeline()
  local okG, Game = pcall(require, "src.core.Game")
  if okG and Game and Game.renderer and Game.renderer.worldOverride then
    return true
  end
  return false
end

local function tiltActive()
  local ok, Tilt = pcall(require, "src.render.Tilt")
  if ok and Tilt and type(Tilt.active) == "function" then
    local ok2, active = pcall(Tilt.active)
    return ok2 and active == true
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

--- Flat world→native world-canvas pixels (same space as TileRenderer batches).
-- Camera is floored to match TileRenderer:drawWindow (-floor(cam)).
-- Do NOT apply Zoom.scale / ctx.scale / window FIT — survey zoom is applied
-- later when Renderer blits worldCanvas.
function RangePreview.worldToScreenFlat(cellX, cellY, cam)
  local camX = math.floor((cam and cam.x) or 0)
  local camY = math.floor((cam and cam.y) or 0)
  local sx = (cellX or 0) * CELL - camX
  local sy = (cellY or 0) * CELL - camY
  return sx, sy, CELL, CELL
end

--- Voxel world→screen via Dramatic Shape project(wx, wy).
-- Kept for unit tests / future ground-plane work. Not used for live Voxel draw
-- while VOXEL_GROUND_PREVIEW_ENABLED is false.
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
-- Clears pending in Voxel mode so stale Flat cells never survive a mode switch.
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
  local mod = catching.mod
  if RangePreview.isVoxelActive(mod, ow) then
    -- Voxel: no ground preview state. HUD meter is independent.
    RangePreview.clear()
    return nil
  end
  local cells = RangePreview.cells(ow.player, catching.meter.power, catching.logic, ow)
  RangePreview._pending = {
    cells = cells,
    mod = mod,
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

--- Draw into the active Flat world canvas (call from OverworldState.drawWorld).
-- Must run while beginWorldPass has worldCanvas current — never from present().
function RangePreview.drawWorldPass(ow, catching)
  catching = catching or RangePreview._catching
  if type(ow) ~= "table" or type(catching) ~= "table" then return end
  if not (love and love.graphics) then return end
  if not catching.meter or not catching.meter.active
     or catching.phase ~= "metering" then
    return
  end
  if RangePreview.isVoxelActive(catching.mod, ow) then return end
  if worldOwnedByPipeline() then return end
  if tiltActive() then return end

  local game = catching.game and catching:game() or nil
  if catching.canShowHud and not catching:canShowHud(game, ow) then
    return
  end
  if not ow.player then return end

  local cells = RangePreview.cells(ow.player, catching.meter.power, catching.logic, ow)
  if not cells or #cells == 0 then return end

  RangePreview._pending = {
    cells = cells,
    mod = catching.mod,
    cam = ow.camera,
  }

  local lg = love.graphics
  -- Do not setCanvas / origin: stay on the engine's current worldCanvas and
  -- any transform the world pass already established (normally identity + cam
  -- baked into draw positions, same as tiles/entities).
  lg.push("all")
  drawFlatCells(lg, cells, ow.camera)
  lg.setColor(1, 1, 1, 1)
  lg.pop()
end

--- Legacy present()-stage entry. Intentionally a no-op for world geometry.
-- Ball HUD still uses present; green tiles must NOT — that was post-zoom.
function RangePreview.draw(_canvas, _ctx, catching)
  -- Keep pending in sync for tests / diagnostics; do not paint presentCanvas.
  if catching then
    RangePreview.sync(catching)
  end
end

--- Voxel / Dramatic Shape path — intentionally a no-op for stability.
function RangePreview.drawVoxel(_project, _scale)
  return
end

--- One-time wrap of OverworldState.drawWorld so Flat preview shares worldCanvas.
-- Idempotent. Does not wrap Voxel drawWorld pipelines or Dramatic Shape.
function RangePreview.installFlatWorldHook(catching)
  if type(catching) == "table" then
    RangePreview._catching = catching
  end
  if RangePreview._worldHookInstalled then
    return true
  end
  local ok, OverworldState = pcall(require, "src.world.OverworldController")
  if not ok or type(OverworldState) ~= "table"
     or type(OverworldState.drawWorld) ~= "function" then
    return false
  end
  if OverworldState._owwildCatchPreviewWrap == OverworldState.drawWorld then
    RangePreview._worldHookInstalled = true
    return true
  end
  local orig = OverworldState.drawWorld
  local function wrap(self, ...)
    local a, b, c, d, e = orig(self, ...)
    -- After tiles/entities/FX: still inside beginWorldPass worldCanvas.
    pcall(RangePreview.drawWorldPass, self, RangePreview._catching)
    return a, b, c, d, e
  end
  OverworldState.drawWorld = wrap
  OverworldState._owwildCatchPreviewWrap = wrap
  RangePreview._origDrawWorld = orig
  RangePreview._worldHookInstalled = true
  return true
end

RangePreview.MAX = MAX
RangePreview.CELL = CELL

return RangePreview
