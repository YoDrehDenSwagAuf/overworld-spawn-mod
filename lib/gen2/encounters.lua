-- Gen 2 / Pokémon Gold wild encounter provider.
--
-- Reads Gold's actual encounter tables (data.gen2Encounters), keyed
-- kind-first: grass[mapId], water[mapId]. Does NOT use Pokédex habitat data
-- and does NOT share tables with Gen1 (game.data.encounters[mapId]).
--
-- Normalized output matches the shared Wilds encDef shape:
--   { grass = { rate, slots = { {species, level}, ... }, buckets },
--     water = { rate, slots = { ... }, buckets } }
-- so Surface / EncounterPick / WaterSpawn can consume it without Gen1 tables.
--
-- Time of day: grass has MORN / DAY / NITE (DARK → NITE), matching
-- src/battle/gen2/Encounter.lua. Slot chances match the engine:
--   grass 30/30/20/10/5/4/1, water 60/30/10.
--
-- Fishing, headbutt, and rock smash are not visible Wilds spawns (same as
-- Gen1: EncounterPick.pick("fishing") is nil; rods stay engine-side).
local V = ...

local Enc = {}

-- data/wild/probabilities.asm, cumulative out of 100.
Enc.GRASS_SLOT_CHANCES = { 30, 60, 80, 90, 95, 99, 100 }
Enc.WATER_SLOT_CHANCES = { 60, 90, 100 }

-- EncounterPick diagnostics use 0..255 buckets. Scale the percent table.
local function chancesToBuckets(chances)
  local buckets = {}
  for i, pct in ipairs(chances) do
    buckets[i] = math.floor((pct * 256) / 100 + 0.5)
  end
  if #buckets > 0 then buckets[#buckets] = 256 end
  return buckets
end

Enc.GRASS_BUCKETS = chancesToBuckets(Enc.GRASS_SLOT_CHANCES)
Enc.WATER_BUCKETS = chancesToBuckets(Enc.WATER_SLOT_CHANCES)

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

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

-- Gold tables are kind-first: grass[mapId], water[mapId].
-- A Gen1 map-first encDef ({ grass = { rate, slots } }) must never qualify.
local function isKindFirst(tables)
  if type(tables) ~= "table" then return false end
  for _, kind in ipairs({ "grass", "water" }) do
    local block = tables[kind]
    if type(block) == "table" then
      if type(block.slots) == "table" and block.slots[1] and block.rate ~= nil then
        return false
      end
      for _, row in pairs(block) do
        if type(row) == "table" and (row.slots or row.rates or row.rate ~= nil) then
          return true
        end
      end
    end
  end
  return false
end

function Enc.rawTables(game, ctx)
  ctx = ctx or {}
  local world = ctx.world or (game and game.world)
  if world then
    if type(world.encounterTables) == "function" then
      local ok, tables = pcall(world.encounterTables, world)
      if ok and isKindFirst(tables) then return tables end
    end
    if isKindFirst(world.encounters) then return world.encounters end
  end
  if game and game.data then
    if isKindFirst(game.data.gen2Encounters) then return game.data.gen2Encounters end
    -- Gen2Compat may expose the same table as data.encounters.
    if isKindFirst(game.data.encounters) then return game.data.encounters end
  end
  return nil
end

-- Engine daytime: MORN / DAY / NITE / DARK. DARK reuses NITE lists.
function Enc.timeOfDay(game, ctx)
  ctx = ctx or {}
  if type(ctx.timeOfDay) == "string" and ctx.timeOfDay ~= "" then
    return string.upper(ctx.timeOfDay)
  end
  local world = ctx.world or (game and game.world)
  if world then
    if type(world.daytime) == "string" and world.daytime ~= "" then
      return string.upper(world.daytime)
    end
    if type(world.timeOfDay) == "function" then
      local ok, tod = pcall(world.timeOfDay, world)
      if ok and type(tod) == "string" and tod ~= "" then
        return string.upper(tod)
      end
    end
    if type(world.getTimeOfDay) == "function" then
      local ok, tod = pcall(world.getTimeOfDay, world)
      if ok and type(tod) == "string" and tod ~= "" then
        return string.upper(tod)
      end
    end
    if type(world.timeOfDayId) == "function" then
      local ok, id = pcall(world.timeOfDayId, world)
      if ok then
        local names = { [0] = "MORN", [1] = "DAY", [2] = "NITE", [3] = "DARK" }
        if names[id] then return names[id] end
      end
    end
  end
  return "DAY"
end

function Enc.grassKey(daytime)
  local key = daytime and string.upper(tostring(daytime)) or "DAY"
  if key == "DARK" then return "NITE" end
  if key == "MORN" or key == "DAY" or key == "NITE" then return key end
  return "DAY"
end

local function copySlots(slots)
  if type(slots) ~= "table" then return nil end
  local out = {}
  for i, slot in ipairs(slots) do
    if type(slot) == "table" and slot.species then
      out[#out + 1] = {
        species = slot.species,
        level = tonumber(slot.level) or 1,
        slot = i,
      }
    end
  end
  if #out == 0 then return nil end
  return out
