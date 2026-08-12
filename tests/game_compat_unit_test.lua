-- GameCompat generation / species / party / surf unit tests.
-- Run: lua tests/game_compat_unit_test.lua
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

local modules = {}
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    content = { pokemon = { get = function() return nil end } },
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

modules.config = {
  DEFAULTS = { grass_occlusion_px = 6, min_sprite_size = 16 },
  get = function() return nil end,
  useAnimatedOverworldSprites = function() return true end,
  debug = function() return false end,
}
modules.debug_log = {
  info = function() end, warn = function() end, error = function() end, debug = function() end,
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16, size = function() return 16, 16 end }

-- Mirrors Gen1Recomp src/core/GameVersion.lua: get() + generation(id).
-- Red/Blue/Yellow have no generation field (reads as 1). Gold is 2.
local function setEngineVersion(v)
  if v == nil then
    package.loaded["src.core.GameVersion"] = nil
    return
  end
  local id = string.lower(tostring(v))
  package.loaded["src.core.GameVersion"] = {
    get = function() return id end,
    isYellow = function() return id == "yellow" end,
    isGold = function() return id == "gold" end,
    generation = function(which)
      which = which or id
      if which == "gold" or which == "silver" or which == "crystal" then
        return 2
      end
      if which == "red" or which == "blue" or which == "yellow" then
        return 1
      end
      error("unknown GameVersion id: " .. tostring(which))
    end,
  }
end

local GameCompat = V.require("game_compat")
local SpriteService = V.require("follower/sprite_service")

----------------------------------------------------------------
-- Red / Blue / Yellow detection
----------------------------------------------------------------
do
  setEngineVersion("red")
  eq(GameCompat.generation(nil, {}), 1, "Red generation == 1")
  eq(GameCompat.isSupported(nil, {}), true, "Red supported == true")
  eq(GameCompat.isGen1(nil, {}), true, "Red isGen1")
  eq(GameCompat.isGen2(nil, {}), false, "Red is not Gen2")
  eq(GameCompat.gameVersion({}), "red", "Red gameVersion")
  check(GameCompat.current(nil, {}) == GameCompat.Gen1, "Red uses Gen1 adapter")
end

do
  setEngineVersion("blue")
  eq(GameCompat.generation(nil, {}), 1, "Blue generation == 1")
  eq(GameCompat.isSupported(nil, {}), true, "Blue supported == true")
  eq(GameCompat.isGen1(nil, {}), true, "Blue isGen1")
  eq(GameCompat.gameVersion({}), "blue", "Blue gameVersion")
  check(GameCompat.current(nil, {}) == GameCompat.Gen1, "Blue uses Gen1 adapter")
end

do
  setEngineVersion("yellow")
  eq(GameCompat.generation(nil, {}), 1, "Yellow generation == 1")
  eq(GameCompat.isSupported(nil, {}), true, "Yellow supported == true")
  eq(GameCompat.isGen1(nil, {}), true, "Yellow isGen1")
  eq(GameCompat.gameVersion({}), "yellow", "Yellow gameVersion")
  eq(GameCompat.gameVersion({}), "yellow", "Yellow via isYellow/get")
  check(GameCompat.current(nil, {}) == GameCompat.Gen1, "Yellow uses Gen1 adapter")
end

do
  setEngineVersion("RED")
  eq(GameCompat.generation(nil, {}), 1, "RED uppercase still Gen1")
  eq(GameCompat.isSupported({}), true, "isSupported(game) form")
end

----------------------------------------------------------------
-- Mock Gen2 (Gold): generation 2, adapter still unsupported
----------------------------------------------------------------
do
  setEngineVersion("gold")
  local ok, gen = pcall(GameCompat.generation, nil, {})
  check(ok, "gold generation does not crash")
  eq(gen, 2, "gold generation == 2")
  eq(GameCompat.isGen2(nil, {}), true, "gold isGen2")
  eq(GameCompat.isGen1(nil, {}), false, "gold is not Gen1")
  eq(GameCompat.isSupported(nil, {}), false, "gold supported == false (stub)")
  eq(GameCompat.current(nil, {}), nil, "gold has no adapter while stub unsupported")
  eq(GameCompat.speciesId("RATTATA", {}, V.mod), nil,
     "gold does not use Gen1 species mapping")
  eq(GameCompat.party({ save = { party = { 1 } } }), nil,
     "gold does not expose Gen1 party")
  eq(GameCompat.isSurfing({}, { player = { surfing = true } }), false,
     "gold does not use Gen1 surf detection")
