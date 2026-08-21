-- Free-text input for AI dialogues (keyboard preferred; NamingScreen fallback).
local V = ...
local AiLog = V.require("ai/log")

local Input = {}
Input.MAX_LEN = 80

local function tryRequire(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil
end

function Input.supportsKeyboard()
  if love and love.keyboard then return true end
  return false
end

--- Push a free-text prompt. onDone(text|nil) — nil means cancelled.
-- path: "keyboard" | "naming" | "none"
function Input.prompt(mod, game, opts, onDone)
  opts = opts or {}
  local title = opts.title or "ASK WHAT?"
  local maxLen = tonumber(opts.maxLen) or Input.MAX_LEN
  onDone = onDone or function() end

  -- Unit-test / headless injection
  if Input._testPrompt then
    return Input._testPrompt(mod, game, opts, onDone)
  end

  -- Prefer engine NamingScreen with elevated maxLen (works on controller/mobile).
  -- On desktop with keyboard, still use NamingScreen unless a keyboard screen exists;
  -- M9 documents glyph-grid limits. Desktop builds may also feed love.textinput
  -- into a thin wrapper when available.
  if Input.supportsKeyboard() and Input._useKeyboardScreen ~= false then
    local screen = Input._makeKeyboardScreen(game, title, maxLen, onDone)
    if screen and game and game.stack and game.stack.push then
      pcall(game.stack.push, game.stack, screen)
      return "keyboard"
    end
  end

  local NamingScreen = (mod and mod.ui and mod.ui.NamingScreen)
    or tryRequire("src.ui.NamingScreen")
    or tryRequire("src.ui.gen2.NamingScreen")
  if NamingScreen and NamingScreen.new and game and game.stack then
    local ok, screen = pcall(NamingScreen.new, game, {
      title = title,
      maxLen = math.min(maxLen, 32),
      onDone = function(name)
        if type(name) == "string" and name ~= "" then
          onDone(name)
        else
          onDone(nil)
        end
      end,
    })
    if ok and screen then
      pcall(game.stack.push, game.stack, screen)
      return "naming"
    end
  end

  AiLog.warn(mod, "no free-text input available")
  onDone(nil)
  return "none"
end

function Input._makeKeyboardScreen(game, title, maxLen, onDone)
  local screen = {
    isOpaque = true,
    game = game,
    title = title,
    maxLen = maxLen,
    text = "",
    _done = false,
  }
  function screen:enter() end
  function screen:leave() end
  function screen:textinput(t)
    if self._done then return end
    if type(t) ~= "string" then return end
    if #self.text < self.maxLen then
      self.text = self.text .. t
    end
  end
  function screen:keypressed(key)
    if self._done then return end
    if key == "backspace" then
      self.text = self.text:sub(1, math.max(0, #self.text - 1))
    elseif key == "return" or key == "kpenter" then
      self:_finish(self.text)
    elseif key == "escape" then
      self:_finish(nil)
    end
  end
  function screen:handleInput(input)
    -- Gen1Recomp-style logical buttons when love keyboard events are absent.
    if not input then return end
    if input.wasPressed and input:wasPressed("b") then
      self:_finish(nil)
      return
    end
    if input.wasPressed and input:wasPressed("a") then
      self:_finish(self.text)
      return
    end
  end
  function screen:_finish(value)
    if self._done then return end
    self._done = true
    if self.game and self.game.stack and self.game.stack.pop then
      pcall(self.game.stack.pop, self.game.stack)
    end
    if type(value) == "string" then
      value = value:match("^%s*(.-)%s*$") or ""
      if value == "" then value = nil end
    end
    onDone(value)
  end
  function screen:draw()
    -- Minimal presentation; Theme may be unavailable headless.
    local ok, Font = pcall(require, "src.render.Font")
    if ok and Font and Font.draw then
      pcall(Font.draw, tostring(self.title), 8, 8)
      pcall(Font.draw, (self.text or "") .. "_", 8, 32)
      pcall(Font.draw, "A/Enter: OK  B/Esc: Cancel", 8, 56)
    end
  end
  return screen
end

function Input.setTestPrompt(fn)
  Input._testPrompt = fn
end

return Input
