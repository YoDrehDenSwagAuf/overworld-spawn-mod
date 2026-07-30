-- Logic half of overworld_wild_spawns: map enter, periodic spawn, optional
-- wander, touch -> battle, developer test spawn. Rendering is delegated to
-- SpawnRender.
--
-- Fail-safe: vanilla grass rolls are suppressed only after the visible spawn
-- system is proven ready for the current map (see SpawnState:canSuppressVanilla).
-- The Pokédex is never a spawn gate. The player is never teleported.
local V = ...
local Config = V.require("config")
local EncounterPick = V.require("encounter_pick")
local EncounterIndex = V.require("encounter_index")
local Grass = V.require("grass")
local SpawnState = V.require("spawn_state")
local DebugLog = V.require("debug_log")
local Diagnostics = V.require("diagnostics")

local SpawnLogic = {}
SpawnLogic.__index = SpawnLogic

local TEST_STEPS = {
  "Species resolved",
  "Sprite registered",
  "Runtime asset loaded",
  "Spawn tile resolved",
  "Entity created",
  "Entity registered",
  "Entity visible",
}

local function gameOf(mod)
  if mod.world and mod.world.game then return mod.world.game end
  return mod._testGame
end

local function rngOf()
  if love and love.math and love.math.random then return love.math.random end
  return math.random
end

local function pokedexOwnedForDiag(game)
  -- Diagnostic only. Never used as a spawn condition.
  local save = game and game.save
  local dex = save and save.pokedex
  if not dex then return false end
  if dex.owned and next(dex.owned) then return true end
  return false
end

function SpawnLogic.new(mod, render)
  local self = setmetatable({}, SpawnLogic)
  self.mod = mod
  self.render = render
  self.spawns = {}      -- id -> record
  self.byMap = {}       -- mapId -> { id, ... }
  self.entities = {}    -- id -> entity
  self.stepsOnMap = 0
  self.activeMapId = nil
  self.pendingBattle = nil
  self.nextId = 1
  self.grassCache = nil
  self.state = SpawnState.new()
  self.state.updateCallbackRegistered = true
  self._restoreVanilla = nil
  self.hud = nil
  self.overlay = nil
  self.browser = nil
  self.lastTestSpawn = nil
  return self
end

function SpawnLogic:setRestoreVanilla(fn)
  self._restoreVanilla = fn
end

function SpawnLogic:attachDevTools(hud, overlay, browser)
  self.hud = hud
  self.overlay = overlay
  self.browser = browser
end

function SpawnLogic:canSuppressVanilla()
  if not self:featureActive() then return false end
  if not Config.get(self.mod, "suppress_random_grass") then return false end
  local ok = self.state:canSuppressVanilla()
  self.state.vanillaSuppressed = ok
  return ok
end

function SpawnLogic:_log(fmt, ...)
  DebugLog.info(self.mod, fmt, ...)
end

function SpawnLogic:_debug(fmt, ...)
  DebugLog.debug(self.mod, fmt, ...)
end

function SpawnLogic:_warn(fmt, ...)
  DebugLog.warn(self.mod, fmt, ...)
end

function SpawnLogic:_restoreVanillaEncounters(reason)
  self.state.vanillaSuppressed = false
  self.state.initialized = false
  self.state.pipelineVerified = false
  self.state.fallbackToVanilla = true
  if reason then
    self:_log("restore vanilla encounters: %s", tostring(reason))
  end
  if self._restoreVanilla then
    local ok, err = pcall(self._restoreVanilla, reason)
    if not ok then
      self:_warn("restoreVanilla callback failed: %s", tostring(err))
    end
  end
end

function SpawnLogic:_encDef(mapId, game)
  game = game or gameOf(self.mod)
  if not game or not game.data then return nil end
  local encounters = game.data.encounters
  if type(encounters) ~= "table" then return nil end
  return encounters[mapId]
end

function SpawnLogic:_clearMap(mapId)
  local list = self.byMap[mapId]
  if not list then return end
  local ids = {}
  for i, id in ipairs(list) do ids[i] = id end
  for _, id in ipairs(ids) do
    self:_despawn(id, true)
  end
  self.byMap[mapId] = {}
end

