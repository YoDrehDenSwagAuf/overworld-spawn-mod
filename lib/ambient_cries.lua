-- Curated textual cry lines for ambient Town Pokémon + generic fragment fallback.
-- Gen1Recomp exposes audio cry data (pitch/base/length / PCM) only — not
-- usable as TextBox speech.
--
-- Prefer curated lines when present. Otherwise derive a short species-name
-- fragment (never leave the player with "[...]").
local V = ...

local AmbientCries = {}

-- Legacy constant kept for tests / callers that still check the old sentinel.
-- textFor() no longer returns this for valid species keys.
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

-- Readable display overrides for awkward internal keys (identity stays canonical).
AmbientCries.DISPLAY_NAME = {
  MR_MIME = "Mr. Mime",
  FARFETCHD = "Farfetchd",
  HO_OH = "Ho-Oh",
  PORYGON2 = "Porygon2",
  NIDOQUEEN = "Nidoqueen",
  NIDOKING = "Nidoking",
}

function AmbientCries.normalizeSpecies(species)
  if type(species) ~= "string" or species == "" then return nil end
  return species:upper()
end

--- Human-readable species label for dialogue (not a stable identity key).
function AmbientCries.displayName(species)
  local key = AmbientCries.normalizeSpecies(species)
  if not key then return "Pokemon" end
  if AmbientCries.DISPLAY_NAME[key] then
    return AmbientCries.DISPLAY_NAME[key]
  end
  -- Strip gender suffixes used by internal ids.
  key = key:gsub("_F$", ""):gsub("_M$", "")
  -- Title-case underscore tokens: HO_OH already handled; NIDORAN → Nidoran.
  local parts = {}
  for part in key:gmatch("[^_]+") do
    local lower = part:lower()
    parts[#parts + 1] = lower:sub(1, 1):upper() .. lower:sub(2)
  end
  if #parts == 0 then return "Pokemon" end
  return table.concat(parts, " ")
end

--- Short cry-like fragment, e.g. Pika!, Chari!, Ho!
function AmbientCries.fragmentFor(species)
  local display = AmbientCries.displayName(species)
  -- First readable token (ignore "Mr." style particles for fragment length).
  local token = display:match("([%a]+)") or display
  token = tostring(token or "Pokemon")
  -- Keep internal capitalization of the display token's first letter.
  local clean = token:sub(1, 1):upper() .. token:sub(2)
  local n = #clean
  if n <= 0 then return "!" end
  local take = 4
  if n >= 8 then take = 5 end
  if n <= take then
    return clean .. "!"
  end
  return clean:sub(1, take) .. "!"
end

--- Return curated cry text, or a generated species fragment (never "[...]" for
-- a valid species key). Nil/empty species still returns FALLBACK.
function AmbientCries.textFor(species)
  local key = AmbientCries.normalizeSpecies(species)
  if not key then return AmbientCries.FALLBACK end
  local hit = AmbientCries.CURATED[key]
  if type(hit) == "string" and hit ~= "" then
    return hit
  end
  return AmbientCries.fragmentFor(key)
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
