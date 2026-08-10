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
    visible = true,
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

-- ---- Cycle skips empty (Q default; not E) ----
eq(OverworldCatching.CYCLE_KEYS[1], "q", "cycle default key is Q")
check(OverworldCatching.CYCLE_KEYS[1] ~= "e", "cycle must not use E")
catching.selectedBallIndex = 1
eq(catching:cycleSelectedBall(game, 1), "ULTRA_BALL", "cycle skips Great(0) → Ultra")
eq(catching:cycleSelectedBall(game, 1), "MASTER_BALL", "cycle Ultra → Master")
eq(catching:cycleSelectedBall(game, 1), "POKE_BALL", "cycle Master → Poké")
-- Edge hold must not multi-cycle: simulate held key by calling cycle once only
local held = catching:getSelectedBall(game)
eq(held, "POKE_BALL", "selection stable after edge cycle")

-- ---- Meter charge ----
catching:_beginMeter()
eq(catching.phase, "metering", "C press → metering")
eq(catching.meter.active, true, "meter.active true while charging")
local p0 = catching.meter.power
catching:_updateMeter(0.2)
check(catching.meter.power > p0, "held C advances power")
check(catching.meter.power >= 1 and catching.meter.power <= 6, "power stays in 1..6")
for _ = 1, 40 do catching:_updateMeter(0.1) end
check(catching.meter.power >= 1 and catching.meter.power <= 6, "long hold still clamps 1..6")

-- ---- Projectile travels selected power distance (not auto-aim to mon) ----
local lx, ly = catching.projectile.landCell(5, 5, "right", 2)
eq(lx, 7, "RIGHT power 2 → x+2")
eq(ly, 5, "RIGHT power 2 → same y")
lx, ly = catching.projectile.landCell(5, 5, "right", 6)
eq(lx, 11, "RIGHT power 6 → x+6")
lx, ly = catching.projectile.landCell(5, 5, "left", 3)
eq(lx, 2, "LEFT power 3 → x-3")
lx, ly = catching.projectile.landCell(5, 5, "up", 4)
eq(ly, 1, "UP power 4 → y-4")
lx, ly = catching.projectile.landCell(5, 5, "down", 1)
eq(ly, 6, "DOWN power 1 → y+1")

-- ---- No balls message path ----
local emptyGameInv = game.save.inventory
game.save.inventory = {}
check(not catching:anyBalls(game), "no balls")
game.save.inventory = emptyGameInv
catching:cancelAll("reset after meter")

-- ---- MISS: consumes ball, no catch, no battle, target remains, Ball removed ----
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
eq(entity.visible, true, "MISS leaves Pokémon visible")
check(not entity.wildsCatchLocked, "MISS does not lock target")
check(entity.wildsCatchState ~= "pending" and entity.wildsCatchState ~= "capturing",
  "MISS does not leave catch state")
-- finish projectile
for _ = 1, 120 do
  catching.projectile:update(game, ow, 0.05, logic.voxel)
  if catching.phase == "idle" and not catching.projectile:isBusy() then break end
end
eq(catching.phase, "idle", "MISS cleans to idle")
check(not catching.projectile:isBusy(), "MISS projectile not busy")
check(catching.projectile._trackedBall == nil, "MISS clears tracked Ball")
local ballLeft = false
for _, e in ipairs(ow.entities) do
  if e and e.isPokeBallEntity then ballLeft = true end
end
check(not ballLeft, "MISS removes Ball from ow.entities")

-- ---- HIT: Pokémon stays visible during flight; hides only at impact ----
logic.entities = {}
logic.spawns = {}
ow.entities = {}
despawned = {}
occupancyReleased = {}
entity, record = placeWild({ id = "wild_hit_vis", x = 7, y = 5, facing = "right" })
CatchingApi._force = "catch"
catching.selectedBallIndex = 1
catching.meter.active = true
catching.meter.power = 2.0
catching.phase = "metering"
catching:_releaseThrow(game, ow)
eq(catching.phase, "flying", "HIT starts flying")
eq(entity.visible, true, "Pokémon visible during flight")
eq(entity.wildsCatchState, "pending", "pending freeze during flight")
eq(entity.wildsCatchLocked, false, "not fully locked until impact")
-- Advance almost to impact but stop before wobble resolve
local sawImpactHide = false
for _ = 1, 200 do
  local wasFlying = catching.phase == "flying"
  catching.projectile:update(game, ow, 0.05, logic.voxel)
  if wasFlying and catching.phase == "capturing" then
    sawImpactHide = entity.visible == false and entity.wildsCatchLocked == true
    break
  end
  if catching.phase == "idle" then break end
end
check(sawImpactHide, "Pokémon hidden only at impact")
-- finish capture
for _ = 1, 200 do
  catching.projectile:update(game, ow, 0.05, logic.voxel)
  if catching.phase == "idle" and catching.activeCapture == nil
     and not catching.projectile:isBusy() then break end
end
check(logic.entities["wild_hit_vis"] == nil, "HIT success removes entity after impact path")
game.stack._top = ow

-- ---- SUCCESS (+ SUCCESS_CLICK visual) ----
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
local sawWobble, sawClick, sawFailBreak = false, false, false
for _ = 1, 400 do
  catching.projectile:update(game, ow, 0.05, logic.voxel)
  local vp = catching.projectile:visualPhase()
  if vp == "WOBBLE" then sawWobble = true end
  if vp == "SUCCESS_CLICK" then sawClick = true end
  if vp == "FAIL_BREAK" then sawFailBreak = true end
  if catching.phase == "idle" and not catching.projectile:isBusy()
     and catching.activeCapture == nil then break end
