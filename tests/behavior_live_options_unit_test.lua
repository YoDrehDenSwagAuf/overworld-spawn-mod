-- Live behaviour toggles for EXISTING entities (Gen1 + Gen2 wrap).
-- Run: lua tests/behavior_live_options_unit_test.lua
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
local Movement = V.require("movement")
local GameCompat = V.require("game_compat")
local BehaviorTick = V.require("behavior_tick")
local Config = V.require("config")

local function makeEntity(behavior, extras)
  extras = extras or {}
  local e = {
    id = extras.id or "wild_1",
    species = extras.species or "PIDGEY",
    cellX = extras.x or 4,
    cellY = extras.y or 4,
    surface = extras.surface,
    overworldWildSpawn = true,
    sprite = extras.sprite or { id = "sprite-A" },
    facing = "down",
    passable = false,
  }
  Behavior.attach(e, behavior, extras.region, function() return 0.2 end)
  e.sprite = extras.sprite or e.sprite
  return e
end

----------------------------------------------------------------
-- WANDER ON -> OFF keeps identity, stops wander, picks another enabled type
----------------------------------------------------------------
do
  local e = makeEntity(Behavior.GRASS_WANDER)
  local id, sprite, bx = e.id, e.sprite, e.behaviorState
  Movement.beginStep(e, 5, 4, { facing = "right" })
  check(Movement.isBusy(e) == true, "wanderer is mid-step before toggle")
  local changed, presentation = Behavior.resetForConfigChange(e, {
    enable_idle = true,
    enable_wander = false,
    enable_aggressive = true,
    enable_hidden = true,
    rng = function() return 0 end,
  })
  check(changed == true, "wander OFF re-evaluates existing wanderer")
  eq(presentation, nil, "wander OFF does not rebuild presentation")
  check(e == e, "same entity table")
  eq(e.id, id, "same entity id")
  check(e.sprite == sprite, "same SpriteRenderer / sprite table")
  check(e.behaviorState == bx, "same behaviorState table")
  check(e.behavior ~= Behavior.GRASS_WANDER, "wander type cleared")
  check(Behavior.isEnabledBehavior(e.behavior, {
    enable_idle = true, enable_wander = false,
    enable_aggressive = true, enable_hidden = true,
  }), "replacement is still enabled")
  check(Movement.isBusy(e) == false, "stale wander step stopped")
  eq(e.cellX, 4, "cell preserved (no teleport)")
  eq(e.cellY, 4, "cell Y preserved")
end

----------------------------------------------------------------
-- WANDER OFF -> ON does not recreate allowed idle entities
----------------------------------------------------------------
do
  local e = makeEntity(Behavior.IDLE_LOOK)
  local bx, sprite = e.behaviorState, e.sprite
  local changed = Behavior.resetForConfigChange(e, {
    enable_idle = true,
    enable_wander = true,
    enable_aggressive = true,
    enable_hidden = true,
  })
  check(changed == false, "wander ON leaves allowed idle unchanged")
  check(e.behaviorState == bx, "idle identity preserved when wander enabled")
  check(e.sprite == sprite, "sprite identity preserved")
  eq(e.behavior, Behavior.IDLE_LOOK, "stays idle")
end

----------------------------------------------------------------
-- AGGRESSIVE ON -> OFF stops chase and re-picks
----------------------------------------------------------------
do
  local e = makeEntity(Behavior.AGGRESSIVE)
  local bx = e.behaviorState
  bx.chasing = true
  bx.chaseReady = true
  bx.state = Behavior.STATE.CHASING
  local sprite = e.sprite
  local changed = Behavior.resetForConfigChange(e, {
    enable_idle = true,
    enable_wander = true,
    enable_aggressive = false,
    enable_hidden = true,
    rng = function() return 0 end,
  })
  check(changed == true, "aggressive OFF re-evaluates chaser")
  check(e.sprite == sprite, "chase OFF does not rebuild sprite")
  check(e.behavior ~= Behavior.AGGRESSIVE, "aggressive type cleared")
  check(e.behaviorState.chasing ~= true, "chase flag cleared")
  check(e.behaviorState.chaseReady ~= true, "chaseReady cleared")
  check(e.behaviorState == bx, "same behaviorState")
end

