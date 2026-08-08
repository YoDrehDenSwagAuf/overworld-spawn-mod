-- Option schema for Wilds of Kanto (id: overworld_wild_spawns).
-- Loaded via mod.options:define() from main.lua and referenced by
-- manifest options_schema for Mod Manager lazy-load.
--
-- Visible labels for Gen1 ListMenu entries must be <= 14 characters
-- (Gen1Recomp truncates longer names). Mod Settings choice labels may be
-- longer when clarity requires it (e.g. "Poke Followers / GSC").
-- Internal keys are stable so saved settings survive across releases.
--
-- Types match Gen1Recomp ManagerState.OPTION_TYPES: toggle, choice, number, text.
-- There is no action/button option type; Test Spawn opens via the public
-- ui.options.rows activate hook (see lib/preview_browser.lua).
--
-- All options are live-toggleable through Mod Manager (mod.options_changed).
--
-- UI submenu mapping (both write the SAME mod.options keys):
--   Poke Followers EX → follow_control, trainer_trail, follower_count
--                       (+ Leader via party menu hint)
--   Wilds of Kanto    → enabled, spawn_density, random_encounters,
--                       water_spawns, cave_spawns, sprite_style, sprite_fade,
--                       town_pokemon, pokemon_grass_render_mode,
--                       enable_idle, enable_wander, enable_aggressive,
--                       enable_hidden, dev_overlay

return {
  -- ------- Core gameplay
  {
    key = "enabled",
    label = "Show Wild Mons",
    type = "toggle",
    default = true,
    description = "Spawn visible wild Pokemon in eligible overworld encounter areas.",
  },
  {
    key = "sprite_style",
    label = "Sprite Style",
    type = "choice",
    default = "followers",
    choices = {
      { "Poke Followers / GSC", "followers" },
      { "HGSS / PokeMMO", "pokemmo" },
      { "Pokédex", "pokedex" },
    },
    description = "Overworld sprite style for wild Pokémon and followers. Poke Followers / GSC is the built-in default. Water Pokémon still use Swimming or Levitates sprites when available.",
  },
  {
    key = "sprite_fade",
    label = "Sprite Fade",
    type = "choice",
    default = "solid",
    choices = {
      { "Solid", "solid" },
      { "Faded", "faded" },
    },
    description = "Opacity of normal visible wild Pokémon. Solid is fully opaque. Faded uses the classic semi-transparent wild look. Does not affect followers, Town Pokémon, silhouettes, or UI.",
  },
  {
    key = "follow_control",
    label = "Control Mode",
    type = "choice",
    default = "trainer",
    choices = {
      { "Trainer", "trainer" },
      { "Pokémon", "pokemon" },
    },
    description = "Choose whether you control the trainer or the selected Pokémon.",
  },
  {
    key = "trainer_trail",
    label = "Trainer Trail",
    type = "toggle",
    default = false,
    description = "When controlling a Pokémon, the trainer follows behind.",
  },
  {
    key = "follower_count",
    label = "Followers",
    type = "choice",
    default = 1,
    choices = {
      { "0", 0 },
      { "1", 1 },
      { "2", 2 },
      { "3", 3 },
      { "4", 4 },
      { "5", 5 },
      { "6", 6 },
    },
    description = "Number of additional party Pokémon following the active leader.",
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
    description = "Controls how many visible overworld Pokémon can appear. This also affects visible water Pokémon.",
  },
  {
    key = "random_encounters",
    label = "Random Enc",
    type = "toggle",
    default = true,
    description = "Enables or disables classic step-based random encounters. Visible overworld Pokémon remain active.",
  },
  {
    key = "water_spawns",
    label = "Water Mons",
    type = "choice",
    default = "swimming_sprites",
    choices = {
      { "Swim Sprites", "swimming_sprites" },
      { "Hid Silhouette", "hidden_silhouettes" },
      { "Silhouettes", "silhouettes" },
      { "Classic Enc", "classic_encounters" },
      { "Disabled", "disabled" },
    },
    description = "How water Pokémon appear: swimming sprites (default), hidden dark circles, tinted silhouettes, classic random encounters only, or fully disabled.",
  },
  {
    key = "cave_spawns",
    label = "Cave Spawns",
    type = "choice",
    default = "reachable",
    choices = {
      { "Reachable Only", "reachable" },
      { "Mixed", "mixed" },
    },
    description = "Cave Pokémon spawn only on tiles the player can reach, or Mixed (~20% atmospheric scenery in inaccessible cave pockets).",
  },
  {
    key = "town_pokemon",
    label = "Town Pokémon",
    type = "toggle",
    default = true,
    description = "Adds peaceful Pokémon to safe towns and interiors. They behave like NPCs and cannot start battles.",
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

  -- ------- Developer (only Dev Overlay + Test Spawn)
  {
    key = "dev_overlay",
    label = "Dev Overlay",
    type = "toggle",
    default = false,
    description = "Shows each wild Pokémon's behaviour and facing direction above it.",
  },
}
