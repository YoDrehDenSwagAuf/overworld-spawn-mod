-- B-modifier catching input adapter (mobile / controller logical GB buttons).
-- Run: lua tests/overworld_catch_input_unit_test.lua
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

package.preload["src.inventory.Bag"] = function()
  return {
    remove = function(save, id, qty)
      local n = (save.inventory[id] or 0) - (qty or 1)
      if n <= 0 then save.inventory[id] = nil else save.inventory[id] = n end
    end,
  }
end
package.preload["src.render.TextBox"] = function()
  return {
    new = function(game, msg, onDone)
      game._lastText = msg
      return { msg = msg, onDone = onDone, isOpaque = true }
    end,
  }
end
package.preload["src.render.Pipelines"] = function()
  return { setLevel = function() end, rows = function() return {} end }
end

local optionStore = {
  enabled = true,
  overworld_catching = true,
  wilds_ai = true,
  dev_overlay = false,
}
local game = {
  save = {
    inventory = { POKE_BALL = 5, GREAT_BALL = 2, ULTRA_BALL = 1, MASTER_BALL = 1 },
    party = {},
    boxes = { {} },
    options = { modOptions = { overworld_wild_spawns = optionStore } },
  },
  mods = { modOptions = { overworld_wild_spawns = optionStore } },
  data = { pokemon = {} },
  stack = {
    _top = nil,
    top = function(self) return self._top end,
    push = function(self, s) self._top = s end,
  },
  input = nil,
}

local ow = {
  player = { cellX = 10, cellY = 10, facing = "up" },
  map = { id = "ROUTE_1" },
  entities = {},
}

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
      register = function() end,
    },
  },
  hooks = {
    wraps = {},
    wrap = function(self, name, fn)
      self.wraps[name] = fn
    end,
  },
  ui = {},
  read = function() return nil end,
}

