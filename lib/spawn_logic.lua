-- Logic half of overworld_wild_spawns: map enter, periodic spawn, optional
-- wander, touch -> battle, developer test spawn. Rendering is delegated to
-- SpawnRender.
--
-- Fail-safe: vanilla encounter rolls are suppressed when Random Enc is OFF
-- (see SpawnLogic:shouldSuppressClassicEncounter / canSuppressVanilla).
-- The Pokédex is never a spawn gate. The player is never teleported.
local V = ...
local Config = V.require("config")
local EncounterPick = V.require("encounter_pick")
local EncounterIndex = V.require("encounter_index")
local Grass = V.require("grass")
local SpawnState = V.require("spawn_state")
local DebugLog = V.require("debug_log")
local Diagnostics = V.require("diagnostics")
local Surface = V.require("surface")
local SpawnRegions = V.require("spawn_regions")
local Behavior = V.require("behavior")
local Movement = V.require("movement")
local VoxelAdapter = V.require("voxel_adapter")
local SpawnFx = V.require("spawn_fx")
local WaterSpawn = V.require("water_spawn")
local AnimatedSprites = V.require("animated_sprites")
local CellOccupancy = V.require("cell_occupancy")
local FollowersWaterCompat = V.require("followers_water_compat")
local CaveReachability = V.require("cave_reachability")
local SafariCompat = V.require("safari_compat")

local SpawnLogic = {}
SpawnLogic.__index = SpawnLogic

local TEST_STEPS = {
  "Species resolved",
  "Sprite registered",
  "Runtime asset loaded",
  "Spawn tile resolved",
  "Entity created",
  "Entity registered",
  "Entity visible",
}

local function gameOf(mod)
  if mod.world and mod.world.game then return mod.world.game end
  return mod._testGame
end

local function rngOf()
  if love and love.math and love.math.random then return love.math.random end
  return math.random
end

local function pokedexOwnedForDiag(game)
  -- Diagnostic only. Never used as a spawn condition.
  local save = game and game.save
  local dex = save and save.pokedex
  if not dex then return false end
  if dex.owned and next(dex.owned) then return true end
  return false
end

function SpawnLogic.new(mod, render)
  local self = setmetatable({}, SpawnLogic)
  self.mod = mod
  self.render = render
  self.spawns = {}      -- id -> record
  self.byMap = {}       -- mapId -> { id, ... }
  self.entities = {}    -- id -> entity
  self.stepsOnMap = 0
  self.activeMapId = nil
  self.pendingBattle = nil
  self.nextId = 1
  self.grassCache = nil
  self.eligibleCache = nil
  self.regions = {}
  self.regionQuotas = {}
  self.regionCounts = {}
  self.targetSpawnCount = 0
  self.surfaceInfo = nil
  self.state = SpawnState.new()
  self.state.updateCallbackRegistered = true
  self._restoreVanilla = nil
  self.hud = nil
  self.overlay = nil
  self.browser = nil
  self.behaviorTick = nil
  self.lastTestSpawn = nil
  self.voxel = VoxelAdapter.new(mod)
  self.spawnFx = SpawnFx.new(mod)
  self.waterCache = nil
  self.waterRegions = {}
  self.targetWaterCount = 0
  self.waterPool = nil
  self.waterZonePools = nil
  self.shoreDistance = nil
  self.waterZoneTargets = nil
  self.waterZoneCounts = { near = 0, mid = 0, deep = 0 }
  self.recentWaterSpecies = {}
  self._lastStepDiag = nil
  self.occupancy = CellOccupancy.new()
  self.followersWater = FollowersWaterCompat.new(mod)
  -- Land style resolver bound after self exists (closure over logic).
  self.followersWater.resolveLandSprite = function(speciesId, isShiny, form, opts)
    opts = opts or {}
    local style = opts.style or Config.spriteStyle(mod)
    local game = opts.game or gameOf(mod)
    local variant = (isShiny == true or isShiny == "shiny") and "shiny" or "normal"
    local providers = self.render and self.render.spriteProviders
    if not providers then return nil, nil end
    local result = providers:resolve(style, speciesId, variant, game)
    if result and result.def then
      return result.def, {
        providerId = result.providerId,
        kind = result.providerId,
        frames = result.def.frames,
      }
    end
    return nil, nil
  end
  return self
end

function SpawnLogic:rebuildOccupancy(ow)
  local occupancy = self.occupancy or CellOccupancy.new()
  self.occupancy = occupancy
  ow = ow or (self.mod.world and self.mod.world.overworld
              and self.mod.world:overworld())
  occupancy:rebuild({
    player = ow and ow.player,
    entities = ow and ow.entities,
    npcs = ow and ow.npcs,
    logicEntities = self.entities,
    trailers = ow and ow.pokepcTrailers,
  })
  return occupancy
end

function SpawnLogic:occupancyContext(ow)
  ow = ow or (self.mod.world and self.mod.world.overworld
              and self.mod.world:overworld())
  return {
    player = ow and ow.player,
    entities = ow and ow.entities,
    npcs = ow and ow.npcs,
    logicEntities = self.entities,
    trailers = ow and ow.pokepcTrailers,
  }
end

-- Central per-entity sprite refresh. Replaces SpriteDef / native SpriteRenderer
-- only; never mutates position, movement, behaviour, battle payload, or voxels.
function SpawnLogic:refreshEntitySprite(entity, opts)
  opts = opts or {}
  if not entity then return false, "no_entity" end
  local reason = opts.reason or "refresh"
  entity.lastSpriteRefreshReason = reason
  if opts.surface ~= nil then
    entity.surface = opts.surface
  end
  if opts.spriteState ~= nil then
    entity.spriteState = opts.spriteState
  elseif entity.surface == Surface.WATER then
    entity.spriteState = "water"
  end
  if opts.pendingSpriteDef then
    entity.pendingSpriteDef = opts.pendingSpriteDef
  end
  if opts.pendingSurface ~= nil then
    entity.pendingSurface = opts.pendingSurface
  end
  local game = opts.game or gameOf(self.mod)
  local render = self.render
  if not (render and render.applyProviderSprite) then
    return false, "no_render"
  end
  local ok, applied = pcall(render.applyProviderSprite, render, entity, game)
  if not ok then
    self:_warn("refreshEntitySprite failed (%s): %s", tostring(reason), tostring(applied))
    return false, applied
  end
  if applied and entity.pendingSpriteDef and opts.clearPending ~= false then
    -- Applied via resolver path; drop pending payload.
    if entity.spriteState == "water" or entity.surface == Surface.WATER then
      entity.pendingSpriteDef = nil
      entity.waterSpritePrepared = true
      entity.waterSpriteApplied = true
    end
  end
  entity.spriteRefreshAt = (love and love.timer and love.timer.getTime and love.timer.getTime())
    or os.clock()
  return applied == true, nil
end

-- Public water-sprite resolution used by Wilds entities and Followers EX compat.
-- Default follower-safe rule: swimming → levitates → nil (no land masquerade).
function SpawnLogic:resolveWaterSprite(speciesId, isShiny, form, opts)
  opts = opts or {}
  local variant
  if type(isShiny) == "string" then
    variant = isShiny
  else
    variant = (isShiny == true) and "shiny" or "normal"
  end
  local allowLandFallback = opts.allowLandFallback == true
  if opts.follower == true then
    allowLandFallback = false
  end
  local render = self.render
  local reg = render and render.waterSpriteRegistry
  local game = opts.game or gameOf(self.mod)

  -- When the GSC / Poke Followers sprite style is selected, try the
  -- poke_followers submerged sheet directly (fsExists, no mod:read).
  -- Otherwise fall through to the swimming/levitates registry so the
  -- selected style (e.g. HGSS) is respected.
  local style = opts.style or Config.spriteStyle(self.mod)
  if Config and type(Config.normalizeSpriteStyle) == "function" then
    style = Config.normalizeSpriteStyle(style)
  end
  local trySubmerged = style == "followers" and function()
    local dexId = speciesId
    if type(dexId) ~= "number" then
      dexId = AnimatedSprites.resolveSpeciesId(speciesId, game, self.mod)
    end
    if not dexId then return nil end
    local redpp = Config and type(Config.paletteFxRedpp) == "function"
      and Config.paletteFxRedpp()
    local tryVariants
    if redpp then
      if variant == "shiny" then
        tryVariants = { "shiny_submerged", "normal_submerged" }
      else
        tryVariants = { "normal_submerged" }
      end
    else
      tryVariants = { "grayscale_submerged" }
    end
    for _, v in ipairs(tryVariants) do
      local rel = string.format(
        "assets/enhanced_overworld/poke_followers/follower_%03d_%s.png",
        dexId, v)
      local loadPath = rel
      if self.mod and self.mod.assets and self.mod.assets.path then
        local ok, p = pcall(function() return self.mod.assets:path(rel) end)
        if ok and type(p) == "string" then loadPath = p end
      end
      if (love and love.filesystem and love.filesystem.getInfo
          and love.filesystem.getInfo(loadPath))
         or (love and love.filesystem and love.filesystem.getInfo
             and love.filesystem.getInfo(rel)) then
        return {
          image = loadPath,
          frames = 6,
          walker = true,
          trueColor = true,
          id = "SPRITE_OW_WILD_SUBMERGED_" .. tostring(dexId),
        }, {
          kind = "submerged",
          speciesId = dexId,
          variant = v,
          form = form,
          image = loadPath,
          frames = 6,
          walker = true,
        }
      end
    end
    return nil, nil
  end

  local subDef, subMeta = nil, nil
  if trySubmerged then
    subDef, subMeta = trySubmerged()
    if subDef then
      return subDef, subMeta
    end
  end

  -- Prefer registry path for a stable, style-independent water result.
  if reg and reg.isReady and reg:isReady() then
    local dexId = speciesId
    if type(dexId) ~= "number" then
      dexId = AnimatedSprites.resolveSpeciesId(speciesId, game, self.mod)
    end
    if dexId then
      local preferred = reg:preferredKindFor(dexId)
      local waterDef, waterErr = reg:resolve(dexId, variant, preferred, form)
      if waterDef then
        local spriteDef = {
          image = waterDef.image,
          frames = waterDef.frames or 6,
          walker = true,
          trueColor = true,
          id = waterDef.id,
          kind = waterDef.kind,
        }
        local meta = {
          kind = waterDef.kind,
          speciesId = waterDef.speciesId or dexId,
          variant = waterDef.variant or variant,
          form = waterDef.formKey or form,
          image = waterDef.image,
          frames = waterDef.frames or 6,
          walker = true,
        }
        return spriteDef, meta
      end
      if not allowLandFallback then
        return nil, { error = waterErr or "no swimming or levitates asset" }
      end
    end
  end

  if not allowLandFallback then
    return nil, { error = "no swimming or levitates asset" }
  end

  -- Optional land-style fallback for Wilds water entities only.
  local resolver = render and render.spriteResolver
  if resolver and resolver.resolveWaterSprite then
    local entity = opts.entity or {
      species = speciesId,
      enhancedDexId = type(speciesId) == "number" and speciesId or nil,
      shiny = variant == "shiny",
      surface = Surface.WATER,
      form = form,
    }
    local result = resolver:resolveWaterSprite(entity, {
      style = opts.style or Config.spriteStyle(self.mod),
      game = game,
      speciesId = type(speciesId) == "number" and speciesId or nil,
      variant = variant,
      form = form,
    })
    if result and result.def and result.def.image
       and (result.spriteKind == "swimming" or result.spriteKind == "levitates") then
      return result.def, {
        kind = result.spriteKind,
        speciesId = speciesId,
        variant = variant,
        form = form,
        image = result.def.image,
        frames = result.def.frames or 6,
        walker = result.def.walker == true,
      }
    end
    if result and result.def and allowLandFallback then
      return result.def, {
        kind = result.spriteKind or result.providerId,
        speciesId = speciesId,
        variant = variant,
        form = form,
        image = result.def.image,
        frames = result.def.frames or 1,
        walker = result.def.walker == true,
        fallback = true,
      }
    end
  end
  return nil, { error = "all water resolvers failed" }
end

function SpawnLogic:_validateNoCellOverlap(ow)
  local occupancy = self.occupancy
  if not occupancy then return end
  local conflicts = occupancy:assertOnlyOneBlockingEntityPerCell(
    self:occupancyContext(ow),
    function(c)
      self:_warn("occupancy conflict at %s,%s owners=%s/%s",
                 tostring(c.x), tostring(c.y), tostring(c.a), tostring(c.b))
      -- Prefer removing the younger Wilds spawn (higher numeric suffix).
      local function wildId(owner)
        if type(owner) ~= "string" then return nil end
        if owner:find("wilds_of_kanto_entity_", 1, true) then return owner end
        return nil
      end
      local a, b = wildId(c.a), wildId(c.b)
      local removeId = b or a
      if removeId and self.entities[removeId] then
        DebugLog.warn(self.mod,
          "removing overlapping spawn %s at %s,%s", removeId, tostring(c.x), tostring(c.y))
        self:_despawn(removeId, true)
        occupancy:releaseEntity(removeId)
      end
    end)
  return conflicts
end

function SpawnLogic:setRestoreVanilla(fn)
  self._restoreVanilla = fn
end

function SpawnLogic:attachDevTools(hud, overlay, browser, behaviorTick, devOverlay)
  self.hud = hud
  self.overlay = overlay
  self.browser = browser
  self.behaviorTick = behaviorTick
  self.devOverlay = devOverlay
  if self.voxel and self.voxel.attachLogic then
    self.voxel:attachLogic(self)
  end
  if behaviorTick and behaviorTick.voxel and behaviorTick.voxel.attachLogic then
    behaviorTick.voxel:attachLogic(self)
  end
