-- Wilds game / generation compatibility facade.
--
-- Shared Wilds systems should ask this module instead of assuming Gen 1.
-- Gen1 is the full gameplay adapter. Gen2 is a Gold adapter with wild
-- overworld encounters and one curated town Pokémon; followers / catching /
-- safari stay off via capabilities.
--
-- Canonical engine source of truth (Gen1Recomp src/core/GameVersion.lua):
--   GameVersion.get()            → "red"|"blue"|"yellow"|"gold"|…
--   GameVersion.generation(id)   → 1 or 2  (absent row field reads as 1)
--   GameVersion.info(id)
--
-- GameVersion is a zero-require module, loaded during love.conf, and
-- GameVersion.set() runs in bootGame() BEFORE Loader:load / mod entry.
-- A real engine boot therefore never hits the "module missing" path.
-- That path exists only for standalone Wilds unit tests.
--
-- Production manifest claims:
--   "games": ["gen1", "gen2"]  → ModTargets.label = "Gen 1+2"
local V = ...

local Gen1 = V.require("game_compat/gen1")
local Gen2 = V.require("game_compat/gen2")

local GameCompat = {}
GameCompat.Gen1 = Gen1
GameCompat.Gen2 = Gen2

-- Official manifest tokens (production manifest.json uses these).
GameCompat.GAMES = { "gen1", "gen2" }
GameCompat.FUTURE_GAMES = GameCompat.GAMES -- alias kept for older tests/docs

local GEN1_VERSIONS = {
  red = true,
  blue = true,
  yellow = true,
}

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function looksLikeGame(t)
  if type(t) ~= "table" then return false end
  if t.save or t.data or t.overworld or t.player then return true end
  if t.generation ~= nil or t.version ~= nil or t.gameVersion ~= nil then
    return true
  end
  return false
end

-- Accept both GameCompat.generation(mod, game) and GameCompat.generation(game).
local function splitModGame(modOrGame, game)
  if game ~= nil then
    return modOrGame, game
  end
  if looksLikeGame(modOrGame) then
    return nil, modOrGame
  end
  return modOrGame, nil
end

local function readEngineVersion(GV, game)
  if GV then
    if type(GV.isYellow) == "function" then
      local ok, yellow = pcall(GV.isYellow)
      if ok and yellow == true then return "yellow" end
    end
    if type(GV.get) == "function" then
      local ok, v = pcall(GV.get)
      if ok and type(v) == "string" and v ~= "" then
        return string.lower(v)
      end
    end
  end
  if type(game) == "table" then
    local v = game.version or game.gameVersion
    if type(v) == "string" and v ~= "" then
      return string.lower(v)
    end
  end
  return nil
end

-- Engine generation number, or nil when the running title is unknown.
-- Returns: gen, versionId, source
--   source = "engine" | "declared" | "missing-module"
local function detectGeneration(game)
  local GV = tryRequire("src.core.GameVersion")
  local ver = readEngineVersion(GV, game)

  if GV then
    -- Module present: never assume Gen1. Gold boots with GameVersion already
    -- set; treating a missing get() as Gen1 would install Gen1 hooks on Gen2.
    if type(GV.generation) == "function" then
      local ok, gen = pcall(function()
        if ver then return GV.generation(ver) end
        return GV.generation()
      end)
      if ok and type(gen) == "number" then
        return gen, ver, "engine"
      end
    end
    if ver and GEN1_VERSIONS[ver] then
      return 1, ver, "engine"
    end
    if type(game) == "table" then
      local declared = tonumber(game.generation)
      if declared then
        return declared, ver, "declared"
      end
    end
    -- Explicit unknown version, or GameVersion present but unreadable.
    return nil, ver, "engine"
  end

  -- Module absent: standalone unit tests / no engine on package.path.
  -- Cannot happen on a real Gen1Recomp boot (GameVersion loads at love.conf).
  if type(game) == "table" then
    local declared = tonumber(game.generation)
    if declared then
      if declared == 1 then return 1, ver, "declared" end
      if declared == 2 then return 2, ver, "declared" end
      return nil, ver, "declared"
    end
  end
  if ver and GEN1_VERSIONS[ver] then return 1, ver, "missing-module" end
  if ver then return nil, ver, "missing-module" end
  return 1, nil, "missing-module"
end

--- Engine version string: "red" | "blue" | "yellow" | "gold" | other | nil.
function GameCompat.gameVersion(game)
  return readEngineVersion(tryRequire("src.core.GameVersion"), game)
end

--- National-dex generation currently running, or nil if unknown/unsupported.
-- Red / Blue / Yellow → 1. Gold (engine GameVersion.generation) → 2.
-- Explicit unknown versions → nil (never guessed as 1).
function GameCompat.generation(mod, game)
  local _, g = splitModGame(mod, game)
  local gen = detectGeneration(g)
  return gen
