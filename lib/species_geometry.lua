-- Species visual geometry for True Size / variable-size overworld sprites.
-- Logical cell footprint remains 1×1 (16×16 collision / movement / catching).
--
-- Prototype scope: Charizard (dex 6) only. Full migration waits on Flat PASS
-- and Dramatic Shape consuming SpriteRenderer:getPoseGeometry().
local V = ...

local SpeciesGeometry = {}

-- Compressed visual height bands (px). Art-direction targets, not 1:1 Pokédex.
SpeciesGeometry.SIZE_CLASSES = {
  XS  = { minH = 14, maxH = 16, label = "XS" },
  S   = { minH = 17, maxH = 20, label = "S" },
  M   = { minH = 21, maxH = 24, label = "M" },
  L   = { minH = 25, maxH = 29, label = "L" },
  XL  = { minH = 30, maxH = 35, label = "XL" },
  XXL = { minH = 36, maxH = 42, label = "XXL" },
}

-- Manual overrides for unusual silhouettes (scaffold; only Charizard live).
-- Keys are numeric dex ids.
SpeciesGeometry.OVERRIDES = {
  [6] = {
    class = "XL",
    -- HGSS / PokeMMO prototype canvas (source tiles are already 32×32).
    packs = {
      pokemmo = {
        frameWidth = 32,
        frameHeight = 32,
        anchorX = 16,
        anchorY = 32,
        relativeDir = "assets/generated/variable_size_prototype/hgss",
        prototype = true,
      },
    },
    notes = "Charizard variable-size Flat prototype (#1016).",
  },
}

function SpeciesGeometry.normalizeDex(speciesId)
  local n = tonumber(speciesId)
  if n and n >= 1 then return math.floor(n) end
  return nil
end

function SpeciesGeometry.overrideFor(speciesId)
  local dex = SpeciesGeometry.normalizeDex(speciesId)
  if not dex then return nil, nil end
  return SpeciesGeometry.OVERRIDES[dex], dex
end

function SpeciesGeometry.packGeometry(speciesId, packId)
  local ov, dex = SpeciesGeometry.overrideFor(speciesId)
  if not ov or type(ov.packs) ~= "table" then return nil, dex end
  local pack = ov.packs[packId]
  if type(pack) ~= "table" then return nil, dex end
  return pack, dex, ov
end

function SpeciesGeometry.prototypeRelativePath(speciesId, packId, variant)
  local pack = SpeciesGeometry.packGeometry(speciesId, packId)
  if not pack or not pack.prototype or type(pack.relativeDir) ~= "string" then
    return nil
  end
  local dex = SpeciesGeometry.normalizeDex(speciesId)
  if not dex then return nil end
  local v = (variant == "shiny" or variant == "s" or variant == true) and "shiny" or "normal"
  return string.format("%s/%03d-%s.png", pack.relativeDir, dex, v), pack
end

return SpeciesGeometry
