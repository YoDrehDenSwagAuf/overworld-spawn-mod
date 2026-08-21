-- Manifest target semantics vs current Gen1Recomp ModTargets.
-- Does not duplicate engine logic: when a Gen1Recomp tree is present it
-- requires src.mods.ModTargets and checks labels against the production
-- Wilds manifest (`games`: gen1+gen2 → "Gen 1+2").
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
-- Production Wilds manifest: Gen1 + Gen2 (canonical `games` field)
----------------------------------------------------------------
do
  local raw = assert(readFile("manifest.json"), "manifest.json missing")
  check(raw:find('"games"', 1, true) ~= nil, "games key present")
  check(raw:find('"gen1"', 1, true) ~= nil, "games includes gen1")
  check(raw:find('"gen2"', 1, true) ~= nil, "games includes gen2")
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
  -- Engine ORDER: gold then silver (GameVersion.ORDER / generationVersions).
  eq(table.concat(ModTargets.expand("gen2"), ","), "gold,silver",
     "gen2 expands to gold,silver (current engine)")
  eq(table.concat(ModTargets.expand("silver"), ","), "silver",
     "silver is a recognized Gen2 game target")

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

  eq(ModTargets.chip(both), "GEN 1+2",
     'games: ["gen1", "gen2"] chip → GEN 1+2')

  -- Canonical engine generation API (do not duplicate in Wilds).
  package.loaded["src.core.GameVersion"] = nil
  local GameVersion = require("src.core.GameVersion")
  eq(GameVersion.generation("red"), 1, "engine generation(red) == 1")
  eq(GameVersion.generation("blue"), 1, "engine generation(blue) == 1")
  eq(GameVersion.generation("yellow"), 1, "engine generation(yellow) == 1")
  eq(GameVersion.generation("gold"), 2, "engine generation(gold) == 2")
  eq(GameVersion.generation("silver"), 2, "engine generation(silver) == 2")
  check(type(GameVersion.VERSIONS.silver) == "table",
        "engine silver version definition exists")
  eq(GameVersion.VERSIONS.silver.id, "silver",
     "engine silver version id is silver")
  eq(GameVersion.VERSIONS.silver.generation, 2,
     "engine silver version generation is 2")
  eq(GameVersion.VERSIONS.silver.cachePrefix, "silver/",
     "engine silver has cache prefix silver/")

  local prodGames = ModTargets.normalize({ "gen1", "gen2" })
  local prod = { games = prodGames }
  eq(table.concat(prodGames, ","), "red,blue,yellow,gold,silver",
     "production normalize(gen1,gen2) → red,blue,yellow,gold,silver")
  eq(ModTargets.label(prod), "Gen 1+2", "production games label Gen 1+2")
  eq(ModTargets.chip(prod), "GEN 1+2", "production games chip GEN 1+2")
  eq(ModTargets.supports(prod, "red"), true, "production supports red")
  eq(ModTargets.supports(prod, "blue"), true, "production supports blue")
  eq(ModTargets.supports(prod, "yellow"), true, "production supports yellow")
  eq(ModTargets.supports(prod, "gold"), true, "production supports gold")
  eq(ModTargets.supports(prod, "silver"), true, "production supports silver")

  print("ok  ModTargets sourced from " .. root)
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll manifest target tests passed.")
