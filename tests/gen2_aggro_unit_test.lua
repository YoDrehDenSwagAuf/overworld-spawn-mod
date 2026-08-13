-- Gen2 aggressive chase: Gold emote contract + shared Behavior chase path.
--
-- The Gold crash was World:update doing `self.emote.left = self.emote.left - 1`
-- after Wilds wrote the Gen1 { npc, frames, onDone } shape (left is nil).
-- These tests are UNIT TESTED engine-path checks, not a live ROM boot.
--
-- Run: lua tests/gen2_aggro_unit_test.lua
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

local engine = { version = "gold", generation = 2 }
package.loaded["src.core.GameVersion"] = {
  get = function() return engine.version end,
  isYellow = function() return engine.version == "yellow" end,
  isGold = function() return engine.version == "gold" end,
  generation = function() return engine.generation end,
}

local modules = {}
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end, error = function() end },
    find = function() return nil end,
    options = { get = function() return nil end },
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

local GameCompat = V.require("game_compat")
local Behavior = V.require("behavior")
local Movement = V.require("movement")
local Surface = V.require("surface")

local function makeLandMap(opts)
  opts = opts or {}
  local walls = opts.walls or {}
  local function key(x, y) return tostring(x) .. "," .. tostring(y) end
  local blocked = {}
  for _, w in ipairs(walls) do blocked[key(w[1], w[2])] = true end
  return {
    id = opts.id or "ROUTE_29",
    widthCells = 12,
    heightCells = 10,
    inBounds = function(_, x, y)
      return x >= 0 and y >= 0 and x < 12 and y < 10
    end,
    isWalkableCell = function(_, x, y)
      if x < 0 or y < 0 or x >= 12 or y >= 10 then return false end
      return not blocked[key(x, y)]
    end,
    isWaterCell = function() return false end,
    isGrassCell = function() return true end,
    warpAtCell = function() return nil end,
  }
end

local function makeChaser(x, y, facing)
  local e = {
    id = "wild_spearow_1",
    species = "SPEAROW",
    cellX = x,
    cellY = y,
    facing = facing or "up",
    surface = Surface.GRASS,
    overworldWildSpawn = true,
    passable = true,
    px = x * 16,
    py = y * 16,
  }
  Movement.init(e, x, y, e.facing)
  Behavior.attach(e, Behavior.AGGRESSIVE, nil, function(n)
    if n then return 1 end
    return 0.5
  end)
  e.facing = facing or "up"
  e.behaviorState.facing = e.facing
  return e
end

----------------------------------------------------------------
-- Gold emote shape vs Gen1 snapshot
----------------------------------------------------------------
do
  engine.version, engine.generation = "gold", 2
  local entity = { id = "e1", cellX = 12, cellY = 9, px = 192, py = 144 }
  local ow = {
    emote = nil,
    engaging = false,
    player = { cellX = 12, cellY = 5 },
    map = { id = "ROUTE_29" },
    emoteOrder = { "SHOCK" },
    emoteImages = { SHOCK = "shock-sheet" },
  }
  local armed = false
  local shown = GameCompat.showWildAlertEmote(ow, entity, 60, function()
    armed = true
  end, { version = "gold" })
  check(shown, "Gold alert emote accepted")
  check(ow.emote ~= nil, "Gold emote payload set")
  eq(type(ow.emote.left), "number", "Gold emote.left is a number")
  eq(ow.emote.left, 60, "Gold emote.left == frames")
  eq(ow.emote.entity, entity, "Gold emote.entity is the wild")
  eq(ow.emote.npc, entity, "Gold emote.npc still set for cleanup")
  eq(ow.emote.image, "shock-sheet", "Gold uses shock sheet when present")
  check(ow.emote._wildsAlert == true, "Gold emote marked _wildsAlert")

  -- Reproduce Gold World:update emote arm. Must not error.
  local okTick, errTick = pcall(function()
    for _ = 1, 59 do GameCompat.tickGoldEmote(ow) end
  end)
  check(okTick, "Gold World emote tick does not crash: " .. tostring(errTick))
  check(ow.emote ~= nil, "emote still live before last frame")
  eq(ow.emote.left, 1, "one frame left")
  GameCompat.tickGoldEmote(ow)
  check(ow.emote == nil, "Gold World nils emote at left<=0")
  check(armed == false, "Gold World does not call onDone")
  local polled = GameCompat.pollWildAlertEmote(ow)
  check(polled, "poll fires Gold onDone after expiry")
  check(armed, "chase/flee callback armed after poll")
end

do
  -- The exact Gen1 shape Gold World cannot tick.
  local bad = { npc = {}, frames = 60, onDone = function() end }
  local ow = { emote = bad }
  local ok, err = pcall(GameCompat.tickGoldEmote, ow)
  check(not ok, "Gen1 {frames} emote on Gold World errors")
  check(tostring(err):find("left", 1, true) ~= nil,
        "error names the nil `left` field")
end

do
  engine.version, engine.generation = "red", 1
  local entity = { id = "e-red", cellX = 4, cellY = 4 }
  local ow = { emote = nil, engaging = false }
  GameCompat.showWildAlertEmote(ow, entity, 60, function() end, { version = "red" })
  eq(ow.emote.npc, entity, "Gen1 emote.npc")
  eq(ow.emote.frames, 60, "Gen1 emote.frames")
  check(type(ow.emote.onDone) == "function", "Gen1 emote.onDone")
  check(ow.emote.left == nil, "Gen1 emote has no `left` field")
  check(ow.emote.entity == nil, "Gen1 emote has no `entity` field")
  check(ow.emote._wildsAlert == nil, "Gen1 emote is not a Gold payload")
  check(ow._wildsAlertEmote == nil, "Gen1 does not stash Gold pending emote")
  engine.version, engine.generation = "gold", 2
