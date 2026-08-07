-- Curated textual cry lines for ambient Town Pokémon.
-- Gen1Recomp exposes audio cry data (pitch/base/length / PCM) only — not
-- usable as TextBox speech. When no curated line exists, return exactly "[...]".
local V = ...

local AmbientCries = {}

AmbientCries.FALLBACK = "[...]"

-- Small curated table for iconic peaceful species only. Do not invent 151.
AmbientCries.CURATED = {
  PIKACHU = "Pikaa...",
  MEOWTH = "Meow...",
  EEVEE = "Vee...",
  PSYDUCK = "Psy...",
  JIGGLYPUFF = "Jiggly...",
  CLEFAIRY = "Clef...",
  SLOWPOKE = "Slooow...",
  GROWLITHE = "Growl...",
  VULPIX = "Vulp...",
  CHANSEY = "Chan...",
}

function AmbientCries.normalizeSpecies(species)
  if type(species) ~= "string" or species == "" then return nil end
  return species:upper()
end

--- Return curated cry text or exactly "[...]".
function AmbientCries.textFor(species)
  local key = AmbientCries.normalizeSpecies(species)
  if not key then return AmbientCries.FALLBACK end
  local hit = AmbientCries.CURATED[key]
  if type(hit) == "string" and hit ~= "" then
    return hit
  end
  return AmbientCries.FALLBACK
end

function AmbientCries.curatedCount()
  local n = 0
  for _ in pairs(AmbientCries.CURATED) do n = n + 1 end
  return n
end

function AmbientCries.hasCurated(species)
  local key = AmbientCries.normalizeSpecies(species)
  return key ~= nil and AmbientCries.CURATED[key] ~= nil
end

return AmbientCries
