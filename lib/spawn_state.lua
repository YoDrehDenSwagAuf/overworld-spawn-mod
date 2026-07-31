-- Fail-safe readiness state for visible overworld wild spawns.
-- Vanilla grass rolls may be suppressed ONLY when every flag below is true
-- and lastError is nil. The Pokédex is never part of this state.
local V = ...

local SpawnState = {}
SpawnState.__index = SpawnState

function SpawnState.new()
  local self = setmetatable({}, SpawnState)
  self:reset("boot")
  return self
end

function SpawnState:reset(reason)
  self.initialized = false
  self.mapSupported = false
  self.encounterDataAvailable = false
  self.eligibleTilesAvailable = false
  self.rendererAvailable = false
  self.updateCallbackRegistered = false
  self.updateCallbackActive = false
  self.pipelineVerified = false
  self.vanillaSuppressed = false
  self.lastError = nil
  self.lastSpawnError = nil
  self.mapId = nil
  self.mapName = nil
  self.mapType = nil
  self.unsupportedReason = nil
  self.rejectCounts = {}
  self.encounterEntryCount = 0
  self.uniqueSpeciesCount = 0
  self.uniqueSpecies = {}
  self.eligibleTileCount = 0
  self.requiredAssets = 0
  self.loadedAssets = 0
  self.assetsLoading = false
  self.assetError = nil
  self.fallbackToVanilla = false
  self.phase = "idle"
  self.pokedexOwnedDiag = nil
  self.hudShownAt = nil
  self.updateCallbackCount = 0
  self.lastDiagAt = 0
  self.resetReason = reason or "reset"
  self.encounterSource = nil
  self.surface = nil
  self.encounterKind = nil
  self.spawnRegionCount = 0
  self.targetSpawnCount = 0
  self.allocatedSpawns = 0
  self.tileRejectBreakdown = {
    collision = 0,
    warp = 0,
    npc = 0,
    player_distance = 0,
    unknown_tile = 0,
    outside = 0,
    player = 0,
    other = 0,
  }
end

function SpawnState:markUnsupported(reason)
  self.mapSupported = false
  self.unsupportedReason = reason
  self.initialized = false
  self.pipelineVerified = false
  self.vanillaSuppressed = false
  self.fallbackToVanilla = true
  self.phase = "idle"
end

function SpawnState:markError(err)
  self.lastError = tostring(err)
  self.lastSpawnError = self.lastError
  self.initialized = false
  self.pipelineVerified = false
  self.vanillaSuppressed = false
  self.fallbackToVanilla = true
  self.phase = "idle"
end

function SpawnState:clearError()
  self.lastError = nil
  self.assetError = nil
end

function SpawnState:noteReject(reason)
  local key = tostring(reason or "rejected: unknown")
  self.rejectCounts[key] = (self.rejectCounts[key] or 0) + 1
  local br = self.tileRejectBreakdown
  if key:find("blocked", 1, true) or key:find("collision", 1, true) then
    br.collision = br.collision + 1
  elseif key:find("warp", 1, true) then
    br.warp = br.warp + 1
  elseif key:find("NPC", 1, true) or key:find("occupied by NPC", 1, true) then
    br.npc = br.npc + 1
  elseif key:find("too close", 1, true) or key:find("search radius", 1, true) then
    br.player_distance = br.player_distance + 1
  elseif key:find("outside map", 1, true) then
    br.outside = br.outside + 1
  elseif key:find("occupied by player", 1, true) then
    br.player = br.player + 1
  elseif key:find("not encounter", 1, true) or key:find("unknown", 1, true) then
    br.unknown_tile = br.unknown_tile + 1
  else
    br.other = br.other + 1
  end
end

-- Vanilla grass rolls stay active unless the visible system is fully ready
-- for the current map. Pokédex ownership is intentionally not consulted.
function SpawnState:canSuppressVanilla()
  return self.initialized == true
     and self.mapSupported == true
     and self.encounterDataAvailable == true
     and self.eligibleTilesAvailable == true
     and self.rendererAvailable == true
     and self.updateCallbackRegistered == true
     and self.pipelineVerified == true
     and self.lastError == nil
end

function SpawnState:snapshot()
  return {
    initialized = self.initialized,
    mapSupported = self.mapSupported,
    encounterDataAvailable = self.encounterDataAvailable,
    eligibleTilesAvailable = self.eligibleTilesAvailable,
    rendererAvailable = self.rendererAvailable,
    updateCallbackRegistered = self.updateCallbackRegistered,
    updateCallbackActive = self.updateCallbackActive,
    pipelineVerified = self.pipelineVerified,
    vanillaSuppressed = self.vanillaSuppressed,
    lastError = self.lastError,
    lastSpawnError = self.lastSpawnError,
    mapId = self.mapId,
    mapName = self.mapName,
    mapType = self.mapType,
    unsupportedReason = self.unsupportedReason,
    encounterEntryCount = self.encounterEntryCount,
    uniqueSpeciesCount = self.uniqueSpeciesCount,
    uniqueSpecies = self.uniqueSpecies,
    eligibleTileCount = self.eligibleTileCount,
    requiredAssets = self.requiredAssets,
    loadedAssets = self.loadedAssets,
    assetsLoading = self.assetsLoading,
    assetError = self.assetError,
    fallbackToVanilla = self.fallbackToVanilla,
    phase = self.phase,
    pokedexOwnedDiag = self.pokedexOwnedDiag,
    hudShownAt = self.hudShownAt,
    updateCallbackCount = self.updateCallbackCount,
    rejectCounts = self.rejectCounts,
    tileRejectBreakdown = self.tileRejectBreakdown,
    encounterSource = self.encounterSource,
    surface = self.surface,
    encounterKind = self.encounterKind,
    spawnRegionCount = self.spawnRegionCount,
    targetSpawnCount = self.targetSpawnCount,
    allocatedSpawns = self.allocatedSpawns,
  }
end

return SpawnState
