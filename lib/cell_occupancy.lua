-- Central world-cell occupancy for Wilds of Kanto.
-- Tracks current cells, movement targets, and in-flight spawn reservations.
-- No renderer dependency.
local V = ...

local CellOccupancy = {}
CellOccupancy.__index = CellOccupancy

local function cellKey(x, y)
  if x == nil or y == nil then return nil end
  return tostring(x) .. ":" .. tostring(y)
end

local function entityToken(entity)
  if entity == nil then return nil end
  if type(entity) == "string" or type(entity) == "number" then
    return tostring(entity)
  end
  -- Player rebuild always uses the literal owner "player".
  if entity.player == true or entity.isPlayer == true then
    return "player"
  end
  if entity.id ~= nil then
    return tostring(entity.id)
  end
  if entity.spawnId ~= nil then
    return tostring(entity.spawnId)
  end
  return tostring(entity)
end

-- Public markers / flags that identify blocking world entities.
-- Followers EX trailers use pokepcTrailer + passable=true; classic Yellow uses
-- pikachuFollower. Wilds unified follower marks wildsFollower / isFollower.
-- We never read private Followers tables.
function CellOccupancy.isFollowerEntity(entity)
  if not entity then return false end
  if entity.pokepcTrailer == true then return true end
  if entity.pikachuFollower == true then return true end
  if entity.wildsFollower == true then return true end
  if entity.isFollower == true or entity.follower == true then return true end
  local sprite = entity.sprite
  local def = sprite and sprite.def
  local sid = def and def.id
  if sid == "SPRITE_POKEPC_MON" or sid == "SPRITE_PLAYER_POKEMON" then
    return true
  end
  return false
end

function CellOccupancy.isBlockingEntity(entity)
  if not entity then return false end
  if entity.state == "REMOVED" or entity.removed == true then return false end
  if entity.overworldWildOverlay == true then return false end -- debug markers
  if entity.alertIcon == true then return false end
  if entity.isEmote == true or entity.emoteOnly == true then return false end
  if entity.debugMarker == true then return false end
  if entity.fxOnly == true or entity.pureFx == true then return false end
  -- Visible / spawning wilds always block (even while passable=true).
  if entity.overworldWildSpawn == true then
    if entity.hiddenEncounter == true and entity.visibleSprite == false then
      -- Hidden idle body is logical-only; still reserve its tile if registered.
      return entity.registeredInWorld == true or entity.cellX ~= nil
    end
    return true
  end
  if CellOccupancy.isFollowerEntity(entity) then return true end
  if entity.passable == true then return false end
  return true
end

-- Central owner-key API. Prefer this over inventing identities in callers.
function CellOccupancy.ownerKey(entity)
  return entityToken(entity)
end

function CellOccupancy:ownerKeyOf(entity)
  return entityToken(entity)
end

function CellOccupancy.new()
  local self = setmetatable({}, CellOccupancy)
  self.occupied = {}          -- key -> { x, y, owner, kind, entity }
  self.moveReservations = {}  -- key -> { entity, fromX, fromY, toX, toY, owner }
  self.spawnReservations = {} -- key -> { token, x, y }
  self.entityCells = {}       -- owner -> key
  self.entityMoves = {}       -- owner -> key (target)
  self.tokenSpawns = {}       -- token -> key
  self.nextToken = 1
  self.stats = {
    conflicts = 0,
    swapBlocks = 0,
    spawnRejects = 0,
    moveRejects = 0,
  }
  return self
end

function CellOccupancy:clear()
  self.occupied = {}
  self.moveReservations = {}
  self.spawnReservations = {}
  self.entityCells = {}
  self.entityMoves = {}
  self.tokenSpawns = {}
end

function CellOccupancy:counts()
  local occ, moves, spawns = 0, 0, 0
  for _ in pairs(self.occupied) do occ = occ + 1 end
  for _ in pairs(self.moveReservations) do moves = moves + 1 end
  for _ in pairs(self.spawnReservations) do spawns = spawns + 1 end
  return {
    occupied = occ,
    moveReservations = moves,
    spawnReservations = spawns,
    conflicts = self.stats.conflicts or 0,
    swapBlocks = self.stats.swapBlocks or 0,
  }
end

