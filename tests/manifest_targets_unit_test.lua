-- Manifest target semantics vs current Gen1Recomp ModTargets.
-- Does not duplicate engine logic: when a Gen1Recomp tree is present it
-- requires src.mods.ModTargets and checks labels. Otherwise it only asserts
-- that Wilds' production manifest is still Gen1-only.
--
-- Run: lua tests/manifest_targets_unit_test.lua
-- Optional: GEN1RECOMP_ROOT=/path/to/gen1recomp
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

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function engineRoot()
  local env = os.getenv("GEN1RECOMP_ROOT")
  if type(env) == "string" and env ~= "" and readFile(env .. "/src/mods/ModTargets.lua") then
    return env
  end
  for _, root in ipairs({ ".deps/gen1recomp", "/tmp/gen1recomp-src" }) do
    if readFile(root .. "/src/mods/ModTargets.lua") then return root end
  end
  return nil
end

----------------------------------------------------------------
-- Production Wilds manifest: Gen1-only until Gen2 adapter is boot-safe
----------------------------------------------------------------
do
  local raw = assert(readFile("manifest.json"), "manifest.json missing")
  check(not raw:find('"games"', 1, true),
        "no games key (legacy Gen1 = omit games)")
  check(not raw:find("gen2compat", 1, true),
        "no gen2compat (legacy flag; games is the precise field)")
  check(raw:find('"api": 2', 1, true) ~= nil or raw:find('"api":2', 1, true) ~= nil,
        "manifest api 2")
  check(raw:find(">=0.0.0-0 <2.0.0", 1, true) ~= nil,
        "game_version still >=0.0.0-0 <2.0.0")
end

----------------------------------------------------------------
-- Engine ModTargets labels (when a Gen1Recomp checkout is available)
----------------------------------------------------------------
local root = engineRoot()
if not root then
  print("skip  ModTargets labels (no Gen1Recomp tree; set GEN1RECOMP_ROOT)")
else
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
  -- Isolate from any GameVersion mock other tests may have left behind.
  package.loaded["src.core.GameVersion"] = nil
  package.loaded["src.mods.ModTargets"] = nil
  local ModTargets = require("src.mods.ModTargets")

  eq(table.concat(ModTargets.expand("gen1"), ","), "red,blue,yellow",
     "gen1 expands to red,blue,yellow")
  eq(table.concat(ModTargets.expand("gen2"), ","), "gold",
     "gen2 expands to gold (current engine)")
  eq(ModTargets.expand("silver"), nil,
     "silver is unknown until the engine has a cache for it")

  local none = { }
  eq(ModTargets.label(none), "Gen 1",
     "manifest with no games → Gen 1")

  local gen1 = { games = ModTargets.normalize({ "gen1" }) }
  eq(ModTargets.label(gen1), "Gen 1",
     'games: ["gen1"] → Gen 1')

  local both = { games = ModTargets.normalize({ "gen1", "gen2" }) }
  eq(ModTargets.label(both), "Gen 1+2",
     'games: ["gen1", "gen2"] → Gen 1+2')

  local all = { games = ModTargets.normalize({ "all" }) }
  eq(ModTargets.label(all), "Gen 1+2",
     'games: ["all"] → Gen 1+2')

  local gen2 = { games = ModTargets.normalize({ "gen2" }) }
  eq(ModTargets.label(gen2), "Gen 2",
     'games: ["gen2"] → Gen 2')

  print("ok  ModTargets sourced from " .. root)
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll manifest target tests passed.")
