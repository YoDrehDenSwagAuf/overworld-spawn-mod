-- Land→water chase entry: reservation-before-sprite, occupancy, rollback.
-- Run: lua tests/land_to_water_chase_unit_test.lua
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
  mod = {
    path = ".",
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

local Behavior = V.require("behavior")
local Surface = V.require("surface")
local Movement = V.require("movement")
local CellOccupancy = V.require("cell_occupancy")
local Config = V.require("config")

------------------------------------------------------------------------
-- Fixture map: water on top row (y==0) and left column (x==0); rest land.
------------------------------------------------------------------------
local function makeMap()
  return {
    widthCells = 8,
    heightCells = 6,
    inBounds = function(_, x, y)
      return x >= 0 and y >= 0 and x < 8 and y < 6
    end,
    isWalkableCell = function(_, x, y)
      return not (y == 0 or x == 0)
    end,
    isGrassCell = function(_, x, y)
      return not (y == 0 or x == 0)
    end,
    isWaterCell = function(_, x, y)
      return y == 0 or x == 0
    end,
    warpAtCell = function() return nil end,
  }
end

local function makeLandChaser(x, y, id)
  local e = {
    id = id or "wild_land_1",
    cellX = x,
    cellY = y,
    targetX = nil,
    targetY = nil,
    surface = Surface.GRASS,
    originSurface = Surface.GRASS,
    spriteState = "land",
    overworldWildSpawn = true,
    hasWaterSprite = true,
    facing = "up",
    passable = true,
  }
  Behavior.attach(e, Behavior.AGGRESSIVE, nil, function() return 0 end)
  local bx = e.behaviorState
  bx.chasing = true
  bx.state = Behavior.STATE.CHASING
  bx.playerDetected = true
  bx.chaseReady = true
  bx.sightDisabled = true
  Movement.init(e, x, y, "up")
  return e
end

local function finishStep(entity, occupancy, ctx)
  -- Drive interpolation to completion.
  for _ = 1, 40 do
    if not Movement.isBusy(entity) then break end
    local done = Movement.update(entity, 0.05)
    if done then
      if occupancy then occupancy:commitMove(entity) end
      break
    end
  end
  if entity.behaviorState and entity.behaviorState.pendingWaterEnter then
    Behavior.tick(entity, ctx)
  end
end

------------------------------------------------------------------------
-- Free water entry
------------------------------------------------------------------------
print("== free water entry ==")
do
  local map = makeMap()
  local occ = CellOccupancy.new()
  -- Player further along the water so contact does not fire before entry.
  local player = { cellX = 5, cellY = 0, surfing = true }
  local entity = makeLandChaser(3, 1, "entry_free")
  occ:rebuild({ player = player, entities = { entity } })

  local spriteSwitches = 0
  local logic = {
    refreshEntitySprite = function(_, ent, opts)
      if opts and opts.spriteState == "water" then
        spriteSwitches = spriteSwitches + 1
        ent.spriteState = "water"
      elseif opts and opts.spriteState == "land" then
        ent.spriteState = "land"
      end
      return true
    end,
  }

  local ctx = {
    map = map,
    entities = { entity },
    player = player,
    occupancy = occ,
    logic = logic,
    dt = 0.016,
    waterMonsEnabled = true,
    hasWaterSprite = function() return true end,
    landWaterPlayerMax = 8,
    shoreMap = { distance = { ["5:0"] = 1 } },
  }

  -- During entry attempt, committed surface must stay land.
  Behavior.tick(entity, ctx)
  check(entity.behaviorState.pendingWaterEnter == true
        or Movement.isBusy(entity), "step toward water started")
  eq(entity.surface, Surface.GRASS, "committed surface still land during step")
  check(entity.pendingSurface == Surface.WATER, "pendingSurface water")
  check(entity.spriteState == "water", "spriteState water after reserve")
  check(spriteSwitches >= 1, "water sprite prepared after reserve")
  check(select(1, occ:isReserved(3, 0)) == true, "target water reserved")

  local _, kind, slot = occ:ownerAt(3, 0)
  if kind == "move" and slot then
    eq(slot.kind, "land_to_water_chase", "reservation kind land_to_water_chase")
  else
    check(false, "reservation kind land_to_water_chase")
  end

  finishStep(entity, occ, ctx)
  eq(entity.cellX, 3, "reached water x")
  eq(entity.cellY, 0, "reached water y")
  eq(entity.surface, Surface.WATER, "surface WATER after commit")
  eq(entity.behavior, Behavior.WATER_AGGRESSIVE, "behaviour WATER_AGGRESSIVE")
  check(entity.pendingSurface == nil, "pendingSurface cleared")
end

------------------------------------------------------------------------
-- Sprite must not change when foreign reservation blocks entry
------------------------------------------------------------------------
print("== blocked entry keeps land sprite ==")
do
  local map = makeMap()
  local occ = CellOccupancy.new()
  local player = { cellX = 5, cellY = 0, surfing = true }
  local entity = makeLandChaser(3, 1, "entry_blocked")
  local blocker = {
    id = "water_blocker",
    cellX = 3, cellY = 0,
    overworldWildSpawn = true,
    surface = Surface.WATER,
    passable = true,
  }
  occ:rebuild({ player = player, entities = { entity, blocker } })

  local spriteSwitches = 0
  local logic = {
    refreshEntitySprite = function(_, ent, opts)
      if opts and opts.spriteState == "water" then
        spriteSwitches = spriteSwitches + 1
      elseif opts and opts.spriteState == "land" then
        ent.spriteState = "land"
      end
      return true
    end,
  }

  local ctx = {
    map = map,
    entities = { entity, blocker },
    player = player,
    occupancy = occ,
    logic = logic,
    dt = 0.016,
    waterMonsEnabled = true,
    hasWaterSprite = function() return true end,
    landWaterPlayerMax = 8,
    shoreMap = { distance = { ["5:0"] = 1 } },
  }

  Behavior.tick(entity, ctx)
  -- May walk on land toward the player, but must not begin a water entry.
  check(entity.surface ~= Surface.WATER, "surface not water")
  eq(entity.spriteState, "land", "land sprite remains")
  check(entity.pendingSurface == nil, "no pendingSurface")
  check(entity.waterEntryReserved ~= true, "no leftover water reservation flag")
  check(entity.behaviorState.pendingWaterEnter ~= true, "no pendingWaterEnter")
  check(spriteSwitches == 0, "sprite never switched to water")
  -- Direct water cell must remain owned by the blocker, not the land chaser.
  local owner = occ:ownerAt(3, 0)
  check(owner == CellOccupancy.ownerKey(blocker) or owner == "water_blocker",
        "blocker still owns water cell")
end

------------------------------------------------------------------------
-- Alternate free water cell when direct entry blocked
------------------------------------------------------------------------
print("== alternate water entry cell ==")
do
  local map = makeMap()
  local occ = CellOccupancy.new()
  -- From (1,1): water neighbors are (1,0) and (0,1). Block direct (1,0).
  -- Player on the left water column so (0,1) is the best free step.
  local player = { cellX = 0, cellY = 3, surfing = true }
  local entity = makeLandChaser(1, 1, "entry_alt")
  local blocker = {
    id = "block_direct",
    cellX = 1, cellY = 0,
    overworldWildSpawn = true,
    surface = Surface.WATER,
    passable = true,
  }
  occ:rebuild({ player = player, entities = { entity, blocker } })

  local logic = {
    refreshEntitySprite = function(_, ent, opts)
      if opts and opts.spriteState then ent.spriteState = opts.spriteState end
      return true
    end,
  }
  local ctx = {
    map = map,
    entities = { entity, blocker },
    player = player,
    occupancy = occ,
    logic = logic,
    dt = 0.016,
    waterMonsEnabled = true,
    hasWaterSprite = function() return true end,
    landWaterPlayerMax = 8,
    shoreMap = { distance = { ["0:3"] = 1 } },
  }

  Behavior.tick(entity, ctx)
  check(Movement.isBusy(entity) or entity.behaviorState.pendingWaterEnter,
        "took alternate water step")
  local tx = entity.movement and entity.movement.targetTileX
  local ty = entity.movement and entity.movement.targetTileY
  check(not (tx == 1 and ty == 0), "did not enter blocked water cell")
  eq(tx, 0, "chose side water cell x")
  eq(ty, 1, "chose side water cell y")
  finishStep(entity, occ, ctx)
  eq(entity.cellX, 0, "alt entry x")
  eq(entity.cellY, 1, "alt entry y")
  eq(entity.surface, Surface.WATER, "alt entry committed to water")
  eq(entity.behavior, Behavior.WATER_AGGRESSIVE, "alt entry WATER_AGGRESSIVE")
end

------------------------------------------------------------------------
-- All entry points blocked: wait, no sprite swap, chase stays
------------------------------------------------------------------------
print("== all entries blocked waits ==")
do
  local map = makeMap()
  local occ = CellOccupancy.new()
  local player = { cellX = 6, cellY = 0, surfing = true }
  local entity = makeLandChaser(1, 1, "entry_wait")
  local failsBefore = entity.behaviorState.chaseFailCount or 0
  -- Block both orthogonal water neighbors of (1,1): (1,0) and (0,1).
  local blockers = {
    {
      id = "wblock_a",
      cellX = 1, cellY = 0,
      overworldWildSpawn = true,
      surface = Surface.WATER,
      passable = true,
    },
    {
      id = "wblock_b",
      cellX = 0, cellY = 1,
      overworldWildSpawn = true,
      surface = Surface.WATER,
      passable = true,
    },
  }
  local ents = { entity, blockers[1], blockers[2] }
  occ:rebuild({ player = player, entities = ents })

  local spriteSwitches = 0
  local ctx = {
    map = map,
    entities = ents,
    player = player,
    occupancy = occ,
    logic = {
      refreshEntitySprite = function(_, _, opts)
        if opts and opts.spriteState == "water" then
          spriteSwitches = spriteSwitches + 1
        end
        return true
      end,
    },
    dt = 0.016,
    waterMonsEnabled = true,
    hasWaterSprite = function() return true end,
    landWaterPlayerMax = 8,
    shoreMap = { distance = { ["6:0"] = 1 } },
  }

  Behavior.tick(entity, ctx)
  eq(entity.cellX, 1, "still on shore x")
  eq(entity.cellY, 1, "still on shore y")
  eq(entity.spriteState, "land", "no sprite swap while blocked")
  check(entity.behaviorState.chasing == true, "chase remains active")
  check((entity.behaviorState.chaseFailCount or 0) <= failsBefore,
        "temp occupancy does not raise chaseFailCount")
  eq(spriteSwitches, 0, "no water sprite while fully blocked")
end

------------------------------------------------------------------------
-- Own reservation is idempotent / not self-blocking
------------------------------------------------------------------------
print("== own reservation idempotent ==")
do
  local occ = CellOccupancy.new()
  local a = { id = "self_res", cellX = 1, cellY = 1, overworldWildSpawn = true }
  occ:rebuild({ entities = { a } })
  check(occ:reserveMove(a, 1, 1, 1, 0, { kind = "land_to_water_chase" }) == true,
        "first reserve ok")
  local ok2, why2 = occ:reserveMove(a, 1, 1, 1, 0, { kind = "land_to_water_chase" })
  check(ok2 == true, "second reserve same target idempotent")
  check(why2 == "already_held" or why2 == nil, "idempotent reason")
  check(occ:isReserved(1, 0, a) == false, "own reservation ignored for self")
  check(occ:isReserved(1, 0) == true, "reservation visible to others")
  eq(CellOccupancy.ownerKey(a), "self_res", "ownerKey stable id")
end

------------------------------------------------------------------------
-- No water sprite → no entry
------------------------------------------------------------------------
print("== no water sprite ==")
do
  local map = makeMap()
  local occ = CellOccupancy.new()
  local player = { cellX = 5, cellY = 0, surfing = true }
  local entity = makeLandChaser(3, 1, "no_sprite")
  entity.hasWaterSprite = false
  occ:rebuild({ player = player, entities = { entity } })
  local ctx = {
    map = map,
    entities = { entity },
    player = player,
    occupancy = occ,
    dt = 0.016,
    waterMonsEnabled = true,
    hasWaterSprite = function() return false end,
    landWaterPlayerMax = 8,
    shoreMap = { distance = { ["5:0"] = 1 } },
  }
  Behavior.tick(entity, ctx)
  eq(entity.cellY, 1, "no entry without water sprite")
  eq(entity.surface, Surface.GRASS, "stays on land surface")
  eq(entity.spriteState, "land", "land sprite")
  check(entity.pendingSurface == nil, "no pending water surface")
  check(entity.behaviorState.pendingWaterEnter ~= true, "no pendingWaterEnter")
  check(entity.waterEntryReserved ~= true, "no water entry reservation flag")
end

------------------------------------------------------------------------
-- Water chase after entry respects occupancy (no overlap / swap)
------------------------------------------------------------------------
print("== water chase occupancy ==")
do
  local map = makeMap()
  local occ = CellOccupancy.new()
  local player = { cellX = 5, cellY = 0, surfing = true }
  local chaser = {
    id = "water_chaser",
    cellX = 1, cellY = 0,
    surface = Surface.WATER,
    spriteState = "water",
    overworldWildSpawn = true,
    hasWaterSprite = true,
    facing = "right",
    passable = true,
  }
  Behavior.attach(chaser, Behavior.WATER_AGGRESSIVE, nil, function() return 0 end)
  local bx = chaser.behaviorState
  bx.chasing = true
  bx.state = Behavior.STATE.CHASING
  bx.waterChase = true
  Movement.init(chaser, 1, 0, "right")

  local mid = {
    id = "water_mid",
    cellX = 2, cellY = 0,
    surface = Surface.WATER,
    overworldWildSpawn = true,
    passable = true,
  }
  occ:rebuild({ player = player, entities = { chaser, mid } })
  local ctx = {
    map = map,
    entities = { chaser, mid },
    player = player,
    occupancy = occ,
    dt = 0.016,
    waterMonsEnabled = true,
    hasWaterSprite = function() return true end,
  }
  Behavior.tick(chaser, ctx)
  local tx = chaser.movement and chaser.movement.targetTileX
  local ty = chaser.movement and chaser.movement.targetTileY
  check(not (tx == 2 and ty == 0), "does not step through mid entity")
  if Movement.isBusy(chaser) then
    check(ty == 0, "stays on water")
    check(tx ~= 2, "avoids occupied water cell")
  else
    -- Waited due to temporary block — also acceptable.
    check(chaser.behaviorState.chasing == true, "chase still active while blocked")
  end
end

------------------------------------------------------------------------
-- Premature surface must not abort chase (regression for original bug)
------------------------------------------------------------------------
print("== pending surface does not route to water tick ==")
do
  local map = makeMap()
  local occ = CellOccupancy.new()
  local player = { cellX = 5, cellY = 0, surfing = true }
  local entity = makeLandChaser(3, 1, "no_abort")
  occ:rebuild({ player = player, entities = { entity } })
  local ctx = {
    map = map,
    entities = { entity },
    player = player,
    occupancy = occ,
    logic = {
      refreshEntitySprite = function(_, ent, opts)
        if opts and opts.spriteState then ent.spriteState = opts.spriteState end
        return true
      end,
    },
    dt = 0.016,
    waterMonsEnabled = true,
    hasWaterSprite = function() return true end,
    landWaterPlayerMax = 8,
    shoreMap = { distance = { ["5:0"] = 1 } },
  }
  Behavior.tick(entity, ctx)
  check(Movement.isBusy(entity), "entry step in progress")
  eq(entity.surface, Surface.GRASS, "surface not committed early")
  check(entity.behavior == Behavior.AGGRESSIVE, "still LAND AGGRESSIVE mid-step")
  -- Mid-step tick must not abort via water same-component check.
  local ev = Behavior.tick(entity, ctx)
  check(ev ~= "chase_abort", "no chase_abort during land→water interpolation")
  check(entity.behaviorState.chasing == true, "still chasing mid-step")
  check(Movement.isBusy(entity), "movement not cancelled mid-step")
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll land_to_water_chase tests passed.")
