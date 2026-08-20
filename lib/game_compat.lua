-- Wilds game / generation compatibility facade.
--
-- Shared Wilds systems should ask this module instead of assuming Gen 1.
-- Gen1 is the full gameplay adapter. Gen2 is a Gold adapter with wild
-- overworld encounters, curated town Pokémon, shared followers, and
-- overworld catching. Safari / special-session compatibility stays off.
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

--- True while the Poké Center nurse heal-machine animation is active.
-- Edge-trigger this from follower runtime (false→true / true→false).
-- CANCELLED nurse dialog never sets healAnim — no false positives.
function GameCompat.isPokecenterHealActive(game, ow)
  ow = ow or GameCompat.liveOverworld(nil, game)
  local adapter = GameCompat.current(nil, game)
  if adapter and type(adapter.isPokecenterHealActive) == "function" then
    local ok, active = pcall(adapter.isPokecenterHealActive, ow, game)
    if ok then return active == true end
  end
  return ow ~= nil and ow.healAnim ~= nil
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

local function catchAdapter(game)
  return GameCompat.current(nil, game) or Gen1
end

--- Authoritative capture species: entity/record species id, never an asset id.
function GameCompat.captureSpecies(entity, record)
  if record and record.species ~= nil then return record.species end
  if entity then
    return entity.species or entity.wildSpecies
  end
  return nil
end

function GameCompat.captureLevel(entity, record)
  if record and record.level ~= nil then return record.level end
  if entity then
    return entity.level or entity.wildLevel
  end
  return nil
end

function GameCompat.ballCount(game, ballType)
  local adapter = catchAdapter(game)
  if adapter and adapter.ballCount then
    return adapter.ballCount(game, ballType)
  end
  return 0
end

function GameCompat.consumeBall(game, ballType)
  local adapter = catchAdapter(game)
  if adapter and adapter.consumeBall then
    return adapter.consumeBall(game, ballType) == true
  end
  return false
end

function GameCompat.catchRate(game, species)
  local adapter = catchAdapter(game)
  if adapter and adapter.catchRate then
    return adapter.catchRate(game, species)
  end
  return 255, nil
end

function GameCompat.attemptCatch(game, opts)
  local adapter = catchAdapter(game)
  if adapter and adapter.attemptCatch then
    return adapter.attemptCatch(game, opts)
  end
  return Gen1.attemptCatch(game, opts)
end

function GameCompat.createCaughtPokemon(game, species, level, context)
  local adapter = catchAdapter(game)
  if adapter and adapter.createCaughtPokemon then
    return adapter.createCaughtPokemon(game, species, level, context)
  end
  return Gen1.createCaughtPokemon(game, species, level, context)
end

--- Catching-only live world. Gen1: exact previous `mod.world:overworld()`.
-- Gen2: `game.world` (src/world/gen2/World.lua). Does not change liveOverworld.
function GameCompat.catchWorld(mod, game)
  game = game or (mod and (mod.game or (mod.world and mod.world.game)))
  local adapter = GameCompat.current(mod, game)
  if adapter and adapter.catchWorld then
    local ow = adapter.catchWorld(mod, game)
    if ow then return ow end
  end
  local gen1Ow = Gen1.catchWorld(mod, game)
  if gen1Ow then return gen1Ow end
  -- Gold last resort when generation detection missed: Gen1 has no game.world.
  if game and game.world and game.world.player then
    return game.world
  end
  return nil
end

--- Catching-only native player object. Gen1: ow.player. Gen2: World.player.
function GameCompat.catchPlayer(game, ow)
  local adapter = catchAdapter(game)
  if adapter and adapter.catchPlayer then
    return adapter.catchPlayer(game, ow)
  end
  return ow and ow.player
end

function GameCompat.playerCell(game, ow)
  local adapter = catchAdapter(game)
  if adapter and adapter.playerCell then
    return adapter.playerCell(game, ow)
  end
  local player = GameCompat.catchPlayer(game, ow)
  if not player then return nil, nil end
  return player.cellX, player.cellY
end

