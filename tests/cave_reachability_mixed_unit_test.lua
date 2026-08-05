-- Cave reachability + Mixed quota unit tests.
-- Run: lua tests/cave_reachability_mixed_unit_test.lua
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
  cave_spawns = nil,
  water_spawns = "swimming_sprites",
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

local function makeCaveMap(w, h, blocked, warps, playerPassable)
  blocked = blocked or {}
  warps = warps or {}
  return {
    widthCells = w,
    heightCells = h,
    isWalkableCell = function(_, x, y)
      if x < 0 or y < 0 or x >= w or y >= h then return false end
      return not blocked[x .. ":" .. y]
    end,
    isPlayerPassableCell = playerPassable and function(_, x, y)
      return playerPassable[x .. ":" .. y] == true
    end or nil,
    warpAtCell = function(_, x, y)
      return warps[x .. ":" .. y] == true
    end,
    isWaterCell = function() return false end,
  }
end

-- ------- Schema / config -------
local schema = assert(loadfile("options.lua"))()
local byKey = {}
for _, row in ipairs(schema) do byKey[row.key] = row end
check(byKey.cave_spawns ~= nil, "cave_spawns present")
eq(byKey.cave_spawns.type, "choice", "cave_spawns is choice")
eq(byKey.cave_spawns.default, "reachable", "default reachable")
eq(byKey.cave_spawns.label, "Cave Spawns", "label")
check(#byKey.cave_spawns.label <= 14, "label <= 14")
for _, c in ipairs(byKey.cave_spawns.choices) do
  check(#c[1] <= 14, "choice <= 14: " .. c[1])
end

savedOpts.cave_spawns = nil
eq(Config.caveSpawnMode(V.mod), "reachable", "default mode reachable")
check(not Config.caveSpawnsMixed(V.mod), "default not mixed")

savedOpts.cave_spawns = true
eq(Config.caveSpawnMode(V.mod), "reachable", "legacy true → reachable")
savedOpts.cave_spawns = false
eq(Config.caveSpawnMode(V.mod), "mixed", "legacy false → mixed")
Config.migrateCaveSpawnMode(V.mod)
eq(savedOpts.cave_spawns, "mixed", "migrate writes mixed")

Config.setCaveSpawnMode(V.mod, "reachable", "test", {
  game = V.mod.world.game, confirm = false,
})
eq(Config.caveSpawnMode(V.mod), "reachable", "setter reachable")

-- ------- Mixed quota -------
local r, s = CaveReachability.mixedTargets(1)
eq(r, 1, "target1 reachable")
eq(s, 0, "target1 scenery 0")
r, s = CaveReachability.mixedTargets(2)
eq(s, 0, "target2 scenery 0")
r, s = CaveReachability.mixedTargets(3)
eq(s, 1, "target3 scenery 1")
eq(r, 2, "target3 reachable 2")
r, s = CaveReachability.mixedTargets(5)
eq(s, 1, "target5 scenery 1")
r, s = CaveReachability.mixedTargets(10)
eq(s, 2, "target10 scenery 2")
eq(r, 8, "target10 reachable 8")
r, s = CaveReachability.mixedTargets(20)
eq(s, 4, "target20 scenery 4")

-- ------- Wall plateau / player passability -------
-- 7x5: left room (x=0..2), wall x=3, right plateau x=4..6 all walkable.
local blocked = {}
for y = 0, 4 do blocked["3:" .. y] = true end
-- Player-passable only on left room (simulates decorative right plateau).
local playerPass = {}
for y = 0, 4 do
  for x = 0, 2 do playerPass[x .. ":" .. y] = true end
end
local map = makeCaveMap(7, 5, blocked, {}, playerPass)
-- Without isPlayerPassableCell override path: use walkable-only map for BFS wall test.
local mapWall = makeCaveMap(7, 5, blocked, { ["0:0"] = true })
local player = { cellX = 1, cellY = 2 }
local data = CaveReachability.build(mapWall, player)
eq(data.status, "READY", "READY from player")
check(CaveReachability.isReachable(data, 1, 2), "player reachable")
check(CaveReachability.isReachable(data, 2, 2), "left of wall reachable")
check(not CaveReachability.isReachable(data, 4, 2), "right of wall unreachable")
eq(CaveReachability.classifyCell(mapWall, data, 4, 2),
   CaveReachability.CLASS.UNREACHABLE_VALID, "plateau UNREACHABLE_VALID")
eq(CaveReachability.classifyCell(mapWall, data, 3, 2),
   CaveReachability.CLASS.INVALID, "wall INVALID")
eq(CaveReachability.classifyCell(mapWall, data, 0, 0),
   CaveReachability.CLASS.INVALID, "warp INVALID")

local cells = {}
for y = 0, 4 do for x = 0, 6 do cells[#cells + 1] = { x = x, y = y } end end
local reach, unreach, invalid = CaveReachability.partitionCells(cells, mapWall, data)
check(#reach > 0, "reachable pool non-empty")
check(#unreach > 0, "unreachable valid pool non-empty")
check(invalid > 0, "invalid counted")

-- Player-passable stricter than walkable: right plateau walkable but not player-passable.
local dataStrict = CaveReachability.build(map, player)
check(CaveReachability.isReachable(dataStrict, 1, 2), "strict left reachable")
check(not CaveReachability.isPassableCaveCell(map, 5, 2),
      "decorative plateau not player-passable")
eq(CaveReachability.classifyCell(map, dataStrict, 5, 2),
   CaveReachability.CLASS.INVALID, "decorative plateau INVALID")

-- ------- Two entry seeds -------
local map2 = makeCaveMap(9, 3, {}, {})
-- Wall separating rooms at x=4
for y = 0, 2 do map2.isWalkableCell = nil end
local blocked2 = {}
for y = 0, 2 do blocked2["4:" .. y] = true end
map2 = makeCaveMap(9, 3, blocked2, {})
local dataOne = CaveReachability.build(map2, { cellX = 1, cellY = 1 })
check(not CaveReachability.isReachable(dataOne, 7, 1), "one seed: right room unreachable")
local dataTwo = CaveReachability.build(map2, { cellX = 1, cellY = 1 }, {
  entrySeeds = { { x = 7, y = 1 } },
})
check(CaveReachability.isReachable(dataTwo, 7, 1), "two seeds: right room reachable")
check(CaveReachability.isReachable(dataTwo, 1, 1), "two seeds: left still reachable")

-- ------- needsRebuild on warp -------
local dataA = CaveReachability.build(map2, { cellX = 1, cellY = 1 })
check(CaveReachability.needsRebuild(dataA, map2, { cellX = 7, cellY = 1 }),
      "needs rebuild when player on other side")
check(not CaveReachability.needsRebuild(dataA, map2, { cellX = 1, cellY = 1 }),
      "no rebuild when still in component")

-- ------- Component cells for scenery -------
local bag = CaveReachability.componentCells(data, 5, 2)
check(bag ~= nil, "unreachable component bag exists")
check(bag[CaveReachability.cellKey(5, 2)] == true, "cell in component")

-- ------- Dev overlay labels -------
local reachEnt = {
  behavior = Behavior.GRASS_WANDER,
  facing = "left",
  caveReachClass = "REACHABLE",
}
local l1, l2 = DevOverlay.labelLines(reachEnt)
eq(l1, "CAVE · REACHABLE", "reachable overlay line1")
check(l2:find("WANDER", 1, true) ~= nil, "reachable shows wander")

local scenEnt = {
  behavior = Behavior.IDLE_LOOK,
  facing = "down",
  caveScenery = true,
  caveReachClass = "UNREACHABLE_VALID",
}
local s1, s2, col = DevOverlay.labelLines(scenEnt)
eq(s1, "CAVE · SCENERY", "scenery overlay line1")
check(s2:find("IDLE", 1, true) ~= nil, "scenery shows idle")
check(col[1] < 0.7 and col[3] > 0.5, "scenery purple-ish")

-- ------- Water overlay presentation split -------
local WaterDisplay = V.require("water_display")
savedOpts.water_spawns = "silhouettes"
local waterEnt = { surface = "WATER" }
check(not WaterDisplay.needsOverlayPresentation(V.mod, waterEnt),
      "silhouettes do not force overlay")
check(WaterDisplay.needsNativeSilhouetteSheet(V.mod, waterEnt),
      "silhouettes need native sheet")
check(WaterDisplay.useNativeSilhouetteSheet(V.mod, waterEnt, true),
      "voxel silhouettes use native sheet")
check(not WaterDisplay.useNativeSilhouetteSheet(V.mod, waterEnt, false),
      "flat silhouettes keep tint path")
savedOpts.water_spawns = "hidden_silhouettes"
check(not WaterDisplay.needsOverlayPresentation(V.mod, waterEnt),
      "hidden no longer forces emergency overlay")
check(WaterDisplay.needsNativeHiddenShadow(V.mod, waterEnt),
      "hidden needs native flat shadow marker")
check(not WaterDisplay.needsNativeSilhouetteSheet(V.mod, waterEnt),
      "hidden does not use native silhouette sheet")
local hiddenAsset = "assets/generated/water_hidden_runtime/hidden-water-shadow.png"
local hf = io.open(hiddenAsset, "rb")
check(hf ~= nil, "hidden water shadow asset exists")
if hf then hf:close() end

-- ------- Silhouette assets exist -------
local sil = "assets/generated/swimming_silhouette_runtime/130-normal.png"
local f = io.open(sil, "rb")
check(f ~= nil, "swimming silhouette sample exists")
if f then f:close() end
local sil2 = "assets/generated/levitates_silhouette_runtime/092-shiny.png"
-- 092 may or may not exist; check any levitates file
local handle = io.popen("ls assets/generated/levitates_silhouette_runtime | head -1")
local first = handle and handle:read("*l")
if handle then handle:close() end
check(first ~= nil and first ~= "", "levitates silhouette dir populated")

print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("all cave_reachability_mixed unit tests passed")
