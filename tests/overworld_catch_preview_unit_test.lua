-- Ground throw-range preview cell math + lifecycle helpers.
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

-- Rounding shared with land / HUD
eq(CatchMath.roundedPower(1.0), 1, "1.0 → 1")
eq(CatchMath.roundedPower(1.49), 1, "1.49 → 1")
eq(CatchMath.roundedPower(1.5), 2, "1.5 → 2")
eq(CatchMath.roundedPower(5.5), 6, "5.5 → 6")
eq(CatchMath.roundedPower(6.0), 6, "6.0 → 6")
eq(CatchMath.roundedPower(9), 6, "clamp max 6")
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
eq(#cells("right", 1.2), 1, "power 1.2 → 1 tile")

-- Target highlight flag (visual only)
local logic = { entities = {} }
local wild = {
  id = "w1", cellX = 12, cellY = 10,
  overworldWildSpawn = true, visibleSprite = true, state = "available",
}
logic.entities.w1 = wild
player.facing = "right"
local preview = RangePreview.cells(player, 3, logic, {})
eq(preview[1].hasTarget, false, "cell 1 no target")
eq(preview[2].hasTarget, true, "cell 2 has target highlight")
eq(preview[3].hasTarget, false, "cell 3 no target")

-- Lifecycle: inactive when meter not active
local catching = {
  meter = { active = false, power = 3 },
  phase = "idle",
  logic = logic,
  game = function() return nil end,
  overworld = function() return { player = player, camera = { x = 0, y = 0 } } end,
  canShowHud = function() return true end,
}
-- draw is a no-op without love; just ensure it does not error
RangePreview.draw(nil, { scale = 1 }, catching)
catching.meter.active = true
catching.phase = "metering"
RangePreview.draw(nil, { scale = 1 }, catching)
check(true, "preview draw safe without love graphics")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("overworld_catch_preview_unit_test: all passed")
