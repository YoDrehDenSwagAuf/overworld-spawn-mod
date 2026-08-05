-- Safari Zone compatibility + SAFARI_FLEE unit tests.
-- Run: lua tests/safari_compat_unit_test.lua
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
  enable_idle = true,
  enable_wander = true,
  enable_aggressive = true,
  enable_hidden = true,
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
        save = {
          safari = { balls = 30, steps = 500 },
          options = { modOptions = { overworld_wild_spawns = savedOpts } },
        },
        mods = { modOptions = { overworld_wild_spawns = savedOpts } },
        data = {
          maps = {
            SAFARI_ZONE_CENTER = { id = "SAFARI_ZONE_CENTER", region = "SAFARI" },
            SAFARI_ZONE_EAST = { id = "SAFARI_ZONE_EAST" },
            ROUTE_1 = { id = "ROUTE_1", label = "Route 1" },
            FUCHSIA_CITY = { id = "FUCHSIA_CITY", label = "Fuchsia City" },
          },
        },
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

local SafariCompat = V.require("safari_compat")
local Behavior = V.require("behavior")
local Surface = V.require("surface")
local Movement = V.require("movement")
local CellOccupancy = V.require("cell_occupancy")
local DevOverlay = V.require("dev_overlay")
local Config = V.require("config")

-- Force native path available for ACTIVE status tests.
SafariCompat.setNativePathProbe(true, "test")

local function safariGame(extra)
  local g = {
    save = { safari = { balls = 30, steps = 500 } },
    data = V.mod.world.game.data,
  }
  if extra then for k, v in pairs(extra) do g[k] = v end end
  return g
end

local function owFor(mapId)
  return {
    map = {
      id = mapId,
      def = { id = mapId, region = mapId:find("SAFARI_ZONE", 1, true) and "SAFARI" or nil },
      widthCells = 20,
      heightCells = 20,
      isWalkableCell = function(_, x, y)
        return x >= 0 and y >= 0 and x < 20 and y < 20
      end,
      isGrassCell = function(_, x, y)
        return x >= 0 and y >= 0 and x < 20 and y < 20
      end,
      warpAtCell = function(_, x, y) return x == 0 and y == 0 end,
      inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 20 and y < 20 end,
    },
    player = { cellX = 5, cellY = 5 },
    entities = {},
  }
end

----------------------------------------------------------------
-- Session detection
----------------------------------------------------------------
check(SafariCompat.isSafariMap(safariGame(), "SAFARI_ZONE_CENTER", owFor("SAFARI_ZONE_CENTER")),
      "SAFARI_ZONE_CENTER is Safari map")
check(SafariCompat.isSafariMap(safariGame(), "SAFARI_ZONE_EAST", owFor("SAFARI_ZONE_EAST")),
      "SAFARI_ZONE_EAST is Safari map")
check(not SafariCompat.isSafariMap(safariGame(), "ROUTE_1", owFor("ROUTE_1")),
      "ROUTE_1 is not Safari map")
check(not SafariCompat.isSafariMap(safariGame(), "FUCHSIA_CITY", owFor("FUCHSIA_CITY")),
      "FUCHSIA_CITY is not Safari map")
-- Label alone must not be enough
check(not SafariCompat.isSafariMap(
        { data = { maps = { MY_MAP = { id = "MY_MAP", label = "Safari Funhouse" } } } },
        "MY_MAP",
        { map = { id = "MY_MAP", def = { id = "MY_MAP", label = "Safari Funhouse" } } }),
      "label Safari alone is not enough")

local gActive = safariGame()
local owSz = owFor("SAFARI_ZONE_CENTER")
check(SafariCompat.isActive(gActive, owSz, "SAFARI_ZONE_CENTER"),
      "active session + Safari map => isActive")
eq(SafariCompat.status(gActive, owSz, "SAFARI_ZONE_CENTER"),
   SafariCompat.STATUS.ACTIVE, "status ACTIVE")

local gNoSess = safariGame()
gNoSess.save.safari = nil
check(not SafariCompat.isActive(gNoSess, owSz, "SAFARI_ZONE_CENTER"),
      "Safari map without session => inactive")
