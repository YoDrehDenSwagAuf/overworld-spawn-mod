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
    active = logic.countVisibleOnMap
      and logic:countVisibleOnMap(logic.activeMapId)
      or logic:countOnMap(logic.activeMapId),
  }
end

function Diagnostics.entityDetail(logic, entity, record)
  if not entity then return {} end
  local bx = entity.behaviorState or {}
  local scale = entity.scaleInfo or {}
  local Tile = V.require("tile")
  local VoxelAdapter = V.require("voxel_adapter")
  local lines = {
    ("Entity ID: %s"):format(tostring(entity.id or entity.spawnId or "?")),
    ("Behavior: %s"):format(tostring(entity.behavior or record and record.behavior)),
    ("Behaviour: %s"):format(tostring(entity.behavior or record and record.behavior)),
    ("Behavior state: %s"):format(tostring(bx.state or "?")),
    ("Surface: %s"):format(tostring(entity.surface or "?")),
    ("Home region: %s"):format(tostring(entity.homeRegionId or "?")),
    ("Facing: %s"):format(tostring(entity.facing or bx.facing or "?")),
  }
  do
    local SpawnFx = V.require("spawn_fx")
    local fx = entity.spawnFx
    local kind = (fx and fx.kind) or "NONE"
    lines[#lines + 1] = ("Spawn FX: %s"):format(tostring(kind):upper())
    if fx and not fx.done then
      lines[#lines + 1] = ("Spawn FX Phase: %.2fs / %.2fs"):format(
        fx.elapsed or 0, fx.duration or 0)
    else
      lines[#lines + 1] = ("Spawn FX Phase: %s"):format(fx and fx.done and "DONE" or "NONE")
    end
    lines[#lines + 1] = ("Body Visible: %s"):format(
      SpawnFx.bodyVisible(entity) and "YES" or "NO")
    lines[#lines + 1] = ("Can Act: %s"):format(SpawnFx.canAct(entity) and "YES" or "NO")
    lines[#lines + 1] = ("Can Battle: %s"):format(SpawnFx.canBattle(entity) and "YES" or "NO")
  end
  if entity.species then
    lines[#lines + 1] = ("Species key: %s"):format(tostring(entity.species))
    lines[#lines + 1] = ("Species ID: %s"):format(tostring(entity.species))
  end
  local dexId = entity.enhancedDexId
  if not dexId and logic and logic.render and logic.render.registrationInfo then
    local reg = logic.render.registrationInfo[entity.species]
    if reg and reg.dexId then dexId = reg.dexId end
  end
  if dexId then
    lines[#lines + 1] = ("Dex ID: %s"):format(tostring(dexId))
  end
  if entity.enhancedStatus then
    lines[#lines + 1] = ("Mapping: %s"):format(tostring(entity.enhancedStatus))
  end
  -- Native runtime-sheet diagnostics.
  local reg = logic and logic.render and logic.render.registrationInfo
    and logic.render.registrationInfo[entity.species]
  local rel = entity.runtimeRelativePath or (reg and reg.relativePath)
  local loadP = entity.runtimeLoadPath
    or (entity.sprite and entity.sprite.def and entity.sprite.def.image)
    or (reg and reg.image)
  local manKey = dexId and (tostring(dexId) .. ":" .. tostring(entity.spriteVariant or "normal"))
  lines[#lines + 1] = ("Runtime manifest key: %s"):format(tostring(manKey or "?"))
  lines[#lines + 1] = ("Runtime relative path: %s"):format(tostring(rel or "?"))
  lines[#lines + 1] = ("Runtime resolved path: %s"):format(tostring(loadP or "?"))
  if reg then
    lines[#lines + 1] = ("Registration kind: %s"):format(tostring(reg.kind or "?"))
    lines[#lines + 1] = ("Registered frames: %s"):format(tostring(reg.frames or "?"))
    lines[#lines + 1] = ("Registered walker: %s"):format(tostring(reg.walker == true))
    lines[#lines + 1] = ("Fallback used: %s"):format(
      (reg.kind == "fallback" or entity.usingFallback) and "YES" or "NO")
    if reg.fallbackReason then
      lines[#lines + 1] = ("Fallback reason: %s"):format(tostring(reg.fallbackReason):sub(1, 72))
    end
  else
    lines[#lines + 1] = ("Fallback used: %s"):format(entity.usingFallback and "YES" or "NO")
  end
  if entity.sprite and entity.sprite.def then
    lines[#lines + 1] = ("Registered sprite image: %s"):format(
      tostring(entity.sprite.def.image or "?"))
    lines[#lines + 1] = ("Sprite frames: %s"):format(tostring(entity.sprite.def.frames or "?"))
    lines[#lines + 1] = ("Walker: %s"):format(entity.sprite.def.walker and "true" or "false")
  end
  if logic and logic.render and logic.render.runtimeSheets and dexId then
    local probe = logic.render.runtimeSheets:probeRegistration(
      dexId, entity.spriteVariant or "normal")
    lines[#lines + 1] = ("Runtime sheet load: %s"):format(
      probe.assetsImageOk and "READY" or ("FAILED " .. tostring(probe.assetsImageError or "")))
    if probe.imageWidth and probe.imageHeight then
      lines[#lines + 1] = ("Runtime image dimensions: %sx%s"):format(
        tostring(probe.imageWidth), tostring(probe.imageHeight))
    end
  end
  for _, line in ipairs(VoxelAdapter.statusLines(entity)) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = ("Sprite source: %s"):format(
    tostring(entity.spriteSource2D or entity.spriteSource
      or (entity.usingEnhancedSprite and "FOLLOW_SPRITES")
      or (entity.usingFallback and "BLACK_FALLBACK") or "LEGACY_PNG"))
  if logic and logic.render and logic.render.spriteProviders then
    local game = logic.mod.world and logic.mod.world.game
    local style = Config.spriteStyle(logic.mod)
    for _, line in ipairs(logic.render.spriteProviders:diagnostics(style, game, entity)) do
      lines[#lines + 1] = line
    end
  end
  -- Requested/Actual renderer lines come from VoxelAdapter.statusLines
  -- via RenderDiagnostics (honest counters).
  if entity.animation and entity.usingEnhancedSprite then
    local anim = entity.animation
    local frameCount = anim._lastFrameCount or "?"
    local variant = tostring(anim.variant or entity.spriteVariant or "normal"):upper()
    lines[#lines + 1] = ("Sprite system: %s"):format(
      tostring(anim.source or entity.spriteSource2D or "FOLLOW_SPRITES"))
    lines[#lines + 1] = ("Variant: %s"):format(variant)
    local AnimatedSprites = V.require("animated_sprites")
    lines[#lines + 1] = ("Runtime shiny support: %s"):format(
      tostring(AnimatedSprites.RUNTIME_SHINY_SUPPORT))
    if AnimatedSprites.RUNTIME_SHINY_SUPPORT ~= "AVAILABLE" then
      lines[#lines + 1] = "Using variant: NORMAL"
    end
    if entity.enhancedDexId and logic and logic.render and logic.render.animated then
      local vm = logic.render.animated:getVariantMapping(
        entity.enhancedDexId, anim.variant or entity.spriteVariant or "normal")
      if vm and vm.fileName then
        lines[#lines + 1] = ("Image file: %s"):format(tostring(vm.fileName))
      end
    end
    lines[#lines + 1] = ("Animation: %s"):format(
      tostring(anim.type or anim.name or "?"):upper())
    lines[#lines + 1] = ("Direction: %s"):format(tostring(anim.direction or "?"):upper())
    lines[#lines + 1] = ("Frame: %s / %s"):format(
      tostring(anim.frameIndex or 1), tostring(frameCount))
    if anim._lastFrameSize then
      lines[#lines + 1] = ("Frame size source: %dx%d"):format(
        anim._lastFrameSize[1] or 0, anim._lastFrameSize[2] or 0)
    elseif scale.contentW then
      lines[#lines + 1] = ("Frame size source: %dx%d"):format(
        scale.contentW or 0, scale.contentH or 0)
    end
    lines[#lines + 1] = ("Billboard card size: %s"):format(
      tostring(entity.voxelCardSize or "16x16"))
    lines[#lines + 1] = ("Render revision: %s"):format(
      tostring(anim.renderRevision or 0))
    lines[#lines + 1] = ("Scale: %s"):format(
      string.format("%.2f", entity.final2DScale or 1))
    if scale.visualFootprintTilesW or scale.visualFootprintTilesH then
      lines[#lines + 1] = ("Visual footprint: %.0fx%.0f tiles"):format(
        scale.visualFootprintTilesW or 1, scale.visualFootprintTilesH or 1)
    end
  end
  lines[#lines + 1] = ("Ground Y: %.1f"):format(entity.py or 0)
  lines[#lines + 1] = ("Visual Y: %.1f"):format(
    entity._lastVisualY or entity.py or 0)
  lines[#lines + 1] = ("Lift: %.1f"):format(entity._lastLift or 0)
  lines[#lines + 1] = ("World pos: %.1f, %.1f"):format(
    entity.px or 0, entity.py or 0)
  for _, line in ipairs((function()
    local GrassOcclusion = V.require("grass_occlusion")
    return GrassOcclusion.statusLines(entity)
  end)()) do
    lines[#lines + 1] = line
  end
  if entity.scaleInfo and (entity.scaleInfo.renderedW or entity.animation) then
    local rw = entity.scaleInfo.renderedW
    local rh = entity.scaleInfo.renderedH
    if entity.animation and entity.animation._lastFrameSize then
      local s = entity.final2DScale or 1
      rw = (entity.animation._lastFrameSize[1] or 0) * s
      rh = (entity.animation._lastFrameSize[2] or 0) * s
    end
    if rw and rh then
      lines[#lines + 1] = ("Rendered sprite size: %.0fx%.0f"):format(rw, rh)
    end
  end
  local now = (love and love.timer and love.timer.getTime and love.timer.getTime())
              or os.clock()
  if bx.nextActionAt then
    lines[#lines + 1] = ("Next action: %.1fs"):format(
      math.max(0, bx.nextActionAt - now))
  end
  lines[#lines + 1] = ("2D registered: %s"):format(
    (entity.registeredInWorld or entity.registered2D) and "YES" or "NO")
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

  local render = logic.render
  local animated = render and render.animated
  if animated then
    local sum = animated:summary()
    lines[#lines + 1] = ("Follow sprites: %s"):format(animated:statusLabel())
    lines[#lines + 1] = ("Mapping files found: %d"):format(sum.mappingFilesFound or 0)
    lines[#lines + 1] = ("Valid mappings: %d"):format(sum.validSpeciesCount or 0)
    lines[#lines + 1] = ("Partial mappings: %d"):format(sum.partialSpeciesCount or 0)
    lines[#lines + 1] = ("Invalid mappings: %d"):format(sum.invalidSpeciesCount or 0)
    lines[#lines + 1] = ("Animated entities: %d"):format(
      render:countAnimatedEntities(logic))
    local VoxelAdapter = V.require("voxel_adapter")
    local va = logic.voxel or (logic.behaviorTick and logic.behaviorTick.voxel)
    if va and va.hooksInstalled then
      lines[#lines + 1] = "Voxel Pokemon: NATIVE_SPRITE_RENDERER"
    end
    if render.runtimeSheets and render.runtimeSheets:isReady() then
      local rs = render.runtimeSheets:summary()
      lines[#lines + 1] = ("Native runtime sheets: %d"):format(rs.sheetCount or 0)
    end
    lines[#lines + 1] = ("Billboard frames cached: %d"):format(sum.voxelCacheEntries or 0)
    lines[#lines + 1] = ("Billboard cache hits/misses: %d/%d"):format(
      sum.voxelCacheHits or 0, sum.voxelCacheMisses or 0)
  end

  if render and render.spriteProviders then
    local game = logic.mod.world and logic.mod.world.game
    local style = Config.spriteStyle(logic.mod)
    local sample = nil
    for _, entity in pairs(logic.entities or {}) do
      if entity and not entity.hiddenEncounter and entity.visibleSprite ~= false then
        sample = entity
        break
      end
    end
    for _, line in ipairs(render.spriteProviders:diagnostics(style, game, sample)) do
      lines[#lines + 1] = line
    end
  end

  do
    local randomOn = Config.randomEncountersEnabled(logic.mod)
    local onOff = randomOn and "ON" or "OFF"
    lines[#lines + 1] = ("Random Enc: %s"):format(onOff)
    lines[#lines + 1] = ("Classic Grass: %s"):format(onOff)
    lines[#lines + 1] = ("Classic Cave: %s"):format(onOff)
    lines[#lines + 1] = ("Classic Water: %s"):format(onOff)
    lines[#lines + 1] = ("Water Mons: %s"):format(
      Config.waterMons(logic.mod) and "ON" or "OFF")
    lines[#lines + 1] = ("Water Cells: %d"):format(#(logic.waterCache or {}))
    lines[#lines + 1] = ("Water Target: %d"):format(logic.targetWaterCount or 0)
    local waterLoaded = 0
    if logic.activeMapId and logic.countWaterOnMap then
      waterLoaded = logic:countWaterOnMap(logic.activeMapId)
    end
    lines[#lines + 1] = ("Water Loaded: %d"):format(waterLoaded)
  end

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
