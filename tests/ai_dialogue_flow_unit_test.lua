-- AI dialogue flow, memory, input path selection.
-- Run: luajit tests/ai_dialogue_flow_unit_test.lua
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

package.loaded["src.core.GameVersion"] = {
  get = function() return "red" end,
  generation = function() return 1 end,
  isYellow = function() return false end,
  isGold = function() return false end,
}

local presented = {}
local choices = {}
package.loaded["src.render.TextBox"] = {
  new = function(game, text, onDone, opts)
    presented[#presented + 1] = text
    if opts and opts.choice then
      choices[#choices + 1] = opts
      -- Auto-pick Talk
      opts.choice(true)
    elseif onDone then
      onDone()
    end
    return { text = text }
  end,
}

local modules = {}
local opts = {
  ai_dialogues = true, ai_provider = "local", ai_model = "local",
  ai_endpoint = "http://127.0.0.1:1234/v1", ai_memory = true,
}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end, error = function() end },
    options = { get = function(_, k) return opts[k] end },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local d = f:read("*a"); f:close(); return d
    end,
  },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  modules[name] = chunk(V)
  return modules[name]
end

local Memory = V.require("ai/memory")
local Dialogue = V.require("ai/dialogue")
local Input = V.require("ai/input")
local Ai = V.require("ai/init")

Memory.resetRam()

local game = {
  generation = 1,
  stack = {
    push = function(self, screen) self.top = screen end,
    pop = function(self) self.top = nil end,
  },
  save = { party = { { species = "BULBASAUR", level = 5 } } },
}
local ow = { map = { id = "PEWTER_CITY" }, game = game }
local npc = { def = { name = "Clerk", index = 2 } }

local d = Dialogue.new(V.mod, {})
d:setForceProvider("mock")

Input.setTestPrompt(function(mod, g, o, onDone)
  check(o.title ~= nil, "input has title")
  onDone("Where is the museum?")
  return "test"
end)

d:afterVanilla(game, ow, npc)
check(#choices >= 1, "Talk/Leave choice presented")

-- Process pending request ticks
for _ = 1, 5 do d:tick() end
check(#presented >= 1, "thinking or reply presented")

-- Memory recorded
local ctxId = V.require("ai/context_builder").npcIdentity(npc, "PEWTER_CITY")
local turns = Memory.getTurns(V.mod, game, ctxId)
check(#turns >= 2, "memory stored user+assistant turns")

Memory.clearAll(V.mod, game)
check(#Memory.getTurns(V.mod, game, ctxId) == 0, "memory reset")

-- Memory off
opts.ai_memory = false
Memory.append(V.mod, game, ctxId, "user", "hi")
check(#Memory.getTurns(V.mod, game, ctxId) == 0, "memory disabled skips store")

-- Input path: keyboard screen builder
local pathSeen
Input.setTestPrompt(nil)
Input._useKeyboardScreen = true
love = { keyboard = {} }
pathSeen = Input.prompt(V.mod, game, { title = "ASK WHAT?", maxLen = 40 }, function() end)
check(pathSeen == "keyboard", "keyboard path selected when love.keyboard present")

-- Controller/naming fallback
love = nil
Input._useKeyboardScreen = false
package.loaded["src.ui.NamingScreen"] = {
  new = function(g, o)
    check((o.maxLen or 0) >= 16, "naming maxLen elevated")
    return { naming = true }
  end,
}
pathSeen = Input.prompt(V.mod, game, { title = "ASK WHAT?", maxLen = 40 }, function() end)
check(pathSeen == "naming", "naming path for controller/mobile")

-- Dev probe
local ai = Ai.new(V.mod, {})
local finished
ai:devProbe({
  useMock = true,
  message = "test",
  onDone = function(ok, text) finished = { ok = ok, text = text } end,
})
for _ = 1, 4 do ai:tick() end
check(finished and finished.ok and finished.text == "Wilds AI OK", "dev probe Wilds AI OK")

print("ai_dialogue_flow_unit_test: " .. (failures == 0 and "PASS" or "FAIL"))
os.exit(failures == 0 and 0 or 1)
