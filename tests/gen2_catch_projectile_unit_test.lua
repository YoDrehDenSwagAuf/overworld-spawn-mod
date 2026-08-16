-- Gold catch projectile must be a native gen2.Npc, not Gen1 NPC.new(data, ...).
-- Run: lua tests/gen2_catch_projectile_unit_test.lua
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

package.loaded["src.core.GameVersion"] = {
  get = function() return "gold" end,
  isYellow = function() return false end,
  isGold = function() return true end,
  generation = function() return 2 end,
}

local gen1NpcCalls = 0
package.loaded["src.world.NPC"] = {
  new = function(data, mapId, objDef)
    if type(data) == "table" then
      gen1NpcCalls = gen1NpcCalls + 1
      error("Gold must not call Gen1 NPC.new(data, mapId, objDef)")
    end
    error("poisoned src.world.NPC is not Gold Npc")
  end,
}

local goldNewCalls = 0
local function nativeGoldNpcModule()
  return {
    MOVE = {
      STILL = 1, WANDER = 2, STANDING_DOWN = 6,
      STANDING_UP = 7, STANDING_LEFT = 8, STANDING_RIGHT = 9,
    },
    new = function(mapId, objDef, spriteDef)
      if type(mapId) == "table" then
        error("Gold native NPC.new received Gen1 arity")
      end
      if type(objDef) ~= "table" then
        error("Gold native NPC.new missing objDef")
      end
      if type(spriteDef) ~= "table" or spriteDef.image == nil then
        error("Gold native NPC.new requires spriteDef.image")
      end
      goldNewCalls = goldNewCalls + 1
      return {
        id = string.format("%s_obj_%d", tostring(mapId), objDef.index or 0),
        mapId = mapId,
        def = objDef,
        spriteDef = spriteDef,
        sprite = { def = spriteDef, id = "npc" },
        cellX = objDef.x or 0,
        cellY = objDef.y or 0,
        px = (objDef.x or 0) * 16,
        py = (objDef.y or 0) * 16,
        facing = "down",
        moving = false,
        passable = false,
        movement = objDef.movement,
        update = function(self, map, entities)
          self._goldUpdateArgs = { map = map, entities = entities }
          if self.frozen or self.movement == 6 then
            return
          end
          self.px = 0
          self.py = 0
        end,
        pose = function(ent)
          return ent.sprite, ent.px, ent.py, ent.facing, 0, false
        end,
        draw = function(self, ox, oy, scale)
          self._lastGoldDraw = { ox = ox, oy = oy, scale = scale }
        end,
      }
    end,
  }
end
local goldNpc = nativeGoldNpcModule()
package.loaded["src.world.gen2.Npc"] = goldNpc

package.preload["src.inventory.Bag"] = function()
  return {
    remove = function(save, id, qty)
      local n = (save.inventory[id] or 0) - (qty or 1)
      if n <= 0 then save.inventory[id] = nil else save.inventory[id] = n end
    end,
  }
end
package.preload["src.battle.gen2.Mon"] = function()
  return { new = function() return nil end, stampOT = function(_, mon) return mon end }
end
package.preload["src.battle.gen2.Catching"] = function()
  return { attempt = function() return false, 40 end }
end
package.preload["src.core.gen2.Boxes"] = function()
  return { box = function() return {} end, isFull = function() return false end }
end
package.preload["src.render.Pipelines"] = function()
  return { setLevel = function() end, rows = function() return {} end }
end
package.preload["src.render.TextBox"] = function()
  return { new = function() return {} end }
end

local optionStore = {
  enabled = true,
  overworld_catching = true,
  wilds_ai = true,
  dev_overlay = false,
  debug = false,
}

local goldPlayer = { cellX = 12, cellY = 8, facing = "left", moving = false }
local goldWorld = {
  map = { id = "ROUTE_29" },
  player = goldPlayer,
  playerState = "normal",
  npcs = {},
  entities = {},
  textbox = nil,
  choicebox = nil,
  battleActive = nil,
  busy = function() return false end,
  scriptRunning = function() return false end,
  showText = function() end,
}

