-- DEV-only PerfStats: disabled when Config.debug is off; snapshot fields.
-- Run: lua tests/perf_stats_unit_test.lua
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

local debugOn = false
local modules = {}
local V = {
  mod = { path = ".", log = { info = function() end }, find = function() return nil end },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  if name == "config" then
    local cfg = {
      debug = function() return debugOn end,
      DEFAULTS = {},
    }
    modules[name] = cfg
    return cfg
  end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

local PerfStats = V.require("perf_stats")
local mod = { log = { info = function() end } }

debugOn = false
local p = PerfStats.new(mod)
local start = p:beginFrame()
check(start == nil, "beginFrame nil when debug off")
p:count("aiTicks", 5)
check(p.aiTicks == 0, "count no-op when disabled")
p:endFrame(nil)
check(p.frames == 0, "endFrame no-op when disabled")

debugOn = true
p = PerfStats.new(mod)
start = p:beginFrame()
check(type(start) == "number", "beginFrame returns time when debug on")
p:count("aiTicks", 3)
p:count("occupancyRebuilds", 2)
p:addMs("msAi", start)
p:sampleCounts({ a = 1, b = 2 }, 4)
check(p.aiTicks == 3, "aiTicks counted")
check(p.occupancyRebuilds == 2, "occupancyRebuilds counted")
check(p.entitiesSample == 2, "entity sample")
check(p.followersSample == 4, "follower sample")
p:endFrame(start)
check(p.frames == 1, "frame counted")
-- Force window flush
p._windowStart = (os.clock() - 2)
p:beginFrame()
p:endFrame(os.clock())
check(p:lastSnapshot() ~= nil, "snapshot after window")
local snap = p:lastSnapshot()
check(snap.aiTicks ~= nil, "snapshot has aiTicks")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("ALL PASS")
