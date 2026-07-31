-- Derive clear HUD / log status values from the real spawn-system state.
-- Never fabricates READY when prerequisites are missing.
local V = ...
local Config = V.require("config")

local Diagnostics = {}

local STATUS = Config.STATUS

function Diagnostics.spawnSystemStatus(logic)
  local st = logic.state
  if not logic:featureActive() then
    return STATUS.DISABLED
  end
  if st.lastError then
    return STATUS.ERROR
  end
  if st.phase == "initializing" then
    return STATUS.INITIALIZING
  end
  if st.phase == "spawning" then
    return STATUS.SPAWNING
  end
  local why = tostring(st.unsupportedReason or "")
  if why:find("encounter data", 1, true)
     or (st.mapId and st.encounterDataAvailable == false
         and not st.initialized and st.eligibleTilesAvailable ~= true
         and why ~= "" and why:find("encounter", 1, true)) then
    return STATUS.NO_ENCOUNTER_DATA
  end
  if why:find("tile", 1, true)
     or (st.encounterDataAvailable and not st.eligibleTilesAvailable) then
    return STATUS.NO_ELIGIBLE_TILES
  end
  if st.assetsLoading then
    return STATUS.ASSETS_LOADING
  end
  if st.assetError then
    return STATUS.ASSET_ERROR
  end
  if st.encounterDataAvailable and st.rendererAvailable == false then
    return STATUS.NO_RENDERER
  end
  if st.initialized and st.pipelineVerified then
    return STATUS.READY
  end
  if st.unsupportedReason or st.fallbackToVanilla then
    return STATUS.FALLBACK_TO_VANILLA
  end
  if not st.mapSupported and st.mapId then
    return STATUS.FALLBACK_TO_VANILLA
  end
  return STATUS.INITIALIZING
end

function Diagnostics.rendererStatus(logic)
  local st = logic.state
  local render = logic.render
  if st.rendererAvailable and render and render.rendererMode == "base" then
    return STATUS.READY
  end
  if render and render.lastError then
    return STATUS.ERROR
  end
  if st.rendererAvailable == false then
    return STATUS.NO_RENDERER
  end
  if st.assetsLoading then
    return STATUS.ASSETS_LOADING
  end
  if st.assetError then
    return STATUS.ASSET_ERROR
  end
  return STATUS.INITIALIZING
end

function Diagnostics.shortError(err, maxLen)
  if not err then return nil end
  local s = tostring(err):gsub("%s+", " ")
  maxLen = maxLen or 48
  if #s > maxLen then
    return s:sub(1, maxLen - 1) .. "…"
  end
  return s
end

function Diagnostics.visibilityCounts(logic)
  local created, registered, rendered, visible = 0, 0, 0, 0
  local world = logic.mod.world
  local ow = world and world.overworld and world:overworld()
  local player = ow and ow.player
  local cam = ow and ow.cam
  for id, entity in pairs(logic.entities or {}) do
    created = created + 1
    local inWorld = logic:entityRegisteredInWorld(id)
    if inWorld then registered = registered + 1 end
    local hidden = entity.hiddenEncounter == true or entity.visibleSprite == false
    local hasAsset = hidden or (entity.sprite ~= nil and entity.spriteId ~= nil)
    local opacity = Config.get(logic.mod, "sprite_opacity") or 1
    local scaleOk = true
    if entity.sprite and entity.sprite.scale ~= nil then
      scaleOk = entity.sprite.scale > 0
    end
    local notRemoved = entity.state ~= Config.STATE.REMOVED
    if inWorld and hasAsset and opacity > 0 and scaleOk and notRemoved then
      rendered = rendered + 1
      local onCamera = true
      if cam and player then
        -- Approximate camera visibility: within ±12 cells of player.
        local dx = math.abs((entity.cellX or 0) - (player.cellX or 0))
        local dy = math.abs((entity.cellY or 0) - (player.cellY or 0))
        onCamera = dx <= 12 and dy <= 10
      end
      if onCamera then visible = visible + 1 end
    end
  end
  return {
    created = created,
    registered = registered,
    rendered = rendered,
    visible = visible,
    active = logic:countOnMap(logic.activeMapId),
  }
end

