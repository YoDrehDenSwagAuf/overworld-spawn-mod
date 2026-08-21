-- AI config, secrets redaction, disabled noop.
-- Run: luajit tests/ai_config_secrets_unit_test.lua
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
local opts = { ai_dialogues = false, ai_provider = "local", ai_model = "local",
  ai_endpoint = "http://127.0.0.1:1234/v1", ai_memory = true }
local logs = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = {
      info = function(_, fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end,
      warn = function(_, fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end,
      error = function(_, fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end,
    },
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

local AiConfig = V.require("ai/config")
local AiLog = V.require("ai/log")
local schema = assert(loadfile("options.lua"))()

local secretKeys = 0
for _, row in ipairs(schema) do
  local k = row.key or ""
  if k:find("api_key", 1, true) or k:find("apikey", 1, true) or k:find("secret", 1, true) then
    secretKeys = secretKeys + 1
  end
end
check(secretKeys == 0, "options schema has no api key / secret fields")

check(AiConfig.enabled(V.mod) == false, "AI disabled by default option")

local tmp = os.tmpname()
AiConfig.setSecretsPathForTests(tmp)
check(AiConfig.saveSecrets({ openai_api_key = "sk-abcdefghijklmnopqrstuvwxyz" }) == true,
      "secrets save")
AiConfig.resetCache()
local s = AiConfig.loadSecrets()
check(s.openai_api_key:find("sk-", 1, true), "secrets load")

local red = AiConfig.redact(s.openai_api_key)
check(not red:find("abcdefgh", 1, true), "redact hides key body")

AiLog.warn(V.mod, "Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz leaked")
local joined = table.concat(logs, "\n")
check(not joined:find("sk-abcdefgh", 1, true), "logs scrub bearer/sk tokens")
check(joined:find("Authorization: ***", 1, true) or joined:find("Bearer ***", 1, true),
      "authorization redacted in logs")

local diag = AiConfig.diagnostics(V.mod)
check(diag.hasOpenAiKey == true, "diagnostics reports key presence")
check(diag.openai_api_key == nil, "diagnostics omits raw key field")

-- Disabled dialogue eligible path
local Dialogue = V.require("ai/dialogue")
local d = Dialogue.new(V.mod, {})
local ok, reason = d:eligible({}, {}, { def = { name = "Youngster" } })
check(ok == false and reason == "disabled", "disabled AI is ineligible")

os.remove(tmp)
print("ai_config_secrets_unit_test: " .. (failures == 0 and "PASS" or "FAIL"))
os.exit(failures == 0 and 0 or 1)
