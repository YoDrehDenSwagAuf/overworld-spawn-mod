-- Gold boot: Wilds entry must load without installing Gen1 gameplay.
-- Run: lua tests/gold_boot_unit_test.lua
-- Optional: GEN1RECOMP_ROOT=/path/to/gen1recomp (uses real FieldMoves / GameVersion)
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
  if type(env) == "string" and env ~= "" and readFile(env .. "/src/core/GameVersion.lua") then
    return env
  end
  for _, root in ipairs({ ".deps/gen1recomp", "/tmp/gen1recomp-src" }) do
    if readFile(root .. "/src/core/GameVersion.lua") then return root end
  end
  return nil
end

local root = engineRoot()
if root then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
  package.loaded["src.core.GameVersion"] = nil
  local GameVersion = require("src.core.GameVersion")
  GameVersion.set("gold")
  eq(GameVersion.get(), "gold", "GameVersion.get() → gold")
  eq(GameVersion.generation(), 2, "GameVersion.generation() → 2")
else
  package.loaded["src.core.GameVersion"] = {
    get = function() return "gold" end,
    isYellow = function() return false end,
    isGold = function() return true end,
    generation = function() return 2 end,
  }
  print("skip  live GameVersion (no Gen1Recomp tree; using mock gold)")
end

local optionStore = {
  enabled = true,
  sprite_style = "followers",
  sprite_fade = "solid",
  follow_control = "trainer",
  trainer_trail = false,
  follower_count = 1,
  town_pokemon = true,
  overworld_catching = true,
}
local wrapped = {}
local events = {}
local definedSchema = nil
local logLines = {}

local contentSprites = {}
local pokemonEach = function() return function() return nil end end

local party = { { species = "CHIKORITA", level = 5 } }
local goldGame = {
  save = { party = party, playerState = "normal" },
  world = {
    map = { id = "ROUTE_29", isWaterCell = function() return false end },
    player = { cellX = 8, cellY = 8 },
    playerState = "normal",
  },
  data = {
    pokemon = {
      SENTRET = { name = "SENTRET", dex = 161, index = 161 },
      CHIKORITA = { name = "CHIKORITA", dex = 152, index = 152 },
    },
  },
}

