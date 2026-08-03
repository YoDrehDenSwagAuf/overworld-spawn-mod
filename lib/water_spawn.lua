-- Visible water spawn pools, shore-distance zones, and zone-aware picks.
-- Data sources (Gen1Recomp):
--   Surf:        game.data.encounters[mapId].water
--   Old Rod:     game.data.field.fishing.OLD_ROD
--   Good Rod:    game.data.field.fishing.GOOD_ROD
--   Super Rod:   game.data.field.superRod[mapId] (via fishing.SUPER_ROD.perMap)
-- Never invents species from types or a global water list.
local V = ...
local Config = V.require("config")
local EncounterPick = V.require("encounter_pick")

local WaterSpawn = {}

WaterSpawn.ROD_TIER = {
  SURF = 0,
  OLD = 1,
  GOOD = 2,
  SUPER = 3,
}

WaterSpawn.SOURCE = {
  SURF = "surf",
  OLD_ROD = "old_rod",
  GOOD_ROD = "good_rod",
  SUPER_ROD = "super_rod",
}

WaterSpawn.ZONE = {
  NEAR = "NEAR",
  MID = "MID",
  DEEP = "DEEP",
}

-- Shore-distance thresholds (tiles from walkable land).
WaterSpawn.NEAR_SHORE_MAX = 2
WaterSpawn.MID_WATER_MAX = 5
WaterSpawn.DEEP_WATER_MIN = 6

-- Zone target mix when all three zones exist.
WaterSpawn.ZONE_SHARE = {
  NEAR = 0.35,
  MID = 0.40,
  DEEP = 0.25,
}

WaterSpawn.MAX_SAME_SPECIES_DEFAULT = 2
WaterSpawn.MAX_SAME_SPECIES_SPARSE = 1
WaterSpawn.ANTI_STREAK_LEN = 3
WaterSpawn.ANTI_STREAK_MUL = 0.35

local DIRS = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }

local function cellKey(x, y)
  return x .. ":" .. y
end

local function rngOf(rng)
  if type(rng) == "function" then return rng end
  if love and love.math and love.math.random then return love.math.random end
  return math.random
end

local function sourceForTier(tier)
  if tier == WaterSpawn.ROD_TIER.SURF then return WaterSpawn.SOURCE.SURF end
  if tier == WaterSpawn.ROD_TIER.OLD then return WaterSpawn.SOURCE.OLD_ROD end
  if tier == WaterSpawn.ROD_TIER.GOOD then return WaterSpawn.SOURCE.GOOD_ROD end
  if tier == WaterSpawn.ROD_TIER.SUPER then return WaterSpawn.SOURCE.SUPER_ROD end
  return WaterSpawn.SOURCE.SURF
end

local function tierLabel(tier)
  if tier == WaterSpawn.ROD_TIER.SURF then return "SURF" end
  if tier == WaterSpawn.ROD_TIER.OLD then return "OLD_ROD" end
  if tier == WaterSpawn.ROD_TIER.GOOD then return "GOOD_ROD" end
  if tier == WaterSpawn.ROD_TIER.SUPER then return "SUPER_ROD" end
  return "?"
end

function WaterSpawn.zoneForDistance(dist)
  dist = tonumber(dist)
  if dist == nil then return nil end
  if dist <= WaterSpawn.NEAR_SHORE_MAX then return WaterSpawn.ZONE.NEAR end
  if dist <= WaterSpawn.MID_WATER_MAX then return WaterSpawn.ZONE.MID end
  return WaterSpawn.ZONE.DEEP
end

function WaterSpawn.spawnRuleForTier(tier)
  if tier == WaterSpawn.ROD_TIER.SUPER then return "DEEP_ONLY" end
  if tier == WaterSpawn.ROD_TIER.GOOD then return "MID_OR_DEEP" end
  if tier == WaterSpawn.ROD_TIER.OLD then return "NEAR_OR_MID" end
  return "ANY_WEIGHTED"
end

