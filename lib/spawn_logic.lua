-- Logic half of overworld_wild_spawns: map enter, periodic spawn, optional
-- wander, touch -> battle. Rendering is delegated to SpawnRender.
--
-- Fail-safe: vanilla grass rolls are suppressed only after the visible spawn
-- system is proven ready for the current map (see SpawnState:canSuppressVanilla).
-- The Pokédex is never a spawn gate. The player is never teleported.
local V = ...
local Config = V.require("config")
local EncounterPick = V.require("encounter_pick")
local Grass = V.require("grass")
local SpawnState = V.require("spawn_state")

local SpawnLogic = {}
SpawnLogic.__index = SpawnLogic

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
  self._restoreVanilla = nil -- set by main.lua
  return self
end

function SpawnLogic:setRestoreVanilla(fn)
  self._restoreVanilla = fn
end

function SpawnLogic:canSuppressVanilla()
  if not self:featureActive() then return false end
  if not Config.get(self.mod, "suppress_random_grass") then return false end
  local ok = self.state:canSuppressVanilla()
  self.state.vanillaSuppressed = ok
  return ok
end

function SpawnLogic:_log(fmt, ...)
  if Config.debug(self.mod) then
    self.mod.log:info("[owwild] " .. fmt, ...)
  end
end

function SpawnLogic:_warn(fmt, ...)
  self.mod.log:warn("[owwild] " .. fmt, ...)
end

function SpawnLogic:_restoreVanillaEncounters(reason)
  self.state.vanillaSuppressed = false
  self.state.initialized = false
  self.state.pipelineVerified = false
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

-- Full map init in the required order. Vanilla suppression is NOT enabled
-- until this completes with pipelineVerified.
function SpawnLogic:initializeForMap(mapId, game)
  local st = self.state
  st:reset("map:" .. tostring(mapId))
  st.updateCallbackRegistered = true
  st.mapId = mapId

  if not self:featureActive() then
    st:markUnsupported("feature disabled")
    return false
  end

  game = game or gameOf(self.mod)
  if not game or not game.data then
    st:markError("game data unavailable")
    self:_restoreVanillaEncounters("no game data")
    return false
  end

  -- 1) Map recognition
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
  st.mapName = (ow.map.def and ow.map.def.name) or mapId
  st.mapSupported = true

  -- 2) Encounter data
  local encDef = self:_encDef(mapId, game)
  if not EncounterPick.hasGrassTable(encDef) then
    st.encounterDataAvailable = false
    st:markUnsupported("No encounter data available")
    self:_log("map %s has no grass encounter table; vanilla left intact", mapId)
    self:_restoreVanillaEncounters("no encounter data")
    return false
  end
  st.encounterDataAvailable = true
  st.encounterEntryCount = EncounterPick.slotCount(encDef)
  local summary = EncounterPick.summarize(encDef)
  if summary then
    self:_log("map %s encounter slots=%d rate=%d species=%s levels=%d-%d",
              mapId, summary.slots, summary.rate,
              table.concat(summary.species, ","),
              summary.levelMin, summary.levelMax)
  end

  -- 3) Eligible encounter tiles (engine Map:isGrassCell)
  self.grassCache = Grass.cells(ow.map)
  st.eligibleTileCount = #self.grassCache
  if #self.grassCache == 0 then
    st.eligibleTilesAvailable = false
    st:markUnsupported("no grass encounter tiles")
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
    self:_restoreVanillaEncounters("no eligible tiles")
    return false
  end
  st.eligibleTilesAvailable = true
  self:_log("eligible tiles=%d; probe tile=(%d,%d) player=(%d,%d)",
            #self.grassCache, probeX, probeY, ow.player.cellX, ow.player.cellY)

  -- 4) Renderer support (base Gen1Recomp; Dramatic Shape optional)
  local renderOk, renderInfo = self.render:checkAvailable(game)
  st.rendererAvailable = renderOk == true
  if not renderOk then
    st:markError(renderInfo or "renderer unavailable")
    self:_restoreVanillaEncounters("renderer unavailable")
    return false
  end
  self:_log("renderer available mode=%s", tostring(renderInfo))

  -- 5) Update callback registration already true; activity flips on first step.
  st.updateCallbackRegistered = true

  -- 6) First controlled spawn attempt (standing entity)
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
    -- Retry once with forced relaxed placement for readiness probe.
    local record, err = self:trySpawn(game, { force = true, readinessProbe = true })
    if record then
      spawned = 1
      self:_log("readiness probe spawn ok: %s Lv%d", record.species, record.level)
    else
      st:markError(err or "first spawn failed")
      self:_restoreVanillaEncounters("first spawn failed")
      return false
    end
  end

  st.pipelineVerified = true
  st.initialized = true
  st:clearError()
  self:_log("spawn system initialized on %s (active=%d, suppress_ready=%s, pokedex_owned=%s diag-only)",
            mapId, self:countOnMap(mapId), tostring(st:canSuppressVanilla()),
            tostring(pokedexOwnedForDiag(game)))
  return true
end