end

----------------------------------------------------------------
-- Unknown explicit version: not classified as Gen1
----------------------------------------------------------------
do
  setEngineVersion("unknown")
  local ok, gen = pcall(GameCompat.generation, nil, {})
  check(ok, "unknown generation does not crash")
  eq(gen, nil, "unknown generation == nil")
  eq(GameCompat.isSupported(nil, {}), false, "unknown supported == false")
  eq(GameCompat.current(nil, {}), nil, "unknown has no adapter")
end

do
  setEngineVersion("silver")
  eq(GameCompat.generation(nil, {}), 2, "silver mock generation == 2")
  eq(GameCompat.isSupported(nil, {}), false, "silver unsupported (no adapter)")
end

do
  setEngineVersion(nil)
  eq(GameCompat.isSupported({ generation = 2 }), false,
     "explicit generation=2 unsupported")
  eq(GameCompat.generation({ generation = 2 }), nil, "generation=2 → nil")
  local ok = pcall(function()
    GameCompat.speciesId("MEW", { generation = 2 }, V.mod)
    GameCompat.isSurfing({ generation = 2 }, { player = { surfing = true } })
    GameCompat.party({ generation = 2, save = { party = {} } })
  end)
  check(ok, "unsupported accessors do not crash")
end

----------------------------------------------------------------
-- Early load: GameVersion present cannot classify Gen2 as Gen1
----------------------------------------------------------------
do
  -- Engine module exists (Gold already selected) even if game object is nil.
  setEngineVersion("gold")
  eq(GameCompat.generation(nil, nil), 2, "early-load gold is Gen2, not Gen1")
  eq(GameCompat.isSupported(nil, nil), false, "early-load gold not supported")
  check(GameCompat.current(nil, nil) ~= GameCompat.Gen1,
        "early-load gold does not select Gen1 adapter")
end

----------------------------------------------------------------
-- Missing GameVersion module: standalone tests only (not a real engine boot)
----------------------------------------------------------------
do
  setEngineVersion(nil)
  eq(GameCompat.generation(nil, {}), 1, "missing module defaults to Gen1 for tests")
  eq(GameCompat.isSupported(nil, nil), true, "missing module is supported")
end

----------------------------------------------------------------
-- Species lookup
----------------------------------------------------------------
do
  setEngineVersion("red")
  eq(GameCompat.speciesId("RATTATA", {}, V.mod), 19, "RATTATA → 19")
  eq(GameCompat.speciesId("ONIX", {}, V.mod), 95, "ONIX → 95")
  eq(GameCompat.speciesId("MEW", {}, V.mod), 151, "MEW → 151")
  eq(GameCompat.speciesId("rattata", {}, V.mod), 19, "lowercase rattata → 19")
  eq(GameCompat.speciesId(19, {}, V.mod), 19, "numeric 19 preserved")
  eq(GameCompat.speciesId("19", {}, V.mod), 19, "numeric string 19 preserved")
  eq(GameCompat.speciesId(151, {}, V.mod), 151, "numeric MEW preserved")
  eq(GameCompat.speciesId(0, {}, V.mod), nil, "species 0 is invalid")
  eq(GameCompat.speciesId(-1, {}, V.mod), nil, "negative species invalid")
  eq(GameCompat.speciesId(nil, {}, V.mod), nil, "nil species → nil")
  eq(GameCompat.speciesId("", {}, V.mod), nil, "empty species → nil")
  eq(GameCompat.speciesId("NOTAPOKEMON", {}, V.mod), nil, "unknown name → nil")
  eq(GameCompat.speciesId({}, {}, V.mod), nil, "table species → nil")
