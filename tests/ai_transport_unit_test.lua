-- AI transport + mock OpenAI-compatible probe ("Wilds AI OK").
-- Run: luajit tests/ai_transport_unit_test.lua
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

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end, error = function() end },
    options = {
      _d = { ai_dialogues = true, ai_provider = "local", ai_model = "local",
             ai_endpoint = "http://127.0.0.1:1234/v1", ai_memory = true },
      get = function(self, k) return self._d[k] end,
    },
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
  local value = chunk(V)
  modules[name] = value
  return value
end

local Transport = V.require("ai/transport")
local Ai = V.require("ai/init")
local JsonEncode = V.require("ai/json_encode")
local Prompt = V.require("ai/prompt")

-- Mock transport proving request shape + reply extraction path
local jobs = {}
local nextId = 0
Transport.setMock({
  start = function(opts)
    check(opts.method == "POST", "mock start uses POST")
    check(type(opts.url) == "string" and opts.url:find("chat/completions", 1, true),
          "mock url is chat/completions")
    check(type(opts.body) == "string" and opts.body:find("Wilds AI OK", 1, true)
            or opts.body:find('"test"', 1, true),
          "mock body includes probe content")
    nextId = nextId + 1
    local id = nextId
    jobs[id] = { pending = 1, opts = opts }
    return { mockId = id }
  end,
  poll = function(handle)
    local j = jobs[handle.mockId]
    if not j then return { status = "error", err = "missing" } end
    if j.pending > 0 then
      j.pending = j.pending - 1
      return { status = "pending" }
    end
    local body = JsonEncode.encode({
      choices = { { message = { content = "Wilds AI OK" } } },
    })
    return { status = "ok", body = body, code = 200 }
  end,
  release = function() end,
  cancel = function() end,
})

check(Transport.available(V.mod) == true, "transport available with mock")

local AiMod = Ai.new(V.mod, {})
local doneOk, doneText
AiMod:devProbe({
  useMock = false, -- use real provider path with mocked transport
  message = "test",
  onDone = function(ok, text)
    doneOk, doneText = ok, text
  end,
})
-- Force local provider through Compat with mock transport:
-- Override: use Providers local via startChat
local Compat = V.require("ai/providers/openai_compatible")
local handle = assert(Compat.startChat(V.mod, {
  context = {
    npcName = "Probe",
    localKnowledge = "Reply with exactly: Wilds AI OK",
  },
  message = "test",
  model = "local",
}))
local st = Compat.pollChat(V.mod, handle)
if st.status == "pending" then st = Compat.pollChat(V.mod, handle) end
check(st.status == "success", "compat poll success")
check(st.text == "Wilds AI OK", "exact Wilds AI OK reply")

-- Mock provider path
local Mock = V.require("ai/providers/mock")
local mh = assert(select(1, Mock.startRequest(V.mod, { _testExact = "Wilds AI OK" }, "test")))
local ms = Mock.poll(V.mod, mh)
if ms.status == "pending" then ms = Mock.poll(V.mod, mh) end
check(ms.status == "success" and ms.text == "Wilds AI OK", "mock provider Wilds AI OK")

local text, err = Prompt.sanitizeReply("run function() dofile('x') end please")
check(text == nil, "sanitize rejects code-like reply: " .. tostring(err))

Transport.clearMock()
print("ai_transport_unit_test: " .. (failures == 0 and "PASS" or "FAIL"))
os.exit(failures == 0 and 0 or 1)
