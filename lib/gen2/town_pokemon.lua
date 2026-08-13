-- Curated Gen 2 town / indoor ambient Pokémon.
--
-- Separate from random wild grass encounters. These are NPC-like ambient
-- mons using the shared AmbientPokemon renderer. Do not convert Gold NPCs
-- into Pokémon and do not dump a full Johto town catalog here.
--
-- First proof: New Bark Town, one Sentret. Other Gold towns stay empty
-- until a later PR adds curated rows (never Kanto fallback species).
local Town = {}

Town.CATALOG = {
  NEW_BARK_TOWN = {
    species = "SENTRET",
    count = 1,
  },
}

function Town.forMap(mapId)
  if mapId == nil then return nil end
  return Town.CATALOG[tostring(mapId)]
end

function Town.speciesForMap(mapId)
  local row = Town.forMap(mapId)
  return row and row.species or nil
end

function Town.targetCount(mapId)
  local row = Town.forMap(mapId)
  if not row then return 0 end
  return tonumber(row.count) or 1
end

return Town