end

do
  -- Engine resolver wins when dex is present.
  setEngineVersion("blue")
  local game = {
    data = { pokemon = { CHARMELEON = { name = "Glutexo", dex = 5 } } },
  }
  eq(GameCompat.speciesId("CHARMELEON", game, V.mod), 5,
     "engine dex for CHARMELEON")
  eq(GameCompat.speciesId("Glutexo", game, V.mod), nil,
     "localized name alone must not resolve")
end

do
  -- SpriteService.dexOf is a GameCompat wrapper (mapping still works).
  setEngineVersion("yellow")
  local svc = SpriteService.new(V.mod, {})
  eq(svc:dexOf("RATTATA"), 19, "sprite_service RATTATA → 19")
  eq(svc:dexOf("ONIX"), 95, "sprite_service ONIX → 95")
  eq(svc:dexOf("MEW"), 151, "sprite_service MEW → 151")
  eq(svc:dexOf(25), 25, "sprite_service numeric preserved")
end

----------------------------------------------------------------
-- Party accessor: same object as game.save.party
----------------------------------------------------------------
do
  setEngineVersion("red")
  local party = { { species = "PIKACHU", hp = 20 } }
  local game = { save = { party = party } }
  check(GameCompat.party(game) == party, "party returns same table object")
  eq(GameCompat.party({ save = {} }), nil, "missing party → nil")
  eq(GameCompat.party(nil), nil, "nil game party → nil")
end

----------------------------------------------------------------
-- Surfing: same result as previous ControlEngine / water-compat checks
----------------------------------------------------------------
do
  setEngineVersion("red")
  eq(GameCompat.isSurfing({}, { player = { surfing = true } }), true,
     "player.surfing == true")
  eq(GameCompat.isSurfing({}, { player = { isSurfing = true } }), true,
     "player.isSurfing == true")
  eq(GameCompat.isSurfing({}, { player = { surface = "WATER" } }), true,
     "player.surface WATER")
  eq(GameCompat.isSurfing({}, { player = { surface = "water" } }), true,
     "player.surface water")
  eq(GameCompat.isSurfing({ player = { surfing = true } }, { player = {} }), true,
     "game.player.surfing == true")
  eq(GameCompat.isSurfing({}, { player = { surfing = false } }), false,
     "not surfing")
  eq(GameCompat.isSurfing({}, nil), false, "nil ow not surfing")
  local map = {
    isWaterCell = function(_, x, y) return x == 3 and y == 4 end,
  }
  eq(GameCompat.isSurfing({}, {
    map = map,
    player = { surfing = false, cellX = 3, cellY = 4 },
  }), true, "water-cell fallback while standing in water")
  eq(GameCompat.isSurfing({}, {
    map = map,
    player = { surfing = false, cellX = 0, cellY = 0 },
  }), false, "land cell is not surfing")
end

----------------------------------------------------------------
-- Water cell: same result as map:isWaterCell
----------------------------------------------------------------
do
  local map = {
    isWaterCell = function(_, x, y) return x == 1 and y == 2 end,
  }
  eq(GameCompat.isWaterCell(map, 1, 2), true, "water cell true")
  eq(GameCompat.isWaterCell(map, 0, 0), false, "water cell false")
  eq(GameCompat.isWaterCell(nil, 1, 2), false, "nil map")
  eq(GameCompat.isWaterCell({}, 1, 2), false, "map without isWaterCell")
  local boom = {
    isWaterCell = function() error("bad map") end,
  }
  eq(GameCompat.isWaterCell(boom, 0, 0), false, "isWaterCell error → false")
end

----------------------------------------------------------------
-- Current map id
----------------------------------------------------------------
do
  setEngineVersion("blue")
  eq(GameCompat.currentMapId({}, { map = { id = "PALLET_TOWN" } }),
     "PALLET_TOWN", "currentMapId from ow.map.id")
  eq(GameCompat.currentMapId({ overworld = { map = { id = 3 } } }, nil),
     3, "currentMapId from game.overworld")
  eq(GameCompat.currentMapId({}, {}), nil, "missing map id")
