-- Forward targeting + catchable filters for overworld catching.
-- Run: lua tests/overworld_catch_target_unit_test.lua
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
  mod = { id = "overworld_wild_spawns", path = ".", log = { info = function() end, warn = function() end } },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end
modules.debug_log = { warn = function() end, info = function() end }
modules.tile = { CELL = 16 }

local Config = V.require("config")
modules.config = Config
local Target = V.require("catching/target")

local function makeWild(opts)
  opts = opts or {}
  return {
    id = opts.id or "wilds_of_kanto_entity_1",
    cellX = opts.x or 10,
    cellY = opts.y or 10,
    overworldWildSpawn = opts.overworldWildSpawn ~= false and true or opts.overworldWildSpawn,
    wildsAmbientPokemon = opts.ambient == true,
    caveScenery = opts.caveScenery == true,
    wildsFollower = opts.follower == true,
    pokepcTrailer = opts.trailer == true,
    hiddenEncounter = opts.hidden == true,
    visibleSprite = opts.visibleSprite,
    canTriggerBattle = opts.canTriggerBattle,
    wildsCatchLocked = opts.locked == true,
    state = opts.state or "available",
    species = opts.species or "PIDGEY",
    facing = opts.facing or "down",
  }
end

-- Battleable wild
check(Target.isCatchableWild(makeWild()), "normal wild catchable")
check(not Target.isCatchableWild(makeWild({ ambient = true, overworldWildSpawn = false })), "town ambient not catchable")
check(not Target.isCatchableWild(makeWild({ caveScenery = true, canTriggerBattle = false })), "cave scenery not catchable")
check(not Target.isCatchableWild(makeWild({ follower = true, overworldWildSpawn = false })), "follower not catchable")
check(not Target.isCatchableWild(makeWild({ trailer = true, overworldWildSpawn = false })), "trailer not catchable")
check(not Target.isCatchableWild(makeWild({ hidden = true, visibleSprite = false })), "hidden marker not catchable")
check(not Target.isCatchableWild(makeWild({ locked = true })), "catch-locked not catchable")
check(not Target.isCatchableWild(makeWild({ state = "REMOVED" })), "removed not catchable")

local player = { cellX = 5, cellY = 5, facing = "right" }
local logic = { entities = {} }
local ow = { entities = {}, player = player }

local function place(ent)
  logic.entities[ent.id] = ent
end

-- 1 tile ahead
place(makeWild({ id = "a", x = 6, y = 5 }))
local e, dist = Target.findAhead(logic, ow, player, 6)
eq(dist, 1, "1 tile ahead → target dist 1")
check(e and e.id == "a", "1 tile ahead → target entity")

-- 6 tiles ahead
logic.entities = {}
place(makeWild({ id = "b", x = 11, y = 5 }))
e, dist = Target.findAhead(logic, ow, player, 6)
eq(dist, 6, "6 tiles ahead → target")
check(e and e.id == "b", "6 tiles entity")

-- 7 tiles ahead → no target
logic.entities = {}
place(makeWild({ id = "c", x = 12, y = 5 }))
e, dist = Target.findAhead(logic, ow, player, 6)
check(e == nil, "7 tiles ahead → no target")

-- Behind player → no target
logic.entities = {}
place(makeWild({ id = "d", x = 4, y = 5 }))
e = Target.findAhead(logic, ow, player, 6)
check(e == nil, "behind player → no target")

-- Side → no target (no cone)
logic.entities = {}
place(makeWild({ id = "e", x = 6, y = 6 }))
e = Target.findAhead(logic, ow, player, 6)
check(e == nil, "side offset → no target")

-- Town Pokémon ahead
logic.entities = {}
place(makeWild({ id = "f", x = 6, y = 5, ambient = true, overworldWildSpawn = false }))
e = Target.findAhead(logic, ow, player, 6)
check(e == nil, "town Pokémon ahead → no target")

-- Follower ahead
logic.entities = {}
place(makeWild({ id = "g", x = 6, y = 5, follower = true, overworldWildSpawn = false }))
e = Target.findAhead(logic, ow, player, 6)
check(e == nil, "follower ahead → no target")

-- Non-battleable scenery
logic.entities = {}
place(makeWild({ id = "h", x = 6, y = 5, caveScenery = true, canTriggerBattle = false }))
e = Target.findAhead(logic, ow, player, 6)
check(e == nil, "scenery wild → no target")

-- First along ray wins over farther
logic.entities = {}
place(makeWild({ id = "near", x = 7, y = 5 }))
place(makeWild({ id = "far", x = 10, y = 5 }))
e, dist = Target.findAhead(logic, ow, player, 6)
eq(dist, 2, "nearest along ray wins")
eq(e.id, "near", "nearest entity")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("overworld_catch_target_unit_test: all passed")