end

function SpawnLogic:canSuppressVanilla()
  local suppress = not Config.randomEncountersEnabled(self.mod)
  self.state.vanillaSuppressed = suppress
  return suppress
end

-- True when classic encounter RNG must be blocked (grass / cave / water).
-- Active Safari sessions always suppress step encounters (independent of
-- Random Enc) so visible Safari Pokémon can be approached safely.
-- Water Mons modes may override Random Enc for water / fishing only:
--   classic_encounters → never suppress water (even if Random Enc OFF)
--   disabled           → always suppress water
-- Land / cave remain gated solely by Random Enc (+ Safari).
function SpawnLogic:shouldSuppressClassicEncounter(ctx)
  local game = gameOf(self.mod)
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  local mapId = (ctx and ctx.mapId) or (ow and ow.map and ow.map.id) or self.activeMapId
  if SafariCompat.shouldSuppressClassicEncounters(game, ow, mapId) then
    return true
  end

  local WaterDisplay = V.require("water_display")
  if WaterDisplay.isWaterTerrain(ctx) then
    if Config.waterEncountersDisabled(self.mod) then
      return true
    end
    if Config.waterClassicEncountersForced(self.mod) then
      return false
    end
  end

  return not Config.randomEncountersEnabled(self.mod)
end

function SpawnLogic:_safariStatus(game, ow, mapId)
  game = game or gameOf(self.mod)
  local world = self.mod.world
  ow = ow or (world and world.overworld and world:overworld())
  mapId = mapId or (ow and ow.map and ow.map.id) or self.activeMapId
  return SafariCompat.status(game, ow, mapId)
end

function SpawnLogic:_safariActive(game, ow, mapId)
  return self:_safariStatus(game, ow, mapId) == SafariCompat.STATUS.ACTIVE
end

function SpawnLogic:_log(fmt, ...)
  DebugLog.info(self.mod, fmt, ...)
end

function SpawnLogic:_debug(fmt, ...)
  DebugLog.debug(self.mod, fmt, ...)
end

function SpawnLogic:_warn(fmt, ...)
  DebugLog.warn(self.mod, fmt, ...)
end

function SpawnLogic:_restoreVanillaEncounters(reason)
  self.state.vanillaSuppressed = false
  self.state.initialized = false
  self.state.pipelineVerified = false
  self.state.fallbackToVanilla = true
  if reason then
    self:_log("restore vanilla encounters: %s", tostring(reason))
  end
  if self._restoreVanilla then
    local ok, err = pcall(self._restoreVanilla, reason)
    if not ok then
      self:_warn("restoreVanilla callback failed: %s", tostring(err))
    end
  end
end

function SpawnLogic:_encDef(mapId, game)
  game = game or gameOf(self.mod)
  if not game or not game.data then return nil end
  local encounters = game.data.encounters
  if type(encounters) ~= "table" then return nil end
  return encounters[mapId]
end

function SpawnLogic:_clearMap(mapId)
  local list = self.byMap[mapId]
  if not list then return end
  local ids = {}
  for i, id in ipairs(list) do ids[i] = id end
  for _, id in ipairs(ids) do
    self:_despawn(id, true)
  end
  self.byMap[mapId] = {}
  if self.occupancy then self.occupancy:clear() end
end

