-- AI provider abstraction + local/OpenAI/custom configuration.
-- Run: luajit tests/ai_provider_unit_test.lua
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
local opts = {
  ai_dialogues = true,
  ai_provider = "local",
  ai_model = "local",
  ai_endpoint = "http://127.0.0.1:1234/v1",
  ai_memory = true,
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

local Transport = V.require("ai/transport")
local AiConfig = V.require("ai/config")
local Providers = V.require("ai/providers/init")
local JsonEncode = V.require("ai/json_encode")

local tmpSecrets = os.tmpname()
AiConfig.setSecretsPathForTests(tmpSecrets)
AiConfig.saveSecrets({ openai_api_key = "sk-test-key-123456", custom_api_key = "" })

Transport.setMock({
  start = function(opts)
    return { id = 1, opts = opts }
  end,
  poll = function(handle)
    return {
      status = "ok",
      code = 200,
      body = JsonEncode.encode({
        choices = { { message = { content = "Nice day for a walk!" } } },
      }),
    }
  end,
  release = function() end,
})

local localP = Providers.resolve(V.mod, "local")
check(localP.id == "local", "local provider id")
check(localP.isConfigured(V.mod) == true, "local configured")

local openai = Providers.resolve(V.mod, "openai")
check(openai.isConfigured(V.mod) == true, "openai configured with key")

AiConfig.saveSecrets({ openai_api_key = "", custom_api_key = "" })
AiConfig.resetCache()
check(openai.isConfigured(V.mod) == false, "openai unconfigured without key")

opts.ai_provider = "custom"
opts.ai_endpoint = "https://example.com/v1"
local custom = Providers.resolve(V.mod, "custom")
check(custom.isConfigured(V.mod) == true, "custom configured by endpoint")

-- Timeout / HTTP error paths
Transport.setMock({
  start = function() return { id = 2 } end,
  poll = function() return { status = "error", err = "connection refused" } end,
  release = function() end,
})
local Compat = V.require("ai/providers/openai_compatible")
local h = assert(select(1, Compat.startChat(V.mod, {
  context = { npcName = "A" }, message = "hi",
})))
local st = Compat.pollChat(V.mod, h)
check(st.status == "error", "http error surfaces as error")

Transport.setMock({
  start = function() return { id = 3 } end,
  poll = function() return { status = "ok", body = "{not-json", code = 200 } end,
  release = function() end,
})
h = assert(select(1, Compat.startChat(V.mod, { context = { npcName = "A" }, message = "hi" })))
st = Compat.pollChat(V.mod, h)
check(st.status == "error", "malformed json is error")

Transport.setMock({
  start = function() return { id = 4 } end,
  poll = function()
    return {
      status = "ok", code = 200,
      body = JsonEncode.encode({ choices = { { message = { content = "" } } } }),
    }
  end,
  release = function() end,
})
h = assert(select(1, Compat.startChat(V.mod, { context = { npcName = "A" }, message = "hi" })))
st = Compat.pollChat(V.mod, h)
check(st.status == "error", "empty reply is error")

Transport.clearMock()
os.remove(tmpSecrets)
print("ai_provider_unit_test: " .. (failures == 0 and "PASS" or "FAIL"))
os.exit(failures == 0 and 0 or 1)