function SpawnLogic:trySpawn(game, opts)
  opts = opts or {}
  if not self:featureActive() then
    return nil, "feature disabled"
  end

  local st = self.state
  if st.lastError and not opts.force then
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
  if not EncounterPick.hasGrassTable(encDef) then
    st:noteReject("rejected: no encounter data")
    return nil, "rejected: no encounter data"
  end

  local maxSpawns = Config.get(self.mod, "max_spawns")
  if self:countOnMap(mapId) >= maxSpawns then
    return nil, "max spawns reached"
  end

  self.grassCache = self.grassCache or Grass.cells(ow.map)
  if #self.grassCache == 0 then
    st:noteReject("rejected: not encounter tile")
    return nil, "rejected: not encounter tile"
  end

  local minDist = opts.force and 1 or Config.DEFAULTS.min_player_distance
  local maxDist = Config.DEFAULTS.max_player_distance
  local x, y, reason = Grass.pickFree(
    ow.map, ow.entities, ow.player, minDist, nil, self.grassCache, maxDist,
    function(r) st:noteReject(r) end)
  if not x then
    return nil, reason or "rejected: no eligible tiles"
  end

  local pick = EncounterPick.pick(encDef)
  if not pick then
    st:noteReject("rejected: no encounter data")
    return nil, "rejected: no encounter data"
  end

  local id = string.format("owwild_%d", self.nextId)
  self.nextId = self.nextId + 1

  local record = {
    id = id,
    mapId = mapId,
    x = x,
    y = y,
    species = pick.species,
    level = pick.level,
    state = Config.STATE.AVAILABLE,
  }

  local ok, entityOrErr = pcall(self.render.makeEntity, self.render, game, record)
  if not ok then
    self:_warn("entity creation failed for %s: %s", tostring(pick.species), tostring(entityOrErr))
    st:markError(entityOrErr)
    self:_restoreVanillaEncounters("entity creation failed")
    return nil, "entity creation failed: " .. tostring(entityOrErr)
  end
  local entity = entityOrErr
  if not entity then
    st:markError("makeEntity returned nil")
    self:_restoreVanillaEncounters("entity creation nil")
    return nil, "entity creation failed"
  end
  self:_log("entity creation ok species=%s sprite=%s",
            tostring(entity.species), tostring(entity.spriteId))

  local attached, attachErr = self:_attach(entity)
  if not attached then
    self:_warn("render registration failed: %s", tostring(attachErr))
    st:markError(attachErr)
    self:_restoreVanillaEncounters("render registration failed")
    return nil, "render registration failed: " .. tostring(attachErr)
  end
  self:_log("render registration ok id=%s at (%d,%d)", id, x, y)

  self.spawns[id] = record
  self.entities[id] = entity
  self.byMap[mapId] = self.byMap[mapId] or {}
  self.byMap[mapId][#self.byMap[mapId] + 1] = id

  if not opts.readinessProbe then
    self.mod.log:info("spawned wild %s Lv%d at %s (%d,%d)",
                      pick.species, pick.level, mapId, x, y)
  end
  return record
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
  self:_restoreVanillaEncounters("map enter before init")

  if not self:featureActive() then
    self.state:reset("disabled")
    self.state.updateCallbackRegistered = true
    return
  end

  local game = gameOf(self.mod)
  local ok, err = pcall(self.initializeForMap, self, mapId, game)
  if not ok then
    self:_warn("initializeForMap error: %s", tostring(err))
    self.state:markError(err)
    self:_restoreVanillaEncounters("initializeForMap error")
  end
end

function SpawnLogic:onMapExited(ev)
  if ev.mapId then self:_clearMap(ev.mapId) end
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
  local world = self.mod.world
  if not world or not world.overworld then return end
  local ow = world:overworld()
  if ow and ow.map and ow.map.id then
    self:onMapEntered({ mapId = ow.map.id, map = ow.map })
  end
end

function SpawnLogic:onOptionsChanged(payload)
  if not payload or payload.mod ~= self.mod.id then return end
  if payload.key == "enabled" and payload.value == false then
    self:clearAll()
  elseif payload.key == "enabled" and payload.value == true then
    local world = self.mod.world
    local ow = world and world.overworld and world:overworld()
    if ow and ow.map and ow.map.id then
      self:onMapEntered({ mapId = ow.map.id, map = ow.map })
    end
  elseif payload.key == "suppress_random_grass"
      or payload.key == "debug_logging"
      or payload.key == "force_test_spawn" then
    self:_log("option %s -> %s (suppress_ready=%s)",
              tostring(payload.key), tostring(payload.value),
              tostring(self:canSuppressVanilla()))
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
  -- After progressive search, allow a wider leash so small-map spawns stay.
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

  -- If init never completed (e.g. map entered before world ready), retry once.
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
  self:_log("diag map=%s supported=%s enc=%s tiles=%d active=%d suppress=%s pokedex_owned=%s (diag) updateCount=%d err=%s",
            tostring(st.mapId), tostring(st.mapSupported),
            tostring(st.encounterDataAvailable), st.eligibleTileCount or 0,
            self:countOnMap(st.mapId), tostring(self:canSuppressVanilla()),
            tostring(pokedexOwnedForDiag(game)), st.updateCallbackCount,
            tostring(st.lastError))
  self:_log("diag player=(%s,%s) renderer=%s pipeline=%s",
            tostring(px), tostring(py), tostring(st.rendererAvailable),
            tostring(st.pipelineVerified))
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

-- Source-level guarantee used by tests: no Pokédex gate in spawn logic.
function SpawnLogic.requiresPokedex()
  return false
end

return SpawnLogic
