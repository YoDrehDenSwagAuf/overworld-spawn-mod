-- Wilds follower control settings (Mod Settings + save migration).
-- Replaces FOLLOWERS_EX options: control_mode, trainer_follows, follower_count.
local V = ...
local Constants = V.require("follower/constants")
local Config = V.require("config")
local DebugLog = V.require("debug_log")

local Settings = {}
Settings.__index = Settings

local VALID_UI_CONTROL = { trainer = true, pokemon = true }
local VALID_ENGINE = {
  follow = true,
  pokemon = true,
  lead_trainer = true,
  pack = true,
}

local function clampCount(n)
  n = tonumber(n)
  if n == nil then return 1 end
  -- Boolean corruption from older EX saves → default 1.
  if type(n) == "boolean" then return 1 end
  n = math.floor(n)
  if n < 0 then return 0 end
  if n > 6 then return 6 end
  return n
end

local function saveGet(mod, key)
  if not (mod and mod.save and mod.save.get) then return nil end
  local ok, v = pcall(function() return mod.save:get(key) end)
  if ok then return v end
  return nil
end

local function saveSet(mod, key, value)
  if not (mod and mod.save and mod.save.set) then return false end
  return pcall(function() mod.save:set(key, value) end) == true
end

function Settings.new(mod)
  local self = setmetatable({}, Settings)
  self.mod = mod
  self._migrated = saveGet(mod, "follower_settings_migrated") == true
  return self
end

--- UI control mode: "trainer" | "pokemon"
function Settings:followControl()
  local v
  if Config and type(Config.get) == "function" then
    v = Config.get(self.mod, "follow_control")
  elseif self.mod.options and self.mod.options.get then
    v = self.mod.options:get("follow_control")
  end
  if VALID_UI_CONTROL[v] then return v end
  return "trainer"
end

--- Trainer trail when controlling a Pokémon: boolean
function Settings:trainerTrail()
  local v
  if Config and type(Config.get) == "function" then
    v = Config.get(self.mod, "trainer_trail")
  elseif self.mod.options and self.mod.options.get then
    v = self.mod.options:get("trainer_trail")
  end
  return v == true
end

--- Extra party trailers 0–6
function Settings:followerCount(_game)
  local v
  if Config and type(Config.get) == "function" then
    v = Config.get(self.mod, "follower_count")
  elseif self.mod.options and self.mod.options.get then
    v = self.mod.options:get("follower_count")
  end
  return clampCount(v)
end

--- Map UI settings → engine mode (follow|pokemon|lead_trainer|pack)
--- Wilds Mod Settings are the source of truth; game.save is a mirror.
function Settings:engineMode(game)
  local ui = self:followControl()
  if ui == "trainer" then
    return "follow"
  end
  -- pokemon control
  if self:trainerTrail() then
    return "lead_trainer"
  end
  local n = self:followerCount(game)
  if n > 0 then return "pack" end
  return "pokemon"
end

function Settings:setEngineMode(game, mode)
  if mode == "lead" then mode = "lead_trainer" end
  if not VALID_ENGINE[mode] then return false end
  if game and game.save then
    game.save.pokepcControlMode = mode
  end
  -- Mirror into Wilds option buckets (Gen1Recomp has no mod.options:set).
  local ui, trail
  if mode == "follow" then
    ui, trail = "trainer", false
  elseif mode == "lead_trainer" then
    ui, trail = "pokemon", true
  else
    ui, trail = "pokemon", false
  end
  if Config and type(Config.setOption) == "function" then
    Config.setOption(self.mod, "follow_control", ui, "settings_set_engine_mode", {
      game = game,
    })
    Config.setOption(self.mod, "trainer_trail", trail, "settings_set_engine_mode", {
      game = game,
    })
  end
  return true
end

--- Canonical adapter write for follower_count.
-- Source of truth is the loader/save option bucket (what mod.options:get reads).
-- Gen1Recomp does not expose mod.options:set — use Config.setOption.
function Settings:setFollowerCount(game, n)
  n = clampCount(n)
  if Config and type(Config.setOption) == "function" then
    Config.setOption(self.mod, "follower_count", n, "settings_set_follower_count", {
      game = game,
    })
  end
  if game and game.save then
    game.save.pokepcFollowerCount = n
  end
  return n
