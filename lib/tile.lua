-- Gen1Recomp walk-grid tile size.
-- Source of truth: NPC.lua / Player set px,py = cell * 16; Collision steps 16px.
-- Never invent a different tile size for overworld wilds.
local V = ...

local Tile = {}

Tile.WIDTH = 16
Tile.HEIGHT = 16
Tile.CELL = 16

-- Soft inset for the one-tile visual footprint (keeps feet readable in grass).
Tile.USABLE_WIDTH_FRAC = 0.90
Tile.USABLE_HEIGHT_FRAC = 0.95

function Tile.size()
  return Tile.WIDTH, Tile.HEIGHT
end

function Tile.usableSize()
  return Tile.WIDTH * Tile.USABLE_WIDTH_FRAC,
         Tile.HEIGHT * Tile.USABLE_HEIGHT_FRAC
end

function Tile.pixelsForCell(cellX, cellY)
  return (cellX or 0) * Tile.CELL, (cellY or 0) * Tile.CELL
end

return Tile
