-- Lightweight offline benchmark harness for Wilds performance scenarios.
-- Does not claim FPS gains; records structural work counters under simulated FPS.
-- Run: lua tests/perf_bench_harness.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local clock = 0
love = { timer = { getTime = function() return clock end } }

local results = {}

local function stubV()
  local behaviorTicks, occRebuilds, voxelPresence, movementUpdates = 0, 0, 0, 0
  local modules = {}
  local V = { path = ".", mod = nil }
  function V.require(name)
    if modules[name] ~= nil then return modules[name] end
    if name == "config" then
      modules[name] = {
        isEnabled = function() return true end,
        debug = function() return true end,
        get = function(_, k) return modules[name].DEFAULTS[k] end,
        waterMons = function() return true end,
        DEFAULTS = {
          aggressive_sight_range = 4,
          aggressive_reaction_delay = 0.35,
          aggressive_step_seconds = 0.2,
          water_aggressive_sight_range = 4,
          land_water_chase_player_max = 3,
        },
        STATE = { AVAILABLE = "available" },
      }
      return modules[name]
    end
    if name == "behavior" then
      modules[name] = {
        STATE = { IDLE = "idle", CHASING = "chasing", CHASE_START = "cs",
                  ALERT = "a", PLAYER_DETECTED = "pd", PLAYER_NOTICED = "pn",
                  FLEEING = "f", FLEE_START = "fs", CLEANUP = "c" },
        tick = function() behaviorTicks = behaviorTicks + 1 end,
        isSafari = function() return false end,
        isSafariFlee = function() return false end,
      }
      return modules[name]
    end
    if name == "movement" then
      modules[name] = {
        isBusy = function() return false end,
        healBusy = function() return false end,
        update = function() movementUpdates = movementUpdates + 1 end,
        refreshGrassFlag = function() end,
      }
      return modules[name]
    end
    if name == "voxel_adapter" then
      local VA = {}
      VA.__index = VA
      function VA.new() return setmetatable({ present = false, voxelActive = false }, VA) end
      function VA:refreshPresence()
        voxelPresence = voxelPresence + 1
        self.present = false
        return false
      end
      function VA:_probeVoxelActive() return false end
      function VA:updateEntity() return true end
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
        updateEntity = function() end,
        canAct = function() return true end,
        canBattle = function() return true end,
      }
      return modules[name]
    end
    if name == "surface" then modules[name] = { WATER = "water" } return modules[name] end
    if name == "water_spawn" then modules[name] = {} return modules[name] end
    if name == "safari_compat" then
      modules[name] = {
        isActive = function() return false end,
        status = function() return "off" end,
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
        liveOverworld = function(_, g) return g and g.overworld end,
        pollWildAlertEmote = function() end,
      }
      return modules[name]
    end
    if name == "cave_reachability" then
      modules[name] = {
        needsRebuild = function() return false end,
        build = function() return {} end,
        partitionCells = function() return {}, {} end,
        filterCells = function(c) return c end,
      }
      return modules[name]
    end
    if name == "perf_stats" or name == "behavior_tick" then
      local chunk = assert(loadfile("lib/" .. name .. ".lua"))
      local value = chunk(V)
      modules[name] = value
      return value
    end
    error("unexpected require " .. name)
  end
  return V, function()
    return {
      behaviorTicks = behaviorTicks,
      occRebuilds = occRebuilds,
      voxelPresence = voxelPresence,
      movementUpdates = movementUpdates,
    }
  end, function(n) occRebuilds = occRebuilds + (n or 1) end
end