eq(SafariCompat.status(gNoSess, owSz, "SAFARI_ZONE_CENTER"),
   SafariCompat.STATUS.INACTIVE, "status INACTIVE without session")

local gRoute = safariGame()
check(not SafariCompat.isActive(gRoute, owFor("ROUTE_1"), "ROUTE_1"),
      "session on non-Safari map => not active")

SafariCompat.setNativePathProbe(false, "missing")
eq(SafariCompat.status(gActive, owSz, "SAFARI_ZONE_CENTER"),
   SafariCompat.STATUS.FALLBACK_VANILLA, "missing native path => FALLBACK_VANILLA")
SafariCompat.setNativePathProbe(true, "test")

check(SafariCompat.shouldSuppressClassicEncounters(gActive, owSz, "SAFARI_ZONE_CENTER"),
      "ACTIVE Safari suppresses classic encounters")
check(not SafariCompat.shouldSuppressClassicEncounters(gNoSess, owSz, "SAFARI_ZONE_CENTER"),
      "inactive Safari does not suppress")
check(not SafariCompat.shouldSuppressClassicEncounters(gRoute, owFor("ROUTE_1"), "ROUTE_1"),
      "Route 1 does not suppress via Safari")

----------------------------------------------------------------
-- Behaviour selection
----------------------------------------------------------------
local function fixedRng(u)
  return function(a, b)
    if a == nil then return u end
    if b == nil then return math.max(1, math.floor(u * a + 0.0001)) end
    return a + math.floor(u * (b - a + 1))
  end
end

-- Collect distribution over many rolls
local counts = { SAFARI_IDLE = 0, SAFARI_WANDER = 0, SAFARI_FLEE = 0, AGGRESSIVE = 0, other = 0 }
for i = 1, 200 do
  local u = (i - 0.5) / 200
  local b = Behavior.pick("PIDGEY", Surface.GRASS, { safari = true }, fixedRng(u))
  if counts[b] then counts[b] = counts[b] + 1
  elseif b == Behavior.AGGRESSIVE then counts.AGGRESSIVE = counts.AGGRESSIVE + 1
  else counts.other = counts.other + 1 end
end
eq(counts.AGGRESSIVE, 0, "Safari pick never returns AGGRESSIVE")
check(counts.SAFARI_IDLE > 0, "Safari pick can return SAFARI_IDLE")
check(counts.SAFARI_WANDER > 0, "Safari pick can return SAFARI_WANDER")
check(counts.SAFARI_FLEE > 0, "Safari pick can return SAFARI_FLEE")

-- Outside Safari: SAFARI_FLEE not selectable
local normalCounts = { SAFARI_FLEE = 0, AGGRESSIVE = 0 }
for i = 1, 100 do
  local u = (i - 0.5) / 100
  local b = Behavior.pick("SPEAROW", Surface.GRASS, {
    enable_idle = true, enable_wander = true, enable_aggressive = true, enable_hidden = false,
  }, fixedRng(u))
  if b == Behavior.SAFARI_FLEE then normalCounts.SAFARI_FLEE = normalCounts.SAFARI_FLEE + 1 end
  if b == Behavior.AGGRESSIVE then normalCounts.AGGRESSIVE = normalCounts.AGGRESSIVE + 1 end
end
eq(normalCounts.SAFARI_FLEE, 0, "SAFARI_FLEE not selectable outside Safari")
check(normalCounts.AGGRESSIVE > 0, "AGGRESSIVE still selectable outside Safari")

-- Water Safari: no aggressive, no land flee
for i = 1, 50 do
  local b = Behavior.pick("MAGIKARP", Surface.WATER, { safari = true }, fixedRng((i - 0.5) / 50))
  check(b == Behavior.WATER_IDLE or b == Behavior.WATER_WANDER,
        "water Safari pick is idle/wander (" .. tostring(b) .. ")")
end

-- Species affinity: CHANSEY more flee than RHYHORN
local function fleeRate(species)
  local n = 0
  for i = 1, 400 do
    local b = Behavior.pick(species, Surface.GRASS, { safari = true }, fixedRng((i - 0.5) / 400))
    if b == Behavior.SAFARI_FLEE then n = n + 1 end
  end
  return n
