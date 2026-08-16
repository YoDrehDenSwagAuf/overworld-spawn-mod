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

modules.debug_log = {
  warn = function() end, info = function() end, error = function() end,
  onceKey = function() return true end,
}
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
local CatchBindings = V.require("catching/bindings")

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

-- ============================================================
-- Bindings API + defaults
-- ============================================================
eq(CatchBindings.keyboardThrow(mod), "c", "default Catch Key is C")
eq(CatchBindings.keyboardCycle(mod), "q", "default Ball Switch Key is Q")
local defaultThrow = CatchBindings.throwCombo(mod)
check(defaultThrow ~= nil, "default throw combo present")
eq(defaultThrow.modifier, "b", "default throw modifier B")
eq(defaultThrow.action, "a", "default throw action A")
local defaultCycle = CatchBindings.cycleCombo(mod)
check(defaultCycle ~= nil, "default cycle combo present")
eq(defaultCycle.modifier, "b", "default cycle modifier B")
eq(defaultCycle.previous, "left", "default cycle previous left")
eq(defaultCycle.next, "right", "default cycle next right")

-- Preset tables must not be shared mutably with callers.
defaultThrow.modifier = "mutated"
eq(CatchBindings.throwCombo(mod).modifier, "b", "throwCombo returns a copy")
defaultCycle.previous = "mutated"
eq(CatchBindings.cycleCombo(mod).previous, "left", "cycleCombo returns a copy")

eq(CatchInput.STATE_B_HELD, CatchInput.STATE_MODIFIER_HELD,
   "STATE_B_HELD remains a compat alias")

-- ============================================================
-- Select+A throw
-- ============================================================
optionStore.catch_throw_combo = "select_a"
optionStore.catch_cycle_combo = "b_dpad"
catching.catchInput:reset("select_a setup", false)
game.input = freshInput()
ballsBefore = catching:ballCount(game, "POKE_BALL")
press(game.input, "select", "touch:select")
stepModifier()
eq(catching.catchInput.state, CatchInput.STATE_MODIFIER_HELD, "Select down → modifier_held")
eq(catching.phase, "idle", "Select alone does not meter")
eq(game.input.state.select, true, "Select alone keeps hold")
press(game.input, "a", "touch:a")
stepModifier()
eq(catching.phase, "metering", "Select+A begins meter")
eq(catching.meterSource, "modifier", "Select+A meter owned by modifier")
check(game.input.pressed.a ~= true, "Select+A: A edge suppressed")
check(game.input.state.a == true, "Select+A: A hold kept")
check(game.input.sources.a and game.input.sources.a["touch:a"] == true,
      "Select+A: A touch source kept")
check(game.input.sources.select and game.input.sources.select["touch:select"] == true,
      "Select+A: Select touch source kept")
check(game.input.state.select == true, "Select+A: Select hold kept")
release(game.input, "a", "touch:a")
stepModifier()
eq(catching.phase, "flying", "Select+A release throws")
eq(catching:ballCount(game, "POKE_BALL"), ballsBefore - 1, "Select+A throw consumed a ball")
catching:cancelAll("select_a cleanup")

-- Select alone after reset is not consumed as a catch combo
game.input = freshInput()
press(game.input, "select", "touch:select")
stepModifier()
eq(catching.phase, "idle", "Select alone still idle")
eq(game.input.state.select, true, "Select alone not hold-cleared")
check(game.input.pressed.select == true, "Select-alone edge left for native Select")
release(game.input, "select", "touch:select")
stepModifier()

-- ============================================================
-- Select+Left/Right cycle
-- ============================================================
optionStore.catch_throw_combo = "b_a"
optionStore.catch_cycle_combo = "select_dpad"
catching.catchInput:reset("select_dpad setup", false)
game.input = freshInput()
catching.selectedBallIndex = 1
press(game.input, "select", "pad:select")
stepModifier()
press(game.input, "right", "pad:right")
stepModifier()
eq(catching.selectedBallIndex, 2, "Select+RIGHT selects GREAT_BALL")
check(game.input.state.right ~= true, "Select+RIGHT suppresses walk")
check(game.input.sources.select and game.input.sources.select["pad:select"] == true,
      "Select+RIGHT keeps Select pad source")
release(game.input, "select", "pad:select")
stepModifier()

game.input = freshInput()
catching.selectedBallIndex = 2
press(game.input, "select", "pad:select")
stepModifier()
press(game.input, "left", "pad:left")
stepModifier()
eq(catching.selectedBallIndex, 1, "Select+LEFT selects previous POKE_BALL")
catching.catchInput:reset("select_dpad cleanup", false)

