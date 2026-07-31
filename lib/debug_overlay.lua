-- Visual spawn-tile overlay using passable marker entities on ow.entities.
-- Public path only: same pose()/draw() entity contract as wild spawns.
-- Never mutates collision, map data, or player position.
--
-- Legend (RGBA fills):
--   valid spawn tile          green
--   blocked tile              red
--   warp tile                 blue
--   NPC occupied              orange
--   excluded by player dist   yellow
local V = ...
local Config = V.require("config")
local Grass = V.require("grass")
local DebugLog = V.require("debug_log")

local DebugOverlay = {}
DebugOverlay.__index = DebugOverlay

local CELL = 16

local COLORS = {
  valid = { 0.15, 0.85, 0.25, 0.28 },
  blocked = { 0.9, 0.15, 0.15, 0.28 },
  warp = { 0.2, 0.35, 0.95, 0.28 },
  npc = { 0.95, 0.55, 0.1, 0.28 },
  player_distance = { 0.95, 0.9, 0.15, 0.22 },
}

local Marker = {}
Marker.__index = Marker

function Marker.new(x, y, kind)
  local self = setmetatable({}, Marker)
  self.overworldWildOverlay = true
  self.passable = true
  self.cellX = x
  self.cellY = y
  self.px = x * CELL
  self.py = y * CELL
  self.kind = kind
  self.color = COLORS[kind] or COLORS.valid
  return self
end

function Marker:pose()
  return nil, self.px, self.py, "down", 0, false, false
end

function Marker:draw(camX, camY)
  if not (love and love.graphics) then return end
  local c = self.color
  love.graphics.setColor(c[1], c[2], c[3], c[4])
  love.graphics.rectangle("fill",
    self.px - (camX or 0),
    self.py - (camY or 0),
    CELL, CELL)
  love.graphics.setColor(1, 1, 1, 1)
end

function DebugOverlay.new(mod, logic)
  local self = setmetatable({}, DebugOverlay)
  self.mod = mod
  self.logic = logic
  self.markers = {}
  return self
end

function DebugOverlay:clear()
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if ow and ow.entities then
    for i = #ow.entities, 1, -1 do
      if ow.entities[i] and ow.entities[i].overworldWildOverlay then
        table.remove(ow.entities, i)
      end
    end
  end
  self.markers = {}
end

local function classifyTile(map, entities, player, x, y, minDist, maxDist, mode)
  if not map then return nil end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  if x < 0 or y < 0 or x >= w or y >= h then return nil end
  if map.warpAtCell and map:warpAtCell(x, y) then return "warp" end
  if mode ~= "water" and map.isWalkableCell and not map:isWalkableCell(x, y) then
    return "blocked"
  end
  for _, e in ipairs(entities or {}) do
    if e and not e.passable and not e.overworldWildOverlay
       and e.cellX == x and e.cellY == y then
      return "npc"
    end
  end
  if player and player.cellX == x and player.cellY == y then
    return "npc"
  end
  local ok, reason = Grass.validateEligibleTile(
    map, entities, player, x, y, minDist, maxDist, nil, nil, mode or "grass")
  if ok then return "valid" end
  if reason and (reason:find("too close") or reason:find("search radius")) then
    return "player_distance"
  end
  return nil
end

function DebugOverlay:rebuild()
  self:clear()
  if not Config.showSpawnTileOverlay(self.mod) then return end

  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if not ow or not ow.map then
    DebugLog.info(self.mod, "spawn tile overlay: no overworld map")
    return
  end

  local map = ow.map
  local minDist = Config.DEFAULTS.min_player_distance
  local maxDist = Config.DEFAULTS.max_player_distance
  local cells = self.logic.eligibleCache or Grass.cells(map)
  local mode = (self.logic.surfaceInfo and self.logic.surfaceInfo.tileMode) or "grass"
  local placed = 0
  local coords = {}

  for _, cell in ipairs(cells) do
    local kind = classifyTile(map, ow.entities, ow.player, cell.x, cell.y,
                              minDist, maxDist, mode)
    if kind then
      local marker = Marker.new(cell.x, cell.y, kind)
      self.markers[#self.markers + 1] = marker
      ow.entities = ow.entities or {}
      table.insert(ow.entities, marker)
      placed = placed + 1
      if kind == "valid" then
        coords[#coords + 1] = ("(%d,%d)"):format(cell.x, cell.y)
      end
    end
  end

  DebugLog.info(self.mod, "spawn tile overlay markers=%d valid_logged=%d",
                placed, math.min(#coords, 40))
  if #coords > 0 then
    local limit = math.min(#coords, 40)
    DebugLog.debug(self.mod, "valid spawn tiles: %s%s",
                   table.concat(coords, " ", 1, limit),
                   #coords > limit and " ..." or "")
  end
end

function DebugOverlay:legend()
  return {
    { kind = "valid", color = "green", meaning = "valid spawn tile" },
    { kind = "blocked", color = "red", meaning = "blocked tile" },
    { kind = "warp", color = "blue", meaning = "warp tile" },
    { kind = "npc", color = "orange", meaning = "NPC / player occupied" },
    { kind = "player_distance", color = "yellow",
      meaning = "excluded by player distance" },
  }
end

return DebugOverlay
