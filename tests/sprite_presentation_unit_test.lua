-- Wilds SpritePresentation adapters: stepFlip + raw true-color wrap.
-- Run: luajit tests/sprite_presentation_unit_test.lua
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
  mod = { path = ".", id = "overworld_wild_spawns", log = { info = function() end, warn = function() end } },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

local Pres = V.require("sprite_presentation")

print("== effectiveStepFlip ==")
eq(Pres.effectiveStepFlip(nil, true), true, "nil def keeps flip")
eq(Pres.effectiveStepFlip({}, true), true, "empty def keeps flip")
eq(Pres.effectiveStepFlip({ disableVerticalStepFlip = true }, true), false,
  "flag clears flip")
eq(Pres.effectiveStepFlip({ def = { disableVerticalStepFlip = true } }, true), false,
  "sprite.def form clears flip")

print("== attach wrap stepFlip ==")
local calls = {}
local sprite = {
  def = { disableVerticalStepFlip = true },
  draw = function(self, _px, _py, _cx, _cy, facing, walkPhase, stepFlip)
    calls[#calls + 1] = { facing = facing, walkPhase = walkPhase, stepFlip = stepFlip }
  end,
}
check(Pres.attach(sprite) == true, "attach succeeds")
check(Pres.attach(sprite) == true, "attach idempotent")
sprite:draw(0, 0, 0, 0, "down", 1, true)
sprite:draw(0, 0, 0, 0, "up", 1, true)
sprite:draw(0, 0, 0, 0, "left", 0, false)
sprite:draw(0, 0, 0, 0, "right", 0, true)
eq(#calls, 4, "four draws")
eq(calls[1].stepFlip, false, "down: no vertical stepFlip")
eq(calls[2].stepFlip, false, "up: no vertical stepFlip")
eq(calls[3].stepFlip, false, "left: sf false")
eq(calls[4].stepFlip, false, "right: sf forced false (facing mirror separate)")
eq(calls[4].facing, "right", "right facing preserved for mirror path")

print("== raw truecolor path marks + skips orig when blit works ==")
local origCalled = false
local marked = {}
package.loaded["src.render.PaletteFX"] = {
  markTrueColor = function(x, y, w, h)
    marked[#marked + 1] = { x = x, y = y, w = w, h = h }
  end,
}
_G.love = {
  graphics = {
    setColor = function() end,
    draw = function() end,
    newQuad = function(x, y, w, h, iw, ih)
      return { x = x, y = y, w = w, h = h, iw = iw, ih = ih }
    end,
  },
}
local rawSprite = {
  def = { forceRawTrueColor = true, disableVerticalStepFlip = true },
  image = { getDimensions = function() return 16, 96 end },
  frameWidth = 16,
  frameHeight = 16,
  frameCount = 6,
  frames = { [0] = {}, [1] = {}, [2] = {}, [3] = {}, [4] = {}, [5] = {} },
  getScreenOrigin = function() return 10, 20 end,
  getPoseGeometry = function(_self, facing, _wp, _sf)
    local frame = 0
    local mirror = false
    if facing == "up" then frame = 1
    elseif facing == "left" or facing == "right" then frame = 2 end
    if facing == "right" then mirror = true end
    return { frame = frame, mirror = mirror }
  end,
  draw = function()
    origCalled = true
  end,
}
check(Pres.attach(rawSprite) == true, "raw attach")
rawSprite:draw(0, 0, 0, 0, "right", 0, false)
eq(origCalled, false, "raw blit skips engine draw (no DMG remap)")
check(#marked >= 1, "markTrueColor called")
eq(marked[1].x, 10, "mark x")
eq(marked[1].y, 20, "mark y")
eq(marked[1].w, 16, "mark w")

-- Unflagged sprite: attach returns false, no wrap
local plain = {
  def = { trueColor = true },
  draw = function() end,
}
eq(Pres.attach(plain), false, "no wrap without flags")

print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("ALL PASSED")