function Diagnostics.entityDetail(logic, entity, record)
  if not entity then return {} end
  local bx = entity.behaviorState or {}
  local scale = entity.scaleInfo or {}
  local Tile = V.require("tile")
  local VoxelAdapter = V.require("voxel_adapter")
  local lines = {
    ("Stable entity ID: %s"):format(tostring(entity.id or entity.spawnId or "?")),
    ("Behavior: %s"):format(tostring(entity.behavior or record and record.behavior)),
    ("Behavior state: %s"):format(tostring(bx.state or "?")),
    ("Surface: %s"):format(tostring(entity.surface or "?")),
    ("Home region: %s"):format(tostring(entity.homeRegionId or "?")),
    ("Facing: %s"):format(tostring(entity.facing or bx.facing or "?")),
  }
  local now = (love and love.timer and love.timer.getTime and love.timer.getTime())
              or os.clock()
  if bx.nextActionAt then
    lines[#lines + 1] = ("Next action: %.1fs"):format(
      math.max(0, bx.nextActionAt - now))
  end
  lines[#lines + 1] = ("2D registered: %s"):format(
    (entity.registeredInWorld or entity.registered2D) and "YES" or "NO")
  lines[#lines + 1] = ("Grass overlay: %s"):format(
    entity.inGrassOverlay and "YES" or "NO")
  lines[#lines + 1] = ("Alert icon: %s"):format(
    entity.alertIcon and "ON" or "OFF")
  lines[#lines + 1] = ("Battle pending: %s"):format(
    (bx.battlePending or bx.state == "BATTLE_PENDING") and "YES" or "NO")
  if scale.originalW or scale.imageW then
    lines[#lines + 1] = ("Source image size: %d x %d"):format(
      scale.originalW or scale.imageW or 0, scale.originalH or scale.imageH or 0)
    lines[#lines + 1] = ("Visible bounds: %d x %d"):format(
      scale.contentW or 0, scale.contentH or 0)
    lines[#lines + 1] = ("Tile size: %d x %d"):format(
      scale.tileWidth or Tile.WIDTH, scale.tileHeight or Tile.HEIGHT)
    lines[#lines + 1] = ("Desired scale: %s"):format(
      scale.desiredScale and string.format("%.2f", scale.desiredScale) or "?")
    lines[#lines + 1] = ("Maximum one-tile scale: %s"):format(
      scale.maximumOneTileScale and string.format("%.2f", scale.maximumOneTileScale) or "?")
    lines[#lines + 1] = ("Final 2D scale: %s"):format(
      string.format("%.2f", entity.final2DScale or entity.visualScale or scale.final2DScale or 1))
    lines[#lines + 1] = ("Rendered visible size: %.0f x %.0f"):format(
      scale.renderedW or 0, scale.renderedH or 0)
    lines[#lines + 1] = ("Logical footprint: %d tile"):format(
      scale.logicalFootprintTiles or 1)
  end
  for _, line in ipairs(VoxelAdapter.statusLines(entity)) do
    lines[#lines + 1] = line
  end
  if entity.behavior == "AGGRESSIVE" then
    lines[#lines + 1] = ("Sight range: %s"):format(
      tostring(Config.DEFAULTS.aggressive_sight_range))
    lines[#lines + 1] = ("Player detected: %s"):format(
      bx.playerDetected and "YES" or "NO")
    lines[#lines + 1] = ("Chasing: %s"):format(bx.chasing and "YES" or "NO")
  end
  if entity.hiddenEncounter then
    lines[#lines + 1] = "Visible sprite: NO"
    lines[#lines + 1] = ("Grass effect: %s"):format(
      entity.grassEffectActive and "ACTIVE" or "IDLE")
  end
  return lines
end

function Diagnostics.hudSnapshot(logic)
  local st = logic.state
  local vis = Diagnostics.visibilityCounts(logic)
  local maxSpawns = Config.maxVisible(logic.mod)
  local target = st.targetSpawnCount or logic.targetSpawnCount or maxSpawns
  local spawnStatus = Diagnostics.spawnSystemStatus(logic)
  local rendererStatus = Diagnostics.rendererStatus(logic)
  local lastErr = Diagnostics.shortError(st.lastError or st.lastSpawnError)
  return {
    mapId = st.mapId,
    mapName = st.mapName or st.mapId or "?",
    mapType = st.mapType or "unknown",
    surface = st.surface or (logic.surfaceInfo and logic.surfaceInfo.surface) or "?",
    encounterSpecies = st.uniqueSpeciesCount or 0,
    encounterSlots = st.encounterEntryCount or 0,
    eligibleTiles = st.eligibleTileCount or 0,
    spawnRegions = st.spawnRegionCount or #(logic.regions or {}),
    requiredAssets = st.requiredAssets or 0,
    loadedAssets = st.loadedAssets or 0,
    activePokemon = vis.active,
    targetPokemon = target,
    maxPokemon = maxSpawns,
    spawnStatus = spawnStatus,
    rendererStatus = rendererStatus,
    lastError = lastErr,
    created = vis.created,
    registered = vis.registered,
    rendered = vis.rendered,
    visible = vis.visible,
    pokedexOwned = st.pokedexOwnedDiag,
  }
end

function Diagnostics.hudLines(logic)
  local s = Diagnostics.hudSnapshot(logic)
  local lines = {
    "Wilds of Kanto Debug",
    ("Map: %s"):format(tostring(s.mapName)),
    ("Surface: %s"):format(tostring(s.surface)),
    ("Encounter species: %d"):format(s.encounterSpecies),
    ("Encounter slots: %d"):format(s.encounterSlots),
    ("Eligible spawn tiles: %d"):format(s.eligibleTiles),
    ("Spawn regions: %d"):format(s.spawnRegions),
    ("Loaded assets: %d / %d"):format(s.loadedAssets, s.requiredAssets),
    ("Target Pokemon: %d"):format(s.targetPokemon),
    ("Active Pokemon: %d / %d"):format(s.activePokemon, s.maxPokemon),
    ("Spawn system: %s"):format(s.spawnStatus),
    ("Renderer: %s"):format(s.rendererStatus),
    ("Created: %d"):format(s.created),
    ("Registered: %d"):format(s.registered),
    ("Rendered: %d"):format(s.rendered),
  }
  -- Detail the nearest entity when developer overlays are on.
  if Config.devMode(logic.mod) then
    local world = logic.mod.world
    local ow = world and world.overworld and world:overworld()
    local player = ow and ow.player
    local best, bestD, bestId
    if player then
      for id, entity in pairs(logic.entities or {}) do
        local d = math.abs((entity.cellX or 0) - player.cellX)
                + math.abs((entity.cellY or 0) - player.cellY)
        if not bestD or d < bestD then
          bestD, best, bestId = d, entity, id
        end
      end
    end
    if best then
      lines[#lines + 1] = "-- Nearest entity --"
      for _, line in ipairs(Diagnostics.entityDetail(logic, best, logic.spawns[bestId])) do
        lines[#lines + 1] = line
      end
    end
  end
  if s.lastError then
    lines[#lines + 1] = ("Last error: %s"):format(s.lastError)
  end
  if s.pokedexOwned ~= nil then
    lines[#lines + 1] = ("Pokedex obtained: %s"):format(tostring(s.pokedexOwned))
  end
  return lines, s
end

return Diagnostics
