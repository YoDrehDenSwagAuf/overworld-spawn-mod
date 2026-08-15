-- Gold catching runtime: world/player/control/HUD/input (not a new catch system).
-- Run: lua tests/gen2_catch_runtime_unit_test.lua
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

package.preload["src.inventory.Bag"] = function()
  return {
    remove = function(save, id, qty)
      local n = (save.inventory[id] or 0) - (qty or 1)
      if n <= 0 then save.inventory[id] = nil else save.inventory[id] = n end
    end,
  }
end
package.preload["src.battle.gen2.Mon"] = function()
  return {
    new = function(data, species, level)
      if not (data and data.pokemon and data.pokemon[species]) then return nil end
      return {
        species = species, level = level, hp = 20, stats = { hp = 20 },
        _fromMonNew = true,
      }
    end,
    stampOT = function(save, mon)
      mon.ot = save.player and save.player.name
      return mon
    end,
  }
end
package.preload["src.battle.gen2.Catching"] = function()
  return {
    attempt = function(opts)
      if opts.ball == "MASTER_BALL" then return true, 255 end
      return false, 40
    end,
  }
end
package.preload["src.core.gen2.Boxes"] = function()
  return {
    NUM_BOXES = 14,
    box = function(save, index)
      save.boxes = save.boxes or {}
      save.boxes[index] = save.boxes[index] or {}
      return save.boxes[index]
    end,
    isFull = function() return false end,
  }
end
package.preload["src.render.Pipelines"] = function()
  return { setLevel = function() end, rows = function() return {} end }
end
package.preload["src.render.TextBox"] = function()
  return {
    new = function(game, msg, onDone)
      return { msg = msg, onDone = onDone }
    end,
  }
end

local optionStore = {
  enabled = true,
  overworld_catching = true,
  wilds_ai = true,
  dev_overlay = false,
  debug = false,
}

local goldPlayer = { cellX = 12, cellY = 8, facing = "right", moving = false }
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
    pokemon = {
      CATERPIE = { name = "CATERPIE", catchRate = 255 },
    },
  },
  stack = {
    _top = nil,
    top = function(self) return self._top end,
    push = function(self, s) self._top = s end,
  },
  input = {
    down = function() return false end,
  },
}

-- Old catching path: requires mod.world.overworld. Gold WorldAPI may be
-- missing or return nil while Wilds already use game.world.
local mod = {
  id = "overworld_wild_spawns",
  path = ".",
  log = { info = function() end, warn = function() end },
  options = {
    get = function(_, k)
      if optionStore[k] ~= nil then return optionStore[k] end
      return nil
    end,
  },
  world = { game = game }, -- NO overworld() method
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
}

local modules = {}
local V = { mod = mod, path = "." }
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
modules.movement = {
  stop = function() end,
  setFacing = function(e, f) e.facing = f end,
}
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

----------------------------------------------------------------
-- World / player resolution (the actual Gold dead-path)
----------------------------------------------------------------
local legacyOw
if mod.world.overworld then
  legacyOw = mod.world:overworld()
end
eq(legacyOw, nil, "legacy mod.world:overworld() is nil on this Gold fixture")

local catchOw = GameCompat.catchWorld(mod, game)
check(catchOw == goldWorld, "catchWorld returns game.world")
check(catchOw.player == goldPlayer, "Gold world.player is the native Player")
eq(GameCompat.catchPlayer(game, catchOw), goldPlayer, "catchPlayer returns Gold Player")
local cx, cy = GameCompat.playerCell(game, catchOw)
eq(cx, 12, "playerCell x")
eq(cy, 8, "playerCell y")

----------------------------------------------------------------
-- HUD / input guards on empty Gold stack (free roam)
----------------------------------------------------------------
local logic = {
  entities = {},
  spawns = {},
  pendingBattle = false,
  _despawn = function() end,
  _attach = function() end,
  _detachFromWorld = function() end,
  _onAggressiveAlert = function() end,
}
local catching = OverworldCatching.new(mod, logic)
eq(catching:overworld(), goldWorld, "OverworldCatching:overworld() is game.world")
eq(catching:canShowHud(game, catchOw), true, "GOLD CP1: canShowHud while walking")
eq(catching:canAcceptInput(game, catchOw), true, "GOLD CP2: canAcceptInput while walking")
eq(catching:_catchBlocker(game, catchOw), nil, "no runtime blocker in free roam")

goldWorld.textbox = true
eq(catching:canAcceptInput(game, catchOw), false, "Gold textbox latch blocks input")
eq(catching:canShowHud(game, catchOw), false, "Gold textbox latch hides HUD")
goldWorld.textbox = nil

goldWorld.busy = function() return true end
eq(catching:canAcceptInput(game, catchOw), false, "World:busy blocks input")
goldWorld.busy = function() return false end

