-- Inventory consume, miss, success cleanup, failure aggro routing, live setting.
-- Run: lua tests/overworld_catch_flow_unit_test.lua
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

-- Minimal Gen1Recomp stubs
package.preload["src.inventory.Bag"] = function()
  return {
    remove = function(save, id, qty)
      local n = (save.inventory[id] or 0) - (qty or 1)
      if n <= 0 then save.inventory[id] = nil else save.inventory[id] = n end
    end,
  }
end
package.preload["src.battle.Catching"] = function()
  local M = {}
  M._force = nil -- "catch" | "fail" | nil
  function M.attempt(ball, mon, def, rng, rateOverride)
    if ball == "MASTER_BALL" then return true, 3 end
    if M._force == "catch" then return true, 3 end
    if M._force == "fail" then return false, 2 end
    local rate = rateOverride or (def and def.catchRate) or 255
    local r = (rng or math.random)(0, 255)
    return r <= rate, 2
  end
  return M
end
package.preload["src.pokemon.Pokemon"] = function()
  return {
    new = function(data, species, level)
      return { species = species, level = level, hp = 20, stats = { hp = 20 } }
    end,
  }
end
package.preload["src.pokemon.Party"] = function()
  return {
    MAX = 6,
    add = function(party, mon)
      if #party >= 6 then return false end
      table.insert(party, mon)
      return true
    end,
  }
end
package.preload["src.pokemon.Boxes"] = function()
  return {
    deposit = function(save, mon)
      save.boxes = save.boxes or { {} }
      table.insert(save.boxes[1], mon)
      return 1
    end,
  }
end
package.preload["src.render.TextBox"] = function()
  return {
    new = function(game, msg, onDone)
      game._lastText = msg
      return {
        msg = msg,
        onDone = onDone,
        isOpaque = true,
      }
    end,
  }
end
package.preload["src.render.Pipelines"] = function()
  return {
    setLevel = function() end,
    rows = function() return {} end,
  }
end

local optionStore = {
  enabled = true,
  overworld_catching = true,
  wilds_ai = true,
  dev_overlay = false,
}
local game = {
  save = {
    inventory = { POKE_BALL = 5, GREAT_BALL = 0, ULTRA_BALL = 1, MASTER_BALL = 1 },
    party = {},
    boxes = { {} },
    options = { modOptions = { overworld_wild_spawns = optionStore } },
  },
  mods = { modOptions = { overworld_wild_spawns = optionStore } },
  data = {
    pokemon = {
      PIDGEY = { name = "PIDGEY", catchRate = 255 },
      MEWTWO = { name = "MEWTWO", catchRate = 3 },
    },
  },
  audio = { playSfx = function() end },
}
game.stack = {
  _top = nil,
  top = function(self) return self._top end,
  push = function(self, box)
    self._top = box
    -- Dismiss textboxes immediately in unit tests (engine waits for A).
    if box and box.msg then
      local cb = box.onDone
      self._top = game._ow
      if cb then cb() end
    end
  end,
}
game.stack._top = nil

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    options = {
      get = function(_, k)
        if optionStore[k] ~= nil then return optionStore[k] end
        return nil
      end,
    },
    world = { game = game, overworld = function() return game._ow end },
    assets = { path = function(_, rel) return rel end },
    content = {
      sprites = {
        _defs = {},
        get = function(self, id) return self._defs[id] end,
        register = function(self, id, def) self._defs[id] = def end,
      },
      render_pipelines = {
        register = function() end,
      },
    },
    ui = {},
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
modules.debug_log = { warn = function() end, info = function() end, error = function() end }
modules.tile = { CELL = 16 }

-- Stub heavy deps used transitively
modules.spawn_regions = {}
modules.cell_occupancy = {
  ownerKey = function() return nil end,
  isFollowerEntity = function() return false end,
  isBlockingEntity = function() return true end,
}
modules.surface = {
  WATER = "WATER", GRASS = "GRASS", CAVE = "CAVE",
  BEHAVIORS = {},
}
modules.safari_compat = {
  STATUS = { INACTIVE = "INACTIVE", ACTIVE = "ACTIVE", FALLBACK_VANILLA = "FALLBACK_VANILLA" },
  LAND_WEIGHTS = { SAFARI_IDLE = 35, SAFARI_WANDER = 40, SAFARI_FLEE = 25 },
  status = function() return "INACTIVE" end,
  isSafariMap = function() return false end,
}
modules.movement = {
  stop = function() end,
  setFacing = function(e, f) e.facing = f end,
  init = function() end,
  STATE = { ALERT = "ALERT", IDLE = "IDLE", CATCHING = "CATCHING" },
}

local Config = V.require("config")
modules.config = Config
local Behavior = V.require("behavior")
modules.behavior = Behavior

local CatchingApi = require("src.battle.Catching")
local OverworldCatching = V.require("catching/init")

local occupancyReleased = {}
local despawned = {}
local alertCalls = {}
local battleStarts = {}