-- ============================================================
-- Mixed: Select+A throw, B+Left/Right cycle
-- ============================================================
optionStore.catch_throw_combo = "select_a"
optionStore.catch_cycle_combo = "b_dpad"
catching.catchInput:reset("mixed setup", false)
game.input = freshInput()
catching.selectedBallIndex = 1
press(game.input, "b", "pad:b")
stepModifier()
press(game.input, "right", "pad:right")
stepModifier()
eq(catching.selectedBallIndex, 2, "mixed: B+RIGHT still cycles")
eq(catching.phase, "idle", "mixed: cycle does not start meter")
release(game.input, "b", "pad:b")
stepModifier()

game.input = freshInput()
press(game.input, "select", "pad:select")
stepModifier()
press(game.input, "a", "pad:a")
stepModifier()
eq(catching.phase, "metering", "mixed: Select+A still charges")
eq(catching.meterSource, "modifier", "mixed: throw uses Select modifier")
-- Cycle with the other modifier while charging
press(game.input, "b", "pad:b")
press(game.input, "left", "pad:left")
local mixedIdx = catching.selectedBallIndex
stepModifier()
eq(catching.selectedBallIndex, mixedIdx - 1, "mixed: B+LEFT cycles while Select+A charges")
eq(catching.phase, "metering", "mixed: cycle does not cancel Select charge")
release(game.input, "b", "pad:b")
stepModifier()
eq(catching.phase, "metering", "mixed: releasing B does not cancel Select charge")
release(game.input, "select", "pad:select")
stepModifier()
eq(catching.phase, "idle", "mixed: releasing Select cancels charge")
eq(catching.meter.active, false, "mixed: meter inactive after Select release")
catching:cancelAll("mixed cleanup")

-- ============================================================
-- Disabled logical throw combo (desktop key still works)
-- ============================================================
optionStore.catch_throw_combo = "disabled"
optionStore.catch_cycle_combo = "b_dpad"
catching.catchInput:reset("disabled throw", false)
game.input = freshInput()
press(game.input, "b")
stepModifier()
press(game.input, "a")
stepModifier()
eq(catching.phase, "idle", "disabled throw combo: B+A does not meter")
check(game.input.state.a == true, "disabled throw combo: A not suppressed")
release(game.input, "a")
release(game.input, "b")
stepModifier()

_G.love = {
  keyboard = { isDown = function(k) return k == "c" end },
  timer = { getTime = function() return 0 end },
}
catching.throwHeld = false
catching.phase = "idle"
catching.meterSource = nil
catching:pollInput(game, ow, 0.016)
eq(catching.phase, "metering", "disabled combo: desktop C still throws")
eq(catching.meterSource, "desktop", "disabled combo: desktop owns meter")
catching:cancelAll("disabled throw cleanup")
_G.love = nil

-- Disabled cycle combo
optionStore.catch_throw_combo = "b_a"
optionStore.catch_cycle_combo = "disabled"
catching.catchInput:reset("disabled cycle", false)
game.input = freshInput()
catching.selectedBallIndex = 1
press(game.input, "b")
stepModifier()
press(game.input, "right")
stepModifier()
eq(catching.selectedBallIndex, 1, "disabled cycle combo: B+RIGHT does not cycle")
eq(game.input.state.right, true, "disabled cycle combo: right not suppressed")
release(game.input, "b")
stepModifier()
optionStore.catch_throw_combo = "b_a"
optionStore.catch_cycle_combo = "b_dpad"

-- ============================================================
-- Movement: cycle combo does not steal direction while moving
-- ============================================================
catching.catchInput:reset("move setup", false)
game.input = freshInput()
catching.selectedBallIndex = 1
ow.player.moving = true
press(game.input, "b")
stepModifier()
press(game.input, "right")
stepModifier()
eq(catching.selectedBallIndex, 1, "moving: B+RIGHT does not cycle")
eq(game.input.state.right, true, "moving: right not suppressed")
ow.player.moving = false
-- Drain the movement cooldown, then a fresh edge can cycle.
for _ = 1, CatchInput.CATCH_COMBO_MOVE_WINDOW + 1 do
  stepModifier()
end
game.input = freshInput()
press(game.input, "b")
stepModifier()
press(game.input, "right")
stepModifier()
eq(catching.selectedBallIndex, 2, "after stand-still: B+RIGHT cycles")
ow.player.moving = false
catching.catchInput:reset("move cleanup", false)