end
local chanseyFlee = fleeRate("CHANSEY")
local rhyhornFlee = fleeRate("RHYHORN")
check(chanseyFlee > rhyhornFlee, string.format(
  "CHANSEY flee affinity > RHYHORN (%d > %d)", chanseyFlee, rhyhornFlee))

----------------------------------------------------------------
-- Safari flee detection / alert / movement
----------------------------------------------------------------
local function makeFleeEntity(x, y, facing)
  local entity = {
    cellX = x, cellY = y, px = x * 16, py = y * 16,
    facing = facing or "down",
    surface = Surface.GRASS,
    overworldWildSpawn = true,
    mod = V.mod,
  }
  Behavior.attach(entity, Behavior.SAFARI_FLEE, {
    id = 1,
    membership = {},
  }, fixedRng(0.5))
  -- Fill region membership with a walkable patch around the entity.
  local region = { id = 1, membership = {} }
  for cy = 0, 19 do
    for cx = 0, 19 do
      if not (cx == 0 and cy == 0) then
        region.membership[tostring(cx) .. ":" .. tostring(cy)] = true
      end
    end
  end
  entity.homeRegion = region
  entity.behaviorState.facing = facing or "down"
  entity.facing = facing or "down"
  Movement.init(entity, x, y, facing or "down")
  return entity
end

local function bindOcc(occ, ents)
  occ:rebuild({ entities = ents })
  return occ
end

local map = owSz.map
local player = { cellX = 5, cellY = 8 } -- south of entity at (5,5) facing down
local entity = makeFleeEntity(5, 5, "down")
local occupancy = bindOcc(CellOccupancy.new(), { entity })

local ctx = {
  map = map,
  entities = { entity },
  player = player,
  dt = 0.016,
  safariActive = true,
  safariSightRange = 4,
  occupancy = occupancy,
  rng = fixedRng(0.5),
}

-- Out of range / wrong facing: no reaction
local farPlayer = { cellX = 5, cellY = 18 }
local ctxFar = {}
for k, v in pairs(ctx) do ctxFar[k] = v end
ctxFar.player = farPlayer
local ev = Behavior.tick(entity, ctxFar)
eq(ev, nil, "player out of range => no reaction")

-- In sight facing player
entity = makeFleeEntity(5, 5, "down")
occupancy = bindOcc(CellOccupancy.new(), { entity })
ctx.entities = { entity }
ctx.occupancy = occupancy
ctx.player = { cellX = 5, cellY = 8 }
ev = Behavior.tick(entity, ctx)
eq(ev, "alert", "player in sight => alert once")
check(entity.behaviorState.safariFlee.noticedPlayer == true, "noticedPlayer set")
check(entity.facing == "down" or entity.behaviorState.facing == "down",
      "faces player during alert")

-- Second detection blocked
local ev2 = Behavior.tick(entity, ctx)
eq(ev2, nil, "no second detection during alert")

-- Emote done → flee ready → flee start
Behavior.markFleeReady(entity)
ev = Behavior.tick(entity, ctx)
eq(ev, "flee_start", "flee starts after markFleeReady")
local sf = entity.behaviorState.safariFlee
check(sf.fleeStepsTarget >= 2 and sf.fleeStepsTarget <= 5,
      "flee steps target in 2–5")

-- Step away increases distance from player
local dist0 = math.abs(entity.cellX - ctx.player.cellX)
            + math.abs(entity.cellY - ctx.player.cellY)
-- Complete current step if begun
if Movement.isBusy(entity) then
  for _ = 1, 40 do
    if Movement.update(entity, 0.05) then
      occupancy:commitMove(entity)
      break
    end
  end
  -- Count the completed step via tick
  Behavior.tick(entity, ctx)
end
local dist1 = math.abs(entity.cellX - ctx.player.cellX)
            + math.abs(entity.cellY - ctx.player.cellY)
check(dist1 >= dist0, string.format(
  "flee moves away or stays (dist %d -> %d)", dist0, dist1))

