-- Gold catch frame path: update must run without the present pipeline.
-- Run: lua tests/gen2_catch_frame_unit_test.lua
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

local pipelineLevels = {}
package.preload["src.render.Pipelines"] = function()
  return {
    setLevel = function(id, level) pipelineLevels[id] = level end,
    level = function(id) return pipelineLevels[id] or 0 end,
    eligible = function(id) return (pipelineLevels[id] or 0) > 0 end,
    rows = function() return {} end,
    applyOptions = function()
      -- Gold boot restore: hidden Wilds pipelines drop to OFF.
      pipelineLevels["owwild_catching_tick"] = 0
      pipelineLevels["owwild_ball_hud"] = 0
    end,
  }
end
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
  return { box = function() return {} end }
end
package.preload["src.render.TextBox"] = function()
  return { new = function() return {} end }
end

package.loaded["src.world.NPC"] = {
  new = function(data)
    if type(data) == "table" then error("Gen1 NPC.new on Gold") end
    error("poisoned src.world.NPC")
  end,
}
package.loaded["src.world.gen2.Npc"] = {
  MOVE = { STANDING_DOWN = 6 },
  new = function(mapId, objDef, spriteDef)
    return {
      mapId = mapId, def = objDef, spriteDef = spriteDef,
      cellX = objDef.x, cellY = objDef.y,
      px = (objDef.x or 0) * 16, py = (objDef.y or 0) * 16,
      facing = "down", movement = objDef.movement, frozen = true,
      update = function() end,
      draw = function() end,
      pose = function(self) return self.sprite, self.px, self.py, "down", 0, false end,
    }
  end,
}

local optionStore = {
  enabled = true,
  overworld_catching = true,
  wilds_ai = true,
  catch_hud_size = 5,
}

local goldPlayer = { cellX = 10, cellY = 10, facing = "right", moving = false, px = 160, py = 160 }
local goldWorld = {
  map = { id = "ROUTE_29" },
  player = goldPlayer,
  camera = { x = 80, y = 72 },
  zoomScale = function() return 2 end,
  npcs = {},
  entities = {},
  busy = function() return false end,
  scriptRunning = function() return false end,
}

local game = {
  generation = 2,
  version = "gold",
  world = goldWorld,
  save = {
    inventory = { POKE_BALL = 5, GREAT_BALL = 2, ULTRA_BALL = 1, MASTER_BALL = 0 },
    party = {},
    options = { modOptions = { overworld_wild_spawns = optionStore } },
  },
  mods = { modOptions = { overworld_wild_spawns = optionStore } },
  data = { pokemon = { SENTRET = { name = "SENTRET", catchRate = 255 } } },
  stack = { top = function() return nil end },
  input = { down = function() return false end },
}