local function runScenario(name, opts)
  opts = opts or {}
  local fps = opts.fps or 60
  local seconds = opts.seconds or 1
  local wildN = opts.wilds or 0
  local followerN = opts.followers or 0
  local enabled = opts.enabled ~= false

  local V, counters, bumpOcc = stubV()
  local BehaviorTick = V.require("behavior_tick")
  local Config = V.require("config")
  if not enabled then
    Config.isEnabled = function() return false end
  end

  local player = { cellX = 5, cellY = 5, targetX = 5, targetY = 5 }
  local trailers = {}
  for i = 1, followerN do
    trailers[i] = { cellX = 5 - i, cellY = 5, pokepcTrailer = true }
  end
  local entities, spawns = {}, {}
  for i = 1, wildN do
    local id = "w" .. i
    entities[id] = {
      id = id, cellX = 6 + i, cellY = 5,
      overworldWildSpawn = true,
      behaviorState = { state = "idle" },
      registeredInWorld = true,
      sprite = { def = { image = "x" } },
    }
    spawns[id] = { state = Config.STATE.AVAILABLE, species = "PIDGEY", x = 6 + i, y = 5 }
  end

  local logic = {
    state = { initialized = true },
    entities = entities,
    spawns = spawns,
    occupancy = {},
    _occupancyDirty = true,
    rebuildOccupancy = function(self)
      bumpOcc(1)
      self._occupancyDirty = false
      return self.occupancy
    end,
    _entityHasCompatibleWaterSprite = function() return false end,
    _onAggressiveAlert = function() end,
    _startBattle = function() end,
    _attach = function() end,
  }

  local mod = {
    world = {
      game = {
        overworld = {
          map = { id = "bench" },
          player = player,
          entities = {},
          pokepcTrailers = trailers,
          npcs = {},
        },
      },
    },
    log = { info = function() end },
    content = { render_pipelines = { register = function() end } },
  }
  V.mod = mod

  local tick = BehaviorTick.new(mod, logic)
  clock = 0
  tick._lastT = 0
  local frames = math.floor(fps * seconds)
  local t0 = os.clock()
  for i = 1, frames do
    clock = i / fps
    tick:step({})
  end
  local wallMs = (os.clock() - t0) * 1000
  local c = counters()
  local row = {
    scenario = name,
    fps = fps,
    seconds = seconds,
    wilds = wildN,
    followers = followerN,
    enabled = enabled,
    frames = frames,
    wallMs = wallMs,
    aiTicks = c.behaviorTicks,
    occRebuilds = c.occRebuilds,
    voxelPresence = c.voxelPresence,
    aiPerSec = c.behaviorTicks / seconds,
    occPerSec = c.occRebuilds / seconds,
  }
  results[#results + 1] = row
  return row
end

print("=== Wilds perf bench (structural counters) ===")
runScenario("A_disabled", { enabled = false, fps = 60, wilds = 0 })
runScenario("B_6wild_60fps", { wilds = 6, fps = 60 })
runScenario("C_12wild_60fps", { wilds = 12, fps = 60 })
runScenario("D_6wild_1f", { wilds = 6, followers = 1, fps = 60 })
runScenario("E_6wild_6f", { wilds = 6, followers = 6, fps = 60 })
runScenario("B_6wild_30fps", { wilds = 6, fps = 30 })
runScenario("B_6wild_120fps", { wilds = 6, fps = 120 })
runScenario("B_6wild_144fps", { wilds = 6, fps = 144 })

local function fmt(r)
  return string.format(
    "%-18s fps=%3d wilds=%2d foll=%d ai/s=%5.1f occ/s=%5.1f voxelP=%d wall=%.1fms",
    r.scenario, r.fps, r.wilds, r.followers, r.aiPerSec, r.occPerSec,
    r.voxelPresence, r.wallMs)
end

for _, r in ipairs(results) do
  print(fmt(r))
end

-- Acceptance: AI rate must not scale with render FPS.
local function find(name)
  for _, r in ipairs(results) do
    if r.scenario == name then return r end
  end
end
local a30 = find("B_6wild_30fps")
local a144 = find("B_6wild_144fps")
assert(a30 and a144, "missing fps rows")
local ratio = a144.aiPerSec / math.max(1, a30.aiPerSec)
if ratio > 1.35 then
  io.stderr:write(string.format(
    "FAIL: AI rate scaled with FPS (30→%.1f 144→%.1f ratio=%.2f)\n",
    a30.aiPerSec, a144.aiPerSec, ratio))
  os.exit(1)
end
print(string.format("ok  AI rate stable across FPS (30=%.1f 144=%.1f ratio=%.2f)",
                    a30.aiPerSec, a144.aiPerSec, ratio))
print("ALL PASS")
