-- Curated Gen 2 town / indoor ambient Pokémon.
--
-- Separate from random wild grass encounters. These are NPC-like ambient
-- mons using the shared AmbientPokemon renderer. Do not convert Gold NPCs
-- into Pokémon and do not mix Kanto town maps into this table.
--
-- Counts stay conservative. Species are flavour for the town, not encounter
-- slots and not Pokédex-gated.
local Town = {}

-- Each map is a list of { species, count }. A legacy single-row
-- { species = "SENTRET", count = 1 } is still accepted by entriesForMap.
Town.CATALOG = {
  NEW_BARK_TOWN = {
    { species = "SENTRET", count = 1 },
  },
  CHERRYGROVE_CITY = {
    { species = "PIDGEY", count = 1 },
  },
  VIOLET_CITY = {
    { species = "HOOTHOOT", count = 1 },
  },
  AZALEA_TOWN = {
    { species = "SLOWPOKE", count = 1 },
  },
  GOLDENROD_CITY = {
    { species = "SNUBBULL", count = 1 },
  },
  ECRUTEAK_CITY = {
    { species = "HOOTHOOT", count = 1 },
  },
  OLIVINE_CITY = {
    { species = "MEOWTH", count = 1 },
  },
  CIANWOOD_CITY = {
    { species = "SHUCKLE", count = 1 },
  },
  MAHOGANY_TOWN = {
    { species = "SENTRET", count = 1 },
  },
  BLACKTHORN_CITY = {
    { species = "DRATINI", count = 1 },
  },
}

local function upper(s)
  return tostring(s or ""):upper()
end

function Town.forMap(mapId)
  if mapId == nil then return nil end
  return Town.CATALOG[tostring(mapId)]
end

function Town.entriesForMap(mapId)
  local row = Town.forMap(mapId)
  if not row then return {} end
  if type(row) ~= "table" then return {} end
  -- Legacy single-row: { species = "SENTRET", count = 1 }
  if type(row.species) == "string" then
    return { { species = upper(row.species), count = tonumber(row.count) or 1 } }
  end
  local out = {}
  for _, entry in ipairs(row) do
    if type(entry) == "table" and type(entry.species) == "string" then
      out[#out + 1] = {
        species = upper(entry.species),
        count = math.max(0, tonumber(entry.count) or 1),
      }
    end
  end
  return out
end

function Town.speciesForMap(mapId)
  local entries = Town.entriesForMap(mapId)
  return entries[1] and entries[1].species or nil
end

function Town.speciesListForMap(mapId)
  local names = {}
  local seen = {}
  for _, entry in ipairs(Town.entriesForMap(mapId)) do
    if entry.species and not seen[entry.species] then
      seen[entry.species] = true
      names[#names + 1] = entry.species
    end
  end
  return names
end

function Town.targetCount(mapId)
  local total = 0
  for _, entry in ipairs(Town.entriesForMap(mapId)) do
    total = total + (tonumber(entry.count) or 0)
  end
  return total
end

return Town
