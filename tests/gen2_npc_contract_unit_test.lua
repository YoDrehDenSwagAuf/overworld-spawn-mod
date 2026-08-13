-- Gold NPC constructor contract against real src/world/gen2/Npc.lua when
-- Gen1Recomp is available. Unit mocks that accept Gen1 arity are not proof.
-- Run: luajit tests/gen2_npc_contract_unit_test.lua
-- Optional: GEN1RECOMP_ROOT=/path/to/gen1recomp
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

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function engineRoot()
  local env = os.getenv("GEN1RECOMP_ROOT")
  if type(env) == "string" and env ~= "" and readFile(env .. "/src/world/gen2/Npc.lua") then
    return env
  end
  for _, root in ipairs({ ".deps/gen1recomp", "/tmp/gen1recomp-src" }) do
    if readFile(root .. "/src/world/gen2/Npc.lua") then return root end
  end
  return nil
end

package.loaded["src.core.GameVersion"] = {
  get = function() return "gold" end,
  isYellow = function() return false end,
  isGold = function() return true end,
  generation = function() return 2 end,
}

local V = {
  mod = { path = ".", id = "overworld_wild_spawns", log = { info = function() end, warn = function() end } },
  path = ".",
}
local modules = {}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

local GameCompat = V.require("game_compat")
local Gen2 = GameCompat.Gen2

local world = {
  map = { id = "ROUTE_29" },
  player = { cellX = 10, cellY = 10, facing = "down" },
  npcs = {},
  entities = {},
}
local game = { generation = 2, version = "gold", world = world, save = { party = {} } }
local spriteDef = {
  id = "SPRITE_WILDS_FOLLOWER_MON",
  image = "land_SENTRET.png",
  frames = 6,
  walker = true,
  trueColor = true,
  frameWidth = 16,
  frameHeight = 16,
}

local root = engineRoot()
if not root then
  print("skip  live src.world.gen2.Npc (no Gen1Recomp tree)")