----------------------------------------------------------------
-- AGGRESSIVE OFF -> ON does not rebuild allowed wanderers
----------------------------------------------------------------
do
  local e = makeEntity(Behavior.GRASS_WANDER)
  local bx, sprite = e.behaviorState, e.sprite
  local changed = Behavior.resetForConfigChange(e, {
    enable_idle = true,
    enable_wander = true,
    enable_aggressive = true,
    enable_hidden = true,
  })
  check(changed == false, "aggressive ON leaves wanderer on next AI decision")
  eq(e.behavior, Behavior.GRASS_WANDER, "stays wander")
  check(e.behaviorState == bx, "same state table")
  check(e.sprite == sprite, "same sprite")
end

----------------------------------------------------------------
-- IDLE toggle re-evaluates only when idle is the current type
----------------------------------------------------------------
do
  local e = makeEntity(Behavior.IDLE_LOOK)
  local changed = Behavior.resetForConfigChange(e, {
    enable_idle = false,
    enable_wander = true,
    enable_aggressive = true,
    enable_hidden = true,
    rng = function() return 0.99 end,
  })
  check(changed == true, "idle OFF re-evaluates idler")
  check(e.behavior ~= Behavior.IDLE_LOOK, "idle type cleared")
end

----------------------------------------------------------------
-- HIDDEN OFF reveals without destroying the entity
----------------------------------------------------------------
do
  local e = makeEntity(Behavior.HIDDEN_GRASS)
  e.hiddenEncounter = true
  e.visibleSprite = false
  local id = e.id
  local changed, presentation = Behavior.resetForConfigChange(e, {
    enable_idle = true,
    enable_wander = true,
    enable_aggressive = true,
    enable_hidden = false,
    rng = function() return 0 end,
  })
  check(changed == true, "hidden OFF re-evaluates hidden marker")
  eq(presentation, "reveal", "hidden OFF asks caller to reveal once")
  eq(e.id, id, "hidden reveal keeps id")
  check(e.hiddenEncounter ~= true, "no longer a hidden marker")
  check(e.visibleSprite == true, "sprite becomes visible")
end

----------------------------------------------------------------
-- HIDDEN ON does not convert an existing wanderer
----------------------------------------------------------------
do
  local e = makeEntity(Behavior.GRASS_WANDER)
  local changed = Behavior.resetForConfigChange(e, {
    enable_idle = true,
    enable_wander = true,
    enable_aggressive = true,
    enable_hidden = true,
  })
  check(changed == false, "hidden ON leaves wanderer")
  eq(e.behavior, Behavior.GRASS_WANDER, "stays wander")
end

----------------------------------------------------------------
-- Gen2 update owner: World:updatePeople must not drive Movement
----------------------------------------------------------------
do
  local origIsGen2 = GameCompat.isGen2
  GameCompat.isGen2 = function() return true end
  local e = makeEntity(Behavior.GRASS_WANDER)
  local origUpdate = function() end
  e.update = origUpdate
  GameCompat.adaptWildEntity(e, { generation = 2 })
  check(e._wildsGoldAdapted == true, "gold adapted")
  Movement.beginStep(e, 5, 4, { facing = "right" })
  e:update({ id = "map" }, {})
  check(Movement.isBusy(e) == true, "table-arg update does not complete the step")
  local stolen = function() error("npc update must not run") end
  e.update = stolen
  GameCompat.ensureWildEntityUpdateOwner(e, { generation = 2 })
  check(e.update ~= stolen, "ensureWildEntityUpdateOwner restores wrap")
  e:update({ id = "map" }, {})
  GameCompat.isGen2 = origIsGen2
end

----------------------------------------------------------------
-- Pipeline helper exists; stepFromWorld does not double-advance when fresh
----------------------------------------------------------------
do
  check(type(BehaviorTick.ensurePipeline) == "function", "ensurePipeline exists")
  local tick = BehaviorTick.new({
    world = { game = { overworld = { map = { id = "x" }, player = {} } } },
    log = { info = function() end },
  }, { state = { initialized = false } })
  tick._lastT = 1e12
  tick.ensurePipeline = function(self)
    self._ensured = (self._ensured or 0) + 1
  end
  local stepped = 0
  tick.step = function() stepped = stepped + 1 end
  tick:stepFromWorld({})
  eq(tick._ensured, 1, "stepFromWorld re-asserts pipeline")
  eq(stepped, 0, "fresh _lastT does not double-run AI")
end

eq(Config.DEFAULTS.enable_wander, true, "config wander default")
eq(Config.DEFAULTS.enable_aggressive, true, "config chase default")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("behavior_live_options_unit_test: all passed")