function CellOccupancy:_setOccupied(x, y, owner, kind, entity)
  local key = cellKey(x, y)
  if not key or not owner then return false end
  local prevKey = self.entityCells[owner]
  if prevKey and prevKey ~= key then
    local prev = self.occupied[prevKey]
    if prev and prev.owner == owner then
      self.occupied[prevKey] = nil
    end
  end
  self.occupied[key] = {
    x = x, y = y, owner = owner, kind = kind or "entity", entity = entity,
  }
  self.entityCells[owner] = key
  return true
end

function CellOccupancy:_clearOwnerCell(owner)
  if not owner then return end
  local key = self.entityCells[owner]
  if key then
    local slot = self.occupied[key]
    if slot and slot.owner == owner then
      self.occupied[key] = nil
    end
    self.entityCells[owner] = nil
  end
end

function CellOccupancy:isOccupied(x, y, ignoreEntity)
  local key = cellKey(x, y)
  if not key then return false end
  local ignore = entityToken(ignoreEntity)
  local slot = self.occupied[key]
  if slot and slot.owner ~= ignore then
    return true, slot
  end
  return false
end

function CellOccupancy:isReserved(x, y, ignoreEntity)
  local key = cellKey(x, y)
  if not key then return false end
  local ignore = entityToken(ignoreEntity)
  local move = self.moveReservations[key]
  if move and move.owner ~= ignore then
    return true, move, "move"
  end
  local spawn = self.spawnReservations[key]
  if spawn then
    return true, spawn, "spawn"
  end
  return false
end

function CellOccupancy:ownerAt(x, y)
  local key = cellKey(x, y)
  if not key then return nil end
  local slot = self.occupied[key]
  if slot then return slot.owner, "occupied", slot end
  local move = self.moveReservations[key]
  if move then return move.owner, "move", move end
  local spawn = self.spawnReservations[key]
  if spawn then return spawn.token, "spawn", spawn end
  return nil
end

function CellOccupancy:canReserve(entity, fromX, fromY, toX, toY)
  local owner = entityToken(entity)
  if toX == nil or toY == nil then
    return false, "bad_target"
  end
  if self:isOccupied(toX, toY, entity) then
    return false, "occupied"
  end
  if self:isReserved(toX, toY, entity) then
    return false, "reserved"
  end
  -- Swap prevention: someone at `to` reserved `from`.
  local toKey = cellKey(toX, toY)
  local fromKey = cellKey(fromX, fromY)
  if toKey and fromKey then
    for _, res in pairs(self.moveReservations) do
      if res.owner ~= owner
         and res.fromX == toX and res.fromY == toY
         and res.toX == fromX and res.toY == fromY then
        self.stats.swapBlocks = (self.stats.swapBlocks or 0) + 1
        return false, "swap_blocked"
      end
    end
    -- Also: occupant currently on target intending nothing, but their cell is
    -- fromX of a reverse move already covered by isOccupied on from for the
    -- other entity. Explicit check: target occupied by entity whose current
    -- cell is to and who has reserved from.
    local occ = self.occupied[toKey]
    if occ and occ.owner ~= owner then
      local theirMoveKey = self.entityMoves[occ.owner]
      local theirMove = theirMoveKey and self.moveReservations[theirMoveKey]
      if theirMove and theirMove.toX == fromX and theirMove.toY == fromY then
        self.stats.swapBlocks = (self.stats.swapBlocks or 0) + 1
        return false, "swap_blocked"
      end
    end
  end
  return true
end

function CellOccupancy:reserveSpawn(token, x, y)
  local key = cellKey(x, y)
  if not key then return nil, "bad_cell" end
  if self:isOccupied(x, y) or self:isReserved(x, y) then
    self.stats.spawnRejects = (self.stats.spawnRejects or 0) + 1
    self.stats.conflicts = (self.stats.conflicts or 0) + 1
    return nil, "occupied_or_reserved"
  end
  if token == nil then
    token = "spawn_" .. tostring(self.nextToken)
    self.nextToken = self.nextToken + 1
  end
  token = tostring(token)
  self.spawnReservations[key] = { token = token, x = x, y = y }
  self.tokenSpawns[token] = key
  -- Also mark as occupied under the spawn token so rebuild + checks agree.
  self.occupied[key] = {
    x = x, y = y, owner = token, kind = "spawn", entity = nil,
  }
  self.entityCells[token] = key
  return token
end