function GameCompat.catchPlayerHasControl(game, ow, logic)
  local adapter = catchAdapter(game)
  if adapter and adapter.catchPlayerHasControl then
    return adapter.catchPlayerHasControl(game, ow, logic) == true
  end
  return Gen1.catchPlayerHasControl(game, ow, logic) == true
end

function GameCompat.catchUiBlocked(game, ow, logic)
  local adapter = catchAdapter(game)
  if adapter and adapter.catchUiBlocked then
    return adapter.catchUiBlocked(game, ow, logic) == true
  end
  return Gen1.catchUiBlocked(game, ow, logic) == true
end

function GameCompat.giveCaughtPokemon(game, mon, context)
  local adapter = catchAdapter(game)
  if adapter and adapter.giveCaughtPokemon then
    return adapter.giveCaughtPokemon(game, mon, context)
  end
  return Gen1.giveCaughtPokemon(game, mon, context)
end

function GameCompat.markSpeciesCaught(game, species, mon)
  local adapter = catchAdapter(game)
  local ok = false
  if adapter and adapter.markSpeciesCaught then
    ok = adapter.markSpeciesCaught(game, species, mon) == true
  end
  return ok
end

--- Normalize a species argument to the internal Pokédex key.
-- Accepts mon.species strings ("PIDGEY") or canonical Wilds asset ids (16).
-- Never uses runtime Dex position / mon.dex (mod-reorder unsafe).
function GameCompat.resolveSpeciesKey(species)
  if species == nil then return nil end
  if type(species) == "string" and species ~= "" then
    if not species:match("^%s*%d+%.?%d*%s*$") then
      return species
    end
    species = tonumber(species)
  end
  if type(species) == "number" then
    local ok, SpeciesAssets = pcall(function() return V.require("species_assets") end)
    if ok and SpeciesAssets and SpeciesAssets.speciesFor then
      return SpeciesAssets.speciesFor(species)
    end
  end
  return nil
end

--- True when the player's Pokédex has seen this species.
-- Uses species key identity (not runtime Dex position). Unknown / Fakemon
-- species with no resolvable seen entry are treated as unseen (conservative).
function GameCompat.hasSeenSpecies(game, species)
  local key = GameCompat.resolveSpeciesKey(species)
  if type(key) ~= "string" or key == "" then
    return false
  end
  local adapter = GameCompat.current(nil, game)
  if adapter and type(adapter.hasSeenSpecies) == "function" then
    local ok, seen = pcall(adapter.hasSeenSpecies, game, key)
    if ok then return seen == true end
  end
  local dex = game and game.save and game.save.pokedex
  if type(dex) ~= "table" then return false end
  local seen = dex.seen
  if type(seen) ~= "table" then return false end
  return seen[key] == true
end

--- True when the species is registered in the Pokédex after capture.
-- Gen1: save.pokedex.owned (preferred) or .caught.
-- Gen2: save.pokedex.caught (native SetSeenAndCaughtMon).
-- Encounter-only `seen` is NOT enough — Undiscovered silhouettes use this.
function GameCompat.hasCaughtSpecies(game, species)
  local key = GameCompat.resolveSpeciesKey(species)
  if type(key) ~= "string" or key == "" then
    return false
  end
  local adapter = GameCompat.current(nil, game)
  if adapter and type(adapter.hasCaughtSpecies) == "function" then
    local ok, caught = pcall(adapter.hasCaughtSpecies, game, key)
    if ok then return caught == true end
  end
  local dex = game and game.save and game.save.pokedex
  if type(dex) ~= "table" then return false end
  if type(dex.owned) == "table" and dex.owned[key] == true then return true end
  if type(dex.caught) == "table" and dex.caught[key] == true then return true end
  return false
end

--- Alias: Pokédex entry exists after capture (same as hasCaughtSpecies).
function GameCompat.isPokedexRegistered(game, species)
  return GameCompat.hasCaughtSpecies(game, species)
end

function GameCompat.playerHasPartySpace(game)
  local adapter = catchAdapter(game)
  if adapter and adapter.playerHasPartySpace then
    return adapter.playerHasPartySpace(game) == true
  end
  return false
end