end

function GameCompat.isGen1(mod, game)
  return GameCompat.generation(mod, game) == 1
end

function GameCompat.isGen2(mod, game)
  return GameCompat.generation(mod, game) == 2
end

--- Active adapter, or nil when this generation has no supported adapter.
function GameCompat.current(mod, game)
  local gen = GameCompat.generation(mod, game)
  if gen == 1 and Gen1.supported then return Gen1 end
  if gen == 2 and Gen2.supported then return Gen2 end
  return nil
end

--- True when a supported adapter is active (Gen1 or boot-safe Gen2).
-- This is NOT permission to install every Wilds subsystem. Use
-- GameCompat.supportsFeature(feature, mod, game) for gameplay gates.
function GameCompat.isSupported(mod, game)
  local adapter = GameCompat.current(mod, game)
  return adapter ~= nil and adapter.supported == true
end

--- Adapter capability: "encounters", "followers", "catching", "ambient", …
function GameCompat.supportsFeature(feature, mod, game)
  if type(feature) ~= "string" or feature == "" then return false end
  local adapter = GameCompat.current(mod, game)
  if not (adapter and adapter.supported == true) then return false end
  local caps = adapter.capabilities
  if type(caps) ~= "table" then return false end
  return caps[feature] == true
end

function GameCompat.speciesId(species, game, mod)
  local adapter = GameCompat.current(mod, game)
  if not (adapter and adapter.speciesId) then return nil end
  return adapter.speciesId(species, game, mod or V.mod)
end

function GameCompat.isSurfing(game, ow)
  local adapter = GameCompat.current(nil, game)
  if not (adapter and adapter.isSurfing) then return false end
  return adapter.isSurfing(game, ow) == true
end

function GameCompat.isWaterCell(map, x, y, game)
  local adapter = GameCompat.current(nil, game)
  if adapter and adapter.isWaterCell then
    return adapter.isWaterCell(map, x, y) == true
  end
  if not (map and type(map.isWaterCell) == "function") then return false end
  local ok, water = pcall(map.isWaterCell, map, x, y)
  return ok and water == true
end

function GameCompat.party(game)
  local adapter = GameCompat.current(nil, game)
  if not (adapter and adapter.party) then return nil end
  return adapter.party(game)
end

function GameCompat.currentMapId(game, ow)
  local adapter = GameCompat.current(nil, game)
  if not (adapter and adapter.currentMapId) then return nil end
  return adapter.currentMapId(game, ow)
end

--- Normalized per-map encounter table for the active adapter.
function GameCompat.encountersForMap(game, mapId, ctx)
  local adapter = GameCompat.current(nil, game)
  if adapter and adapter.encountersForMap then
    return adapter.encountersForMap(game, mapId, ctx)
  end
  if not game or not game.data or type(game.data.encounters) ~= "table" then
    return nil
  end
  return game.data.encounters[mapId]
end

--- Weighted species/level pick for the active adapter.
function GameCompat.pickEncounter(game, mapId, kind, ctx)
  local adapter = GameCompat.current(nil, game)
  if adapter and adapter.pickEncounter then
    return adapter.pickEncounter(game, mapId, kind, ctx)
  end
  return nil
end

--- Start a wild battle for the visible overworld entity (exact species/level).
function GameCompat.startWildBattle(world, species, level, game)
  local adapter = GameCompat.current(nil, game)
  if adapter and adapter.startWildBattle then
    return adapter.startWildBattle(world, species, level)
  end
  if world and type(world.queueScript) == "function" then
    return world:queueScript({
      { "start_battle", "wild", species, tonumber(level) or 5 },
    })
  end
  return nil, "no wild battle adapter"
end

-- Live world object used by visible Wilds (map / player / entities / npcs).
-- Gen1: WorldAPI:overworld() → OverworldState.
-- Gen2: WorldAPI:overworld() → game.world (only once world.map exists).
-- Does NOT assign game.overworld = game.world; the two are not identical.
function GameCompat.liveOverworld(mod, game)
  game = game or (mod and (mod.game or (mod.world and mod.world.game)))
  local api = mod and mod.world
  if api then
    if type(api.overworld) == "function" then
      local ok, ow = pcall(api.overworld, api)
      if ok and ow and ow.map and ow.player then return ow end
    elseif type(api.overworld) == "table" then
      local ow = api.overworld
      if ow.map and ow.player then return ow end
    end
  end
  if game and game.world and game.world.map and game.world.player then
    return game.world
  end
  if game and game.overworld and game.overworld.map and game.overworld.player then
    return game.overworld
  end
  return nil