local game = {
  generation = 2,
  version = "gold",
  world = goldWorld,
  save = {
    inventory = { POKE_BALL = 5, GREAT_BALL = 1, ULTRA_BALL = 0, MASTER_BALL = 0 },
    party = {},
    boxes = {},
    currentBox = 1,
    pokedex = { seen = {}, caught = {} },
    player = { name = "GOLD", id = 1 },
    options = { modOptions = { overworld_wild_spawns = optionStore } },
  },
  mods = { modOptions = { overworld_wild_spawns = optionStore } },
  data = {
    pokemon = { CATERPIE = { name = "CATERPIE", catchRate = 255 } },
    sprites = {},
  },
  stack = {
    _top = nil,
    top = function(self) return self._top end,
    push = function(self, s) self._top = s end,
  },
  input = { down = function() return false end },
}

local modules = {}
local V = { mod = {
  id = "overworld_wild_spawns",
  path = ".",
  log = { info = function() end, warn = function() end },
  options = {
    get = function(_, k)
      if optionStore[k] ~= nil then return optionStore[k] end
      return nil
    end,
  },
  world = { game = game },
  assets = { path = function(_, rel) return rel end },
  content = {
    sprites = {
      _defs = {},
      get = function(self, id) return self._defs[id] end,
      register = function(self, id, def) self._defs[id] = def end,
    },
    render_pipelines = { register = function() end },
  },
  ui = {},
}, path = "." }
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end
modules.debug_log = { warn = function() end, info = function() end, error = function() end }
modules.tile = { CELL = 16 }
modules.safari_compat = {
  STATUS = { INACTIVE = "INACTIVE", ACTIVE = "ACTIVE" },
  status = function() return "INACTIVE" end,
}
modules.movement = { stop = function() end, setFacing = function(e, f) e.facing = f end }
modules.behavior = {
  isWater = function() return false end,
  attach = function() end,
  WATER_AGGRESSIVE = "WATER_AGGRESSIVE",
  AGGRESSIVE = "AGGRESSIVE",
  STATE = { ALERT = "ALERT" },
}

local Config = V.require("config")
modules.config = Config
local GameCompat = V.require("game_compat")
local OverworldCatching = V.require("catching/init")

local src = assert(io.open("lib/catching/projectile.lua", "r")):read("*a")
check(not src:find('src.world.NPC', 1, true),
      "projectile.lua no longer requires src.world.NPC")
check(src:find("GameCompat.makeCatchProjectile", 1, true),
      "projectile.lua uses GameCompat.makeCatchProjectile")

local logic = {
  entities = {},
  spawns = {},
  pendingBattle = false,
  _despawn = function() end,
  _attach = function() end,
  _detachFromWorld = function() end,
  _onAggressiveAlert = function() end,
}
local catching = OverworldCatching.new(V.mod, logic)
catching:registerContent()
local ballDef = catching:ballSpriteDef("POKE_BALL")
check(type(ballDef) == "table" and ballDef.image ~= nil,
      "ballSpriteDef has image (not a sprite id only)")
eq(ballDef.frames, 1, "ball SpriteDef frames=1")
eq(ballDef.walker, false, "ball SpriteDef walker=false")

----------------------------------------------------------------
-- Direct makeCatchProjectile: native Gold NPC
----------------------------------------------------------------
local npc, npcErr = GameCompat.makeCatchProjectile(game, goldWorld, {
  ballType = "POKE_BALL",
  spriteId = "SPRITE_WILDS_BALL_POKE_BALL",
  spriteDef = ballDef,
  x = 12, y = 8,
})
check(npc ~= nil, "makeCatchProjectile returns Gold NPC: " .. tostring(npcErr))
eq(npc and npc._wildsGoldNpcSource, "src.world.gen2.Npc", "source is gen2.Npc")
eq(npc and npc.movement, 6, "Gold ball uses STANDING_DOWN")
eq(npc and npc.frozen, true, "Gold ball is frozen (no wander)")
check(npc and npc.spriteDef and npc.spriteDef.image, "native spriteDef.image present")
eq(gen1NpcCalls, 0, "Gen1 NPC.new was not called")
check(goldNewCalls >= 1, "src.world.gen2.Npc.new was used")

----------------------------------------------------------------
-- Empty-space miss throw (no wild in front)
----------------------------------------------------------------
goldWorld.npcs = {}
goldWorld.entities = {}
goldPlayer.facing = "left"
goldPlayer.cellX, goldPlayer.cellY = 12, 8
catching.meterSource = "modifier"
catching:_beginMeter()
catching.meter.power = 3
local before = GameCompat.ballCount(game, "POKE_BALL")
local releaseOk, releaseErr = pcall(function()
  catching:_releaseThrow(game, goldWorld)
end)
check(releaseOk, "empty miss _releaseThrow does not error: " .. tostring(releaseErr))
eq(catching.phase, "flying", "miss throw enters flying")
eq(GameCompat.ballCount(game, "POKE_BALL"), before - 1, "miss consumes one ball")