function GameCompat.specialCatchSessionBlocks(game, ow)
  local adapter = catchAdapter(game)
  if adapter and adapter.specialCatchSessionBlocks then
    return adapter.specialCatchSessionBlocks(game, ow) == true
  end
  return false
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
local function goldWildUpdate(self, a, b)
  -- Gold World:updatePeople calls npc:update(map, entities). BehaviorTick
  -- is the Wilds AI source of truth and calls Movement.update(dt).
  if type(a) == "table" then
    return
  end
  local orig = self._wildsOrigUpdate
  if orig then return orig(self, a, b) end
end

-- NOT the Gold NPC:draw(ox, oy, scale) signature, so Gen2 gets a thin wrap.
function GameCompat.adaptWildEntity(entity, game)
  if not entity or entity._wildsGoldAdapted then return entity end
  if not GameCompat.isGen2(nil, game) then return entity end
  entity._wildsGoldAdapted = true
  entity._wildsGoldGuest = true
  local origDraw = entity.draw
  if entity.update and entity.update ~= goldWildUpdate then
    entity._wildsOrigUpdate = entity.update
  end
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
  entity.update = goldWildUpdate
  return entity
end

-- Re-assert the Gold World:updatePeople no-op if a later wrap replaced update.
function GameCompat.ensureWildEntityUpdateOwner(entity, game)
  if not entity then return entity end
  if not GameCompat.isGen2(nil, game) then return entity end
  if not entity._wildsGoldAdapted then
    return GameCompat.adaptWildEntity(entity, game)
  end
  if entity.update ~= goldWildUpdate then
    if entity.update and entity.update ~= goldWildUpdate then
      entity._wildsOrigUpdate = entity._wildsOrigUpdate or entity.update
    end
    entity.update = goldWildUpdate
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

function GameCompat.containerMembership(ow, entity)
  if not ow or not entity then
    return { entities = false, npcs = false }
  end
  return {
    entities = listHas(ow.entities, entity),
    npcs = listHas(ow.npcs, entity),
  }
end

--- Presentation-only recall/release ghost.
-- Gen1 OverworldState:checkTrainerSight does `local d = npc.def` with no nil
-- guard, and iterates ow.npcs every live overworld tick. Poké Center recall
-- ghosts survive because healAnim returns before that loop. Manual Ball
-- runs on a live tick, so Gen1 FX ghosts attach to ow.entities only (the
-- draw list). Gold still uses attachGuestEntity (drawPeople reads npcs).
function GameCompat.attachPresentationGhost(ow, entity, game)
  if not ow or not entity then return "none" end
  if entity.def == nil then entity.def = {} end
  entity.frozen = true
  entity.wanders = false
  if GameCompat.isGen2(nil, game) then
    return GameCompat.attachGuestEntity(ow, entity, game)
  end
  ow.entities = ow.entities or {}
  listInsert(ow.entities, entity)
  entity.worldContainer = "entities"
  return "entities"
end

--- True when the live OverworldState/World is the StateStack top.
-- This is the real Gen1 UI ownership boundary: only the top state updates.
-- Missing stack.top (unit tests) is treated as owning so recall can run.
function GameCompat.overworldOwnsStack(game, ow)
  ow = ow or GameCompat.liveOverworld(nil, game)
  local stack = game and game.stack
  if not (stack and type(stack.top) == "function") then
    return true
  end
  local ok, top = pcall(stack.top, stack)
  if not ok or top == nil or ow == nil then
    return false
  end
  return top == ow
end

--- Insert a follower / town guest without wild-spawn flags.
-- Gold World:drawPeople / rebuildPeople keep non-map NPCs as guests.
-- Native Gold NPC:draw already accepts (ox, oy, scale); only wrap guests
-- that still use the Gen1 camera-arity draw (no spriteDef).
-- Never sets overworldWildSpawn.
function GameCompat.attachGuestEntity(ow, entity, game)
  if not ow or not entity then return "none" end
  ow.entities = ow.entities or {}
  ow.npcs = ow.npcs or {}
  listInsert(ow.entities, entity)
  listInsert(ow.npcs, entity)
  if GameCompat.isGen2(nil, game) then
    if entity.mapId == nil and ow.map and ow.map.id then
      entity.mapId = ow.map.id
    end
    entity._wildsGoldGuest = true
    if not entity.spriteDef then
      GameCompat.adaptWildEntity(entity, game)
    end
    entity.worldContainer = "npcs+entities"
    return "npcs+entities"
  end
  entity.worldContainer = "npcs+entities"
  return "npcs+entities"