function SpawnLogic:clearAll()
  local maps = {}
  for mapId in pairs(self.byMap) do maps[#maps + 1] = mapId end
  for _, mapId in ipairs(maps) do
    self:_clearMap(mapId)
  end
  self.pendingBattle = nil
  self.grassCache = nil
  if self.overlay then self.overlay:clear() end
  self:_restoreVanillaEncounters("clearAll")
  self.state:reset("clearAll")
  self.state.updateCallbackRegistered = true
end

function SpawnLogic:_removeEntity(entity)
  local world = self.mod.world
  if not world or not world.overworld then return end
  local ow = world:overworld()
  if not ow then return end
  for _, listName in ipairs({ "entities", "npcs" }) do
    local list = ow[listName]
    if list then
      for i = #list, 1, -1 do
        if list[i] == entity then table.remove(list, i) end
      end
    end
  end
end

function SpawnLogic:_despawn(id, removeEntity)
  local entity = self.entities[id]
  local record = self.spawns[id]
  if record then
    record.state = Config.STATE.REMOVED
  end
  if entity then
    entity.state = Config.STATE.REMOVED
    entity.registeredInWorld = false
    if removeEntity ~= false then
      self:_removeEntity(entity)
    end
  end
  self.entities[id] = nil
  self.spawns[id] = nil
  if record then
    local list = self.byMap[record.mapId]
    if list then
      for i = #list, 1, -1 do
        if list[i] == id then table.remove(list, i) end
      end
    end
  end
end

function SpawnLogic:countOnMap(mapId)
  local list = self.byMap[mapId]
  return list and #list or 0
end

function SpawnLogic:_attach(entity)
  local world = self.mod.world
  if not world or not world.overworld then return false, "no world" end
  local ow = world:overworld()
  if not ow then return false, "no overworld" end
  ow.entities = ow.entities or {}
  table.insert(ow.entities, entity)
  entity.registeredInWorld = self.render:isEntityRegistered(ow, entity)
  if not entity.registeredInWorld then
    return false, "entity not in ow.entities after insert"
  end
  return true
end

function SpawnLogic:featureActive()
  return Config.isEnabled(self.mod)
end

function SpawnLogic:entityRegisteredInWorld(id)
  local entity = self.entities[id]
  if not entity then return false end
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  return self.render:isEntityRegistered(ow, entity)
end

function SpawnLogic:_logMapDiagnostics(mapId, game, encDef)
  local st = self.state
  self:_log("Entered map %s", tostring(st.mapName or mapId))
  self:_log("Map id=%s type=%s", tostring(mapId), tostring(st.mapType))
  self:_log("Encounter table present=%s source=%s",
            tostring(st.encounterDataAvailable),
            tostring(st.encounterSource or "none"))
  self:_log("Encounter slots: %d", st.encounterEntryCount or 0)
  self:_log("Unique species: %d", st.uniqueSpeciesCount or 0)
  if st.uniqueSpecies and #st.uniqueSpecies > 0 then
    self:_log("Species IDs: %s", table.concat(st.uniqueSpecies, ","))
  end
  local weights = EncounterPick.slotWeights(encDef, "grass")
  for _, w in ipairs(weights) do
    self:_debug("slot species=%s level=%d weight=%d",
                tostring(w.species), w.level or 1, w.weight or 0)
  end
  for _, summary in ipairs(EncounterPick.summarizeAll(encDef)) do
    self:_log("kind=%s slots=%d unique=%d levels=%d-%d rate=%s",
              summary.kind, summary.slots, summary.uniqueSpecies,
              summary.levelMin, summary.levelMax, tostring(summary.rate))
  end
  self:_log("Eligible tiles: %d", st.eligibleTileCount or 0)
  local br = st.tileRejectBreakdown
  self:_log("Tile rejects collision=%d warp=%d npc=%d dist=%d unknown=%d",
            br.collision, br.warp, br.npc, br.player_distance, br.unknown_tile)
  self:_log("Required assets: %d", st.requiredAssets or 0)
  self:_log("Loaded assets: %d", st.loadedAssets or 0)
  self:_log("Renderer: %s", Diagnostics.rendererStatus(self))
  self:_log("Spawn system: %s", Diagnostics.spawnSystemStatus(self))
  self:_log("Pokedex obtained: %s (diag-only, not a gate)",
            tostring(st.pokedexOwnedDiag))
end

-- Full map init in the required order. Vanilla suppression is NOT enabled
-- until this completes with pipelineVerified.
function SpawnLogic:initializeForMap(mapId, game)
  local st = self.state
  st:reset("map:" .. tostring(mapId))
  st.updateCallbackRegistered = true
  st.mapId = mapId
  st.phase = "initializing"

  -- 1) Mod options
  if not self:featureActive() then
    st:markUnsupported("feature disabled")
    st.phase = "idle"
    return false
  end

  game = game or gameOf(self.mod)
  if not game or not game.data then
    st:markError("game data unavailable")
    self:_restoreVanillaEncounters("no game data")
    return false
  end
  st.pokedexOwnedDiag = pokedexOwnedForDiag(game)

  -- 2) Map-ID and map name
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if not ow or not ow.map or not ow.player then
    st:markError("overworld not loaded")
    self:_restoreVanillaEncounters("no overworld")
    return false
  end
  if ow.map.id ~= mapId then
    st:markError("map id mismatch")
    self:_restoreVanillaEncounters("map mismatch")
    return false
  end
  st.mapName = EncounterIndex.mapLabel(game, mapId)
  if ow.map.def and (ow.map.def.label or ow.map.def.name) then
    st.mapName = ow.map.def.label or ow.map.def.name
  end
  st.mapType = EncounterIndex.mapTypeOf(game, mapId)
  st.mapSupported = true

  -- 3) Encounter table
  local encDef = self:_encDef(mapId, game)
  if not EncounterPick.hasGrassTable(encDef) then
    st.encounterDataAvailable = false
    st.encounterSource = encDef and "game.data.encounters (no grass)" or "none"
    st:markUnsupported("No encounter data available")
    self:_log("map %s has no grass encounter table; vanilla left intact", mapId)
    self:_logMapDiagnostics(mapId, game, encDef)
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("no encounter data")
    return false
  end
  st.encounterDataAvailable = true
  st.encounterSource = "game.data.encounters." .. tostring(mapId) .. ".grass"
  st.encounterEntryCount = EncounterPick.slotCount(encDef, "grass")
  local speciesNames = EncounterPick.uniqueSpecies(encDef, "grass")
  st.uniqueSpecies = speciesNames
  st.uniqueSpeciesCount = #speciesNames

  -- 4) Unique species already computed above

  -- 5) Encounter tiles
  self.grassCache = Grass.cells(ow.map)
  st.eligibleTileCount = #self.grassCache
  if #self.grassCache == 0 then
    st.eligibleTilesAvailable = false
    st:markUnsupported("no grass encounter tiles")
    self:_logMapDiagnostics(mapId, game, encDef)
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("no grass tiles")
    return false
  end

  local minDist = Config.DEFAULTS.min_player_distance
  local maxDist = Config.DEFAULTS.max_player_distance
  local probeX, probeY, probeReason = Grass.pickFree(
    ow.map, ow.entities, ow.player, minDist, nil, self.grassCache, maxDist,
    function(reason) st:noteReject(reason) end)
  if not probeX then
    st.eligibleTilesAvailable = false
    st:markUnsupported(probeReason or "no eligible tiles")
    self:_log("no eligible spawn tiles on %s (%s); vanilla left intact",
              mapId, tostring(probeReason))
    self:_logMapDiagnostics(mapId, game, encDef)
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("no eligible tiles")
    return false
  end
  st.eligibleTilesAvailable = true

  -- 6/7) Required assets + load/validate
  st.assetsLoading = true
  local required, loaded = self.render:countAssets(speciesNames, game)
  st.requiredAssets = required
  st.loadedAssets = loaded
  st.assetsLoading = false
  if required > 0 and loaded == 0 then
    -- Placeholder path still allows entity creation; mark soft asset warning.
    st.assetError = nil
    self:_log("no real overworld assets loaded; placeholder path active")
  end

  -- 8) Renderer capability
  local renderOk, renderInfo = self.render:checkAvailable(game)
  st.rendererAvailable = renderOk == true
  if not renderOk then
    st:markError(renderInfo or "renderer unavailable")
    self:_logMapDiagnostics(mapId, game, encDef)
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("renderer unavailable")
    return false
  end

  -- 9) Spawn system status (READY after verified spawn)
  st.updateCallbackRegistered = true

  -- 10) Debug HUD update
  if self.hud then self.hud:markMapEnter() end
  if self.overlay then self.overlay:rebuild() end

  -- 11) Spawn attempts
  st.phase = "spawning"
  local want = Config.get(self.mod, "initial_spawns") or 1
  if Config.get(self.mod, "force_test_spawn") then
    want = math.max(want, 1)
  end
  local spawned = 0
  for _ = 1, want do
    local record, err = self:trySpawn(game, { force = Config.get(self.mod, "force_test_spawn") })
    if record then
      spawned = spawned + 1
    else
      self:_log("spawn attempt rejected: %s", tostring(err))
      break
    end
  end

  if spawned < 1 then
    local record, err = self:trySpawn(game, { force = true, readinessProbe = true })
    if record then
      spawned = 1
      self:_log("readiness probe spawn ok: %s Lv%d", record.species, record.level)
    else
      st:markError(err or "first spawn failed")
      self:_logMapDiagnostics(mapId, game, encDef)
      self:_restoreVanillaEncounters("first spawn failed")
      return false
    end
  end

  st.pipelineVerified = true
  st.initialized = true
  st.fallbackToVanilla = false
  st.phase = "idle"
  st:clearError()
  self:_logMapDiagnostics(mapId, game, encDef)
  self:_log("Spawn system: READY")
  return true