-- Inactive Safari: flee state cleared / not selectable path
entity = makeFleeEntity(5, 5, "down")
local ctxOff = {}
for k, v in pairs(ctx) do ctxOff[k] = v end
ctxOff.safariActive = false
ctxOff.entities = { entity }
Behavior.tick(entity, ctxOff)
check(entity.behavior ~= Behavior.SAFARI_FLEE
      or entity.behaviorState.safariFlee == nil
      or entity.behaviorState.safariFlee.active ~= true,
      "Safari inactive clears/stops flee evaluation")

----------------------------------------------------------------
-- Occupancy / pathfinding constraints
----------------------------------------------------------------
entity = makeFleeEntity(5, 5, "down")
local blocker = {
  cellX = 5, cellY = 6, passable = false, overworldWildSpawn = true,
}
local trainer = {
  cellX = 6, cellY = 5, passable = false,
}
local follower = {
  cellX = 4, cellY = 5, passable = false, isFollower = true,
}
ctx.entities = { entity, blocker, trainer, follower }
occupancy = bindOcc(CellOccupancy.new(), ctx.entities)
ctx.occupancy = occupancy
ctx.player = { cellX = 5, cellY = 7 }
Behavior.attach(entity, Behavior.SAFARI_FLEE, entity.homeRegion, fixedRng(0.5))
Movement.init(entity, 5, 5, "down")
entity.behaviorState.facing = "down"
-- Force flee mid-state
local bx = entity.behaviorState
bx.safariFlee = Behavior.newSafariFleeState()
bx.safariFlee.active = true
bx.safariFlee.fleeStepsTarget = 3
bx.safariFlee.fleeStepsTaken = 0
bx.fleeReady = true
bx.state = Behavior.STATE.FLEEING
bx.sightDisabled = true
Behavior.tick(entity, ctx)
-- Must not occupy player / warp / double-reserve
check(entity.cellX ~= ctx.player.cellX or entity.cellY ~= ctx.player.cellY
      or Movement.isBusy(entity),
      "flee does not teleport onto player")
check(not (entity.targetX == 0 and entity.targetY == 0),
      "flee does not target warp at 0,0")

-- Fully blocked: no teleport
entity = makeFleeEntity(10, 10, "down")
local walls = {}
for _, d in ipairs({ {0,-1},{0,1},{-1,0},{1,0} }) do
  walls[#walls + 1] = {
    cellX = 10 + d[1], cellY = 10 + d[2],
    passable = false, overworldWildSpawn = true,
  }