end

function GameCompat.detachGuestEntity(ow, entity)
  return GameCompat.detachWildEntity(ow, entity)
end

--- Insert the thrown Ball into the list the generation actually draws.
-- Gen1: ow.entities only (previous Projectile:startFlight).
-- Gen2: native Gold NPC only, via attachGuestEntity (no adaptWildEntity).
-- A Gen1-shaped stub without spriteDef must never enter Gold World.
function GameCompat.attachCatchProjectile(ow, entity, game)
  if not ow or not entity then return "none" end
  if GameCompat.isGen2(nil, game) then
    if not entity.spriteDef then
      return "none"
    end
    return GameCompat.attachGuestEntity(ow, entity, game)
  end
  if ow.entities then
    listInsert(ow.entities, entity)
    return "entities"
  end
  return "none"
end

--- Thrown Poké Ball entity. Gen1 keeps historical NPC.new(data, mapId, objDef).
-- Gen2 builds a native Gold NPC through makeGuestNpc (src.world.gen2.Npc).
-- Never construct a Gen1 NPC and insert it into Gold World.
function GameCompat.makeCatchProjectile(game, ow, spec)
  local adapter = catchAdapter(game)
  if adapter and type(adapter.makeCatchProjectile) == "function" then
    return adapter.makeCatchProjectile(game, ow, spec)
  end
  return Gen1.makeCatchProjectile(game, ow, spec)
end

--- Construct a follower/town guest NPC. Gen1 keeps the exact historical
-- NPC.new(data, mapId, objDef) call. Gen2 uses native Npc.new(mapId, objDef,
-- spriteDef) from src.world.gen2.Npc (same contract as Follower.lua). It does
-- not sniff NPC.MOVE to fall back to Gen1 arity.
function GameCompat.makeGuestNpc(game, ow, spec)
  local adapter = GameCompat.current(nil, game)
  if adapter and type(adapter.makeGuestNpc) == "function" then
    return adapter.makeGuestNpc(game, ow, spec)
  end
  return nil, "no makeGuestNpc adapter"
end

--- CONTROL=POKEMON presentation. Gen1 assigns player.sprite (SpriteRenderer).
-- Gen2 calls player:setSprite(def) — Gold World:applyPlayerState uses that.
function GameCompat.applyControlledPokemonSprite(player, defOrRenderer, game)
  local adapter = GameCompat.current(nil, game)
  if adapter and type(adapter.applyControlledPokemonSprite) == "function" then
    return adapter.applyControlledPokemonSprite(player, defOrRenderer, game)
  end
  if player then
    player.sprite = defOrRenderer
    player._pokepcAsPokemon = true
    return true, "player.sprite"
  end
  return false, "no player"
end

--- Restore the walking trainer/Chris sprite. Gen2 uses World:applyPlayerState.
function GameCompat.restoreTrainerSprite(player, game, ow)
  local adapter = GameCompat.current(nil, game)
  if adapter and type(adapter.restoreTrainerSprite) == "function" then
    return adapter.restoreTrainerSprite(player, game, ow)
  end
  return false, "no restoreTrainerSprite adapter"
end

--- Present dialogue. Gen1 keeps the existing TextBox stack path.
-- Gen2 uses World:showText when the live world exposes it (Gold interact).
function GameCompat.presentText(mod, game, ow, text, onDone)
  ow = ow or GameCompat.liveOverworld(mod, game)
  if GameCompat.isGen2(nil, game) and ow and type(ow.showText) == "function" then
    ow:showText(text, onDone)
    return "showText"
  end
  local TextBox = tryRequire("src.render.TextBox")
  if game and game.stack and TextBox and TextBox.new then
    game.stack:push(TextBox.new(game, text, onDone))
    return "textBox"
  end
  if type(onDone) == "function" then
    onDone()
  end
  return "none"
end

