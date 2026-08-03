-- Weighted species/level picks from a map's encounter tables.
-- Defensive: nil / empty tables are never treated as a valid spawn source.
--
-- Grass and cave (indoor) spawns use the grass table. Classic Surf rolls use
-- the water table. Visible Water Mons build a separate zone-aware pool from
-- Surf + fishing (Old/Good/Super Rod) via water_spawn.lua — not this pick().
-- EncounterPick.pick("fishing") still returns nil (rod rolls stay engine-side).
local V = ...
local Config = V.require("config")

local EncounterPick = {}

EncounterPick.KINDS = { "grass", "water", "fishing" }

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

local function tableOf(encDef, kind)
  if not encDef then return nil end
  local t = encDef[kind]
  if type(t) ~= "table" then return nil end
  if type(t.slots) ~= "table" or #t.slots == 0 then return nil end
  if kind ~= "fishing" and (t.rate or 0) <= 0 then return nil end
  return t
end

function EncounterPick.grassTable(encDef)
  return tableOf(encDef, "grass")
end

function EncounterPick.kindTable(encDef, kind)
  return tableOf(encDef, kind)
end

local function pickFromTable(t, rng)
  if not t then return nil end
  local buckets = t.buckets or Config.ENCOUNTER_BUCKETS
  local pick = rng(0, 255)
  for i, threshold in ipairs(buckets) do
    if pick < threshold then
      local slot = t.slots[i] or t.slots[#t.slots]
      if slot and slot.species then
        return { species = slot.species, level = slot.level or 1, kind = t._kind }
      end
      return nil
    end
  end
  local last = t.slots[#t.slots]
  if last and last.species then
    return { species = last.species, level = last.level or 1, kind = t._kind }
  end
  return nil
end

-- Returns { species, level [, kind] } or nil.
-- kind defaults to "grass". Pass "water" for Surf tables. Never pass "fishing"
-- for free overworld spawns.
function EncounterPick.pick(encDef, rng, kind)
  rng = rng01(rng)
  kind = kind or "grass"
  if kind == "fishing" then
    return nil
  end
  local t = EncounterPick.kindTable(encDef, kind)
  if t then t._kind = kind end
  return pickFromTable(t, rng)
end

-- Convenience: grass-only (legacy callers).
function EncounterPick.pickGrass(encDef, rng)
  return EncounterPick.pick(encDef, rng, "grass")
end

function EncounterPick.pickWater(encDef, rng)
  return EncounterPick.pick(encDef, rng, "water")
end

function EncounterPick.hasGrassTable(encDef)
  return EncounterPick.grassTable(encDef) ~= nil
end

function EncounterPick.hasAnyTable(encDef)
  for _, kind in ipairs(EncounterPick.KINDS) do
    if tableOf(encDef, kind) then return true end
  end
  return false
end

function EncounterPick.slotCount(encDef, kind)
  kind = kind or "grass"
  local t = tableOf(encDef, kind)
  return t and #t.slots or 0
end

function EncounterPick.totalSlotCount(encDef)
  local n = 0
  for _, kind in ipairs(EncounterPick.KINDS) do
    n = n + EncounterPick.slotCount(encDef, kind)
  end
  return n
end

-- Unique species across one kind (default grass). Duplicates in multiple
-- slots count once.
function EncounterPick.uniqueSpecies(encDef, kind)
  kind = kind or "grass"
  local t = tableOf(encDef, kind)
  local set = {}
  local names = {}
  if not t then return names, set end
  for _, slot in ipairs(t.slots) do
    if slot.species and not set[slot.species] then
      set[slot.species] = true
      names[#names + 1] = slot.species
    end
  end
  table.sort(names)
  return names, set
end

function EncounterPick.uniqueSpeciesCount(encDef, kind)
  local names = EncounterPick.uniqueSpecies(encDef, kind)
  return #names
end

function EncounterPick.summarize(encDef, kind)
  kind = kind or "grass"
  local t = tableOf(encDef, kind)
  if not t then return nil end
  local names, _ = EncounterPick.uniqueSpecies(encDef, kind)
  local lo, hi = math.huge, 0
  for _, slot in ipairs(t.slots) do
    local lv = slot.level or 1
    if lv < lo then lo = lv end
    if lv > hi then hi = lv end
  end
  return {
    kind = kind,
    rate = t.rate,
    slots = #t.slots,
    species = names,
    uniqueSpecies = #names,
    levelMin = lo,
    levelMax = hi,
  }
end

function EncounterPick.summarizeAll(encDef)
  local out = {}
  for _, kind in ipairs(EncounterPick.KINDS) do
    local s = EncounterPick.summarize(encDef, kind)
    if s then out[#out + 1] = s end
  end
  return out
end

-- True when species/level could come from this map's grass table.
function EncounterPick.inTable(encDef, species, level, kind)
  kind = kind or "grass"
  local t = tableOf(encDef, kind)
  if not t then return false end
  for _, slot in ipairs(t.slots) do
    if slot.species == species and (level == nil or slot.level == level) then
      return true
    end
  end
  return false
end

function EncounterPick.levelRange(encDef, kind)
  local summary = EncounterPick.summarize(encDef, kind)
  if not summary then return nil end
  return summary.levelMin, summary.levelMax
end

-- Slot weight approximation for diagnostics (bucket widths when present).
function EncounterPick.slotWeights(encDef, kind)
  kind = kind or "grass"
  local t = tableOf(encDef, kind)
  if not t then return {} end
  local buckets = t.buckets or Config.ENCOUNTER_BUCKETS
  local weights = {}
  local prev = 0
  for i, slot in ipairs(t.slots) do
    local thr = buckets[i] or 256
    local w = thr - prev
    if w < 0 then w = 0 end
    weights[#weights + 1] = {
      species = slot.species,
      level = slot.level or 1,
      weight = w,
      index = i,
    }
    prev = thr
  end
  return weights
end

return EncounterPick
