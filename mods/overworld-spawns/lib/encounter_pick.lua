-- Weighted species/level picks from a map's grass encounter table.
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

-- Returns { species, level } or nil when the map has no grass slots.
function EncounterPick.pick(encDef, rng)
  rng = rng01(rng)
  local grass = encDef and encDef.grass
  if not grass or not grass.slots or #grass.slots == 0 then return nil end
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
  local grass = encDef and encDef.grass
  return grass ~= nil and type(grass.slots) == "table" and #grass.slots > 0
      and (grass.rate or 0) > 0
end

return EncounterPick
