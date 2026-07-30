-- Weighted species/level picks from a map's grass encounter table.
-- Defensive: nil / empty tables are never treated as a valid spawn source.
local V = ...
local Config = V.require("config")

local EncounterPick = {}

local function rng01(rng)
  if type(rng) == "function" then return rng end
  if love and love.math and love.math.random then
    return function(a, b)
      if b == nil then return love.math.random(a) end
      return love.math.random(a, b)
    end
  end
  return function(a, b)
    if b == nil then return math.random(a) end
    return math.random(a, b)
  end
end

function EncounterPick.grassTable(encDef)
  if not encDef then return nil end
  local grass = encDef.grass
  if type(grass) ~= "table" then return nil end
  if type(grass.slots) ~= "table" or #grass.slots == 0 then return nil end
  if (grass.rate or 0) <= 0 then return nil end
  return grass
end

-- Returns { species, level } or nil when the map has no grass slots.
function EncounterPick.pick(encDef, rng)
  rng = rng01(rng)
  local grass = EncounterPick.grassTable(encDef)
  if not grass then return nil end
  local buckets = grass.buckets or Config.ENCOUNTER_BUCKETS
  local pick = rng(0, 255)
  for i, threshold in ipairs(buckets) do
    if pick < threshold then
      local slot = grass.slots[i] or grass.slots[#grass.slots]
      if slot and slot.species then
        return { species = slot.species, level = slot.level or 1 }
      end
      return nil
    end
  end
  local last = grass.slots[#grass.slots]
  if last and last.species then
    return { species = last.species, level = last.level or 1 }
  end
  return nil
end

function EncounterPick.hasGrassTable(encDef)
  return EncounterPick.grassTable(encDef) ~= nil
end

function EncounterPick.slotCount(encDef)
  local grass = EncounterPick.grassTable(encDef)
  return grass and #grass.slots or 0
end

function EncounterPick.summarize(encDef)
  local grass = EncounterPick.grassTable(encDef)
  if not grass then return nil end
  local species = {}
  local lo, hi = math.huge, 0
  for _, slot in ipairs(grass.slots) do
    if slot.species then species[slot.species] = true end
    local lv = slot.level or 1
    if lv < lo then lo = lv end
    if lv > hi then hi = lv end
  end
  local names = {}
  for name in pairs(species) do names[#names + 1] = name end
  table.sort(names)
  return {
    rate = grass.rate,
    slots = #grass.slots,
    species = names,
    levelMin = lo,
    levelMax = hi,
  }
end

-- True when species/level could come from this map's grass table.
function EncounterPick.inTable(encDef, species, level)
  local grass = encDef and encDef.grass
  if not grass or type(grass.slots) ~= "table" then return false end
  for _, slot in ipairs(grass.slots) do
    if slot.species == species and (level == nil or slot.level == level) then
      return true
    end
  end
  return false
end

function EncounterPick.levelRange(encDef)
  local summary = EncounterPick.summarize(encDef)
  if not summary then return nil end
  return summary.levelMin, summary.levelMax
end

return EncounterPick
