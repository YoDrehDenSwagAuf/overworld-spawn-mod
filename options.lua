-- Option schema for Wilds of Kanto (id: overworld_wild_spawns).
-- Loaded via mod.options:define() from main.lua and referenced by
-- manifest options_schema for Mod Manager lazy-load.
--
-- Visible labels must be <= 14 characters (Gen1Recomp truncates longer names).
-- Internal keys are stable so saved settings survive across releases.
--
-- Types match Gen1Recomp ManagerState.OPTION_TYPES: toggle, choice, number, text.
-- There is no action/button option type; the Pokemon preview browser is opened
-- via the public ui.options.rows activate hook (see lib/preview_browser.lua).
--
-- All options are live-toggleable through Mod Manager (mod.options_changed).

return {
  -- ------- Core
  {
    key = "enabled",
    label = "Show Wild Mons",
    type = "toggle",
    default = true,
    description = "Spawn visible wild Pokemon in eligible overworld encounter areas.",
  },
  {
    key = "suppress_random_grass",
    label = "Hide Grass RNG",
    type = "toggle",
    default = true,
    description = "Suppress vanilla random grass encounters only after visible spawns are ready.",
  },
  {
    key = "sprite_style",
    label = "Sprite Style",
    type = "choice",
    default = "auto",
    choices = {
      { "Auto", "auto" },
      { "Followers EX", "followers_ex" },
      { "PokeMMO", "pokemmo" },
      { "Pokedex", "pokedex" },
    },
    description = "Overworld Pokemon sprite source. Auto prefers Followers EX when its sprite provider is available, otherwise Wilds PokeMMO-style sheets, then Pokedex images.",
  },
  {
    key = "spawn_density",
    label = "Spawn Amount",
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
    key = "pokemon_grass_render_mode",
    label = "Grass View",
    type = "choice",
    default = "immersed",
    choices = {
      { "Above", "above" },
      { "Immersed", "immersed" },
    },
    description = "Draw wild Pokemon fully above tall grass, or partially hidden inside it like the player and trainers.",
  },
  {
    key = "enable_idle",
    label = "Idle Mons",
    type = "toggle",
    default = true,
    description = "Allow Idle Look behaviour (stand still, glance around).",
  },
  {
    key = "enable_wander",
    label = "Roam Mons",
    type = "toggle",
    default = true,
    description = "Allow wander behaviour within a connected encounter region.",
  },
  {
    key = "enable_aggressive",
    label = "Chase Mons",
    type = "toggle",
    default = true,
    description = "Allow aggressive Pokemon that spot, chase, and force a battle.",
  },
  {
    key = "enable_hidden",
    label = "Hidden Mons",
    type = "toggle",
    default = true,
    description = "Allow hidden grass (or cave dust) encounter markers with no Pokemon sprite.",
  },

  -- ------- Developer
  {
    key = "dev_mode",
    label = "Dev Mode",
    type = "toggle",
    default = false,
    description = "Show overworld spawn diagnostics and enable the Pokemon preview browser.",
  },
  {
    key = "debug_hud_always_visible",
    label = "Debug HUD",
    type = "toggle",
    default = false,
    description = "Keep the current map spawn diagnostics visible while developer mode is enabled.",
  },
  {
    key = "show_spawn_tile_overlay",
    label = "Spawn Tiles",
    type = "toggle",
    default = false,
    description = "Highlight tiles that the mod considers valid for visible wild Pokemon.",
  },
  {
    key = "show_behavior_overlays",
    label = "Behavior View",
    type = "toggle",
    default = false,
    description = "DEBUG: draw home region, sight line, and behaviour labels in developer mode.",
  },
  {
    key = "allow_debug_spawn_outside_encounter_areas",
    label = "Outside Spawn",
    type = "toggle",
    default = false,
    description = "DEBUG: allow Test spawn on any free walkable tile (not only encounter tiles). Dev mode only.",
  },
  {
    key = "debug_logging",
    label = "Debug Log",
    type = "toggle",
    default = false,
    description = "Write extra Wilds of Kanto diagnostics to the log. Also forced on when Dev Mode is enabled.",
  },
  {
    key = "force_test_spawn",
    label = "Force Spawn",
    type = "toggle",
    default = false,
    description = "Force one visible spawn from the map encounter table for diagnosis.",
  },
  {
    key = "preview_filter",
    label = "Preview Filter",
    type = "choice",
    default = "all",
    choices = {
      { "All", "all" },
      { "Asset OK", "asset_loaded" },
      { "Missing", "asset_missing" },
      { "Ready", "entity_ready" },
      { "Failed", "entity_failed" },
    },
    description = "Filter used when opening the Pokemon preview browser (Dev Mode).",
  },
  {
    key = "preview_search",
    label = "Preview Search",
    type = "text",
    default = "",
    description = "Search by species name or ID when opening the Pokemon preview browser.",
  },
  {
    key = "preview_map_filter",
    label = "Map Filter",
    type = "text",
    default = "",
    description = "Optional map/route id substring filter for the preview browser location list.",
  },
  {
    key = "preview_encounter_kind",
    label = "Encounter Kind",
    type = "choice",
    default = "any",
    choices = {
      { "Any", "any" },
      { "Grass", "grass" },
      { "Water", "water" },
      { "Fishing", "fishing" },
    },
    description = "Encounter-kind filter for preview browser locations.",
  },
}