end

function Settings:onOptionsChanged(payload)
  if not payload then return end
  local key = payload.key
  if key ~= "follow_control" and key ~= "trainer_trail" and key ~= "follower_count"
      and key ~= "sprite_style" then
    return
  end
  -- Mirror only. Caller (Follower:onOptionsChanged) runs alignSave + syncAll.
  if payload.game then
    self:alignSave(payload.game)
  end
end

--- Import FOLLOWERS_EX / save keys once into Wilds options.
function Settings:migrateFromLegacy(game)
  if self._migrated then return false, "already" end
  local mod = self.mod
  local changed = false

  local function optGet(id, key)
    if not (mod and mod.find) then return nil end
    local hit = mod:find(id)
    if not (hit and hit.options and hit.options.get) then return nil end
    local ok, v = pcall(function() return hit.options:get(key) end)
    if ok then return v end
    return nil
  end

  -- Only fill Wilds keys when unset / still default-ish.
  local currentControl, currentTrail, currentCount
  if Config and type(Config.get) == "function" then
    currentControl = Config.get(mod, "follow_control")
    currentTrail = Config.get(mod, "trainer_trail")
    currentCount = Config.get(mod, "follower_count")
  elseif mod.options and type(mod.options.get) == "function" then
    currentControl = mod.options:get("follow_control")
    currentTrail = mod.options:get("trainer_trail")
    currentCount = mod.options:get("follower_count")
  end

  local exMode = optGet(Constants.FOLLOWERS_EX_ID, "control_mode")
  local exTrail = optGet(Constants.FOLLOWERS_EX_ID, "trainer_follows")
  local exCount = optGet(Constants.FOLLOWERS_EX_ID, "follower_count")

  local function writeOpt(key, value)
    if Config and type(Config.setOption) == "function" then
      return Config.setOption(mod, key, value, "follower_migrate", { game = game })
    end
    return false
  end

  if game and game.save then
    if game.save.pokepcControlMode and (currentControl == nil or currentControl == "trainer") then
      local m = game.save.pokepcControlMode
      if m == "lead" then m = "lead_trainer" end
      if m == "follow" then
        -- keep trainer
      elseif m == "lead_trainer" then
        writeOpt("follow_control", "pokemon")
        writeOpt("trainer_trail", true)
        changed = true
      elseif m == "pokemon" or m == "pack" then
        writeOpt("follow_control", "pokemon")
        writeOpt("trainer_trail", false)
        changed = true
      end
    end
    if game.save.pokepcFollowerCount ~= nil and (currentCount == nil or currentCount == 1) then
      local n = clampCount(game.save.pokepcFollowerCount)
      writeOpt("follower_count", n)
      changed = true
    end
  end

  if exMode == "pokemon" and (currentControl == nil or currentControl == "trainer") then
    writeOpt("follow_control", "pokemon")
    changed = true
  elseif exMode == "trainer" or exMode == "follow" then
    -- already default trainer
  end
  if exTrail == true and currentTrail ~= true then
    writeOpt("trainer_trail", true)
    changed = true
  end
  if exCount ~= nil then
    local n = clampCount(exCount)
    if type(exCount) == "boolean" then n = 1 end
    writeOpt("follower_count", n)
    changed = true
  end

  self._migrated = true
  saveSet(mod, "follower_settings_migrated", true)
  if changed then
    DebugLog.info(mod, "migrated follower control settings from legacy sources")
  end
  return changed, changed and "imported" or "nothing"
end

--- Write engine mirrors from current Wilds options into game.save.
function Settings:alignSave(game)
  if not (game and game.save) then return end
  game.save.pokepcControlMode = self:engineMode(game)
  game.save.pokepcFollowerCount = self:followerCount(game)
end

Settings.clampCount = clampCount
Settings.VALID_ENGINE = VALID_ENGINE

return Settings