-- Zones a rod tier may appear in.
-- Super-Rod-only (tier SUPER after dedupe) → Deep only.
-- Good Rod → Near/Mid/Deep. Old Rod → Near/Mid. Surf → all.
function WaterSpawn.zonesForTier(tier)
  if tier == WaterSpawn.ROD_TIER.SUPER then
    return { [WaterSpawn.ZONE.DEEP] = true }
  end
  if tier == WaterSpawn.ROD_TIER.GOOD then
    return {
      [WaterSpawn.ZONE.NEAR] = true,
      [WaterSpawn.ZONE.MID] = true,
      [WaterSpawn.ZONE.DEEP] = true,
    }
  end
  if tier == WaterSpawn.ROD_TIER.OLD then
    return {
      [WaterSpawn.ZONE.NEAR] = true,
      [WaterSpawn.ZONE.MID] = true,
    }
  end
  -- Surf: all zones (weights applied at pick).
  return {
    [WaterSpawn.ZONE.NEAR] = true,
    [WaterSpawn.ZONE.MID] = true,
    [WaterSpawn.ZONE.DEEP] = true,
  }
end

-- True when merged entry came only from Super Rod (lowest tier stayed SUPER).
function WaterSpawn.isSuperRodOnly(entry)
  return entry and entry.rodTier == WaterSpawn.ROD_TIER.SUPER
end

-- Species water capability from real Gen1Recomp / Wilds data only.
-- Priority: types WATER → swimming/levitates mapping → local encounter → false.
function WaterSpawn.isWaterCapable(species, game, opts)
  opts = opts or {}
  if species == nil then return false, "nil species" end
  local name = species
  if type(species) == "number" then
    -- Dex id → name via game.data.pokemon when available.
    local poke = game and game.data and game.data.pokemon and game.data.pokemon[species]
    name = (poke and (poke.name or poke.id or poke.species)) or tostring(species)
  end
  name = tostring(name):upper()

  -- 1) Explicit type table on species (Gen1Recomp: pokemon[N].types = {"WATER", ...}).
  local pokeTable = game and game.data and game.data.pokemon
  if type(pokeTable) == "table" then
    local entry = pokeTable[name] or pokeTable[species]
    if not entry then
      for _, p in pairs(pokeTable) do
        if type(p) == "table" then
          local id = p.id or p.name or p.species
          if id and tostring(id):upper() == name then
            entry = p
            break
          end
          if tonumber(species) and tonumber(p.dex or p.number or p.id) == tonumber(species) then
            entry = p
            break
          end
        end
      end
    end
    if entry and type(entry.types) == "table" then
      for _, t in ipairs(entry.types) do
        if tostring(t):upper() == "WATER" then
          return true, "type:WATER"
        end
      end
    end
  end

  -- 2–3) Swimming / Levitates sprite mappings (technical water/float fitness).
  local registry = opts.waterRegistry
  if registry and registry.ready then
    local sid = tonumber(opts.speciesId or species)
    if not sid and type(name) == "string" and opts.resolveDex then
      sid = opts.resolveDex(name)
    end
    if sid then
      if registry:hasKind(sid, "swimming") then
        return true, "swimming_sprite"
      end
      if registry:hasKind(sid, "levitates") then
        return true, "levitates_sprite"
      end
    end
  end

  -- 4) Present in local Surf/rod encounter pool.
  if opts.localPoolSpecies and opts.localPoolSpecies[name] then
    return true, "local_encounter"
  end

  return false, "not_water_capable"
end

-- Relative weight multiplier by zone for Surf entries.
function WaterSpawn.surfZoneWeight(zone)
  if zone == WaterSpawn.ZONE.NEAR then return 0.55 end
  if zone == WaterSpawn.ZONE.MID then return 1.0 end
  if zone == WaterSpawn.ZONE.DEEP then return 1.15 end
  return 1.0
end

local function appendSlots(out, slots, tier, source, defaultWeight)
  if type(slots) ~= "table" then return end
  for _, slot in ipairs(slots) do
    if type(slot) == "table" and slot.species then
      local level = tonumber(slot.level) or 1
      out[#out + 1] = {
        species = slot.species,
        speciesId = slot.species,
        level = level,
        levelMin = level,
        levelMax = level,
        source = source,
        rodTier = tier,
        weight = tonumber(slot.weight) or defaultWeight or 1,
      }
    end
  end
end

