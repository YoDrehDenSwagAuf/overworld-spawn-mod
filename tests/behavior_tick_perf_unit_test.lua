-- BehaviorTick: fixed-rate AI vs per-frame visuals; occupancy skip; cave counter.
-- Run: lua tests/behavior_tick_perf_unit_test.lua
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

local clock = 0
love = {
  timer = {
    getTime = function() return clock end,
  },
}

local behaviorTickCalls = 0
local movementUpdates = 0
local occupancyRebuilds = 0
local voxelPresenceCalls = 0
local voxelUpdateCalls = 0
local debugOn = true

local modules = {}
local V = {
  mod = nil,
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end

  if name == "config" then
    local DEFAULTS = {
      aggressive_sight_range = 4,
      aggressive_reaction_delay = 0.35,
      aggressive_step_seconds = 0.2,
      water_aggressive_sight_range = 4,
      land_water_chase_player_max = 3,
    }
    local cfg = {
      isEnabled = function() return true end,
      debug = function() return debugOn end,
      get = function(_, key)
        return DEFAULTS[key]
      end,
      waterMons = function() return true end,
      DEFAULTS = DEFAULTS,
      STATE = { AVAILABLE = "available", REMOVED = "removed" },
    }
    modules[name] = cfg
    return cfg
  end
  if name == "behavior" then
    local B = {
      STATE = {
        IDLE = "idle", CHASING = "chasing", CHASE_START = "chase_start",
        ALERT = "alert", PLAYER_DETECTED = "player_detected",
        PLAYER_NOTICED = "player_noticed", FLEEING = "fleeing",
        FLEE_START = "flee_start", CLEANUP = "cleanup",
      },
      tick = function(entity, ctx)
        behaviorTickCalls = behaviorTickCalls + 1
        entity._lastAiDt = ctx.dt
        return nil
      end,
      isSafari = function() return false end,
      isSafariFlee = function() return false end,
    }
    modules[name] = B
    return B
  end
  if name == "movement" then
    local M = {
      isBusy = function() return false end,
      healBusy = function() return false end,
      update = function()
        movementUpdates = movementUpdates + 1
        return false
      end,
      refreshGrassFlag = function() end,
      syncLegacyFields = function() return true end,
    }
    modules[name] = M
    return M
  end
  if name == "voxel_adapter" then
    local VA = {}
    VA.__index = VA
    function VA.new()
      return setmetatable({ present = false, voxelActive = false }, VA)
    end
    function VA:refreshPresence()
      voxelPresenceCalls = voxelPresenceCalls + 1
      self.present = false
      self.voxelActive = false
      return false
    end
    function VA:_probeVoxelActive() return false end
    function VA:updateEntity()
      voxelUpdateCalls = voxelUpdateCalls + 1
      return true
    end
    function VA:markFallback() end
    modules[name] = VA
    return VA
  end
  if name == "debug_log" then
    modules[name] = { info = function() end, warn = function() end, enabled = function() return false end }
    return modules[name]
  end
  if name == "spawn_fx" then
    modules[name] = {
      ensureProgress = function() end,
      updateEntity = function() return nil end,
      canAct = function() return true end,
      canBattle = function() return true end,
    }
    return modules[name]
  end
  if name == "surface" then
    modules[name] = { WATER = "water", LAND = "land" }
    return modules[name]
  end
  if name == "water_spawn" then
    modules[name] = {}
    return modules[name]
  end
  if name == "safari_compat" then
    modules[name] = {
      isActive = function() return false end,
      status = function() return "inactive" end,
      STATUS = { ACTIVE = "active" },
      SIGHT_RANGE = 3,
    }
    return modules[name]
  end
  if name == "grass" then
    modules[name] = { caveCells = function() return {} end }
    return modules[name]
  end
  if name == "palette_watch" then
    local PW = {}
    PW.__index = PW
    function PW.new() return setmetatable({}, PW) end
    function PW:tick() end
    modules[name] = PW
    return PW
  end
  if name == "game_compat" then
    modules[name] = {
      isGen2 = function() return false end,
      liveOverworld = function(_, game)
        return game and game.overworld
      end,
      pollWildAlertEmote = function() end,
      logGoldAggro = function() end,
      logGoldAggroError = function() end,
    }
    return modules[name]
  end
  if name == "perf_stats" then
    local chunk = assert(loadfile("lib/perf_stats.lua"))
    local value = chunk(V)
    modules[name] = value
    return value
  end
  if name == "cave_reachability" then
    modules[name] = {
      needsRebuild = function() return false end,
      build = function() return { status = "OK", reachable = {} } end,
      partitionCells = function() return {}, {} end,
      filterCells = function(cells) return cells end,
    }
    return modules[name]
  end

  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

local BehaviorTick = V.require("behavior_tick")

local player = { cellX = 5, cellY = 5, targetX = 5, targetY = 5 }
local entity = {
  id = "w1",
  cellX = 8, cellY = 5,
  overworldWildSpawn = true,
  behaviorState = { state = "idle" },
  registeredInWorld = true,
  sprite = { def = { image = "x" } },
}
local logic = {
  state = { initialized = true },
  entities = { w1 = entity },
  spawns = { w1 = { state = "available", species = "PIDGEY", x = 8, y = 5 } },
  occupancy = { commitMove = function() end, cancelMove = function() end },
  _occupancyDirty = true,
  rebuildOccupancy = function(self)
    occupancyRebuilds = occupancyRebuilds + 1
    self._occupancyDirty = false
    return self.occupancy
  end,
  _entityHasCompatibleWaterSprite = function() return false end,
  _onAggressiveAlert = function() end,
  _startBattle = function() end,
  _attach = function() end,
  _detachFromWorld = function() end,
}
-- Config.STATE.AVAILABLE
local Config = V.require("config")
logic.spawns.w1.state = Config.STATE.AVAILABLE

local mod = {
  world = {
    game = {
      overworld = {
        map = { id = "test" },
        player = player,
        entities = {},
        pokepcTrailers = {},
      },
    },
  },
  log = { info = function() end },
  content = { render_pipelines = { register = function() end } },
}
V.mod = mod

local tick = BehaviorTick.new(mod, logic)
eq(BehaviorTick.AI_HZ, 30, "AI target 30 Hz")
check(BehaviorTick.AI_STEP > 0, "AI_STEP positive")

-- Simulate 1 second at 120 FPS render.
clock = 0
tick._lastT = 0
local frames = 120
local dtFrame = 1 / 120
for i = 1, frames do
  clock = i * dtFrame
  tick:step({})
end

check(behaviorTickCalls > 0, "Behavior.tick ran")
check(behaviorTickCalls <= 35, "AI decisions ~30/sec not 120 (got " .. behaviorTickCalls .. ")")
check(behaviorTickCalls >= 25, "AI decisions at least ~25 in 1s (got " .. behaviorTickCalls .. ")")
check(occupancyRebuilds <= behaviorTickCalls + 2,
      "occupancy rebuilds not above AI ticks (occ=" .. occupancyRebuilds
        .. " ai=" .. behaviorTickCalls .. ")")
check(voxelPresenceCalls <= 4, "voxel presence throttled (got " .. voxelPresenceCalls .. ")")

-- Idle player/trailers: second second should skip many occupancy rebuilds.
local occBefore = occupancyRebuilds
local aiBefore = behaviorTickCalls
logic._occupancyDirty = false
tick._occFp = nil -- force one rebuild then stable
-- Prime fingerprint
tick:step({})
local occAfterPrime = occupancyRebuilds
for i = 1, 60 do
  clock = clock + (1 / 60)
  tick:step({})
end
local occDelta = occupancyRebuilds - occAfterPrime
local aiDelta = behaviorTickCalls - aiBefore
check(aiDelta >= 25 and aiDelta <= 35, "second window AI ~30 (got " .. aiDelta .. ")")
check(occDelta < aiDelta,
      "idle occupancy rebuilds < AI ticks (occDelta=" .. occDelta
        .. " aiDelta=" .. aiDelta .. ")")

-- Player cell change dirties fingerprint → rebuild
local occAtMove = occupancyRebuilds
player.cellX = 6
clock = clock + BehaviorTick.AI_STEP
tick:step({})
check(occupancyRebuilds > occAtMove, "player move triggers occupancy rebuild")

-- AI dt is time-based (accumulated steps), not raw frame dt
check(entity._lastAiDt ~= nil, "entity received aiDt")
check(entity._lastAiDt >= BehaviorTick.AI_STEP * 0.9,
      "aiDt roughly AI_STEP (got " .. tostring(entity._lastAiDt) .. ")")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("ALL PASS")