end

local function normalizeGrass(entry, daytime)
  if type(entry) ~= "table" then return nil end
  local key = Enc.grassKey(daytime)
  local slots = entry.slots
  local chosen
  if type(slots) == "table" then
    chosen = slots[key] or slots.DAY or slots.MORN or slots.NITE
    -- Some fixtures flatten to a single array (no TOD keys).
    if not chosen and slots[1] then chosen = slots end
  end
  chosen = copySlots(chosen)
  if not chosen then return nil end
  local rates = entry.rates
  local rate = 0
  if type(rates) == "table" then
    rate = tonumber(rates[key] or rates.DAY or rates.MORN or rates.NITE) or 0
  else
    rate = tonumber(entry.rate) or 0
  end
  return {
    rate = rate,
    slots = chosen,
    buckets = Enc.GRASS_BUCKETS,
    timeOfDay = key,
  }
end

local function normalizeWater(entry)
  if type(entry) ~= "table" then return nil end
  local slots = entry.slots
  -- Water has no TOD split. Ignore accidental MORN/DAY maps.
  if type(slots) == "table" and (slots.DAY or slots.MORN or slots.NITE) then
    slots = slots.DAY or slots.MORN or slots.NITE
  end
  slots = copySlots(slots)
  if not slots then return nil end
  return {
    rate = tonumber(entry.rate) or 0,
    slots = slots,
    buckets = Enc.WATER_BUCKETS,
  }
end

--- Normalized Wilds encDef for one Gold map, or nil when the map has none.
function Enc.forMap(game, mapId, ctx)
  if mapId == nil then return nil end
  ctx = ctx or {}
  local tables = Enc.rawTables(game, ctx)
  if not tables then return nil end
  local tod = Enc.timeOfDay(game, ctx)
  local def = {}
  local grass = tables.grass and tables.grass[mapId]
  local water = tables.water and tables.water[mapId]
  def.grass = normalizeGrass(grass, tod)
  def.water = normalizeWater(water)
  if not def.grass and not def.water then return nil end
  def._source = "gen2Encounters"
  def._mapId = mapId
  def._timeOfDay = Enc.grassKey(tod)
  return def
end

local function slotFor(chances, value)
  for index, cumulative in ipairs(chances) do
    if value < cumulative then return index end
  end
  return #chances
end

local function pickFromSlots(slots, chances, rng)
  if type(slots) ~= "table" or #slots == 0 then return nil end
  rng = rng01(rng)
  local value = rng(0, 99)
  local index = slotFor(chances, value)
  local slot = slots[index] or slots[#slots]
  if not slot or not slot.species then return nil end
  return {
    species = slot.species,
    level = tonumber(slot.level) or 1,
    slot = index,
  }
end

--- Weighted pick from Gold tables. Prefers engine Encounter.grassSlot / waterSlot.
--- Weighted pick from Gold tables. Prefers engine Encounter.grassSlot / waterSlot.
function Enc.pick(game, mapId, kind, ctx)
  ctx = ctx or {}
  kind = kind or ctx.kind or ctx.surface or "grass"
  if kind == "land" then kind = "grass" end
  if kind == "fishing" then return nil end
  local tables = Enc.rawTables(game, ctx)
  local tod = Enc.grassKey(Enc.timeOfDay(game, ctx))
  local Engine = tryRequire("src.battle.gen2.Encounter")
  if Engine and tables then
    if kind == "grass" and type(Engine.grassSlot) == "function" then
      local rng = ctx.random
      local ok, hit = pcall(Engine.grassSlot, tables, mapId, tod, rng)
      if ok and hit and hit.species then
        hit.kind = "grass"
        return hit
      end
      if ok and hit == nil then return nil end
    elseif kind == "water" and type(Engine.waterSlot) == "function" then
      local rng = ctx.random
      local ok, hit = pcall(Engine.waterSlot, tables, mapId, rng)
      if ok and hit and hit.species then
        hit.kind = "water"
        return hit
      end
      if ok and hit == nil then return nil end
    end
  end

  local def = ctx.encDef or Enc.forMap(game, mapId, ctx)
  if not def then return nil end
  if kind == "water" then
    local t = def.water
    if not t then return nil end
    local hit = pickFromSlots(t.slots, Enc.WATER_SLOT_CHANCES, ctx.random)
    if hit then hit.kind = "water" end
    return hit
  end
  local t = def.grass
  if not t then return nil end
  local hit = pickFromSlots(t.slots, Enc.GRASS_SLOT_CHANCES, ctx.random)
  if hit then hit.kind = "grass" end
  return hit
end

function Enc.candidates(game, mapId, kind, ctx)
  local def = Enc.forMap(game, mapId, ctx)
  if not def then return {} end
  kind = kind or "grass"
  local t = def[kind]
  if not t or type(t.slots) ~= "table" then return {} end
  local names, seen = {}, {}
  for _, slot in ipairs(t.slots) do
    if slot.species and not seen[slot.species] then
      seen[slot.species] = true
      names[#names + 1] = slot.species
    end
  end
  table.sort(names)
  return names, def
end

return Enc