--- True when follower recall must wait until Overworld owns the stack again.
-- Gen1: true — do not recall inside the ChoiceBox callback.
-- Gen2: false — Gold's working talk-Ball path stays immediate.
function GameCompat.shouldDeferFollowerRecall(game, ow, npc)
  ow = ow or GameCompat.liveOverworld(nil, game)
  local adapter = GameCompat.current(nil, game)
  if adapter and type(adapter.shouldDeferFollowerRecall) == "function" then
    local ok, defer = pcall(adapter.shouldDeferFollowerRecall, ow, game, npc)
    if ok then return defer == true end
  end
  return GameCompat.isGen1(nil, game)
end

--- True while a non-overworld state still owns the StateStack.
-- Gen1: stack:top() ~= live OverworldState (TextBox / ChoiceBox / menus).
-- Do not use ow.engaging (trainer sight) or npc.frozen as the talk gate.
-- Gen2: World.textbox / choicebox / engaging / busy.
function GameCompat.followerInteractionBusy(game, ow, npc)
  ow = ow or GameCompat.liveOverworld(nil, game)
  local adapter = GameCompat.current(nil, game)
  if adapter and type(adapter.followerInteractionBusy) == "function" then
    local ok, busy = pcall(adapter.followerInteractionBusy, ow, game, npc)
    if ok then return busy == true end
  end
  return GameCompat.overworldOwnsStack(game, ow) ~= true
end

--- Present dialogue ending in a two-option ChoiceBox (shared TextBox path).
-- onChoose(yes): yes == true → first label; yes == false → second label.
-- opts.labels = { "Ok", "Ball" } (default YES/NO if omitted).
-- Works for Gen1 and Gold: TextBox.choice stacks ChoiceBox over the text.
function GameCompat.presentTextChoice(mod, game, ow, text, onChoose, opts)
  opts = opts or {}
  ow = ow or GameCompat.liveOverworld(mod, game)
  local TextBox = tryRequire("src.render.TextBox")
  if not (game and game.stack and TextBox and TextBox.new) then
    if type(onChoose) == "function" then onChoose(true) end
    return "none"
  end
  if ow and GameCompat.isGen2(nil, game) then
    ow.textbox = true
  end
  local labels = opts.labels
  game.stack:push(TextBox.new(game, text, nil, {
    choice = function(yes)
      if ow and GameCompat.isGen2(nil, game) then
        ow.textbox = nil
        ow.choicebox = nil
      end
      if type(onChoose) == "function" then
        onChoose(yes == true)
      end
    end,
    choiceLabels = labels,
    choiceBox = opts.box,
    defaultNo = opts.defaultNo,
    noSound = opts.noSound,
  }))
  return "textBoxChoice"
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

local function goldDebugEnabled(mod)
  local ok, Config = pcall(function() return V.require("config") end)
  if ok and Config and type(Config.debug) == "function" then
    return Config.debug(mod) == true
  end
  return false
end

