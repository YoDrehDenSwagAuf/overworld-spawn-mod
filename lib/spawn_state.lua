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
  self.mapId = nil
  self.mapName = nil
  self.unsupportedReason = nil
  self.rejectCounts = {}
  self.encounterEntryCount = 0
  self.eligibleTileCount = 0
  self.updateCallbackCount = 0
  self.lastDiagAt = 0
  self.resetReason = reason or "reset"
end

function SpawnState:markUnsupported(reason)
  self.mapSupported = false
  self.unsupportedReason = reason
  self.initialized = false
  self.pipelineVerified = false
  self.vanillaSuppressed = false
end

function SpawnState:markError(err)
  self.lastError = tostring(err)
  self.initialized = false
  self.pipelineVerified = false
  self.vanillaSuppressed = false
end

function SpawnState:clearError()
  self.lastError = nil
end

function SpawnState:noteReject(reason)
  local key = tostring(reason or "rejected: unknown")
  self.rejectCounts[key] = (self.rejectCounts[key] or 0) + 1
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
    mapId = self.mapId,
    mapName = self.mapName,
    unsupportedReason = self.unsupportedReason,
    encounterEntryCount = self.encounterEntryCount,
    eligibleTileCount = self.eligibleTileCount,
    updateCallbackCount = self.updateCallbackCount,
    rejectCounts = self.rejectCounts,
  }
end

return SpawnState
