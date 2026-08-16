-- Mobile / controller alternative catching input (logical GB combos).
--
-- ADDITIONAL path alongside desktop Catch Key / Ball Switch Key.
-- Uses Gen1Recomp logical GB buttons via game.input (a/b/select/left/right)
-- so TouchControls, gamepad, and keyboard-mapped GB buttons share one adapter.
--
-- Combo buttons come from CatchBindings (defaults B+A / B+Left/Right).
-- Throw and cycle may use different modifiers (e.g. Select+A and B+Dpad).
--
-- Architecture note (Gen1Recomp mod API):
--   - Readable: Input:isDown(btn), Input:wasPressed(btn) after Input:step
--   - Injectable: mod.input:tap/press/release (source-safe)
--   - NO documented consume/suppress API for physical/overlay presses
--   - input.step runs BEFORE Input:step promotes pressQueue → pressed edges
--
-- Therefore this adapter:
--   1. Runs on input.step and peeks pressQueue for edges (no modifier-hold delay).
--   2. Best-effort suppresses combo-owned left/right/a by clearing that button's
--      pressQueue entries + hold state/sources on the live Input object so
--      OverworldState:handleInput neither walks nor interacts.
--   3. Never delays or replays vanilla B: short B taps stay untouched; B is only
--      a modifier when a combo key appears while B is held. Select is the same:
--      Select alone stays native Select; its edge is suppressed only after a
--      configured Catch combo is detected (hold/sources are kept).
--
-- TouchControls multitouch (verified in Gen1Recomp src/core/TouchControls.lua):
--   separate touch ids for d-pad vs face buttons; A and B are distinct controls;
--   B held + A held and B held + d-pad direction are supported without engine changes.

local V = ...
local GameCompat = V.require("game_compat")
local CatchBindings = V.require("catching/bindings")

local CatchInput = {}
CatchInput.__index = CatchInput

-- Logical Gen1Recomp GB button ids (Input / TouchControls / mod.input).
CatchInput.BTN_A = "a"
CatchInput.BTN_B = "b"
CatchInput.BTN_SELECT = "select"
CatchInput.BTN_START = "start"
CatchInput.BTN_LEFT = "left"
CatchInput.BTN_RIGHT = "right"

local STATE_IDLE = "idle"
local STATE_MODIFIER_HELD = "modifier_held" -- a configured modifier is down
local STATE_MODIFIER = "modifier"           -- combo used; dirs suppressed while cycle modifier held
local STATE_CHARGING = "charging"           -- throw combo meter active

-- Compat alias: historical name for "modifier down, waiting for combo".
local STATE_B_HELD = STATE_MODIFIER_HELD

-- Movement re-arm window (logic frames, ~one step at default cadence):
-- after the player is mid-step, held directions stay MOVEMENT (not catching
-- combos) until the player has stood still for this long.  B doubles as the
-- run button in many setups, so a combo fired mid-run would suppress
-- steering for the whole B hold.  Applies to any D-pad cycle combo.
local CATCH_COMBO_MOVE_WINDOW = 16

function CatchInput.new(catching)
  local self = setmetatable({}, CatchInput)
  self.catching = catching
  self:_clearFlags("init")
  self._hookInstalled = false
  return self
end

function CatchInput:_clearFlags(reason)
  self.state = STATE_IDLE
  self.consumed = false
  self.suppressDirs = false
  self._reason = reason
end

--- Reset modifier bookkeeping. Optionally cancel an in-progress modifier meter.
-- When called from OverworldCatching:cancelAll, pass cancelMeter=false because
-- cancelAll already cleared the meter.
function CatchInput:reset(reason, cancelMeter)
  local catching = self.catching
  if cancelMeter ~= false and catching and catching.meterSource == "modifier" then
    if catching.meter and catching.meter.active then
      catching:_cancelMeter()
    end
    if catching._clearPreview then
      catching:_clearPreview()
    end
    catching.meterSource = nil
  end
  self:_clearFlags(reason or "reset")
end

local function inputIsDown(input, btn)
  if not input or not btn then return false end
  if type(input.isDown) == "function" then
    local ok, v = pcall(function() return input:isDown(btn) end)
    if ok then return v and true or false end
  end
  if type(input.down) == "function" then
    local ok, v = pcall(function() return input:down(btn) end)
    if ok then return v and true or false end
  end
  if type(input.state) == "table" then
    return input.state[btn] and true or false
  end
  return false
end

-- Edge pending for this fixed step (input.step runs before Input:step).
local function pendingEdge(input, btn)
  if not input or not btn then return false end
  local q = input.pressQueue
  if type(q) == "table" then
    for i = 1, #q do
      if q[i] == btn then return true end
    end
  end
  -- Fallback if somehow called after Input:step.
  if type(input.wasPressed) == "function" then
    local ok, v = pcall(function() return input:wasPressed(btn) end)
    if ok and v then return true end
  end
  if type(input.pressed) == "table" and input.pressed[btn] then
    return true
  end
  return false