-- DEV-only, once-per-transition Gold aggro log. Never per-frame.
function GameCompat.logGoldAggro(mod, info)
  if not GameCompat.isGen2(mod) then return end
  if not goldDebugEnabled(mod) then return end
  if not (mod and mod.log and type(mod.log.info) == "function") then return end
  info = info or {}
  local parts = {
    "species=" .. tostring(info.species or "?"),
    "state=" .. tostring(info.state or "?"),
    "entity=" .. tostring(info.entityX or "?") .. "," .. tostring(info.entityY or "?"),
    "player=" .. tostring(info.playerX or "?") .. "," .. tostring(info.playerY or "?"),
  }
  if info.mapId then
    parts[#parts + 1] = "map=" .. tostring(info.mapId)
  end
  if info.surface then
    parts[#parts + 1] = "surface=" .. tostring(info.surface)
  end
  if info.op then
    parts[#parts + 1] = "op=" .. tostring(info.op)
  end
  pcall(function()
    mod.log:info("[Wilds][Gen2][Aggro] %s", table.concat(parts, " "))
  end)
end

-- Always-on Gold aggro error (the crash we are diagnosing). Not per-frame.
function GameCompat.logGoldAggroError(mod, info)
  if not GameCompat.isGen2(mod) then return end
  if not (mod and mod.log) then return end
  info = info or {}
  local parts = {
    "ERROR",
    "op=" .. tostring(info.op or "?"),
    "err=" .. tostring(info.err or "?"),
    "map=" .. tostring(info.mapId or "?"),
    "species=" .. tostring(info.species or "?"),
    "entity=" .. tostring(info.entityX or "?") .. "," .. tostring(info.entityY or "?"),
    "player=" .. tostring(info.playerX or "?") .. "," .. tostring(info.playerY or "?"),
    "surface=" .. tostring(info.surface or "?"),
    "state=" .. tostring(info.state or "?"),
  }
  local line = "[Wilds][Gen2][Aggro] " .. table.concat(parts, " ")
  pcall(function()
    if type(mod.log.error) == "function" then
      mod.log:error("%s", line)
    elseif type(mod.log.warn) == "function" then
      mod.log:warn("%s", line)
    elseif type(mod.log.info) == "function" then
      mod.log:info("%s", line)
    end
  end)
end

-- Gold World:showEmote stores { image, entity, left }. Gen1 OverworldController
-- stores { npc, frames, onDone }. Writing the Gen1 shape onto Gold World crashes
-- in World:update (`self.emote.left = self.emote.left - 1` on a nil field).
function GameCompat.goldAlertEmoteImage(ow)
  if not ow then return nil end
  local images = ow.emoteImages
  local order = ow.emoteOrder
  if type(images) ~= "table" then return nil end
  if type(order) == "table" then
    for _, key in ipairs(order) do
      if images[key] ~= nil then return images[key] end
    end
  end
  return images.SHOCK or images.shock or images.EMOTE_SHOCK or images[1]
end

function GameCompat.showWildAlertEmote(ow, entity, frames, onDone, game)
  if not ow or not entity then return false end
  if ow.emote or ow.engaging then return false end
  frames = tonumber(frames) or 60
  if GameCompat.isGen2(nil, game) then
    local payload = {
      image = GameCompat.goldAlertEmoteImage(ow),
      entity = entity,
      npc = entity,
      left = frames,
      frames = frames,
      onDone = onDone,
      _wildsAlert = true,
    }
    ow.emote = payload
    ow._wildsAlertEmote = payload
    return true
  end
  ow.emote = {
    npc = entity,
    frames = frames,
    onDone = onDone,
  }
  return true
end

function GameCompat.ownsWildAlertEmote(ow, entity)
  if not (ow and ow.emote and entity) then return false end
  return ow.emote.npc == entity or ow.emote.entity == entity
end

function GameCompat.clearWildAlertEmote(ow, entity)
  if not ow then return end
  if entity == nil or GameCompat.ownsWildAlertEmote(ow, entity) then
    ow.emote = nil
  end
  local pending = ow._wildsAlertEmote
  if pending and (entity == nil or pending.npc == entity or pending.entity == entity) then
    ow._wildsAlertEmote = nil
  end
end

-- Gold World expires emote by nilling it and never calls onDone. Fire once.
function GameCompat.pollWildAlertEmote(ow)
  local pending = ow and ow._wildsAlertEmote
  if not pending then return false end
  local live = ow.emote
  local expired = (live == nil) or (live ~= pending)
  if live and live._wildsAlert and type(live.left) == "number" and live.left <= 0 then
    expired = true
  end
  if not expired then return false end
  ow._wildsAlertEmote = nil
  if ow.emote == pending then ow.emote = nil end
  local cb = pending.onDone
  pending.onDone = nil
  if type(cb) == "function" then
    pcall(cb)
  end
  return true
end

-- Simulate Gold World:update's emote arm. Tests use this; production Gold
-- World already does the same decrement. Safe no-op on Gen1 {frames} emotes.
function GameCompat.tickGoldEmote(ow)
  if not (ow and ow.emote) then return end
  if type(ow.emote.left) ~= "number" then
    error("attempt to perform arithmetic on field 'left' (a "
      .. type(ow.emote.left) .. " value)")
  end
  ow.emote.left = ow.emote.left - 1
  if ow.emote.left <= 0 then
    ow.emote = nil
  end
end

return GameCompat