local hookWraps = {}
local V = { mod = {
  id = "overworld_wild_spawns",
  path = ".",
  log = { info = function() end, warn = function() end },
  options = { get = function(_, k) return optionStore[k] end },
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
  hooks = {
    wrap = function(_, name, fn)
      hookWraps[name] = hookWraps[name] or {}
      local prev = hookWraps[name][#hookWraps[name]]
      hookWraps[name][#hookWraps[name] + 1] = function(gameArg, dt)
        return fn(prev, gameArg, dt)
      end
    end,
  },
}, path = "." }

local modules = {}
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
  isWater = function() return false end, attach = function() end,
  WATER_AGGRESSIVE = "WATER_AGGRESSIVE", AGGRESSIVE = "AGGRESSIVE",
  STATE = { ALERT = "ALERT" },
}

local Config = V.require("config")
modules.config = Config
local GameCompat = V.require("game_compat")
local OverworldCatching = V.require("catching/init")
local RangePreview = V.require("catching/range_preview")

local logic = {
  entities = {},
  spawns = {},
  pendingBattle = false,
  _despawn = function() end,
  _attach = function() end,
  _detachFromWorld = function() end,
}
local catching = OverworldCatching.new(V.mod, logic)
catching:registerContent()
catching:register()

-- Simulate Gold Pipelines.applyOptions wiping hidden levels after register.
local Pipelines = require("src.render.Pipelines")
catching:syncPipelineLevel()
eq(Pipelines.level("owwild_catching_tick"), 1, "level is ON after Wilds register/sync")
Pipelines.applyOptions()
eq(Pipelines.level("owwild_catching_tick"), 0, "Gold applyOptions resets catching pipeline to 0")
eq(Pipelines.eligible("owwild_catching_tick"), false, "reset pipeline is not eligible")

-- Logic must still run from input.step even with pipeline OFF.
check(catching._updateHookInstalled, "input.step update hook installed")
check(catching._goldPresentHookInstalled, "render.hud present hook installed")

local function fireInputStep(dt)
  local chain = hookWraps["input.step"]
  local fn = chain and chain[#chain]
  if fn then fn(game, dt or (1 / 60)) end
end

-- Hold B+A so CatchInput does not cancel a modifier meter on input.step.
local held = { a = true, b = true }
game.input.down = function(_, key) return held[key] == true end
game.input.isDown = game.input.down

catching.meterSource = "modifier"
catching:_beginMeter()
if catching.catchInput then catching.catchInput.state = "charging" end
eq(catching.meter.active, true, "B+A / _beginMeter arms meter")
eq(catching.meter.power, 1, "meter starts at 1")

local startUpdates = catching._catchUpdateCount or 0
for _ = 1, 60 do
  catching:update(1 / 60, "input.step")
end
check((catching._catchUpdateCount or 0) - startUpdates == 60,
      "update ran exactly 60 times for 60 input.step frames")
eq(catching._skippedDoubleUpdate or 0, 0, "no double update during input.step-only run")
check(catching.meter.power ~= 1, "meter.power is not stuck at 1 after 60 frames")
check(catching.meter.power > 1.5, "meter advanced well past 1")
eq(catching.phase, "metering", "still metering while held")

-- The installed input.step wrap also reaches update (B+A still held).
local hookUpdates = catching._catchUpdateCount
fireInputStep(1 / 60)
eq(catching._catchUpdateCount, hookUpdates + 1, "input.step wrap calls update once")

-- A second update() from a dead pipeline present must not double-speed.
local powerBefore = catching.meter.power
local updatesBefore = catching._catchUpdateCount
catching:update(1 / 60, "pipeline")
eq(catching._catchUpdateCount, updatesBefore, "pipeline present does not double-update")
eq(catching.meter.power, powerBefore, "meter unchanged on skipped pipeline update")
check((catching._skippedDoubleUpdate or 0) >= 1, "double-update guard fired")

check(RangePreview._pending ~= nil and RangePreview._pending.cells
      and #RangePreview._pending.cells > 0,
      "Flat Gold RangePreview cells are non-empty")
local tiles = RangePreview.tilesFromPower(catching.meter.power)
eq(#RangePreview._pending.cells, tiles, "preview cell count matches rounded power")

-- HUD callback (render.hud) even with pipeline OFF.
love = {
  graphics = {
    push = function() end, pop = function() end, origin = function() end,
    translate = function() end, scale = function() end,
    setColor = function() end, rectangle = function() end, draw = function() end,
    setCanvas = function() end,
  },
}
local hudBefore = catching.hud._hudDrawCount or 0
catching:presentGold(game, { gameX = 40, gameY = 20, scale = 4, width = 640, height = 360 })
check((catching.hud._hudDrawCount or 0) > hudBefore, "HUD draw invoked via render.hud")

-- Gold projection uses World camera * zoomScale.
local sx, sy, sw, sh = RangePreview.worldToScreenGold(11, 10, goldWorld.camera, 2)
eq(sx, math.floor((0 - 80) * 2) + 11 * 16 * 2, "tile 1 east uses Gold transform")
eq(sw, 32, "Gold cell size follows zoomScale")

-- Release at charged power: travel == rounded power.
local rounded = RangePreview.tilesFromPower(catching.meter.power)
local landX, landY, travel = catching.projectile.landCell(
  goldPlayer.cellX, goldPlayer.cellY, goldPlayer.facing, catching.meter.power)
eq(travel, rounded, "landCell travel equals rounded meter power")
eq(landX, goldPlayer.cellX + rounded, "release travels east by charged tiles")
eq(landY, goldPlayer.cellY, "release keeps Y")

-- Native Gold projectile still used.
local okFlight = catching.projectile:startFlight(game, goldWorld, {
  ballType = "POKE_BALL",
  spriteDef = catching:ballSpriteDef("POKE_BALL"),
  startX = goldPlayer.cellX, startY = goldPlayer.cellY,
  facing = "right",
  power = rounded,
  miss = true,
})
check(okFlight, "native Gold projectile still starts")
local ball = catching.projectile._trackedBall
check(ball and ball.spriteDef and ball.spriteDef.image, "projectile still has Gold spriteDef")
eq(ball._wildsGoldNpcSource, "src.world.gen2.Npc", "native gen2.Npc regression")
catching.projectile:cleanup(goldWorld)

-- Voxel Gold: preview off, update/HUD still work.
goldWorld.cameraMode = "VOXEL"
eq(RangePreview.groundPreviewSupported(V.mod, game, goldWorld), false,
   "Voxel Gold disables green tiles")
goldWorld.cameraMode = "FLAT"

-- HUD size setting still maps 1/5/10.
local BallHud = catching.hud
optionStore.catch_hud_size = 1
local px1 = BallHud.iconPx(V.mod)
optionStore.catch_hud_size = 5
local px5 = BallHud.iconPx(V.mod)
optionStore.catch_hud_size = 10
local px10 = BallHud.iconPx(V.mod)
check(px1 < px5 and px5 < px10, "Catch HUD Size 1 < 5 < 10 on Gold")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("gen2_catch_frame_unit_test: all passed")