end

-- Best-effort runtime consumption (no mod-facing consume API exists).
-- clearHold=false keeps isDown so we can detect A release while charging.
function CatchInput.suppressButton(input, btn, clearHold)
  if not input or not btn then return end
  local q = input.pressQueue
  if type(q) == "table" then
    for i = #q, 1, -1 do
      if q[i] == btn then table.remove(q, i) end
    end
  end
  if type(input.pressed) == "table" then
    input.pressed[btn] = nil
  end
  if clearHold ~= false then
    if type(input.state) == "table" then
      input.state[btn] = false
    end
    if type(input.sources) == "table" then
      input.sources[btn] = nil
    end
  end
end

-- Select is a registered-item / menu button. After a Catch combo using Select
-- as the modifier, drop only its pending edge so native Select does not fire
-- on the same step. Keep hold + sources so the combo stays usable.
local function suppressModifierEdge(input, modifier)
  if modifier == "select" then
    CatchInput.suppressButton(input, modifier, false)
  end
end

-- Start+Select (and Start alone) are engine menu / soft-reset chords.
-- Select alone is only treated as a catch-abort when Select is NOT a
-- configured catch modifier — that keeps default B+A behavior identical.
local function isProtectedChord(input, throwBinding, cycleBinding)
  local startDown = inputIsDown(input, CatchInput.BTN_START)
  local selectDown = inputIsDown(input, CatchInput.BTN_SELECT)
  if startDown and selectDown then
    return true
  end
  if startDown then
    return true
  end
  if selectDown then
    local selectUsed = (throwBinding and throwBinding.modifier == "select")
      or (cycleBinding and cycleBinding.modifier == "select")
    if not selectUsed then
      return true
    end
  end
  return false
end

function CatchInput:installHook(mod)
  if self._hookInstalled then return true end
  if not (mod and mod.hooks and mod.hooks.wrap) then
    return false
  end
  local catchInput = self
  mod.hooks:wrap("input.step", function(nextFn, game, dt)
    -- Always advance the chain first (vanilla is a no-op; other tools may inject).
    if nextFn then nextFn(game, dt) end
    catchInput:onInputStep(game, dt)
  end)
  self._hookInstalled = true
  return true
end

local function cancelModifierMeter(catching)
  if not catching then return end
  if catching.meter and catching.meter.active and catching.meterSource == "modifier" then
    catching:_cancelMeter()
  end
  if catching._clearPreview then
    catching:_clearPreview()
  end
  catching.meterSource = nil
  if catching.phase == "metering" then
    catching.phase = "idle"
  end
end

