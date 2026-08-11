-- True Size scaleInfo / grass occlusion must use frame geometry, not CELL=16.
-- Run: lua tests/true_size_grass_scale_unit_test.lua
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
  mod = {
    path = ".",
    options = { get = function() return "immersed" end },
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
modules.config = {
  DEFAULTS = {
    pokemon_grass_render_mode = "immersed",
    grass_occlusion_px = 6,
  },
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }
modules.surface = {
  usesGrassOverlay = function(s) return s == "GRASS" end,
  GRASS = "GRASS",
}
modules.spawn_fx = { bodyVisible = function() return true end }

local GrassOcclusion = V.require("grass_occlusion")

-- Rattata-like 20px True Size frame: occlusion from real height, not 16.
local cover20 = GrassOcclusion.computeTrueSizeCover(20)
local cover16 = GrassOcclusion.computeOcclusionHeight(16)
local cover32 = GrassOcclusion.computeTrueSizeCover(32)
check(cover20 >= 2 and cover20 <= 6, "20px True Size cover 2–6 (" .. tostring(cover20) .. ")")
check(cover32 <= 6, "32px Charizard True Size cover capped at 6 (" .. tostring(cover32) .. ")")
check(cover16 <= 8, "16px classic cover bounded")
check(cover20 < GrassOcclusion.ENGINE_BOTTOM_COVER_PX,
      "True Size cover thinner than native 8px drawCellBottom")

modules["variable_size"] = {
  canApplyTrueSize = function() return true end,
}

local entity = {
  mod = V.mod,
  surface = "GRASS",
  cellX = 1, cellY = 1,
  visibleSprite = true,
  final2DScale = 1,
  variableSizeApplied = true,
  -- Stale Classic scaleInfo (the bug): claims 16×16 while SpriteDef is 20×20.
  scaleInfo = { renderedH = 16, contentH = 16 },
  sprite = {
    def = {
      frameWidth = 20,
      frameHeight = 20,
      anchorX = 10,
      anchorY = 20,
    },
  },
}
local fakeMap = {
  isGrassCell = function(_, x, y) return true end,
}
GrassOcclusion.refreshEntity(entity, V.mod, fakeMap)
eq(entity.grassOcclusionHeight, cover20,
   "refreshEntity True Size cover from SpriteDef frameHeight")

-- Classic native (no frameHeight): falls back to scaleInfo/CELL path.
modules["variable_size"] = {
  canApplyTrueSize = function() return false end,
}
local classic = {
  mod = V.mod,
  surface = "GRASS",
  cellX = 1, cellY = 1,
  visibleSprite = true,
  final2DScale = 1,
  variableSizeApplied = false,
  scaleInfo = { renderedH = 16, contentH = 16 },
  sprite = { def = { frames = 6, walker = true } },
}
GrassOcclusion.refreshEntity(classic, V.mod, fakeMap)
eq(classic.grassOcclusionHeight, cover16, "Classic without frameHeight uses 16px path")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nPASS true_size_grass_scale_unit_test")
