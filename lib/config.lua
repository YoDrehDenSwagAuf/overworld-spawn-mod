-- Tunables and option helpers for overworld_wild_spawns.
local V = ...

local Config = {}

-- Vanilla Gen 1 encounter slot buckets (out of 256).
Config.ENCOUNTER_BUCKETS = { 51, 102, 141, 166, 191, 216, 229, 242, 253, 256 }

-- Spawn-system defaults (tile distances are walk-grid cells).
Config.DEFAULTS = {
  enabled = true,
  max_spawns = 5,
  spawn_every_steps = 8,
  initial_spawns = 3,
  min_player_distance = 4,
  max_player_distance = 12,
  wander_every_steps = 3,
  suppress_random_grass = true,
  sprite_opacity = 0.88,
  grass_tuck_px = 2,
}

-- Entity lifecycle states for encounter safety.
Config.STATE = {
  AVAILABLE = "available",
  ENCOUNTER_STARTING = "encounter_starting",
  IN_BATTLE = "in_battle",
  REMOVED = "removed",
}

function Config.schema()
  local source = V.mod:read("options.lua")
  if not source then
    error("overworld_wild_spawns: options.lua is missing", 0)
  end
  local chunk, err = load(source, "@" .. V.path .. "/options.lua")
  if not chunk then
    error(("overworld_wild_spawns: options.lua did not compile: %s"):format(tostring(err)), 0)
  end
  return chunk()
end

function Config.defineOptions(mod)
  mod.options:define(Config.schema())
end

function Config.get(mod, key)
  local v = mod.options:get(key)
  if v == nil then return Config.DEFAULTS[key] end
  return v
end

function Config.isEnabled(mod)
  return Config.get(mod, "enabled") == true
end

return Config