-- Select+Dpad also respects movement
optionStore.catch_cycle_combo = "select_dpad"
catching.catchInput:reset("move select", false)
game.input = freshInput()
catching.selectedBallIndex = 1
ow.player.moving = true
press(game.input, "select")
stepModifier()
press(game.input, "right")
stepModifier()
eq(catching.selectedBallIndex, 1, "moving: Select+RIGHT does not cycle")
eq(game.input.state.right, true, "moving: Select+RIGHT not suppressed")
ow.player.moving = false
optionStore.catch_cycle_combo = "b_dpad"
catching.catchInput:reset("move select cleanup", false)

-- ============================================================
-- Reset: Start+Select never becomes catch input
-- ============================================================
optionStore.catch_throw_combo = "select_a"
catching.catchInput:reset("reset chord", false)
game.input = freshInput()
press(game.input, "start")
press(game.input, "select")
press(game.input, "a")
stepModifier()
eq(catching.phase, "idle", "Start+Select+A does not start catch")
eq(catching.catchInput.state, CatchInput.STATE_IDLE, "Start+Select stays idle")
eq(game.input.state.a, true, "Start+Select: A not consumed")
catching.catchInput:reset("reset chord cleanup", false)
optionStore.catch_throw_combo = "b_a"

-- Default B+A: Select still aborts (identical to historical behavior)
game.input = freshInput()
press(game.input, "b")
stepModifier()
press(game.input, "select")
stepModifier()
eq(catching.catchInput.state, CatchInput.STATE_IDLE, "default: Select aborts B hold")

-- ============================================================
-- Keyboard: default C/Q, custom F/E, duplicate, live change
-- ============================================================
local function setKeys(c, q)
  optionStore.catch_throw_key = c
  optionStore.catch_cycle_key = q
end

setKeys(nil, nil)
eq(CatchBindings.keyboardThrow(mod), "c", "unset Catch Key → C")
eq(CatchBindings.keyboardCycle(mod), "q", "unset Ball Switch Key → Q")

setKeys("f", "e")
eq(CatchBindings.keyboardThrow(mod), "f", "custom Catch Key F")
eq(CatchBindings.keyboardCycle(mod), "e", "custom Ball Switch Key E")

game.input = freshInput()
_G.love = {
  keyboard = { isDown = function(k) return k == "f" end },
  timer = { getTime = function() return 0 end },
}
catching.throwHeld = false
catching.cycleHeld = false
catching.phase = "idle"
catching.meterSource = nil
catching:pollInput(game, ow, 0.016)
eq(catching.phase, "metering", "custom F begins meter")
eq(catching.meterSource, "desktop", "custom F is desktop source")
_G.love.keyboard.isDown = function(k) return k == "c" end
-- Still holding F conceptually? We switched isDown to C only; F is up.
-- But throwHeld is true from F, and C is now "down" as throw? Catch key is F,
-- so C should not keep the meter. Release path should throw.
catching:pollInput(game, ow, 0.016)
check(catching.phase == "flying" or catching.phase == "idle",
      "releasing F (C no longer bound) releases throw")
catching:cancelAll("custom F cleanup")

-- C no longer starts when Catch Key is F
_G.love.keyboard.isDown = function(k) return k == "c" end
catching.throwHeld = false
catching.phase = "idle"
catching.meterSource = nil
catching:pollInput(game, ow, 0.016)
eq(catching.phase, "idle", "C no longer starts catch when Catch Key is F")

-- E cycles when Ball Switch Key is E
catching.selectedBallIndex = 1
catching.cycleHeld = false
_G.love.keyboard.isDown = function(k) return k == "e" end
catching:pollInput(game, ow, 0.016)
eq(catching.selectedBallIndex, 2, "custom E cycles ball")
catching.cycleHeld = true
_G.love.keyboard.isDown = function(k) return k == "q" end
catching:pollInput(game, ow, 0.016)
eq(catching.selectedBallIndex, 2, "Q no longer cycles when Ball Switch Key is E")
_G.love = nil

-- Duplicate binding: throw wins, cycle falls back
setKeys("f", "f")
eq(CatchBindings.keyboardThrow(mod), "f", "duplicate: throw stays F")
eq(CatchBindings.keyboardCycle(mod), "q", "duplicate: cycle falls back to Q")
setKeys("t", "t")
eq(CatchBindings.keyboardThrow(mod), "t", "duplicate T: throw stays T")
eq(CatchBindings.keyboardCycle(mod), "q", "duplicate T: cycle falls back to Q")