-- Virtual loader for lib/*
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
modules.movement = {
  stop = function() end,
  setFacing = function(e, f) e.facing = f end,
}
modules.behavior = {
  STATE = { ALERT = "ALERT", IDLE = "IDLE" },
}
modules.safari_compat = {
  STATUS = { INACTIVE = "INACTIVE", ACTIVE = "ACTIVE", FALLBACK_VANILLA = "FALLBACK_VANILLA" },
  status = function() return "INACTIVE" end,
  isSafariMap = function() return false end,
}

local OverworldCatching = V.require("catching/init")
local CatchInput = V.require("catching/input")

local logic = {
  voxel = nil,
  spawns = {},
  _detachFromWorld = function() end,
  _attach = function() end,
  _onAggressiveAlert = function() end,
  pendingBattle = nil,
}

local catching = OverworldCatching.new(mod, logic)

local function freshInput()
  return {
    state = {},
    pressed = {},
    pressQueue = {},
    sources = {},
    isDown = function(self, btn) return self.state[btn] and true or false end,
    wasPressed = function(self, btn) return self.pressed[btn] and true or false end,
  }
end

local function press(input, btn, source)
  source = source or ("test:" .. btn)
  input.sources[btn] = input.sources[btn] or {}
  if not input.sources[btn][source] then
    input.sources[btn][source] = true
    input.pressQueue[#input.pressQueue + 1] = btn
  end
  input.state[btn] = true
end

local function release(input, btn, source)
  source = source or ("test:" .. btn)
  local sources = input.sources[btn]
  if sources then
    sources[source] = nil
    if next(sources) == nil then
      input.state[btn] = false
      input.sources[btn] = nil
    end
  else
    input.state[btn] = false
  end
end

local function promote(input)
  input.pressed = {}
  for _, btn in ipairs(input.pressQueue) do
    input.pressed[btn] = true
  end
  input.pressQueue = {}
end

local function stepModifier()
  catching.catchInput:onInputStep(game, 1 / 60)
  promote(game.input)
end

-- ---- Helpers ----
catching:registerContent()
game.input = freshInput()
game.stack._top = ow

check(catching:canAcceptInput(game, ow) == true, "eligible for catch input")

-- ---- OW CATCH OFF: no interception ----
optionStore.overworld_catching = false
game.input = freshInput()
press(game.input, "b")
press(game.input, "right")
stepModifier()
eq(catching.catchInput.state, CatchInput.STATE_IDLE, "OFF: modifier stays idle")
eq(game.input.state.right, true, "OFF: right not suppressed")
eq(catching.selectedBallIndex, 1, "OFF: ball index unchanged")
optionStore.overworld_catching = true
catching.catchInput:reset("test", false)

-- ---- Short B tap: no meter, no cycle, no consume ----
game.input = freshInput()
press(game.input, "b")
stepModifier()
eq(catching.catchInput.state, CatchInput.STATE_B_HELD, "B down → b_held")
eq(catching.catchInput.consumed, false, "short B not consumed yet")
eq(catching.phase, "idle", "short B does not meter")
release(game.input, "b")
stepModifier()
eq(catching.catchInput.state, CatchInput.STATE_IDLE, "B release → idle")
eq(catching.catchInput.consumed, false, "short B release not consumed")

-- ---- B + RIGHT: next ball, suppress walk ----
game.input = freshInput()
catching.selectedBallIndex = 1
press(game.input, "b")
stepModifier()
press(game.input, "right")
local before = catching.selectedBallIndex
stepModifier()
check(catching.selectedBallIndex ~= before or catching:ballCount(game, "GREAT_BALL") > 0,
      "B+RIGHT cycles toward next available")
-- GREAT_BALL count is 2, so index should advance to GREAT_BALL (2)
eq(catching.selectedBallIndex, 2, "B+RIGHT selects GREAT_BALL")
check(game.input.state.right ~= true, "RIGHT suppressed (no walk)")
local rightStillQueued = false
for _, b in ipairs(game.input.pressQueue) do
  if b == "right" then rightStillQueued = true end
end
check(not rightStillQueued, "RIGHT edge removed from pressQueue")
eq(catching.catchInput.consumed, true, "combo consumes B press cycle")
eq(catching.catchInput.suppressDirs, true, "dirs stay suppressed after cycle")
-- Held right continues to be suppressed next frame
game.input.state.right = true
game.input.sources.right = { ["test:right"] = true }
stepModifier()
check(game.input.state.right ~= true, "RIGHT still suppressed while B held")
release(game.input, "b")
stepModifier()
eq(catching.catchInput.state, CatchInput.STATE_IDLE, "B release after cycle → idle")

-- ---- B + LEFT: previous ball ----
game.input = freshInput()
catching.selectedBallIndex = 2
press(game.input, "b")
stepModifier()
press(game.input, "left")
stepModifier()
eq(catching.selectedBallIndex, 1, "B+LEFT selects previous POKE_BALL")
check(game.input.state.left ~= true, "LEFT suppressed")
release(game.input, "b")
stepModifier()

-- ---- B + A: begin meter; A release throws ----
game.input = freshInput()
local ballsBefore = catching:ballCount(game, "POKE_BALL")
catching.selectedBallIndex = 1
press(game.input, "b")
stepModifier()
press(game.input, "a")
stepModifier()
eq(catching.phase, "metering", "B+A begins meter")
eq(catching.meterSource, "modifier", "meter owned by modifier")
eq(catching.meter.active, true, "meter active")
check(game.input.pressed.a ~= true, "A edge suppressed (no interact)")
check(game.input.state.a == true, "A hold kept for release detection")
-- Advance meter a bit via desktop poll path (visual/update owner).
catching:_updateMeter(0.5)
local power = catching.meter.power
check(power > 1, "meter cycles while A held")
-- Release A → throw
release(game.input, "a")
stepModifier()
eq(catching.phase, "flying", "A release throws (flying)")
eq(catching:ballCount(game, "POKE_BALL"), ballsBefore - 1, "throw consumed a ball")
-- Cleanup flight for later tests
catching:cancelAll("test cleanup")
eq(catching.phase, "idle", "cancel clears phase")

-- ---- Cancel: release B before A ----
game.input = freshInput()
ballsBefore = catching:ballCount(game, "POKE_BALL")
press(game.input, "b")
stepModifier()
press(game.input, "a")
stepModifier()
eq(catching.phase, "metering", "charging before cancel")
release(game.input, "b")
stepModifier()
eq(catching.phase, "idle", "B release cancels meter")
eq(catching.meter.active, false, "meter inactive after cancel")
eq(catching:ballCount(game, "POKE_BALL"), ballsBefore, "cancel consumes no ball")

-- ---- Menu / no control: no modifier ----
game.input = freshInput()
local menu = { isOpaque = true }
game.stack._top = menu
press(game.input, "b")
press(game.input, "right")
local idx = catching.selectedBallIndex
stepModifier()
eq(catching.catchInput.state, CatchInput.STATE_IDLE, "menu: modifier inactive")
eq(catching.selectedBallIndex, idx, "menu: no ball cycle")
eq(game.input.state.right, true, "menu: right not suppressed")
game.stack._top = ow

-- ---- Desktop C path unchanged while modifier idle ----
game.input = freshInput()
-- Simulate C hold via pollInput aliases (physical key path).
local loveKeyboard = { c = true }
_G.love = {
  keyboard = {
    isDown = function(k) return loveKeyboard[k] == true end,
  },
  timer = { getTime = function() return 0 end },
}
catching.throwHeld = false
catching.phase = "idle"
catching.meterSource = nil
catching:pollInput(game, ow, 0.016)
eq(catching.phase, "metering", "desktop C still begins meter")
eq(catching.meterSource, "desktop", "desktop owns meter")
-- Modifier must not steal desktop metering.
press(game.input, "b")
press(game.input, "a")
stepModifier()
eq(catching.meterSource, "desktop", "modifier ignores desktop metering")
loveKeyboard.c = false
catching:pollInput(game, ow, 0.016)
check(catching.phase == "flying" or catching.phase == "idle",
      "desktop C release still throws/resolves")
catching:cancelAll("desktop cleanup")

-- ---- suppressButton helper ----
local inp = freshInput()
press(inp, "left")
CatchInput.suppressButton(inp, "left", true)
check(inp.state.left ~= true, "suppress clears hold")
eq(#inp.pressQueue, 0, "suppress clears queue")

print(string.format("\n%d failures", failures))
if failures > 0 then os.exit(1) end