local function fishingDef(game, rod)
  local field = game and game.data and game.data.field
  local fishing = field and field.fishing
  if type(fishing) ~= "table" then return nil end
  return fishing[rod]
end

-- Collect raw Old/Good/Super Rod slots for a map from Gen1Recomp field data.
function WaterSpawn.rodSlotsForMap(game, mapId)
  local out = {
    old = {},
    good = {},
    super = {},
  }
  local oldDef = fishingDef(game, "OLD_ROD")
  if oldDef then
    if oldDef.always and oldDef.always.species then
      out.old[#out.old + 1] = {
        species = oldDef.always.species,
        level = oldDef.always.level or 5,
        weight = 1,
      }
    elseif type(oldDef.pool) == "table" then
      for _, slot in ipairs(oldDef.pool) do
        out.old[#out.old + 1] = {
          species = slot.species,
          level = slot.level or 5,
          weight = 1,
        }
      end
    end
  end

  local goodDef = fishingDef(game, "GOOD_ROD")
  if goodDef and type(goodDef.pool) == "table" then
    for _, slot in ipairs(goodDef.pool) do
      out.good[#out.good + 1] = {
        species = slot.species,
        level = slot.level or 10,
        weight = 1,
      }
    end
  end

  local superDef = fishingDef(game, "SUPER_ROD")
  local field = game and game.data and game.data.field
  if superDef and superDef.perMap and field then
    local groups = field[superDef.perMap]
    local group = groups and mapId and groups[mapId]
    if type(group) == "table" then
      for _, slot in ipairs(group) do
        out.super[#out.super + 1] = {
          species = slot.species,
          level = slot.level or 1,
          weight = 1,
        }
      end
    end
  elseif type(field) == "table" and type(field.superRod) == "table" and mapId then
    local group = field.superRod[mapId]
    if type(group) == "table" then
      for _, slot in ipairs(group) do
        out.super[#out.super + 1] = {
          species = slot.species,
          level = slot.level or 1,
          weight = 1,
        }
      end
    end
  end

  local function pushRodTable(bucket, t)
    if type(t) ~= "table" then return end
    local slots = t
    if type(t.slots) == "table" then slots = t.slots end
    if type(slots) ~= "table" then return end
    -- Array of slots vs single always-entry.
    if slots.species and not slots[1] then
      bucket[#bucket + 1] = {
        species = slots.species,
        level = slots.level or 1,
        weight = slots.weight or 1,
      }
      return
    end
    for _, slot in ipairs(slots) do
      if type(slot) == "table" and slot.species then
        bucket[#bucket + 1] = {
          species = slot.species,
          level = slot.level or 1,
          weight = slot.weight or 1,
        }
      end
    end
  end

  -- Legacy / fixture shapes: encDef.fishing with nested rods, or flat slots.
  local encDef = game and game.data and game.data.encounters
                  and mapId and game.data.encounters[mapId]
  local fishing = encDef and encDef.fishing
  if type(fishing) == "table" then
    pushRodTable(out.old, fishing.old_rod or fishing.OLD_ROD)
    pushRodTable(out.good, fishing.good_rod or fishing.GOOD_ROD)
    pushRodTable(out.super, fishing.super_rod or fishing.SUPER_ROD)
    -- Flat fishing.slots with optional rod/tier tags.
    if type(fishing.slots) == "table" then
      for _, slot in ipairs(fishing.slots) do
        if slot and slot.species then
          local tag = tostring(slot.rod or slot.source or slot.tier or ""):lower()
          local bucket = out.old
          if tag:find("super", 1, true) then
            bucket = out.super
          elseif tag:find("good", 1, true) then
            bucket = out.good
          elseif tag:find("old", 1, true) or tag == "" then
            bucket = out.old
          end
          bucket[#bucket + 1] = {
            species = slot.species,
            level = slot.level or 1,
            weight = slot.weight or 1,
          }
        end
      end
    end
  end

  -- Direct encDef.old_rod / good_rod / super_rod tables (tests / patches).
  if encDef then
    pushRodTable(out.old, encDef.old_rod)
    pushRodTable(out.good, encDef.good_rod)
    pushRodTable(out.super, encDef.super_rod)
  end

  return out
end