local mod = {
  path = ".",
  id = "overworld_wild_spawns",
  game = goldGame,
  log = {
    info = function(_, fmt, ...)
      logLines[#logLines + 1] = string.format(tostring(fmt), ...)
    end,
    warn = function(_, fmt, ...)
      logLines[#logLines + 1] = string.format(tostring(fmt), ...)
    end,
  },
  read = function(_, rel)
    return readFile(rel) or readFile("./" .. rel)
  end,
  find = function() return nil end,
  save = {
    get = function() return nil end,
    set = function() end,
  },
  options = {
    define = function(_, schema) definedSchema = schema end,
    get = function(_, k) return optionStore[k] end,
    set = function(_, k, v) optionStore[k] = v end,
  },
  content = {
    sprites = {
      get = function(_, id) return contentSprites[id] end,
      register = function(_, id, def) contentSprites[id] = def end,
      patch = function(_, id, def) contentSprites[id] = def end,
    },
    pokemon = {
      get = function() return nil end,
      each = pokemonEach,
    },
    render_pipelines = {
      register = function() end,
    },
    screens = {
      register = function() end,
    },
  },
  assets = {
    path = function(_, rel) return rel end,
  },
  events = {
    on = function(_, name, fn)
      events[name] = events[name] or {}
      events[name][#events[name] + 1] = fn
    end,
  },
  hooks = {
    wrap = function(_, name, fn)
      wrapped[#wrapped + 1] = name
      return function() end
    end,
  },
  ui = {},
  exports = {},
  world = { game = goldGame },
}

local chunk, err = loadfile("main.lua")
check(chunk ~= nil, "main.lua loads (" .. tostring(err) .. ")")
if not chunk then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end

local ok, entry = pcall(chunk)
check(ok, "main.lua chunk runs (" .. tostring(entry) .. ")")
check(type(entry) == "function", "main.lua returns entry function")

local bootOk, bootErr = pcall(entry, mod)
check(bootOk, "Wilds Gold entry does not throw (" .. tostring(bootErr) .. ")")

local GameCompat = mod.exports.gameCompat
check(GameCompat ~= nil, "exports.gameCompat")
if GameCompat then
  eq(GameCompat.generation(mod, goldGame), 2, "GameCompat.generation() → 2")
  check(GameCompat.current(mod, goldGame) == GameCompat.Gen2,
        "GameCompat.current() → Gen2")
  eq(GameCompat.isSupported(mod, goldGame), true, "GameCompat.isSupported() → true")
  eq(GameCompat.supportsFeature("encounters", mod, goldGame), false,
     "encounters capability false")
  eq(GameCompat.supportsFeature("followers", mod, goldGame), false,
     "followers capability false")
  eq(GameCompat.supportsFeature("catching", mod, goldGame), false,
     "catching capability false")
  eq(GameCompat.supportsFeature("ambient", mod, goldGame), false,
     "ambient capability false")
  eq(GameCompat.supportsFeature("safari", mod, goldGame), false,
     "safari capability false")
  eq(GameCompat.supportsFeature("townPokemon", mod, goldGame), false,
     "townPokemon capability false")
  eq(GameCompat.speciesId("SENTRET", goldGame, mod), 161, "SENTRET → 161")
  eq(GameCompat.currentMapId(goldGame), "ROUTE_29", "current map ROUTE_29")
end

local function wrappedHook(name)
  for _, h in ipairs(wrapped) do
    if h == name then return true end
  end
  return false
end

eq(wrappedHook("encounter.roll"), false, "encounter.roll NOT wrapped")
eq(wrappedHook("movement.collision"), false, "movement.collision NOT wrapped")
eq(wrappedHook("pikachu_follower"), false, "Yellow Pikachu hook NOT wrapped")
eq(wrappedHook("ui.party.submenu"), false, "follower party submenu NOT wrapped")

local follower = mod.exports.follower
check(follower ~= nil, "follower object exists (construct only)")
if follower then
  eq(follower._installed, false, "follower hooks NOT installed")
  eq(follower._supported, false, "follower capability false at construct")
  if follower.lifecycle then
    eq(follower.lifecycle._installed, false, "follower lifecycle hooks NOT installed")
  end
  if follower.control then
    check(follower.control._installed ~= true, "ControlEngine NOT installed")
  end
end

local catching = mod.exports.catching
check(catching ~= nil, "catching object exists (construct only)")
if catching then
  eq(catching._registered, false, "catching hooks NOT registered")
end

local ambient = mod.exports.ambient
check(ambient ~= nil, "ambient object exists (construct only)")
if ambient then
  eq(ambient._installed, false, "ambient / town Pokémon NOT installed")
end

local behaviorTick = mod.exports.behaviorTick
check(behaviorTick ~= nil, "behaviorTick object exists (construct only)")
if behaviorTick then
  eq(behaviorTick._registered, false, "WILDS AI pipeline NOT registered")
end

check(definedSchema ~= nil, "options schema defined (menu can load)")
check(type(mod.exports.handleOptionsChanged) == "function",
      "options-changed handler exported")
if type(mod.exports.handleOptionsChanged) == "function" then
  local optOk, optErr = pcall(mod.exports.handleOptionsChanged, {
    mod = mod.id, key = "enabled", value = true,
  })
  check(optOk, "options change on Gold does not throw (" .. tostring(optErr) .. ")")
end

local sawGoldLog = false
for _, line in ipairs(logLines) do
  if tostring(line):find("experimental Gen2 foundation", 1, true) then
    sawGoldLog = true
  end
end
check(sawGoldLog, "logs experimental Gold foundation once")

local function fire(name, ev)
  local list = events[name]
  if not list then return true, nil end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, ev or {})
    if not ok then return false, err end
  end
  return true, nil
end

local mapOk, mapErr = fire("map.entered", { map = goldGame.world.map })
check(mapOk, "map.entered on Gold is a no-op (" .. tostring(mapErr) .. ")")
local readyOk, readyErr = fire("game.ready", {})
check(readyOk, "game.ready on Gold does not throw (" .. tostring(readyErr) .. ")")
local modsOk, modsErr = fire("mods.loaded", {})
check(modsOk, "mods.loaded on Gold does not throw (" .. tostring(modsErr) .. ")")

eq(wrappedHook("encounter.roll"), false, "map.entered still did not wrap encounter.roll")
eq(follower._installed, false, "map.entered still did not install followers")
eq(ambient._installed, false, "map.entered still did not install ambient")
eq(catching._registered, false, "map.entered still did not register catching")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll Gold boot tests passed.")
