-- Neighbor / connection helpers for outdoor map seams.
-- Reads Gen1Recomp map connection data when present; never invents a second
-- connection graph. Offsets rebase local cell coords across a root-map change.
local V = ...
local EncounterIndex = V.require("encounter_index")

local MapNeighbors = {}

local OUTDOOR_TYPES = {
  route = true,
  town = true,
  city = true,
  overworld = true,
  water = true,
}

local SAFE_INTERIOR_TYPES = {
  building = true,
}

local DIR_DELTA = {
  north = { 0, -1 }, n = { 0, -1 }, up = { 0, -1 },
  south = { 0, 1 }, s = { 0, 1 }, down = { 0, 1 },
  west = { -1, 0 }, w = { -1, 0 }, left = { -1, 0 },
  east = { 1, 0 }, e = { 1, 0 }, right = { 1, 0 },
}

function MapNeighbors.mapType(game, mapId)
  return EncounterIndex.mapTypeOf(game, mapId)
end

function MapNeighbors.isOutdoorType(mapType)
  return OUTDOOR_TYPES[tostring(mapType or "")] == true
end

function MapNeighbors.isSafeInteriorType(mapType)
  return SAFE_INTERIOR_TYPES[tostring(mapType or "")] == true
end

function MapNeighbors.isOutdoorMap(game, mapId)
  return MapNeighbors.isOutdoorType(MapNeighbors.mapType(game, mapId))
end

function MapNeighbors.isSafeInteriorMap(game, mapId)
  local t = MapNeighbors.mapType(game, mapId)
  if MapNeighbors.isSafeInteriorType(t) then return true end
  local id = tostring(mapId or ""):upper()
  if id:find("CENTER", 1, true) or id:find("_HOUSE", 1, true)
     or id:find("_GYM", 1, true) or id:find("MART", 1, true)
     or id:find("LAB", 1, true) or id:find("GATE", 1, true) then
    return true
  end
  return false
end

local function mapDef(game, mapId, ow)
  if ow and ow.map and ow.map.id == mapId and ow.map.def then
    return ow.map.def, ow.map
  end
  local maps = game and game.data and game.data.maps
  return maps and maps[mapId], nil
end

-- Normalize heterogeneous engine connection tables into:
-- { mapId, direction, xOffset, yOffset, width, height }
local function normalizeEntry(raw, fallbackDir)
  if type(raw) ~= "table" then return nil end
  local mapId = raw.mapId or raw.map or raw.map_id or raw.target or raw.id
  if type(mapId) ~= "string" or mapId == "" then return nil end
  local dir = raw.direction or raw.dir or raw.facing or fallbackDir
  if type(dir) == "string" then dir = dir:lower() else dir = nil end
  local xOff = tonumber(raw.xOffset or raw.x_offset or raw.offsetX or raw.ox)
  local yOff = tonumber(raw.yOffset or raw.y_offset or raw.offsetY or raw.oy)
  local offset = tonumber(raw.offset)
  if offset ~= nil then
    if dir == "north" or dir == "south" or dir == "n" or dir == "s"
       or dir == "up" or dir == "down" then
      if xOff == nil then xOff = offset end
    else
      if yOff == nil then yOff = offset end
    end
  end
  return {
    mapId = mapId,
    direction = dir,
    xOffset = xOff or 0,
    yOffset = yOff or 0,
    width = tonumber(raw.width),
    height = tonumber(raw.height),
  }
end

