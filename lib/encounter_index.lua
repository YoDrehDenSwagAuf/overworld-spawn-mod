-- Global encounter location index for the developer preview browser.
-- Built from game.data.encounters (ROM / merged content), never from the
-- Pokédex, never from the currently visited map alone.
local V = ...
local EncounterPick = V.require("encounter_pick")

local EncounterIndex = {}

local function mapLabel(game, mapId)
  local maps = game and game.data and game.data.maps
  local def = maps and maps[mapId]
  if not def then return mapId end
  return def.label or def.name or mapId
end

local function mapTypeOf(game, mapId)
  local maps = game and game.data and game.data.maps
  local def = maps and maps[mapId]
  if not def then return "unknown" end
  local tileset = tostring(def.tileset or ""):upper()
  local id = tostring(mapId):upper()
  if tileset:find("CAVERN") or id:find("CAVE") or id:find("MT_") then
    return "cave"
  end
  if tileset:find("GYM") or tileset:find("HOUSE") or tileset:find("POKECENTER")
     or tileset:find("MART") or tileset:find("INTERIOR")
     or id:find("_HOUSE") or id:find("_GYM") or id:find("CENTER") then
    return "building"
  end
  if id:find("ROUTE") then return "route" end
  if id:find("TOWN") or id:find("CITY") then return "town" end
  if tileset:find("WATER") or id:find("SEA") or id:find("LAKE") then
    return "water"
  end
  return "overworld"
end

-- Build speciesId -> { { mapId, mapName, mapType, kind, levelMin, levelMax,
--                         slots, weightSum }, ... }
function EncounterIndex.build(game)
  local index = {}
  local encounters = game and game.data and game.data.encounters
  if type(encounters) ~= "table" then return index end

  for mapId, encDef in pairs(encounters) do
    if type(mapId) == "string" and type(encDef) == "table" then
      local mapName = mapLabel(game, mapId)
      local mapType = mapTypeOf(game, mapId)
      for _, kind in ipairs(EncounterPick.KINDS) do
        local t = EncounterPick.kindTable(encDef, kind)
        if t then
          local bySpecies = {}
          local weights = EncounterPick.slotWeights(encDef, kind)
          for _, w in ipairs(weights) do
            local sp = w.species
            if sp then
              local bucket = bySpecies[sp]
              if not bucket then
                bucket = {
                  mapId = mapId,
                  mapName = mapName,
                  mapType = mapType,
                  kind = kind,
                  levelMin = w.level,
                  levelMax = w.level,
                  slots = 0,
                  weightSum = 0,
                }
                bySpecies[sp] = bucket
              end
              if w.level < bucket.levelMin then bucket.levelMin = w.level end
              if w.level > bucket.levelMax then bucket.levelMax = w.level end
              bucket.slots = bucket.slots + 1
              bucket.weightSum = bucket.weightSum + (w.weight or 0)
            end
          end
          for sp, loc in pairs(bySpecies) do
            index[sp] = index[sp] or {}
            index[sp][#index[sp] + 1] = loc
          end
        end
      end
    end
  end

  for _, locs in pairs(index) do
    table.sort(locs, function(a, b)
      if a.mapName ~= b.mapName then return a.mapName < b.mapName end
      return a.kind < b.kind
    end)
  end
  return index
end

-- Collapse locations for display:
--   Route 1, Grass: Level 2-5
-- Multiple kinds on the same map stay separate lines.
function EncounterIndex.formatLocations(locs, mapFilter, kindFilter)
  local lines = {}
  if type(locs) ~= "table" then return lines end
  mapFilter = mapFilter and tostring(mapFilter):lower() or ""
  kindFilter = kindFilter and tostring(kindFilter):lower() or "any"

  -- Group by mapId then list kinds.
  local byMap = {}
  local order = {}
  for _, loc in ipairs(locs) do
    if mapFilter == ""
       or tostring(loc.mapId):lower():find(mapFilter, 1, true)
       or tostring(loc.mapName):lower():find(mapFilter, 1, true) then
      if kindFilter == "any" or kindFilter == "" or loc.kind == kindFilter then
        local key = loc.mapId
        if not byMap[key] then
          byMap[key] = { mapName = loc.mapName, mapId = loc.mapId, kinds = {} }
          order[#order + 1] = key
        end
        byMap[key].kinds[#byMap[key].kinds + 1] = loc
      end
    end
  end

  for _, mapId in ipairs(order) do
    local group = byMap[mapId]
    if #group.kinds == 1 then
      local loc = group.kinds[1]
      if loc.levelMin == loc.levelMax then
        lines[#lines + 1] = ("%s, %s: Level %d"):format(
          loc.mapName, loc.kind, loc.levelMin)
      else
        lines[#lines + 1] = ("%s, %s: Level %d-%d"):format(
          loc.mapName, loc.kind, loc.levelMin, loc.levelMax)
      end
    else
      lines[#lines + 1] = group.mapName
      for _, loc in ipairs(group.kinds) do
        if loc.levelMin == loc.levelMax then
          lines[#lines + 1] = ("- %s: Level %d"):format(loc.kind, loc.levelMin)
        else
          lines[#lines + 1] = ("- %s: Level %d-%d"):format(
            loc.kind, loc.levelMin, loc.levelMax)
        end
      end
    end
  end
  return lines
end

function EncounterIndex.mapTypeOf(game, mapId)
  return mapTypeOf(game, mapId)
end

function EncounterIndex.mapLabel(game, mapId)
  return mapLabel(game, mapId)
end

return EncounterIndex