end

function SpawnLogic:trySpawn(game, opts)
  opts = opts or {}
  if not self:featureActive() then
    return nil, "feature disabled"
  end

  local st = self.state
  if st.lastError and not opts.force and not opts.testSpawn then
    return nil, "paused after error: " .. tostring(st.lastError)
  end

  local world = self.mod.world
  if not world or not world.overworld then
    return nil, "no world"
  end
  local ow = world:overworld()
  if not ow or not ow.map or not ow.player then
    return nil, "no overworld"
  end

  local mapId = ow.map.id
  local encDef = self:_encDef(mapId, game)
  if not opts.testSpawn and not EncounterPick.hasGrassTable(encDef) then
    st:noteReject("rejected: no encounter data")
    return nil, "rejected: no encounter data"
  end

  local maxSpawns = Config.get(self.mod, "max_spawns")
  if self:countOnMap(mapId) >= maxSpawns then
    return nil, "max spawns reached"
  end

  local x, y, reason
  if opts.x and opts.y then
    x, y = opts.x, opts.y
  elseif opts.allowOutside then
    x, y, reason = Grass.pickFreeWalkable(
      ow.map, ow.entities, ow.player,
      opts.force and 1 or Config.DEFAULTS.min_player_distance,
      nil, Config.DEFAULTS.max_player_distance,
      function(r) st:noteReject(r) end)
  else
    self.grassCache = self.grassCache or Grass.cells(ow.map)
    if #self.grassCache == 0 then
      st:noteReject("rejected: not encounter tile")
      return nil, "rejected: not encounter tile"
    end
    local minDist = opts.force and 1 or Config.DEFAULTS.min_player_distance
    local maxDist = Config.DEFAULTS.max_player_distance
    x, y, reason = Grass.pickFree(
      ow.map, ow.entities, ow.player, minDist, nil, self.grassCache, maxDist,
      function(r) st:noteReject(r) end)
  end
  if not x then
    return nil, reason or "rejected: no eligible tiles"
  end

  local species, level
  if opts.species then
    species = opts.species
    level = opts.level or 5
  else
    local pick = EncounterPick.pick(encDef)
    if not pick then
      st:noteReject("rejected: no encounter data")
      return nil, "rejected: no encounter data"
    end
    species, level = pick.species, pick.level
  end

  self:_debug("Selected species=%s level=%d", tostring(species), level or 1)
  self:_debug("Selected tile x=%d y=%d", x, y)

  local id = string.format("owwild_%d", self.nextId)
  self.nextId = self.nextId + 1

  local record = {
    id = id,
    mapId = mapId,
    x = x,
    y = y,
    species = species,
    level = level,
    state = Config.STATE.AVAILABLE,
    testSpawn = opts.testSpawn == true,
  }

  local ok, entityOrErr = pcall(self.render.makeEntity, self.render, game, record)
  if not ok then
    self:_warn("entity creation failed for %s: %s", tostring(species), tostring(entityOrErr))
    DebugLog.error(self.mod, "Entity creation failed: %s", tostring(entityOrErr))
    st:markError(entityOrErr)
    st.lastSpawnError = tostring(entityOrErr)
    if not opts.testSpawn then
      self:_restoreVanillaEncounters("entity creation failed")
    end
    return nil, "entity creation failed: " .. tostring(entityOrErr)
  end
  local entity = entityOrErr
  if not entity then
    st:markError("makeEntity returned nil")
    st.lastSpawnError = "makeEntity returned nil"
    if not opts.testSpawn then
      self:_restoreVanillaEncounters("entity creation nil")
    end
    return nil, "entity creation failed"
  end
  self:_debug("Entity created id=%s", id)

  local attached, attachErr = self:_attach(entity)
  if not attached then
    self:_warn("render registration failed: %s", tostring(attachErr))
    DebugLog.error(self.mod, "Entity registration failed: %s", tostring(attachErr))
    st:markError(attachErr)
    st.lastSpawnError = tostring(attachErr)
    if not opts.testSpawn then
      self:_restoreVanillaEncounters("render registration failed")
    end
    return nil, "render registration failed: " .. tostring(attachErr)
  end
  self:_debug("Entity registered")
  self:_debug("Renderer registered")

  self.spawns[id] = record
  self.entities[id] = entity
  self.byMap[mapId] = self.byMap[mapId] or {}
  self.byMap[mapId][#self.byMap[mapId] + 1] = id

  if not opts.readinessProbe then
    self.mod.log:info("spawned wild %s Lv%d at %s (%d,%d)",
                      species, level, mapId, x, y)
  end
  return record, nil, entity
end

-- Developer test spawn with explicit phase reporting. Never touches Pokédex,
-- save story flags, or player position.
function SpawnLogic:testSpawn(species, opts)
  opts = opts or {}
  local result = {
    ok = false,
    failedAt = nil,
    stepName = nil,
    error = nil,
    steps = {},
    species = species,
  }
  local function fail(step, err)
    result.ok = false
    result.failedAt = step
    result.stepName = TEST_STEPS[step]
    result.error = tostring(err)
    result.steps[step] = { name = TEST_STEPS[step], ok = false, error = result.error }
    DebugLog.error(self.mod,
      "Test spawn failed at step %d (%s): %s",
      step, TEST_STEPS[step], result.error)
    self.state.lastSpawnError = result.error
    self.lastTestSpawn = result
    return result
  end
  local function pass(step, detail)
    result.steps[step] = { name = TEST_STEPS[step], ok = true, detail = detail }
  end

  if not Config.devMode(self.mod) then
    return fail(1, "Developer mode is disabled")
  end

  local game = gameOf(self.mod)
  if not game or not game.data then
    return fail(1, "game data unavailable")
  end

  -- Snapshot player position to prove we never move it.
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  local px = ow and ow.player and ow.player.cellX
  local py = ow and ow.player and ow.player.cellY
  local pokedexBefore = game.save and game.save.pokedex

  -- 1) Species resolved (ROM / content data only — never Pokédex)
  local mon = game.data.pokemon and game.data.pokemon[species]
  if not mon and not (self.mod.content.pokemon and self.mod.content.pokemon:get(species)) then
    return fail(1, "unknown species: " .. tostring(species))
  end
  pass(1, species)

  -- 2) Pre-registered sprite ID (pure lookup; no content registry writes)
  self.render.assetInfo[species] = nil
  self.render.runtimeImageCache[species] = nil
  local spriteId, spriteErr = self.render:spriteIdFor(species)
  if not spriteId then
    return fail(2, spriteErr or ("No pre-registered sprite for species " .. tostring(species)))
  end
  pass(2, spriteId)

  -- 3) Runtime asset available (load/cache only — never registry mutation)
  local runtime = self.render:getRuntimeImage(species, game)
  if not runtime or runtime.status ~= "LOADED" then
    return fail(3, (runtime and runtime.status and ("Sprite asset could not be loaded (" .. tostring(runtime.status) .. ")"))
      or "Sprite asset could not be loaded.")
  end
  local info = self.render:assetStatusFor(species, game)
  pass(3, runtime.kind or info.status)

  -- 4) Spawn tile resolved
  if not ow or not ow.map or not ow.player then
    return fail(4, "No valid test spawn position on the current map.")
  end
  local allowOutside = Config.allowOutsideEncounter(self.mod)
  local x, y, reason
  if allowOutside then
    x, y, reason = Grass.pickFreeWalkable(
      ow.map, ow.entities, ow.player, 1, nil, 32,
      function(r) self.state:noteReject(r) end)
  else
    self.grassCache = self.grassCache or Grass.cells(ow.map)
    x, y, reason = Grass.pickFree(
      ow.map, ow.entities, ow.player, 1, nil, self.grassCache, 32,
      function(r) self.state:noteReject(r) end)
  end
  if not x then
    return fail(4, reason or "No valid test spawn position on the current map.")
  end
  -- Hard bans still apply even with allowOutside.
  local okTile, tileReason
  if allowOutside then
    okTile, tileReason = Grass.validateWalkableTile(
      ow.map, ow.entities, ow.player, x, y, 1, nil, nil)
  else
    okTile, tileReason = Grass.validateSpawnTile(
      ow.map, ow.entities, ow.player, x, y, 1, nil, nil)
  end
  if not okTile then
    return fail(4, tileReason or "No valid test spawn position on the current map.")
  end
  pass(4, ("(%d,%d)"):format(x, y))

  -- 5) Entity created (uses pre-registered sprite IDs only)
  local level = opts.level or 5
  local id = string.format("owwild_test_%d", self.nextId)
  self.nextId = self.nextId + 1
  local record = {
    id = id,
    mapId = ow.map.id,
    x = x, y = y,
    species = species,
    level = level,
    state = Config.STATE.AVAILABLE,
    testSpawn = true,
  }

  local okCreate, entityOrErr = pcall(self.render.makeEntity, self.render, game, record)
  if not okCreate then
    DebugLog.error(self.mod, "stack/error: %s", tostring(entityOrErr))
    return fail(5, entityOrErr)
  end
  if not entityOrErr then
    return fail(5, "makeEntity returned nil")
  end
  pass(5, id)
  local entity = entityOrErr

  -- 6) Entity registered in the world entity list
  local attached, attachErr = self:_attach(entity)
  if not attached then
    DebugLog.error(self.mod, "Entity registration failed: %s", tostring(attachErr))
    return fail(6, attachErr or "Entity registration returned nil.")
  end
  if not entity.sprite or not entity.pose or not entity.draw then
    self:_removeEntity(entity)
    return fail(6, "renderer contract missing pose/draw/sprite")
  end
  if self.render.rendererMode ~= "base" then
    self:_removeEntity(entity)
    return fail(6, self.render.lastError or "renderer not ready")
  end
  pass(6, "registered")

  -- 7) Visible = registered + asset + non-zero opacity + on map.
  local opacity = Config.get(self.mod, "sprite_opacity") or 1
  if opacity <= 0 then
    self:_removeEntity(entity)
    return fail(7, "entity fully transparent")
  end
  if not entity.registeredInWorld then
    self:_removeEntity(entity)
    return fail(7, "entity not registered in world")
  end
  pass(7, "visible")

  self.spawns[id] = record
  self.entities[id] = entity
  self.byMap[ow.map.id] = self.byMap[ow.map.id] or {}
  self.byMap[ow.map.id][#self.byMap[ow.map.id] + 1] = id

  -- Prove no side effects on player / pokedex / save.
  if ow.player then
    if ow.player.cellX ~= px or ow.player.cellY ~= py then
      DebugLog.error(self.mod, "BUG: test spawn moved player")
    end
  end
  if game.save and game.save.pokedex ~= pokedexBefore then
    DebugLog.error(self.mod, "BUG: test spawn mutated pokedex table ref")
  end

  result.ok = true
  result.x, result.y = x, y
  result.level = level
  result.id = id
  self.lastTestSpawn = result
  self:_log("Test spawn OK species=%s at (%d,%d)", tostring(species), x, y)
  return result
end

function SpawnLogic:onMapEntered(ev)
  local mapId = ev.mapId
  if self.activeMapId and self.activeMapId ~= mapId then
    self:_clearMap(self.activeMapId)
  end
  self.activeMapId = mapId
  self.stepsOnMap = 0
  self.grassCache = nil
  self.pendingBattle = nil

  self:_clearMap(mapId)
  if self.overlay then self.overlay:clear() end
  self:_restoreVanillaEncounters("map enter before init")

  if not self:featureActive() then
    self.state:reset("disabled")
    self.state.updateCallbackRegistered = true
    if Config.devMode(self.mod) and self.hud then
      self.hud:markMapEnter()
    end
    return
  end

  local game = gameOf(self.mod)
  local ok, err = pcall(self.initializeForMap, self, mapId, game)
  if not ok then
    self:_warn("initializeForMap error: %s", tostring(err))
    DebugLog.error(self.mod, "initializeForMap error: %s", tostring(err))
    self.state:markError(err)
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("initializeForMap error")
  end
end

function SpawnLogic:onMapExited(ev)
  if ev.mapId then self:_clearMap(ev.mapId) end
  if self.overlay then self.overlay:clear() end
  if self.activeMapId == ev.mapId then
    self.activeMapId = nil
    self.grassCache = nil
    self:_restoreVanillaEncounters("map exited")
    self.state:reset("map exited")
    self.state.updateCallbackRegistered = true
  end
end

function SpawnLogic:onMapReloaded(ev)
  if ev and ev.mapId and self.activeMapId == ev.mapId then
    self:onMapEntered({ mapId = ev.mapId })
  end
end

function SpawnLogic:onSaveLoaded()
  self:clearAll()
  self.activeMapId = nil
  self.stepsOnMap = 0
  if self.browser then self.browser:invalidateIndex() end
  local world = self.mod.world
  if not world or not world.overworld then return end
  local ow = world:overworld()
  if ow and ow.map and ow.map.id then
    self:onMapEntered({ mapId = ow.map.id, map = ow.map })
  end
end

function SpawnLogic:onOptionsChanged(payload)
  if not payload or payload.mod ~= self.mod.id then return end
  local key = payload.key
  if key == "enabled" and payload.value == false then
    self:clearAll()
  elseif key == "enabled" and payload.value == true then
    local world = self.mod.world
    local ow = world and world.overworld and world:overworld()
    if ow and ow.map and ow.map.id then
      self:onMapEntered({ mapId = ow.map.id, map = ow.map })
    end
  elseif key == "dev_mode"
      or key == "debug_hud_always_visible"
      or key == "show_spawn_tile_overlay"
      or key == "allow_debug_spawn_outside_encounter_areas"
      or key == "debug_logging"
      or key == "force_test_spawn"
      or key == "suppress_random_grass" then
    self:_log("option %s -> %s (suppress_ready=%s dev=%s)",
              tostring(key), tostring(payload.value),
              tostring(self:canSuppressVanilla()),
              tostring(Config.devMode(self.mod)))
    if self.hud then self.hud:syncPipelineLevel() end
    if key == "dev_mode" and payload.value == true and self.hud then
      self.hud:markMapEnter()
    end
    if key == "show_spawn_tile_overlay" or key == "dev_mode" then
      if self.overlay then self.overlay:rebuild() end
    end
    if key == "dev_mode" and payload.value == false then
      if self.overlay then self.overlay:clear() end
    end
  end
end

function SpawnLogic:_spawnAt(x, y)
  for id, record in pairs(self.spawns) do
    if record.state == Config.STATE.AVAILABLE
       and record.x == x and record.y == y then
      return id, record, self.entities[id]
    end
  end
  return nil
end

function SpawnLogic:_startBattle(record)
  if not record or record.state ~= Config.STATE.AVAILABLE then
    return false
  end
  if self.pendingBattle then return false end

  local world = self.mod.world
  if not world or not world.overworld then return false end
  local ow = world:overworld()
  if not ow then return false end
  if ow.runner and ow.runner.isRunning and ow.runner:isRunning() then
    return false
  end

  record.state = Config.STATE.ENCOUNTER_STARTING
  local entity = self.entities[record.id]
  if entity then entity.state = Config.STATE.ENCOUNTER_STARTING end

  self.pendingBattle = {
    id = record.id,
    species = record.species,
    level = record.level,
  }

  self:_despawn(record.id, true)

  local ok, err = world:queueScript({
    { "start_battle", "wild", record.species, record.level },
  })
  if not ok then
    self:_warn("could not queue wild battle: %s", tostring(err))
    self.pendingBattle = nil
    self.state:markError(err)
    self:_restoreVanillaEncounters("battle queue failed")
    return false
  end

  if self.pendingBattle then
    self.pendingBattle.state = Config.STATE.IN_BATTLE
  end
  self.mod.log:info("triggered wild battle: %s Lv%d",
                    record.species, record.level)
  return true
end

function SpawnLogic:_despawnFar(ow)
  local maxDist = Config.DEFAULTS.max_player_distance
  local mapSpan = math.max(ow.map.widthCells or 0, ow.map.heightCells or 0)
  maxDist = math.max(maxDist, mapSpan)
  local player = ow.player
  if not player then return end
  local doomed = {}
  for id, record in pairs(self.spawns) do
    if record.state == Config.STATE.AVAILABLE then
      local d = Grass.chebyshev(record.x, record.y, player.cellX, player.cellY)
      if d > maxDist then
        doomed[#doomed + 1] = id
      end
    end
  end
  for _, id in ipairs(doomed) do
    self:_despawn(id, true)
  end
end

function SpawnLogic:_wander(ow)
  local every = Config.get(self.mod, "wander_every_steps")
  if every == nil then every = Config.DEFAULTS.wander_every_steps end
  if every <= 0 then return end
  if self.stepsOnMap % every ~= 0 then return end
  local maxDist = Config.DEFAULTS.max_player_distance
  local rng = rngOf()
  for id, record in pairs(self.spawns) do
    if record.state == Config.STATE.AVAILABLE then
      local entity = self.entities[id]
      if entity and rng() < 0.55 then
        local nx, ny = Grass.pickNeighbor(ow.map, ow.entities, entity,
                                          ow.player, maxDist, rng)
        if nx then
          entity:setCell(nx, ny)
          record.x, record.y = nx, ny
        end
      end
    end
  end
end

function SpawnLogic:onStepped(ev)
  self.state.updateCallbackCount = self.state.updateCallbackCount + 1
  self.state.updateCallbackActive = true

  if Config.debug(self.mod) and self.state.updateCallbackCount == 1 then
    self:_log("update callback world.stepped is active")
  end
  if Config.debug(self.mod) and self.state.updateCallbackCount > 0
     and self.state.updateCallbackCount % 24 == 0 then
    self:_logDiag()
  end

  if not ev or not ev.mapId then return end
  if self.activeMapId ~= ev.mapId then return end

  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()

  if not self:featureActive() then
    if self:countOnMap(ev.mapId) > 0 then self:_clearMap(ev.mapId) end
    return
  end

  if not self.state.initialized and ow and ow.map then
    local game = gameOf(self.mod)
    local ok, err = pcall(self.initializeForMap, self, ev.mapId, game)
    if not ok then
      self:_warn("late initializeForMap error: %s", tostring(err))
      self.state:markError(err)
      self:_restoreVanillaEncounters("late init error")
      return
    end
  end

  local id, record = self:_spawnAt(ev.x, ev.y)
  if record then
    self:_startBattle(record)
    return
  end

  self.stepsOnMap = self.stepsOnMap + 1

  if ow then
    self:_despawnFar(ow)
    self:_wander(ow)
  end

  if not self.state.initialized then return end

  local every = Config.get(self.mod, "spawn_every_steps") or 8
  if self.stepsOnMap % every == 0 then
    local game = gameOf(self.mod)
    if game then
      local ok, resultOrErr = pcall(self.trySpawn, self, game, {})
      if not ok then
        self:_warn("trySpawn error: %s", tostring(resultOrErr))
        DebugLog.error(self.mod, "trySpawn error: %s", tostring(resultOrErr))
        self.state:markError(resultOrErr)
        self:_restoreVanillaEncounters("trySpawn error")
      end
    end
  end
end

function SpawnLogic:_logDiag()
  local st = self.state
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  local px = ow and ow.player and ow.player.cellX
  local py = ow and ow.player and ow.player.cellY
  local game = gameOf(self.mod)
  local vis = Diagnostics.visibilityCounts(self)
  DebugLog.onceKey(self.mod, "diag-snapshot", "INFO",
    "diag map=%s species=%d slots=%d tiles=%d assets=%d/%d active=%d created=%d registered=%d rendered=%d status=%s err=%s",
    tostring(st.mapId), st.uniqueSpeciesCount or 0, st.encounterEntryCount or 0,
    st.eligibleTileCount or 0, st.loadedAssets or 0, st.requiredAssets or 0,
    vis.active, vis.created, vis.registered, vis.rendered,
    Diagnostics.spawnSystemStatus(self), tostring(st.lastError))
  self:_debug("diag player=(%s,%s) pokedex_owned=%s (diag)",
              tostring(px), tostring(py), tostring(pokedexOwnedForDiag(game)))
end

function SpawnLogic:onBattleEnded()
  self.pendingBattle = nil
end

function SpawnLogic:onCollision(allowed, ctx)
  if allowed then return allowed end
  if not self:featureActive() then return allowed end
  if not ctx or ctx.reason ~= "entity" then return allowed end
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if not ow or not ow.player or ctx.mover ~= ow.player then return allowed end
  local id, record = self:_spawnAt(ctx.toX, ctx.toY)
  if record then
    self:_startBattle(record)
    return false
  end
  return allowed
end

function SpawnLogic.touchesPlayerPosition()
  return false
end

function SpawnLogic.requiresPokedex()
  return false
end

function SpawnLogic.testSteps()
  return TEST_STEPS
end

return SpawnLogic
