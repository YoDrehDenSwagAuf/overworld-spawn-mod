-- Cell occupancy + atomic spawn/move reservation unit tests.
-- Run: lua tests/cell_occupancy_unit_test.lua
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
  mod = { path = ".", log = { info = function() end }, find = function() return nil end },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

local CellOccupancy = V.require("cell_occupancy")

------------------------------------------------------------------------
-- Spawn reservations
------------------------------------------------------------------------
local occ = CellOccupancy.new()
local t1, err1 = occ:reserveSpawn(nil, 3, 4)
check(t1 ~= nil, "first spawn reserve ok")
local t2, err2 = occ:reserveSpawn(nil, 3, 4)
check(t2 == nil, "second spawn on same cell rejected")
check(err2 == "occupied_or_reserved", "reject reason occupied_or_reserved")

local entA = { id = "wilds_of_kanto_entity_1", cellX = 3, cellY = 4, overworldWildSpawn = true }
check(occ:commitSpawn(t1, entA) == true, "commit spawn transfers to entity")
check(occ:isOccupied(3, 4) == true, "cell occupied after commit")
check(select(1, occ:reserveSpawn(nil, 3, 4)) == nil, "cannot respawn on committed cell")

local t3 = occ:reserveSpawn(nil, 5, 5)
check(t3 ~= nil, "reserve free spawn cell")
occ:releaseSpawn(t3)
check(occ:isOccupied(5, 5) == false, "failed/released spawn frees cell")
check(occ:isReserved(5, 5) == false, "released spawn not reserved")

------------------------------------------------------------------------
-- Rebuild from player / NPC / follower / wild
------------------------------------------------------------------------
occ:clear()
local player = { cellX = 1, cellY = 1 }
local npc = { id = "npc1", cellX = 2, cellY = 2, passable = false }
local follower = {
  id = "f1", cellX = 6, cellY = 6, passable = true, pokepcTrailer = true,
}
local wild = {
  id = "wilds_of_kanto_entity_2", cellX = 7, cellY = 7,
  overworldWildSpawn = true, targetX = 8, targetY = 7,
}
occ:rebuild({
  player = player,
  entities = { npc, follower, wild },
})
check(occ:isOccupied(1, 1) == true, "player cell occupied")
check(occ:isOccupied(2, 2) == true, "npc cell occupied")
check(occ:isOccupied(6, 6) == true, "follower cell occupied")
check(occ:isOccupied(7, 7) == true, "wild cell occupied")
check(occ:isReserved(8, 7) == true, "wild target reserved")
check(select(1, occ:reserveSpawn(nil, 1, 1)) == nil, "player cell spawn rejected")
check(select(1, occ:reserveSpawn(nil, 2, 2)) == nil, "trainer/npc spawn rejected")
check(select(1, occ:reserveSpawn(nil, 6, 6)) == nil, "follower spawn rejected")

------------------------------------------------------------------------
-- Movement reservations + swap block
------------------------------------------------------------------------
occ:clear()
local a = { id = "A", cellX = 0, cellY = 0, overworldWildSpawn = true }
local b = { id = "B", cellX = 1, cellY = 0, overworldWildSpawn = true }
occ:rebuild({ entities = { a, b } })

check(occ:reserveMove(a, 0, 0, 1, 0) == false, "A cannot reserve B's current cell")
-- Reset and test two entities targeting same free cell.
occ:clear()
a = { id = "A", cellX = 0, cellY = 0, overworldWildSpawn = true }
b = { id = "B", cellX = 2, cellY = 0, overworldWildSpawn = true }
occ:rebuild({ entities = { a, b } })
check(occ:reserveMove(a, 0, 0, 1, 0) == true, "A reserves shared target")
local okB, whyB = occ:reserveMove(b, 2, 0, 1, 0)
check(okB == false, "B denied same target")
check(whyB == "reserved" or whyB == "occupied", "B deny reason reserved/occupied")

-- Swap block: A at (0,0)->(1,0), B at (1,0)->(0,0)
occ:clear()
a = { id = "A", cellX = 0, cellY = 0, overworldWildSpawn = true }
b = { id = "B", cellX = 1, cellY = 0, overworldWildSpawn = true }
occ:rebuild({ entities = { a, b } })
-- A cannot enter B's cell while B stands there.
check(occ:canReserve(a, 0, 0, 1, 0) == false, "cannot enter occupied cell")
-- Simulate both leaving: clear occupancy of destinations by only tracking moves
-- after temporarily releasing? Real engine keeps origin occupied during step.
-- With origin occupied, swap is blocked by isOccupied on destination.
local okSwap, whySwap = occ:reserveMove(a, 0, 0, 1, 0)
check(okSwap == false, "swap step A→B cell blocked while B present")

