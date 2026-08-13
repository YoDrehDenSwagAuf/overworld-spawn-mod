-- Gold runtime integration: the four real-game failures, plus Gen1 isolation.
-- These tests mock the CURRENT Gen1Recomp Gold World / OPTIONS / encounter.roll
-- shapes (src/world/gen2/World.lua, src/ui/gen2/OptionsMenu.lua). They are
-- UNIT TESTED engine-path checks, not a live ROM boot.
--
-- Run: lua tests/gen2_runtime_integration_unit_test.lua
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
  random_encounters = true,
  sprite_style = "followers",
  sprite_fade = "solid",
  follow_control = "trainer",
  trainer_trail = false,
  follower_count = 1,
  town_pokemon = true,
  overworld_catching = true,
  spawn_density = "normal",
  water_spawns = "swimming_sprites",
  cave_spawns = "reachable",
  enable_idle = true,
  enable_wander = true,
  enable_aggressive = true,
  enable_hidden = true,
  dev_overlay = false,
}

local ROUTE_29 = {
  rates = { MORN = 25, DAY = 25, NITE = 25 },
  slots = {
    DAY = {
      { species = "PIDGEY", level = 2 },
      { species = "RATTATA", level = 2 },
      { species = "PIDGEY", level = 3 },
      { species = "RATTATA", level = 3 },
      { species = "PIDGEY", level = 3 },
      { species = "RATTATA", level = 4 },
      { species = "PIDGEY", level = 4 },
    },
    MORN = {
      { species = "PIDGEY", level = 2 },
      { species = "RATTATA", level = 2 },
      { species = "PIDGEY", level = 3 },
      { species = "RATTATA", level = 3 },
      { species = "PIDGEY", level = 3 },
      { species = "RATTATA", level = 4 },
      { species = "PIDGEY", level = 4 },
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
}

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
    def = { environment = "ROUTE", label = "ROUTE 29" },
  },
  player = { cellX = 8, cellY = 8, facing = "up", px = 128, py = 128 },
  playerState = "normal",
  daytime = "DAY",
  entities = {},
  npcs = {},
  encounters = { grass = { ROUTE_29 = ROUTE_29 } },
  queueScript = function() return true end,
}

