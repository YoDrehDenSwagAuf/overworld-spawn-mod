-- Tunables and option helpers for overworld_wild_spawns.
local V = ...

local Config = {}

-- Vanilla Gen 1 encounter slot buckets (out of 256).
Config.ENCOUNTER_BUCKETS = { 51, 102, 141, 166, 191, 216, 229, 242, 253, 256 }

-- Spawn-system defaults (tile distances are walk-grid cells).
-- min/max distances are soft constraints: pickers expand the search when a
-- small map would otherwise reject every tile.
Config.DEFAULTS = {
  enabled = true,
  max_spawns = 5,
  spawn_every_steps = 8,
  initial_spawns = 1, -- minimal vertical path: one standing spawn first
  min_player_distance = 4,
  max_player_distance = 12,
  wander_every_steps = 0, -- off until standing spawn path is proven
  suppress_random_grass = true,
  sprite_opacity = 0.88,
  grass_tuck_px = 2,
  debug_logging = false,
  force_test_spawn = false,
  dev_mode = false,
  debug_hud_always_visible = false,
  allow_debug_spawn_outside_encounter_areas = false,
  show_spawn_tile_overlay = false,
  preview_filter = "all",
  preview_search = "",
  preview_map_filter = "",
  preview_encounter_kind = "any",
}

-- Entity lifecycle states for encounter safety.
Config.STATE = {
  AVAILABLE = "available",
  ENCOUNTER_STARTING = "encounter_starting",
  IN_BATTLE = "in_battle",
  REMOVED = "removed",
}

-- Spawn-system / renderer status strings for the debug HUD.
Config.STATUS = {
  DISABLED = "DISABLED",
  INITIALIZING = "INITIALIZING",
  NO_ENCOUNTER_DATA = "NO_ENCOUNTER_DATA",
  NO_ELIGIBLE_TILES = "NO_ELIGIBLE_TILES",
  ASSETS_LOADING = "ASSETS_LOADING",
  ASSET_ERROR = "ASSET_ERROR",
  NO_RENDERER = "NO_RENDERER",
  READY = "READY",
  SPAWNING = "SPAWNING",
  FALLBACK_TO_VANILLA = "FALLBACK_TO_VANILLA",
  ERROR = "ERROR",
  NOT_AVAILABLE = "NOT AVAILABLE",
}

Config.HUD_SHOW_SECONDS = 8

function Config.schema()
  local source = V.mod:read("options.lua")
  if not source then
    error("overworld_wild_spawns: options.lua is missing", 0)
  end
  local loadcode = loadstring or load
  local chunk, err = loadcode(source, "@" .. V.path .. "/options.lua")
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

function Config.devMode(mod)
  return Config.get(mod, "dev_mode") == true
end

function Config.debug(mod)
  -- Developer mode forces structured diagnostics logging.
  if Config.devMode(mod) then return true end
  return Config.get(mod, "debug_logging") == true
end

function Config.hudAlwaysVisible(mod)
  return Config.devMode(mod) and Config.get(mod, "debug_hud_always_visible") == true
end

function Config.allowOutsideEncounter(mod)
  return Config.devMode(mod)
     and Config.get(mod, "allow_debug_spawn_outside_encounter_areas") == true
end

function Config.showSpawnTileOverlay(mod)
  return Config.devMode(mod)
     and Config.get(mod, "show_spawn_tile_overlay") == true
end

return Config
