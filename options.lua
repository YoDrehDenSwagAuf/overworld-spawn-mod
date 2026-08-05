-- Option schema for Wilds of Kanto (id: overworld_wild_spawns).
-- Loaded via mod.options:define() from main.lua and referenced by
-- manifest options_schema for Mod Manager lazy-load.
--
-- Visible labels must be <= 14 characters (Gen1Recomp truncates longer names).
-- Internal keys are stable so saved settings survive across releases.
--
-- Types match Gen1Recomp ManagerState.OPTION_TYPES: toggle, choice, number, text.
-- There is no action/button option type; Test Spawn opens via the public
-- ui.options.rows activate hook (see lib/preview_browser.lua).
--
-- All options are live-toggleable through Mod Manager (mod.options_changed).

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
    default = "auto",
    choices = {
      { "Auto", "auto" },
      { "Gold Sprites", "gold" },
      { "Followers EX", "followers_ex" },
      { "PokeMMO", "pokemmo" },
      { "Pokedex", "pokedex" },
    },
    description = "Selects the overworld sprite style used by wild Pokémon and your active follower. Water Pokémon use Swimming or Levitates sprites when available.",
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