end

----------------------------------------------------------------
-- Sight / chase / wall / contact (shared Behavior, Gold-shaped map)
----------------------------------------------------------------
do
  engine.version, engine.generation = "gold", 2
  local map = makeLandMap()
  local e = makeChaser(12, 9, "up")
  -- remap to in-bounds cells
  e.cellX, e.cellY = 6, 6
  e.px, e.py = 96, 96
  Movement.init(e, 6, 6, "up")
  e.behaviorState.facing = "up"
  e.facing = "up"

  local playerFar = { cellX = 6, cellY = 1 } -- 5 cells north, in sight if range>=4
  local ctx = {
    map = map,
    entities = { e },
    player = playerFar,
    dt = 0.016,
    sightRange = 4,
  }
  -- Player at y=1 is dist 5 from y=6 — outside range 4.
  local ev = Behavior.tick(e, ctx)
  check(ev ~= "alert", "player outside sight → no chase")
  eq(e.behaviorState.chasing, false, "not chasing when out of range")

  ctx.player = { cellX = 6, cellY = 3 } -- dist 3, directly ahead
  ev = Behavior.tick(e, ctx)
  eq(ev, "alert", "player directly ahead → alert")
  eq(e.behaviorState.state, Behavior.STATE.ALERT, "state ALERT after sight")
  eq(e.cellX, 6, "alert does not move the entity")

  -- Wall between Pokémon and player: no sight.
  local e2 = makeChaser(6, 6, "up")
  local wallMap = makeLandMap({ walls = { { 6, 5 } } })
  local evWall = Behavior.tick(e2, {
    map = wallMap, entities = { e2 },
    player = { cellX = 6, cellY = 3 }, dt = 0.016, sightRange = 4,
  })
  check(evWall ~= "alert", "wall between Pokémon/player → no sight")
  eq(e2.behaviorState.chasing, false, "walled sight does not start chase")

  -- Chase step after emote onDone.
  Behavior.markChaseReady(e)
  Behavior.tick(e, {
    map = map, entities = { e },
    player = { cellX = 6, cellY = 3 }, dt = 0.016, sightRange = 4,
  })
  check(e.behaviorState.state == Behavior.STATE.CHASING
        or e.behaviorState.chasing,
        "chase starts after markChaseReady")
  local okStep, errStep = pcall(function()
    Behavior.tick(e, {
      map = map, entities = { e },
      player = { cellX = 6, cellY = 3 }, dt = 0.2, sightRange = 4,
    })
  end)
  check(okStep, "Gen2 chase stepToward does not crash: " .. tostring(errStep))

  -- Adjacent player → battle pending.
  local e3 = makeChaser(6, 6, "up")
  e3.behaviorState.state = Behavior.STATE.CHASING
  e3.behaviorState.chasing = true
  e3.behaviorState.chaseReady = true
  e3.behaviorState.playerDetected = true
  e3.behaviorState.sightDisabled = true
  local evContact = Behavior.tick(e3, {
    map = map, entities = { e3 },
    player = { cellX = 6, cellY = 5 }, dt = 0.016, sightRange = 4,
  })
  check(evContact == "contact" or evContact == "battle_pending"
        or e3.behaviorState.state == Behavior.STATE.BATTLE_PENDING,
        "adjacent player → battle pending/contact")

  -- Non-aggressive wander unchanged: GRASS_WANDER never alerts.
  local wander = {
    id = "wander_1", cellX = 6, cellY = 6, facing = "up",
    surface = Surface.GRASS, overworldWildSpawn = true, passable = true,
  }
  Movement.init(wander, 6, 6, "up")
  Behavior.attach(wander, Behavior.GRASS_WANDER, nil, function(n)
    if n then return 1 end
    return 0.5
  end)
  wander.behaviorState.facing = "up"
  wander.facing = "up"
  local evW = Behavior.tick(wander, {
    map = map, entities = { wander },
    player = { cellX = 6, cellY = 3 }, dt = 0.016, sightRange = 4,
  })
  check(evW ~= "alert", "non-aggressive wander does not alert")
  eq(wander.behaviorState.chasing, false, "wander is not chasing")
end

----------------------------------------------------------------
-- Gen1 aggressive snapshot still uses the same Behavior states
----------------------------------------------------------------
do
  engine.version, engine.generation = "red", 1
  local map = makeLandMap({ id = "ROUTE_1" })
  local e = makeChaser(6, 6, "up")
  local ev = Behavior.tick(e, {
    map = map, entities = { e },
    player = { cellX = 6, cellY = 3 }, dt = 0.016, sightRange = 4,
  })
  eq(ev, "alert", "Gen1 aggressive still alerts")
  eq(e.behaviorState.state, Behavior.STATE.ALERT, "Gen1 still ALERT")
  Behavior.markChaseReady(e)
  Behavior.tick(e, {
    map = map, entities = { e },
    player = { cellX = 6, cellY = 3 }, dt = 0.016, sightRange = 4,
  })
  check(e.behaviorState.chasing or e.behaviorState.state == Behavior.STATE.CHASING,
        "Gen1 chase still arms")
  engine.version, engine.generation = "gold", 2
end

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("gen2_aggro_unit_test: all passed")