function CellOccupancy:commitSpawn(token, entity)
  if token == nil then return false, "no_token" end
  token = tostring(token)
  local key = self.tokenSpawns[token]
  if not key then return false, "unknown_token" end
  local spawn = self.spawnReservations[key]
  self.spawnReservations[key] = nil
  self.tokenSpawns[token] = nil
  local owner = entityToken(entity) or token
  local x = spawn and spawn.x
  local y = spawn and spawn.y
  if entity and entity.cellX ~= nil then
    x, y = entity.cellX, entity.cellY
  end
  -- Drop token occupancy and bind the live entity.
  if self.entityCells[token] then
    local tokKey = self.entityCells[token]
    local slot = self.occupied[tokKey]
    if slot and slot.owner == token then
      self.occupied[tokKey] = nil
    end
    self.entityCells[token] = nil
  end
  if x ~= nil and y ~= nil then
    self:_setOccupied(x, y, owner, "entity", entity)
  end
  return true
end

function CellOccupancy:releaseSpawn(token)
  if token == nil then return false end
  token = tostring(token)
  local key = self.tokenSpawns[token]
  if not key then
    -- Also scan by token owner cell.
    key = self.entityCells[token]
  end
  if key then
    self.spawnReservations[key] = nil
    local slot = self.occupied[key]
    if slot and slot.owner == token then
      self.occupied[key] = nil
    end
  end
  self.tokenSpawns[token] = nil
  self.entityCells[token] = nil
  return true
end

function CellOccupancy:reserveMove(entity, fromX, fromY, toX, toY, opts)
  opts = opts or {}
  local owner = entityToken(entity)
  if not owner then return false, "no_entity" end
  local toKey = cellKey(toX, toY)

  -- Idempotent: same entity already holding the same target succeeds.
  local prevKey = self.entityMoves[owner]
  if prevKey and prevKey == toKey then
    local existing = self.moveReservations[toKey]
    if existing and existing.owner == owner
       and existing.toX == toX and existing.toY == toY then
      if opts.kind then existing.kind = opts.kind end
      existing.fromX = fromX
      existing.fromY = fromY
      existing.entity = entity
      return true, "already_held"
    end
  end

  local ok, why = self:canReserve(entity, fromX, fromY, toX, toY)
  if not ok then
    self.stats.moveRejects = (self.stats.moveRejects or 0) + 1
    if why ~= "swap_blocked" then
      self.stats.conflicts = (self.stats.conflicts or 0) + 1
    end
    return false, why
  end
  -- Ensure origin stays occupied for the duration of the step.
  if fromX ~= nil and fromY ~= nil then
    self:_setOccupied(fromX, fromY, owner, "entity", entity)
  end
  -- Cancel any prior reservation for this entity.
  if prevKey and prevKey ~= toKey then
    local old = self.moveReservations[prevKey]
    if old and old.owner == owner then
      self.moveReservations[prevKey] = nil
    end
  end
  self.moveReservations[toKey] = {
    entity = entity,
    owner = owner,
    fromX = fromX, fromY = fromY,
    toX = toX, toY = toY,
    kind = opts.kind,
  }
  self.entityMoves[owner] = toKey
  return true
end

function CellOccupancy:commitMove(entity)
  local owner = entityToken(entity)
  if not owner then return false end
  local toKey = self.entityMoves[owner]
  local res = toKey and self.moveReservations[toKey]
  local toX = entity and entity.cellX
  local toY = entity and entity.cellY
  if res then
    toX = res.toX
    toY = res.toY
    self.moveReservations[toKey] = nil
  end
  self.entityMoves[owner] = nil
  if toX ~= nil and toY ~= nil then
    self:_setOccupied(toX, toY, owner, "entity", entity)
  end
  return true
end

function CellOccupancy:cancelMove(entity)
  local owner = entityToken(entity)
  if not owner then return false end
  local toKey = self.entityMoves[owner]
  if toKey then
    local res = self.moveReservations[toKey]
    if res and res.owner == owner then
      self.moveReservations[toKey] = nil
    end
  end
  self.entityMoves[owner] = nil
  -- Keep origin occupancy if we still know the entity cell.
  if entity and entity.cellX ~= nil and entity.cellY ~= nil then
    self:_setOccupied(entity.cellX, entity.cellY, owner, "entity", entity)
  end
  return true
end

function CellOccupancy:releaseEntity(entity)
  local owner = entityToken(entity)
  if not owner then return false end
  self:cancelMove(entity)
  self:_clearOwnerCell(owner)
  return true
end