function SpawnLogic:clearAll()
  local maps = {}
  for mapId in pairs(self.byMap) do maps[#maps + 1] = mapId end
  for _, mapId in ipairs(maps) do
    self:_clearMap(mapId)
  end
  self.pendingBattle = nil
  self.grassCache = nil
  self.eligibleCache = nil
  self.regions = {}
  self.regionQuotas = {}
  self.regionCounts = {}
  self.targetSpawnCount = 0
  self.surfaceInfo = nil
  if self.occupancy then self.occupancy:clear() end
  if self.overlay then self.overlay:clear() end
  self:_restoreVanillaEncounters("clearAll")
  self.state:reset("clearAll")
  self.state.updateCallbackRegistered = true
end

function SpawnLogic:_occupiedSpawnCoords(mapId)
  local out = {}
  for _, id in ipairs(self.byMap[mapId] or {}) do
    local r = self.spawns[id]
    if r and r.state == Config.STATE.AVAILABLE then
      out[#out + 1] = { x = r.x, y = r.y }
    end
  end
  return out
end

function SpawnLogic:_recountRegions()
  self.regionCounts = {}
  for _, region in ipairs(self.regions or {}) do
    self.regionCounts[region.id] = 0
  end
  for _, record in pairs(self.spawns) do
    if record.state == Config.STATE.AVAILABLE and record.homeRegionId then
      local id = record.homeRegionId
      self.regionCounts[id] = (self.regionCounts[id] or 0) + 1
    end
  end
end

function SpawnLogic:_pickUnderfilledRegion(rng)
  rng = rng or math.random
  local candidates = {}
  for _, region in ipairs(self.regions or {}) do
    local q = self.regionQuotas[region.id] or 0
    local c = self.regionCounts[region.id] or 0
    if c < q then
      candidates[#candidates + 1] = region
    end
  end
  if #candidates == 0 then
    -- Fall back to any region with free tile capacity.
    for _, region in ipairs(self.regions or {}) do
      local cap = math.max(1, math.floor((region.tileCount or 0) / 6))
      local c = self.regionCounts[region.id] or 0
      if c < cap then candidates[#candidates + 1] = region end
    end
  end
  if #candidates == 0 then return nil end
  return candidates[rng(#candidates)]
end

function SpawnLogic:_onAggressiveAlert(entity, record)
  if not entity or not record then return end
  if record.state ~= Config.STATE.AVAILABLE then return end
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if not ow then return end
  local bx = entity.behaviorState
  if not bx then return end
  -- Exactly one alert / emote per detection.
  if bx.alertEmoteSpawned then return end

  local safariFlee = Behavior.isSafariFlee(bx.behavior or entity.behavior
                                           or record.behavior)

  -- Stop movement and disable sight for the reaction pause.
  Movement.stop(entity, "ALERT")
  bx.sightDisabled = true
  bx.alertAt = bx.alertAt or (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
  bx.state = Behavior.STATE.ALERT
  if safariFlee then
    local sf = bx.safariFlee or Behavior.newSafariFleeState()
    bx.safariFlee = sf
    sf.noticedPlayer = true
    sf.alertStarted = true
    sf.active = true
  end

  if ow.emote or ow.engaging then
    -- Emote slot busy: Behaviour fail-safe arms chase/flee after timeout.
    return
  end

  bx.alertEmoteSpawned = true

  -- Engine emotion bubble (same path as trainers). NOT a wild/Voxel entity.
  -- No species, no collision, no spawn slot — only npc.px/py for anchoring.
  local frames = safariFlee and (SafariCompat.ALERT_FRAMES or 24) or 60
  ow.emote = {
    npc = entity,
    frames = frames,
    onDone = function()
      if safariFlee then
        Behavior.markFleeReady(entity)
      else
        -- Clear emote ownership first; then arm chase exactly once.
        Behavior.markChaseReady(entity)
      end
    end,
  }
  entity.alertIcon = true
  self:_log("%s alert id=%s species=%s at (%d,%d)",
            safariFlee and "safari flee" or "aggressive",
            tostring(entity.id or record.id),
            tostring(record.species), record.x, record.y)
end

function SpawnLogic:_detachFromWorld(entity)
  if not entity then return end
  local world = self.mod.world
  if not world or not world.overworld then return end
  local ow = world:overworld()
  if not ow then return end
  for _, listName in ipairs({ "entities", "npcs" }) do
    local list = ow[listName]
    if list then
      for i = #list, 1, -1 do
        if list[i] == entity then table.remove(list, i) end
      end
    end
  end
  entity.registeredInWorld = false
  entity.registered2D = false
  if self.voxel then self.voxel:unregister(entity) end
end

function SpawnLogic:_removeEntity(entity)
  self:_detachFromWorld(entity)
end

function SpawnLogic:_despawn(id, removeEntity)
  local entity = self.entities[id]
  local record = self.spawns[id]
  if record then
    record.state = Config.STATE.REMOVED
  end
  if entity then
    local bx = entity.behaviorState
    if bx then
      bx.state = Behavior.STATE.CLEANUP
      bx.battleStarted = true
    end
    entity.state = Config.STATE.REMOVED
    entity.alertIcon = false
    entity.registeredInWorld = false
    if self.occupancy then
      self.occupancy:releaseEntity(entity)
    end
    if self.voxel then self.voxel:unregister(entity) end
    -- Clear emote if we own it (exactly once).
    local world = self.mod.world
    local ow = world and world.overworld and world:overworld()
    if ow and ow.emote and ow.emote.npc == entity then
      ow.emote = nil
    end
    if removeEntity ~= false then
      self:_removeEntity(entity)
    end
  elseif self.occupancy then
    self.occupancy:releaseEntity(id)
  end
  self.entities[id] = nil
  self.spawns[id] = nil
  if record then
    local list = self.byMap[record.mapId]
    if list then
      for i = #list, 1, -1 do
        if list[i] == id then table.remove(list, i) end
      end
    end
  end
end

function SpawnLogic:countOnMap(mapId)
  local list = self.byMap[mapId]
  return list and #list or 0
end

function SpawnLogic:countVisibleOnMap(mapId)
  local n = 0
  for _, id in ipairs(self.byMap[mapId] or {}) do
    local r = self.spawns[id]
    if r and r.state == Config.STATE.AVAILABLE then
      n = n + 1
    end
  end
  return n
end

function SpawnLogic:countLandOnMap(mapId)
  local n = 0
  for _, id in ipairs(self.byMap[mapId] or {}) do
    local r = self.spawns[id]
    if r and r.state == Config.STATE.AVAILABLE
       and not Behavior.isWater(r.behavior) then
      n = n + 1
    end
  end
  return n
end

function SpawnLogic:countWaterOnMap(mapId)
  local n = 0
  for _, id in ipairs(self.byMap[mapId] or {}) do
    local r = self.spawns[id]
    if r and r.state == Config.STATE.AVAILABLE and Behavior.isWater(r.behavior) then
      n = n + 1
    end
  end
  return n
end

function SpawnLogic:countCaveSceneryOnMap(mapId)
  local n = 0
  for _, id in ipairs(self.byMap[mapId] or {}) do
    local r = self.spawns[id]
    local e = self.entities[id]
    if r and r.state == Config.STATE.AVAILABLE
       and (r.caveScenery == true or (e and e.caveScenery == true)) then
      n = n + 1
    end
  end
  return n
end

function SpawnLogic:countCaveReachableOnMap(mapId)
  local n = 0
  for _, id in ipairs(self.byMap[mapId] or {}) do
    local r = self.spawns[id]
    local e = self.entities[id]
    if r and r.state == Config.STATE.AVAILABLE
       and not Behavior.isWater(r.behavior)
       and r.caveScenery ~= true
       and not (e and e.caveScenery == true) then
      n = n + 1
    end
  end
  return n
end

function SpawnLogic:applyCaveSpawnMode(mode, source)
  mode = mode or Config.caveSpawnMode(self.mod)
  self.caveMode = mode
  self:_log("cave_spawns -> %s via %s", tostring(mode), tostring(source))
  -- Rebuild map eligibility with the new mode (despawn scenery when leaving Mixed).
  if mode ~= "mixed" and self.activeMapId then
    local doomed = {}
    for _, id in ipairs(self.byMap[self.activeMapId] or {}) do
      local r = self.spawns[id]
      local e = self.entities[id]
      if r and (r.caveScenery or (e and e.caveScenery))
         and r.state == Config.STATE.AVAILABLE then
        if not (e and e.state == Config.STATE.ENCOUNTER_STARTING) then
          doomed[#doomed + 1] = id
        end
      end
    end
    for _, id in ipairs(doomed) do
      self:_despawn(id, true)
    end
    self.caveSceneryTarget = 0
    self.caveSceneryCache = {}
  end
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if ow and ow.map and self.state and self.state.initialized then
    self:onMapEntered({ mapId = ow.map.id, map = ow.map })
  end
end

function SpawnLogic:countWaterZone(mapId, zone)
  local n = 0
  for _, id in ipairs(self.byMap[mapId] or {}) do
    local r = self.spawns[id]
    if r and r.state == Config.STATE.AVAILABLE and Behavior.isWater(r.behavior)
       and r.waterZone == zone then
      n = n + 1
    end
  end
  return n
end

function SpawnLogic:_recountWaterZones()
  local mapId = self.activeMapId
  self.waterZoneCounts = { near = 0, mid = 0, deep = 0 }
  if not mapId then return end
  for _, id in ipairs(self.byMap[mapId] or {}) do
    local r = self.spawns[id]
    if r and r.state == Config.STATE.AVAILABLE and Behavior.isWater(r.behavior) then
      local z = r.waterZone
      if z == WaterSpawn.ZONE.NEAR then
        self.waterZoneCounts.near = self.waterZoneCounts.near + 1
      elseif z == WaterSpawn.ZONE.MID then
        self.waterZoneCounts.mid = self.waterZoneCounts.mid + 1
      elseif z == WaterSpawn.ZONE.DEEP then
        self.waterZoneCounts.deep = self.waterZoneCounts.deep + 1
      end
    end
  end
end

function SpawnLogic:_speciesCountsOnMap(mapId, waterOnly)
  local counts = {}
  for _, id in ipairs(self.byMap[mapId] or {}) do
    local r = self.spawns[id]
    if r and r.state == Config.STATE.AVAILABLE then
      if (not waterOnly) or Behavior.isWater(r.behavior) then
        counts[r.species] = (counts[r.species] or 0) + 1
      end
    end
  end
  return counts
end

function SpawnLogic:_noteRecentWaterSpecies(species)
  local list = self.recentWaterSpecies or {}
  list[#list + 1] = species
  while #list > WaterSpawn.ANTI_STREAK_LEN do
    table.remove(list, 1)
  end
  self.recentWaterSpecies = list
end

function SpawnLogic:_entityHasCompatibleWaterSprite(entity)
  if not entity then return false end
  if entity.hasWaterSprite ~= nil then return entity.hasWaterSprite == true end
  local render = self.render
  local reg = render and render.waterSpriteRegistry
  if not (reg and reg:isReady()) then
    entity.hasWaterSprite = false
    return false
  end
  local dexId = entity.enhancedDexId
  if not dexId and entity.species then
    local game = gameOf(self.mod)
    dexId = AnimatedSprites.resolveSpeciesId(entity.species, game, self.mod)
  end
  if not dexId then
    entity.hasWaterSprite = false
    return false
  end
  local has = reg:hasKind(dexId, "swimming", "normal")
           or reg:hasKind(dexId, "levitates", "normal")
  entity.hasWaterSprite = has == true
  return entity.hasWaterSprite
end

function SpawnLogic:_rebuildWaterSpawnData(game, mapId, encDef)
  encDef = encDef or self:_encDef(mapId, game)
  self.waterPool = WaterSpawn.buildPool(game, mapId, encDef)
  self.shoreDistance = WaterSpawn.buildShoreDistance(
    (self.mod.world and self.mod.world.overworld and self.mod.world:overworld()
     and self.mod.world:overworld().map),
    self.waterCache)
  -- Prefer map from overworld when available.
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if ow and ow.map then
    self.shoreDistance = WaterSpawn.buildShoreDistance(ow.map, self.waterCache)
  end
  local hasDeep = self.shoreDistance and self.shoreDistance.hasDeep == true
  self.waterZonePools = WaterSpawn.buildZonePools(self.waterPool, hasDeep)
  self.waterZoneTargets = WaterSpawn.zoneTargets(
    self.targetWaterCount or 0, self.shoreDistance, self.waterZonePools)
  self:_recountWaterZones()
  return self.waterPool
end

function SpawnLogic:_computeWaterTarget(waterCells)
  waterCells = tonumber(waterCells) or 0
  if waterCells <= 0 then return 0 end
  if not Config.waterMons(self.mod) then return 0 end

  -- Conservative base by water surface size (Normal Spawn Amount):
  --   very small (<8): 0–1   small (<20): 1
  --   medium (<50): 1–2      large (<120): 2–4
  --   very large: max 4–6
  local base
  if waterCells < 4 then
    base = 0
  elseif waterCells < 8 then
    base = (waterCells >= 6) and 1 or 0
  elseif waterCells < 20 then
    base = 1
  elseif waterCells < 50 then
    base = 1 + math.floor(waterCells / 40) -- 1–2
  elseif waterCells < 120 then
    base = 2 + math.floor((waterCells - 50) / 35) -- 2–4
  else
    base = 4 + math.floor((waterCells - 120) / 80) -- 4–6+
    if base > 6 then base = 6 end
  end

  local factor = Config.waterDensityFactor(self.mod)
  local raw = math.floor(base * factor + 0.5)

  -- Do NOT force one mon per connected water region (small ponds may stay empty).
  local maxW = Config.maxWaterMons(self.mod)
  if raw > maxW then raw = maxW end
  -- Soft cell density: roughly ≥8 water tiles per mon.
  local cellCap = math.floor(waterCells / 8)
  if raw > cellCap then raw = math.max(0, cellCap) end
  if waterCells >= 8 and raw < 1 and factor >= 1.0 then
    raw = 1
  end
  return raw
end

function SpawnLogic:_attach(entity)
  local world = self.mod.world
  if not world or not world.overworld then return false, "no world" end
  local ow = world:overworld()
  if not ow then return false, "no overworld" end

  -- Hidden markers / unrevealed / spawn-FX-hidden bodies must NEVER join
  -- ow.entities: DramaticShapeVoxelMod poses every entry and crashes on nil.
  local SpawnFxMod = V.require("spawn_fx")
  if entity.hiddenEncounter or entity.visibleSprite == false
     or not SpawnFxMod.bodyVisible(entity) then
    entity.registeredInWorld = false
    entity.registered2D = false
    entity.voxelRegistered = false
    entity.worldRegistration = "logical_only"
    return true
  end

  -- Refuse to register Voxel-unsafe entities into the shared list.
  local okPose, why = VoxelAdapter.isPoseSafe(entity)
  if not okPose then
    return false, "voxel-unsafe entity: " .. tostring(why)
  end

  ow.entities = ow.entities or {}
  -- Stable id: never re-insert under a new identity.
  for _, e in ipairs(ow.entities) do
    if e == entity or (e.id and entity.id and e.id == entity.id) then
      entity.registeredInWorld = true
      entity.registered2D = true
      if self.voxel then self.voxel:updateEntity(entity) end
      return true
    end
  end
  table.insert(ow.entities, entity)
  entity.registeredInWorld = self.render:isEntityRegistered(ow, entity)
  entity.registered2D = entity.registeredInWorld
  if not entity.registeredInWorld then
    return false, "entity not in ow.entities after insert"
  end
  if self.voxel then self.voxel:updateEntity(entity) end
  return true
end

function SpawnLogic:featureActive()
  return Config.isEnabled(self.mod)
end

function SpawnLogic:entityRegisteredInWorld(id)
  local entity = self.entities[id]
  if not entity then return false end
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  return self.render:isEntityRegistered(ow, entity)
end

function SpawnLogic:_logMapDiagnostics(mapId, game, encDef)
  local st = self.state
  self:_log("Entered map %s", tostring(st.mapName or mapId))
  self:_log("Map id=%s type=%s", tostring(mapId), tostring(st.mapType))
  self:_log("Encounter table present=%s source=%s",
            tostring(st.encounterDataAvailable),
            tostring(st.encounterSource or "none"))
  self:_log("Encounter slots: %d", st.encounterEntryCount or 0)
  self:_log("Unique species: %d", st.uniqueSpeciesCount or 0)
  if st.uniqueSpecies and #st.uniqueSpecies > 0 then
    self:_log("Species IDs: %s", table.concat(st.uniqueSpecies, ","))
  end
  local weights = EncounterPick.slotWeights(encDef, "grass")
  for _, w in ipairs(weights) do
    self:_debug("slot species=%s level=%d weight=%d",
                tostring(w.species), w.level or 1, w.weight or 0)
  end
  for _, summary in ipairs(EncounterPick.summarizeAll(encDef)) do
    self:_log("kind=%s slots=%d unique=%d levels=%d-%d rate=%s",
              summary.kind, summary.slots, summary.uniqueSpecies,
              summary.levelMin, summary.levelMax, tostring(summary.rate))
  end
  self:_log("Eligible tiles: %d", st.eligibleTileCount or 0)
  local br = st.tileRejectBreakdown
  self:_log("Tile rejects collision=%d warp=%d npc=%d dist=%d unknown=%d",
            br.collision, br.warp, br.npc, br.player_distance, br.unknown_tile)
  self:_log("Required assets: %d", st.requiredAssets or 0)
  self:_log("Loaded assets: %d", st.loadedAssets or 0)
  self:_log("Renderer: %s", Diagnostics.rendererStatus(self))
  self:_log("Spawn system: %s", Diagnostics.spawnSystemStatus(self))
  self:_log("Pokedex obtained: %s (diag-only, not a gate)",
            tostring(st.pokedexOwnedDiag))
end

-- Full map init in the required order. Vanilla suppression is NOT enabled
-- until this completes with pipelineVerified.
function SpawnLogic:initializeForMap(mapId, game)
  local st = self.state
  st:reset("map:" .. tostring(mapId))
  st.updateCallbackRegistered = true
  st.mapId = mapId
  st.phase = "initializing"

  -- 1) Mod options
  if not self:featureActive() then
    st:markUnsupported("feature disabled")
    st.phase = "idle"
    return false
  end

  game = game or gameOf(self.mod)
  if not game or not game.data then
    st:markError("game data unavailable")
    self:_restoreVanillaEncounters("no game data")
    return false
  end
  st.pokedexOwnedDiag = pokedexOwnedForDiag(game)

  -- 2) Map-ID and map name
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if not ow or not ow.map or not ow.player then
    st:markError("overworld not loaded")
    self:_restoreVanillaEncounters("no overworld")
    return false
  end
  if ow.map.id ~= mapId then
    st:markError("map id mismatch")
    self:_restoreVanillaEncounters("map mismatch")
    return false
  end
  st.mapName = EncounterIndex.mapLabel(game, mapId)
  if ow.map.def and (ow.map.def.label or ow.map.def.name) then
    st.mapName = ow.map.def.label or ow.map.def.name
  end
  st.mapType = EncounterIndex.mapTypeOf(game, mapId)
  st.mapSupported = true

  -- Safari Zone gate: only spawn visible mons during an ACTIVE session with a
  -- verified native Safari encounter path. Otherwise keep Vanilla Safari.
  local safariStatus = SafariCompat.status(game, ow, mapId)
  st.safariCompat = safariStatus
  st.safariActive = safariStatus == SafariCompat.STATUS.ACTIVE
  self.safariStatus = safariStatus
  if safariStatus == SafariCompat.STATUS.FALLBACK_VANILLA then
    st.encounterDataAvailable = true
    st:markUnsupported("Safari compat: FALLBACK_VANILLA")
    self:_log("map %s Safari FALLBACK_VANILLA; visible spawns off, vanilla Safari kept",
              tostring(mapId))
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("safari fallback vanilla")
    return false
  end

  -- 3) Encounter surface + table
  local encDef = self:_encDef(mapId, game)
  local surfaceInfo = Surface.resolve(game, ow.map, encDef)
  self.surfaceInfo = surfaceInfo
  st.surface = surfaceInfo.surface
  st.encounterKind = surfaceInfo.encounterKind

  if not surfaceInfo.supported or not surfaceInfo.encounterKind then
    st.encounterDataAvailable = false
    st.encounterSource = encDef and ("unsupported:" .. tostring(surfaceInfo.reason)) or "none"
    st:markUnsupported(surfaceInfo.reason or "No encounter data available")
    self:_log("map %s unsupported surface (%s); vanilla left intact",
              mapId, tostring(surfaceInfo.reason))
    self:_logMapDiagnostics(mapId, game, encDef)
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("no encounter data")
    return false
  end

  -- Safari Zone without an active paid session: do not alter Vanilla.
  if SafariCompat.isSafariMap(game, mapId, ow)
     and safariStatus ~= SafariCompat.STATUS.ACTIVE then
    st:markUnsupported("Safari session inactive")
    self:_log("map %s Safari map without active session; vanilla left intact",
              tostring(mapId))
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("safari session inactive")
    return false
  end

  -- Water / cave feature toggles (safe defaults on).
  if surfaceInfo.surface == Surface.WATER
     and not Config.waterMons(self.mod) then
    st:markUnsupported("water spawns disabled")
    self:_restoreVanillaEncounters("water spawns disabled")
    return false
  end
  if surfaceInfo.surface == Surface.CAVE
     and not Config.caveSpawnsEnabled(self.mod) then
    st:markUnsupported("cave spawns disabled")
    self:_restoreVanillaEncounters("cave spawns disabled")
    return false
  end

  local kind = surfaceInfo.encounterKind
  st.encounterDataAvailable = true
  st.encounterSource = "game.data.encounters." .. tostring(mapId) .. "." .. kind
  st.encounterEntryCount = EncounterPick.slotCount(encDef, kind)
  local speciesNames = EncounterPick.uniqueSpecies(encDef, kind)
  st.uniqueSpecies = speciesNames
  st.uniqueSpeciesCount = #speciesNames

  -- 4) Eligible tiles by surface (not grass graphics alone)
  self.grassCache = Grass.cells(ow.map)
  self.caveReachability = nil
  if surfaceInfo.tileMode == "grass" then
    self.eligibleCache = self.grassCache
  elseif surfaceInfo.tileMode == "water" then
    self.eligibleCache = Grass.waterCells(ow.map)
  elseif surfaceInfo.tileMode == "walkable" then
    local caveAll = Grass.caveCells(ow.map)
    self.caveReachability = CaveReachability.build(ow.map, ow.player)
    local reachable, unreachable, invalid = CaveReachability.partitionCells(
      caveAll, ow.map, self.caveReachability)
    local status = self.caveReachability.status
    self.caveSceneryCache = {}
    self.caveMode = Config.caveSpawnMode(self.mod)
    if status == "READY" or (status == "FALLBACK" and #reachable > 0) then
      self.eligibleCache = reachable
      if self.caveMode == "mixed" then
        self.caveSceneryCache = unreachable
      end
      self:_log("cave reachability %s mode=%s reachable=%d scenery=%d invalid=%d",
                tostring(status), tostring(self.caveMode),
                #reachable, #unreachable, invalid)
    elseif status == "FAILED" then
      -- Conservative fallback: nearby passable cells only — never unfiltered cave.
      local near = CaveReachability.conservativeNearPlayer(ow.map, ow.player, 5)
      if #near > 0 then
        self.caveReachability.status = "FALLBACK"
        self.caveReachability.reason = self.caveReachability.reason
          or "nearby player cells"
        self.eligibleCache = near
        self.caveSceneryCache = {}
        self:_log("cave reachability FAILED → nearby fallback cells=%d", #near)
      else
        self.eligibleCache = {}
        self.caveSceneryCache = {}
        self:_log("cave reachability FAILED → no visible cave spawns")
      end
    else
      self.eligibleCache = reachable
      if self.caveMode == "mixed" then
        self.caveSceneryCache = unreachable
      end
    end
  else
    self.eligibleCache = {}
    self.caveSceneryCache = nil
  end
  st.eligibleTileCount = #self.eligibleCache
  if #self.eligibleCache == 0 then
    st.eligibleTilesAvailable = false
    st:markUnsupported("no eligible encounter tiles")
    self:_logMapDiagnostics(mapId, game, encDef)
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("no eligible tiles")
    return false
  end

  -- 5) Connected spawn regions + density target
  self.regions = SpawnRegions.build(self.eligibleCache)
  self.caveSceneryRegions = nil
  if self.caveSceneryCache and #self.caveSceneryCache > 0 then
    self.caveSceneryRegions = SpawnRegions.build(self.caveSceneryCache)
  end
  st.spawnRegionCount = #self.regions
  local mapSpan = math.max(ow.map.widthCells or 0, ow.map.heightCells or 0)
  self.targetSpawnCount = SpawnRegions.targetCount({
    eligibleTiles = #self.eligibleCache,
    minVisible = Config.minVisible(self.mod),
    maxVisible = Config.maxVisible(self.mod),
    tilesPerAdditional = Config.tilesPerAdditional(self.mod),
    density = Config.spawnDensity(self.mod),
    mapSpan = mapSpan,
  })
  st.targetSpawnCount = self.targetSpawnCount

  -- Water layer: primary water maps + secondary water on grass/cave maps.
  self.waterCache = Grass.waterCells(ow.map)
  self.waterRegions = {}
  self.targetWaterCount = 0
  self.waterPool = nil
  self.waterZonePools = nil
  self.shoreDistance = nil
  self.waterZoneTargets = nil
  self.recentWaterSpecies = {}
  local waterPoolPreview = WaterSpawn.buildPool(game, mapId, encDef)
  local hasWaterPool = WaterSpawn.hasPool(waterPoolPreview)
  if surfaceInfo.surface == Surface.WATER then
    -- Primary water map: sparse water density; gated by Water Mons.
    if Config.waterMons(self.mod) then
      self.waterCache = self.eligibleCache
      self.targetWaterCount = self:_computeWaterTarget(#self.waterCache)
      self.targetSpawnCount = self.targetWaterCount
      st.targetSpawnCount = self.targetSpawnCount
      if #self.waterCache > 0 then
        self.waterRegions = SpawnRegions.build(self.waterCache)
      end
      self:_rebuildWaterSpawnData(game, mapId, encDef)
    else
      self.targetSpawnCount = 0
      st.targetSpawnCount = 0
      self.targetWaterCount = 0
    end
  elseif Config.waterMons(self.mod) and hasWaterPool and #(self.waterCache) > 0 then
    self.targetWaterCount = self:_computeWaterTarget(#self.waterCache)
    if #self.waterCache > 0 then
      self.waterRegions = SpawnRegions.build(self.waterCache)
    end
    self:_rebuildWaterSpawnData(game, mapId, encDef)
  end

  self.regionQuotas, st.allocatedSpawns = SpawnRegions.allocate(
    self.regions, self.targetSpawnCount)
  self.regionCounts = {}
  for _, region in ipairs(self.regions) do
    self.regionCounts[region.id] = 0
  end

  -- Cave Mixed quota: ~80% reachable / ~20% scenery (unreachable valid).
  self.caveReachableTarget = self.targetSpawnCount
  self.caveSceneryTarget = 0
  if surfaceInfo.tileMode == "walkable" and self.caveMode == "mixed" then
    local rTarget, sTarget = CaveReachability.mixedTargets(self.targetSpawnCount)
    if not self.caveSceneryCache or #self.caveSceneryCache == 0 then
      sTarget = 0
      rTarget = self.targetSpawnCount
    end
    -- Never exceed available reachable tiles; reduce total rather than raise scenery.
    if rTarget > #self.eligibleCache then
      rTarget = #self.eligibleCache
    end
    if sTarget > #(self.caveSceneryCache or {}) then
      sTarget = #(self.caveSceneryCache or {})
    end
    self.caveReachableTarget = rTarget
    self.caveSceneryTarget = sTarget
    self.targetSpawnCount = rTarget + sTarget
    st.targetSpawnCount = self.targetSpawnCount
    self:_log("cave mixed targets reachable=%d scenery=%d (tiles r/s=%d/%d)",
              rTarget, sTarget, #self.eligibleCache, #(self.caveSceneryCache or {}))
  end

  self:_log("surface=%s tiles=%d regions=%d target=%d waterTarget=%d density=%s randomEnc=%s water=%s",
            tostring(surfaceInfo.surface), #self.eligibleCache,
            #self.regions, self.targetSpawnCount,
            self.targetWaterCount,
            tostring(Config.spawnDensity(self.mod)),
            tostring(Config.randomEncountersEnabled(self.mod)),
            tostring(Config.waterDisplayMode(self.mod)))
  if Config.devMode(self.mod) then
    self:_log("Random Enc: %s",
              tostring(Config.randomEncountersEnabled(self.mod)))
    self:_log("Water Mons: %s cells=%d target=%d",
              tostring(Config.waterDisplayMode(self.mod)),
              #(self.waterCache or {}), self.targetWaterCount or 0)
    if self.shoreDistance then
      local s = WaterSpawn.summarize(
        self.waterPool, self.shoreDistance, self.waterZonePools, self.waterZoneTargets)
      self:_log(
        "Water zones near/mid/deep=%d/%d/%d pools=%d/%d/%d surf/old/good/super=%d/%d/%d/%d",
        s.nearShore, s.midWater, s.deepWater,
        s.nearPool, s.midPool, s.deepPool,
        s.surfSpecies, s.oldRodSpecies, s.goodRodSpecies, s.superRodSpecies)
    end
  end

  local minDist = Config.DEFAULTS.min_player_distance
  local maxDist = Config.DEFAULTS.max_player_distance
  local probeX, probeY, probeReason = Grass.pickFree(
    ow.map, ow.entities, ow.player, minDist, nil, self.eligibleCache, maxDist,
    function(reason) st:noteReject(reason) end,
    { mode = surfaceInfo.tileMode })
  if not probeX then
    st.eligibleTilesAvailable = false
    st:markUnsupported(probeReason or "no eligible tiles")
    self:_log("no eligible spawn tiles on %s (%s); vanilla left intact",
              mapId, tostring(probeReason))
    self:_logMapDiagnostics(mapId, game, encDef)
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("no eligible tiles")
    return false
  end
  st.eligibleTilesAvailable = true

  -- 6/7) Required assets + load/validate (real or fallback both count)
  st.assetsLoading = true
  if Config.devMode(self.mod) then
    self.render.debugMarkers = true
    self.render:auditAssets(game)
  end
  local required, loaded = self.render:countAssets(speciesNames, game)
  st.requiredAssets = required
  st.loadedAssets = loaded
  st.assetsLoading = false
  if required > 0 and loaded == 0 then
    st.assetError = nil
    self:_log("no real overworld assets loaded; fallback path active")
  end

  -- 8) Renderer capability
  local renderOk, renderInfo = self.render:checkAvailable(game)
  st.rendererAvailable = renderOk == true
  if not renderOk then
    st:markError(renderInfo or "renderer unavailable")
    self:_logMapDiagnostics(mapId, game, encDef)
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("renderer unavailable")
    return false
  end

  st.updateCallbackRegistered = true
  if self.hud then self.hud:markMapEnter() end
  if self.overlay then self.overlay:rebuild() end
  if self.behaviorTick then self.behaviorTick:syncPipelineLevel() end

  -- 11) Spawn toward density target (initial wave is a lower bound)
  st.phase = "spawning"
  local spawned = 0
  local waterSpawned = 0

  if surfaceInfo.surface == Surface.WATER then
    -- Primary water maps use trySpawnWater only (never land trySpawn refill).
    if (self.targetWaterCount or 0) > 0 and Config.waterMons(self.mod) then
      for _ = 1, self.targetWaterCount do
        local record, err = self:trySpawnWater(game, {})
        if record then
          waterSpawned = waterSpawned + 1
          spawned = spawned + 1
        else
          self:_log("water spawn rejected: %s", tostring(err))
          break
        end
      end
    end
  else
    local want = math.max(
      Config.get(self.mod, "initial_spawns") or 1,
      math.min(self.targetSpawnCount, 3))
    if Config.get(self.mod, "force_test_spawn") then
      want = math.max(want, 1)
    end
    want = math.min(want, self.targetSpawnCount)
    for _ = 1, want do
      local record, err = self:trySpawn(game, { force = Config.get(self.mod, "force_test_spawn") })
      if record then
        spawned = spawned + 1
      else
        self:_log("spawn attempt rejected: %s", tostring(err))
        break
      end
    end

    -- Secondary water wave on grass/cave maps with water tables.
    if (self.targetWaterCount or 0) > 0 and Config.waterMons(self.mod) then
      for _ = 1, self.targetWaterCount do
        local record, err = self:trySpawnWater(game, {})
        if record then
          waterSpawned = waterSpawned + 1
        else
          self:_log("water spawn rejected: %s", tostring(err))
          break
        end
      end
    end
  end

  if spawned < 1 and waterSpawned < 1 then
    -- Water maps: allow READY with zero visible mons (Water Mons OFF or tiny pond).
    -- Classic surf / fishing encounters stay unchanged either way.
    if surfaceInfo.surface == Surface.WATER then
      self:_log("water map ready with %d visible water mons (Water Mons=%s target=%d)",
                waterSpawned, tostring(Config.waterDisplayMode(self.mod)),
                self.targetWaterCount or 0)
    else
      local record, err = self:trySpawn(game, { force = true, readinessProbe = true })
      if record then
        spawned = 1
        self:_log("readiness probe spawn ok: %s Lv%d", record.species, record.level)
      else
        st:markError(err or "first spawn failed")
        self:_logMapDiagnostics(mapId, game, encDef)
        self:_restoreVanillaEncounters("first spawn failed")
        return false
      end
    end
  end

  st.pipelineVerified = true
  st.initialized = true
  st.fallbackToVanilla = false
  st.phase = "idle"
  st:clearError()
  self:_logMapDiagnostics(mapId, game, encDef)
  self:_log("Spawn system: READY target=%d active=%d water=%d",
            self.targetSpawnCount, self:countVisibleOnMap(mapId),
            waterSpawned)
  return true
end

function SpawnLogic:trySpawn(game, opts)
  opts = opts or {}
  if not self:featureActive() then
    return nil, "feature disabled"
  end

  if self.render and self.render.ensureStyleOwnedMakeEntity then
    pcall(function() self.render:ensureStyleOwnedMakeEntity(game) end)
  end

  local st = self.state
  if st.lastError and not opts.force and not opts.testSpawn then
    return nil, "paused after error: " .. tostring(st.lastError)
  end

  local world = self.mod.world
  if not world or not world.overworld then
    return nil, "no world"
  end
  local ow = world:overworld()
  if not ow or not ow.map or not ow.player then
    return nil, "no overworld"
  end

  local mapId = ow.map.id
  local encDef = self:_encDef(mapId, game)
  local surfaceInfo = self.surfaceInfo or Surface.resolve(game, ow.map, encDef)
  local encounterKind = surfaceInfo.encounterKind or "grass"
  local tileMode = surfaceInfo.tileMode or "grass"

  -- Primary water maps must use trySpawnWater (Water Mons gated).
  if not opts.testSpawn and not opts.readinessProbe
     and surfaceInfo.surface == Surface.WATER then
    return nil, "use trySpawnWater for water maps"
  end

  if not opts.testSpawn then
    if encounterKind == "grass" and not EncounterPick.hasGrassTable(encDef) then
      st:noteReject("rejected: no encounter data")
      return nil, "rejected: no encounter data"
    end
    if encounterKind == "water" and not EncounterPick.kindTable(encDef, "water") then
      st:noteReject("rejected: no encounter data")
      return nil, "rejected: no encounter data"
    end
  end

  local maxSpawns = Config.maxVisible(self.mod)
  local target = self.targetSpawnCount or maxSpawns
  if not opts.force and not opts.testSpawn
     and self:countLandOnMap(mapId) >= target then
    return nil, "target spawn count reached"
  end
  if self:countLandOnMap(mapId) >= maxSpawns then
    return nil, "max spawns reached"
  end

  local region = opts.region
  if not region and not opts.allowOutside and not (opts.x and opts.y) then
    region = self:_pickUnderfilledRegion()
  end

  -- Cave Mixed: choose scenery vs reachable pool by remaining quota.
  local scenerySpawn = opts.scenery == true
  if not opts.scenery and not opts.x and tileMode == "walkable"
     and self.caveMode == "mixed"
     and (self.caveSceneryTarget or 0) > 0
     and self.caveSceneryCache and #self.caveSceneryCache > 0 then
    local sceneryCount = self:countCaveSceneryOnMap(mapId)
    local reachCount = self:countCaveReachableOnMap(mapId)
    if sceneryCount < (self.caveSceneryTarget or 0)
       and reachCount >= (self.caveReachableTarget or 0) then
      scenerySpawn = true
    elseif sceneryCount < (self.caveSceneryTarget or 0)
       and math.random() < 0.25
       and reachCount + 1 >= (self.caveReachableTarget or 0) then
      -- Prefer filling reachable first; occasional scenery while both open.
      scenerySpawn = true
    end
  end

  local tileList = self.eligibleCache
  if scenerySpawn then
    tileList = self.caveSceneryCache
    region = nil
  elseif region and region.tiles then
    tileList = region.tiles
  elseif not tileList or #tileList == 0 then
    if tileMode == "water" then
      tileList = Grass.waterCells(ow.map)
    elseif tileMode == "walkable" then
      -- Never reload unfiltered cave cells; rebuild from reachability.
      if self.caveReachability and self.caveReachability.status ~= "FAILED" then
        tileList = {}
        for _, c in ipairs(Grass.caveCells(ow.map)) do
          if CaveReachability.isReachable(self.caveReachability, c.x, c.y) then
            tileList[#tileList + 1] = c
          end
        end
      else
        tileList = {}
      end
    else
      tileList = Grass.cells(ow.map)
      self.grassCache = tileList
    end
    if not scenerySpawn then
      self.eligibleCache = tileList
    end
  end

  local occupancy = self:rebuildOccupancy(ow)

  local x, y, reason
  if opts.x and opts.y then
    x, y = opts.x, opts.y
    if occupancy:isOccupied(x, y) or occupancy:isReserved(x, y) then
      st:noteReject("rejected: occupied by NPC")
      return nil, "rejected: occupied by NPC"
    end
  elseif opts.allowOutside then
    x, y, reason = Grass.pickFreeWalkable(
      ow.map, ow.entities, ow.player,
      opts.force and 1 or Config.DEFAULTS.min_player_distance,
      nil, Config.DEFAULTS.max_player_distance,
      function(r) st:noteReject(r) end)
  else
    if #tileList == 0 then
      st:noteReject("rejected: not encounter tile")
      return nil, "rejected: not encounter tile"
    end
    local minDist = opts.force and 1 or Config.DEFAULTS.min_player_distance
    local maxDist = Config.DEFAULTS.max_player_distance
    local membership = region and region.membership or nil
    x, y, reason = Grass.pickFree(
      ow.map, ow.entities, ow.player, minDist, nil, tileList, maxDist,
      function(r) st:noteReject(r) end,
      {
        mode = tileMode,
        membership = membership,
        occupiedSpawns = self:_occupiedSpawnCoords(mapId),
        minSeparation = SpawnRegions.minSeparation(),
        preferFar = not opts.force,
        occupancy = occupancy,
      })
  end
  if not x then
    return nil, reason or "rejected: no eligible tiles"
  end
  if tileMode == "walkable" and self.caveReachability then
    local cls = CaveReachability.classifyCell(ow.map, self.caveReachability, x, y)
    if cls == CaveReachability.CLASS.INVALID then
      return nil, "rejected: invalid cave tile"
    end
    if scenerySpawn and cls ~= CaveReachability.CLASS.UNREACHABLE_VALID then
      scenerySpawn = false
    elseif (not scenerySpawn) and cls == CaveReachability.CLASS.UNREACHABLE_VALID
           and self.caveMode ~= "mixed" then
      return nil, "rejected: unreachable cave tile"
    elseif (not scenerySpawn) and cls == CaveReachability.CLASS.UNREACHABLE_VALID
           and self.caveMode == "mixed" then
      scenerySpawn = true
    end
  end

  -- Atomic spawn reservation before species/entity creation.
  local spawnToken, reserveErr = occupancy:reserveSpawn(nil, x, y)
  if not spawnToken then
    st:noteReject("rejected: occupied by NPC")
    return nil, reserveErr or "rejected: occupied by NPC"
  end

  if not region then
    region = SpawnRegions.regionForCell(self.regions, x, y)
  end

  local species, level
  if opts.species then
    species = opts.species
    level = opts.level or 5
  else
    local pick = EncounterPick.pick(encDef, nil, encounterKind)
    if not pick then
      occupancy:releaseSpawn(spawnToken)
      st:noteReject("rejected: no encounter data")
      return nil, "rejected: no encounter data"
    end
    species, level = pick.species, pick.level
  end

  local behavior = opts.behavior
  if not behavior then
    local safariActive = self:_safariActive(game, ow, mapId)
    if opts.readinessProbe or opts.force then
      behavior = safariActive and Behavior.SAFARI_IDLE or Behavior.IDLE_LOOK
    else
      -- Mixed scenery: atmosphere only — never AGGRESSIVE / Hidden.
      behavior = Behavior.pick(species, surfaceInfo.surface, {
        safari = safariActive,
        enable_idle = Config.get(self.mod, "enable_idle") ~= false,
        enable_wander = Config.get(self.mod, "enable_wander") ~= false,
        enable_aggressive = (not scenerySpawn) and (not safariActive)
          and Config.get(self.mod, "enable_aggressive") ~= false,
        enable_hidden = (not scenerySpawn) and (not safariActive)
          and Config.get(self.mod, "enable_hidden") ~= false,
        enable_safari_flee = safariActive,
        aggressive_frequency = Config.get(self.mod, "aggressive_frequency") or 1,
        hiddenCaveAvailable = (not scenerySpawn) and not safariActive,
      })
    end
  end
  if scenerySpawn then
    if Behavior.isHidden(behavior) or behavior == Behavior.AGGRESSIVE then
      behavior = (math.random() < 0.55) and Behavior.IDLE_LOOK or Behavior.GRASS_WANDER
    end
  end

  self:_debug("Selected species=%s level=%d behavior=%s",
              tostring(species), level or 1, tostring(behavior))
  self:_debug("Selected tile x=%d y=%d region=%s", x, y,
              tostring(region and region.id))

  local seq = self.nextId
  self.nextId = self.nextId + 1
  -- Stable for the entity's full lifetime (idle→alert→chase→battle→cleanup).
  local id = string.format("wilds_of_kanto_entity_%d", seq)

  local hidden = Behavior.isHidden(behavior)
  local record = {
    id = id,
    mapId = mapId,
    x = x,
    y = y,
    species = species,
    level = level,
    state = Config.STATE.AVAILABLE,
    testSpawn = opts.testSpawn == true,
    behavior = behavior,
    surface = surfaceInfo.surface,
    encounterKind = encounterKind,
    homeRegionId = region and region.id or nil,
    visibleSprite = not hidden,
    hiddenEncounter = hidden,
  }

  local ok, entityOrErr = pcall(self.render.makeEntity, self.render, game, record)
  if not ok then
    occupancy:releaseSpawn(spawnToken)
    local phase = "ENTITY CREATE ERROR"
    local msg = tostring(entityOrErr)
    if msg:find("ASSET LOAD", 1, true) then phase = "ASSET LOAD ERROR"
    elseif msg:find("INVALID POSITION", 1, true) then phase = "INVALID POSITION"
    elseif msg:find("SpriteRenderer", 1, true) then phase = "ENTITY CREATE ERROR"
    end
    self:_warn("%s for %s: %s", phase, tostring(species), msg)
    DebugLog.error(self.mod, "%s: %s", phase, msg)
    st:markError(phase .. ": " .. msg)
    st.lastSpawnError = phase .. ": " .. msg
    if not opts.testSpawn then
      self:_restoreVanillaEncounters("entity creation failed")
    end
    return nil, phase .. ": " .. msg
  end
  local entity = entityOrErr
  if not entity then
    occupancy:releaseSpawn(spawnToken)
    st:markError("ENTITY CREATE ERROR: makeEntity returned nil")
    st.lastSpawnError = "ENTITY CREATE ERROR: makeEntity returned nil"
    if not opts.testSpawn then
      self:_restoreVanillaEncounters("entity creation nil")
    end
    return nil, "ENTITY CREATE ERROR: makeEntity returned nil"
  end
  self:_debug("Entity created id=%s fallback=%s phase=%s",
              id, tostring(entity.usingFallback), tostring(entity.entityPhase))

  Behavior.attach(entity, behavior, region)
  entity.surface = surfaceInfo.surface
  entity.originSurface = surfaceInfo.surface
  entity.waterEnteredByChase = false
  entity.hasWaterSprite = self:_entityHasCompatibleWaterSprite(entity)
  entity.encounterKind = encounterKind
  record.facing = entity.facing
  record.originSurface = surfaceInfo.surface

  if tileMode == "walkable" and self.caveReachability then
    if scenerySpawn then
      entity.caveReachClass = CaveReachability.CLASS.UNREACHABLE_VALID
      entity.caveScenery = true
      entity.caveHomeCells = CaveReachability.componentCells(
        self.caveReachability, x, y)
      entity.canTriggerBattle = false
      record.caveReachClass = entity.caveReachClass
      record.caveScenery = true
    else
      entity.caveReachClass = CaveReachability.CLASS.REACHABLE
      entity.caveScenery = false
      entity.caveHomeCells = self.caveReachability.reachable
      record.caveReachClass = entity.caveReachClass
    end
  end

  -- Visible grass/land spawn pop (not readiness probe).
  -- Begin FX before world attach so pose-nil entities stay logical-only.
  if not opts.readinessProbe and not Behavior.isHidden(behavior)
     and surfaceInfo.surface == Surface.GRASS then
    SpawnFx.begin(entity, SpawnFx.KIND.GRASS)
    entity.canTriggerBattle = false
  elseif not opts.readinessProbe and Behavior.isWater(behavior) then
    SpawnFx.begin(entity, SpawnFx.KIND.WATER)
    entity.canTriggerBattle = false
  end

  local attached, attachErr = self:_attach(entity)
  if not attached then
    occupancy:releaseSpawn(spawnToken)
    self:_warn("WORLD REGISTER ERROR: %s", tostring(attachErr))
    DebugLog.error(self.mod, "WORLD REGISTER ERROR: %s", tostring(attachErr))
    st:markError("WORLD REGISTER ERROR: " .. tostring(attachErr))
    st.lastSpawnError = "WORLD REGISTER ERROR: " .. tostring(attachErr)
    if not opts.testSpawn then
      self:_restoreVanillaEncounters("render registration failed")
    end
    return nil, "WORLD REGISTER ERROR: " .. tostring(attachErr)
  end
  if entity then entity.entityPhase = entity.usingFallback
      and "FALLBACK LOADED" or "ENTITY REGISTERED" end
  self:_debug("Entity registered")
  self:_debug("Renderer registered")

  occupancy:commitSpawn(spawnToken, entity)
  self:refreshEntitySprite(entity, {
    reason = "spawn",
    surface = entity.surface,
    game = game,
  })

  self.spawns[id] = record
  self.entities[id] = entity
  self.byMap[mapId] = self.byMap[mapId] or {}
  self.byMap[mapId][#self.byMap[mapId] + 1] = id
  self:_recountRegions()
  self:_validateNoCellOverlap(ow)

  if not opts.readinessProbe then
    self.mod.log:info("spawned wild %s Lv%d %s at %s (%d,%d)",
                      species, level, tostring(behavior), mapId, x, y)
  end
  return record, nil, entity
end

function SpawnLogic:trySpawnWater(game, opts)
  opts = opts or {}
  if not self:featureActive() then
    return nil, "feature disabled"
  end
  if not Config.waterMons(self.mod) then
    return nil, "water mons disabled"
  end

  if self.render and self.render.ensureStyleOwnedMakeEntity then
    pcall(function() self.render:ensureStyleOwnedMakeEntity(game) end)
  end

  local world = self.mod.world
  if not world or not world.overworld then
    return nil, "no world"
  end
  local ow = world:overworld()
  if not ow or not ow.map or not ow.player then
    return nil, "no overworld"
  end

  local mapId = ow.map.id
  local encDef = self:_encDef(mapId, game)

  if not self.waterPool or not WaterSpawn.hasPool(self.waterPool) then
    self:_rebuildWaterSpawnData(game, mapId, encDef)
  end
  if not WaterSpawn.hasPool(self.waterPool) then
    return nil, "rejected: no water encounter data"
  end

  local target = self.targetWaterCount or 0
  if not opts.force and self:countWaterOnMap(mapId) >= target then
    return nil, "water target reached"
  end

  self.waterCache = self.waterCache or Grass.waterCells(ow.map)
  if #(self.waterCache) == 0 then
    return nil, "rejected: no water tiles"
  end

  if not self.shoreDistance then
    self.shoreDistance = WaterSpawn.buildShoreDistance(ow.map, self.waterCache)
    self.waterZonePools = WaterSpawn.buildZonePools(
      self.waterPool, self.shoreDistance.hasDeep)
    self.waterZoneTargets = WaterSpawn.zoneTargets(
      target, self.shoreDistance, self.waterZonePools)
  end

  self:_recountWaterZones()
  local zone, zoneCells = WaterSpawn.pickSpawnZone(
    self.waterZoneCounts, self.waterZoneTargets, self.shoreDistance)
  if not zone or not zoneCells or #zoneCells == 0 then
    -- Soft fallback: any water cell.
    zoneCells = self.waterCache
    if self.shoreDistance then
      local sample = zoneCells[1]
      if sample then
        local d = WaterSpawn.distanceAt(self.shoreDistance, sample.x, sample.y)
        zone = WaterSpawn.zoneForDistance(d or 0) or WaterSpawn.ZONE.MID
      else
        zone = WaterSpawn.ZONE.MID
      end
    else
      zone = WaterSpawn.ZONE.MID
    end
  end

  local occupancy = self:rebuildOccupancy(ow)
  local minWaterSep = Config.waterMinSpacing(self.mod)

  local x, y, reason = Grass.pickFree(
    ow.map, ow.entities, ow.player,
    Config.DEFAULTS.min_player_distance, nil, zoneCells,
    Config.DEFAULTS.max_player_distance,
    function(r) self.state:noteReject(r) end,
    {
      mode = "water",
      occupiedSpawns = self:_occupiedSpawnCoords(mapId),
      minSeparation = minWaterSep,
      strictSeparation = true,
      separationMetric = "manhattan",
      preferFar = true,
      occupancy = occupancy,
    })
  if not x then
    -- Retry against full water cache once (still with strict spacing).
    x, y, reason = Grass.pickFree(
      ow.map, ow.entities, ow.player,
      Config.DEFAULTS.min_player_distance, nil, self.waterCache,
      Config.DEFAULTS.max_player_distance,
      function(r) self.state:noteReject(r) end,
      {
        mode = "water",
        occupiedSpawns = self:_occupiedSpawnCoords(mapId),
        minSeparation = minWaterSep,
        strictSeparation = true,
        separationMetric = "manhattan",
        preferFar = true,
        occupancy = occupancy,
      })
    if not x then
      -- No spaced cell → reduce target rather than ignore spacing.
      local have = self:countWaterOnMap(mapId)
      if (self.targetWaterCount or 0) > have then
        self.targetWaterCount = have
        self:_log("water spacing: reduced target to %d (no spaced cell)", have)
      end
      return nil, reason or "rejected: water spacing"
    end
    local d = WaterSpawn.distanceAt(self.shoreDistance, x, y)
    zone = WaterSpawn.zoneForDistance(d or 0) or zone
  else
    local d = WaterSpawn.distanceAt(self.shoreDistance, x, y)
    if d ~= nil then
      zone = WaterSpawn.zoneForDistance(d) or zone
    end
  end

  local spawnToken, reserveErr = occupancy:reserveSpawn(nil, x, y)
  if not spawnToken then
    return nil, reserveErr or "rejected: occupied by NPC"
  end

  local maxSame = WaterSpawn.maxSameSpecies(target)
  local pick = WaterSpawn.pickForZone(self.waterZonePools, zone, {
    recentSpecies = self.recentWaterSpecies,
    speciesCounts = self:_speciesCountsOnMap(mapId, true),
    maxSameSpecies = maxSame,
    fallbackEntries = self.waterPool and self.waterPool.entries,
  })
  if not pick then
    -- Fallback: any zone pool that is non-empty.
    for _, z in ipairs({ WaterSpawn.ZONE.MID, WaterSpawn.ZONE.NEAR, WaterSpawn.ZONE.DEEP }) do
      pick = WaterSpawn.pickForZone(self.waterZonePools, z, {
        recentSpecies = self.recentWaterSpecies,
        speciesCounts = self:_speciesCountsOnMap(mapId, true),
        maxSameSpecies = maxSame,
        fallbackEntries = self.waterPool and self.waterPool.entries,
      })
      if pick then
        zone = z
        break
      end
    end
  end
  if not pick then
    occupancy:releaseSpawn(spawnToken)
    return nil, "rejected: no encounter data"
  end

  local species, level = pick.species, pick.level
  local region = SpawnRegions.regionForCell(self.waterRegions, x, y)
  local waterAggChance = Config.get(self.mod, "water_aggressive_chance")
                      or Config.DEFAULTS.water_aggressive_chance or 0.15
  local safariActive = self:_safariActive(game, ow, mapId)
  local behavior = Behavior.pick(species, Surface.WATER, {
    safari = safariActive,
    enable_idle = true,
    enable_wander = true,
    -- Water Safari: never WATER_AGGRESSIVE; land Safari flee not used on water.
    enable_aggressive = (not safariActive)
      and Config.get(self.mod, "enable_aggressive") ~= false,
    enable_water_aggressive = (not safariActive)
      and Config.get(self.mod, "enable_aggressive") ~= false,
    enable_hidden = false,
    water_aggressive_chance = safariActive and 0 or waterAggChance,
    aggressive_frequency = Config.get(self.mod, "aggressive_frequency") or 1,
  })
  if not Behavior.isWater(behavior) then
    behavior = (math.random() < 0.45) and Behavior.WATER_IDLE or Behavior.WATER_WANDER
  end
  if safariActive and behavior == Behavior.WATER_AGGRESSIVE then
    behavior = (math.random() < 0.45) and Behavior.WATER_IDLE or Behavior.WATER_WANDER
  end

  local seq = self.nextId
  self.nextId = self.nextId + 1
  local id = string.format("wilds_of_kanto_entity_%d", seq)

  local shoreDist = WaterSpawn.distanceAt(self.shoreDistance, x, y)
  local record = {
    id = id,
    mapId = mapId,
    x = x, y = y,
    species = species,
    level = level,
    state = Config.STATE.AVAILABLE,
    behavior = behavior,
    surface = Surface.WATER,
    encounterKind = pick.source or "water",
    encounterSource = pick.encounterSource or "SURF",
    rodTier = pick.rodTier,
    waterZone = zone,
    shoreDistance = shoreDist,
    spawnRule = pick.spawnRule,
    homeRegionId = region and region.id or nil,
    visibleSprite = true,
    hiddenEncounter = false,
    canTriggerBattle = false,
    originSurface = Surface.WATER,
  }

  local ok, entityOrErr = pcall(self.render.makeEntity, self.render, game, record)
  if not ok or not entityOrErr then
    occupancy:releaseSpawn(spawnToken)
    return nil, "ENTITY CREATE ERROR: " .. tostring(entityOrErr or "nil")
  end
  local entity = entityOrErr

  Behavior.attach(entity, behavior, region)
  entity.surface = Surface.WATER
  entity.spriteState = "water"
  entity.encounterKind = record.encounterKind
  entity.encounterSource = record.encounterSource
  entity.rodTier = record.rodTier
  entity.waterZone = zone
  entity.shoreDistance = shoreDist
  entity.spawnRule = record.spawnRule
  entity.originSurface = Surface.WATER
  entity.waterEnteredByChase = false
  entity.surfaceVisualOffset = 2
  entity.waterSink = 2
  entity.hasWaterSprite = self:_entityHasCompatibleWaterSprite(entity)
  SpawnFx.begin(entity, SpawnFx.KIND.WATER)
  entity.canTriggerBattle = true
  record.facing = entity.facing
  record.canTriggerBattle = true

  local attached, attachErr = self:_attach(entity)
  if not attached then
    occupancy:releaseSpawn(spawnToken)
    return nil, "WORLD REGISTER ERROR: " .. tostring(attachErr)
  end

  occupancy:commitSpawn(spawnToken, entity)
  self:refreshEntitySprite(entity, {
    reason = "spawn",
    surface = Surface.WATER,
    spriteState = "water",
    game = game,
  })

  self.spawns[id] = record
  self.entities[id] = entity
  self.byMap[mapId] = self.byMap[mapId] or {}
  self.byMap[mapId][#self.byMap[mapId] + 1] = id
  self:_noteRecentWaterSpecies(species)
  self:_recountWaterZones()
  self:_validateNoCellOverlap(ow)

  self.mod.log:info(
    "spawned water %s Lv%d %s zone=%s src=%s at %s (%d,%d)",
    species, level, tostring(behavior), tostring(zone),
    tostring(record.encounterSource), mapId, x, y)
  return record, nil, entity
end

function SpawnLogic:_trimVisibleToTarget()
  local mapId = self.activeMapId
  if not mapId then return 0 end
  local target = self.targetSpawnCount or 0
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  local player = ow and ow.player
  local candidates = {}
  for _, id in ipairs(self.byMap[mapId] or {}) do
    local r = self.spawns[id]
    local e = self.entities[id]
    if r and r.state == Config.STATE.AVAILABLE then
      if e and e.behaviorState and e.behaviorState.chasing then
        -- keep chasing
      else
        local d = 0
        if player then
          d = Grass.chebyshev(r.x, r.y, player.cellX, player.cellY)
        end
        candidates[#candidates + 1] = { id = id, d = d }
      end
    end
  end
  table.sort(candidates, function(a, b) return a.d > b.d end)
  local removed = 0
  local visible = self:countVisibleOnMap(mapId)
  for _, c in ipairs(candidates) do
    if visible - removed <= target then break end
    self:_despawn(c.id, true)
    removed = removed + 1
  end
  if removed > 0 then self:_recountRegions() end
  return removed
end

function SpawnLogic:applySpawnAmount(value, source)
  if not self.activeMapId or not self.state.initialized then
    self:_log("spawn_density -> %s via %s (deferred until map ready)",
              tostring(value), tostring(source))
    return
  end
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if not (ow and ow.map) then return end
  local mapSpan = math.max(ow.map.widthCells or 0, ow.map.heightCells or 0)
  self.targetSpawnCount = SpawnRegions.targetCount({
    eligibleTiles = #(self.eligibleCache or {}),
    minVisible = Config.minVisible(self.mod),
    maxVisible = Config.maxVisible(self.mod),
    tilesPerAdditional = Config.tilesPerAdditional(self.mod),
    density = value or Config.spawnDensity(self.mod),
    mapSpan = mapSpan,
  })
  self.regionQuotas = select(1, SpawnRegions.allocate(
    self.regions, self.targetSpawnCount))
  self.state.targetSpawnCount = self.targetSpawnCount
  self:_trimVisibleToTarget()
  local game = gameOf(self.mod)
  if game then
    -- Controlled refill of under-stock (no mass respawn).
    local guard = 0
    while self:countVisibleOnMap(self.activeMapId) < self.targetSpawnCount
          and guard < 3 do
      guard = guard + 1
      if not self:trySpawn(game, {}) then break end
    end
  end
  self:_log("density retarget -> visible=%d via %s",
            self.targetSpawnCount, tostring(source))
end

function SpawnLogic:applyRandomEncounters(on, source)
  local enabled = on == true
  self.state.vanillaSuppressed = not enabled
  self:_log("random_encounters -> %s (vanillaSuppressed=%s) via %s",
            tostring(enabled), tostring(not enabled), tostring(source))
end

function SpawnLogic:applyWaterMons(on, source, mode)
  local game = gameOf(self.mod)
  mode = mode or Config.waterDisplayMode(self.mod)
  -- Prefer spawn-enabled check from mode when provided as string/bool.
  if on == nil then
    on = Config.waterMons(self.mod)
  end
  if not on then
    local mapId = self.activeMapId
    if mapId then
      local doomed = {}
      for _, id in ipairs(self.byMap[mapId] or {}) do
        local r = self.spawns[id]
        local e = self.entities[id]
        if r and Behavior.isWater(r.behavior)
           and r.state == Config.STATE.AVAILABLE then
          if e and e.state == Config.STATE.ENCOUNTER_STARTING then
            -- keep mid-battle
          else
            doomed[#doomed + 1] = id
          end
        elseif r and e and e.waterEnteredByChase then
          -- Land-origin chasers that entered water: remove when Water Mons off.
          if e.state ~= Config.STATE.ENCOUNTER_STARTING then
            doomed[#doomed + 1] = id
          end
        end
      end
      for _, id in ipairs(doomed) do
        self:_despawn(id, true)
      end
    end
    self.targetWaterCount = 0
    self.waterZoneTargets = { near = 0, mid = 0, deep = 0, total = 0 }
    self:_log("water_spawns %s via %s; removed water mons",
              tostring(mode), tostring(source))
    return
  end

  if not self.activeMapId or not self.state.initialized then
    self:_log("water_spawns %s via %s (deferred)", tostring(mode), tostring(source))
    return
  end
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if not (ow and ow.map) then return end
  local encDef = self:_encDef(self.activeMapId, game)
  self.waterCache = Grass.waterCells(ow.map)
  if self.surfaceInfo and self.surfaceInfo.surface == Surface.WATER then
    self.waterCache = self.eligibleCache or self.waterCache
    self.targetWaterCount = self:_computeWaterTarget(#self.waterCache)
    self.targetSpawnCount = self.targetWaterCount
    if self.state then self.state.targetSpawnCount = self.targetSpawnCount end
    self.waterRegions = SpawnRegions.build(self.waterCache)
  else
    local pool = WaterSpawn.buildPool(game, self.activeMapId, encDef)
    if WaterSpawn.hasPool(pool) and #(self.waterCache) > 0 then
      self.targetWaterCount = self:_computeWaterTarget(#self.waterCache)
      self.waterRegions = SpawnRegions.build(self.waterCache)
    else
      self.targetWaterCount = 0
    end
  end
  self:_rebuildWaterSpawnData(game, self.activeMapId, encDef)
  if game then
    local guard = 0
    while self:countWaterOnMap(self.activeMapId) < (self.targetWaterCount or 0)
          and guard < 4 do
      guard = guard + 1
      if not self:trySpawnWater(game, {}) then break end
    end
  end
  self:_log("water_spawns %s target=%d via %s",
            tostring(mode), self.targetWaterCount or 0, tostring(source))
end

-- Developer test spawn with explicit phase reporting. Never touches Pokédex,
-- save story flags, or player position.
function SpawnLogic:testSpawn(species, opts)
  opts = opts or {}
  local result = {
    ok = false,
    failedAt = nil,
    stepName = nil,
    error = nil,
    steps = {},
    species = species,
  }
  local function fail(step, err)
    result.ok = false
    result.failedAt = step
    result.stepName = TEST_STEPS[step]
    result.error = tostring(err)
    result.steps[step] = { name = TEST_STEPS[step], ok = false, error = result.error }
    DebugLog.error(self.mod,
      "Test spawn failed at step %d (%s): %s",
      step, TEST_STEPS[step], result.error)
    self.state.lastSpawnError = result.error
    self.lastTestSpawn = result
    return result
  end
  local function pass(step, detail)
    result.steps[step] = { name = TEST_STEPS[step], ok = true, detail = detail }
  end

  -- Test Spawn is always available as a developer Mod Settings action.
  -- (No longer gated on a separate Dev Mode toggle.)

  local game = gameOf(self.mod)
  if not game or not game.data then
    return fail(1, "game data unavailable")
  end

  -- Snapshot player position to prove we never move it.
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  local px = ow and ow.player and ow.player.cellX
  local py = ow and ow.player and ow.player.cellY
  local pokedexBefore = game.save and game.save.pokedex

  -- 1) Species resolved (ROM / content data only — never Pokédex)
  local mon = game.data.pokemon and game.data.pokemon[species]
  if not mon and not (self.mod.content.pokemon and self.mod.content.pokemon:get(species)) then
    return fail(1, "unknown species: " .. tostring(species))
  end
  pass(1, species)

  -- 2) Sprite ID lookup (species sprite or shared fallback; no registry writes)
  self.render:invalidateAssetCache(species)
  local spriteId, spriteErr = self.render:spriteIdFor(species)
  if not spriteId then
    return fail(2, spriteErr or ("No pre-registered sprite for species " .. tostring(species)))
  end
  pass(2, spriteId)

  -- 3) Runtime asset available (real image OR fallback — never abort on missing cache)
  local runtime = self.render:getRuntimeImage(species, game)
  local runtimeOk = runtime and (runtime.status == "LOADED"
                              or runtime.status == "FALLBACK_LOADED")
  if not runtimeOk then
    return fail(3, (runtime and runtime.status and ("Sprite asset could not be loaded (" .. tostring(runtime.status) .. ")"))
      or "Sprite asset could not be loaded.")
  end
  local info = self.render:assetStatusFor(species, game)
  local detail = runtime.status
  if runtime.fallbackUsed then
    detail = "FALLBACK_LOADED"
  elseif runtime.kind then
    detail = tostring(runtime.kind)
  end
  result.runtimeImage = detail
  result.fallbackUsed = runtime.fallbackUsed == true
  result.realAssetPath = info.realAssetPath
  result.tried = info.tried
  pass(3, detail)

  -- 4) Spawn tile resolved — prefer a free neighbour of the player.
  if not ow or not ow.map or not ow.player then
    return fail(4, "No free spawn tile")
  end
  local occupancy = self.rebuildOccupancy and self:rebuildOccupancy(ow) or self.occupancy
  local px = ow.player.cellX
  local py = ow.player.cellY
  local dirs = { { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 },
                 { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
  local x, y, reason
  local tileMode = (self.surfaceInfo and self.surfaceInfo.tileMode) or "grass"
  for _, d in ipairs(dirs) do
    local nx, ny = px + d[1], py + d[2]
    local okTile, tileReason
    if tileMode == "water" then
      okTile, tileReason = Grass.validateEligibleTile(
        ow.map, ow.entities, ow.player, nx, ny, 1, nil, nil, nil, "water", occupancy)
    elseif tileMode == "walkable" then
      okTile, tileReason = Grass.validateWalkableTile(
        ow.map, ow.entities, ow.player, nx, ny, 1, nil, nil)
      if okTile and self.caveReachability
         and self.caveReachability.status ~= "FAILED"
         and not CaveReachability.isReachable(self.caveReachability, nx, ny) then
        okTile, tileReason = false, "rejected: unreachable cave"
      end
    else
      okTile, tileReason = Grass.validateSpawnTile(
        ow.map, ow.entities, ow.player, nx, ny, 1, nil, nil)
    end
    if okTile then
      x, y = nx, ny
      break
    end
    reason = tileReason
  end
  if not x then
    -- Expand search slightly using surface-appropriate candidate list.
    local list
    if tileMode == "water" then
      list = self.waterCache or Grass.waterCells(ow.map)
    elseif tileMode == "walkable" then
      list = self.eligibleCache or Grass.caveCells(ow.map)
    else
      list = self.grassCache or Grass.cells(ow.map)
    end
    x, y, reason = Grass.pickFree(
      ow.map, ow.entities, ow.player, 1, nil, list, 6,
      function(r) self.state:noteReject(r) end,
      { mode = tileMode, occupancy = occupancy })
  end
  if not x then
    return fail(4, "No free spawn tile")
  end
  pass(4, ("(%d,%d)"):format(x, y))

  -- 5) Entity created (uses pre-registered sprite IDs only)
  local level = opts.level or 5
  local id = string.format("wilds_of_kanto_entity_%d", self.nextId)
  self.nextId = self.nextId + 1
  local record = {
    id = id,
    mapId = ow.map.id,
    x = x, y = y,
    species = species,
    level = level,
    state = Config.STATE.AVAILABLE,
    testSpawn = true,
    behavior = Behavior.IDLE_LOOK,
    surface = (self.surfaceInfo and self.surfaceInfo.surface) or Surface.GRASS,
    encounterKind = (self.surfaceInfo and self.surfaceInfo.encounterKind) or "grass",
    visibleSprite = true,
    hiddenEncounter = false,
  }

  local okCreate, entityOrErr = pcall(self.render.makeEntity, self.render, game, record)
  if not okCreate then
    DebugLog.error(self.mod, "ENTITY CREATE ERROR: %s", tostring(entityOrErr))
    return fail(5, "ENTITY CREATE ERROR: " .. tostring(entityOrErr))
  end
  if not entityOrErr then
    return fail(5, "ENTITY CREATE ERROR: makeEntity returned nil")
  end
  pass(5, id)
  local entity = entityOrErr
  result.entityPhase = entity.entityPhase
  result.fallbackUsed = entity.usingFallback == true or result.fallbackUsed

  -- 6) Entity registered in the world entity list
  local attached, attachErr = self:_attach(entity)
  if not attached then
    DebugLog.error(self.mod, "WORLD REGISTER ERROR: %s", tostring(attachErr))
    return fail(6, "WORLD REGISTER ERROR: " .. tostring(attachErr or "nil"))
  end
  if not entity.sprite or not entity.pose or not entity.draw then
    self:_removeEntity(entity)
    return fail(6, "DRAW REGISTER ERROR: renderer contract missing pose/draw/sprite")
  end
  if self.render.rendererMode ~= "base" then
    self:_removeEntity(entity)
    return fail(6, "DRAW REGISTER ERROR: " .. tostring(self.render.lastError or "renderer not ready"))
  end
  entity.entityPhase = result.fallbackUsed and "FALLBACK LOADED" or "ENTITY REGISTERED"
  pass(6, "registered")

  -- 7) Visible = registered + asset + non-zero opacity + on map.
  local opacity = (Config.spriteOpacity and Config.spriteOpacity(self.mod))
    or Config.get(self.mod, "sprite_opacity") or 1
  if opacity <= 0 then
    self:_removeEntity(entity)
    return fail(7, "OUTSIDE CAMERA: entity fully transparent")
  end
  if not entity.registeredInWorld then
    self:_removeEntity(entity)
    return fail(7, "ENTITY REMOVED IMMEDIATELY: not registered in world")
  end
  local iw, ih = 0, 0
  if entity.sprite and entity.sprite.image and entity.sprite.image.getDimensions then
    iw, ih = entity.sprite.image:getDimensions()
  end
  if iw == 0 or ih == 0 then
    -- Headless stubs may omit dimensions; only fail when graphics can answer.
    if love and love.graphics and entity.sprite and entity.sprite.image then
      self:_removeEntity(entity)
      return fail(7, "ASSET LOAD ERROR: image width/height is 0")
    end
  end
  pass(7, result.fallbackUsed and "FALLBACK LOADED" or "RENDERED")
  entity.entityPhase = result.fallbackUsed and "FALLBACK LOADED" or "RENDERED"

  local region = SpawnRegions.regionForCell(self.regions, x, y)
  Behavior.attach(entity, Behavior.IDLE_LOOK, region)
  record.behavior = Behavior.IDLE_LOOK
  record.homeRegionId = region and region.id or nil
  result.behavior = Behavior.IDLE_LOOK
  result.spriteScale = entity.visualScale
  result.scaleInfo = entity.scaleInfo

  self.spawns[id] = record
  self.entities[id] = entity
  self.byMap[ow.map.id] = self.byMap[ow.map.id] or {}
  self.byMap[ow.map.id][#self.byMap[ow.map.id] + 1] = id
  self:_recountRegions()

  -- Prove no side effects on player / pokedex / save.
  if ow.player then
    if ow.player.cellX ~= px or ow.player.cellY ~= py then
      DebugLog.error(self.mod, "BUG: test spawn moved player")
    end
  end
  if game.save and game.save.pokedex ~= pokedexBefore then
    DebugLog.error(self.mod, "BUG: test spawn mutated pokedex table ref")
  end

  result.ok = true
  result.x, result.y = x, y
  result.level = level
  result.id = id
  result.summary = result.fallbackUsed
    and "TEST SPAWN SUCCESS — Rendering with fallback sprite"
    or "TEST SPAWN SUCCESS — Rendering with real sprite"
  self.lastTestSpawn = result
  self:_log("Test spawn OK species=%s at (%d,%d) fallback=%s",
            tostring(species), x, y, tostring(result.fallbackUsed))
  return result
end

function SpawnLogic:onMapEntered(ev)
  local mapId = ev.mapId
  if self.activeMapId and self.activeMapId ~= mapId then
    self:_clearMap(self.activeMapId)
  end
  self.activeMapId = mapId
  self.stepsOnMap = 0
  self.grassCache = nil
  self.eligibleCache = nil
  self.regions = {}
  self.regionQuotas = {}
  self.regionCounts = {}
  self.targetSpawnCount = 0
  self.surfaceInfo = nil
  self.pendingBattle = nil

  self:_clearMap(mapId)
  if self.overlay then self.overlay:clear() end
  self:_restoreVanillaEncounters("map enter before init")

  -- Re-assert style-owned makeEntity wrap before any spawn (Followers may wrap later).
  if self.render and self.render.ensureStyleOwnedMakeEntity then
    local world = self.mod.world
    local game = world and world.game
    pcall(function() self.render:ensureStyleOwnedMakeEntity(game) end)
    local style = Config.spriteStyle(self.mod)
    self:_log("sprite_style mapenter saved/config/resolver=%s", tostring(style))
  end

  if not self:featureActive() then
    self.state:reset("disabled")
    self.state.updateCallbackRegistered = true
    if Config.devMode(self.mod) and self.hud then
      self.hud:markMapEnter()
    end
    return
  end

  local game = gameOf(self.mod)
  local ok, err = pcall(self.initializeForMap, self, mapId, game)
  if not ok then
    self:_warn("initializeForMap error: %s", tostring(err))
    DebugLog.error(self.mod, "initializeForMap error: %s", tostring(err))
    self.state:markError(err)
    if self.hud then self.hud:markMapEnter() end
    self:_restoreVanillaEncounters("initializeForMap error")
  end
end

function SpawnLogic:onMapExited(ev)
  if ev.mapId then self:_clearMap(ev.mapId) end
  if self.overlay then self.overlay:clear() end
  -- Safari flee state must not leak onto the next map.
  for _, entity in pairs(self.entities or {}) do
    if entity then Behavior.clearSafariFlee(entity) end
  end
  self.safariStatus = SafariCompat.STATUS.INACTIVE
  if self.state then
    self.state.safariCompat = SafariCompat.STATUS.INACTIVE
    self.state.safariActive = false
  end
  if self.activeMapId == ev.mapId then
    self.activeMapId = nil
    self.grassCache = nil
    self:_restoreVanillaEncounters("map exited")
    self.state:reset("map exited")
    self.state.updateCallbackRegistered = true
  end
end

function SpawnLogic:onMapReloaded(ev)
  if ev and ev.mapId and self.activeMapId == ev.mapId then
    self:onMapEntered({ mapId = ev.mapId })
  end
end

function SpawnLogic:onSaveLoaded()
  self:clearAll()
  self.activeMapId = nil
  self.stepsOnMap = 0
  if self.browser then self.browser:invalidateIndex() end
  local world = self.mod.world
  if not world or not world.overworld then return end
  local ow = world:overworld()
  if ow and ow.map and ow.map.id then
    self:onMapEntered({ mapId = ow.map.id, map = ow.map })
  end
end

function SpawnLogic:onOptionsChanged(payload)
  if not payload or payload.mod ~= self.mod.id then return end
  local key = payload.key
  if key == "enabled" and payload.value == false then
    self:clearAll()
  elseif key == "enabled" and payload.value == true then
    local world = self.mod.world
    local ow = world and world.overworld and world:overworld()
    if ow and ow.map and ow.map.id then
      self:onMapEntered({ mapId = ow.map.id, map = ow.map })
    end
  elseif key == "spawn_density"
      or key == "max_visible_pokemon"
      or key == "min_visible_pokemon"
      or key == "tiles_per_additional_pokemon"
      or key == "max_spawns" then
    self:applySpawnAmount(Config.spawnDensity(self.mod), "options_changed")
  elseif key == "random_encounters" then
    self:applyRandomEncounters(
      payload.value == true, "options_changed")
  elseif key == "water_spawns" or key == "enable_water_spawns" then
    local mode = Config.waterDisplayMode(self.mod)
    self:applyWaterMons(Config.waterMons(self.mod), "options_changed", mode)
    -- Presentation-only mode switches (swim ↔ silhouette ↔ hidden) must rebind
    -- sprites without respawning. invalidate caches so old colour/silhouette
    -- SpriteRenderers are never reused.
    if Config.waterMons(self.mod) and self.render then
      local world = self.mod.world
      local game = world and world.game
      if self.render.invalidateAssetCache then
        pcall(self.render.invalidateAssetCache, self.render)
      end
      if self.render.spriteResolver and self.render.spriteResolver.invalidateCache then
        pcall(self.render.spriteResolver.invalidateCache, self.render.spriteResolver)
      end
      pcall(self.render.refreshAllEntitySprites, self.render, self, game)
    end
  elseif key == "cave_spawns" or key == "enable_cave_spawns" then
    self:applyCaveSpawnMode(Config.caveSpawnMode(self.mod), "options_changed")
  elseif key == "dev_overlay"
      or key == "dev_mode"
      or key == "debug_hud_always_visible"
      or key == "show_spawn_tile_overlay"
      or key == "show_behavior_overlays"
      or key == "allow_debug_spawn_outside_encounter_areas"
      or key == "debug_logging"
      or key == "force_test_spawn"
      or key == "suppress_random_grass"
      or key == "enabled" then
    self:_log("option %s -> %s (suppress_ready=%s overlay=%s)",
              tostring(key), tostring(payload.value),
              tostring(self:canSuppressVanilla()),
              tostring(Config.devOverlay(self.mod)))
    if self.hud then self.hud:syncPipelineLevel() end
    if self.behaviorTick then self.behaviorTick:syncPipelineLevel() end
    if self.devOverlay and self.devOverlay.syncPipelineLevel then
      self.devOverlay:syncPipelineLevel()
    end
    if key == "dev_overlay" and payload.value == true and self.hud then
      self.hud:markMapEnter()
    end
    if key == "dev_overlay" and payload.value == false then
      if self.overlay then self.overlay:clear() end
    end
  elseif key == "sprite_style"
      or key == "use_animated_overworld_sprites" then
    -- Legacy Mon Sprites toggles map onto sprite_style via Config.spriteStyle.
    local world = self.mod.world
    local game = world and world.game
    self.render:invalidateAssetCache()
    local n = self.render:refreshAllEntitySprites(self, game)
    self:_log("sprite_style -> %s; refreshed %d entities (no respawn)",
              tostring(Config.spriteStyle(self.mod)), n)
    -- Refresh active follower land/water sprite to the new style.
    if self.followersWater and self.followersWater.invalidateStyle then
      pcall(function()
        self.followersWater:invalidateStyle()
        local ow = world and world.overworld and world:overworld()
        self.followersWater:tick(game, ow, function(speciesId, shiny, form, opts)
          return self:resolveWaterSprite(speciesId, shiny, form, opts)
        end)
      end)
    end
  elseif key == "sprite_fade" or key == "sprite_opacity" then
    self:_log("sprite_fade -> %s (opacity=%s)",
              tostring(Config.spriteFade(self.mod)),
              tostring(Config.spriteOpacity(self.mod)))
  elseif key == "town_pokemon" then
    self:_log("town_pokemon -> %s", tostring(Config.townPokemonEnabled(self.mod)))
  elseif key == "pokemon_grass_render_mode"
      or key == "show_pokemon_in_grass" then
    local Movement = V.require("movement")
    local n = 0
    for _, entity in pairs(self.entities or {}) do
      if entity then
        Movement.refreshGrassFlag(entity, self.mod)
        n = n + 1
      end
    end
    self:_log("grass render mode -> %s; refreshed %d entities (no respawn)",
              tostring(Config.pokemonGrassRenderMode(self.mod)), n)
  end
end

function SpawnLogic:_spawnAt(x, y)
  for id, record in pairs(self.spawns) do
    if record.state == Config.STATE.AVAILABLE
       and record.x == x and record.y == y then
      return id, record, self.entities[id]
    end
  end
  return nil
end

function SpawnLogic:_startBattle(record)
  if not record or record.state ~= Config.STATE.AVAILABLE then
    return false
  end
  if self.pendingBattle then return false end

  local world = self.mod.world
  if not world or not world.overworld then return false end
  local ow = world:overworld()
  if not ow then return false end
  if ow.runner and ow.runner.isRunning and ow.runner:isRunning() then
    return false
  end

  local entity = self.entities[record.id]
  -- Ambient Town Pokémon and any non-battleable wild marker never battle.
  if entity and Config.isBattleableWild and not Config.isBattleableWild(entity) then
    return false
  end
  if entity and entity.wildsAmbientPokemon then
    return false
  end

  local game = gameOf(self.mod)
  local mapId = record.mapId or (ow.map and ow.map.id) or self.activeMapId
  local safariStatus = SafariCompat.status(game, ow, mapId)
  local safariActive = safariStatus == SafariCompat.STATUS.ACTIVE

  -- Never start a normal wild battle inside Safari; only the native path.
  if SafariCompat.isSafariMap(game, mapId, ow)
     and safariStatus ~= SafariCompat.STATUS.ACTIVE then
    self:_warn("Safari encounter blocked (status=%s); no normal wild battle",
               tostring(safariStatus))
    return false
  end

  record.state = Config.STATE.ENCOUNTER_STARTING
  entity = self.entities[record.id]
  if entity then
    entity.state = Config.STATE.ENCOUNTER_STARTING
    entity.alertIcon = false
    if entity.behaviorState then
      entity.behaviorState.battleStarted = true
      entity.behaviorState.battlePending = true
      entity.behaviorState.sightDisabled = true
      entity.behaviorState.state = Behavior.STATE.BATTLE_PENDING
      Behavior.clearSafariFlee(entity)
      entity.behaviorState.battleStarted = true
      entity.behaviorState.battlePending = true
    end
    if self.occupancy then
      self.occupancy:cancelMove(entity)
      self.occupancy:releaseEntity(entity)
    end
    Movement.stop(entity, "BATTLE_PENDING")
    -- Hide from both render paths before battle (exactly once).
    if self.voxel then self.voxel:unregister(entity) end
    self:_detachFromWorld(entity)
    if entity.behaviorState then
      entity.behaviorState.state = Behavior.STATE.IN_BATTLE
    end
  end

  self.pendingBattle = {
    id = record.id,
    species = record.species,
    level = record.level,
    behavior = record.behavior,
    safari = safariActive,
  }

  -- Clear our emotion bubble if we own it.
  if ow.emote and entity and ow.emote.npc == entity then
    ow.emote = nil
  end

  self:_despawn(record.id, true)
  self:_recountRegions()

  local ok, err
  if safariActive then
    ok, err = SafariCompat.startNativeSafariEncounter(
      game, ow, record.species, record.level, {
        safari = SafariCompat.sessionState(game),
      })
    if not ok then
      self:_warn("could not start native Safari encounter: %s", tostring(err))
      self.pendingBattle = nil
      self.state:markError(err)
      -- Do not fall back to a normal wild battle in Safari.
      self.state.safariCompat = SafariCompat.STATUS.FALLBACK_VANILLA
      self:_restoreVanillaEncounters("safari encounter path failed")
      return false
    end
    if self.pendingBattle then
      self.pendingBattle.state = Config.STATE.IN_BATTLE
    end
    self.mod.log:info("triggered safari encounter: %s Lv%d (%s) id=%s",
                      record.species, record.level, tostring(record.behavior),
                      tostring(record.id))
    return true
  end

  ok, err = world:queueScript({
    { "start_battle", "wild", record.species, record.level },
  })
  if not ok then
    self:_warn("could not queue wild battle: %s", tostring(err))
    self.pendingBattle = nil
    self.state:markError(err)
    self:_restoreVanillaEncounters("battle queue failed")
    return false
  end

  if self.pendingBattle then
    self.pendingBattle.state = Config.STATE.IN_BATTLE
  end
  self.mod.log:info("triggered wild battle: %s Lv%d (%s) id=%s",
                    record.species, record.level, tostring(record.behavior),
                    tostring(record.id))
  return true
end

function SpawnLogic:_despawnFar(ow)
  -- Despawn only entities far behind the player so long routes can refill
  -- ahead without popping in nearby. Never larger than map span.
  local maxDist = Config.DEFAULTS.despawn_distance
                  or Config.DEFAULTS.max_player_distance
  local mapSpan = math.max(ow.map.widthCells or 0, ow.map.heightCells or 0)
  maxDist = math.min(math.max(maxDist, 16), math.max(mapSpan, 16))
  local player = ow.player
  if not player then return end
  local doomed = {}
  for id, record in pairs(self.spawns) do
    if record.state == Config.STATE.AVAILABLE then
      local entity = self.entities[id]
      -- Never despawn an aggressive chase.
      if entity and entity.behaviorState and entity.behaviorState.chasing then
        -- keep
      else
        local d = Grass.chebyshev(record.x, record.y, player.cellX, player.cellY)
        if d > maxDist then
          doomed[#doomed + 1] = id
        end
      end
    end
  end
  for _, id in ipairs(doomed) do
    self:_despawn(id, true)
  end
  if #doomed > 0 then self:_recountRegions() end
end

function SpawnLogic:_wander(ow)
  -- Legacy step-wander disabled; Behaviour.GRASS_WANDER owns movement.
  return
end

function SpawnLogic:onStepped(ev)
  self.state.updateCallbackCount = self.state.updateCallbackCount + 1
  self.state.updateCallbackActive = true

  if Config.debug(self.mod) and self.state.updateCallbackCount == 1 then
    self:_log("update callback world.stepped is active")
  end
  if Config.debug(self.mod) and self.state.updateCallbackCount > 0
     and self.state.updateCallbackCount % 24 == 0 then
    self:_logDiag()
  end

  if not ev or not ev.mapId then return end
  if self.activeMapId ~= ev.mapId then return end

  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()

  if not self:featureActive() then
    if self:countOnMap(ev.mapId) > 0 then self:_clearMap(ev.mapId) end
    return
  end

  if not self.state.initialized and ow and ow.map then
    local game = gameOf(self.mod)
    local ok, err = pcall(self.initializeForMap, self, ev.mapId, game)
    if not ok then
      self:_warn("late initializeForMap error: %s", tostring(err))
      self.state:markError(err)
      self:_restoreVanillaEncounters("late init error")
      return
    end
  end

  local id, record, entity = self:_spawnAt(ev.x, ev.y)

  if record then
    entity = entity or self.entities[id]
    -- Block battle during spawn FX.
    if entity and not SpawnFx.canBattle(entity) then
      return
    end
    if Config.devMode(self.mod) then
      self:_log("Battle source: CONTACT")
    end
    self:_startBattle(record)
    return
  end

  self.stepsOnMap = self.stepsOnMap + 1

  if ow then
    self:_despawnFar(ow)
    self:_wander(ow)
  end

  if not self.state.initialized then return end

  local every = Config.refillSteps(self.mod)
  if self.stepsOnMap % every == 0 then
    local game = gameOf(self.mod)
    if game then
      local surface = self.surfaceInfo and self.surfaceInfo.surface
      if surface ~= Surface.WATER then
        local active = self:countLandOnMap(ev.mapId)
        local target = self.targetSpawnCount or Config.maxVisible(self.mod)
        local guard = 0
        while active < target and guard < 3 do
          guard = guard + 1
          local ok, resultOrErr = pcall(self.trySpawn, self, game, {})
          if not ok then
            self:_warn("trySpawn error: %s", tostring(resultOrErr))
            DebugLog.error(self.mod, "trySpawn error: %s", tostring(resultOrErr))
            self.state:markError(resultOrErr)
            self:_restoreVanillaEncounters("trySpawn error")
            break
          elseif not resultOrErr then
            break
          else
            active = active + 1
          end
        end
      end
      if Config.waterMons(self.mod) and (self.targetWaterCount or 0) > 0 then
        local wguard = 0
        while self:countWaterOnMap(ev.mapId) < self.targetWaterCount and wguard < 2 do
          wguard = wguard + 1
          if not self:trySpawnWater(game, {}) then break end
        end
      end
    end
  end
end

function SpawnLogic:_logDiag()
  local st = self.state
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  local px = ow and ow.player and ow.player.cellX
  local py = ow and ow.player and ow.player.cellY
  local game = gameOf(self.mod)
  local vis = Diagnostics.visibilityCounts(self)
  DebugLog.onceKey(self.mod, "diag-snapshot", "INFO",
    "diag map=%s species=%d slots=%d tiles=%d assets=%d/%d active=%d created=%d registered=%d rendered=%d status=%s err=%s",
    tostring(st.mapId), st.uniqueSpeciesCount or 0, st.encounterEntryCount or 0,
    st.eligibleTileCount or 0, st.loadedAssets or 0, st.requiredAssets or 0,
    vis.active, vis.created, vis.registered, vis.rendered,
    Diagnostics.spawnSystemStatus(self), tostring(st.lastError))
  self:_debug("diag player=(%s,%s) pokedex_owned=%s (diag)",
              tostring(px), tostring(py), tostring(pokedexOwnedForDiag(game)))
end

function SpawnLogic:onBattleEnded()
  self.pendingBattle = nil
end

function SpawnLogic:onCollision(allowed, ctx)
  if allowed then return allowed end
  if not self:featureActive() then return allowed end
  if not ctx or ctx.reason ~= "entity" then return allowed end
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if not ow or not ow.player or ctx.mover ~= ow.player then return allowed end

  -- Ambient Town Pokémon: normal NPC collision only — never a wild battle.
  if ctx.entity and (ctx.entity.wildsAmbientPokemon
      or (Config.isBattleableWild and not Config.isBattleableWild(ctx.entity)
          and ctx.entity.overworldWildSpawn ~= true)) then
    return allowed
  end

  local id, record, entity = self:_spawnAt(ctx.toX, ctx.toY)
  if record then
    entity = entity or self.entities[id]
    if entity and entity.wildsAmbientPokemon then
      return allowed
    end
    if entity and Config.isBattleableWild and not Config.isBattleableWild(entity) then
      return allowed
    end
    if entity and not SpawnFx.canBattle(entity) then
      return allowed
    end
    self:_startBattle(record)
    return false
  end
  return allowed
end

function SpawnLogic.touchesPlayerPosition()
  return false
end

function SpawnLogic.requiresPokedex()
  return false
end

function SpawnLogic.testSteps()
  return TEST_STEPS
end

return SpawnLogic
