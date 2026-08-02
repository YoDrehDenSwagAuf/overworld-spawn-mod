-- Option schema for Wilds of Kanto (id: overworld_wild_spawns).
-- Loaded via mod.options:define() from main.lua and referenced by
-- manifest options_schema for Mod Manager lazy-load.
--
-- Types match Gen1Recomp ManagerState.OPTION_TYPES: toggle, choice, number, text.
-- There is no action/button option type; the Pokemon preview browser is opened
-- via the public ui.options.rows activate hook (see lib/preview_browser.lua).
--
-- All options are live-toggleable through Mod Manager (mod.options_changed).

return {
  -- ------- General
  {
    key = "enabled",
    label = "Show wild Pokemon in the overworld",
    type = "toggle",
    default = true,
    description = "Spawn visible wild Pokemon in eligible overworld encounter areas.",
  },
  {
    key = "suppress_random_grass",
    label = "Hide random grass encounters",
    type = "toggle",
    default = true,
    description = "Suppress vanilla random grass encounters only after visible spawns are ready.",
  },

  -- ------- Spawn density
  {
    key = "spawn_density",
    label = "Spawn density",
    type = "choice",
    default = "normal",
    choices = {
      { "Low", "low" },
      { "Normal", "normal" },
      { "High", "high" },
      { "Very High", "very_high" },
    },
    description = "Target visible Pokemon count relative to encounter area size. Applies on the next map enter or refill.",
  },
  {
    key = "max_visible_pokemon",
    label = "Maximum visible Pokemon",
    type = "choice",
    default = 12,
    choices = {
      { "4", 4 }, { "6", 6 }, { "8", 8 }, { "10", 10 }, { "12", 12 }, { "16", 16 },
    },
    description = "Hard cap on visible wild Pokemon on the current map.",
  },
  {
    key = "min_visible_pokemon",
    label = "Minimum visible Pokemon",
    type = "choice",
    default = 1,
    choices = {
      { "1", 1 }, { "2", 2 }, { "3", 3 },
    },
    description = "Lower bound for the density-based target count when encounter tiles exist.",
  },
  {
    key = "tiles_per_additional_pokemon",
    label = "Tiles per additional Pokemon",
    type = "choice",
    default = 24,
    choices = {
      { "16", 16 }, { "20", 20 }, { "24", 24 }, { "32", 32 }, { "40", 40 },
    },
    description = "Eligible encounter tiles required for each Pokemon above the minimum.",
  },
  {
    key = "spawn_refill_interval",
    label = "Spawn refill interval",
    type = "choice",
    default = 8,
    choices = {
      { "Fast (4)", 4 }, { "Normal (8)", 8 }, { "Slow (14)", 14 },
    },
    description = "Player steps between attempts to refill toward the target count.",
  },
  {
    key = "initial_spawns",
    label = "On enter",
    type = "choice",
    default = 1,
    choices = {
      { "1", 1 }, { "2", 2 }, { "3", 3 }, { "4", 4 }, { "5", 5 },
    },
    description = "How many wild Pokemon to try spawning immediately when entering a map (still capped by density target).",
  },

  -- ------- Behavior
  {
    key = "enable_idle",
    label = "Enable idle Pokemon",
    type = "toggle",
    default = true,
    description = "Allow Idle Look behaviour (stand still, glance around).",
  },
  {
    key = "enable_wander",
    label = "Enable wandering Pokemon",
    type = "toggle",
    default = true,
    description = "Allow wander behaviour within a connected encounter region.",
  },
  {
    key = "enable_aggressive",
    label = "Enable aggressive Pokemon",
    type = "toggle",
    default = true,
    description = "Allow aggressive Pokemon that spot, chase, and force a battle.",
  },
  {
    key = "enable_hidden",
    label = "Enable hidden encounters",
    type = "toggle",
    default = true,
    description = "Allow hidden grass (or cave dust) encounter markers with no Pokemon sprite.",
  },
  {
    key = "aggressive_frequency",
    label = "Aggressive encounter frequency",
    type = "choice",
    default = 1.0,
    choices = {
      { "Rare", 0.5 }, { "Normal", 1.0 }, { "Common", 1.5 },
    },
    description = "Relative weight of aggressive behaviour when selecting a spawn.",
  },

  -- ------- Visuals
  {
    key = "use_animated_overworld_sprites",
    label = "Use animated overworld Pokemon sprites",
    type = "toggle",
    default = true,
    description = "Use directional idle and walking animations from the Pokemon overworld sprite atlas when available.",
  },
  {
    key = "sprite_opacity",
    label = "Sprite fade",
    type = "choice",
    default = 1.0,
    choices = {
      { "Solid", 1.0 }, { "Tucked", 0.88 }, { "Faint", 0.72 },
    },
    description = "Opacity of overworld wild Pokemon sprites.",
  },
  {
    key = "min_sprite_size",
    label = "Minimum Pokemon sprite size",
    type = "choice",
    default = 16,
    choices = {
      { "12", 12 }, { "14", 14 }, { "16", 16 },
    },
    description = "Controls the preferred minimum readable size for legacy sprites. Animated atlas frames keep their native cell size (16x16 / 16x32 / 32x16 / 32x32) and are not squashed to one tile.",
  },
  {
    key = "pokemon_grass_render_mode",
    label = "Pokemon grass rendering",
    type = "choice",
    default = "immersed",
    choices = {
      { "Above grass", "above" },
      { "Partially hidden in grass", "immersed" },
    },
    description = "Choose whether visible wild Pokemon are drawn fully above tall grass or partially hidden inside it like the player and trainers.",
  },
  {
    key = "enable_grass_movement_effects",
    label = "Enable grass movement effects",
    type = "toggle",
    default = true,
    description = "Animate grass shake for hidden encounters and wandering steps when supported.",
  },

  -- ------- Developer
  {
    key = "dev_mode",
    label = "Developer mode",
    type = "toggle",
    default = false,
    description = "Show overworld spawn diagnostics and enable the Pokemon preview browser.",
  },
  {
    key = "debug_hud_always_visible",
    label = "Keep spawn debug HUD visible",
    type = "toggle",
    default = false,
    description = "Keep the current map spawn diagnostics visible while developer mode is enabled.",
  },
  {
    key = "show_spawn_tile_overlay",
    label = "Show valid spawn tiles",
    type = "toggle",
    default = false,
    description = "Highlight tiles that the mod considers valid for visible wild Pokemon.",
  },
  {
    key = "show_behavior_overlays",
    label = "Show behavior overlays",
    type = "toggle",
    default = false,
    description = "DEBUG: draw home region, sight line, and behaviour labels in developer mode.",
  },
  {
    key = "allow_debug_spawn_outside_encounter_areas",
    label = "Allow test spawn outside encounter areas",
    type = "toggle",
    default = false,
    description = "DEBUG: allow Test spawn on any free walkable tile (not only encounter tiles). Dev mode only.",
  },
  {
    key = "debug_logging",
    label = "Debug log",
    type = "toggle",
    default = false,
    description = "Write extra Wilds of Kanto diagnostics to the log. Also forced on when Developer mode is enabled.",
  },
  {
    key = "strict_world_billboard_debug",
    label = "Strict World Billboard Debug",
    type = "toggle",
    default = false,
    description = "DEV: disable emergency/post-voxel Pokemon body draws. Only Dramatic Shape SpriteBillboards may show the body. If that fails the Pokemon stays invisible and the HUD shows the failure reason.",
  },
  {
    key = "strict_magenta_billboard_probe",
    label = "Strict magenta billboard probe",
    type = "toggle",
    default = false,
    description = "DEV: with Strict World Billboard Debug, resolveImage returns a magenta 16x16 probe card to prove the DS texture path.",
  },
  {
    key = "force_test_spawn",
    label = "Force test spawn",
    type = "toggle",
    default = false,
    description = "Force one visible spawn from the map encounter table for diagnosis.",
  },
  {
    key = "preview_filter",
    label = "Preview filter",
    type = "choice",
    default = "all",
    choices = {
      { "ALL", "all" },
      { "ASSET OK", "asset_loaded" },
      { "ASSET MISSING", "asset_missing" },
      { "ENTITY READY", "entity_ready" },
      { "ENTITY FAIL", "entity_failed" },
    },
    description = "Filter used when opening the Pokemon preview browser (Developer mode).",
  },
  {
    key = "preview_search",
    label = "Preview search",
    type = "text",
    default = "",
    description = "Search by species name or ID when opening the Pokemon preview browser.",
  },
  {
    key = "preview_map_filter",
    label = "Preview map filter",
    type = "text",
    default = "",
    description = "Optional map/route id substring filter for the preview browser location list.",
  },
  {
    key = "preview_encounter_kind",
    label = "Preview encounter kind",
    type = "choice",
    default = "any",
    choices = {
      { "ANY", "any" },
      { "GRASS", "grass" },
      { "WATER", "water" },
      { "FISHING", "fishing" },
    },
    description = "Encounter-kind filter for preview browser locations.",
  },

  -- Legacy aliases kept so older saved option files still resolve.
  {
    key = "max_spawns",
    label = "Max spawns (legacy)",
    type = "choice",
    default = 12,
    choices = {
      { "4", 4 }, { "6", 6 }, { "8", 8 }, { "10", 10 }, { "12", 12 }, { "16", 16 },
    },
    description = "Legacy alias of Maximum visible Pokemon.",
  },
  {
    key = "spawn_every_steps",
    label = "Spawn rate (legacy)",
    type = "choice",
    default = 8,
    choices = {
      { "FAST", 4 }, { "NORMAL", 8 }, { "SLOW", 14 },
    },
    description = "Legacy alias of Spawn refill interval.",
  },
}
