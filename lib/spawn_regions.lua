-- Connected encounter regions and map-aware spawn capacity.
-- Prefer eligible encounter-tile counts over raw map width*height so
-- buildings / walls do not inflate density.
local V = ...
local Config = V.require("config")
local Surface = V.require("surface")

local SpawnRegions = {}

local function key(x, y)
  return x .. "," .. y
end

local DIRS = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }

-- Collect eligible encounter cells for the resolved surface.
function SpawnRegions.eligibleCells(map, surfaceInfo)
  local out = {}
  if not map or not surfaceInfo then return out end
  local mode = surfaceInfo.tileMode
  local w = map.widthCells or 0
  local h = map.heightCells or 0
  for cy = 0, h - 1 do
    for cx = 0, w - 1 do
      local ok = false
      if mode == "grass" then
        ok = map.isGrassCell and map:isGrassCell(cx, cy)
      elseif mode == "water" then
        ok = map.isWaterCell and map:isWaterCell(cx, cy)
      elseif mode == "walkable" then
        ok = true
        if map.isWalkableCell then ok = map:isWalkableCell(cx, cy) end
        -- Cave floors exclude water and tall grass graphics if present.
        if ok and map.isWaterCell and map:isWaterCell(cx, cy) then ok = false end
      end
      if ok then
        if map.isWalkableCell and mode ~= "water" and not map:isWalkableCell(cx, cy) then
          -- Grass mode still lists graphic grass; walkability filtered at pick.
        elseif mode == "water" or not (map.warpAtCell and map:warpAtCell(cx, cy)) then
          if mode == "walkable" and map.warpAtCell and map:warpAtCell(cx, cy) then
            -- skip warps for cave walkables
          else
            out[#out + 1] = { x = cx, y = cy }
          end
        end
      end
    end
  end
  return out
end

-- Flood-fill 4-connected regions from an eligible cell list.
function SpawnRegions.build(cells)
  local regions = {}
  local cellSet = {}
  for _, c in ipairs(cells or {}) do
    cellSet[key(c.x, c.y)] = c
  end
  local seen = {}
  for _, start in ipairs(cells or {}) do
    local sk = key(start.x, start.y)
    if not seen[sk] then
      local queue = { start }
      local tiles = {}
      local minX, maxX = start.x, start.x
      local minY, maxY = start.y, start.y
      seen[sk] = true
      local qi = 1
      while qi <= #queue do
        local c = queue[qi]
        qi = qi + 1
        tiles[#tiles + 1] = c
        if c.x < minX then minX = c.x end
        if c.x > maxX then maxX = c.x end
        if c.y < minY then minY = c.y end
        if c.y > maxY then maxY = c.y end
        for _, d in ipairs(DIRS) do
          local nx, ny = c.x + d[1], c.y + d[2]
          local nk = key(nx, ny)
          if cellSet[nk] and not seen[nk] then
            seen[nk] = true
            queue[#queue + 1] = cellSet[nk]
          end
        end
      end
      local id = #regions + 1
      local region = {
        id = id,
        tiles = tiles,
        tileCount = #tiles,
        minX = minX, maxX = maxX, minY = minY, maxY = maxY,
        spanX = maxX - minX + 1,
        spanY = maxY - minY + 1,
        membership = {},
      }
      for _, t in ipairs(tiles) do
        region.membership[key(t.x, t.y)] = true
      end
      regions[id] = region
    end
  end
  return regions
end

function SpawnRegions.contains(region, x, y)
  if not region or not region.membership then return false end
  return region.membership[key(x, y)] == true
end

function SpawnRegions.regionForCell(regions, x, y)
  for _, region in ipairs(regions or {}) do
    if SpawnRegions.contains(region, x, y) then return region end
  end
  return nil
end

local DENSITY_FACTOR = {
  low = 0.55,
  normal = 1.0,
  high = 1.45,
  very_high = 1.9,
}

function SpawnRegions.densityFactor(densityKey)
  return DENSITY_FACTOR[densityKey] or DENSITY_FACTOR.normal
end

-- Capacity from eligible tiles (primary) with a soft map-span bonus.
-- Never uses raw width*height alone — buildings inflate that badly.
function SpawnRegions.targetCount(opts)
  opts = opts or {}
  local eligible = tonumber(opts.eligibleTiles) or 0
  local minVis = tonumber(opts.minVisible) or Config.DEFAULTS.min_visible_pokemon
  local maxVis = tonumber(opts.maxVisible) or Config.DEFAULTS.max_visible_pokemon
  local tilesPer = tonumber(opts.tilesPerAdditional)
                  or Config.DEFAULTS.tiles_per_additional_pokemon
  local density = opts.density or "normal"
  local factor = SpawnRegions.densityFactor(density)
  local spanBonus = 0
  local span = tonumber(opts.mapSpan) or 0
  -- Soft bonus for very long routes: +1 per 40 cells of max(spanX,spanY)
  -- beyond 20, still secondary to tile count.
  if span > 20 then
    spanBonus = math.floor((span - 20) / 40)
  end

  if tilesPer < 1 then tilesPer = 1 end
  local raw = minVis + math.floor(eligible / tilesPer) + spanBonus
  raw = math.floor(raw * factor + 0.5)
  if raw < minVis then raw = minVis end
  if raw > maxVis then raw = maxVis end
  if eligible <= 0 then return 0 end
  -- Tiny patches: never more Pokemon than roughly tiles/3.
  local hardCap = math.max(minVis, math.floor(eligible / 3))
  if raw > hardCap then raw = hardCap end
  if raw > maxVis then raw = maxVis end
  return raw
end

-- Proportional quotas per region; tiny regions get at most 1.
function SpawnRegions.allocate(regions, targetCount)
  local quotas = {}
  local totalTiles = 0
  local list = {}
  for _, region in ipairs(regions or {}) do
    list[#list + 1] = region
    totalTiles = totalTiles + (region.tileCount or 0)
  end
  if #list == 0 or targetCount <= 0 or totalTiles <= 0 then
    return quotas, 0
  end
  table.sort(list, function(a, b)
    return (a.tileCount or 0) > (b.tileCount or 0)
  end)

  local assigned = 0
  for _, region in ipairs(list) do
    local share = (region.tileCount / totalTiles) * targetCount
    local q = math.floor(share + 0.5)
    if q < 1 and region.tileCount >= 2 then q = 1 end
    if region.tileCount < 2 then q = math.min(q, 1) end
    -- Cap density inside a region: at least ~6 tiles per pokemon.
    local regionCap = math.max(1, math.floor(region.tileCount / 6))
    if q > regionCap then q = regionCap end
    quotas[region.id] = q
    assigned = assigned + q
  end

  -- Trim overflow from smallest regions first.
  while assigned > targetCount do
    local trimmed = false
    for i = #list, 1, -1 do
      local id = list[i].id
      if quotas[id] and quotas[id] > 0 then
        quotas[id] = quotas[id] - 1
        assigned = assigned - 1
        trimmed = true
        if assigned <= targetCount then break end
      end
    end
    if not trimmed then break end
  end

  -- Top up under-filled capacity on largest regions.
  local guard = 0
  while assigned < targetCount and guard < 64 do
    guard = guard + 1
    local grew = false
    for _, region in ipairs(list) do
      local id = region.id
      local regionCap = math.max(1, math.floor(region.tileCount / 6))
      local q = quotas[id] or 0
      if q < regionCap then
        quotas[id] = q + 1
        assigned = assigned + 1
        grew = true
        if assigned >= targetCount then break end
      end
    end
    if not grew then break end
  end

  return quotas, assigned
end

function SpawnRegions.summarize(regions, quotas, target)
  return {
    regionCount = regions and #regions or 0,
    target = target or 0,
    quotas = quotas or {},
  }
end

-- Min distance between two spawn positions (chebyshev).
function SpawnRegions.minSeparation()
  return Config.DEFAULTS.min_spawn_separation or 3
end

return SpawnRegions
