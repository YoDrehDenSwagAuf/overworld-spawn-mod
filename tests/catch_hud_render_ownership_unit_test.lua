-- Catch HUD render ownership: Gen1 paints once via owwild_ball_hud only.
-- Gold paints once via render.hud → presentGold → drawScreen.
-- Run: lua tests/catch_hud_render_ownership_unit_test.lua
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

local optionStore = {
  enabled = true,
  overworld_catching = true,
  wilds_ai = true,
  catch_hud_size = 5,
}

local pipelineLevels = {}
local registered = {}
package.preload["src.render.Pipelines"] = function()
  return {
    setLevel = function(id, level) pipelineLevels[id] = level end,
    level = function(id) return pipelineLevels[id] or 0 end,
    eligible = function(id) return (pipelineLevels[id] or 0) > 0 end,
    rows = function() return {} end,
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
package.preload["src.battle.Catching"] = function()
  return { attempt = function() return false, 2 end }
end
package.preload["src.pokemon.Pokemon"] = function()
  return { new = function() return {} end }
end
package.preload["src.pokemon.Party"] = function()
  return { MAX = 6, add = function() return true end }
end
package.preload["src.pokemon.Boxes"] = function()
  return { deposit = function() return 1 end }
end
package.preload["src.render.TextBox"] = function()
  return { new = function() return {} end }
end

local drawCalls = 0
local drawnBalls = {}
love = {
  graphics = {
    push = function() end,
    pop = function() end,
    origin = function() end,
    translate = function() end,
    scale = function() end,
    setColor = function() end,
    setCanvas = function() end,
    rectangle = function() end,
    draw = function()
      drawCalls = drawCalls + 1
    end,
    print = function() end,
  },
  timer = { getTime = function() return 0 end },
}

local function makeV(isGen2)
  local player = { cellX = 5, cellY = 5, facing = "up", moving = false, px = 80, py = 80 }
  local ow = {
    map = { id = isGen2 and "ROUTE_29" or "ROUTE1" },
    player = player,
    npcs = {},
    entities = {},
    camera = { x = 0, y = 0 },
    zoomScale = function() return 1 end,
    busy = function() return false end,
    scriptRunning = function() return false end,
  }
  local game = {
    generation = isGen2 and 2 or 1,
    version = isGen2 and "gold" or "red",
    overworld = (not isGen2) and ow or nil,
    world = isGen2 and ow or nil,
    save = {
      inventory = {
        POKE_BALL = 5, GREAT_BALL = 2, ULTRA_BALL = 1, MASTER_BALL = 0,
      },
      party = {},
      options = { modOptions = { overworld_wild_spawns = optionStore } },
    },
    mods = { modOptions = { overworld_wild_spawns = optionStore } },
    data = { pokemon = {} },
    stack = { top = function() return nil end },
    input = { down = function() return false end },
  }
  if isGen2 then
    package.loaded["src.core.GameVersion"] = {
      get = function() return "gold" end,
      isYellow = function() return false end,
      isGold = function() return true end,
      generation = function() return 2 end,
    }
  else
    package.loaded["src.core.GameVersion"] = {
      get = function() return "red" end,
      isYellow = function() return false end,
      isGold = function() return false end,
      generation = function() return 1 end,
    }
  end

  local hookWraps = {}
  local V = {
    mod = {
      id = "overworld_wild_spawns",
      path = ".",
      log = { info = function() end, warn = function() end },
      options = {
        get = function(_, k) return optionStore[k] end,
        set = function(_, k, v) optionStore[k] = v end,
      },
      -- Gen1 catchWorld uses mod.world:overworld(); Gold uses game.world.
      world = {
        game = game,
        overworld = function() return ow end,
      },
      assets = { path = function(_, rel) return rel end },
      content = {
        sprites = {
          _defs = {},
          get = function(self, id) return self._defs[id] end,
          register = function(self, id, def) self._defs[id] = def end,
        },
        render_pipelines = {
          register = function(_, id, def)
            registered[id] = def
          end,
        },
      },
      ui = {
        Font = { draw = function() end, drawBox = function() end },
      },
      hooks = {
        wrap = function(_, name, fn)
          hookWraps[name] = hookWraps[name] or {}
          local prev = hookWraps[name][#hookWraps[name]]
          hookWraps[name][#hookWraps[name] + 1] = function(gameArg, dt)
            return fn(prev, gameArg, dt)
          end
        end,
      },
    },
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
  modules.debug_log = {
    warn = function() end, info = function() end, error = function() end,
  }
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

  return V, game, ow, hookWraps, modules
end

----------------------------------------------------------------
-- GEN1: single BallHud owner is owwild_ball_hud
----------------------------------------------------------------
do
  registered = {}
  pipelineLevels = {}
  optionStore.catch_hud_size = 5
  local V, game, ow = makeV(false)
  local Config = V.require("config")
  local OverworldCatching = V.require("catching/init")
  local BallHud = V.require("catching/hud")
  local logic = {
    entities = {}, spawns = {}, pendingBattle = false,
    _despawn = function() end, _attach = function() end,
    _detachFromWorld = function() end,
  }
  local catching = OverworldCatching.new(V.mod, logic)
  catching:registerContent()
  catching:register()
  catching:syncPipelineLevel()

  check(registered[OverworldCatching.PIPELINE_ID] ~= nil,
        "Gen1: owwild_catching_tick registered")
  check(registered[BallHud.PIPELINE_ID] ~= nil,
        "Gen1: owwild_ball_hud registered")
  eq(pipelineLevels[OverworldCatching.PIPELINE_ID], 1,
     "Gen1: catching pipeline level ON")
  eq(pipelineLevels[BallHud.PIPELINE_ID], 1,
     "Gen1: ball_hud pipeline level ON")

  -- Stub images so draw paints icons via love.graphics.draw.
  catching.ballHudImage = function()
    return {
      getDimensions = function() return 16, 16 end,
      setFilter = function() end,
    }
  end
  catching.ballImage = catching.ballHudImage

  local canvas = { id = "canvas" }
  local ctx = { width = 160, height = 144 }

  local beforeDraw = catching.hud._hudDrawCount or 0
  drawCalls = 0
  registered[OverworldCatching.PIPELINE_ID].present(canvas, ctx)
  eq(catching.hud._hudDrawCount or 0, beforeDraw,
     "Gen1: catching_tick.present does NOT draw BallHud")
  eq(drawCalls, 0, "Gen1: catching_tick.present issues no graphics.draw")

  beforeDraw = catching.hud._hudDrawCount or 0
  drawCalls = 0
  registered[BallHud.PIPELINE_ID].present(canvas, ctx)
  eq(catching.hud._hudDrawCount or 0, beforeDraw + 1,
     "Gen1: ball_hud.present draws BallHud exactly once")
  check(drawCalls > 0, "Gen1: ball_hud.present paints icons")

  -- Repeated render frames: exactly one draw per ball_hud present.
  local draws = catching.hud._hudDrawCount or 0
  for i = 1, 5 do
    registered[OverworldCatching.PIPELINE_ID].present(canvas, ctx)
    registered[BallHud.PIPELINE_ID].present(canvas, ctx)
    eq(catching.hud._hudDrawCount, draws + i,
       string.format("Gen1: frame %d draws once via ball_hud only", i))
  end

  -- No dependency on input.step / update count for HUD visibility.
  local mid = catching.hud._hudDrawCount or 0
  for _ = 1, 10 do
    catching:update(1 / 60, "input.step")
  end
  eq(catching.hud._hudDrawCount or 0, mid,
     "Gen1: input.step updates do not draw HUD")
  check(catching.hud._frame == nil, "Gen1: no _frame bookkeeping")
  check(catching.hud._drawnFrame == nil, "Gen1: no _drawnFrame bookkeeping")

  registered[BallHud.PIPELINE_ID].present(canvas, ctx)
  eq(catching.hud._hudDrawCount, mid + 1,
     "Gen1: HUD still draws after many input.steps")

  -- Ball selection / inventory refresh immediately on next present.
  catching.selectedBallIndex = 2 -- GREAT_BALL
  eq(catching:getSelectedBall(game), "GREAT_BALL", "Gen1: ball selection updates")
  game.save.inventory.GREAT_BALL = 9
  beforeDraw = catching.hud._hudDrawCount or 0
  registered[BallHud.PIPELINE_ID].present(canvas, ctx)
  eq(catching.hud._hudDrawCount, beforeDraw + 1,
     "Gen1: inventory/selection change still draws next frame")

  -- Size 0: no paint. Size 1–10: paints.
  optionStore.catch_hud_size = 0
  beforeDraw = catching.hud._hudDrawCount or 0
  drawCalls = 0
  registered[BallHud.PIPELINE_ID].present(canvas, ctx)
  eq(catching.hud._hudDrawCount or 0, beforeDraw,
     "Gen1: Catch HUD Size 0 draws nothing")
  eq(drawCalls, 0, "Gen1: size 0 issues no graphics.draw")
  -- Catching itself stays enabled at size 0.
  eq(Config.overworldCatchingEnabled(V.mod), true,
     "Gen1: size 0 does not disable catching")
  eq(Config.catchHudEnabled(V.mod), false,
     "Gen1: size 0 hides HUD only")

  for size = 1, 10 do
    optionStore.catch_hud_size = size
    beforeDraw = catching.hud._hudDrawCount or 0
    drawCalls = 0
    registered[BallHud.PIPELINE_ID].present(canvas, ctx)
    eq(catching.hud._hudDrawCount, beforeDraw + 1,
       string.format("Gen1: size %d draws once", size))
    check(drawCalls > 0, string.format("Gen1: size %d paints", size))
  end

  -- Source audit: catching_tick present must not call hud:draw.
  local initSrc = assert(io.open("lib/catching/init.lua", "r")):read("*a")
  local presentBlock = initSrc:match(
    "mod%.content%.render_pipelines:register%(OverworldCatching%.PIPELINE_ID,%s*%b{}%)")
  check(presentBlock ~= nil, "Gen1: found catching_tick register block")
  check(not presentBlock:find("hud:draw", 1, true),
        "Gen1: catching_tick register block has no hud:draw")
  check(not initSrc:find("hud._frame", 1, true)
        and not initSrc:find("hud%._frame", 1, true)
        and not initSrc:find("self.hud._frame", 1, true),
        "Gen1: update no longer stamps hud._frame")
end

----------------------------------------------------------------
-- GEN2 / Gold: render.hud → presentGold → drawScreen is sole owner
----------------------------------------------------------------
do
  registered = {}
  pipelineLevels = {}
  optionStore.catch_hud_size = 5
  package.loaded["src.core.GameVersion"] = nil
  package.loaded["src.render.Pipelines"] = nil
  local V, game, ow, hookWraps = makeV(true)
  local OverworldCatching = V.require("catching/init")
  local BallHud = V.require("catching/hud")
  local logic = {
    entities = {}, spawns = {}, pendingBattle = false,
    _despawn = function() end, _attach = function() end,
    _detachFromWorld = function() end,
  }
  local catching = OverworldCatching.new(V.mod, logic)
  catching:registerContent()
  catching:register()
  catching:syncPipelineLevel()

  catching.ballHudImage = function()
    return {
      getDimensions = function() return 16, 16 end,
      setFilter = function() end,
    }
  end
  catching.ballImage = catching.ballHudImage

  local canvas = { id = "canvas" }
  local ctx = { width = 160, height = 144 }

  local beforeDraw = catching.hud._hudDrawCount or 0
  registered[BallHud.PIPELINE_ID].present(canvas, ctx)
  eq(catching.hud._hudDrawCount or 0, beforeDraw,
     "Gold: owwild_ball_hud.present skips draw")

  beforeDraw = catching.hud._hudDrawCount or 0
  registered[OverworldCatching.PIPELINE_ID].present(canvas, ctx)
  eq(catching.hud._hudDrawCount or 0, beforeDraw,
     "Gold: owwild_catching_tick.present does not draw HUD")

  beforeDraw = catching.hud._hudDrawCount or 0
  drawCalls = 0
  catching:presentGold(game, { gameX = 40, gameY = 20, scale = 4, width = 640, height = 360 })
  eq(catching.hud._hudDrawCount or 0, beforeDraw + 1,
     "Gold: presentGold/drawScreen draws HUD exactly once")
  check(drawCalls > 0, "Gold: presentGold paints icons")

  -- render.hud wrap reaches presentGold once.
  check(catching._goldPresentHookInstalled, "Gold: render.hud hook installed")
  local hudChain = hookWraps["render.hud"]
  check(hudChain and #hudChain > 0, "Gold: render.hud wrap recorded")
  beforeDraw = catching.hud._hudDrawCount or 0
  hudChain[#hudChain](game, { gameX = 10, gameY = 10, scale = 2 })
  eq(catching.hud._hudDrawCount or 0, beforeDraw + 1,
     "Gold: render.hud wrap draws HUD exactly once")

  -- Repeated Gold presents: one draw each, no suppression flicker.
  beforeDraw = catching.hud._hudDrawCount or 0
  for i = 1, 3 do
    catching:presentGold(game, { gameX = 0, gameY = 0, scale = 1 })
    eq(catching.hud._hudDrawCount, beforeDraw + i,
       string.format("Gold: presentGold #%d draws once", i))
  end
end

----------------------------------------------------------------
-- Repo-wide: only the intended owners call BallHud draw APIs
----------------------------------------------------------------
do
  local files = {
    "lib/catching/hud.lua",
    "lib/catching/init.lua",
  }
  local drawOwners = 0
  local screenOwners = 0
  for _, path in ipairs(files) do
    local src = assert(io.open(path, "r")):read("*a")
    for _ in src:gmatch("hud:draw%(") do drawOwners = drawOwners + 1 end
    for _ in src:gmatch(":drawScreen%(") do screenOwners = screenOwners + 1 end
  end
  -- hud.lua present → hud:draw; drawScreen → self:draw (not hud:draw).
  -- init.lua must not call hud:draw anymore.
  local initSrc = assert(io.open("lib/catching/init.lua", "r")):read("*a")
  local hudSrc = assert(io.open("lib/catching/hud.lua", "r")):read("*a")
  local initHudDraw = 0
  for _ in initSrc:gmatch("hud:draw%(") do initHudDraw = initHudDraw + 1 end
  eq(initHudDraw, 0, "repo: catching/init.lua has zero hud:draw calls")
  check(hudSrc:find("return hud:draw%(canvas, ctx%)") ~= nil,
        "repo: ball_hud present still owns Gen1 hud:draw")
  check(initSrc:find("self.hud:drawScreen%(viewport%)") ~= nil,
        "repo: presentGold still owns Gold drawScreen")
  check(not hudSrc:find("_drawnFrame", 1, true),
        "repo: _drawnFrame removed from hud.lua")
  check(not hudSrc:find("self._frame", 1, true),
        "repo: self._frame removed from hud.lua")
end

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("catch_hud_render_ownership_unit_test: all passed")