else
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
  love = love or {
    math = { random = function(a, b)
      if b then return math.random(a, b) end
      return math.random(a)
    end },
    graphics = {
      newQuad = function() return { quad = true } end,
      push = function() end, pop = function() end,
      translate = function() end, scale = function() end,
      draw = function() end,
    },
  }
  package.loaded["src.core.Logger"] = {
    warn = function() end, info = function() end, error = function() end,
  }
  package.loaded["src.world.gen2.Map"] = {
    DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } },
  }
  package.loaded["src.script.gen2.Movement"] = {
    TELEPORT_BEAT_FRAMES = 16,
    TREE_SHAKE_FRAMES = 24,
    teleportYOffset = function() return 0 end,
    treeShakeIndex = function() return 0 end,
  }
  package.loaded["src.world.gen2.Permissions"] = {
    isSuperTallGrass = function() return false end,
    isGrass = function() return false end,
  }
  package.loaded["src.mods.Runtime"] = {
    wantsHook = function() return false end,
    call = function(_, fn, ...) return fn(...) end,
  }
  package.loaded["src.render.SpriteRenderer"] = {
    new = function(def, id)
      check(type(def) == "table" and def.image ~= nil,
            "real Npc.lua SpriteRenderer.new received spriteDef.image")
      return { def = def, id = id, draw = function() end, frames = { [0] = {} } }
    end,
  }
  package.loaded["src.world.gen2.Npc"] = nil
  package.loaded["src.world.NPC"] = nil

  local Npc = assert(require("src.world.gen2.Npc"), "loaded real Gold Npc.lua")
  check(type(Npc.new) == "function", "real Npc.lua exports new")
  check(type(Npc.MOVE) == "table", "real Npc.lua exports MOVE")
  eq(Npc.MOVE.STANDING_DOWN, 6, "real MOVE.STANDING_DOWN == 6")
  eq(Npc.MOVE.STILL, 1, "real MOVE.STILL == 1 (FIXED_FACING, not for followers)")

  local src, err = Gen2.npcModule()
  check(src == Npc, "Gen2.npcModule returns real src.world.gen2.Npc: " .. tostring(err))

  local npc, npcErr = Gen2.makeGuestNpc(game, world, {
    index = 241, name = "WILDS_TRAILER_1", spriteId = "SPRITE_PIKACHU",
    spriteDef = spriteDef, x = 8, y = 12, facing = "down",
  })
  check(npc ~= nil, "real Npc.lua NPC.new succeeded: " .. tostring(npcErr))
  eq(npc and npc.mapId, "ROUTE_29", "real NPC mapId")
  eq(npc and npc.cellX, 8, "real NPC cellX")
  eq(npc and npc.cellY, 12, "real NPC cellY")
  check(npc and npc.spriteDef == spriteDef, "real NPC keeps spriteDef")
  check(npc and npc.sprite ~= nil, "real NPC has SpriteRenderer")
  check(npc and type(npc.draw) == "function", "real NPC has Gold draw")
  eq(npc and npc.passable, true, "real NPC passable")
  eq(npc and npc._wildsGoldNpcSource, "src.world.gen2.Npc", "source is gen2.Npc")
  eq(npc and npc._wildsGoldMovement, 6, "movement STANDING_DOWN")
  -- Identity: Gold objects use the Npc module as metatable (Follower.lua).
  check(npc and getmetatable(npc) == Npc, "getmetatable(npc) == src.world.gen2.Npc")

  local attached = GameCompat.attachGuestEntity(world, npc, game)
  eq(attached, "npcs+entities", "real NPC attached to npcs+entities")
  local inNpcs, inEntities = false, false
  for _, n in ipairs(world.npcs) do if n == npc then inNpcs = true end end
  for _, e in ipairs(world.entities) do if e == npc then inEntities = true end end
  check(inNpcs, "real NPC in world.npcs")
  check(inEntities, "real NPC in world.entities")
  eq(npc._wildsGoldGuest, true, "guest persistence marker matches town Pokémon")
  -- Do not wrap native Gold draw: attachGuestEntity skips adapt when spriteDef.
  check(npc._wildsGoldAdapted ~= true, "native Gold NPC is not adaptWildEntity-wrapped")
  -- Gold World:rebuildPeople keeps npcs that are not in peopleFromMap when
  -- mapId is nil or equals the current map. Native map objects are the
  -- peopleFromMap set (identity), so mapId itself is not "this is a map object".
  local peopleFromMap = {}
  local kept = 0
  for _, n in ipairs(world.npcs) do
    if not peopleFromMap[n] and (n.mapId == nil or n.mapId == world.map.id) then
      kept = kept + 1
    end
  end
  check(kept >= 1, "rebuildPeople guest rule would keep the trailer")
end

-- Follower.lua source proof: native constructor + STANDING_DOWN + npcs/entities.
do
  local followerSrc
  if root then
    followerSrc = readFile(root .. "/src/world/gen2/Follower.lua")
  end
  if followerSrc then
    check(followerSrc:find('require%("src%.world%.gen2%.Npc"%)', 1) ~= nil,
          "Follower.lua requires src.world.gen2.Npc")
    check(followerSrc:find("NPC%.MOVE%.STANDING_DOWN", 1) ~= nil,
          "Follower.lua uses NPC.MOVE.STANDING_DOWN")
    check(followerSrc:find("NPC%.new%(world%.map%.id", 1) ~= nil,
          "Follower.lua calls NPC.new(world.map.id, ...)")
    check(followerSrc:find("table%.insert%(world%.npcs", 1) ~= nil
          and followerSrc:find("table%.insert%(world%.entities", 1) ~= nil,
          "Follower.lua inserts into world.npcs and world.entities")
    check(followerSrc:find("npc%.pikachuFollower = true", 1) ~= nil,
          "stock Gold follower sets pikachuFollower (Wilds trailers must not)")
  else
    print("skip  Follower.lua source proof (no Gen1Recomp tree)")
  end
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll Gen2 NPC contract tests passed.")
