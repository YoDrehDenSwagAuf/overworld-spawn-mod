-- Central source of truth for Overworld Catch input configuration.
--
-- Keyboard shortcuts (desktop) and logical GB combos (gamepad / touch /
-- keyboard-mapped GB buttons) are parallel: both remain active.
--
-- Combo presets use logical Gen1Recomp buttons (a/b/select/left/right),
-- never physical scan codes, pad indices, or touch IDs.
--
-- Binding audit vs Gen1Recomp defaults + Wilds hotkeys:
--   Move WASD/arrows | A=Z/Enter/Space | B=X/Backspace | Start=Esc
--   Select=Tab/Shift | Hotkeys 2–5, -/=, F1/F2/F10
-- Keyboard choices therefore stay off those keys. Start is never a catch
-- modifier (menu / soft-reset). Select is offered only as a preset modifier.
local V = ...
local Config = V.require("config")
local DebugLog = V.require("debug_log")

local CatchBindings = {}

CatchBindings.DEFAULT_THROW_KEY = "c"
CatchBindings.DEFAULT_CYCLE_KEY = "q"
CatchBindings.DEFAULT_THROW_COMBO = "b_a"
CatchBindings.DEFAULT_CYCLE_COMBO = "b_dpad"

-- Allowed raw keyboard keys (Mod Manager / in-game choice values).
CatchBindings.THROW_KEY_CHOICES = { "c", "v", "f", "g", "r", "t" }
CatchBindings.CYCLE_KEY_CHOICES = { "q", "e", "r", "f", "g", "t" }

CatchBindings.THROW_COMBO_CHOICES = { "b_a", "select_a", "disabled" }
CatchBindings.CYCLE_COMBO_CHOICES = { "b_dpad", "select_dpad", "disabled" }

CatchBindings.OPTION_KEYS = {
  catch_throw_key = true,
  catch_cycle_key = true,
  catch_throw_combo = true,
  catch_cycle_combo = true,
}

-- Module-level presets. Treat as immutable; API returns copies.
local THROW_COMBOS = {
  b_a = { modifier = "b", action = "a" },
  select_a = { modifier = "select", action = "a" },
}

local CYCLE_COMBOS = {
  b_dpad = { modifier = "b", negative = "left", positive = "right" },
  select_dpad = { modifier = "select", negative = "left", positive = "right" },
}

local THROW_KEY_SET = {}
for i = 1, #CatchBindings.THROW_KEY_CHOICES do
  THROW_KEY_SET[CatchBindings.THROW_KEY_CHOICES[i]] = true
end

local CYCLE_KEY_SET = {}
for i = 1, #CatchBindings.CYCLE_KEY_CHOICES do
  CYCLE_KEY_SET[CatchBindings.CYCLE_KEY_CHOICES[i]] = true
end

local THROW_COMBO_SET = {}
for i = 1, #CatchBindings.THROW_COMBO_CHOICES do
  THROW_COMBO_SET[CatchBindings.THROW_COMBO_CHOICES[i]] = true
end

local CYCLE_COMBO_SET = {}
for i = 1, #CatchBindings.CYCLE_COMBO_CHOICES do
  CYCLE_COMBO_SET[CatchBindings.CYCLE_COMBO_CHOICES[i]] = true
end

local function opt(mod, key)
  if Config and type(Config.get) == "function" then
    local v = Config.get(mod, key)
    if v ~= nil then return v end
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local v = mod.options:get(key)
    if v ~= nil then return v end
  end
  return nil
end

local function normalizeKey(raw, allowed, fallback)
  if type(raw) ~= "string" then return fallback end
  local key = string.lower(raw)
  if allowed[key] then return key end
  return fallback
end

local function normalizeCombo(raw, allowed, fallback)
  if type(raw) ~= "string" then return fallback end
  local id = string.lower(raw)
  if allowed[id] then return id end
  return fallback
end

local function alternateCycleKey(throwKey)
  for i = 1, #CatchBindings.CYCLE_KEY_CHOICES do
    local key = CatchBindings.CYCLE_KEY_CHOICES[i]
    if key ~= throwKey then
      return key
    end
  end
  return CatchBindings.DEFAULT_CYCLE_KEY
end

function CatchBindings.isBindingOption(key)
  return CatchBindings.OPTION_KEYS[key] == true
end

--- Desktop throw key. Default "c". Resolved live (no permanent cache).
function CatchBindings.keyboardThrow(mod)
  return normalizeKey(opt(mod, "catch_throw_key"), THROW_KEY_SET,
    CatchBindings.DEFAULT_THROW_KEY)
end

--- Desktop ball-switch key. Default "q".
-- If the player sets Catch Key == Ball Switch Key, throw wins and cycle
-- falls back to the first non-conflicting cycle choice (usually Q).
function CatchBindings.keyboardCycle(mod)
  local throwKey = CatchBindings.keyboardThrow(mod)
  local cycleKey = normalizeKey(opt(mod, "catch_cycle_key"), CYCLE_KEY_SET,
    CatchBindings.DEFAULT_CYCLE_KEY)
  if cycleKey == throwKey then
    cycleKey = alternateCycleKey(throwKey)
    if mod and DebugLog then
      local msg = string.format(
        "Catch Key and Ball Switch Key both resolve to %s; cycle fell back to %s",
        throwKey, cycleKey)
      if type(DebugLog.onceKey) == "function" then
        DebugLog.onceKey(mod, "catch_dup_keys", "WARN", "%s", msg)
      elseif type(DebugLog.warn) == "function" then
        DebugLog.warn(mod, "%s", msg)
      end
    end
  end
  return cycleKey
end

--- Logical throw combo, or nil when disabled.
-- Returns a fresh table { modifier, action }.
function CatchBindings.throwCombo(mod)
  local id = normalizeCombo(opt(mod, "catch_throw_combo"), THROW_COMBO_SET,
    CatchBindings.DEFAULT_THROW_COMBO)
  if id == "disabled" then return nil end
  local preset = THROW_COMBOS[id] or THROW_COMBOS[CatchBindings.DEFAULT_THROW_COMBO]
  return { modifier = preset.modifier, action = preset.action }
end

--- Logical cycle combo, or nil when disabled.
-- Returns a fresh table { modifier, previous, next }.
function CatchBindings.cycleCombo(mod)
  local id = normalizeCombo(opt(mod, "catch_cycle_combo"), CYCLE_COMBO_SET,
    CatchBindings.DEFAULT_CYCLE_COMBO)
  if id == "disabled" then return nil end
  local preset = CYCLE_COMBOS[id] or CYCLE_COMBOS[CatchBindings.DEFAULT_CYCLE_COMBO]
  return {
    modifier = preset.modifier,
    previous = preset.negative,
    next = preset.positive,
  }
end

-- Test / docs surface (do not mutate).
CatchBindings.THROW_COMBOS = THROW_COMBOS
CatchBindings.CYCLE_COMBOS = CYCLE_COMBOS

return CatchBindings