function CatchInput:onInputStep(game, _dt)
  local catching = self.catching
  if not catching then return end

  local ow = catching:overworld()
  local input = game and game.input
  local mod = catching.mod

  -- Entire adapter off when OW CATCH disabled or catching not allowed.
  if not catching:canAcceptInput(game, ow) then
    if self.state ~= STATE_IDLE or catching.meterSource == "modifier" then
      cancelModifierMeter(catching)
      self:_clearFlags("not eligible")
    end
    return
  end

  if not input then return end

  -- Resolve live so Catch Combo / Switch Combo apply without restart.
  local throwBinding = CatchBindings.throwCombo(mod)
  local cycleBinding = CatchBindings.cycleCombo(mod)

  local throwModDown = throwBinding and inputIsDown(input, throwBinding.modifier)
  local actionDown = throwBinding and inputIsDown(input, throwBinding.action)
  local actionEdge = throwBinding and pendingEdge(input, throwBinding.action)

  local cycleModDown = cycleBinding and inputIsDown(input, cycleBinding.modifier)
  local prevEdge = cycleBinding and pendingEdge(input, cycleBinding.previous)
  local nextEdge = cycleBinding and pendingEdge(input, cycleBinding.next)

  -- Movement gate: while the player is mid-step — or was within the last
  -- step — a held direction is MOVEMENT, not a catching combo.  B is also
  -- the run button in many setups (running-shoes / Runner mods), so firing
  -- the combo mid-run eats left/right and the player cannot steer while
  -- running.  The combo re-arms once the player stands still.  Applies to
  -- any D-pad cycle combo, regardless of modifier.
  local player = GameCompat.catchPlayer(game, ow)
  if player and player.moving == true then
    self._moveCooldown = CATCH_COMBO_MOVE_WINDOW
  else
    self._moveCooldown = math.max(0, (self._moveCooldown or 0) - 1)
  end
  local stationary = (self._moveCooldown or 0) <= 0
  -- Cycling with zero balls is pointless and the suppression is pure harm
  -- (a ball-less player holding B to run would lose all steering for no
  -- gain).  Only treat a cycle combo as a combo when there is a ball to
  -- cycle.  Throw keeps its own no-balls message below.
  local hasBalls = catching:anyBalls(game)
  local comboDir = stationary and hasBalls

  -- Soft-reset / Start menu: never steal those chords.
  if isProtectedChord(input, throwBinding, cycleBinding) then
    if self.state == STATE_CHARGING or catching.meterSource == "modifier" then
      cancelModifierMeter(catching)
    end
    self:_clearFlags("start/select")
    return
  end

  -- Desktop meter owns the throw: do not start a parallel combo charge.
  if catching.phase == "metering" and catching.meterSource ~= "modifier" then
    if self.state ~= STATE_IDLE then self:_clearFlags("desktop metering") end
    return
  end

  -- Throw modifier released while charging → cancel (no throw, no ball).
  -- Cycle may still be using a different modifier; do not force idle then.
  if (self.state == STATE_CHARGING or catching.meterSource == "modifier")
     and not throwModDown then
    cancelModifierMeter(catching)
    if not cycleModDown then
      self:_clearFlags("throw modifier released while charging")
      return
    end
    self.state = STATE_MODIFIER_HELD
    self.consumed = false
  end

  if not throwModDown and not cycleModDown then
    -- No configured modifier is down. We never delayed/replayed B or Select.
    self:_clearFlags("modifiers released")
    return
  end

  -- A configured modifier is held. Track pending → modifier without delaying
  -- vanilla B / Select.
  if self.state == STATE_IDLE then
    self.state = STATE_MODIFIER_HELD
    self.consumed = false
    self.suppressDirs = false
  end

  -- CYCLE detector (independent of throw modifier).
  local canCycle = cycleBinding and cycleModDown
    and (catching.phase == "idle" or catching.phase == "metering")
    and comboDir
  if canCycle and (prevEdge or nextEdge) then
    if prevEdge then
      catching:cycleSelectedBall(game, -1)
      CatchInput.suppressButton(input, cycleBinding.previous, true)
    end
    if nextEdge then
      catching:cycleSelectedBall(game, 1)
      CatchInput.suppressButton(input, cycleBinding.next, true)
    end
    suppressModifierEdge(input, cycleBinding.modifier)
    self.consumed = true
    self.suppressDirs = true
    if self.state ~= STATE_CHARGING then
      self.state = STATE_MODIFIER
    end
  end

  -- Keep left/right suppressed for the rest of this cycle-modifier hold
  -- after a cycle so a held direction cannot walk the player on later frames.
  if self.suppressDirs and cycleBinding and cycleModDown then
    local prev = cycleBinding.previous
    local nxt = cycleBinding.next
    if inputIsDown(input, prev) or pendingEdge(input, prev) then
      CatchInput.suppressButton(input, prev, true)
    end
    if inputIsDown(input, nxt) or pendingEdge(input, nxt) then
      CatchInput.suppressButton(input, nxt, true)
    end
  elseif self.suppressDirs and not cycleModDown then
    self.suppressDirs = false
  end

  -- Charging: action release throws; keep action edges suppressed so interact()
  -- cannot fire.
  if self.state == STATE_CHARGING or catching.meterSource == "modifier" then
    if throwBinding and actionEdge then
      CatchInput.suppressButton(input, throwBinding.action, false)
    end
    if throwBinding and not actionDown then
      catching.meterSource = "modifier"
      self.state = STATE_MODIFIER
      self.consumed = true
      catching:_releaseThrow(game, ow)
      catching.meterSource = nil
      return
    end
    return
  end

  -- Throw combo press → begin existing meter.
  if throwBinding and throwModDown and actionEdge and catching.phase == "idle" then
    -- Consume A edge so OverworldState:interact does not run this step.
    CatchInput.suppressButton(input, throwBinding.action, false)
    suppressModifierEdge(input, throwBinding.modifier)
    self.consumed = true

    if not catching:anyBalls(game) then
      catching:_pushNoBalls(game)
      self.state = STATE_MODIFIER
      catching.meterSource = nil
      return
    end

    self.state = STATE_CHARGING
    catching.meterSource = "modifier"
    catching:_beginMeter()
  end
end

function CatchInput:debugState()
  return {
    state = self.state,
    consumed = self.consumed and true or false,
    suppressDirs = self.suppressDirs and true or false,
  }
end

CatchInput.STATE_IDLE = STATE_IDLE
CatchInput.STATE_MODIFIER_HELD = STATE_MODIFIER_HELD
CatchInput.STATE_B_HELD = STATE_B_HELD
CatchInput.STATE_MODIFIER = STATE_MODIFIER
CatchInput.STATE_CHARGING = STATE_CHARGING
CatchInput.CATCH_COMBO_MOVE_WINDOW = CATCH_COMBO_MOVE_WINDOW

return CatchInput