end
ctx.entities = { entity }
for _, w in ipairs(walls) do ctx.entities[#ctx.entities + 1] = w end
occupancy = bindOcc(CellOccupancy.new(), ctx.entities)
ctx.occupancy = occupancy
ctx.player = { cellX = 10, cellY = 12 }
bx = entity.behaviorState
bx.safariFlee = Behavior.newSafariFleeState()
bx.safariFlee.active = true
bx.safariFlee.fleeStepsTarget = 4
bx.fleeReady = true
bx.state = Behavior.STATE.FLEEING
local ox, oy = entity.cellX, entity.cellY
Behavior.tick(entity, ctx)
eq(entity.cellX, ox, "blocked flee keeps cellX (no teleport)")
eq(entity.cellY, oy, "blocked flee keeps cellY (no teleport)")
check(not Movement.isBusy(entity), "blocked flee does not begin a step")

----------------------------------------------------------------
-- Native encounter routing (mocked)
----------------------------------------------------------------
local pushed = nil
local fakeBattle = {
  safari = nil,
  makeSafari = function(self, st)
    self.safari = st
  end,
}
package.preload["src.battle.BattleState"] = function()
  return {
    newWild = function(game, species, level)
      fakeBattle.species = species
      fakeBattle.level = level
      fakeBattle.safari = nil
      return fakeBattle
    end,
    makeSafari = fakeBattle.makeSafari,
  }
end
SafariCompat.setNativePathProbe(nil) -- re-probe
SafariCompat.setNativePathProbe(true, "test")

local owBattle = owFor("SAFARI_ZONE_CENTER")
owBattle.pushBattle = function(_, battle) pushed = battle end
owBattle.afterBattle = function() end
local okEnc, battleOrErr = SafariCompat.startNativeSafariEncounter(
  gActive, owBattle, "CHANSEY", 22, { safari = gActive.save.safari })
check(okEnc == true, "native Safari encounter starts")
check(pushed ~= nil and pushed.safari ~= nil, "battle has safari state")
eq(pushed.species, "CHANSEY", "encounter species preserved")
eq(pushed.level, 22, "encounter level preserved")

-- Fallback: no normal wild battle helper invoked when path missing
SafariCompat.setNativePathProbe(false, "forced missing")
pushed = nil
local okFail, why = SafariCompat.startNativeSafariEncounter(
  gActive, owBattle, "CHANSEY", 22)
check(okFail == false, "missing native path fails closed")
check(pushed == nil, "no battle pushed on fallback")

SafariCompat.setNativePathProbe(true, "test")

----------------------------------------------------------------
-- Dev overlay labels
----------------------------------------------------------------
local meta = DevOverlay.behaviourMeta(Behavior.SAFARI_FLEE)
eq(meta.label, "SAFARI FLEE", "overlay label SAFARI FLEE")
check(meta.color[1] > 0.8 and meta.color[2] > 0.5, "SAFARI FLEE yellowish/orange")
eq(DevOverlay.behaviourMeta(Behavior.SAFARI_IDLE).label, "SAFARI IDLE", "SAFARI IDLE label")
eq(DevOverlay.behaviourMeta(Behavior.SAFARI_WANDER).label, "SAFARI WANDER", "SAFARI WANDER label")

entity = makeFleeEntity(3, 3, "left")
entity.behaviorState.state = Behavior.STATE.FLEEING
entity.behaviorState.safariFlee = {
  active = true, fleeStepsTaken = 2, fleeStepsTarget = 4,
  noticedPlayer = true, alertStarted = true,
}
local l1, l2, _, l3 = DevOverlay.labelLines(entity)
check(l1:find("SAFARI FLEE", 1, true) == 1, "overlay line1 starts with SAFARI FLEE")
check(l2:find("FLEEING", 1, true) ~= nil, "overlay shows FLEEING state")
check(l3 and l3:find("2/4", 1, true) ~= nil, "overlay shows steps 2/4")

----------------------------------------------------------------
-- Regression: normal aggressive unchanged outside Safari
----------------------------------------------------------------
local agg = {
  cellX = 2, cellY = 2, facing = "down", surface = Surface.GRASS,
  overworldWildSpawn = true, mod = V.mod,
}
Behavior.attach(agg, Behavior.AGGRESSIVE, {
  id = 1, membership = { ["2:2"] = true, ["2:3"] = true, ["2:4"] = true, ["2:5"] = true },
}, fixedRng(0.5))
Movement.init(agg, 2, 2, "down")
agg.behaviorState.facing = "down"
agg.behaviorState.sightDisabled = false
local aggCtx = {
  map = map,
  entities = { agg },
  player = { cellX = 2, cellY = 5 },
  dt = 0.016,
  safariActive = false,
  sightRange = 4,
  occupancy = CellOccupancy.new(),
  rng = fixedRng(0.5),
}
aggCtx.occupancy:rebuild({ entities = { agg } })
local aggEv = Behavior.tick(agg, aggCtx)
eq(aggEv, "alert", "normal AGGRESSIVE still alerts outside Safari")

----------------------------------------------------------------
-- shouldSuppressClassicEncounter via SpawnLogic helper shape
----------------------------------------------------------------
-- Random Enc OFF on route still suppresses; Safari ACTIVE suppresses even if ON.
savedOpts.random_encounters = true
check(Config.randomEncountersEnabled(V.mod) == true, "Random Enc ON")
check(SafariCompat.shouldSuppressClassicEncounters(gActive, owSz, "SAFARI_ZONE_CENTER"),
      "Safari ACTIVE suppresses regardless of Random Enc ON")
savedOpts.random_encounters = false
check(not SafariCompat.shouldSuppressClassicEncounters(
        gRoute, owFor("ROUTE_1"), "ROUTE_1"),
      "Safari helper does not suppress Route 1; Random Enc owns that")

print("")
if failures > 0 then
  io.stderr:write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
print("All safari_compat tests passed.")