local function collectFromTable(conn, out)
  if type(conn) ~= "table" then return end
  -- Array form.
  if conn[1] ~= nil then
    for _, entry in ipairs(conn) do
      local n = normalizeEntry(entry, nil)
      if n then out[#out + 1] = n end
    end
    return
  end
  -- Keyed by direction: connections.north = { map=..., offset=... }
  for key, entry in pairs(conn) do
    if type(key) == "string" and type(entry) == "table" then
      local n = normalizeEntry(entry, key)
      if n then out[#out + 1] = n end
    end
  end
end

function MapNeighbors.connectionsOf(game, mapId, ow)
  local out = {}
  local def, liveMap = mapDef(game, mapId, ow)
  local sources = {
    def and def.connections,
    liveMap and liveMap.connections,
    ow and ow.neighborMaps,
    ow and ow.neighbors,
    ow and ow.connectedMaps,
  }
  for _, src in ipairs(sources) do
    collectFromTable(src, out)
  end
  -- Deduplicate by mapId+direction.
  local seen, uniq = {}, {}
  for _, c in ipairs(out) do
    local k = tostring(c.mapId) .. "|" .. tostring(c.direction)
    if not seen[k] then
      seen[k] = true
      uniq[#uniq + 1] = c
    end
  end
  return uniq
end

function MapNeighbors.findConnection(game, fromMapId, toMapId, ow)
  if not fromMapId or not toMapId then return nil end
  for _, c in ipairs(MapNeighbors.connectionsOf(game, fromMapId, ow)) do
    if c.mapId == toMapId then return c, "forward" end
  end
  for _, c in ipairs(MapNeighbors.connectionsOf(game, toMapId, ow)) do
    if c.mapId == fromMapId then return c, "reverse" end
  end
  return nil
end

function MapNeighbors.areConnected(game, fromMapId, toMapId, ow)
  return MapNeighbors.findConnection(game, fromMapId, toMapId, ow) ~= nil
end

function MapNeighbors.activeNeighborMapIds(game, rootMapId, ow)
  local ids = { rootMapId }
  local seen = { [rootMapId] = true }
  for _, c in ipairs(MapNeighbors.connectionsOf(game, rootMapId, ow)) do
    if c.mapId and not seen[c.mapId] then
      seen[c.mapId] = true
      ids[#ids + 1] = c.mapId
    end
  end
  return ids, seen
end

-- Compute cell offset that transforms coords from the old root map into the
-- new root map. Prefer engine connection offsets; fall back to player delta
-- captured across the map change (same logical world step).
function MapNeighbors.connectionOffset(game, fromMapId, toMapId, ow, stash)
  local conn, sense = MapNeighbors.findConnection(game, fromMapId, toMapId, ow)
  local dx, dy = 0, 0
  if conn then
    dx = tonumber(conn.xOffset) or 0
    dy = tonumber(conn.yOffset) or 0
    if sense == "reverse" then
      -- Connection stored on destination pointing back at origin: invert.
      dx, dy = -dx, -dy
    end
    -- When only an alignment offset is known, combine with map extents + dir.
    local dir = conn.direction
    if dir and DIR_DELTA[dir] then
      local fromDef = select(1, mapDef(game, fromMapId, nil))
      local toDef = select(1, mapDef(game, toMapId, ow))
      local fromW = (fromDef and (fromDef.widthCells or fromDef.width)) or 0
      local fromH = (fromDef and (fromDef.heightCells or fromDef.height)) or 0
      local toW = (toDef and (toDef.widthCells or toDef.width)) or 0
      local toH = (toDef and (toDef.heightCells or toDef.height)) or 0
      if sense == "forward" then
        -- Crossing from `from` in `dir` into `to`.
        if dir == "north" or dir == "n" or dir == "up" then
          dy = dy + toH
        elseif dir == "south" or dir == "s" or dir == "down" then
          dy = dy - fromH
        elseif dir == "west" or dir == "w" or dir == "left" then
          dx = dx + toW
        elseif dir == "east" or dir == "e" or dir == "right" then
          dx = dx - fromW
        end
      else
        -- Reverse-listed connection: crossing into `to` from a neighbor that
        -- lists `from` in `dir` means we arrived from the opposite side.
        if dir == "north" or dir == "n" or dir == "up" then
          dy = dy - fromH
        elseif dir == "south" or dir == "s" or dir == "down" then
          dy = dy + toH
        elseif dir == "west" or dir == "w" or dir == "left" then
          dx = dx - fromW
        elseif dir == "east" or dir == "e" or dir == "right" then
          dx = dx + toW
        end
      end
    end
  end

  -- Player-delta fallback / correction (authoritative for the live step).
  if stash and stash.playerX ~= nil and stash.playerY ~= nil
     and ow and ow.player and ow.player.cellX ~= nil then
    local pdx = (ow.player.cellX or 0) - (stash.playerX or 0)
    local pdy = (ow.player.cellY or 0) - (stash.playerY or 0)
    -- Prefer player delta when connection metadata is missing or zero-ish,
    -- or when it disagrees wildly (bad map tables).
    if not conn or (dx == 0 and dy == 0) then
      dx, dy = pdx, pdy
    elseif math.abs(pdx - dx) + math.abs(pdy - dy) > 64 then
      dx, dy = pdx, pdy
    else
      -- Prefer player delta: it matches the engine's actual root rebase.
      dx, dy = pdx, pdy
    end
  end

  return { x = dx, y = dy, connection = conn }
end

function MapNeighbors.rebaseCell(x, y, offset)
  offset = offset or { x = 0, y = 0 }
  local dx = tonumber(offset.x) or 0
  local dy = tonumber(offset.y) or 0
  if x == nil or y == nil then return x, y end
  return x + dx, y + dy
end

function MapNeighbors.rebasePoint(pt, offset)
  if not pt then return pt end
  local nx, ny = MapNeighbors.rebaseCell(pt.x, pt.y, offset)
  local out = {}
  for k, v in pairs(pt) do out[k] = v end
  out.x, out.y = nx, ny
  return out
end

return MapNeighbors
