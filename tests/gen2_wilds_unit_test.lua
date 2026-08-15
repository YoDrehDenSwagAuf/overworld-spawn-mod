-- Shared Wild entity + Gold battle path (ROM-free).
-- Run: lua tests/gen2_wilds_unit_test.lua
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

package.loaded["src.core.GameVersion"] = {
  get = function() return "gold" end,
  isYellow = function() return false end,
  isGold = function() return true end,
  generation = function() return 2 end,
}

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
local logLines = {}
local battles = {}
local contentSprites = {}

local party = { { species = "CHIKORITA", level = 5 } }
local goldWorld
goldWorld = {
  map = {
    id = "ROUTE_29",
    widthCells = 12,
    heightCells = 8,
    isWaterCell = function() return false end,
    isGrassCell = function(_, x, y) return y == 2 and x >= 2 and x <= 9 end,
    isWalkableCell = function() return true end,
    inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 12 and y < 8 end,
    warpAtCell = function() return nil end,
  },
  player = { cellX = 8, cellY = 8, facing = "up" },
  playerState = "normal",
  daytime = "DAY",
  entities = {},
  npcs = {},
  queueScript = function(_, rows)
    battles[#battles + 1] = rows
    return true
  end,
}

local goldGame = {
  save = { party = party, playerState = "normal" },
  world = goldWorld,
  data = {
    pokemon = {
      SENTRET = { name = "SENTRET", dex = 161, index = 161 },
      PIDGEY = { name = "PIDGEY", dex = 16, index = 16 },
      CHIKORITA = { name = "CHIKORITA", dex = 152, index = 152 },
    },
    gen2Encounters = {
      grass = {
        ROUTE_29 = {
          rates = { MORN = 25, DAY = 25, NITE = 25 },
          slots = {
            DAY = {
              { species = "SENTRET", level = 3 },
              { species = "PIDGEY", level = 2 },
              { species = "SENTRET", level = 3 },
              { species = "PIDGEY", level = 3 },
              { species = "RATTATA", level = 3 },
              { species = "PIDGEY", level = 4 },
              { species = "SENTRET", level = 4 },
            },
            MORN = {
              { species = "SENTRET", level = 3 },
              { species = "PIDGEY", level = 2 },
              { species = "SENTRET", level = 3 },
              { species = "PIDGEY", level = 3 },
              { species = "RATTATA", level = 3 },
              { species = "PIDGEY", level = 4 },
              { species = "SENTRET", level = 4 },
            },
            NITE = {
              { species = "HOOTHOOT", level = 2 },
              { species = "RATTATA", level = 2 },
              { species = "HOOTHOOT", level = 3 },
              { species = "RATTATA", level = 3 },
              { species = "HOOTHOOT", level = 4 },
              { species = "RATTATA", level = 4 },
              { species = "HOOTHOOT", level = 4 },
            },
          },
        },
      },
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
  save = { get = function() return nil end, set = function() end },
  options = {
    define = function() end,
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
      each = function() return function() return nil end end,
    },
    render_pipelines = { register = function() end },
    screens = { register = function() end },
  },
  assets = { path = function(_, rel) return rel end },
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
  world = {
    game = goldGame,
    overworld = function() return goldWorld end,
    queueScript = function(_, rows)
      battles[#battles + 1] = rows
      return true
    end,
  },
}

local chunk, err = loadfile("main.lua")
check(chunk ~= nil, "main.lua loads (" .. tostring(err) .. ")")
if not chunk then os.exit(1) end
local ok, entry = pcall(chunk)
check(ok, "main.lua chunk runs (" .. tostring(entry) .. ")")
check(type(entry) == "function", "main.lua returns entry function")
local bootOk, bootErr = pcall(entry, mod)
check(bootOk, "Wilds Gold entry does not throw (" .. tostring(bootErr) .. ")")

local GameCompat = mod.exports.gameCompat
check(GameCompat ~= nil, "exports.gameCompat")
eq(GameCompat.supportsFeature("encounters", mod, goldGame), true, "encounters on")
eq(GameCompat.supportsFeature("followers", mod, goldGame), true, "followers on")
eq(GameCompat.supportsFeature("catching", mod, goldGame), true, "catching on")
eq(GameCompat.supportsFeature("ambient", mod, goldGame), true, "ambient on")
eq(GameCompat.supportsFeature("townPokemon", mod, goldGame), true, "townPokemon on")
eq(GameCompat.supportsFeature("safari", mod, goldGame), false, "safari off")

local function wrappedHook(name)
  for _, h in ipairs(wrapped) do
    if h == name then return true end
  end
  return false
end
check(wrappedHook("encounter.roll"), "encounter.roll wrapped for Gold wilds")
check(wrappedHook("movement.collision"), "movement.collision wrapped for Gold wilds")
check(not wrappedHook("pikachu_follower"), "Yellow Pikachu hook NOT wrapped")
check(wrappedHook("ui.party.submenu"), "follower party submenu wrapped")

eq(mod.exports.follower._installed, true, "follower hooks install on Gold")
eq(mod.exports.catching._registered, true, "catching registers on Gold")
eq(mod.exports.ambient._installed, true, "ambient / town Pokémon installed")
eq(mod.exports.behaviorTick._registered, true, "shared WILDS AI pipeline registered")

local logic = mod.exports.logic
check(logic ~= nil and type(logic._startBattle) == "function",
      "shared SpawnLogic is the Gold wild entity manager")
check(type(logic.trySpawn) == "function", "shared trySpawn reused")
check(type(logic.onCollision) == "function", "shared onCollision reused")

-- Normalized Route 29 candidates come from the Gen2 provider, not Kanto tables.
local encDef = logic:_encDef("ROUTE_29", goldGame)
check(encDef ~= nil and encDef.grass ~= nil, "Route 29 encDef from Gen2 provider")
eq(encDef._source, "gen2Encounters", "encDef source is gen2Encounters")
eq(encDef.grass.slots[1].species, "SENTRET", "DAY Route 29 first slot Sentret")
eq(encDef.grass.slots[1].level, 3, "DAY Route 29 first slot level 3")

-- Exact-once Gold battle: visible Sentret Lv3 → start_battle wild SENTRET 3.
local Config = nil
do
  -- SpawnLogic already loaded Config through the mod; read state constants
  -- from the live record shape used in production.
end
local record = {
  id = "wilds_of_kanto_entity_test_sentret",
  mapId = "ROUTE_29",
  x = 4,
  y = 2,
  species = "SENTRET",
  level = 3,
  state = "available",
  behavior = "IDLE_LOOK",
}
-- Match Config.STATE.AVAILABLE used by SpawnLogic.
if logic.spawns then
  -- Discover the live AVAILABLE constant from a dummy if needed.
end
local available = record.state
-- SpawnLogic compares against Config.STATE.AVAILABLE. Mirror the production
-- token by reading it off a spawned-shaped record after poking Config via
-- the loaded module: "available" is Config.STATE.AVAILABLE in lib/config.lua.
record.state = "available"
logic.spawns = logic.spawns or {}
logic.entities = logic.entities or {}
logic.byMap = logic.byMap or {}
logic.spawns[record.id] = record
logic.byMap["ROUTE_29"] = { record.id }

local started = logic:_startBattle(record)
check(started == true, "Gold wild battle starts from shared _startBattle")
eq(#battles, 1, "Gold queueScript called once")
local row = battles[1] and battles[1][1]
check(row ~= nil, "queued script has a start_battle row")
eq(row[1], "start_battle", "script op is start_battle")
eq(row[2], "wild", "script kind is wild")
eq(row[3], "SENTRET", "battle species matches overworld Sentret")
eq(row[4], 3, "battle level matches overworld level 3")
check(logic.pendingBattle ~= nil, "pendingBattle blocks a second trigger")

local started2 = logic:_startBattle(record)
check(started2 == false, "second battle trigger is rejected")
eq(#battles, 1, "still exactly one Gold battle")

-- Collision uses the shared entity lookup (Gold does not set ctx.entity).
battles = {}
logic.pendingBattle = nil
record.state = "available"
logic.spawns[record.id] = record
local blocked = logic:onCollision(false, {
  reason = "entity",
  mover = goldWorld.player,
  toX = 4,
  toY = 2,
})
eq(blocked, false, "collision consumes the walk")
eq(#battles, 1, "collision starts exactly one Gold battle")
eq(battles[1][1][3], "SENTRET", "collision battle species is Sentret")
eq(battles[1][1][4], 3, "collision battle level is 3")

-- Town Pokémon provider is separate from grass encounters.
local AmbientPokemon
for _, line in ipairs(logLines) do
  if tostring(line):find("experimental Gen2 wild encounters", 1, true) then
    AmbientPokemon = true
  end
end
check(AmbientPokemon, "logs experimental Gen2 wild encounters")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll Gen2 shared-wild / Gold battle tests passed.")