local function mergeEntry(bySpecies, entry)
  local sp = entry.species
  local cur = bySpecies[sp]
  if not cur then
    bySpecies[sp] = {
      species = sp,
      speciesId = sp,
      levelMin = entry.levelMin or entry.level or 1,
      levelMax = entry.levelMax or entry.level or 1,
      source = entry.source,
      rodTier = entry.rodTier,
      weight = entry.weight or 1,
      sources = { entry.source },
    }
    return
  end
  local lv = entry.level or entry.levelMin or 1
  local lvMax = entry.levelMax or entry.level or lv
  if lv < cur.levelMin then cur.levelMin = lv end
  if lvMax > cur.levelMax then cur.levelMax = lvMax end
  cur.weight = (cur.weight or 0) + (entry.weight or 1)
  -- Keep the lowest (most accessible) rod tier; update primary source to match.
  if entry.rodTier < cur.rodTier then
    cur.rodTier = entry.rodTier
    cur.source = entry.source
  end
  local seen = false
  for _, s in ipairs(cur.sources) do
    if s == entry.source then seen = true break end
  end
  if not seen then cur.sources[#cur.sources + 1] = entry.source end
end

-- Build deduplicated visible water pool for a map.
-- Returns { entries = {...}, bySource = {...}, diagnostics = {...} }
function WaterSpawn.buildPool(game, mapId, encDef)
  encDef = encDef or (game and game.data and game.data.encounters
                      and mapId and game.data.encounters[mapId])
  local raw = {}

  -- 1) Surf / water table (preserve bucket weights).
  local waterWeights = EncounterPick.slotWeights(encDef, "water")
  if #waterWeights > 0 then
    for _, w in ipairs(waterWeights) do
      if w.species then
        raw[#raw + 1] = {
          species = w.species,
          speciesId = w.species,
          level = w.level or 1,
          levelMin = w.level or 1,
          levelMax = w.level or 1,
          source = WaterSpawn.SOURCE.SURF,
          rodTier = WaterSpawn.ROD_TIER.SURF,
          weight = w.weight or 1,
        }
      end
    end
  else
    local t = EncounterPick.kindTable(encDef, "water")
    if t then
      for _, slot in ipairs(t.slots or {}) do
        if slot.species then
          raw[#raw + 1] = {
            species = slot.species,
            speciesId = slot.species,
            level = slot.level or 1,
            levelMin = slot.level or 1,
            levelMax = slot.level or 1,
            source = WaterSpawn.SOURCE.SURF,
            rodTier = WaterSpawn.ROD_TIER.SURF,
            weight = 1,
          }
        end
      end
    end
  end

  -- 2–4) Rod tables (map-aware Super Rod; global Old/Good when defined).
  local rods = WaterSpawn.rodSlotsForMap(game, mapId)
  appendSlots(raw, rods.old, WaterSpawn.ROD_TIER.OLD, WaterSpawn.SOURCE.OLD_ROD, 1)
  appendSlots(raw, rods.good, WaterSpawn.ROD_TIER.GOOD, WaterSpawn.SOURCE.GOOD_ROD, 1)
  appendSlots(raw, rods.super, WaterSpawn.ROD_TIER.SUPER, WaterSpawn.SOURCE.SUPER_ROD, 1)

  local bySpecies = {}
  for _, entry in ipairs(raw) do
    mergeEntry(bySpecies, entry)
  end

  local entries = {}
  for _, e in pairs(bySpecies) do
    entries[#entries + 1] = e
  end
  table.sort(entries, function(a, b)
    if a.rodTier ~= b.rodTier then return a.rodTier < b.rodTier end
    return tostring(a.species) < tostring(b.species)
  end)

  local bySource = {
    surf = 0, old_rod = 0, good_rod = 0, super_rod = 0,
  }
  local speciesBySource = {
    surf = {}, old_rod = {}, good_rod = {}, super_rod = {},
  }
  for _, e in ipairs(entries) do
    local src = e.source
    if bySource[src] ~= nil then
      bySource[src] = bySource[src] + 1
      speciesBySource[src][#speciesBySource[src] + 1] = e.species
    end
  end

  return {
    entries = entries,
    bySource = bySource,
    speciesBySource = speciesBySource,
    diagnostics = {
      surfSpecies = bySource.surf,
      oldRodSpecies = bySource.old_rod,
      goodRodSpecies = bySource.good_rod,
      superRodSpecies = bySource.super_rod,
      totalSpecies = #entries,
    },
  }
end

function WaterSpawn.hasPool(pool)
  return pool and type(pool.entries) == "table" and #pool.entries > 0
end

-- True when a cell is valid walkable land (shore source for BFS).
function WaterSpawn.isShoreLandCell(map, x, y)
  if not map then return false end
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  if x < 0 or y < 0 or x >= w or y >= h then return false end
  if map.inBounds and not map:inBounds(x, y) then return false end
  if map.isWaterCell and map:isWaterCell(x, y) then return false end
  if map.warpAtCell and map:warpAtCell(x, y) then return false end
  if map.isWalkableCell then
    return map:isWalkableCell(x, y) == true
  end
  -- Without walkability API, treat non-water in-bounds as land.
  return true
end

-- Multi-source BFS: distance from nearest walkable land, traversing water only.
-- Returns map keyed "x:y" -> tile distance, plus zone cell lists.
function WaterSpawn.buildShoreDistance(map, waterCells)
  local dist = {}
  local near, mid, deep = {}, {}, {}
  if not map then
    return {
      distance = dist,
      near = near, mid = mid, deep = deep,
      hasDeep = false,
      counts = { water = 0, near = 0, mid = 0, deep = 0 },
    }
  end

  local waterSet = {}
  local cells = waterCells
  if type(cells) ~= "table" or #cells == 0 then
    -- Fall back to scanning the map.
    cells = {}
    local w = map.widthCells or 0
    local h = map.heightCells or 0
    for cy = 0, h - 1 do
      for cx = 0, w - 1 do
        if map.isWaterCell and map:isWaterCell(cx, cy) then
          cells[#cells + 1] = { x = cx, y = cy }
        end
      end
    end
  end
  for _, c in ipairs(cells) do
    waterSet[cellKey(c.x, c.y)] = c
  end

  -- Seeds: water cells adjacent to walkable land.
  local queue = {}
  local qi = 1
  for _, c in ipairs(cells) do
    local shore = false
    for _, d in ipairs(DIRS) do
      local lx, ly = c.x + d[1], c.y + d[2]
      if WaterSpawn.isShoreLandCell(map, lx, ly) then
        shore = true
        break
      end
    end
    if shore then
      local k = cellKey(c.x, c.y)
      dist[k] = 0
      queue[#queue + 1] = { x = c.x, y = c.y, d = 0 }
    end
  end

  while qi <= #queue do
    local cur = queue[qi]
    qi = qi + 1
    for _, d in ipairs(DIRS) do
      local nx, ny = cur.x + d[1], cur.y + d[2]
      local nk = cellKey(nx, ny)
      if waterSet[nk] and dist[nk] == nil then
        local nd = cur.d + 1
        dist[nk] = nd
        queue[#queue + 1] = { x = nx, y = ny, d = nd }
      end
    end
  end

  -- Unreachable water (no land adjacency anywhere) stays nil → treat as deep
  -- only when some deep zone exists elsewhere; otherwise leave unset.
  local hasDeep = false
  for _, c in ipairs(cells) do
    local k = cellKey(c.x, c.y)
    local d = dist[k]
    if d == nil then
      -- Isolated / landlocked-from-shore water: classify as mid when no deep
      -- exists yet so Super-Rod-only still cannot appear on tiny ponds.
      d = WaterSpawn.MID_WATER_MAX
      dist[k] = d
    end
    local zone = WaterSpawn.zoneForDistance(d)
    local entry = { x = c.x, y = c.y, distance = d, zone = zone }
    if zone == WaterSpawn.ZONE.NEAR then
      near[#near + 1] = entry
    elseif zone == WaterSpawn.ZONE.MID then
      mid[#mid + 1] = entry
    else
      deep[#deep + 1] = entry
      hasDeep = true
    end
  end

  return {
    distance = dist,
    near = near,
    mid = mid,
    deep = deep,
    hasDeep = hasDeep,
    counts = {
      water = #cells,
      near = #near,
      mid = #mid,
      deep = #deep,
    },
  }
end

function WaterSpawn.distanceAt(shoreMap, x, y)
  if not shoreMap or not shoreMap.distance then return nil end
  return shoreMap.distance[cellKey(x, y)]
end

-- Split pool entries into near/mid/deep lists (species may appear in multiple).
function WaterSpawn.buildZonePools(pool, hasDeep)
  local near, mid, deep = {}, {}, {}
  if not pool or not pool.entries then
    return { near = near, mid = mid, deep = deep }
  end
  for _, e in ipairs(pool.entries) do
    local zones = WaterSpawn.zonesForTier(e.rodTier)
    -- Super-Rod-only never appears without a real deep zone.
    if WaterSpawn.isSuperRodOnly(e) and not hasDeep then
      -- skip deep-only species on maps without deep water
    else
      if zones[WaterSpawn.ZONE.NEAR] then near[#near + 1] = e end
      if zones[WaterSpawn.ZONE.MID] then mid[#mid + 1] = e end
      if zones[WaterSpawn.ZONE.DEEP] and hasDeep then deep[#deep + 1] = e end
    end
  end

  -- Zone empty → fall back to Surf-tier entries, then whole local pool.
  local function surfOnly(list)
    local out = {}
    for _, e in ipairs(pool.entries) do
      if e.rodTier == WaterSpawn.ROD_TIER.SURF then out[#out + 1] = e end
    end
    return out
  end
  if #near == 0 then
    near = surfOnly()
    if #near == 0 then near = pool.entries end
  end
  if #mid == 0 then
    mid = surfOnly()
    if #mid == 0 then mid = pool.entries end
  end
  if hasDeep and #deep == 0 then
    deep = surfOnly()
    if #deep == 0 then deep = pool.entries end
  end

  return { near = near, mid = mid, deep = deep }
end

function WaterSpawn.zoneTargets(total, shoreMap, zonePools)
  total = math.max(0, math.floor(tonumber(total) or 0))
  local counts = shoreMap and shoreMap.counts or { near = 0, mid = 0, deep = 0 }
  local hasDeep = shoreMap and shoreMap.hasDeep == true
  local nearPool = zonePools and zonePools.near or {}
  local midPool = zonePools and zonePools.mid or {}
  local deepPool = zonePools and zonePools.deep or {}

  local shareNear = WaterSpawn.ZONE_SHARE.NEAR
  local shareMid = WaterSpawn.ZONE_SHARE.MID
  local shareDeep = hasDeep and WaterSpawn.ZONE_SHARE.DEEP or 0
  if not hasDeep or #deepPool == 0 or (counts.deep or 0) == 0 then
    shareDeep = 0
    local rem = 1 - 0
    shareNear = WaterSpawn.ZONE_SHARE.NEAR / (WaterSpawn.ZONE_SHARE.NEAR + WaterSpawn.ZONE_SHARE.MID)
    shareMid = 1 - shareNear
  end

  local function canUse(zone)
    if zone == "NEAR" then
      return (counts.near or 0) > 0 and #nearPool > 0
    elseif zone == "MID" then
      return (counts.mid or 0) > 0 and #midPool > 0
    else
      return hasDeep and (counts.deep or 0) > 0 and #deepPool > 0
    end
  end

  if not canUse("NEAR") then shareNear = 0 end
  if not canUse("MID") then shareMid = 0 end
  if not canUse("DEEP") then shareDeep = 0 end
  local sum = shareNear + shareMid + shareDeep
  if sum <= 0 then
    return { near = 0, mid = 0, deep = 0, total = 0 }
  end
  shareNear, shareMid, shareDeep = shareNear / sum, shareMid / sum, shareDeep / sum

  local tNear = math.floor(total * shareNear + 0.5)
  local tMid = math.floor(total * shareMid + 0.5)
  local tDeep = math.floor(total * shareDeep + 0.5)
  local assigned = tNear + tMid + tDeep
  while assigned < total do
    if canUse("MID") then tMid = tMid + 1
    elseif canUse("NEAR") then tNear = tNear + 1
    elseif canUse("DEEP") then tDeep = tDeep + 1
    else break end
    assigned = assigned + 1
  end
  while assigned > total do
    if tDeep > 0 then tDeep = tDeep - 1
    elseif tNear > 0 then tNear = tNear - 1
    elseif tMid > 0 then tMid = tMid - 1
    else break end
    assigned = assigned - 1
  end

  -- Cap by available cells roughly.
  if tNear > (counts.near or 0) then tNear = counts.near or 0 end
  if tMid > (counts.mid or 0) then tMid = counts.mid or 0 end
  if tDeep > (counts.deep or 0) then tDeep = counts.deep or 0 end

  return {
    near = tNear,
    mid = tMid,
    deep = tDeep,
    total = tNear + tMid + tDeep,
  }
end

local function weightedPick(entries, zone, recentSpecies, speciesCounts, maxSame, rng)
  rng = rngOf(rng)
  if not entries or #entries == 0 then return nil end
  local recent = {}
  for _, sp in ipairs(recentSpecies or {}) do
    recent[sp] = true
  end

  local function buildWeights(respectSame, respectStreak)
    local weights = {}
    local total = 0
    for i, e in ipairs(entries) do
      local w = e.weight or 1
      if e.rodTier == WaterSpawn.ROD_TIER.SURF then
        w = w * WaterSpawn.surfZoneWeight(zone)
      elseif WaterSpawn.isSuperRodOnly(e) and zone == WaterSpawn.ZONE.DEEP then
        w = w * 1.35
      end
      local count = speciesCounts and speciesCounts[e.species] or 0
      if respectSame and maxSame and count >= maxSame then
        w = 0
      elseif respectStreak and recent[e.species] then
        w = w * WaterSpawn.ANTI_STREAK_MUL
      end
      weights[i] = w
      total = total + w
    end
    return weights, total
  end

  -- Diversity soft-fail: same-species → anti-streak → any highest-weight.
  local weights, total = buildWeights(true, true)
  if total <= 0 then
    weights, total = buildWeights(true, false)
  end
  if total <= 0 then
    weights, total = buildWeights(false, false)
  end
  if total <= 0 then
    -- Last resort: highest base weight entry.
    local best, bestW = entries[1], -1
    for _, e in ipairs(entries) do
      local w = e.weight or 1
      if w > bestW then best, bestW = e, w end
    end
    if not best then return nil end
    return {
      species = best.species,
      speciesId = best.species,
      level = best.levelMin or 1,
      levelMin = best.levelMin,
      levelMax = best.levelMax,
      source = best.source,
      rodTier = best.rodTier,
      weight = best.weight,
      zone = zone,
      spawnRule = WaterSpawn.spawnRuleForTier(best.rodTier),
      encounterSource = tierLabel(best.rodTier),
    }
  end

  local roll = rng() * total
  if type(roll) ~= "number" then
    roll = ((rng(10000) - 1) / 10000) * total
  end
  local acc = 0
  for i, e in ipairs(entries) do
    acc = acc + (weights[i] or 0)
    if roll <= acc then
      local level = e.levelMin or 1
      if e.levelMax and e.levelMax > level then
        level = rng(level, e.levelMax)
      end
      return {
        species = e.species,
        speciesId = e.species,
        level = level,
        levelMin = e.levelMin,
        levelMax = e.levelMax,
        source = e.source,
        rodTier = e.rodTier,
        weight = e.weight,
        zone = zone,
        spawnRule = WaterSpawn.spawnRuleForTier(e.rodTier),
        encounterSource = tierLabel(e.rodTier),
      }
    end
  end
  local last = entries[#entries]
  return {
    species = last.species,
    speciesId = last.species,
    level = last.levelMin or 1,
    source = last.source,
    rodTier = last.rodTier,
    zone = zone,
    spawnRule = WaterSpawn.spawnRuleForTier(last.rodTier),
    encounterSource = tierLabel(last.rodTier),
  }
end

function WaterSpawn.maxSameSpecies(targetTotal)
  targetTotal = tonumber(targetTotal) or 0
  if targetTotal <= 3 then
    return WaterSpawn.MAX_SAME_SPECIES_SPARSE
  end
  return WaterSpawn.MAX_SAME_SPECIES_DEFAULT
end

-- Pick encounter for a specific zone (cell → zone → pool → species).
function WaterSpawn.pickForZone(zonePools, zone, opts)
  opts = opts or {}
  local list
  if zone == WaterSpawn.ZONE.NEAR then
    list = zonePools and zonePools.near
  elseif zone == WaterSpawn.ZONE.MID then
    list = zonePools and zonePools.mid
  else
    list = zonePools and zonePools.deep
  end
  local pick = weightedPick(
    list, zone,
    opts.recentSpecies, opts.speciesCounts, opts.maxSameSpecies, opts.rng)
  if pick then return pick end
  -- Fallback: full local pool (never leave a zone empty when candidates exist).
  if opts.fallbackEntries and #opts.fallbackEntries > 0 then
    return weightedPick(
      opts.fallbackEntries, zone,
      opts.recentSpecies, opts.speciesCounts, opts.maxSameSpecies, opts.rng)
  end
  return nil
end

-- Choose a zone that still needs spawns, preferring underfilled targets.
function WaterSpawn.pickSpawnZone(zoneCounts, zoneTargets, shoreMap, rng)
  rng = rngOf(rng)
  zoneCounts = zoneCounts or {}
  zoneTargets = zoneTargets or {}
  local candidates = {}
  local function consider(zone, cells)
    local target = zoneTargets[zone:lower()] or zoneTargets[zone] or 0
    local have = zoneCounts[zone:lower()] or zoneCounts[zone] or 0
    if target > 0 and have < target and cells and #cells > 0 then
      candidates[#candidates + 1] = {
        zone = zone,
        deficit = target - have,
        cells = cells,
      }
    end
  end
  consider(WaterSpawn.ZONE.NEAR, shoreMap and shoreMap.near)
  consider(WaterSpawn.ZONE.MID, shoreMap and shoreMap.mid)
  consider(WaterSpawn.ZONE.DEEP, shoreMap and shoreMap.deep)
  if #candidates == 0 then
    -- Soft fallback: any zone with cells + pool will be handled by caller.
    if shoreMap then
      if #(shoreMap.mid or {}) > 0 then
        return WaterSpawn.ZONE.MID, shoreMap.mid
      end
      if #(shoreMap.near or {}) > 0 then
        return WaterSpawn.ZONE.NEAR, shoreMap.near
      end
      if #(shoreMap.deep or {}) > 0 then
        return WaterSpawn.ZONE.DEEP, shoreMap.deep
      end
    end
    return nil, nil
  end
  -- Weight by deficit.
  local total = 0
  for _, c in ipairs(candidates) do total = total + c.deficit end
  local roll = rng() * total
  if type(roll) ~= "number" then
    roll = ((rng(10000) - 1) / 10000) * total
  end
  local acc = 0
  for _, c in ipairs(candidates) do
    acc = acc + c.deficit
    if roll <= acc then return c.zone, c.cells end
  end
  local last = candidates[#candidates]
  return last.zone, last.cells
end

function WaterSpawn.summarize(pool, shoreMap, zonePools, zoneTargets)
  local d = (pool and pool.diagnostics) or {}
  local counts = (shoreMap and shoreMap.counts) or {}
  return {
    waterCells = counts.water or 0,
    nearShore = counts.near or 0,
    midWater = counts.mid or 0,
    deepWater = counts.deep or 0,
    surfSpecies = d.surfSpecies or 0,
    oldRodSpecies = d.oldRodSpecies or 0,
    goodRodSpecies = d.goodRodSpecies or 0,
    superRodSpecies = d.superRodSpecies or 0,
    nearPool = zonePools and #(zonePools.near or {}) or 0,
    midPool = zonePools and #(zonePools.mid or {}) or 0,
    deepPool = zonePools and #(zonePools.deep or {}) or 0,
    nearTarget = zoneTargets and zoneTargets.near or 0,
    midTarget = zoneTargets and zoneTargets.mid or 0,
    deepTarget = zoneTargets and zoneTargets.deep or 0,
    hasDeep = shoreMap and shoreMap.hasDeep == true,
  }
end

WaterSpawn.tierLabel = tierLabel
WaterSpawn.cellKey = cellKey

return WaterSpawn
