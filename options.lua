-- Option schema for Overworld Wild Pokemon.
-- Loaded via mod.options:define() from main.lua and referenced by
-- manifest options_schema for Mod Manager lazy-load.
--
-- Types match Gen1Recomp ManagerState.OPTION_TYPES: toggle, choice, number, text.

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
    key = "debug_logging",
    label = "DEBUG LOG",
    type = "toggle",
    default = false,
    description = "Log map/encounter/tile/spawn diagnostics. Pokedex status is diag-only.",
  },
  {
    key = "force_test_spawn",
    label = "FORCE TEST SPAWN",
    type = "toggle",
    default = false,
    description = "Force one visible spawn from the map encounter table for diagnosis.",
  },
}