end

local function listHas(list, entity)
  if type(list) ~= "table" or not entity then return false end
  for _, e in ipairs(list) do
    if e == entity or (e and entity.id and e.id == entity.id) then
      return true
    end
  end
  return false
end

local function listInsert(list, entity)
  if type(list) ~= "table" or not entity then return end
  if listHas(list, entity) then return end
  table.insert(list, entity)
end

local function listRemove(list, entity)
  if type(list) ~= "table" or not entity then return end
  for i = #list, 1, -1 do
    local e = list[i]
    if e == entity or (e and entity.id and e.id == entity.id) then
      table.remove(list, i)
    end
  end
end

-- Gold World:drawPeople / updatePeople / rebuildPeople guests live on npcs.
-- Gen1 OverworldState draws ow.entities. Wilds Entity:draw(camX, camY) is
-- NOT the Gold NPC:draw(ox, oy, scale) signature, so Gen2 gets a thin wrap.
function GameCompat.adaptWildEntity(entity, game)
  if not entity or entity._wildsGoldAdapted then return entity end
  if not GameCompat.isGen2(nil, game) then return entity end
  entity._wildsGoldAdapted = true
  entity._wildsGoldGuest = true
  local origDraw = entity.draw
  local origUpdate = entity.update
  function entity:draw(ox, oy, scale)
    if scale ~= nil then
      -- Gold World:drawPeople: ox/oy are already camera-translated screen
      -- offsets; SpriteRenderer then draws at world px/py inside the transform.
      if love and love.graphics and love.graphics.push then
        love.graphics.push()
        love.graphics.translate(ox or 0, oy or 0)
        love.graphics.scale(scale, scale)
        if origDraw then origDraw(self, 0, 0) end
        love.graphics.pop()
      elseif origDraw then
        origDraw(self, 0, 0)
      end
      self._lastGoldDraw = { ox = ox, oy = oy, scale = scale }
      return
    end
    if origDraw then return origDraw(self, ox, oy) end
  end
  function entity:update(a, b)
    -- Gold World:updatePeople calls npc:update(map, entities). BehaviorTick
    -- is the Wilds AI source of truth and calls Entity.update(dt).
    if type(a) == "table" then
      return
    end
    if origUpdate then return origUpdate(self, a, b) end
  end
  return entity
end

--- Insert a visible Wild into the container Gold/Gen1 actually draws.
-- Returns the container name used: "npcs+entities" | "entities" | "logical_only".
function GameCompat.attachWildEntity(ow, entity, game)
  if not ow or not entity then return "none" end
  ow.entities = ow.entities or {}
  listInsert(ow.entities, entity)
  if GameCompat.isGen2(nil, game) then
    GameCompat.adaptWildEntity(entity, game)
    ow.npcs = ow.npcs or {}
    -- rebuildPeople keeps npcs that are not map objects as guests. Entities
    -- alone are wiped every zoom / time-of-day rebuild and are never drawn.
    if entity.mapId == nil and ow.map and ow.map.id then
      entity.mapId = ow.map.id
    end
    listInsert(ow.npcs, entity)
    entity.worldContainer = "npcs+entities"
    return "npcs+entities"
  end
  entity.worldContainer = "entities"
  return "entities"
end

function GameCompat.detachWildEntity(ow, entity)
  if not ow or not entity then return end
  listRemove(ow.entities, entity)
  listRemove(ow.npcs, entity)
end

function GameCompat.entityInDrawList(ow, entity, game)
  if not ow or not entity then return false end
  if GameCompat.isGen2(nil, game) then
    return listHas(ow.npcs, entity)
  end
  return listHas(ow.entities, entity)
end

-- One-line DEV snapshot for Gold map enter. Never per-frame.
function GameCompat.logGoldRuntime(mod, info)
  if not (mod and mod.log and type(mod.log.info) == "function") then return end
  info = info or {}
  local parts = {
    "generation=" .. tostring(info.generation or 2),
    "game=" .. tostring(info.gameVersion or "gold"),
    "world=" .. tostring(info.worldType or "game.world"),
    "map=" .. tostring(info.mapId or "?"),
    "encounterSource=" .. tostring(info.encounterSource or "none"),
    "grassSlots=" .. tostring(info.grassSlots or 0),
    "tod=" .. tostring(info.timeOfDay or "?"),
    "wilds=" .. tostring(info.wildsEnabled),
    "randomEnc=" .. tostring(info.randomEnc),
    "activeWilds=" .. tostring(info.activeWilds or 0),
    "container=" .. tostring(info.entityContainer or "?"),
  }
  pcall(function()
    mod.log:info("[Wilds][Gen2] %s", table.concat(parts, " "))
  end)
end

return GameCompat
