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

-- True Size feet-band cover (actual scissor height), not vanilla 8px tile.
local ts20 = GrassOcclusion.computeTrueSizeCover(20)
local ts32 = GrassOcclusion.computeTrueSizeCover(32)
local ts15 = GrassOcclusion.computeTrueSizeCover(15)
check(ts20 >= 2 and ts20 <= 6, "True Size Rattata cover 2–6 (got " .. tostring(ts20) .. ")")
check(ts32 >= 2 and ts32 <= 6, "True Size Charizard cover capped at 6")
check(ts15 <= 4, "True Size small cover aggressive")
check(ts20 < GrassOcclusion.ENGINE_BOTTOM_COVER_PX,
      "True Size cover < native drawCellBottom 8px")

-- True Size entities do not tuck-compensate (wrap owns occlusion).
local tsEnt = {
  inGrassOverlay = true,
  variableSizeApplied = true,
  tuck = 0,
  mod = V.mod,
  grassOcclusionHeight = ts20,
  sprite = { def = { frameWidth = 20, frameHeight = 20, anchorY = 20 } },
}
modules["variable_size"] = {
  canApplyTrueSize = function() return true end,
}
eq(GrassOcclusion.tuckDelta(tsEnt, { mode = "immersed" }), 0,
   "True Size immersed tuck is 0")
eq(GrassOcclusion.tuckDelta(tsEnt, { mode = "above", engineOverdrawExpected = true }), 0,
   "True Size above tuck is 0 (overdraw skipped)")

-- Queue + consume for wrap contract
GrassOcclusion.clearQueues()
V.mod.options.get = function(_, key)
  if key == "pokemon_grass_render_mode" then return "immersed" end
  return nil
end
tsEnt.cellX, tsEnt.cellY = 2, 3
tsEnt.grassOcclusionHeight = 4
local map2 = {
  isGrassCell = function(_, x, y) return x == 2 and y == 3 end,
}
check(GrassOcclusion.queueTrueSizeFeetBand(tsEnt, 0, 0, map2) == true,
      "queues True Size feet band")
local q = GrassOcclusion.takeQueuedBand(2, 3)
check(q ~= nil and q.skip ~= true and q.coverPx == 4, "immersed queue cover=4")
check(GrassOcclusion.takeQueuedBand(2, 3) == nil, "queue consumed once")

V.mod.options.get = function(_, key)
  if key == "pokemon_grass_render_mode" then return "above" end
  return nil
end
tsEnt.inGrassOverlay = true
GrassOcclusion.clearQueues()
check(GrassOcclusion.queueTrueSizeFeetBand(tsEnt, 0, 0, map2) == true,
      "queues Above skip")
local q2 = GrassOcclusion.takeQueuedBand(2, 3)
check(q2 ~= nil and q2.skip == true, "Above mode skips drawCellBottom")

-- Classic entity never queues
local classic = {
  inGrassOverlay = true, variableSizeApplied = false, cellX = 2, cellY = 3,
  mod = V.mod,
}
GrassOcclusion.clearQueues()
check(GrassOcclusion.queueTrueSizeFeetBand(classic, 0, 0, map2) == false,
      "Classic does not queue feet band")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("all grass occlusion unit tests passed")
