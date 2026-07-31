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
  spawn_density = "normal",
  max_spawns = 12, -- legacy key retained; prefer max_visible_pokemon
  max_visible_pokemon = 12,
  min_visible_pokemon = 1,
  tiles_per_additional_pokemon = 24,
  spawn_every_steps = 8,
  spawn_refill_interval = 8, -- alias of spawn_every_steps for docs
  initial_spawns = 1,
  min_player_distance = 3,
  max_player_distance = 16,
  despawn_distance = 22,
  min_spawn_separation = 3,
  wander_every_steps = 0, -- legacy; behaviours own movement now
  suppress_random_grass = true,
  sprite_opacity = 1.0,
  grass_tuck_px = 0, -- engine drawCellBottom provides grass feet overdraw
  show_pokemon_in_grass = true,
  enable_grass_movement_effects = true,
  min_sprite_size = 16,
  min_sprite_visible_height = 16,
  target_sprite_visible_height = 22,
  max_sprite_visible_height = 28,
  enable_idle = true,
  enable_wander = true,
  enable_aggressive = true,
  enable_hidden = true,
  aggressive_frequency = 1.0,
  aggressive_sight_range = 4,
  aggressive_reaction_delay = 0.55,
  aggressive_step_seconds = 0.18,
  wild_step_seconds = 0.28,
  idle_look_min_s = 5,
  idle_look_max_s = 10,
  enable_water_spawns = true,
  enable_cave_spawns = true,
  debug_logging = false,
  force_test_spawn = false,
  dev_mode = false,
  debug_hud_always_visible = false,
  allow_debug_spawn_outside_encounter_areas = false,
  show_spawn_tile_overlay = false,
  show_behavior_overlays = false,
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

function Config.showBehaviorOverlays(mod)
  return Config.devMode(mod)
     and Config.get(mod, "show_behavior_overlays") == true
end

function Config.maxVisible(mod)
  local v = Config.get(mod, "max_visible_pokemon")
  if v == nil then v = Config.get(mod, "max_spawns") end
  return tonumber(v) or Config.DEFAULTS.max_visible_pokemon
end

function Config.minVisible(mod)
  return tonumber(Config.get(mod, "min_visible_pokemon"))
      or Config.DEFAULTS.min_visible_pokemon
end

function Config.tilesPerAdditional(mod)
  return tonumber(Config.get(mod, "tiles_per_additional_pokemon"))
      or Config.DEFAULTS.tiles_per_additional_pokemon
end

function Config.spawnDensity(mod)
  return Config.get(mod, "spawn_density") or "normal"
end

function Config.refillSteps(mod)
  local v = Config.get(mod, "spawn_refill_interval")
  if v == nil then v = Config.get(mod, "spawn_every_steps") end
  return tonumber(v) or Config.DEFAULTS.spawn_every_steps
end

return Config