local function absorbEntity(self, entity, kind)
  if not CellOccupancy.isBlockingEntity(entity) then return end
  local owner = entityToken(entity)
  if not owner then return end
  local x, y = entity.cellX, entity.cellY
  if x ~= nil and y ~= nil then
    -- Prefer first writer; do not overwrite a different live owner silently.
    local key = cellKey(x, y)
    local existing = key and self.occupied[key]
    if existing and existing.owner ~= owner and existing.kind ~= "spawn" then
      self.stats.conflicts = (self.stats.conflicts or 0) + 1
    else
      self:_setOccupied(x, y, owner, kind or "entity", entity)
    end
  end
  local tx, ty = entity.targetX, entity.targetY
  if tx ~= nil and ty ~= nil and (tx ~= x or ty ~= y) then
    local toKey = cellKey(tx, ty)
    if toKey and not self.moveReservations[toKey] then
      self.moveReservations[toKey] = {
        entity = entity,
        owner = owner,
        fromX = x, fromY = y,
        toX = tx, toY = ty,
      }
      self.entityMoves[owner] = toKey
    end
  end
end

-- Rebuild live occupancy from world context. Preserves in-flight spawn tokens.
function CellOccupancy:rebuild(context)
  context = context or {}
  local preservedSpawns = {}
  for key, spawn in pairs(self.spawnReservations) do
    preservedSpawns[key] = spawn
  end
  local preservedTokens = {}
  for token, key in pairs(self.tokenSpawns) do
    preservedTokens[token] = key
  end

  self.occupied = {}
  self.moveReservations = {}
  self.entityCells = {}
  self.entityMoves = {}
  self.spawnReservations = preservedSpawns
  self.tokenSpawns = preservedTokens

  -- Restore spawn reservations as occupied.
  for key, spawn in pairs(preservedSpawns) do
    self.occupied[key] = {
      x = spawn.x, y = spawn.y, owner = spawn.token, kind = "spawn", entity = nil,
    }
    self.entityCells[spawn.token] = key
  end

  local player = context.player
  if player and player.cellX ~= nil and player.cellY ~= nil then
    self:_setOccupied(player.cellX, player.cellY, "player", "player", player)
    if player.targetX ~= nil and player.targetY ~= nil
       and (player.targetX ~= player.cellX or player.targetY ~= player.cellY) then
      local toKey = cellKey(player.targetX, player.targetY)
      if toKey then
        self.moveReservations[toKey] = {
          entity = player,
          owner = "player",
          fromX = player.cellX, fromY = player.cellY,
          toX = player.targetX, toY = player.targetY,
        }
        self.entityMoves["player"] = toKey
      end
    end
  end

  local function absorbList(list, kind)
    if not list then return end
    if list[1] ~= nil or #list > 0 then
      for _, e in ipairs(list) do
        absorbEntity(self, e, kind)
      end
    else
      for _, e in pairs(list) do
        absorbEntity(self, e, kind)
      end
    end
  end

  absorbList(context.entities, "entity")
  absorbList(context.npcs, "npc")
  absorbList(context.logicEntities, "wild")
  absorbList(context.followers, "follower")

  -- Optional public follower list from Followers EX (ow.pokepcTrailers).
  absorbList(context.trailers, "follower")
end

function CellOccupancy:assertOnlyOneBlockingEntityPerCell(context, onConflict)
  context = context or {}
  local seen = {}
  local conflicts = {}
  local function consider(entity)
    if not CellOccupancy.isBlockingEntity(entity) then return end
    local x, y = entity.cellX, entity.cellY
    if x == nil or y == nil then return end
    local key = cellKey(x, y)
    local owner = entityToken(entity)
    if seen[key] and seen[key] ~= owner then
      conflicts[#conflicts + 1] = {
        x = x, y = y, a = seen[key], b = owner, entity = entity,
      }
    else
      seen[key] = owner
    end
  end
  local function walk(list)
    if not list then return end
    if list[1] ~= nil or #list > 0 then
      for _, e in ipairs(list) do consider(e) end
    else
      for _, e in pairs(list) do consider(e) end
    end
  end
  walk(context.entities)
  walk(context.logicEntities)
  walk(context.followers)
  walk(context.trailers)
  for _, c in ipairs(conflicts) do
    self.stats.conflicts = (self.stats.conflicts or 0) + 1
    if onConflict then
      pcall(onConflict, c)
    end
  end
  return conflicts
end

return CellOccupancy
