-- Encounter-surface abstraction: grass, cave/indoor, water, and other.
-- Spawn eligibility and behaviours key off surface type, not "grass == true".
local V = ...
local EncounterPick = V.require("encounter_pick")

local Surface = {}

Surface.GRASS = "GRASS"
Surface.CAVE = "CAVE"
Surface.WATER = "WATER"
Surface.INTERIOR = "INTERIOR"
Surface.OTHER = "OTHER_ENCOUNTER"

-- Behaviours allowed per surface (Hidden Cave only when a cave effect exists).
Surface.BEHAVIORS = {
  [Surface.GRASS] = {
    "IDLE_LOOK", "GRASS_WANDER", "AGGRESSIVE", "HIDDEN_GRASS",
  },
  [Surface.CAVE] = {
    "IDLE_LOOK", "GRASS_WANDER", "AGGRESSIVE", "HIDDEN_CAVE",
  },
  [Surface.WATER] = {
    "WATER_IDLE", "WATER_WANDER", "WATER_AGGRESSIVE",
  },
  [Surface.INTERIOR] = {
    "IDLE_LOOK", "GRASS_WANDER", "AGGRESSIVE",
  },
  [Surface.OTHER] = {
    "IDLE_LOOK", "GRASS_WANDER", "AGGRESSIVE",
  },
}

local function indoorConfig(game)
  local field = game and game.data and game.data.field
  return field and field.indoorEncounters or nil
end

-- Same indoor rule Gen1Recomp uses for cave/tower/mansion wild rolls:
-- map index >= firstIndoorMap and tileset ~= FOREST.
function Surface.isIndoorEncounterMap(game, map)
  if not map or not map.def then return false end
  local indoor = indoorConfig(game)
  if not indoor then
    -- Fallback when field data is absent (headless fixtures): tileset / id.
    local tileset = tostring(map.def.tileset or ""):upper()
    local id = tostring(map.id or ""):upper()
    if tileset == "CAVERN" or tileset == "CEMETERY" or tileset == "FACILITY"
       or tileset == "SHIP" or tileset == "MANSION"
       or id:find("CAVE", 1, true) or id:find("MT_", 1, true)
       or id:find("DIGLETT", 1, true) or id:find("POWER_PLANT", 1, true)
       or id:find("POKEMON_TOWER", 1, true) or id:find("MANSION", 1, true) then
      return true
    end
    return false
  end
  local index = map.def.index
  if index == nil then return false end
  if index < (indoor.firstIndoorMap or 37) then return false end
  if map.def.tileset == (indoor.excludedTileset or "FOREST") then
    return false
  end
  return true
end

function Surface.isWaterMapSupport(encDef)
  return EncounterPick.kindTable(encDef, "water") ~= nil
end

-- Resolve the primary spawn surface for a map.
-- Priority: grass tiles + grass table → indoor/cave walkables + grass table
-- → water tiles + water table → unsupported.
function Surface.resolve(game, map, encDef)
  local hasGrassTable = EncounterPick.hasGrassTable(encDef)
  local grassCount = 0
  if map and map.isGrassCell then
    local w = map.widthCells or 0
    local h = map.heightCells or 0
    for cy = 0, h - 1 do
      for cx = 0, w - 1 do
        if map:isGrassCell(cx, cy) then grassCount = grassCount + 1 end
      end
    end
  end

  if hasGrassTable and grassCount > 0 then
    return {
      surface = Surface.GRASS,
      encounterKind = "grass",
      tileMode = "grass",
      supported = true,
      grassTileCount = grassCount,
      reason = nil,
    }
  end

  if hasGrassTable and Surface.isIndoorEncounterMap(game, map) then
    return {
      surface = Surface.CAVE,
      encounterKind = "grass", -- caves store slots in .grass in Gen1 data
      tileMode = "walkable",
      supported = true,
      grassTileCount = 0,
      reason = nil,
    }
  end

  if Surface.isWaterMapSupport(encDef) then
    return {
      surface = Surface.WATER,
      encounterKind = "water",
      tileMode = "water",
      supported = true,
      grassTileCount = grassCount,
      reason = nil,
      -- Classic rod rolls stay separate; visible Water Mons may use rod pools.
      fishingSeparate = true,
    }
  end

  if hasGrassTable and grassCount == 0 then
    return {
      surface = Surface.OTHER,
      encounterKind = "grass",
      tileMode = "none",
      supported = false,
      grassTileCount = 0,
      reason = "encounter table present but no grass/cave/water tiles",
    }
  end

  return {
    surface = Surface.OTHER,
    encounterKind = nil,
    tileMode = "none",
    supported = false,
    grassTileCount = 0,
    reason = "no supported encounter surface",
  }
end

function Surface.allowsBehavior(surface, behavior)
  local list = Surface.BEHAVIORS[surface]
  if not list then return false end
  for _, b in ipairs(list) do
    if b == behavior then return true end
  end
  return false
end

function Surface.usesGrassOverlay(surface)
  return surface == Surface.GRASS
end

-- True when an entity should use water presentation (sprites / sink offset).
-- Prefers entity.surface and water behaviours; optionally checks map water cells.
function Surface.isWaterEntity(entity, map)
  if not entity then return false end
  if entity.surface == Surface.WATER then return true end
  local b = entity.behavior or entity.behaviour
  if b == "WATER_IDLE" or b == "WATER_WANDER" or b == "WATER_AGGRESSIVE" then
    return true
  end
  if map and map.isWaterCell and entity.cellX ~= nil and entity.cellY ~= nil then
    local ok, water = pcall(map.isWaterCell, map, entity.cellX, entity.cellY)
    if ok and water then return true end
  end
  return false
end

function Surface.hiddenEffect(surface)
  if surface == Surface.GRASS then return "grass_shake" end
  if surface == Surface.CAVE then return "dust" end
  return nil
end

return Surface
