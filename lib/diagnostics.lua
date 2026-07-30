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
    local hasAsset = entity.sprite ~= nil and entity.spriteId ~= nil
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

function Diagnostics.hudSnapshot(logic)
  local st = logic.state
  local vis = Diagnostics.visibilityCounts(logic)
  local maxSpawns = Config.get(logic.mod, "max_spawns") or Config.DEFAULTS.max_spawns
  local spawnStatus = Diagnostics.spawnSystemStatus(logic)
  local rendererStatus = Diagnostics.rendererStatus(logic)
  local lastErr = Diagnostics.shortError(st.lastError or st.lastSpawnError)
  return {
    mapId = st.mapId,
    mapName = st.mapName or st.mapId or "?",
    mapType = st.mapType or "unknown",
    encounterSpecies = st.uniqueSpeciesCount or 0,
    encounterSlots = st.encounterEntryCount or 0,
    eligibleTiles = st.eligibleTileCount or 0,
    requiredAssets = st.requiredAssets or 0,
    loadedAssets = st.loadedAssets or 0,
    activePokemon = vis.active,
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
    "Overworld Spawn Debug",
    ("Map: %s"):format(tostring(s.mapName)),
    ("Encounter species: %d"):format(s.encounterSpecies),
    ("Encounter slots: %d"):format(s.encounterSlots),
    ("Eligible spawn tiles: %d"):format(s.eligibleTiles),
    ("Loaded assets: %d / %d"):format(s.loadedAssets, s.requiredAssets),
    ("Active Pokemon: %d / %d"):format(s.activePokemon, s.maxPokemon),
    ("Spawn system: %s"):format(s.spawnStatus),
    ("Renderer: %s"):format(s.rendererStatus),
    ("Pokemon: %d active"):format(s.activePokemon),
    ("Created: %d"):format(s.created),
    ("Registered: %d"):format(s.registered),
    ("Rendered: %d"):format(s.rendered),
  }
  if s.lastError then
    lines[#lines + 1] = ("Last error: %s"):format(s.lastError)
  end
  if s.pokedexOwned ~= nil then
    lines[#lines + 1] = ("Pokedex obtained: %s"):format(tostring(s.pokedexOwned))
  end
  return lines, s
end

return Diagnostics
