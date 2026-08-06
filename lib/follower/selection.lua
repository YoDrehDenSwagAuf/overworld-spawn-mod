-- Party follower selection (PokéPC concepts adapted for Wilds).
-- Owns: active mon resolution, fingerprint, health, select API.
-- Does NOT resolve sprites or touch renderers.
local V = ...
local Constants = V.require("follower/constants")

local Selection = {}
Selection.__index = Selection

local function healthy(mon)
  return type(mon) == "table" and (tonumber(mon.hp) or 0) > 0
end

-- Fingerprint from stable engine fields. Species alone is insufficient when
-- the party has duplicates; include species + OT + DVs + catchRate.
local function monFingerprint(mon)
  if type(mon) ~= "table" then return nil end
  local dvs = type(mon.dvs) == "table" and mon.dvs or {}
  return table.concat({
    tostring(mon.species or ""),
    tostring(mon.otId or -1),
    tostring(dvs.attack or -1),
    tostring(dvs.defense or -1),
    tostring(dvs.speed or -1),
    tostring(dvs.special or -1),
    tostring(mon.catchRate or -1),
  }, ":")
end

-- Legacy PokéPC key without species (ot:dvs:catchRate).
local function monFingerprintLegacy(mon)
  if type(mon) ~= "table" then return nil end
  local dvs = type(mon.dvs) == "table" and mon.dvs or {}
  return table.concat({
    tostring(mon.otId or -1),
    tostring(dvs.attack or -1),
    tostring(dvs.defense or -1),
    tostring(dvs.speed or -1),
    tostring(dvs.special or -1),
    tostring(mon.catchRate or -1),
  }, ":")
end

local function fingerprintsMatch(stored, mon)
  if not stored or not mon then return false end
  if monFingerprint(mon) == stored then return true end
  -- Accept legacy keys missing species.
  if monFingerprintLegacy(mon) == stored then return true end
  return false
end

function Selection.new(mod, state)
  local self = setmetatable({}, Selection)
  self.mod = mod
  self.state = state
  return self
end

Selection.healthy = healthy
Selection.monFingerprint = monFingerprint

function Selection:getParty(game)
  if not (game and game.save and type(game.save.party) == "table") then
    return nil
  end
  return game.save.party
end

--- Resolve the active follower mon.
-- @param needHealthy when true, fainted mons are skipped
-- @return mon, slot or nil
function Selection:getActiveFollowerMon(game, needHealthy)
  local party = self:getParty(game)
  if not party or #party == 0 then return nil end

  local selKey = self.state.selectedMonKey
  local selSlot = tonumber(self.state.selectedSlot)

  if selKey then
    local atSlot = selSlot and party[selSlot]
    if atSlot and fingerprintsMatch(selKey, atSlot)
        and (not needHealthy or healthy(atSlot)) then
      return atSlot, selSlot
    end
    for i, mon in ipairs(party) do
      if fingerprintsMatch(selKey, mon) and (not needHealthy or healthy(mon)) then
        -- Slot drifted (sort/swap); refresh stored slot hint + upgrade key.
        local key = monFingerprint(mon)
        if key and (i ~= selSlot or key ~= selKey) then
          self.state:setSelection(key, i)
        end
        return mon, i
      end
    end
  end

  -- Legacy game.save.followerPartyIndex (do not delete; read-only fallback).
  local idx = game.save and tonumber(game.save.followerPartyIndex)
  if idx and party[idx] and (not needHealthy or healthy(party[idx])) then
    return party[idx], idx
  end

  for i, mon in ipairs(party) do
    if not needHealthy or healthy(mon) then
      return mon, i
    end
  end
  if needHealthy then return nil end
  return party[1], 1
end

--- Persist an explicit party selection.
function Selection:selectFollower(mon, game, opts)
  opts = opts or {}
  if not (mon and game and healthy(mon)) then return false end
  local party = self:getParty(game)
  if not party then return false end
  local slot
  for i, candidate in ipairs(party) do
    if candidate == mon then
      slot = i
      break
    end
  end
  if not slot then return false end

  local key = monFingerprint(mon)
  if not key then return false end
  self.state:setSelection(key, slot)

  -- Mirror legacy keys for compatibility with older companion mods (write-only).
  if game.save then
    game.save.followerPartyIndex = slot
    game.save.followerSpecies = mon.species
  end

  if opts.onSelected then
    pcall(opts.onSelected, mon, slot, game)
  end
  return true, slot
end

--- Ensure selection still points at a valid party mon after party mutations.
function Selection:reconcile(game)
  local party = self:getParty(game)
  if not party or #party == 0 then
    return nil
  end
  local mon, slot = self:getActiveFollowerMon(game, true)
  if mon then
    local key = monFingerprint(mon)
    if key and (key ~= self.state.selectedMonKey or slot ~= self.state.selectedSlot) then
      self.state:setSelection(key, slot)
    end
    return mon, slot
  end
  -- Selected fainted / removed: fall back to first healthy and persist.
  mon, slot = self:getActiveFollowerMon(game, false)
  if mon and healthy(mon) then
    self.state:setSelection(monFingerprint(mon), slot)
    return mon, slot
  end
  return nil
end

return Selection
