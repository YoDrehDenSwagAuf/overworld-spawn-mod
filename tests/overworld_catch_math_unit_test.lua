-- Catch math: facing, throw quality, level modifier bounds.
-- Run: lua tests/overworld_catch_math_unit_test.lua
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
local function near(a, b, eps, msg)
  check(math.abs(a - b) <= (eps or 1e-9), string.format("%s (got %s expected ~%s)", msg, tostring(a), tostring(b)))
end

local CatchMath = assert(loadfile("lib/catching/catch_math.lua"))()

-- Facing: Pokémon UP
eq(CatchMath.facingAngle(5, 6, 5, 5, "up"), "back", "UP + player south = BACK")
eq(CatchMath.facingAngle(5, 4, 5, 5, "up"), "front", "UP + player north = FRONT")
eq(CatchMath.facingAngle(6, 5, 5, 5, "up"), "side", "UP + player east = SIDE")
eq(CatchMath.facingAngle(4, 5, 5, 5, "up"), "side", "UP + player west = SIDE")

-- Facing: DOWN / LEFT / RIGHT
eq(CatchMath.facingAngle(5, 4, 5, 5, "down"), "back", "DOWN + player north = BACK")
eq(CatchMath.facingAngle(5, 6, 5, 5, "down"), "front", "DOWN + player south = FRONT")
eq(CatchMath.facingAngle(6, 5, 5, 5, "left"), "back", "LEFT + player east = BACK")
eq(CatchMath.facingAngle(4, 5, 5, 5, "left"), "front", "LEFT + player west = FRONT")
eq(CatchMath.facingAngle(4, 5, 5, 5, "right"), "back", "RIGHT + player west = BACK")
eq(CatchMath.facingAngle(6, 5, 5, 5, "right"), "front", "RIGHT + player east = FRONT")

-- Unavailable facing → FRONT / neutral
eq(CatchMath.facingAngle(5, 6, 5, 5, nil), "front", "nil facing = FRONT")
eq(CatchMath.facingAngle(5, 6, 5, 5, ""), "front", "empty facing = FRONT")
eq(CatchMath.facingModifier("front"), 1.00, "FRONT modifier 1.00")
eq(CatchMath.facingModifier("side"), 1.15, "SIDE modifier 1.15")
eq(CatchMath.facingModifier("back"), 1.35, "BACK modifier 1.35")

-- Throw quality windows
eq(CatchMath.throwQuality(3.0, 3.0), "perfect", "exact = PERFECT")
eq(CatchMath.throwQuality(3.15, 3.0), "perfect", "diff 0.15 = PERFECT")
eq(CatchMath.throwQuality(3.4, 3.0), "great", "diff 0.40 = GREAT")
eq(CatchMath.throwQuality(3.8, 3.0), "hit", "diff 0.80 = HIT")
eq(CatchMath.throwQuality(4.1, 3.0), "miss", "diff 1.10 = MISS")
eq(CatchMath.qualityModifier("perfect"), 1.25, "PERFECT ×1.25")
eq(CatchMath.qualityModifier("great"), 1.10, "GREAT ×1.10")
eq(CatchMath.qualityModifier("hit"), 1.00, "HIT ×1.00")

-- Level modifier bounds
near(CatchMath.levelModifier(5), 1.10, 1e-9, "level 5 near upper (1.10)")
check(CatchMath.levelModifier(5) > 1.0, "level 5 above 1.0")
near(CatchMath.levelModifier(50), 0.65, 1e-9, "level 50 at floor (0.65)")
eq(CatchMath.levelModifier(100), 0.65, "level 100 clamps at minimum 0.65")
eq(CatchMath.levelModifier(1), 1.14, "level 1 = 1.14")
check(CatchMath.levelModifier(0) <= 1.15, "level 0 ≤ max")
eq(CatchMath.levelModifier(0), 1.15, "level 0 clamps at max 1.15")

-- Effective rate combines modifiers; ball NOT multiplied here
local rate = CatchMath.effectiveCatchRate(45, 5, "perfect", "back")
-- 45 * 1.10 * 1.25 * 1.35 ≈ 83.4 → 83
check(rate >= 80 and rate <= 86, "mewtwo-ish rate stays modest with bonuses (got " .. rate .. ")")
local mewtwo = CatchMath.effectiveCatchRate(3, 70, "perfect", "back")
check(mewtwo < 20, "Mewtwo catch rate stays hard (got " .. mewtwo .. ")")

eq(CatchMath.feedbackLabel("perfect", "back"), "PERFECT BACK THROW!", "back perfect label")
eq(CatchMath.feedbackLabel("perfect", "front"), "PERFECT!", "front perfect label")
eq(CatchMath.feedbackLabel("great", "side"), "GREAT!", "great label")
eq(CatchMath.feedbackLabel("miss", "front"), "MISS!", "miss label")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("overworld_catch_math_unit_test: all passed")
