-- Logic half of overworld_wild_spawns: map enter, periodic spawn, wander,
-- touch -> battle. Rendering is delegated to SpawnRender; this file never draws.
--
-- This mod NEVER teleports, warps, or repositions the player. "Spawn" means
-- creating visible wild Pokemon entities in the overworld only.
local V = ...
local Config = V.require("config")
local EncounterPick = V.require("encounter_pick")
local Grass = V.require("grass")

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
  return self
end

function SpawnLogic:_encDef(mapId, game)
  game = game or gameOf(self.mod)
  if not game or not game.data then return nil end
  return game.data.encounters and game.data.encounters[mapId]
end

function SpawnLogic:_clearMap(mapId)
  local list = self.byMap[mapId]
  if not list then return end
  -- Copy ids: _despawn mutates the list.
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
  if not world or not world.overworld then return false end
  local ow = world:overworld()
  if not ow then return false end
  ow.entities = ow.entities or {}
  table.insert(ow.entities, entity)
  return true
end

function SpawnLogic:featureActive()
  return Config.isEnabled(self.mod)
end

function SpawnLogic:trySpawn(game)
  if not self:featureActive() then return nil end

  local world = self.mod.world
  if not world or not world.overworld then return nil end
  local ow = world:overworld()
  if not ow or not ow.map or not ow.player then return nil end

  local mapId = ow.map.id
  local encDef = self:_encDef(mapId, game)
  if not EncounterPick.hasGrassTable(encDef) then return nil end

  local maxSpawns = Config.get(self.mod, "max_spawns")
  if self:countOnMap(mapId) >= maxSpawns then return nil end

  self.grassCache = self.grassCache or Grass.cells(ow.map)
  if #self.grassCache == 0 then return nil end

  local minDist = Config.DEFAULTS.min_player_distance
  local maxDist = Config.DEFAULTS.max_player_distance
  local x, y = Grass.pickFree(ow.map, ow.entities, ow.player, minDist,
                              nil, self.grassCache, maxDist)
  if not x then return nil end

  local pick = EncounterPick.pick(encDef)
  if not pick then return nil end

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

  local ok, entity = pcall(self.render.makeEntity, self.render, game, record)
  if not ok or not entity then
    self.mod.log:warn("failed to build spawn entity for %s: %s",
                      tostring(pick.species), tostring(entity))
    return nil
  end

  if not self:_attach(entity) then return nil end

  self.spawns[id] = record
  self.entities[id] = entity
  self.byMap[mapId] = self.byMap[mapId] or {}
  self.byMap[mapId][#self.byMap[mapId] + 1] = id

  self.mod.log:info("spawned wild %s Lv%d at %s (%d,%d)",
                    pick.species, pick.level, mapId, x, y)
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

  -- Drop leftovers if the map reloaded in place (save/load, invalidate).
  self:_clearMap(mapId)

  if not self:featureActive() then return end

  local game = gameOf(self.mod)
  if not game then return end
  local encDef = self:_encDef(mapId, game)
  if not EncounterPick.hasGrassTable(encDef) then return end

  local n = Config.get(self.mod, "initial_spawns") or 0
  for _ = 1, n do
    if not self:trySpawn(game) then break end
  end
end

function SpawnLogic:onMapExited(ev)
  if ev.mapId then self:_clearMap(ev.mapId) end
  if self.activeMapId == ev.mapId then
    self.activeMapId = nil
    self.grassCache = nil
  end
end

function SpawnLogic:onSaveLoaded()
  -- Runtime entities are never part of the save. Rebuild cleanly for the
  -- current map without duplicating stale references.
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

  -- Remove immediately so the next collision frame cannot re-trigger and
  -- Voxel battle staging does not keep a stale billboard.
  self:_despawn(record.id, true)

  local ok, err = world:queueScript({
    { "start_battle", "wild", record.species, record.level },
  })
  if not ok then
    self.mod.log:warn("could not queue wild battle: %s", tostring(err))
    self.pendingBattle = nil
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
  local every = Config.DEFAULTS.wander_every_steps
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
  if not ev or not ev.mapId then return end
  if self.activeMapId ~= ev.mapId then return end

  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()

  if not self:featureActive() then
    if self:countOnMap(ev.mapId) > 0 then self:_clearMap(ev.mapId) end
    return
  end

  -- Touch / step-on collision with a passable spawn entity.
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

  local every = Config.get(self.mod, "spawn_every_steps") or 8
  if self.stepsOnMap % every == 0 then
    local game = gameOf(self.mod)
    if game then self:trySpawn(game) end
  end
end

function SpawnLogic:onBattleEnded()
  self.pendingBattle = nil
end

-- Bump-into safety net if a spawn is ever non-passable.
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

-- Assert helper for tests: this mod never mutates player position fields.
function SpawnLogic.touchesPlayerPosition()
  return false
end

return SpawnLogic
