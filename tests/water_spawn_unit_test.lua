-- Unit tests for water spawn variety: rod pools, shore distance, zones,
-- dedupe, and WATER_AGGRESSIVE / land→water helpers (no rendering).
package.path = "./?.lua;./?/init.lua;" .. package.path

local function fail(msg)
  io.stderr:write("FAIL: " .. tostring(msg) .. "\n")
  os.exit(1)
end

local function check(cond, msg)
  if not cond then fail(msg) end
end

local function eq(a, b, msg)
  if a ~= b then
    fail(("%s: expected %s, got %s"):format(tostring(msg), tostring(b), tostring(a)))
  end
end

-- Minimal V.require harness matching main.lua chunk loader.
local root = arg[0]:match("(.*/)") or "./"
if root == "./" then
  -- When run as tests/foo.lua from repo root.
  root = ""
end

local modPath = "."
local modules = {}
local V = {
  mod = {
    path = modPath,
    read = function(_, rel)
      local f = io.open(rel, "r")
      if not f then
        f = io.open("lib/" .. rel, "r")
      end
      if not f and rel:sub(1, 4) ~= "lib/" then
        f = io.open("lib/" .. rel .. ".lua", "r")
      end
      if not f then return nil end
      local src = f:read("*a")
      f:close()
      return src
    end,
    options = {
      get = function() return nil end,
    },
    log = { info = function() end, warn = function() end },
  },
  path = modPath,
}

function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local path = "lib/" .. name .. ".lua"
  local f = assert(io.open(path, "r"), "missing " .. path)
  local src = f:read("*a")
  f:close()
  local chunk = assert(loadstring and loadstring(src, "@" .. path) or load(src, "@" .. path))
  local value = chunk(V)
  modules[name] = value
  return value
end

local WaterSpawn = V.require("water_spawn")
local Behavior = V.require("behavior")
local Surface = V.require("surface")
local Config = V.require("config")

print("== WaterSpawn rod tiers ==")
eq(WaterSpawn.ROD_TIER.SURF, 0, "SURF tier")
eq(WaterSpawn.ROD_TIER.OLD, 1, "OLD tier")
eq(WaterSpawn.ROD_TIER.GOOD, 2, "GOOD tier")
eq(WaterSpawn.ROD_TIER.SUPER, 3, "SUPER tier")
eq(WaterSpawn.zoneForDistance(0), "NEAR", "dist 0 near")
eq(WaterSpawn.zoneForDistance(2), "NEAR", "dist 2 near")
eq(WaterSpawn.zoneForDistance(3), "MID", "dist 3 mid")
eq(WaterSpawn.zoneForDistance(5), "MID", "dist 5 mid")
eq(WaterSpawn.zoneForDistance(6), "DEEP", "dist 6 deep")

print("== buildPool from surf + rods ==")
local game = {
  data = {
    encounters = {
      ROUTE_19 = {
        water = {
          rate = 5,
          slots = {
            { species = "TENTACOOL", level = 5 },
            { species = "TENTACOOL", level = 10 },
            { species = "TENTACRUEL", level = 15 },
          },
        },
      },
    },
    field = {
      fishing = {
        OLD_ROD = { always = { species = "MAGIKARP", level = 5 } },
        GOOD_ROD = {
          pool = {
            { species = "GOLDEEN", level = 10 },
            { species = "POLIWAG", level = 10 },
          },
        },
        SUPER_ROD = { perMap = "superRod" },
      },
      superRod = {
        ROUTE_19 = {
          { species = "SEAKING", level = 20 },
          { species = "GYARADOS", level = 15 },
          { species = "MAGIKARP", level = 15 }, -- also in Old Rod → keep OLD tier
        },
      },
    },
  },
}

local pool = WaterSpawn.buildPool(game, "ROUTE_19")
check(WaterSpawn.hasPool(pool), "pool non-empty")
eq(pool.diagnostics.surfSpecies >= 2, true, "surf species counted")
eq(pool.diagnostics.oldRodSpecies >= 1, true, "old rod species")
eq(pool.diagnostics.goodRodSpecies >= 2, true, "good rod species")
eq(pool.diagnostics.superRodSpecies >= 1, true, "super rod species")

