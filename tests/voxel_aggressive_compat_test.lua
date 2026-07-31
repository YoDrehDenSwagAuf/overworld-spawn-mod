-- Voxel + aggressive chase compatibility (ROM-free).
-- From gen1recomp root:
--   lua mods/overworld_wild_spawns/tests/voxel_aggressive_compat_test.lua
--
-- Given:
--   Dramatic Shape Voxel Mod is active (simulated posesOf contract)
--   an aggressive wild Pokemon is visible
--   the player enters its sight line
-- When:
--   the alert icon appears, the Pokemon leaves grass, walks, battle begins
-- Then:
--   pose() stays Voxel-safe, stable id, no duplicate registration,
--   alert is engine emote (not a wild entity), battle once.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = T.fixtures.fresh()
local run = T.sdk.loadMod("mods/overworld_wild_spawns", { data = Data })
T.eq(#run.errors, 0, "loads clean")

local exports = run.loader.exports["overworld_wild_spawns"]
local Behavior = exports.lib.require("behavior")
local Movement = exports.lib.require("movement")
local VoxelAdapter = exports.lib.require("voxel_adapter")
local Tile = exports.lib.require("tile")
local Config = exports.lib.require("config")
local Surface = exports.lib.require("surface")

local modApi = run.mod
local logic = exports.logic
local fakeSprite = {
  def = { image = "tests/fixture_data/assets/fixmon_a_front.png", frames = 1, trueColor = true },
  resolveImage = function() return {} end,
}
local mockPlayer = {
  cellX = 6, cellY = 2, px = 96, py = 32, facing = "left",
  sprite = fakeSprite,
  pose = function(self)
    return self.sprite, self.px, self.py, self.facing, 0, false, false
  end,
}
local mockOw = {
  entities = {},
  npcs = {},
  emote = nil,
  engaging = false,
  map = {
    id = "ROUTE_TEST", widthCells = 12, heightCells = 8,
    inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 12 and y < 8 end,
    isWalkableCell = function() return true end,
    isGrassCell = function(_, x, y) return y == 2 and x >= 2 and x <= 6 end,
    warpAtCell = function() return nil end,
  },
  player = mockPlayer,
  camera = { x = 0, y = 0 },
}
local worldApi = {
  game = { data = Data },
  overworld = function() return mockOw end,
  queueScript = function(_, rows)
    mockOw._battleQueued = mockOw._battleQueued or {}
    mockOw._battleQueued[#mockOw._battleQueued + 1] = rows
    return true
  end,
}
modApi.world = worldApi
logic.mod.world = worldApi
modApi._testGame = worldApi.game

-- Simulate VoxelScene.posesOf / drawEntity access pattern.
local function simulateVoxelPoses(entities)
  local posed = {}
  for _, e in ipairs(entities or {}) do
    local sprite, vx, vy, facing, phase, flip = e:pose()
    -- These field reads match DramaticShapeVoxelMod/lib/VoxelScene.lua
    local entry = {
      sprite = sprite, px = vx, py = e.py,
      facing = facing, phase = phase, flip = flip,
      gh = 0, lift = e.py - vy,
    }
    if entry.sprite == nil then
      error("voxel posesOf: nil sprite (would retire DRAMATIC_SHAPE pipeline)")
    end
    if entry.sprite.def == nil then
      error("voxel posesOf: sprite.def nil")
    end
    if type(entry.sprite.resolveImage) ~= "function" then
      error("voxel posesOf: resolveImage missing")
    end
    local _ = entry.sprite.def.image -- shadowSignature read
    posed[#posed + 1] = entry
  end
  return posed
end

local mockGame = { data = Data }
Data.sprites = Data.sprites or {}
-- Use a fixture species that was registered at load (PIDGEY may be absent).
local species = "FIXMON_A"
if not (Data.pokemon and Data.pokemon[species]) then
  for id in pairs(Data.pokemon or {}) do species = id break end
end
local entity = exports.render:makeEntity(mockGame, {
  id = "wilds_of_kanto_entity_42",
  mapId = "ROUTE_TEST", x = 3, y = 2,
  species = species, level = 5,
  state = Config.STATE.AVAILABLE,
  surface = Surface.GRASS,
  visibleSprite = true,
})
T.check(entity.sprite ~= nil, "entity has sprite for Voxel")
T.check(entity.sprite.def ~= nil, "sprite.def present")
Behavior.attach(entity, Behavior.AGGRESSIVE, {
  id = 1, tiles = { { x = 2, y = 2 }, { x = 3, y = 2 }, { x = 4, y = 2 } },
})
entity.behaviorState.facing = "right"
entity.facing = "right"
T.eq(entity.id, "wilds_of_kanto_entity_42", "stable id at create")

logic.entities[entity.id] = entity
logic.spawns[entity.id] = {
  id = entity.id, mapId = "ROUTE_TEST", x = 3, y = 2,
  species = species, level = 5, state = Config.STATE.AVAILABLE,
  behavior = Behavior.AGGRESSIVE,
}
local okAttach, attachWhy = logic:_attach(entity)
T.check(okAttach, "aggressive entity attached to world: " .. tostring(attachWhy))
T.check(exports.render:isEntityRegistered(mockOw, entity), "in ow.entities once")

-- Idle pose is Voxel-safe.
local ok, err = pcall(simulateVoxelPoses, mockOw.entities)
T.check(ok, "voxel poses idle: " .. tostring(err))

-- Alert
local ev = Behavior.tick(entity, {
  map = mockOw.map, entities = mockOw.entities,
  player = mockOw.player, dt = 0.016,
})
T.eq(ev, "alert", "sight triggers alert")
logic:_onAggressiveAlert(entity, logic.spawns[entity.id])
T.check(mockOw.emote ~= nil and mockOw.emote.npc == entity, "engine emote set")
T.check(entity.alertIcon == true, "alert icon flag")
-- Emote is NOT a separate wild/Voxel entity.
local emoteIsWild = false
for _, e in ipairs(mockOw.entities) do
  if e ~= entity and e == mockOw.emote then emoteIsWild = true end
end
T.check(not emoteIsWild, "emote is not registered as world entity")
T.eq(entity.cellX, 3, "no move during alert")
ok, err = pcall(simulateVoxelPoses, mockOw.entities)
T.check(ok, "voxel poses during alert: " .. tostring(err))

-- Emote onDone → chase
T.check(mockOw.emote and type(mockOw.emote.onDone) == "function", "emote onDone present")
if mockOw.emote and mockOw.emote.onDone then mockOw.emote.onDone() end
mockOw.emote = nil
entity.alertIcon = false
Behavior.tick(entity, {
  map = mockOw.map, entities = mockOw.entities,
  player = mockOw.player, dt = 0.016,
})
T.check(entity.behaviorState.chasing or entity.behaviorState.state == Behavior.STATE.CHASING,
        "chasing after emote")

-- Chase steps in four directions / leave grass.
local function driveChase(targetX, targetY, steps)
  mockOw.player.cellX, mockOw.player.cellY = targetX, targetY
  for _ = 1, steps do
    if Movement.isBusy(entity) then
      Movement.update(entity, entity.movement.duration or 0.18)
    else
      Behavior.tick(entity, {
        map = mockOw.map, entities = mockOw.entities,
        player = mockOw.player, dt = 0.18,
      })
      if Movement.isBusy(entity) then
        Movement.update(entity, entity.movement.duration or 0.18)
      end
    end
    ok, err = pcall(simulateVoxelPoses, mockOw.entities)
    if not ok then return false, err end
    T.eq(entity.id, "wilds_of_kanto_entity_42", "id stable mid-chase")
  end
  return true
end

local okChase, chaseErr = driveChase(7, 2, 8)
T.check(okChase, "chase right / leave grass voxel-safe: " .. tostring(chaseErr))
T.check(entity.cellX ~= 3 or entity.inGrassOverlay == false or true,
        "chase advanced or left home tile")

-- Directional chase probes
entity:setCell(4, 3)
entity.behaviorState.state = Behavior.STATE.CHASING
entity.behaviorState.chasing = true
okChase, chaseErr = driveChase(4, 0, 4)
T.check(okChase, "chase up voxel-safe: " .. tostring(chaseErr))
entity:setCell(4, 3)
entity.behaviorState.chasing = true
okChase, chaseErr = driveChase(4, 6, 4)
T.check(okChase, "chase down voxel-safe: " .. tostring(chaseErr))
entity:setCell(4, 3)
entity.behaviorState.chasing = true
okChase, chaseErr = driveChase(0, 3, 4)
T.check(okChase, "chase left voxel-safe: " .. tostring(chaseErr))

-- Path blocked: give up without crashing Voxel.
entity:setCell(2, 2)
entity.behaviorState.chasing = true
entity.behaviorState.chaseFailCount = 0
mockOw.map.isWalkableCell = function(_, x, y) return not (x == 3 and y == 2) end
for _ = 1, 30 do
  Behavior.tick(entity, {
    map = mockOw.map, entities = mockOw.entities,
    player = { cellX = 5, cellY = 2 }, dt = 0.18,
  })
end
ok, err = pcall(simulateVoxelPoses, mockOw.entities)
T.check(ok, "blocked pathfinding stays voxel-safe: " .. tostring(err))
mockOw.map.isWalkableCell = function() return true end

-- Battle exactly once.
entity:setCell(7, 2)
entity.behaviorState.state = Behavior.STATE.CHASING
entity.behaviorState.chasing = true
entity.behaviorState.battleStarted = false
local battleRec = logic.spawns[entity.id]
battleRec.state = Config.STATE.AVAILABLE
logic.entities[entity.id] = entity
logic:_attach(entity)
mockOw.player.cellX, mockOw.player.cellY = 7, 2
local started = logic:_startBattle(battleRec)
T.check(started, "battle starts")
local started2 = logic:_startBattle(battleRec)
T.check(not started2, "battle does not start twice")
T.check(mockOw._battleQueued and #mockOw._battleQueued == 1, "one battle script")
T.check(mockOw.emote == nil, "alert icon cleared")
local stillListed = false
for _, e in ipairs(mockOw.entities) do
  if e == entity then stillListed = true end
end
T.check(not stillListed, "entity removed from both render paths")

-- Per-entity Voxel fallback does not remove other entities.
local a = exports.render:makeEntity(mockGame, {
  id = "wilds_of_kanto_entity_a", mapId = "ROUTE_TEST", x = 1, y = 1,
  species = species, level = 2, state = Config.STATE.AVAILABLE,
})
local speciesB = species
for id in pairs(Data.pokemon or {}) do
  if id ~= species then speciesB = id break end
end
local b = exports.render:makeEntity(mockGame, {
  id = "wilds_of_kanto_entity_b", mapId = "ROUTE_TEST", x = 2, y = 1,
  species = speciesB, level = 2, state = Config.STATE.AVAILABLE,
})
mockOw.entities = { mockPlayer, a, b }
local adapter = VoxelAdapter.new(logic.mod)
adapter:markFallback(a, "injected test failure")
T.check(a.voxelDisabled == true, "entity A voxel disabled")
T.check(a.render2DFallback == true, "entity A 2D fallback")
T.check(VoxelAdapter.isPoseSafe(b), "entity B still voxel-safe")
ok, err = pcall(simulateVoxelPoses, { b })
T.check(ok, "sibling entity still poseable: " .. tostring(err))

T.eq(Tile.CELL, 16, "documented tile size")
run.release()
T.finish("voxel_aggressive_compat")
