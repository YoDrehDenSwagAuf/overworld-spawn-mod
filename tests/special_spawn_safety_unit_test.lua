-- Special spawn safety: reserved story trigger cells (Pokémon Tower Marowak).
-- Run: lua tests/special_spawn_safety_unit_test.lua
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
  mod = { id = "overworld_wild_spawns", path = ".", log = { info = function() end } },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

local SpecialSpawnSafety = V.require("special_spawn_safety")
local Grass = V.require("grass")

local MAP = "POKEMON_TOWER_6F"
local TX, TY = 10, 16

----------------------------------------------------------------
-- 1. Active Marowak trigger rejects spawn cell
----------------------------------------------------------------
do
  local game = { save = { flags = {} } }
  check(SpecialSpawnSafety.isReserved(game, MAP, TX, TY) == true,
        "1: Tower 6F (10,16) reserved while EVENT unset")
end

----------------------------------------------------------------
-- 2. After EVENT_BEAT_GHOST_MAROWAK, tile is free
----------------------------------------------------------------
do
  local game = { save = { flags = { EVENT_BEAT_GHOST_MAROWAK = true } } }
  check(SpecialSpawnSafety.isReserved(game, MAP, TX, TY) == false,
        "2: no longer reserved after Marowak beaten")
end

----------------------------------------------------------------
-- 3. Adjacent cell unaffected
----------------------------------------------------------------
do
  local game = { save = { flags = {} } }
  check(SpecialSpawnSafety.isReserved(game, MAP, TX, TY - 1) == false,
        "3: adjacent (10,15) not reserved")
  check(SpecialSpawnSafety.isReserved(game, MAP, TX + 1, TY) == false,
        "3: adjacent (11,16) not reserved")
end

----------------------------------------------------------------
-- 4. Same coordinates on another map unaffected
----------------------------------------------------------------
do
  local game = { save = { flags = {} } }
  check(SpecialSpawnSafety.isReserved(game, "ROUTE_1", TX, TY) == false,
        "4: other map (10,16) not reserved")
  check(SpecialSpawnSafety.isReserved(game, "POKEMON_TOWER_5F", TX, TY) == false,
        "4: Tower 5F (10,16) not reserved")
end

----------------------------------------------------------------
-- 5. Existing entity purge helper (map-init path)
----------------------------------------------------------------
do
  local game = { save = { flags = {} } }
  local removed = {}
  local entities = {
    bad = {
      overworldWildSpawn = true,
      cellX = TX, cellY = TY,
      mapId = MAP,
    },
    ok = {
      overworldWildSpawn = true,
      cellX = TX + 1, cellY = TY,
      mapId = MAP,
    },
  }
  local logic = {
    entities = entities,
    activeMapId = MAP,
  }
  function logic:_despawn(id)
    removed[id] = true
    self.entities[id] = nil
  end
  function logic:purgeStoryReservedEntities(g, mapId)
    local cells = SpecialSpawnSafety.activeCells(g, mapId or self.activeMapId)
    if #cells == 0 then return 0 end
    local n = 0
    for id, entity in pairs(self.entities or {}) do
      if entity and entity.overworldWildSpawn then
        local ex, ey = entity.cellX, entity.cellY
        for i = 1, #cells do
          if cells[i].x == ex and cells[i].y == ey then
            self:_despawn(id, true)
            n = n + 1
            break
          end
        end
      end
    end
    return n
  end
  local n = logic:purgeStoryReservedEntities(game, MAP)
  eq(n, 1, "5: purged one reserved-cell entity")
  check(removed.bad == true, "5: reserved entity despawned")
  check(logic.entities.ok ~= nil, "5: adjacent Wilds entity kept")
end

----------------------------------------------------------------
-- 6. Hidden spawn candidate also blocked via Grass.pickFree isBlocked
----------------------------------------------------------------
do
  local game = { save = { flags = {} } }
  local map = {
    widthCells = 20, heightCells = 20,
    isGrassCell = function(_, x, y) return true end,
    isWalkableCell = function() return true end,
    warpAtCell = function() return nil end,
  }
  local player = { cellX = 0, cellY = 0 }
  local tiles = {
    { x = TX, y = TY },
    { x = TX + 2, y = TY },
  }
  local rejected = {}
  local x, y, reason = Grass.pickFree(
    map, {}, player, 0, function() return 1 end, tiles, 99,
    function(r) rejected[#rejected + 1] = r end,
    {
      mode = "walkable",
      isBlocked = function(cx, cy)
        return SpecialSpawnSafety.isReserved(game, MAP, cx, cy)
      end,
    })
  eq(x, TX + 2, "6: pickFree skips reserved cell")
  eq(y, TY, "6: picked adjacent eligible tile")
  check(reason == nil, "6: pick succeeded")
  local sawReserved = false
  for _, r in ipairs(rejected) do
    if r == "rejected: story trigger reserved" then sawReserved = true end
  end
  check(sawReserved, "6: reserved rejection noted (hidden/land share path)")
end

----------------------------------------------------------------
-- 7. Regular Tower spawns elsewhere continue (activeCells only trigger)
----------------------------------------------------------------
do
  local game = { save = { flags = {} } }
  local cells = SpecialSpawnSafety.activeCells(game, MAP)
  eq(#cells, 1, "7: only one reserved cell on Tower 6F")
  eq(cells[1].x, TX, "7: reserved x")
  eq(cells[1].y, TY, "7: reserved y")
  check(SpecialSpawnSafety.isReserved(game, MAP, 5, 5) == false,
        "7: ordinary Tower tile not reserved")
  -- After clear, activeCells empty
  game.save.flags.EVENT_BEAT_GHOST_MAROWAK = true
  eq(#SpecialSpawnSafety.activeCells(game, MAP), 0,
     "7: no active reserved cells after event")
end

----------------------------------------------------------------
-- Proven entry documentation
----------------------------------------------------------------
do
  local entry = SpecialSpawnSafety._RESERVED[1]
  check(entry ~= nil, "reserved table has Tower entry")
  eq(entry.mapId, MAP, "documented map id")
  eq(entry.flagUnset, "EVENT_BEAT_GHOST_MAROWAK", "documented event flag")
  check(type(entry.reason) == "string" and #entry.reason > 0,
        "reason documents why tile is reserved")
end

print("")
if failures > 0 then
  io.stderr:write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
print("all special_spawn_safety tests passed")