end
check(sawWobble, "success passed through WOBBLE")
check(sawClick, "success passed through SUCCESS_CLICK")
check(not sawFailBreak, "success never enters FAIL_BREAK")
check(logic.entities["wild_ok"] == nil, "success removes wild entity")
check(#despawned >= 1, "success used Wilds despawn")
check(#occupancyReleased >= 1, "success released occupancy")
check(#game.save.party == partyBefore + 1, "success added to party")
eq(#battleStarts, 0, "success starts no battle")
eq(catching.phase, "idle", "success clears capture state")
check(not catching.projectile:isBusy(), "projectile removed")
check(catching.projectile._trackedBall == nil, "success clears tracked Ball")
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

-- ---- FAILURE → FAIL_BREAK → aggro / ! (not custom battle) ----
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
local sawFailWobble, sawFailBreak, sawSuccessClick = false, false, false
local sawRevealBeforeIdle = false
for _ = 1, 400 do
  catching.projectile:update(game, ow, 0.05, logic.voxel)
  local vp = catching.projectile:visualPhase()
  if vp == "WOBBLE" then sawFailWobble = true end
  if vp == "FAIL_BREAK" then
    sawFailBreak = true
    if entity.visible == true then sawRevealBeforeIdle = true end
  end
  if vp == "SUCCESS_CLICK" then sawSuccessClick = true end
  if catching.phase == "idle" and catching.activeCapture == nil
     and not catching.projectile:isBusy() then break end
end
check(sawFailWobble, "fail passed through WOBBLE")
check(sawFailBreak, "fail passed through FAIL_BREAK")
check(not sawSuccessClick, "fail never enters SUCCESS_CLICK")
check(sawRevealBeforeIdle or entity.visible == true, "Pokémon reappears during/after break")
check(logic.entities["wild_fail"] ~= nil, "fail keeps wild entity")
eq(entity.visible, true, "fail restores visibility")
eq(entity.wildsCatchLocked, false, "fail clears catch lock")
check(not entity.wildsCatchPending, "fail clears pending")
check(entity.behavior == Behavior.AGGRESSIVE, "fail transitions to AGGRESSIVE")
check(#alertCalls >= 1, "! alert path called")
eq(#battleStarts, 0, "fail does not custom-start battle directly")
eq(#despawned, 0, "fail does not despawn")
check(not catching.projectile:isBusy(), "fail Ball cleaned")
local failBallLeft = false
for _, e in ipairs(ow.entities) do
  if e and e.isPokeBallEntity then failBallLeft = true end
end
check(not failBallLeft, "fail removes Ball from ow.entities")
game.stack._top = ow

-- ---- Re-catch same AGGRESSIVE mon before battle starts ----
local Target = OverworldCatching.Target
-- Simulate ! emote flag that previously blocked targeting.
entity.alertIcon = true
check(Target.isCatchableWild(entity), "aggressive+alertIcon still catchable")
local found, fdist = Target.findAhead(logic, ow, ow.player, 6)
check(found == entity, "findAhead retargets aggressive mon")
eq(fdist, 2, "retarget distance still 2")
eq(#battleStarts, 0, "no battle yet before second throw")
check(catching:canAcceptInput(game, ow), "input accepted before battle")
CatchingApi._force = "catch"
local ballsBeforeRetry = catching:ballCount(game, "POKE_BALL")
catching.selectedBallIndex = 1
catching.meter.active = true
catching.meter.power = 2.0
catching.phase = "metering"
catching:_releaseThrow(game, ow)
eq(catching:ballCount(game, "POKE_BALL"), ballsBeforeRetry - 1, "second throw consumes ball")
eq(catching.phase, "flying", "second catch flight starts")
for _ = 1, 400 do
  catching.projectile:update(game, ow, 0.05, logic.voxel)
  if catching.phase == "idle" and catching.activeCapture == nil
     and not catching.projectile:isBusy() then break end
end
check(logic.entities["wild_fail"] == nil, "second throw can catch aggressive mon")
eq(#battleStarts, 0, "successful re-catch starts no battle")
game.stack._top = ow

-- ---- pendingBattle / battle transition rejects throws ----
logic.entities = {}
logic.spawns = {}
ow.entities = {}
entity, record = placeWild({ id = "wild_battle", x = 7, y = 5, facing = "right" })
entity.behavior = Behavior.AGGRESSIVE
Behavior.attach(entity, Behavior.AGGRESSIVE, nil, function() return 1 end)
logic.pendingBattle = { id = "wild_battle" }
check(not catching:canAcceptInput(game, ow), "pendingBattle blocks throw")
logic.pendingBattle = nil
entity.state = Config.STATE.ENCOUNTER_STARTING
check(not Target.isCatchableWild(entity), "ENCOUNTER_STARTING not catchable")
entity.state = "available"
entity.behaviorState.battleStarted = true
check(not Target.isCatchableWild(entity), "battleStarted not catchable")
entity.behaviorState.battleStarted = false
entity.behaviorState.battlePending = true
check(not Target.isCatchableWild(entity), "battlePending not catchable")
entity.behaviorState.battlePending = false
check(Target.isCatchableWild(entity), "aggressive without battle is catchable again")

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

-- Ball presentation size contract
eq(catching.projectile.BALL_VISUAL_PX, 6, "projectile visual ~6px (unchanged)")
local BallHudMod = V.require("catching/hud")
eq(BallHudMod.ICON_PX, 9, "HUD icon ~9px")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("overworld_catch_flow_unit_test: all passed")
