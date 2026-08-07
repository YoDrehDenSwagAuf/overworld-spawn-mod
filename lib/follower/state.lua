-- Follower selection state + persistence (no renderer logic).
-- Concepts adapted from PokéPC Followers (gamecorner-033).
local V = ...
local Constants = V.require("follower/constants")

local State = {}
State.__index = State

local function saveGet(mod, key)
  if not (mod and mod.save and mod.save.get) then return nil end
  local ok, value = pcall(function() return mod.save:get(key) end)
  if ok then return value end
  return nil
end

local function saveSet(mod, key, value)
  if not (mod and mod.save and mod.save.set) then return false end
  local ok = pcall(function() mod.save:set(key, value) end)
  return ok == true
end

function State.new(mod)
  local self = setmetatable({}, State)
  self.mod = mod
  self.selectedMonKey = nil
  self.selectedSlot = nil
  self.identity = nil
  self.migrated = false
  self.surface = Constants.SURFACE.land
  self.ownerMode = Constants.OWNER.wilds
  self.externalMods = {}
  self.spriteRendererNews = 0
  self.lastRefreshReason = nil
  self:_load()
  return self
end

function State:_load()
  local mod = self.mod
  local version = tonumber(saveGet(mod, Constants.SAVE.version)) or 0
  self.selectedMonKey = saveGet(mod, Constants.SAVE.selected_mon)
  local slot = tonumber(saveGet(mod, Constants.SAVE.selected_slot))
  self.selectedSlot = slot
  self.migrated = saveGet(mod, Constants.SAVE.migrated) == true
  if version < Constants.FOLLOWER_STATE_VERSION then
    saveSet(mod, Constants.SAVE.version, Constants.FOLLOWER_STATE_VERSION)
  end
end

function State:persist()
  local mod = self.mod
  saveSet(mod, Constants.SAVE.version, Constants.FOLLOWER_STATE_VERSION)
  if self.selectedMonKey ~= nil then
    saveSet(mod, Constants.SAVE.selected_mon, self.selectedMonKey)
  end
  if self.selectedSlot ~= nil then
    saveSet(mod, Constants.SAVE.selected_slot, self.selectedSlot)
  end
  if self.migrated then
    saveSet(mod, Constants.SAVE.migrated, true)
  end
end

function State:setSelection(monKey, slot)
  self.selectedMonKey = monKey
  self.selectedSlot = slot
  self.identity = monKey
  self:persist()
end

function State:clearSelection()
  self.selectedMonKey = nil
  self.selectedSlot = nil
  self.identity = nil
  self:persist()
end

function State:markMigrated()
  self.migrated = true
  saveSet(self.mod, Constants.SAVE.migrated, true)
end

function State:setSurface(surface)
  self.surface = surface or Constants.SURFACE.land
end

function State:snapshot()
  return {
    version = Constants.FOLLOWER_STATE_VERSION,
    selected_mon = self.selectedMonKey,
    selected_slot = self.selectedSlot,
    identity = self.identity,
    migrated = self.migrated,
    surface = self.surface,
    ownerMode = self.ownerMode,
    externalMods = self.externalMods,
    spriteRendererNews = self.spriteRendererNews,
    lastRefreshReason = self.lastRefreshReason,
  }
end

return State
