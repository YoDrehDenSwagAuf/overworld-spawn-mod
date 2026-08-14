-- Occupancy dirty flag + rebuild skip contract for BehaviorTick.
-- Run: lua tests/occupancy_dirty_unit_test.lua
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

local modules = {}
local V = {
  mod = { path = ".", log = { info = function() end }, find = function() return nil end },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  -- Minimal stubs for spawn_logic dependencies are heavy; test CellOccupancy
  -- + a thin dirty-flag helper mirroring SpawnLogic.
  if name == "cell_occupancy" then
    local chunk = assert(loadfile("lib/cell_occupancy.lua"))
    local value = chunk(V)
    modules[name] = value
    return value
  end
  local path = "lib/" .. name .. ".lua"
  local f = io.open(path, "r")
  if f then
    f:close()
    local chunk = assert(loadfile(path))
    local value = chunk(V)
    modules[name] = value
    return value
  end
  error("missing module " .. name)
end

local CellOccupancy = V.require("cell_occupancy")

-- Mirror SpawnLogic dirty API for isolated contract tests.
local logic = {
  occupancy = CellOccupancy.new(),
  entities = {},
  _occupancyDirty = true,
}
function logic:markOccupancyDirty()
  self._occupancyDirty = true
end
function logic:rebuildOccupancy(ow)
  local occupancy = self.occupancy or CellOccupancy.new()
  self.occupancy = occupancy
  occupancy:rebuild({
    player = ow and ow.player,
    entities = ow and ow.entities,
    npcs = ow and ow.npcs,
    logicEntities = self.entities,
    trailers = ow and ow.pokepcTrailers,
  })
  self._occupancyDirty = false
  return occupancy
end

local player = { cellX = 1, cellY = 1 }
local ow = { player = player, entities = {}, pokepcTrailers = {}, npcs = {} }

check(logic._occupancyDirty == true, "starts dirty")
logic:rebuildOccupancy(ow)
check(logic._occupancyDirty == false, "rebuild clears dirty")
check(logic.occupancy:isOccupied(1, 1) == true, "player occupied after rebuild")

-- Spawn reserve/commit updates occupancy without full rebuild
local wild = { id = "wild1", cellX = 3, cellY = 3, overworldWildSpawn = true }
local token = logic.occupancy:reserveSpawn(nil, 3, 3)
check(token ~= nil, "spawn reserve")
logic.occupancy:commitSpawn(token, wild)
logic.entities.wild1 = wild
check(logic.occupancy:isOccupied(3, 3) == true, "spawn commit occupies")

-- Begin move reserves; finish commits; cancel clears
local ok = logic.occupancy:reserveMove(wild, 3, 3, 4, 3)
check(ok == true, "begin move reserves")
check(logic.occupancy:isReserved(4, 3) == true, "target reserved")
logic.occupancy:commitMove(wild)
check(logic.occupancy:isOccupied(4, 3) == true, "commit moves occupancy")
check(logic.occupancy:isOccupied(3, 3) == false, "old cell freed")

wild.cellX, wild.cellY = 4, 3
ok = logic.occupancy:reserveMove(wild, 4, 3, 5, 3)
check(ok == true, "second move reserve")
logic.occupancy:cancelMove(wild)
check(logic.occupancy:isReserved(5, 3) == false, "cancel clears reservation")
check(logic.occupancy:isOccupied(4, 3) == true, "cancel keeps current cell")

-- Despawn release
logic.occupancy:releaseEntity(wild)
logic.entities.wild1 = nil
check(logic.occupancy:isOccupied(4, 3) == false, "despawn clears cell")

-- Map change / reseed: dirty + rebuild
logic:markOccupancyDirty()
check(logic._occupancyDirty == true, "map change marks dirty")
player.cellX, player.cellY = 9, 9
logic:rebuildOccupancy(ow)
check(logic.occupancy:isOccupied(9, 9) == true, "rebuild after teleport")
check(logic._occupancyDirty == false, "rebuild clears after teleport")

-- Teleport/reseed must not leave stale wild cells when list emptied
local stale = { id = "stale", cellX = 2, cellY = 2, overworldWildSpawn = true }
logic.occupancy:_setOccupied(2, 2, "stale", "wild", stale)
logic:markOccupancyDirty()
logic.entities = {}
logic:rebuildOccupancy(ow)
check(logic.occupancy:isOccupied(2, 2) == false, "full rebuild drops stale wild")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("ALL PASS")