-- Gold World:rebuildPeople wipes entities, then restores npc guests.
function goldWorld:rebuildPeople()
  local guests = {}
  for _, npc in ipairs(self.npcs or {}) do
    guests[#guests + 1] = npc
  end
  self.npcs = {}
  self.entities = { self.player }
  for _, npc in ipairs(guests) do
    self.npcs[#self.npcs + 1] = npc
    self.entities[#self.entities + 1] = npc
  end
end

function goldWorld:drawPeople()
  local drawn = 0
  for _, npc in ipairs(self.npcs) do
    if npc.draw then
      npc:draw(-16, -16, 1)
      drawn = drawn + 1
    end
  end
  return drawn
end

function goldWorld:updatePeople()
  for _, npc in ipairs(self.npcs) do
    if npc.update then npc:update(self.map, self.entities) end
  end
end

local goldGame = {
  version = "gold",
  generation = 2,
  save = { party = { { species = "CHIKORITA", level = 5 } }, pokedex = nil },
  world = goldWorld,
  data = {
    pokemon = {
      PIDGEY = { name = "PIDGEY", dex = 16, index = 16 },
      RATTATA = { name = "RATTATA", dex = 19, index = 19 },
      HOOTHOOT = { name = "HOOTHOOT", dex = 163, index = 163 },
    },
    gen2Encounters = { grass = { ROUTE_29 = ROUTE_29 } },
  },
}

local wrappedFns = {}
local wrappedNames = {}
local events = {}
local screens = {}
local logLines = {}
local definedSchema = nil

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
    error = function(_, fmt, ...)
      logLines[#logLines + 1] = string.format(tostring(fmt), ...)
    end,
  },
  read = function(_, rel)
    return readFile(rel) or readFile("./" .. rel)
  end,
  find = function() return nil end,
  save = { get = function() return nil end, set = function() end },
  options = {
    define = function(_, schema) definedSchema = schema end,
    get = function(_, k) return optionStore[k] end,
    set = function(_, k, v) optionStore[k] = v end,
  },
  content = {
    sprites = {
      get = function() return nil end,
      register = function() end,
      patch = function() end,
    },
    pokemon = {
      get = function() return nil end,
      each = function() return function() return nil end end,
    },
    render_pipelines = { register = function() end },
    screens = {
      register = function(_, id, def) screens[id] = def end,
    },
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
      wrappedNames[#wrappedNames + 1] = name
      wrappedFns[name] = fn
      return function() end
    end,
  },
  ui = {
    ListMenu = {
      new = function(game, title, items, opts)
        return { title = title, items = items, opts = opts, close = function() end }
      end,
    },
    push = function() end,
    insertBefore = function(items, anchor, item)
      for i, it in ipairs(items) do
        if it.label == anchor then
          table.insert(items, i, item)
          return items
        end
      end
      table.insert(items, item)
      return items
    end,
  },
  exports = {},
  world = {
    game = goldGame,
    overworld = function() return goldWorld end,
    queueScript = function(_, rows) return true end,
  },
}

local chunk = assert(loadfile("main.lua"))
local entry = chunk()
local bootOk, bootErr = pcall(entry, mod)
check(bootOk, "Gold entry boots (" .. tostring(bootErr) .. ")")

local GameCompat = mod.exports.gameCompat
local logic = mod.exports.logic
local settingsMenus = mod.exports.settingsMenus

----------------------------------------------------------------
-- 1. SETTINGS: Gold OPTIONS (no MODS row) still gets Wilds rows
----------------------------------------------------------------
check(definedSchema ~= nil, "Mod Manager options schema defined")
check(settingsMenus ~= nil and settingsMenus._registered == true,
      "settingsMenus:register completed")
check(wrappedFns["ui.options.rows"] ~= nil, "ui.options.rows wrapped")

local goldOptions = {
  { label = "TEXT SPEED", key = "textSpeed" },
  { label = "BATTLE SCENE", key = "battleScene" },
  { label = "CANCEL", cancel = true },
}
local injected = wrappedFns["ui.options.rows"](
  function(_, rows) return rows end, goldGame, goldOptions)
local labels, cancelAt, wildsAt, randomAt, showAt = {}, nil, nil, nil, nil
for i, row in ipairs(injected) do
  labels[#labels + 1] = row.label
  if row.label == "CANCEL" then cancelAt = i end
  if row.label == "WILDS OF KANTO" then wildsAt = i end
  if row.label == "RANDOM ENC" then randomAt = i end
  if row.label == "SHOW WILD MONS" then showAt = i end
end
check(wildsAt ~= nil, "Gold OPTIONS has WILDS OF KANTO")
check(showAt ~= nil, "Gold OPTIONS has SHOW WILD MONS")
check(randomAt ~= nil, "Gold OPTIONS has RANDOM ENC")
check(cancelAt ~= nil and wildsAt < cancelAt,
      "Wilds rows appear BEFORE CANCEL (not after it)")
local wildsRow
for _, row in ipairs(injected) do
  if row.label == "WILDS OF KANTO" then wildsRow = row end
end
check(type(wildsRow.text) == "function" and wildsRow.text() == "OPEN",
      "Gold OPTIONS Wilds row has text() OPEN")
check(type(wildsRow.activate) == "function", "Gold OPTIONS Wilds row activates")

-- ListMenu missing must still wrap OPTIONS (root cause of skipped register).
do
  local optionRows
  local menusMod = {
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end },
    options = { get = function(_, k) return optionStore[k] end },
    hooks = {
      wrap = function(_, name, fn)
        if name == "ui.options.rows" then
          optionRows = fn(function(_, rows) return rows end, {}, {
            { label = "TEXT SPEED" }, { label = "CANCEL", cancel = true },
          })
        end
      end,
    },
    content = {}, -- no screens
    ui = {
      insertBefore = function(items, anchor, item)
        for i, it in ipairs(items) do
          if it.label == anchor then
            table.insert(items, i, item)
            return items
          end
        end
        table.insert(items, item)
        return items
      end,
    },
    world = { game = goldGame },
  }
  local modules = {}
  local V = { mod = menusMod, path = "." }
  function V.require(name)
    if modules[name] ~= nil then return modules[name] end
    local value = assert(loadfile("lib/" .. name .. ".lua"))(V)
    modules[name] = value
    return value
  end
  modules.debug_log = {
    warn = function() end, info = function() end, error = function() end, debug = function() end,
  }
  local SettingsMenus = V.require("settings_menus")
  local menus = SettingsMenus.new(menusMod, {}, nil, nil)
  menus:register()
  check(menus._registered == true, "register succeeds without ListMenu/screens")
  local found
  for _, row in ipairs(optionRows or {}) do
    if row.label == "WILDS OF KANTO" or row.label == "SHOW WILD MONS" then
      found = true
    end
  end
  check(found, "OPTIONS wrap still injects Wilds rows without ListMenu")
end

----------------------------------------------------------------
-- 2. POKEDEX INDEPENDENCE
----------------------------------------------------------------
goldGame.save.pokedex = nil
goldGame.save.pokedexReceived = false
local encDef = logic:_encDef("ROUTE_29", goldGame)
check(encDef ~= nil and encDef.grass ~= nil, "Route 29 encDef without Pokédex")
eq(#encDef.grass.slots, 7, "Route 29 has 7 grass slots")
eq(encDef.grass.slots[1].species, "PIDGEY", "first DAY slot is Pidgey (Gen1 species)")
check(logic.requiresPokedex() == false, "requiresPokedex is false")

----------------------------------------------------------------
-- 3/4. RANDOM ENC OFF/ON uses Gold encounter.roll (tables, ctx)
----------------------------------------------------------------
check(wrappedFns["encounter.roll"] ~= nil, "encounter.roll wrap installed")
local vanillaCalls = 0
local function goldVanilla(tables, ctx)
  vanillaCalls = vanillaCalls + 1
  return { species = "PIDGEY", level = 2, kind = ctx.kind }
end
local goldCtx = {
  mapId = "ROUTE_29",
  terrain = "grass",
  kind = "wild",
  daytime = "DAY",
  tables = goldWorld.encounters,
}

optionStore.random_encounters = false
vanillaCalls = 0
local suppressed = wrappedFns["encounter.roll"](goldVanilla, goldWorld.encounters, goldCtx)
eq(suppressed, nil, "Random Enc OFF returns nil from Gold encounter.roll")
eq(vanillaCalls, 0, "Random Enc OFF does not run Gold vanilla picker")

optionStore.random_encounters = true
vanillaCalls = 0
local allowed = wrappedFns["encounter.roll"](goldVanilla, goldWorld.encounters, goldCtx)
check(allowed ~= nil and allowed.species == "PIDGEY",
      "Random Enc ON runs original Gold encounter path")
eq(vanillaCalls, 1, "Random Enc ON calls vanilla once")

-- Water terrain is also suppressed when Random Enc is OFF.
optionStore.random_encounters = false
vanillaCalls = 0
local waterCtx = {
  mapId = "ROUTE_29", terrain = "water", kind = "wild", daytime = "DAY",
}
local waterSuppressed = wrappedFns["encounter.roll"](
  goldVanilla, goldWorld.encounters, waterCtx)
eq(waterSuppressed, nil, "Random Enc OFF suppresses Gold water rolls")

optionStore.random_encounters = true

----------------------------------------------------------------
-- 5. ROUTE 29 encDef non-empty from kind-first world.encounters
----------------------------------------------------------------
eq(encDef._source, "gen2Encounters", "encounter source is gen2Encounters")
check(encDef.grass.rate and encDef.grass.rate > 0, "grass rate > 0")

----------------------------------------------------------------
-- 6/7. SPAWN inserts into Gold npcs (the draw/rebuild container)
----------------------------------------------------------------
local poseSprite = {
  def = { frames = 1 },
  resolveImage = function() return true end,
  draw = function() end,
}
local entity = {
  id = "wilds_pidgey_route29",
  species = "PIDGEY",
  level = 2,
  mapId = "ROUTE_29",
  cellX = 4,
  cellY = 2,
  px = 64,
  py = 32,
  facing = "down",
  overworldWildSpawn = true,
  visibleSprite = true,
  sprite = poseSprite,
  pose = function(self)
    return self.sprite, self.px, self.py, self.facing, 0, false
  end,
}
function entity:draw(camX, camY)
  self._gen1Draw = { camX, camY }
end
function entity:update(dt)
  self._updatedDt = dt
end

goldWorld.npcs = {}
goldWorld.entities = {}
local container = GameCompat.attachWildEntity(goldWorld, entity, goldGame)
eq(container, "npcs+entities", "Gold attach uses npcs+entities")
check(goldWorld.npcs[1] == entity, "Gold npcs contains the Wild")
check(goldWorld.entities[1] == entity, "Gold entities also contains the Wild")

goldWorld:rebuildPeople()
check(goldWorld.npcs[1] == entity, "rebuildPeople keeps Wild as guest NPC")
local stillInEntities = false
for _, e in ipairs(goldWorld.entities) do
  if e == entity then stillInEntities = true end
end
check(stillInEntities, "rebuildPeople copies guest Wild back into entities")

local drawn = goldWorld:drawPeople()
eq(drawn, 1, "Gold drawPeople draws the Wild from npcs")
check(entity._lastGoldDraw ~= nil and entity._lastGoldDraw.scale == 1,
      "Gold draw adapter received (ox, oy, scale)")
check(entity._gen1Draw ~= nil and entity._gen1Draw[1] == 0,
      "adapter maps Gold draw onto Entity:draw(0,0) inside transform")

----------------------------------------------------------------
-- 8. ROAM: Gold updatePeople does not steal dt; Movement still assigns a step
----------------------------------------------------------------
goldWorld:updatePeople()
eq(entity._updatedDt, nil, "Gold World:updatePeople does not call Entity.update(dt)")

local Movement = mod.exports.lib.require("movement")
Movement.init(entity, 4, 2, "down")
local px0, py0 = entity.px, entity.py
Movement.beginStep(entity, 4, 3, { duration = 0.2 })
Movement.update(entity, 0.1)
check(entity.py ~= py0 or entity.px ~= px0 or entity.moving == true,
      "Movement.update assigns/changes a roam step")

----------------------------------------------------------------
-- 9. MAP EXIT cleans Gold npcs + entities
----------------------------------------------------------------
logic.entities[entity.id] = entity
logic:_detachFromWorld(entity)
local npcLeft, entLeft = false, false
for _, e in ipairs(goldWorld.npcs) do if e == entity then npcLeft = true end end
for _, e in ipairs(goldWorld.entities) do if e == entity then entLeft = true end end
check(not npcLeft, "map cleanup removes Wild from Gold npcs")
check(not entLeft, "map cleanup removes Wild from Gold entities")

----------------------------------------------------------------
-- 10. GEN1 attach stays entities-only
----------------------------------------------------------------
package.loaded["src.core.GameVersion"] = {
  get = function() return "red" end,
  isYellow = function() return false end,
  isGold = function() return false end,
  generation = function() return 1 end,
}
local gen1Ow = { map = { id = "ROUTE_1" }, player = { cellX = 5, cellY = 5 }, entities = {}, npcs = {} }
local gen1Entity = { id = "wilds_pidgey_r1", mapId = "ROUTE_1", sprite = poseSprite }
local gen1Game = { version = "red", generation = 1 }
local gen1Container = GameCompat.attachWildEntity(gen1Ow, gen1Entity, gen1Game)
eq(gen1Container, "entities", "Gen1 attach stays on ow.entities")
eq(#gen1Ow.npcs, 0, "Gen1 does not insert Wilds into npcs")
eq(gen1Ow.entities[1], gen1Entity, "Gen1 Wild is in ow.entities")
check(gen1Entity._wildsGoldAdapted ~= true, "Gen1 entity is not Gold-adapted")

-- Restore Gold GameVersion for any later asserts
package.loaded["src.core.GameVersion"] = {
  get = function() return "gold" end,
  isYellow = function() return false end,
  isGold = function() return true end,
  generation = function() return 2 end,
}

local sawMapLog = false
for _, line in ipairs(logLines) do
  if tostring(line):find("%[Wilds%]%[Gen2%]", 1) then sawMapLog = true end
end
-- Snapshot logs on map enter; fire one now.
if events["map.entered"] then
  for _, fn in ipairs(events["map.entered"]) do
    pcall(fn, { mapId = "ROUTE_29", map = goldWorld.map })
  end
end
for _, line in ipairs(logLines) do
  if tostring(line):find("%[Wilds%]%[Gen2%]", 1) then sawMapLog = true end
end
check(sawMapLog, "Gen2 map-enter diagnostic was emitted")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll Gen2 runtime integration tests passed.")
print("UNIT TESTED: settings, pokedex, encounter.roll, Route 29 data,")
print("  Gold npc attach/draw/rebuild, roam primitive, cleanup, Gen1 isolation.")
print("ACTUAL ENGINE PATH VERIFIED: Gold World/OptionsMenu/encounter.roll shapes")
print("  from Gen1Recomp src (not a live ROM session).")