game.stack._top = { name = "StartMenu" }
eq(catching:canAcceptInput(game, catchOw), false, "Gold stack overlay blocks input")
eq(catching:canShowHud(game, catchOw), false, "Gold stack overlay hides HUD")
game.stack._top = nil
eq(catching:canAcceptInput(game, catchOw), true, "empty Gold stack restores input")

----------------------------------------------------------------
-- C starts the meter
----------------------------------------------------------------
local cDown = false
game.input.down = function(_, key)
  return cDown and (key == "c" or key == "throw_ball" or key == "ow_catch_throw")
end
cDown = true
catching:pollInput(game, catchOw, 0.016)
eq(catching.phase, "metering", "GOLD CP2: hold C begins meter")
eq(catching.meter.active, true, "meter.active after C")
cDown = false
catching:pollInput(game, catchOw, 0.016)
check(catching.phase == "flying" or catching.phase == "idle",
      "GOLD CP3: release C leaves metering")
catching:cancelAll("test reset")
eq(catching.phase, "idle", "cancel returns to idle before later checks")

----------------------------------------------------------------
-- Target scan sees Gold Wilds entities (shared Target, same collection)
----------------------------------------------------------------
local Target = OverworldCatching.Target
local caterpie = {
  id = "w1",
  species = "CATERPIE",
  cellX = 14, cellY = 8,
  facing = "left",
  overworldWildSpawn = true,
  visibleSprite = true,
  canTriggerBattle = true,
  state = "AVAILABLE",
}
logic.entities.w1 = caterpie
goldWorld.npcs[1] = caterpie
goldWorld.entities[1] = caterpie
goldPlayer.facing = "right"
goldPlayer.cellX, goldPlayer.cellY = 12, 8
local hit = Target.scanThrowPath(logic, catchOw, goldPlayer, 4)
eq(hit.kind, Target.HitKind.WILD, "GOLD CP4: scanThrowPath sees CATERPIE")
eq(hit.entity, caterpie, "target entity is the Wilds CATERPIE")
eq(hit.distance, 2, "CATERPIE is 2 tiles east")

----------------------------------------------------------------
-- Projectile attaches to Gold npcs (drawPeople list)
----------------------------------------------------------------
goldWorld.npcs = { caterpie }
goldWorld.entities = { caterpie }
local okFlight = catching.projectile:startFlight(game, catchOw, {
  ballType = "POKE_BALL",
  startX = 12, startY = 8,
  facing = "right",
  power = 2,
  miss = true,
})
check(okFlight, "GOLD CP3/5: startFlight returns")
local ball = catching.projectile._trackedBall
check(ball ~= nil, "projectile created a ball entity")
local membership = GameCompat.containerMembership(catchOw, ball)
check(membership.npcs == true, "Gold ball is on ow.npcs")
check(membership.entities == true, "Gold ball is also on ow.entities")
catching.projectile:cleanup(catchOw)

----------------------------------------------------------------
-- Meter activation must not crash (B+A and C both call _beginMeter)
----------------------------------------------------------------
local RangePreview = OverworldCatching.RangePreview
catching:cancelAll("preview test")
eq(RangePreview.groundPreviewSupported(mod, game), false,
   "Gold ground preview intentionally unsupported")
eq(RangePreview.installFlatWorldHook(catching), false,
   "Gold does not wrap OverworldState.drawWorld")

-- Hostile WorldAPI:overworld() — old isVoxelActive would throw here.
mod.world.overworld = function()
  error("mod.world:overworld() is invalid on this Gold fixture")
end
local voxelOk, voxelActive = pcall(RangePreview.isVoxelActive, mod, catchOw)
check(voxelOk, "isVoxelActive does not call exploding overworld() when ow is supplied")
eq(voxelActive, false, "Gold World is not treated as Voxel")

local stepOk, stepErr = pcall(function()
  -- B+A owns the meter: missing C must not be treated as a desktop release.
  catching.meterSource = "modifier"
  catching:_beginMeter()
  catching:step({})
  catching:step({})
end)
check(stepOk, "Gold _beginMeter + step does not error: " .. tostring(stepErr))
eq(catching.meter.active, true, "HUD meter remains active after step")
eq(catching.phase, "metering", "phase stays metering")
eq(RangePreview._pending, nil, "Gold ground cells stay disabled")
eq(RangePreview._unsupportedReason, "gold_no_world_pass",
   "RangePreview reports unsupported Gold world pass")
catching:cancelAll("preview test done")
mod.world.overworld = nil

----------------------------------------------------------------
-- Fake mon fallback removed
----------------------------------------------------------------
local fake, err = GameCompat.createCaughtPokemon(game, "NOT_A_REAL_MON", 5)
eq(fake, nil, "missing Gold species returns nil")
check(err ~= nil, "missing Gold species returns error")

local real = GameCompat.createCaughtPokemon(game, "CATERPIE", 4)
check(real and real._fromMonNew, "real CATERPIE uses Mon.new")
eq(real.species, "CATERPIE", "created species is CATERPIE")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("gen2_catch_runtime_unit_test: all passed")
