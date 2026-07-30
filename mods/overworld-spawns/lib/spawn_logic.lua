-- Logic half of overworld-spawns: map enter, periodic spawn, touch → battle.
-- Rendering is delegated to SpawnRender; this file never draws.
local V = ...
local Config = V.require("config")
local EncounterPick = V.require("encounter_pick")
local Grass = V.require("grass")

local SpawnLogic = {}
SpawnLogic.__index = SpawnLogic

local function gameOf(mod)
  -- WorldAPI is constructed with the live Game reference.
  if mod.world and mod.world.game then return mod.world.game end
  return mod._testGame
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
  for _, id in ipairs(list) do
    self:_despawn(id, false)
  end
  self.byMap[mapId] = {}
end

function SpawnLogic:_removeEntity(entity)
  local ow = self.mod.world:overworld()
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
  if entity and removeEntity ~= false then
    self:_removeEntity(entity)
  end
  self.entities[id] = nil
  local record = self.spawns[id]
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
  local ow = self.mod.world:overworld()
  if not ow then return false end
  ow.entities = ow.entities or {}
  table.insert(ow.entities, entity)
  return true
end

function SpawnLogic:trySpawn(game)
  local ow = self.mod.world:overworld()
  if not ow or not ow.map or not ow.player then return nil end
  local mapId = ow.map.id
  local encDef = self:_encDef(mapId, game)
  if not EncounterPick.hasGrassTable(encDef) then return nil end

  local maxSpawns = Config.get(self.mod, "max_spawns")
  if self:countOnMap(mapId) >= maxSpawns then return nil end

  self.grassCache = self.grassCache or Grass.cells(ow.map)
  if #self.grassCache == 0 then return nil end

  local minDist = Config.DEFAULTS.min_player_distance
  local x, y = Grass.pickFree(ow.map, ow.entities, ow.player, minDist,
                              nil, self.grassCache)
  if not x then return nil end

  local pick = EncounterPick.pick(encDef)
  if not pick then return nil end

  local id = string.format("owspawn_%d", self.nextId)
  self.nextId = self.nextId + 1

  local record = {
    id = id,
    mapId = mapId,
    x = x,
    y = y,
    species = pick.species,
    level = pick.level,
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

  self.mod.log:info("spawned %s Lv%d at %s (%d,%d)",
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

  -- Drop any leftover entities if the map reloaded in place.
  self:_clearMap(mapId)

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

function SpawnLogic:_spawnAt(x, y)
  for id, record in pairs(self.spawns) do
    if record.x == x and record.y == y then
      return id, record, self.entities[id]
    end
  end
  return nil
end

function SpawnLogic:_startBattle(record)
  local ow = self.mod.world:overworld()
  if not ow then return false end
  if ow.runner and ow.runner.isRunning and ow.runner:isRunning() then
    return false
  end

  self.pendingBattle = record.id
  -- Despawn immediately so the player does not re-trigger on the next step
  -- and so Voxel battle staging does not keep a stale billboard around.
  self:_despawn(record.id, true)

  local ok, err = self.mod.world:queueScript({
    { "start_battle", "wild", record.species, record.level },
  })
  if not ok then
    self.mod.log:warn("could not queue wild battle: %s", tostring(err))
    self.pendingBattle = nil
    return false
  end
  self.mod.log:info("triggered wild battle: %s Lv%d",
                    record.species, record.level)
  return true
end

function SpawnLogic:onStepped(ev)
  if not ev or not ev.mapId then return end
  if self.activeMapId ~= ev.mapId then return end

  -- Touch / step-on collision with a passable spawn entity.
  local id, record = self:_spawnAt(ev.x, ev.y)
  if record then
    self:_startBattle(record)
    return
  end

  self.stepsOnMap = self.stepsOnMap + 1
  local every = Config.get(self.mod, "spawn_every_steps") or 8
  if self.stepsOnMap % every == 0 then
    local game = gameOf(self.mod)
    if game then self:trySpawn(game) end
  end
end

function SpawnLogic:onBattleEnded()
  self.pendingBattle = nil
end

-- Also catch bump-into when a future change makes spawns solid: if the
-- player is denied a step onto our tile, start the battle anyway.
function SpawnLogic:onCollision(allowed, ctx)
  if allowed then return allowed end
  if not ctx or ctx.reason ~= "entity" then return allowed end
  local ow = self.mod.world:overworld()
  if not ow or not ow.player or ctx.mover ~= ow.player then return allowed end
  local id, record = self:_spawnAt(ctx.toX, ctx.toY)
  if record then
    self:_startBattle(record)
    return false
  end
  return allowed
end

return SpawnLogic