-- Explicit swap_blocked when reverse reservation exists without destination occ.
occ:clear()
a = { id = "A", cellX = 0, cellY = 0, overworldWildSpawn = true }
b = { id = "B", cellX = 1, cellY = 0, overworldWildSpawn = true }
occ:_setOccupied(0, 0, "A", "entity", a)
occ:_setOccupied(1, 0, "B", "entity", b)
-- Manually place a move reservation as if B already reserved A's cell, and
-- vacate B's occupancy for the canReserve destination check of the reverse:
occ.occupied["1:0"] = nil
occ.entityCells["B"] = nil
occ.moveReservations["0:0"] = {
  entity = b, owner = "B", fromX = 1, fromY = 0, toX = 0, toY = 0,
}
occ.entityMoves["B"] = "0:0"
local okRev, whyRev = occ:canReserve(a, 0, 0, 1, 0)
check(okRev == false, "reverse swap blocked")
eq(whyRev, "swap_blocked", "swap_blocked reason")

------------------------------------------------------------------------
-- Commit / cancel / release
------------------------------------------------------------------------
occ:clear()
a = { id = "A", cellX = 4, cellY = 4, overworldWildSpawn = true }
occ:rebuild({ entities = { a } })
check(occ:reserveMove(a, 4, 4, 5, 4) == true, "reserve move")
check(occ:isReserved(5, 4) == true, "target reserved during step")
check(occ:isOccupied(4, 4) == true, "origin stays occupied during step")
a.cellX, a.cellY = 5, 4
a.targetX, a.targetY = nil, nil
check(occ:commitMove(a) == true, "commit move")
check(occ:isOccupied(5, 4) == true, "new cell occupied")
check(occ:isReserved(5, 4) == false, "target reservation cleared")
check(occ:isOccupied(4, 4) == false, "old cell freed")

check(occ:reserveMove(a, 5, 4, 6, 4) == true, "reserve again")
occ:cancelMove(a)
check(occ:isReserved(6, 4) == false, "cancel clears target")
check(occ:isOccupied(5, 4) == true, "cancel keeps origin")

-- Idempotent re-reserve of the same target by the same entity.
check(occ:reserveMove(a, 5, 4, 6, 4) == true, "reserve target once")
local okIdem, whyIdem = occ:reserveMove(a, 5, 4, 6, 4, { kind = "land_to_water_chase" })
check(okIdem == true, "idempotent reserveMove succeeds")
check(whyIdem == "already_held" or whyIdem == nil, "idempotent reason already_held")
check(occ:isReserved(6, 4, a) == false, "own reservation ignored for owner")
local _, _, slot = occ:ownerAt(6, 4)
check(slot and slot.kind == "land_to_water_chase", "reservation kind stored")
eq(CellOccupancy.ownerKey(a), "A", "ownerKey uses entity id")

occ:releaseEntity(a)
check(occ:isOccupied(5, 4) == false, "releaseEntity frees cell")

------------------------------------------------------------------------
-- Non-blocking entities
------------------------------------------------------------------------
occ:clear()
local fx = { id = "fx", cellX = 9, cellY = 9, passable = true, alertIcon = true }
local overlay = { id = "ov", cellX = 9, cellY = 9, overworldWildOverlay = true, passable = true }
occ:rebuild({ entities = { fx, overlay } })
check(occ:isOccupied(9, 9) == false, "emote/overlay do not occupy")

------------------------------------------------------------------------
-- Land + water share same service
------------------------------------------------------------------------
occ:clear()
local landTok = occ:reserveSpawn("land_tok", 10, 10)
local waterTok = occ:reserveSpawn("water_tok", 11, 11)
check(landTok ~= nil and waterTok ~= nil, "land and water spawn tokens")
check(occ:isReserved(10, 10) == true, "land spawn reserved")
check(occ:isReserved(11, 11) == true, "water spawn reserved")
check(select(1, occ:reserveSpawn(nil, 10, 10)) == nil, "land cell blocked for second")
check(select(1, occ:reserveSpawn(nil, 11, 11)) == nil, "water cell blocked for second")

------------------------------------------------------------------------
-- Follower marker helpers
------------------------------------------------------------------------
check(CellOccupancy.isFollowerEntity({ pokepcTrailer = true }) == true, "pokepcTrailer marker")
check(CellOccupancy.isFollowerEntity({ pikachuFollower = true }) == true, "pikachuFollower marker")
check(CellOccupancy.isFollowerEntity({
  sprite = { def = { id = "SPRITE_POKEPC_MON" } },
}) == true, "sprite id marker")
check(CellOccupancy.isBlockingEntity({
  overworldWildSpawn = true, passable = true,
}) == true, "wild blocks even if passable")
check(CellOccupancy.isBlockingEntity({
  passable = true, alertIcon = true,
}) == false, "alert icon not blocking")

local counts = occ:counts()
check(type(counts.occupied) == "number", "counts.occupied")
check(type(counts.swapBlocks) == "number", "counts.swapBlocks")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll cell_occupancy tests passed.")