local logic = {
  entities = {},
  spawns = {},
  byMap = {},
  pendingBattle = nil,
  occupancy = {
    releaseEntity = function(_, ent)
      occupancyReleased[#occupancyReleased + 1] = ent and ent.id
    end,
  },
  voxel = { unregister = function() end },
  _despawn = function(self, id, removeEntity)
    despawned[#despawned + 1] = id
    local entity = self.entities[id]
    local record = self.spawns[id]
    if record then record.state = "removed" end
    if entity then
      entity.state = "removed"
      entity.wildsCatchLocked = false
      entity.wildsCatchState = nil
    end
    if self.occupancy then self.occupancy:releaseEntity(entity or id) end
    self.entities[id] = nil
    self.spawns[id] = nil
  end,
  _detachFromWorld = function(_, entity)
    entity.registeredInWorld = false
  end,
  _attach = function(_, entity)
    entity.registeredInWorld = true
    return true
  end,
  _onAggressiveAlert = function(_, entity, record)
    alertCalls[#alertCalls + 1] = { entity = entity, record = record }
    if entity.behaviorState then
      entity.behaviorState.alertEmoteSpawned = true
      entity.behaviorState.state = Behavior.STATE.ALERT
    end
  end,
  _startBattle = function(_, record)
    battleStarts[#battleStarts + 1] = record and record.id
  end,
}

local catching = OverworldCatching.new(V.mod, logic)
logic.catching = catching
catching:registerContent()

local ow = {
  player = { cellX = 5, cellY = 5, facing = "right" },
  entities = {},
  map = { id = "ROUTE_1" },
  runner = { isRunning = function() return false end },
}
game._ow = ow
game.stack._top = ow

local function placeWild(opts)
  opts = opts or {}
  local id = opts.id or "wilds_of_kanto_entity_1"
  local entity = {
    id = id,
    cellX = opts.x or 8,
    cellY = opts.y or 5,
    species = opts.species or "PIDGEY",
    level = opts.level or 5,
    facing = opts.facing or "left", -- player is to the west → BACK when mon faces left? 
    -- player at (5,5), mon at (8,5): player is west of mon.
    -- mon facing left (west) → player is FRONT.
    -- mon facing right → player is BACK.
    overworldWildSpawn = true,
    visibleSprite = true,
    canTriggerBattle = true,
    state = "available",
    registeredInWorld = true,
    behavior = Behavior.GRASS_WANDER,
  }
  entity.facing = opts.facing or "right" -- BACK throw from the west
  Behavior.attach(entity, Behavior.GRASS_WANDER, nil, function() return 1 end)
  entity.facing = opts.facing or "right"
  local record = {
    id = id,
    mapId = "ROUTE_1",
    x = entity.cellX, y = entity.cellY,
    species = entity.species,
    level = entity.level,
    state = Config.STATE.AVAILABLE,
    behavior = Behavior.GRASS_WANDER,
  }
  logic.entities[id] = entity
  logic.spawns[id] = record
  table.insert(ow.entities, entity)
  return entity, record
end

-- ---- Inventory consume ----
eq(catching:ballCount(game, "POKE_BALL"), 5, "start with 5 Poké Balls")
eq(catching:getSelectedBall(game), "POKE_BALL", "selected Poké Ball")
check(catching:consumeBall(game, "POKE_BALL"), "consume ok")
eq(catching:ballCount(game, "POKE_BALL"), 4, "after throw count 4")

-- ---- No balls message path ----
local emptyGameInv = game.save.inventory
game.save.inventory = {}
check(not catching:anyBalls(game), "no balls")
game.save.inventory = emptyGameInv

-- ---- MISS: consumes ball, no catch, no battle, target remains ----
local entity, record = placeWild({ id = "wild_miss", x = 8, y = 5 })
local before = catching:ballCount(game, "POKE_BALL")
CatchingApi._force = "catch" -- would catch if attempted
catching.meter.active = true
catching.meter.power = 1.0 -- far from dist 3 → MISS
catching.phase = "metering"
-- Force selected ball
catching.selectedBallIndex = 1
catching:_releaseThrow(game, ow)
eq(catching:ballCount(game, "POKE_BALL"), before - 1, "MISS still consumes ball")
check(logic.entities["wild_miss"] ~= nil, "MISS keeps wild entity")
eq(record.state, Config.STATE.AVAILABLE, "MISS keeps AVAILABLE")
eq(#battleStarts, 0, "MISS starts no battle")
eq(#despawned, 0, "MISS does not despawn")
-- finish projectile
for _ = 1, 120 do
  catching.projectile:update(game, ow, 0.05, logic.voxel)
  if catching.phase == "idle" and not catching.projectile:isBusy() then break end
end
eq(catching.phase, "idle", "MISS cleans to idle")

-- ---- SUCCESS ----
logic.entities = {}
logic.spawns = {}
ow.entities = {}
despawned = {}
occupancyReleased = {}
entity, record = placeWild({ id = "wild_ok", x = 7, y = 5, facing = "right" })
CatchingApi._force = "catch"
local partyBefore = #game.save.party
catching.meter.active = true
catching.meter.power = 2.0 -- dist 2 → PERFECT
catching.phase = "metering"
catching:_releaseThrow(game, ow)
-- fly + wobble
for _ = 1, 200 do
  catching.projectile:update(game, ow, 0.05, logic.voxel)
  if catching.phase == "idle" and not catching.projectile:isBusy()
     and catching.activeCapture == nil then break end
end
check(logic.entities["wild_ok"] == nil, "success removes wild entity")
check(#despawned >= 1, "success used Wilds despawn")
check(#occupancyReleased >= 1, "success released occupancy")
check(#game.save.party == partyBefore + 1, "success added to party")
eq(#battleStarts, 0, "success starts no battle")
eq(catching.phase, "idle", "success clears capture state")
check(not catching.projectile:isBusy(), "projectile removed")
game.stack._top = ow

-- ---- Master Ball hit guarantees capture ----
logic.entities = {}
logic.spawns = {}
ow.entities = {}
despawned = {}
CatchingApi._force = "fail" -- ignored for Master Ball
entity, record = placeWild({ id = "wild_master", x = 6, y = 5 })
catching.selectedBallIndex = 4 -- MASTER_BALL
eq(catching:getSelectedBall(game), "MASTER_BALL", "master selected")
local masterBefore = catching:ballCount(game, "MASTER_BALL")
catching.meter.active = true
catching.meter.power = 1.0
catching.phase = "metering"
catching:_releaseThrow(game, ow)
for _ = 1, 200 do
  catching.projectile:update(game, ow, 0.05, logic.voxel)
  if catching.phase == "idle" and catching.activeCapture == nil
     and not catching.projectile:isBusy() then break end
end
eq(catching:ballCount(game, "MASTER_BALL"), masterBefore - 1, "master consumed")
check(logic.entities["wild_master"] == nil, "master catch removes entity")
game.stack._top = ow

-- Master Ball MISS still possible
logic.entities = {}
logic.spawns = {}
ow.entities = {}
game.save.inventory.MASTER_BALL = 1
entity, record = placeWild({ id = "wild_master_miss", x = 11, y = 5 }) -- dist 6
catching.selectedBallIndex = 4
catching.meter.active = true
catching.meter.power = 1.0 -- miss badly
catching.phase = "metering"
catching:_releaseThrow(game, ow)
check(logic.entities["wild_master_miss"] ~= nil, "master MISS keeps target")
eq(catching:ballCount(game, "MASTER_BALL"), 0, "master MISS still consumes")
for _ = 1, 120 do
  catching.projectile:update(game, ow, 0.05, logic.voxel)
  if catching.phase == "idle" and not catching.projectile:isBusy() then break end
end
catching:cancelAll("test reset")
game.stack._top = ow

-- ---- FAILURE → aggro / ! path (not custom battle) ----
logic.entities = {}
logic.spawns = {}
ow.entities = {}
alertCalls = {}
battleStarts = {}
despawned = {}
game.save.inventory.POKE_BALL = 5
catching.selectedBallIndex = 1
CatchingApi._force = "fail"
entity, record = placeWild({ id = "wild_fail", x = 7, y = 5, facing = "right" })
catching.meter.active = true
catching.meter.power = 2.0
catching.phase = "metering"
catching:_releaseThrow(game, ow)
for _ = 1, 200 do
  catching.projectile:update(game, ow, 0.05, logic.voxel)
  if catching.phase == "idle" and catching.activeCapture == nil
     and not catching.projectile:isBusy() then break end
end
check(logic.entities["wild_fail"] ~= nil, "fail keeps wild entity")
eq(entity.visible, true, "fail restores visibility")
eq(entity.wildsCatchLocked, false, "fail clears catch lock")
check(entity.behavior == Behavior.AGGRESSIVE, "fail transitions to AGGRESSIVE")
check(#alertCalls >= 1, "! alert path called")
eq(#battleStarts, 0, "fail does not custom-start battle directly")
eq(#despawned, 0, "fail does not despawn")
game.stack._top = ow

-- ---- Live setting OFF cancels ----
optionStore.overworld_catching = true
catching:cancelAll("pre-setting")
game.stack._top = ow
catching:_beginMeter()
eq(catching.phase, "metering", "meter starts when ON")
optionStore.overworld_catching = false
catching:onOptionsChanged({ mod = V.mod.id, key = "overworld_catching", value = false })
eq(catching.phase, "idle", "OFF cancels meter")
check(not catching:canAcceptInput(game, ow), "OFF ignores throw input")

optionStore.overworld_catching = true
check(catching:canAcceptInput(game, ow), "ON restores throw")

-- Schema / defaults
local schema = assert(loadfile("options.lua"))()
local byKey = {}
for _, row in ipairs(schema) do byKey[row.key] = row end
check(byKey.overworld_catching ~= nil, "overworld_catching in schema")
eq(byKey.overworld_catching.default, true, "default ON")
eq(Config.overworldCatchingEnabled(V.mod), true, "Config helper ON")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("overworld_catch_flow_unit_test: all passed")
