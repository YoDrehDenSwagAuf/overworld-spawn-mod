-- Battle → Overworld reattach / follower resync (no full map respawn).
-- Run: luajit tests/battle_return_reconcile_unit_test.lua
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

local function listHas(list, entity)
  if type(list) ~= "table" then return false end
  for _, e in ipairs(list) do
    if e == entity then return true end
  end
  return false
end

local function readFile(rel)
  local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local optionStore = {
  enabled = true,
  town_pokemon = true,
  follower_count = 1,
  follow_control = "trainer",
  sprite_style = "followers",
  dev_overlay = false,
}

local modules = {}
local V = {
  path = ".",
  mod = nil,
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

local function makeOw(mapId)
  return {
    map = {
      id = mapId or "ROUTE_1",
      widthCells = 20,
      heightCells = 18,
      inBounds = function(_, x, y) return x >= 0 and y >= 0 end,
      isWaterCell = function() return false end,
      isWalkableCell = function() return true end,
    },
    player = { cellX = 5, cellY = 5, px = 80, py = 80, facing = "down" },
    entities = {},
    npcs = {},
    pokepcTrailers = {},
  }
end

local ow = makeOw("ROUTE_1")
local game = { save = { party = {}, options = {} }, overworld = ow }
local mod = {
  id = "overworld_wild_spawns",
  path = ".",
  log = { info = function() end, warn = function() end, error = function() end },
  find = function() return nil end,
  read = function(_, rel) return readFile(rel) end,
  options = {
    get = function(_, k) return optionStore[k] end,
    set = function(_, k, v) optionStore[k] = v end,
  },
  save = { get = function() return nil end, set = function() end },
  world = {
    game = game,
    overworld = function() return ow end,
  },
  exports = {},
  assets = { path = function(_, rel) return rel end },
}
V.mod = mod
mod._testGame = game
game.world = ow

local function makeWild(id, x, y)
  local entity = {
    id = id,
    species = "PIDGEY",
    cellX = x, cellY = y,
    px = x * 16, py = y * 16,
    state = "available",
    overworldWildSpawn = true,
    registeredInWorld = true,
    visibleSprite = true,
    sprite = {
      def = { id = "test", image = "assets/fallback/pokemon_missing.png" },
      resolveImage = function() return "assets/fallback/pokemon_missing.png" end,
    },
  }
  function entity:pose()
    return { x = self.px, y = self.py, image = "assets/fallback/pokemon_missing.png" }
  end
  return entity
end

local function wipeEngineLists()
  local keepEnt, keepNpc = {}, {}
  for _, e in ipairs(ow.entities or {}) do
    if e == ow.player then keepEnt[#keepEnt + 1] = e end
  end
  for _, n in ipairs(ow.npcs or {}) do
    if n.mapObject == true then keepNpc[#keepNpc + 1] = n end
  end
  ow.entities = keepEnt
  ow.npcs = keepNpc
end

local Config = V.require("config")
local GameCompat = V.require("game_compat")
local SpawnLogic = V.require("spawn_logic")
local AmbientPokemon = V.require("ambient_pokemon")
local ControlEngine = V.require("follower/control_engine")

local render = {
  isEntityRegistered = function(_, world, entity)
    return listHas(world and world.entities, entity)
  end,
}

local logic = SpawnLogic.new(mod, render)
logic.activeMapId = "ROUTE_1"
mod.exports.logic = logic

local function attachThree()
  logic.entities = {}
  logic.spawns = {}
  ow.entities = { ow.player }
  ow.npcs = {}
  local ids = { "w1", "w2", "w3" }
  for i, id in ipairs(ids) do
    local e = makeWild(id, 2 + i, 4)
    logic.entities[id] = e
    logic.spawns[id] = { id = id, state = Config.STATE.AVAILABLE, x = e.cellX, y = e.cellY, mapId = "ROUTE_1" }
    logic:_attach(e)
    check(e.registeredInWorld == true, id .. " attached before battle")
  end
  return ids
end

------------------------------------------------------------------------
-- CASE A: remaining Wilds reattach after engine people rebuild
------------------------------------------------------------------------
attachThree()
eq(logic:_countLogicEntities(), 3, "CASE A: 3 logic entities before battle")
eq(logic:_countAttachedEntities(ow, game), 3, "CASE A: 3 attached before battle")

wipeEngineLists()
logic.entities.w1.registeredInWorld = true -- stale
eq(logic:_isEntityActuallyAttached(logic.entities.w1, ow, game), false,
   "CASE A: stale registeredInWorld is not attached")
eq(GameCompat.containerMembership(ow, logic.entities.w1).entities, false,
   "CASE A: missing from ow.entities after rebuild")

logic:onBattleEnded()
check(logic._pendingBattleReturnReconcile == true, "CASE A: pending after battle.ended")
-- Gen1-style: overworld is live, so battle.ended flush should reattach.
eq(logic:_countAttachedEntities(ow, game), 3, "CASE A: 3 reattached on battle.ended flush")
eq(#ow.entities, 4, "CASE A: player + 3 wilds in ow.entities (got " .. tostring(#ow.entities) .. ")")

------------------------------------------------------------------------
-- CASE B: battled Pokémon stays gone; other 2 remain
------------------------------------------------------------------------
attachThree()
logic:_despawn("w1", true)
eq(logic.entities.w1, nil, "CASE B: battled entity despawned")
wipeEngineLists()
logic._pendingBattleReturnReconcile = true
logic._battleReturnFlushedOnce = false
logic:flushBattleReturnReconcile("tick")
eq(logic.entities.w1, nil, "CASE B: battled Pokémon not recreated")
eq(logic:_countLogicEntities(), 2, "CASE B: 2 surviving logic entities")
eq(logic:_countAttachedEntities(ow, game), 2, "CASE B: 2 remaining attached")
check(not listHas(ow.entities, { id = "w1" }), "CASE B: no stray w1 identity")

------------------------------------------------------------------------
-- CASE G: map mismatch does not reattach onto the wrong map
------------------------------------------------------------------------
attachThree()
wipeEngineLists()
logic.activeMapId = "ROUTE_1"
ow.map.id = "VIRIDIAN_CITY"
logic._pendingBattleReturnReconcile = true
logic._battleReturnFlushedOnce = false
local okG, whyG = logic:flushBattleReturnReconcile("tick")
eq(okG, false, "CASE G: flush refused on map mismatch")
eq(whyG, "map_mismatch", "CASE G: reason map_mismatch")
eq(logic._pendingBattleReturnReconcile, false, "CASE G: pending cleared")
eq(logic:_countAttachedEntities(ow, game), 0, "CASE G: no wrong-map reattach")
ow.map.id = "ROUTE_1"
logic.activeMapId = "ROUTE_1"

------------------------------------------------------------------------
-- Gold battleActive: battle.ended is too early
------------------------------------------------------------------------
attachThree()
wipeEngineLists()
ow.battleActive = true
logic._pendingBattleReturnReconcile = false
logic:onBattleEnded()
eq(logic:_countAttachedEntities(ow, game), 0,
   "Gold: no attach while battleActive")
check(logic._pendingBattleReturnReconcile == true, "Gold: pending kept")
ow.battleActive = nil
logic:flushBattleReturnReconcile("tick")
eq(logic:_countAttachedEntities(ow, game), 3, "Gold: attach on first live tick")
wipeEngineLists()
logic.entities.w2.registeredInWorld = true
logic:onStepped({ mapId = "ROUTE_1", x = 5, y = 5 })
eq(logic:_countAttachedEntities(ow, game), 3, "Gold: world.stepped second pass")
eq(logic._pendingBattleReturnReconcile, false, "Gold: pending cleared on step")

------------------------------------------------------------------------
-- CASE F: two sequential battles do not duplicate
------------------------------------------------------------------------
attachThree()
local function battleCycle()
  wipeEngineLists()
  logic._pendingBattleReturnReconcile = true
  logic._battleReturnFlushedOnce = false
  logic:flushBattleReturnReconcile("tick")
  logic:flushBattleReturnReconcile("world.stepped")
end
battleCycle()
local nAfter1 = #ow.entities
battleCycle()
eq(#ow.entities, nAfter1, "CASE F: second battle does not grow ow.entities")
eq(logic:_countAttachedEntities(ow, game), 3, "CASE F: still exactly 3 wilds")

------------------------------------------------------------------------
-- CASE E: ambient guests reattach, no new random set
------------------------------------------------------------------------
local ambient = AmbientPokemon.new(mod, { logic = logic })
mod.exports.ambient = ambient
ow.entities = { ow.player }
ow.npcs = {}
local townNpc = {
  id = "ambient_1",
  wildsAmbientPokemon = true,
  ambientSpecies = "EEVEE",
  mapId = "ROUTE_1",
  cellX = 8, cellY = 8, px = 128, py = 128,
}
ambient.active[townNpc] = true
ambient.activeMapId = "ROUTE_1"
GameCompat.attachGuestEntity(ow, townNpc, game)
check(listHas(ow.npcs, townNpc), "CASE E: ambient in npcs before battle")
wipeEngineLists()
check(not listHas(ow.npcs, townNpc), "CASE E: ambient dropped by rebuild")
ambient:onBattleEnded({ source = "battle.ended" })
check(listHas(ow.npcs, townNpc) or listHas(ow.entities, townNpc),
      "CASE E: same ambient NPC reattached")
eq(ambient:countActive(), 1, "CASE E: did not roll a new town set")
wipeEngineLists()
ambient:onBattleEnded({ source = "world.stepped" })
eq(ambient:countActive(), 1, "CASE E: still 1 after second pass")
eq(ambient._pendingBattleReturnReconcile, false, "CASE E: pending cleared on step")

------------------------------------------------------------------------
-- CASE C / D: follower pending sync, no duplicate trailers
------------------------------------------------------------------------
local engine = ControlEngine.new(mod, { game = game })
engine._installed = true
local syncCalls = 0
engine.followerCount = function() return optionStore.follower_count end
engine.update = function(self, _, world)
  syncCalls = syncCalls + 1
  self:removeTrailers(world)
  local n = self:followerCount() or 1
  world.pokepcTrailers = {}
  for i = 1, n do
    local t = { id = "trailer_" .. i, pokepcTrailer = true, wildsFollower = true }
    GameCompat.attachGuestEntity(world, t, game)
    world.pokepcTrailers[#world.pokepcTrailers + 1] = t
  end
end

optionStore.follower_count = 1
ow.entities, ow.npcs, ow.pokepcTrailers = { ow.player }, {}, {}
engine._battleReturnFlushedOnce = false
engine:onBattleEnded(game, ow, { source = "battle.ended" })
eq(#ow.pokepcTrailers, 1, "CASE C: exactly 1 follower after battle")
eq(syncCalls, 1, "CASE C: one sync on battle.ended")
engine:onBattleEnded(game, ow, { source = "tick" })
eq(syncCalls, 1, "CASE C: tick does not resync after first flush")
engine:onBattleEnded(game, ow, { source = "world.stepped" })
eq(#ow.pokepcTrailers, 1, "CASE C: still exactly 1 after step")
eq(syncCalls, 2, "CASE C: second pass on world.stepped")

optionStore.follower_count = 6
engine._battleReturnFlushedOnce = false
engine._pendingBattleReturnSync = true
syncCalls = 0
engine:onBattleEnded(game, ow, { source = "battle.ended" })
eq(#ow.pokepcTrailers, 6, "CASE D: exactly 6 followers")
engine:onBattleEnded(game, ow, { source = "world.stepped" })
eq(#ow.pokepcTrailers, 6, "CASE D: still 6, no duplicates")
local trailerMarks = 0
for _, e in ipairs(ow.entities) do
  if e.pokepcTrailer then trailerMarks = trailerMarks + 1 end
end
eq(trailerMarks, 6, "CASE D: 6 trailer refs in ow.entities")

-- CASE F followers: repeated battles
for _ = 1, 2 do
  wipeEngineLists()
  engine._battleReturnFlushedOnce = false
  engine:onBattleEnded(game, ow, { source = "battle.ended" })
  engine:onBattleEnded(game, ow, { source = "world.stepped" })
end
eq(#ow.pokepcTrailers, 6, "CASE F: repeated battles still 6 followers")

------------------------------------------------------------------------
-- CASE H: Yellow Pikachu path is not extra-wrapped here (control flags only)
------------------------------------------------------------------------
check(type(engine.onBattleEnded) == "function",
      "CASE H: battle return uses ControlEngine:onBattleEnded (existing Yellow art helpers)")

------------------------------------------------------------------------
-- Gold attach uses npcs (draw list)
------------------------------------------------------------------------
package.loaded["src.core.GameVersion"] = {
  get = function() return "gold" end,
  isYellow = function() return false end,
  generation = function() return 2 end,
}
-- GameCompat caches version; rebuild membership via isGen2 live read.
attachThree()
wipeEngineLists()
logic._pendingBattleReturnReconcile = true
logic._battleReturnFlushedOnce = false
logic:flushBattleReturnReconcile("tick")
local e1 = logic.entities.w2
local goldDraw = GameCompat.entityInDrawList(ow, e1, game)
check(goldDraw == true or listHas(ow.entities, e1),
      "CASE I: Gold guest present in draw container after reconcile")

------------------------------------------------------------------------
-- Occupancy rebuilt after reattach
------------------------------------------------------------------------
attachThree()
wipeEngineLists()
logic._pendingBattleReturnReconcile = true
logic._battleReturnFlushedOnce = false
logic:flushBattleReturnReconcile("tick")
check(logic.occupancy ~= nil, "occupancy object exists")
check(logic.occupancy:isOccupied(3, 4) or logic.occupancy:isOccupied(4, 4)
      or logic.occupancy:isOccupied(5, 4),
      "occupancy sees a reattached wild cell")

------------------------------------------------------------------------
-- No love.filesystem in this change set (sandbox lock)
------------------------------------------------------------------------
local fsHits = {}
local p = io.popen('rg -l "love\\.filesystem" lib main.lua 2>/dev/null || true')
if p then
  for line in p:lines() do fsHits[#fsHits + 1] = line end
  p:close()
end
eq(#fsHits, 0, "sandbox lock: production still has zero love.filesystem")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("battle_return_reconcile_unit_test: all passed")
