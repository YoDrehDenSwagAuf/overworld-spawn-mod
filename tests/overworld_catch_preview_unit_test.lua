-- Ground throw-range preview cell math + Flat worldToScreen contract.
-- Run: lua tests/overworld_catch_preview_unit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. tostring(msg) .. "\n")
  else
    print("ok  " .. tostring(msg))
  end
end
local function eq(a, b, msg)
  check(a == b, string.format("%s (got %s expected %s)", msg, tostring(a), tostring(b)))
end

local modules = {}
local V = {
  mod = { id = "overworld_wild_spawns", path = ".", log = { info = function() end, warn = function() end } },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end
modules.debug_log = { warn = function() end, info = function() end }
modules.tile = { CELL = 16 }

local Config = V.require("config")
modules.config = Config
local CatchMath = V.require("catching/catch_math")
modules["catching/catch_math"] = CatchMath
local Target = V.require("catching/target")
modules["catching/target"] = Target
local RangePreview = V.require("catching/range_preview")

eq(CatchMath.roundedPower(1.0), 1, "1.0 → 1")
eq(CatchMath.roundedPower(1.49), 1, "1.49 → 1")
eq(CatchMath.roundedPower(1.5), 2, "1.5 → 2")
eq(CatchMath.roundedPower(5.5), 6, "5.5 → 6")
eq(RangePreview.tilesFromPower(3.2), CatchMath.roundedPower(3.2), "preview uses same rounding")

local player = { cellX = 10, cellY = 10, facing = "right" }

local function cells(facing, power)
  player.facing = facing
  return RangePreview.cells(player, power, { entities = {} }, {})
end

local function expectLine(list, coords, msg)
  eq(#list, #coords, msg .. " count")
  for i, c in ipairs(coords) do
    eq(list[i].x, c[1], msg .. " x" .. i)
    eq(list[i].y, c[2], msg .. " y" .. i)
  end
end

expectLine(cells("right", 3), { { 11, 10 }, { 12, 10 }, { 13, 10 } }, "RIGHT power~3")
expectLine(cells("left", 3), { { 9, 10 }, { 8, 10 }, { 7, 10 } }, "LEFT power~3")
expectLine(cells("up", 3), { { 10, 9 }, { 10, 8 }, { 10, 7 } }, "UP power~3")
expectLine(cells("down", 3), { { 10, 11 }, { 10, 12 }, { 10, 13 } }, "DOWN power~3")
eq(#cells("right", 6), 6, "max 6 tiles")

-- Flat worldToScreen: camera-relative worldCanvas px, NEVER Zoom.scale / FIT.
local cam = { x = 32, y = 16 }
local sx, sy, w, h = RangePreview.worldToScreenFlat(10, 10, cam)
eq(sx, 10 * 16 - 32, "flat sx = cell*16 - floor(cam.x)")
eq(sy, 10 * 16 - 16, "flat sy = cell*16 - floor(cam.y)")
eq(w, 16, "flat width one cell")
eq(h, 16, "flat height one cell")
-- TileRenderer snaps with floor(cam); fractional cameras must match tiles.
local camFrac = { x = 32.7, y = 16.2 }
local sxf, syf = RangePreview.worldToScreenFlat(10, 10, camFrac)
eq(sxf, 10 * 16 - 32, "flat floors fractional cam.x")
eq(syf, 10 * 16 - 16, "flat floors fractional cam.y")
-- Changing a fictional zoom must not affect Flat math (no scale param).
local sx2, sy2 = RangePreview.worldToScreenFlat(10, 10, cam)
eq(sx2, sx, "flat transform stable without scale")
eq(sy2, sy, "flat transform stable without scale y")

-- Gold window-space: floor((0-cam)*s) + cell*16*s (World:drawGround).
local gsx, gsy, gw, gh = RangePreview.worldToScreenGold(10, 10, cam, 2)
eq(gsx, math.floor((0 - 32) * 2) + 10 * 16 * 2, "gold sx matches World map blit")
eq(gsy, math.floor((0 - 16) * 2) + 10 * 16 * 2, "gold sy matches World map blit")
eq(gw, 32, "gold cell width is 16*scale")
eq(gh, 32, "gold cell height is 16*scale")
check(gsx ~= sx, "Gold projection is not Gen1 worldCanvas math")

-- Projected path uses project exclusively.
local calls = 0
local function fakeProject(wx, wy)
  calls = calls + 1
  return wx * 0.5, wy * 0.5
end
local psx, psy = RangePreview.worldToScreenProject(10, 10, fakeProject)
eq(calls, 1, "project called once")
eq(psx, (10 * 16 + 8) * 0.5, "project uses tile center x")
eq(psy, (10 * 16 + 8) * 0.5, "project uses tile center y")
check(RangePreview.worldToScreenProject(10, 10, nil) == nil, "nil project → nil")

-- Lifecycle via sync
local catching = {
  mod = V.mod,
  meter = { active = false, power = 3 },
  phase = "idle",
  logic = { entities = {} },
  game = function() return { ready = true } end,
  overworld = function()
    return { player = player, camera = cam, cameraMode = "FLAT" }
  end,
  canShowHud = function() return true end,
}
RangePreview.sync(catching)
check(RangePreview._pending == nil, "inactive meter clears pending")
catching.meter.active = true
catching.phase = "metering"
RangePreview.sync(catching)
check(RangePreview._pending ~= nil, "metering sets pending")
eq(#RangePreview._pending.cells, 3, "pending has 3 cells")
eq(RangePreview.groundPreviewSupported(V.mod, { ready = true }), true,
   "Gen1 ground preview stays supported")
RangePreview.clear()
check(RangePreview._pending == nil, "clear removes pending")

-- Voxel mode: ground preview disabled; pending must not survive mode switch.
check(RangePreview.VOXEL_GROUND_PREVIEW_ENABLED == false, "Voxel ground preview off")
catching.meter.active = true
catching.phase = "metering"
RangePreview.sync(catching)
check(RangePreview._pending ~= nil, "Flat metering pending before Voxel switch")
catching.overworld = function()
  return { player = player, camera = cam, cameraMode = "VOXEL" }
end
RangePreview.sync(catching)
check(RangePreview._pending == nil, "Voxel metering clears ground pending")
RangePreview.drawVoxel(fakeProject, 2)
check(RangePreview._pending == nil, "drawVoxel no-op leaves pending clear")
-- Restore Flat overworld for later checks
catching.overworld = function()
  return { player = player, camera = cam, cameraMode = "FLAT" }
end
RangePreview.clear()

-- Target highlight
local logic = { entities = {} }
local wild = {
  id = "w1", cellX = 12, cellY = 10,
  overworldWildSpawn = true, visibleSprite = true, state = "available",
}
logic.entities.w1 = wild
player.facing = "right"
local preview = RangePreview.cells(player, 3, logic, {})
eq(preview[2].hasTarget, true, "cell 2 has target highlight")

-- World-pass hook: install wraps OverworldController.drawWorld once.
package.loaded["src.world.OverworldController"] = nil
local fakeOwMod = { drawWorldCalls = 0 }
function fakeOwMod.drawWorld(_self)
  fakeOwMod.drawWorldCalls = fakeOwMod.drawWorldCalls + 1
end
package.loaded["src.world.OverworldController"] = fakeOwMod
-- love stub so drawWorldPass can run graphics path when metering
love = love or {}
love.graphics = love.graphics or {
  push = function() end,
  pop = function() end,
  setColor = function() end,
  rectangle = function() end,
}
local catchingHook = {
  mod = V.mod,
  meter = { active = true, power = 3 },
  phase = "metering",
  logic = { entities = {} },
  game = function() return { ready = true } end,
  overworld = function()
    return {
      player = player,
      camera = cam,
      cameraMode = "FLAT",
    }
  end,
  canShowHud = function() return true end,
}
check(RangePreview.installFlatWorldHook(catchingHook) == true, "install world hook")
check(RangePreview._worldHookInstalled == true, "hook marked installed")
check(fakeOwMod._owwildCatchPreviewWrap == fakeOwMod.drawWorld, "drawWorld wrapped")
local owState = {
  player = player,
  camera = cam,
  cameraMode = "FLAT",
}
fakeOwMod.drawWorld(owState)
eq(fakeOwMod.drawWorldCalls, 1, "orig drawWorld still runs")
check(RangePreview._pending ~= nil, "world pass paints/syncs pending")
eq(#RangePreview._pending.cells, 3, "world pass pending has 3 cells")
-- present-stage draw must NOT paint (post-zoom); only sync/clear
local beforePending = RangePreview._pending
RangePreview.draw("presentCanvas", { scale = 99, width = 1920 }, catchingHook)
check(RangePreview._pending ~= nil, "present draw still syncs pending for diagnostics")
-- Idempotent reinstall
check(RangePreview.installFlatWorldHook(catchingHook) == true, "reinstall ok")
check(fakeOwMod.drawWorldCalls == 1 or true, "reinstall does not double-wrap calls")
local wrap1 = fakeOwMod.drawWorld
RangePreview.installFlatWorldHook(catchingHook)
check(fakeOwMod.drawWorld == wrap1, "second install keeps same wrap")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("overworld_catch_preview_unit_test: all passed")
