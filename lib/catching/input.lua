-- Mobile / controller alternative catching input (B-modifier combos).
--
-- ADDITIONAL path alongside desktop C (throw) / Q (cycle). Does not replace them.
-- Uses Gen1Recomp logical GB buttons via game.input (a/b/left/right) so TouchControls,
-- gamepad, and keyboard bindings all share one adapter.
--
-- Architecture note (Gen1Recomp mod API):
--   - Readable: Input:isDown(btn), Input:wasPressed(btn) after Input:step
--   - Injectable: mod.input:tap/press/release (source-safe)
--   - NO documented consume/suppress API for physical/overlay presses
--   - input.step runs BEFORE Input:step promotes pressQueue → pressed edges
--
-- Therefore this adapter:
--   1. Runs on input.step and peeks pressQueue for edges (no B-hold delay).
--   2. Best-effort suppresses combo-owned left/right/a by clearing that button's
--      pressQueue entries + hold state/sources on the live Input object so
--      OverworldState:handleInput neither walks nor interacts.
--   3. Never delays or replays vanilla B: short B taps stay untouched; B is only
--      a modifier when a combo key appears while B is held.
--
-- TouchControls multitouch (verified in Gen1Recomp src/core/TouchControls.lua):
--   separate touch ids for d-pad vs face buttons; A and B are distinct controls;
--   B held + A held and B held + d-pad direction are supported without engine changes.

local CatchInput = {}
CatchInput.__index = CatchInput

-- Logical Gen1Recomp GB button ids (Input / TouchControls / mod.input).
CatchInput.BTN_A = "a"
CatchInput.BTN_B = "b"
CatchInput.BTN_LEFT = "left"
CatchInput.BTN_RIGHT = "right"

local STATE_IDLE = "idle"
local STATE_B_HELD = "b_held"       -- B down, waiting for combo (no delay)
local STATE_MODIFIER = "modifier"   -- combo used; left/right suppressed while B held
local STATE_CHARGING = "charging"   -- B+A meter active

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
  if not input then return false end
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
  if not input then return false end
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

  -- Entire adapter off when OW CATCH disabled or catching not allowed.
  if not catching:canAcceptInput(game, ow) then
    if self.state ~= STATE_IDLE or catching.meterSource == "modifier" then
      cancelModifierMeter(catching)
      self:_clearFlags("not eligible")
    end
    return
  end

  if not input then return end

  local bDown = inputIsDown(input, CatchInput.BTN_B)
  local aDown = inputIsDown(input, CatchInput.BTN_A)
  local leftEdge = pendingEdge(input, CatchInput.BTN_LEFT)
  local rightEdge = pendingEdge(input, CatchInput.BTN_RIGHT)
  local aEdge = pendingEdge(input, CatchInput.BTN_A)

  -- Soft-reset chord / Start-Select: never steal face buttons.
  if inputIsDown(input, "start") or inputIsDown(input, "select") then
    if self.state == STATE_CHARGING or catching.meterSource == "modifier" then
      cancelModifierMeter(catching)
    end
    self:_clearFlags("start/select")
    return
  end

  -- Desktop meter owns the throw: do not start a parallel B+A charge.
  if catching.phase == "metering" and catching.meterSource ~= "modifier" then
    if self.state ~= STATE_IDLE then self:_clearFlags("desktop metering") end
    return
  end

  if not bDown then
    if self.state == STATE_CHARGING or catching.meterSource == "modifier" then
      -- Early B release while charging → cancel (no throw, no ball consume).
      cancelModifierMeter(catching)
      self:_clearFlags("b released while charging")
      return
    end
    -- B released after combo: consumed=true; we never delayed/replayed B, and
    -- overworld handleInput does not act on B edges — no accidental vanilla B.
    self:_clearFlags("b released")
    return
  end

  -- B is held. Track pending → modifier without delaying vanilla B.
  if self.state == STATE_IDLE then
    self.state = STATE_B_HELD
    self.consumed = false
    self.suppressDirs = false
  end

  if (leftEdge or rightEdge or aEdge) and self.state == STATE_B_HELD then
    self.state = STATE_MODIFIER
    self.consumed = true
  end

  local canCycle = catching.phase == "idle" or catching.phase == "metering"
  if canCycle and (leftEdge or rightEdge)
     and (self.state == STATE_MODIFIER or self.state == STATE_CHARGING
          or self.state == STATE_B_HELD) then
    if leftEdge then
      catching:cycleSelectedBall(game, -1)
      CatchInput.suppressButton(input, CatchInput.BTN_LEFT, true)
      self.state = (self.state == STATE_CHARGING) and STATE_CHARGING or STATE_MODIFIER
      self.consumed = true
      self.suppressDirs = true
    end
    if rightEdge then
      catching:cycleSelectedBall(game, 1)
      CatchInput.suppressButton(input, CatchInput.BTN_RIGHT, true)
      self.state = (self.state == STATE_CHARGING) and STATE_CHARGING or STATE_MODIFIER
      self.consumed = true
      self.suppressDirs = true
    end
  end

  -- Keep left/right suppressed for the rest of this B hold after a cycle
  -- so a held direction cannot walk the player on later frames.
  if self.suppressDirs and self.state ~= STATE_IDLE then
    if inputIsDown(input, CatchInput.BTN_LEFT) or pendingEdge(input, CatchInput.BTN_LEFT) then
      CatchInput.suppressButton(input, CatchInput.BTN_LEFT, true)
    end
    if inputIsDown(input, CatchInput.BTN_RIGHT) or pendingEdge(input, CatchInput.BTN_RIGHT) then
      CatchInput.suppressButton(input, CatchInput.BTN_RIGHT, true)
    end
  end

  -- Charging: A release throws; keep A edges suppressed so interact() cannot fire.
  if self.state == STATE_CHARGING or catching.meterSource == "modifier" then
    if aEdge then
      CatchInput.suppressButton(input, CatchInput.BTN_A, false)
    end
    if not aDown then
      catching.meterSource = "modifier"
      self.state = STATE_MODIFIER
      self.consumed = true
      catching:_releaseThrow(game, ow)
      catching.meterSource = nil
      return
    end
    return
  end

  -- B + A press → begin existing meter.
  if aEdge and (self.state == STATE_B_HELD or self.state == STATE_MODIFIER)
     and catching.phase == "idle" then
    -- Consume A edge so OverworldState:interact does not run this step.
    CatchInput.suppressButton(input, CatchInput.BTN_A, false)
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
CatchInput.STATE_B_HELD = STATE_B_HELD
CatchInput.STATE_MODIFIER = STATE_MODIFIER
CatchInput.STATE_CHARGING = STATE_CHARGING

return CatchInput
