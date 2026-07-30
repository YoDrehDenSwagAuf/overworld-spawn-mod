-- Option schema for Overworld Wild Pokemon.
-- Loaded via mod.options:define() from main.lua and referenced by
-- manifest options_schema for Mod Manager lazy-load.
--
-- Types match Gen1Recomp ManagerState.OPTION_TYPES: toggle, choice, number, text.
-- There is no action/button option type; the Pokemon preview browser is opened
-- via the public ui.options.rows activate hook (see lib/preview_browser.lua).
--
-- All options are live-toggleable through Mod Manager (mod.options_changed).

return {
  {
    key = "enabled",
    label = "Show wild Pokemon in the overworld",
    type = "toggle",
    default = true,
    description = "Spawn visible wild Pokemon in eligible overworld encounter areas.",
  },
  {
    key = "max_spawns",
    label = "MAX SPAWNS",
    type = "choice",
    default = 5,
    choices = {
      { "3", 3 }, { "4", 4 }, { "5", 5 }, { "6", 6 }, { "8", 8 },
    },
    description = "Maximum visible wild Pokemon on the current map at once.",
  },
  {
    key = "spawn_every_steps",
    label = "SPAWN RATE",
    type = "choice",
    default = 8,
    choices = {
      { "FAST", 4 }, { "NORMAL", 8 }, { "SLOW", 14 },
    },
    description = "Player steps between spawn attempts.",
  },
  {
    key = "initial_spawns",
    label = "ON ENTER",
    type = "choice",
    default = 1,
    choices = {
      { "1", 1 }, { "2", 2 }, { "3", 3 }, { "4", 4 }, { "5", 5 },
    },
    description = "How many wild Pokemon to try spawning when entering a map.",
  },
  {
    key = "suppress_random_grass",
    label = "HIDE RANDOM GRASS",
    type = "toggle",
    default = true,
    description = "Suppress vanilla random grass encounters only after visible spawns are ready.",
  },
  {
    key = "sprite_opacity",
    label = "SPRITE FADE",
    type = "choice",
    default = 0.88,
    choices = {
      { "SOLID", 1.0 }, { "TUCKED", 0.88 }, { "FAINT", 0.72 },
    },
    description = "Opacity of overworld wild Pokemon sprites.",
  },
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
    key = "allow_debug_spawn_outside_encounter_areas",
    label = "Allow test spawn outside encounter areas",
    type = "toggle",
    default = false,
    description = "DEBUG: allow Test spawn on any free walkable tile (not only encounter tiles). Dev mode only.",
  },
  {
    key = "show_spawn_tile_overlay",
    label = "Show valid spawn tiles",
    type = "toggle",
    default = false,
    description = "Highlight tiles that the mod considers valid for visible wild Pokemon.",
  },
  {
    key = "debug_logging",
    label = "DEBUG LOG",
    type = "toggle",
    default = false,
    description = "Log map/encounter/tile/spawn diagnostics. Also forced on when Developer mode is enabled.",
  },
  {
    key = "force_test_spawn",
    label = "FORCE TEST SPAWN",
    type = "toggle",
    default = false,
    description = "Force one visible spawn from the map encounter table for diagnosis.",
  },
  {
    key = "preview_filter",
    label = "PREVIEW FILTER",
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
    label = "PREVIEW SEARCH",
    type = "text",
    default = "",
    description = "Search by species name or ID when opening the Pokemon preview browser.",
  },
  {
    key = "preview_map_filter",
    label = "PREVIEW MAP FILTER",
    type = "text",
    default = "",
    description = "Optional map/route id substring filter for the preview browser location list.",
  },
  {
    key = "preview_encounter_kind",
    label = "PREVIEW ENC KIND",
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
}