-- Live option change while charging: cancel, no ball consume
setKeys("c", "q")
game.input = freshInput()
_G.love = {
  keyboard = { isDown = function(k) return k == "c" end },
  timer = { getTime = function() return 0 end },
}
catching.throwHeld = false
catching.phase = "idle"
catching.meterSource = nil
local liveBalls = catching:ballCount(game, "POKE_BALL")
catching:pollInput(game, ow, 0.016)
eq(catching.phase, "metering", "live change: C started meter")
setKeys("f", "e")
catching:onOptionsChanged({
  mod = mod.id, key = "catch_throw_key", value = "f",
})
eq(catching.phase, "idle", "live change: meter cancelled")
eq(catching.meter.active, false, "live change: meter inactive")
eq(catching:ballCount(game, "POKE_BALL"), liveBalls, "live change: no ball consumed")
eq(catching.catchInput.state, CatchInput.STATE_IDLE, "live change: CatchInput reset")
_G.love.keyboard.isDown = function(k) return k == "c" end
catching.throwHeld = false
catching:pollInput(game, ow, 0.016)
eq(catching.phase, "idle", "live change: old C no longer starts")
_G.love.keyboard.isDown = function(k) return k == "f" end
catching:pollInput(game, ow, 0.016)
eq(catching.phase, "metering", "live change: new F starts")
catching:cancelAll("live change cleanup")
_G.love = nil
setKeys(nil, nil)

-- Combo option change while charging
optionStore.catch_throw_combo = "b_a"
game.input = freshInput()
press(game.input, "b")
stepModifier()
press(game.input, "a")
stepModifier()
eq(catching.phase, "metering", "combo change: charging")
local comboBalls = catching:ballCount(game, "POKE_BALL")
optionStore.catch_throw_combo = "select_a"
catching:onOptionsChanged({
  mod = mod.id, key = "catch_throw_combo", value = "select_a",
})
eq(catching.phase, "idle", "combo change: meter cancelled")
eq(catching:ballCount(game, "POKE_BALL"), comboBalls, "combo change: no ball consumed")
optionStore.catch_throw_combo = "b_a"
optionStore.catch_cycle_combo = "b_dpad"

-- ============================================================
-- Touch sources: suppression does not corrupt unrelated sources
-- ============================================================
game.input = freshInput()
press(game.input, "b", "touch:b")
stepModifier()
press(game.input, "a", "touch:a")
stepModifier()
eq(catching.phase, "metering", "touch B+A begins meter")
check(game.input.sources.b and game.input.sources.b["touch:b"] == true,
      "touch: B source kept while charging")
check(game.input.sources.a and game.input.sources.a["touch:a"] == true,
      "touch: A source kept (release detection)")
check(game.input.sources.b["touch:a"] == nil, "touch: A source not copied onto B")
release(game.input, "a", "touch:a")
stepModifier()
eq(catching.phase, "flying", "touch A release throws")
catching:cancelAll("touch cleanup")

-- ============================================================
-- Controller pad sources
-- ============================================================
game.input = freshInput()
press(game.input, "b", "pad:b")
stepModifier()
press(game.input, "a", "pad:a")
stepModifier()
eq(catching.phase, "metering", "pad B+A begins meter")
check(game.input.sources.b and game.input.sources.b["pad:b"] == true,
      "pad: B source kept")
check(game.input.sources.a and game.input.sources.a["pad:a"] == true,
      "pad: A source kept")
release(game.input, "a", "pad:a")
stepModifier()
eq(catching.phase, "flying", "pad A release throws")
catching:cancelAll("pad cleanup")

-- Schema / defaults
local schema = assert(loadfile("options.lua"))()
local byKey = {}
for _, row in ipairs(schema) do byKey[row.key] = row end
eq(byKey.catch_throw_key.default, "c", "schema Catch Key default C")
eq(byKey.catch_cycle_key.default, "q", "schema Ball Switch Key default Q")
eq(byKey.catch_throw_combo.default, "b_a", "schema Catch Combo default b_a")
eq(byKey.catch_cycle_combo.default, "b_dpad", "schema Switch Combo default b_dpad")
check(#byKey.catch_throw_key.choices == 6, "Catch Key has 6 choices")
check(#byKey.catch_cycle_key.choices == 6, "Ball Switch Key has 6 choices")
check(#byKey.catch_throw_combo.choices == 3, "Catch Combo has 3 choices")
check(#byKey.catch_cycle_combo.choices == 3, "Switch Combo has 3 choices")

print(string.format("\n%d failures", failures))
if failures > 0 then os.exit(1) end
