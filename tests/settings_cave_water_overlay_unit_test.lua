-- Settings cleanup + cave reachability + water density + Dev Overlay unit tests.
-- Run: lua tests/settings_cave_water_overlay_unit_test.lua
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

local savedOpts = {
  sprite_style = "auto",
  spawn_density = "normal",
  random_encounters = true,
  water_spawns = "swimming_sprites",
  dev_overlay = nil,
  debug = nil,
  dev_mode = nil,
}

local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    options = {
      get = function(_, key) return savedOpts[key] end,
    },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    world = {
      game = {
        save = { options = { modOptions = { overworld_wild_spawns = savedOpts } } },
        mods = { modOptions = { overworld_wild_spawns = savedOpts } },
      },
    },
  },
  path = ".",
}

local modules = {}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

local Config = V.require("config")
local CaveReachability = V.require("cave_reachability")
local DevOverlay = V.require("dev_overlay")
local Behavior = V.require("behavior")
local Grass = V.require("grass")

print("== schema / keys ==")
local schema = assert(loadfile("options.lua"))()
local byKey = {}
for _, row in ipairs(schema) do
  byKey[row.key] = row
  check(#row.label <= 14, "label <=14: " .. row.label)
end

local required = {
  "enabled", "sprite_style", "spawn_density", "random_encounters",
  "water_spawns", "cave_spawns", "dev_overlay",
}
for _, k in ipairs(required) do
  check(byKey[k] ~= nil, "core option present: " .. k)
end

local removed = {
  "dev_mode", "debug_hud_always_visible", "show_spawn_tile_overlay",
  "show_behavior_overlays", "allow_debug_spawn_outside_encounter_areas",
  "debug_logging", "force_test_spawn", "preview_filter", "preview_search",
  "preview_map_filter", "preview_encounter_kind",
}
for _, k in ipairs(removed) do
  check(byKey[k] == nil, "removed public option: " .. k)
end

-- No duplicate keys
local seen = {}
for _, row in ipairs(schema) do
  check(seen[row.key] == nil, "unique key: " .. row.key)
  seen[row.key] = true
end

eq(byKey.dev_overlay.default, false, "dev_overlay default false")
eq(byKey.spawn_density.default, "normal", "spawn_density default normal")

print("== migration ==")
savedOpts.dev_overlay = nil
savedOpts.debug = true
check(Config.devOverlay(V.mod) == true, "debug=true migrates to dev_overlay")
savedOpts.debug = nil
savedOpts.dev_mode = true
check(Config.devOverlay(V.mod) == true, "dev_mode=true migrates to dev_overlay")
Config.migrateDevOverlayOption(V.mod)
eq(savedOpts.dev_overlay, true, "migrate writes dev_overlay")
eq(savedOpts.dev_mode, nil, "migrate clears obsolete dev_mode")
savedOpts.dev_overlay = false
eq(Config.devOverlay(V.mod), false, "explicit false wins")
eq(Config.devMode(V.mod), false, "devMode aliases overlay")

print("== water density / spacing ==")
eq(Config.waterMinSpacing(V.mod), 4, "normal spacing 4")
savedOpts.spawn_density = "low"
eq(Config.waterMinSpacing(V.mod), 5, "low spacing 5")
eq(Config.waterDensityFactor(V.mod), 0.60, "low density 60%")
savedOpts.spawn_density = "high"
eq(Config.waterMinSpacing(V.mod), 3, "high spacing 3")
eq(Config.waterDensityFactor(V.mod), 1.40, "high density 140%")
savedOpts.spawn_density = "normal"
eq(Config.waterDensityFactor(V.mod), 1.0, "normal density 100%")

-- Inline water target formula (mirrors SpawnLogic:_computeWaterTarget).
local function computeWaterTarget(waterCells, factor)
  waterCells = tonumber(waterCells) or 0
  if waterCells <= 0 then return 0 end
  local base
  if waterCells < 4 then base = 0
  elseif waterCells < 8 then base = (waterCells >= 6) and 1 or 0
  elseif waterCells < 20 then base = 1
  elseif waterCells < 50 then base = 1 + math.floor(waterCells / 40)
  elseif waterCells < 120 then base = 2 + math.floor((waterCells - 50) / 35)
  else
    base = 4 + math.floor((waterCells - 120) / 80)
    if base > 6 then base = 6 end
  end
  local raw = math.floor(base * (factor or 1) + 0.5)
  local maxW = 6
  if raw > maxW then raw = maxW end
  local cellCap = math.floor(waterCells / 8)
  if raw > cellCap then raw = math.max(0, cellCap) end
  if waterCells >= 8 and raw < 1 and (factor or 1) >= 1.0 then raw = 1 end
  return raw
end

eq(computeWaterTarget(3, 1), 0, "tiny pond 0")
check(computeWaterTarget(7, 1) <= 1, "very small 0–1")
eq(computeWaterTarget(15, 1), 1, "small water 1")
local mid = computeWaterTarget(40, 1)
check(mid >= 1 and mid <= 2, "medium water 1–2 (got " .. mid .. ")")
local large = computeWaterTarget(100, 1)
check(large >= 2 and large <= 4, "large water 2–4 (got " .. large .. ")")
local huge = computeWaterTarget(200, 1)
check(huge <= 6, "very large capped ≤6 (got " .. huge .. ")")
local lowT = computeWaterTarget(100, 0.60)
local highT = computeWaterTarget(100, 1.40)
check(lowT < highT, "spawn amount scales water target")

-- Manhattan spacing helper
eq(Grass.manhattan(0, 0, 3, 1), 4, "manhattan 4")
check(Grass.manhattan(0, 0, 2, 1) < 4, "manhattan under spacing")

print("== cave reachability BFS ==")
local function makeCaveMap(w, h, blocked, warps)
  blocked = blocked or {}
  warps = warps or {}
  return {
    widthCells = w,
    heightCells = h,
    isWalkableCell = function(_, x, y)
      if x < 0 or y < 0 or x >= w or y >= h then return false end
      return not blocked[x .. ":" .. y]
    end,
    warpAtCell = function(_, x, y)
      return warps[x .. ":" .. y] == true
    end,
    isWaterCell = function() return false end,
  }
end

-- 5x5 open cave with a vertical wall at x=2 separating left/right.
local blocked = {}
for y = 0, 4 do blocked["2:" .. y] = true end
local map = makeCaveMap(5, 5, blocked, { ["0:0"] = true })
local player = { cellX = 0, cellY = 2 }
local data = CaveReachability.build(map, player)
eq(data.status, "READY", "BFS READY from player")
check(CaveReachability.isReachable(data, 0, 2), "player cell reachable")
check(CaveReachability.isReachable(data, 1, 2), "left of wall reachable")
check(not CaveReachability.isReachable(data, 3, 2), "right of wall unreachable")
check(not CaveReachability.isPassableCaveCell(map, 0, 0), "warp not passable")

local cells = {}
for y = 0, 4 do
  for x = 0, 4 do
    if CaveReachability.isPassableCaveCell(map, x, y) then
      cells[#cells + 1] = { x = x, y = y }
    end
  end
end
local filtered, rejected = CaveReachability.filterCells(cells, data)
check(#filtered > 0, "some reachable cave cells")
check(rejected > 0, "some rejected unreachable cells")
for _, c in ipairs(filtered) do
  check(c.x < 2, "filtered cell on reachable side")
end

-- Failed BFS → empty filter, never unfiltered.
local failData = CaveReachability.build(nil, nil)
eq(failData.status, "FAILED", "no map → FAILED")
local empty = select(1, CaveReachability.filterCells(cells, failData))
eq(#empty, 0, "FAILED filter yields no cells")

local near = CaveReachability.conservativeNearPlayer(map, player, 2)
check(#near > 0, "conservative near-player fallback")

print("== Dev Overlay labels ==")
local e = {
  behavior = Behavior.AGGRESSIVE,
  facing = "left",
  behaviorState = { facing = "left", state = "chasing" },
}
local line1, line2, color = DevOverlay.labelLines(e)
check(line1:find("AGGRO", 1, true) ~= nil, "AGGRO label")
check(line2:find("LEFT", 1, true) ~= nil, "LEFT facing")
check(color[1] > 0.5, "aggro red-ish")

local w = {
  behavior = Behavior.WATER_WANDER,
  facing = "up",
  behaviorState = { facing = "up" },
}
local w1, w2 = DevOverlay.labelLines(w)
check(w1:find("WATER", 1, true) ~= nil, "WATER WANDER label")
check(w2:find("UP", 1, true) ~= nil, "UP facing")

savedOpts.dev_overlay = false
eq(Config.devOverlay(V.mod), false, "overlay off")
savedOpts.dev_overlay = true
eq(Config.devOverlay(V.mod), true, "overlay on")

print("== follower cache key ==")
local Followers = V.require("followers_water_compat")
local fw = Followers.new(V.mod)
local key = fw:cacheKey({ id = "f1" }, "PIKACHU", "shiny", "default", "land", "pokemmo")
check(key:find("pokemmo", 1, true) ~= nil, "cache key includes style")
check(key:find("land", 1, true) ~= nil, "cache key includes surface")
check(key:find("shiny", 1, true) ~= nil, "cache key includes variant")
fw:invalidateStyle()
eq(fw.status.lastAction, "style_invalidated", "invalidateStyle works")

-- Manifest / export version
local mf = io.open("manifest.json", "r"):read("*a")
check(mf:find('"1.12.0"', 1, true) ~= nil, "manifest 1.12.0")
local main = io.open("main.lua", "r"):read("*a")
check(main:find('version = "1.12.0"', 1, true) ~= nil, "export version 1.12.0")

print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("all settings_cave_water_overlay unit tests passed")