local bySp = {}
for _, e in ipairs(pool.entries) do bySp[e.species] = e end
check(bySp.MAGIKARP, "Magikarp present")
eq(bySp.MAGIKARP.rodTier, WaterSpawn.ROD_TIER.OLD, "Magikarp keeps lowest tier OLD")
check(bySp.GYARADOS, "Gyarados present")
eq(bySp.GYARADOS.rodTier, WaterSpawn.ROD_TIER.SUPER, "Gyarados SUPER only")
check(bySp.TENTACOOL, "Tentacool present")
eq(bySp.TENTACOOL.rodTier, WaterSpawn.ROD_TIER.SURF, "Tentacool SURF")

print("== shore distance BFS ==")
-- Map: land only at x=0 (all y); water along y=1 for x=1..8.
local map = {
  widthCells = 10,
  heightCells = 3,
  inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 10 and y < 3 end,
  isWaterCell = function(_, x, y) return y == 1 and x >= 1 and x <= 8 end,
  isWalkableCell = function(_, x, y)
    if y == 1 and x >= 1 and x <= 8 then return false end
    -- Only column x=0 is walkable land; other non-water cells are walls.
    return x == 0
  end,
  warpAtCell = function() return nil end,
}
local waterCells = {}
for x = 1, 8 do waterCells[#waterCells + 1] = { x = x, y = 1 } end
local shore = WaterSpawn.buildShoreDistance(map, waterCells)
eq(WaterSpawn.distanceAt(shore, 1, 1), 0, "x=1 is shore (dist 0)")
eq(WaterSpawn.distanceAt(shore, 2, 1), 1, "x=2 dist 1")
eq(WaterSpawn.distanceAt(shore, 3, 1), 2, "x=3 dist 2 near")
eq(WaterSpawn.distanceAt(shore, 4, 1), 3, "x=4 mid")
eq(WaterSpawn.distanceAt(shore, 7, 1), 6, "x=7 deep")
check(shore.hasDeep == true, "has deep zone")
eq(shore.counts.near > 0, true, "near cells exist")
eq(shore.counts.deep > 0, true, "deep cells exist")

print("== zone pools / small pond ==")
local zonePools = WaterSpawn.buildZonePools(pool, true)
check(#zonePools.deep > 0, "deep pool has entries when deep exists")
local gyaradosInNear = false
for _, e in ipairs(zonePools.near) do
  if e.species == "GYARADOS" then gyaradosInNear = true end
end
check(not gyaradosInNear, "Super-Rod-only never in near shore pool")

local smallShore = WaterSpawn.buildShoreDistance({
  widthCells = 4, heightCells = 4,
  inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 4 and y < 4 end,
  isWaterCell = function(_, x, y) return x == 1 and y == 1 end,
  isWalkableCell = function(_, x, y) return not (x == 1 and y == 1) end,
  warpAtCell = function() return nil end,
}, { { x = 1, y = 1 } })
eq(smallShore.hasDeep, false, "tiny pond has no deep")
local smallPools = WaterSpawn.buildZonePools(pool, smallShore.hasDeep)
local gyaradosInSmall = false
for _, e in ipairs(smallPools.near) do
  if e.species == "GYARADOS" then gyaradosInSmall = true end
end
for _, e in ipairs(smallPools.mid) do
  if e.species == "GYARADOS" then gyaradosInSmall = true end
end
for _, e in ipairs(smallPools.deep) do
  if e.species == "GYARADOS" then gyaradosInSmall = true end
end
check(not gyaradosInSmall, "tiny pond excludes Super-Rod-only")

print("== pickForZone respects zone ==")
local pickDeep = WaterSpawn.pickForZone(zonePools, WaterSpawn.ZONE.DEEP, {
  rng = function(a, b)
    if b then return a end
    if a then return 1 end
    return 0.01
  end,
})
check(pickDeep ~= nil, "deep pick non-nil")
check(pickDeep.rodTier ~= nil, "pick has rodTier")

local pickNear = WaterSpawn.pickForZone(zonePools, WaterSpawn.ZONE.NEAR, {
  rng = function(a, b)
    if b then return a end
    if a then return 1 end
    return 0.5
  end,
})
check(pickNear ~= nil, "near pick non-nil")
check(pickNear.rodTier ~= WaterSpawn.ROD_TIER.SUPER, "near pick never SUPER-only")

print("== WATER_AGGRESSIVE behaviour ==")
check(Surface.allowsBehavior(Surface.WATER, Behavior.WATER_AGGRESSIVE),
      "water surface allows WATER_AGGRESSIVE")
check(Behavior.isWater(Behavior.WATER_AGGRESSIVE), "isWater includes aggressive")
check(Behavior.isAggressive(Behavior.WATER_AGGRESSIVE), "isAggressive includes water")

local w = Behavior.weightsFor("TENTACOOL", Surface.WATER, {
  water_aggressive_chance = 0.15,
  enable_aggressive = true,
})
check((w[Behavior.WATER_AGGRESSIVE] or 0) > 0, "water aggressive weight > 0")
check((w[Behavior.AGGRESSIVE] or 0) == 0, "land AGGRESSIVE zero on water")

local wOff = Behavior.weightsFor("TENTACOOL", Surface.WATER, {
  enable_water_aggressive = false,
})
eq(wOff[Behavior.WATER_AGGRESSIVE], 0, "water aggressive disabled")

print("== canStep water-only ==")
local waterEnt = {
  surface = Surface.WATER,
  behavior = Behavior.WATER_AGGRESSIVE,
  cellX = 2, cellY = 0,
}
-- Drive Behaviour.tick abort when player leaves surf.
local bx = Behavior.initState(Behavior.WATER_AGGRESSIVE, function() return 0 end)
bx.chasing = true
bx.state = Behavior.STATE.CHASING
waterEnt.behaviorState = bx
local landPlayer = { cellX = 0, cellY = 0, surfing = false }
local ev = Behavior.tick(waterEnt, {
  map = map,
  entities = { waterEnt },
  player = landPlayer,
  dt = 0.016,
  waterMonsEnabled = true,
})
eq(ev, "chase_abort", "water chase aborts when player on land")
check(Behavior.isWater(waterEnt.behavior), "stays on water behaviour after abort")

print("== Good Rod allowed near shore ==")
local goodNear = false
for _, e in ipairs(zonePools.near) do
  if e.species == "GOLDEEN" or e.species == "POLIWAG" then goodNear = true end
end
check(goodNear, "Good Rod species appear in near shore pool")

print("== isWaterCapable ==")
local capableGame = {
  data = {
    pokemon = {
      SQUIRTLE = { types = { "WATER" }, name = "SQUIRTLE" },
      CHARMANDER = { types = { "FIRE" }, name = "CHARMANDER" },
    },
  },
}
local okWater, whyWater = WaterSpawn.isWaterCapable("SQUIRTLE", capableGame)
check(okWater == true, "Squirtle water-capable via types")
eq(whyWater, "type:WATER", "reason type:WATER")
local okFire = WaterSpawn.isWaterCapable("CHARMANDER", capableGame)
check(okFire == false, "Charmander not water-capable by type alone")
local okLocal = select(1, WaterSpawn.isWaterCapable("TENTACOOL", capableGame, {
  localPoolSpecies = { TENTACOOL = true },
}))
check(okLocal == true, "local encounter marks water-capable")

print("== Behavior.pick water fallback ==")
local emptyPick = Behavior.pick("MISSINGNO", Surface.WATER, {
  enable_idle = false,
  enable_wander = false,
  enable_aggressive = false,
  enable_water_aggressive = false,
})
eq(emptyPick, Behavior.WATER_IDLE, "empty water weights fall back to WATER_IDLE")

print("== SpawnFx fail-safe ==")
local SpawnFx = V.require("spawn_fx")
local fxEnt = { id = "fx1" }
SpawnFx.begin(fxEnt, SpawnFx.KIND.WATER)
fxEnt.spawnFx.elapsed = 5.0
check(SpawnFx.canAct(fxEnt) == true, "stale FX unlocks canAct")
check(SpawnFx.canBattle(fxEnt) == true, "stale FX unlocks canBattle")
check(fxEnt.spawnFx.done == true, "stale FX forced done")
local noFx = { id = "nofx", canTriggerBattle = true }
check(SpawnFx.canAct(noFx) == true, "no FX ⇒ canAct")
check(SpawnFx.canBattle(noFx) == true, "no FX ⇒ canBattle")

print("All water_spawn_unit_test checks passed.")