end

----------------------------------------------------------------
-- Gen2 stub does not claim support
----------------------------------------------------------------
do
  eq(GameCompat.Gen2.supported, false, "Gen2 stub supported == false")
  check(GameCompat.Gen2.speciesId == nil, "Gen2 stub has no species API")
  check(GameCompat.Gen2.isSurfing == nil, "Gen2 stub has no surf API")
  check(GameCompat.FUTURE_GAMES[1] == "gen1"
        and GameCompat.FUTURE_GAMES[2] == "gen2",
        "documented future games tokens")
end

----------------------------------------------------------------
-- Gen1 adapter owns the 151 cap (True Size / diagnostic slots)
----------------------------------------------------------------
do
  setEngineVersion("red")
  eq(GameCompat.Gen1.MAX_SPECIES, 151, "Gen1.MAX_SPECIES == 151")
  local SpeciesGeometry = V.require("species_geometry")
  eq(SpeciesGeometry.normalizeDex(1), 1, "normalizeDex 1")
  eq(SpeciesGeometry.normalizeDex(151), 151, "normalizeDex MEW 151")
  eq(SpeciesGeometry.normalizeDex(152), nil, "normalizeDex 152 is not Gen1")
  eq(SpeciesGeometry.normalizeDex(251), nil, "normalizeDex 251 is not Gen1")
  eq(SpeciesGeometry.normalizeDex(0), nil, "normalizeDex 0 invalid")
end

----------------------------------------------------------------
-- Production manifest stays Gen1-only (STATE A)
----------------------------------------------------------------
do
  local f = assert(io.open("manifest.json", "rb"))
  local raw = f:read("*a")
  f:close()
  check(not raw:find('"games"', 1, true),
        "production manifest has no games key yet")
  check(not raw:find("gen2compat", 1, true),
        "production manifest has no gen2compat key")
  check(raw:find(">=0.0.0-0 <2.0.0", 1, true) ~= nil,
        "game_version range unchanged")
end

----------------------------------------------------------------
-- main.lua boot gate: unsupported generations skip Gen1 hooks
----------------------------------------------------------------
do
  local f = assert(io.open("main.lua", "rb"))
  local raw = f:read("*a")
  f:close()
  check(raw:find("GameCompat.isSupported", 1, true) ~= nil,
        "main.lua uses GameCompat.isSupported")
  check(raw:find("if not gen1GameplayEnabled()", 1, true) ~= nil,
        "main.lua gates map/world handlers on gen1GameplayEnabled")
  check(raw:find("if gen1GameplayEnabled() then", 1, true) ~= nil,
        "main.lua gates install / pipeline sync on gen1GameplayEnabled")
  local ready = raw:find('mod.events:on("game.ready"', 1, true)
  check(ready ~= nil, "main.lua has game.ready handler")
  if ready then
    local afterReady = raw:sub(ready, ready + 2500)
    check(afterReady:find("if gen1GameplayEnabled() then", 1, true) ~= nil,
          "game.ready re-asserts catching/AI pipelines only when supported")
  end
end

----------------------------------------------------------------
-- Example future manifest is not the production file
----------------------------------------------------------------
do
  local example = io.open("docs/analysis/future-manifest-games.example.json", "rb")
  check(example ~= nil, "future games example exists")
  if example then
    local raw = example:read("*a")
    example:close()
    check(raw:find('"games"', 1, true) ~= nil, "example contains games")
    check(raw:find('"gen1"', 1, true) ~= nil and raw:find('"gen2"', 1, true) ~= nil,
          'example games tokens are gen1 and gen2')
  end
  local prod = assert(io.open("manifest.json", "rb"))
  local prodRaw = prod:read("*a")
  prod:close()
  check(not prodRaw:find('"games"', 1, true),
        "example was not copied into production manifest")
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll GameCompat tests passed.")
