-- Runtime sheet walk-frame distinctness + generator walk-column selection.
-- Proves idle/walk frames differ for Gen1 representatives after the column-2 fix.
-- Run: lua tests/runtime_sheet_walk_frames_unit_test.lua
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

-- Minimal PNG IHDR + IDAT reader is heavy; compare frame bytes via Python helper
-- already validated. Here we assert generator walk_col default and Lua-side
-- RuntimeSheets contract, then shell out to a tiny python check if available.

local modules = {}
local V = {
  mod = {
    path = ".",
    log = { info = function() end },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    assets = {
      path = function(_, rel) return "mods/overworld_wild_spawns/" .. rel end,
    },
  },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end
modules.config = { DEFAULTS = {}, get = function() return nil end, debug = function() return false end }
modules.tile = { CELL = 16 }

local RuntimeSheets = V.require("runtime_sheets")
eq = function(a, b, msg)
  check(a == b, string.format("%s (got %s expected %s)", msg, tostring(a), tostring(b)))
end

eq(RuntimeSheets.FRAMES, 6, "frames=6")
eq(RuntimeSheets.WALKER, true, "walker=true")
eq(RuntimeSheets.STAND.down, 0, "STAND down")
eq(RuntimeSheets.WALK.down, 3, "WALK down")
eq(RuntimeSheets.WALK.left, 5, "WALK left")
eq(RuntimeSheets.STAND.right, 2, "right mirrors left stand")
eq(RuntimeSheets.WALK.right, 5, "right mirrors left walk")

-- Pixel compare via python (Pillow available in CI/agent).
local py = io.popen([[python3 - <<'PY'
from PIL import Image
import hashlib, os
rt='assets/generated/followsprites_runtime'
ok=True
for dex in [1,25,151]:
    path=f'{rt}/{dex:03d}-normal.png'
    im=Image.open(path).convert('RGBA')
    assert im.size==(16,96), (dex, im.size)
    frames=[im.crop((0,i*16,16,i*16+16)).tobytes() for i in range(6)]
    if frames[0]==frames[3] or frames[1]==frames[4] or frames[2]==frames[5]:
        print(f'IDENTICAL {dex}')
        ok=False
    else:
        print(f'DISTINCT {dex}')
print('PASS' if ok else 'FAIL')
PY]])
local out = py:read("*a") or ""
py:close()
check(out:find("DISTINCT 1", 1, true) ~= nil, "Bulbasaur idle!=walk")
check(out:find("DISTINCT 25", 1, true) ~= nil, "Pikachu idle!=walk")
check(out:find("DISTINCT 151", 1, true) ~= nil, "Mew idle!=walk")
check(out:find("PASS", 1, true) ~= nil, "all sample sheets distinct")

-- Generator walk_col default prefers column 2.
local gpy = io.popen([[python3 - <<'PY'
import importlib.util
spec=importlib.util.spec_from_file_location('gen','tools/generate_runtime_sprite_sheets.py')
gen=importlib.util.module_from_spec(spec); spec.loader.exec_module(gen)
layout={'walkColumns':[0,1,2,3],'idleColumn':0}
print(gen.walk_col(layout))
PY]])
local goul = (gpy:read("*a") or ""):gsub("%s+", "")
gpy:close()
eq(goul, "2", "walk_col default is column 2")

-- Battle-sprite isolation: applyProviderSprite must not write pokemon fronts.
local src = assert(io.open("lib/spawn_render.lua", "r"))
local body = src:read("*a")
src:close()
check(not body:find("spriteFront%s*="), "spawn_render never assigns spriteFront")
check(not body:find("spriteBack%s*="), "spawn_render never assigns spriteBack")
local fsrc = assert(io.open("lib/followers_water_compat.lua", "r"))
local fbody = fsrc:read("*a")
fsrc:close()
check(not fbody:find("tryPublicFollowerSpriteApi"), "no speculative Followers API probes")
check(not fbody:find("refreshFollowerSprite"), "no guessed refreshFollowerSprite calls")
check(fbody:find("getActiveFollowerMon", 1, true) ~= nil, "uses verified getActiveFollowerMon")

if failures > 0 then
  io.stderr:write(("\n%d failure(s)\n"):format(failures))
  os.exit(1)
end
print("\nAll runtime_sheet_walk_frames tests passed.")
