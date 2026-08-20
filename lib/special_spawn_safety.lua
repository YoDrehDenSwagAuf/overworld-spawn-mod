-- Reserved overworld cells that Wilds must never occupy with a battleable spawn.
--
-- Story / scripted mandatory battles share a tile with normal wild tables.
-- If a Wilds entity sits on that cell when the script fires, the engine can
-- collide two battle paths and force-close (Pokémon Tower 6F Marowak).
--
-- Keep this list small: only proven mandatory trigger cells, gated by the
-- same event flag the engine uses so the tile returns to normal afterwards.
local SpecialSpawnSafety = {}

-- Gen1Recomp / pokered: PokemonTower6FMarowakCoords = dbmapcoord 10, 16
-- while EVENT_BEAT_GHOST_MAROWAK is unset. Verified against engine drivers:
-- tests/drivers/marowak_departed_bug867_test.lua
-- tests/drivers/ghost_unveil_bug492_test.lua
local RESERVED = {
  {
    mapId = "POKEMON_TOWER_6F",
    x = 10,
    y = 16,
    -- Active only before the scripted ghost Marowak is cleared.
    flagUnset = "EVENT_BEAT_GHOST_MAROWAK",
    reason = "scripted ghost Marowak trigger",
  },
}

local function flagIsSet(game, flagName)
  if not flagName or type(game) ~= "table" then return false end
  local flags = game.save and game.save.flags
  if type(flags) ~= "table" then return false end
  return flags[flagName] == true
end

--- True when (mapId, x, y) is an active mandatory story-battle trigger cell.
function SpecialSpawnSafety.isReserved(game, mapId, x, y)
  if mapId == nil or x == nil or y == nil then return false end
  local mx, my = tonumber(x), tonumber(y)
  if not mx or not my then return false end
  for i = 1, #RESERVED do
    local entry = RESERVED[i]
    if entry.mapId == mapId and entry.x == mx and entry.y == my then
      if entry.flagUnset and flagIsSet(game, entry.flagUnset) then
        return false
      end
      return true, entry.reason or "story trigger reserved"
    end
  end
  return false
end

--- Iterate active reserved cells on a map (for purge / diagnostics).
-- @return list of { x, y, reason }
function SpecialSpawnSafety.activeCells(game, mapId)
  local out = {}
  if mapId == nil then return out end
  for i = 1, #RESERVED do
    local entry = RESERVED[i]
    if entry.mapId == mapId then
      if not (entry.flagUnset and flagIsSet(game, entry.flagUnset)) then
        out[#out + 1] = {
          x = entry.x,
          y = entry.y,
          reason = entry.reason or "story trigger reserved",
        }
      end
    end
  end
  return out
end

-- Expose table for focused unit tests (do not mutate at runtime).
SpecialSpawnSafety._RESERVED = RESERVED

return SpecialSpawnSafety
