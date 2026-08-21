-- PMDCollab portrait resolution — independent of overworld Sprite Style.
local V = ...

local PortraitRegistry = {}

PortraitRegistry.GENERIC_POOL = {
  "happy",
  "joyous",
  "inspired",
  "determined",
  "normal",
}

local _pathCache = {}

local function normalizeVariant(variant)
  if variant == true or variant == "shiny" or variant == "s" or variant == "SHINY" then
    return "shiny"
  end
  return "normal"
end

local function rng01(rng)
  if type(rng) == "function" then
    local v = rng()
    if type(v) == "number" then
      if v < 0 then return 0 end
      if v > 1 then return 1 end
      return v
    end
  end
  return math.random()
end

function PortraitRegistry.loadPath(mod, rel)
  if type(rel) ~= "string" or rel == "" then return nil end
  local cached = _pathCache[rel]
  if cached ~= nil then
    return cached ~= false and cached or nil
  end
  local path = nil
  if mod and mod.assets and type(mod.assets.path) == "function" then
    local ok, p = pcall(function() return mod.assets:path(rel) end)
    if ok and type(p) == "string" and p ~= "" then
      path = p
    end
  end
  if not path and mod and type(mod.path) == "string" then
    path = mod.path .. "/" .. rel
  end
  if not path then
    path = rel
  end
  _pathCache[rel] = path
  return path
end

function PortraitRegistry.resetCache()
  _pathCache = {}
end

local function ensureAssets(mod)
  local Assets = V.require("pmdcollab_assets")
  if not Assets.isReady() then
    Assets.load(mod)
  end
  return Assets
end

local function emotionRel(entry, slug)
  if type(entry) ~= "table" or type(entry.emotions) ~= "table" then
    return nil
  end
  return entry.emotions[slug]
end

function PortraitRegistry.pickGenericEmotion(dex, variant, rng, mod)
  local Assets = ensureAssets(mod)
  local entry = select(1, Assets.portraitEntry(dex, variant))
  if not entry then return nil end
  local available = {}
  for _, slug in ipairs(PortraitRegistry.GENERIC_POOL) do
    if emotionRel(entry, slug) then
      available[#available + 1] = slug
    end
  end
  if #available == 0 then
    if emotionRel(entry, "normal") then return "normal" end
    return nil
  end
  local idx = math.floor(rng01(rng) * #available) + 1
  if idx < 1 then idx = 1 end
  if idx > #available then idx = #available end
  return available[idx]
end

--- Resolve a portrait for canonical species identity.
-- opts: shiny, mood, randomGeneric, rng, mod
-- Fallback: requested mood → normal → nil (no empty frame).
function PortraitRegistry.resolve(species, opts)
  opts = opts or {}
  local mod = opts.mod
  local Assets = ensureAssets(mod)
  local SpeciesAssets = V.require("species_assets")
  local dex = SpeciesAssets.idFor(species)
  if not dex then
    return nil
  end
  local variant = normalizeVariant(opts.shiny or opts.variant)
  local entry, usedVariant = Assets.portraitEntry(dex, variant)
  if not entry then
    return nil
  end

  local mood = opts.mood
  if type(mood) == "string" then
    mood = string.lower(mood)
  else
    mood = nil
  end

  if opts.randomGeneric == true and not mood then
    mood = PortraitRegistry.pickGenericEmotion(dex, usedVariant or variant, opts.rng, mod)
  end
  if not mood then
    mood = "normal"
  end

  local rel = emotionRel(entry, mood)
  if not rel and mood ~= "normal" then
    mood = "normal"
    rel = emotionRel(entry, "normal")
  end
  if not rel then
    return nil
  end
  return {
    dex = dex,
    emotion = mood,
    rel = rel,
    path = PortraitRegistry.loadPath(mod, rel),
    variant = usedVariant or variant,
  }
end

return PortraitRegistry
