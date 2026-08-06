-- External mod detection, single-owner guard, save migration.
local V = ...
local Constants = V.require("follower/constants")
local DebugLog = V.require("debug_log")

local Compatibility = {}
Compatibility.__index = Compatibility

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function saveGet(mod, key)
  if not (mod and mod.save and mod.save.get) then return nil end
  local ok, value = pcall(function() return mod.save:get(key) end)
  if ok then return value end
  return nil
end

function Compatibility.new(mod, state)
  local self = setmetatable({}, Compatibility)
  self.mod = mod
  self.state = state
  return self
end

function Compatibility:findMod(id)
  if not (self.mod and self.mod.find) then return nil end
  local ok, hit = pcall(function() return self.mod:find(id) end)
  if ok then return hit end
  return nil
end

function Compatibility:detectExternalMods()
  local found = {}
  for _, id in ipairs(Constants.KNOWN_EXTERNAL_IDS) do
    local hit = self:findMod(id)
    if hit then
      found[#found + 1] = {
        id = id,
        version = hit.version,
        hasExports = hit.exports ~= nil,
        exports = hit.exports,
      }
    end
  end
  self.state.externalMods = found
  return found
end

function Compatibility:followersExActive()
  local hit = self:findMod(Constants.FOLLOWERS_EX_ID)
  if not hit then return false end
  local ex = hit.exports
  if not ex then return false end
  -- Control engine marker / sync APIs indicate a live lifecycle owner.
  if ex._followersExControlEngine == true then return true end
  if type(ex.syncTrailers) == "function" or type(ex.syncAll) == "function" then
    return true
  end
  if type(ex.getActiveFollowerMon) == "function" and type(ex.setControlMode) == "function" then
    return true
  end
  return false
end

function Compatibility:pokePcLifecycleActive()
  local hit = self:findMod(Constants.POKEPC_ID)
  if not hit or not hit.exports then return false, hit end
  local ex = hit.exports
  if type(ex.select) == "function" or type(ex.sync) == "function" then
    return true, hit
  end
  local PF = tryRequire("src.world.PikachuFollower")
  if PF and rawget(PF, "__pokepcFollowersUniversal") then
    return true, hit
  end
  return false, hit
end

--- Decide owner mode. Wilds always owns runtime after standalone follow-up.
--- External mods are migration sources only.
function Compatibility:resolveOwnerMode()
  self:detectExternalMods()
  self.state.ownerMode = Constants.OWNER.wilds
  if self:followersExActive() then
    return self.state.ownerMode, "FOLLOWERS_EX"
  end
  local pokeActive = self:pokePcLifecycleActive()
  if pokeActive then
    return self.state.ownerMode, "PokePCFollowers_VoxelMerge"
  end
  return self.state.ownerMode, nil
end

function Compatibility:logExternalOwnerWarning(detectedId)
  local msg = "[Wilds] Legacy follower mod detected. Settings and selection were imported; Wilds now owns follower runtime."
  if detectedId then
    msg = msg .. " (" .. tostring(detectedId) .. ")"
  end
  if self.mod and self.mod.log and self.mod.log.info then
    pcall(function() self.mod.log:info("%s", msg) end)
  end
  DebugLog.info(self.mod, "%s", msg)
  return msg
end

--- Import legacy selection once. Never deletes old keys.
function Compatibility:migrateSelection(game, selection)
  if self.state.migrated then
    return false, "already_migrated"
  end
  local mod = self.mod
  local imported = false

  -- Prefer Wilds keys if already present.
  if self.state.selectedMonKey then
    self.state:markMigrated()
    return false, "wilds_present"
  end

  -- PokéPC mod.save keys (same process may share; try Wilds mod.save legacy names).
  local legacyMon = saveGet(mod, Constants.LEGACY.pokepc_selected_mon)
  local legacySlot = tonumber(saveGet(mod, Constants.LEGACY.pokepc_selected_slot))
  if legacyMon then
    self.state:setSelection(legacyMon, legacySlot)
    imported = true
  end

  -- External PokéPC mod instance save (if accessible).
  if not imported then
    local poke = self:findMod(Constants.POKEPC_ID)
    if poke and poke.save and poke.save.get then
      local okMon, monKey = pcall(function()
        return poke.save:get(Constants.LEGACY.pokepc_selected_mon)
      end)
      local okSlot, slot = pcall(function()
        return poke.save:get(Constants.LEGACY.pokepc_selected_slot)
      end)
      if okMon and monKey then
        self.state:setSelection(monKey, okSlot and tonumber(slot) or nil)
        imported = true
      end
    end
  end

  -- Followers EX / legacy game.save.followerPartyIndex.
  if not imported and game and game.save then
    local idx = tonumber(game.save.followerPartyIndex)
    local party = game.save.party
    if idx and party and party[idx] and selection then
      local key = selection.monFingerprint(party[idx])
      if key then
        self.state:setSelection(key, idx)
        imported = true
      end
    end
  end

  -- EX leader party index via exports.
  if not imported then
    local ex = self:findMod(Constants.FOLLOWERS_EX_ID)
    local exports = ex and ex.exports
    if exports and type(exports.getActiveFollowerMon) == "function" and selection then
      local ok, mon = pcall(exports.getActiveFollowerMon, game)
      if ok and mon then
        local party = game and game.save and game.save.party
        local slot
        if party then
          for i, m in ipairs(party) do
            if m == mon then slot = i break end
          end
        end
        local key = selection.monFingerprint(mon)
        if key then
          self.state:setSelection(key, slot)
          imported = true
        end
      end
    end
  end

  self.state:markMigrated()
  return imported, imported and "imported" or "nothing_to_import"
end

--- Attempt to restore PokéPC hooks so Wilds can become the sole wrapper.
function Compatibility:restorePokePcIfPresent()
  local active, hit = self:pokePcLifecycleActive()
  if not active then return false end
  if hit and hit.exports and type(hit.exports.restore) == "function" then
    local ok = pcall(hit.exports.restore)
    return ok == true
  end
  local PF = tryRequire("src.world.PikachuFollower")
  local prev = PF and rawget(PF, "__pokepcFollowersUniversal")
  if prev and type(prev.restore) == "function" then
    local ok = pcall(prev.restore)
    return ok == true
  end
  return false
end

--- Best-effort: disable Followers EX control engine if it exposes restore/uninstall.
function Compatibility:restoreFollowersExIfPresent()
  local hit = self:findMod(Constants.FOLLOWERS_EX_ID)
  if not hit or not hit.exports then return false end
  local ex = hit.exports
  if type(ex.restore) == "function" then
    local ok = pcall(ex.restore)
    return ok == true
  end
  -- No public restore: leave markers; Wilds re-wraps outermost on mods.loaded.
  -- Document that users should disable FOLLOWERS_EX when using standalone Wilds.
  if self.mod and self.mod.log and self.mod.log.warn then
    pcall(function()
      self.mod.log:warn(
        "[Wilds] FOLLOWERS_EX is installed; disable it to avoid duplicate follower hooks. Wilds owns runtime.")
    end)
  end
  return false
end

function Compatibility:hasExternalFollowerEntity(ow)
  if not ow then return false end
  local function scan(list)
    if type(list) ~= "table" then return false end
    for i = 1, #list do
      local e = list[i]
      if e and (e.pokepcTrailer == true or e.pikachuFollower == true
          or e.wildsFollower == true or e.isFollower == true) then
        return true
      end
    end
    return false
  end
  if type(ow.pokepcTrailers) == "table" and #ow.pokepcTrailers > 0 then
    return true
  end
  return scan(ow.entities) or scan(ow.npcs)
end

return Compatibility
