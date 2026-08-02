-- Grass occlusion unit tests (no Gen1Recomp required).
-- Run: lua54 tests/grass_occlusion_unit_test.lua
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
  mod = { path = ".", options = { get = function() return nil end } },
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
    show_pokemon_in_grass = true,
  },
  get = function(_, key)
    return modules.config.DEFAULTS[key]
  end,
}
modules.surface = {
  GRASS = "GRASS", WATER = "WATER", CAVE = "CAVE",
  usesGrassOverlay = function(s) return s == "GRASS" end,
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }

local GrassOcclusion = V.require("grass_occlusion")

eq(GrassOcclusion.normalizeMode("above"), "above", "normalize above")
eq(GrassOcclusion.normalizeMode("immersed"), "immersed", "normalize immersed")
eq(GrassOcclusion.normalizeMode("nope"), "immersed", "invalid -> immersed")
eq(GrassOcclusion.mode(V.mod), "immersed", "default immersed")

-- Legacy false → above
V.mod.options.get = function(_, key)
  if key == "show_pokemon_in_grass" then return false end
  return nil
end
eq(GrassOcclusion.mode(V.mod), "above", "legacy show_pokemon_in_grass=false → above")

V.mod.options.get = function(_, key)
  if key == "pokemon_grass_render_mode" then return "above" end
  return nil
end
eq(GrassOcclusion.mode(V.mod), "above", "explicit above")

V.mod.options.get = function(_, key)
  if key == "pokemon_grass_render_mode" then return "immersed" end
  return nil
end
eq(GrassOcclusion.mode(V.mod), "immersed", "explicit immersed")

local h16 = GrassOcclusion.computeOcclusionHeight(16)
check(h16 >= 2 and h16 <= 6, "16px occlusion in range")
check(16 - h16 >= 8, "16px keeps min visible")

local h32 = GrassOcclusion.computeOcclusionHeight(32)
check(h32 >= 2 and h32 <= 6, "32px occlusion capped by engine cover")
check(h32 <= math.floor(32 * 0.32), "32px within max ratio")

local ent = {
  surface = "GRASS",
  visibleSprite = true,
  hiddenEncounter = false,
  cellX = 2, cellY = 3,
  tuck = 0,
  grassOcclusionHeight = 4,
  mod = V.mod,
}
local map = {
  isGrassCell = function(_, x, y) return x == 2 and y == 3 end,
}
GrassOcclusion.updateInGrassFlag(ent, V.mod, map)
check(ent.inGrassOverlay == true, "in grass")
check(ent.grassOcclusionActive == true, "occlusion active immersed")

V.mod.options.get = function(_, key)
  if key == "pokemon_grass_render_mode" then return "above" end
  return nil
end
GrassOcclusion.updateInGrassFlag(ent, V.mod, map)
check(ent.inGrassOverlay == true, "still in grass when above")
check(ent.grassOcclusionActive == false, "occlusion off in above mode")

local water = {
  surface = "WATER", visibleSprite = true, cellX = 2, cellY = 3, mod = V.mod,
}
GrassOcclusion.updateInGrassFlag(water, V.mod, map)
check(water.grassOcclusionActive ~= true, "water never grass-occluded")

local hidden = {
  surface = "GRASS", hiddenEncounter = true, visibleSprite = false,
  cellX = 2, cellY = 3, mod = V.mod,
}
GrassOcclusion.updateInGrassFlag(hidden, V.mod, map)
check(hidden.grassOcclusionActive ~= true, "hidden has no sprite occlusion")

-- Tuck: above + flat engine overdraw lifts full cover
ent.inGrassOverlay = true
local tuckAbove = GrassOcclusion.tuckDelta(ent, {
  mode = "above", engineOverdrawExpected = true, engineCover = 8,
})
eq(tuckAbove, -8, "above flat lifts by engine cover")

local tuckVoxelAbove = GrassOcclusion.tuckDelta(ent, {
  mode = "above", engineOverdrawExpected = false,
})
eq(tuckVoxelAbove, 0, "above voxel needs no lift")

ent.grassOcclusionHeight = 4
local tuckImm = GrassOcclusion.tuckDelta(ent, {
  mode = "immersed", engineCover = 6,
})
eq(tuckImm, -2, "immersed relative lift")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("all grass occlusion unit tests passed")