local ball = catching.projectile._trackedBall
check(ball ~= nil, "miss created a ball")
check(ball.spriteDef and ball.spriteDef.image, "flight ball has spriteDef.image")
eq(ball._wildsGoldNpcSource, "src.world.gen2.Npc", "flight ball is native Gold NPC")
eq(ball.isPokeBallEntity, true, "tagged isPokeBallEntity")
eq(ball.wildsCatchProjectile, true, "tagged wildsCatchProjectile")
eq(ball.overworldWildSpawn, false, "ball is not a wild")
check(ball._wildsGoldAdapted ~= true, "native Gold ball is not adaptWildEntity-wrapped")
local membership = GameCompat.containerMembership(goldWorld, ball)
check(membership.npcs == true, "Gold ball is on ow.npcs")
check(membership.entities == true, "Gold ball is also on ow.entities")

local px0, py0 = ball.px, ball.py
ball:update(goldWorld.map, goldWorld.npcs)
eq(ball.px, px0, "Gold NPC update does not overwrite standing px")
eq(ball.py, py0, "Gold NPC update does not overwrite standing py")

local updateOk, updateErr = pcall(function()
  catching.projectile:update(game, goldWorld, 0.05)
end)
check(updateOk, "first projectile update does not error: " .. tostring(updateErr))
local px1 = ball.px
ball:update(goldWorld.map, goldWorld.npcs)
eq(ball.px, px1, "stand update does not clobber interpolation")

local drawOk, drawErr = pcall(function()
  ball:draw(8, 12, 2)
end)
check(drawOk, "Gold draw(ox, oy, scale) does not error: " .. tostring(drawErr))
check(ball._lastGoldDraw ~= nil, "native draw recorded Gold args")
eq(ball._lastGoldDraw.ox, 8, "draw ox")
eq(ball._lastGoldDraw.oy, 12, "draw oy")
eq(ball._lastGoldDraw.scale, 2, "draw scale")

local idle = false
for _ = 1, 200 do
  catching.projectile:update(game, goldWorld, 0.05)
  if catching.phase == "idle" and not catching.projectile:isBusy() then
    idle = true
    break
  end
end
check(idle, "empty miss lands and cleans up without a target")
eq(catching.projectile._trackedBall, nil, "miss cleanup removes tracked ball")
eq(gen1NpcCalls, 0, "Gen1 NPC.new still unused after miss flight")

----------------------------------------------------------------
-- Construction failure: no Gen1 fallback, throw cancelled, ball refunded
----------------------------------------------------------------
local origGen2 = package.loaded["src.world.gen2.Npc"]
package.loaded["src.world.gen2.Npc"] = nil
-- Only poisoned Gen1 NPC remains.
local failCount = GameCompat.ballCount(game, "POKE_BALL")
catching.meterSource = "modifier"
catching:_beginMeter()
catching.meter.power = 2
local failOk, failErr = pcall(function()
  catching:_releaseThrow(game, goldWorld)
end)
check(failOk, "failed Gold construction does not throw: " .. tostring(failErr))
eq(catching.phase, "idle", "failed construction cancels throw")
eq(GameCompat.ballCount(game, "POKE_BALL"), failCount, "failed construction refunds ball")
eq(catching.projectile._trackedBall, nil, "failed construction attaches nothing")
eq(gen1NpcCalls, 0, "failed path still does not call Gen1 NPC.new")
package.loaded["src.world.gen2.Npc"] = origGen2

----------------------------------------------------------------
-- Sprite-id-only spec is rejected unless a real SpriteDef is resolved
----------------------------------------------------------------
local noDef, noDefErr = GameCompat.makeCatchProjectile(game, goldWorld, {
  ballType = "POKE_BALL",
  spriteId = "SPRITE_WILDS_BALL_POKE_BALL",
  -- no spriteDef, no image, and wipe registry lookup
})
-- registerContent already put a def in content.sprites, so this should succeed
-- via resolve. Prove the id-only path still finds the registered def.
check(noDef ~= nil, "registered content SpriteDef is resolved: " .. tostring(noDefErr))
check(noDef and noDef.spriteDef and noDef.spriteDef.image,
      "resolved ball still has spriteDef.image")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("gen2_catch_projectile_unit_test: all passed")
