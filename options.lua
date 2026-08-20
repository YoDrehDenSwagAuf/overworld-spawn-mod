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
--   Poke Followers EX -> follow_control, trainer_trail, follower_count
--                       (+ Leader via party menu hint)
--   Wilds of Kanto    -> enabled, spawn_density, random_encounters,
--                       water_spawns, cave_spawns, sprite_style, sprite_fade,
--                       town_pokemon, pokemon_grass_render_mode,
--                       wild_silhouettes,
--                       overworld_catching, catch_throw_key, catch_cycle_key,
--                       catch_throw_combo, catch_cycle_combo, catch_hud_size,
--                       enable_idle,
--                       enable_wander, enable_aggressive, enable_hidden,
--                       dev_overlay
--
-- Pokemon size is not a separate option: it is tied to Sprite Style.
--   GSC sprites (followers)   -> Classic (one-tile 16x16 presentation)
--   HGSS sprites (pokemmo)    -> True Size (larger relative species sizes)
--   Pokedex sprites           -> Classic

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
      { "Pokedex", "pokedex" },
    },
    description = "Overworld sprite style for wild Pokemon and followers. Poke Followers / GSC is the built-in default. Sprite size follows the style: GSC sprites use Classic (16x16) presentation, HGSS sprites use True Size (larger relative species sizes). Water Pokemon still use Swimming or Levitates sprites when available.",
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
    description = "Opacity of normal visible wild Pokemon. Solid is fully opaque. Faded uses the classic semi-transparent wild look. Does not affect followers, Town Pokemon, silhouettes, or UI.",
  },
  {
    key = "follow_control",
    label = "Control Mode",
    type = "choice",
    default = "trainer",
    choices = {
      { "Trainer", "trainer" },
      { "Pokemon", "pokemon" },
    },
    description = "Choose whether you control the trainer or the selected Pokemon.",
  },
  {
    key = "trainer_trail",
    label = "Trainer Trail",
    type = "toggle",
    default = false,
    description = "When controlling a Pokemon, the trainer follows behind.",
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
    description = "Number of additional party Pokemon following the active leader.",
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
    description = "Controls how many visible overworld Pokemon can appear. This also affects visible water Pokemon.",
  },
  {
    key = "random_encounters",
    label = "Random Enc",
    type = "toggle",
    default = true,
    description = "Enables or disables classic step-based random encounters. Visible overworld Pokemon remain active.",
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
    description = "How water Pokemon appear: swimming sprites (default), hidden dark circles, tinted silhouettes, classic random encounters only, or fully disabled.",
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
    description = "Cave Pokemon spawn only on tiles the player can reach, or Mixed (~20% atmospheric scenery in inaccessible cave pockets).",
  },
  {
    key = "town_pokemon",
    label = "Town Pokemon",
    type = "toggle",
    default = true,
    description = "Adds peaceful Pokemon to safe towns and interiors. They behave like NPCs and cannot start battles.",
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
    key = "wild_silhouettes",
    label = "Silhouette",
    type = "choice",
    default = "off",
    choices = {
      { "Off", "off" },
      { "Undiscovered", "undiscovered" },
      { "All", "all" },
    },
    description = "Off keeps normal colours. Undiscovered silhouettes species not yet seen in the Pokedex. All silhouettes every encounter-zone wild.",
  },
  {
    key = "overworld_catching",
    label = "OW Catch",
    type = "toggle",
    default = true,
    description = "Enables direct Poke Ball throws at visible wild Pokemon.",
  },
  {
    key = "catch_throw_key",
    label = "Catch Key",
    type = "choice",
    default = "c",
    choices = {
      { "C", "c" },
      { "V", "v" },
      { "F", "f" },
      { "G", "g" },
      { "R", "r" },
      { "T", "t" },
    },
    description = "Desktop keyboard key that charges and throws a Poke Ball. Default C. Does not replace the controller/touch Catch Combo.",
  },
  {
    key = "catch_cycle_key",
    label = "Ball Switch",
    type = "choice",
    default = "q",
    choices = {
      { "Q", "q" },
      { "E", "e" },
      { "R", "r" },
      { "F", "f" },
      { "G", "g" },
      { "T", "t" },
    },
    description = "Desktop keyboard key that cycles the selected Ball. Default Q. If it matches Catch Key, throw wins and this falls back to Q (or E if Catch Key is Q).",
  },
  {
    key = "catch_throw_combo",
    label = "Catch Combo",
    type = "choice",
    default = "b_a",
    choices = {
      { "B + A", "b_a" },
      { "Select + A", "select_a" },
      { "Disabled", "disabled" },
    },
    description = "Controller/touch charge-and-throw combo using logical Game Boy buttons. Default B + A. Desktop Catch Key still works when this is disabled.",
  },
  {
    key = "catch_cycle_combo",
    label = "Switch Combo",
    type = "choice",
    default = "b_dpad",
    choices = {
      { "B + Left/Right", "b_dpad" },
      { "Select + Left/Right", "select_dpad" },
      { "Disabled", "disabled" },
    },
    description = "Controller/touch Ball-switch combo using logical Game Boy buttons. Default B + Left/Right. Desktop Ball Switch still works when this is disabled.",
  },
  {
    key = "catch_hud_size",
    label = "Catch HUD Size",
    type = "number",
    default = 5,
    min = 0,
    max = 10,
    description = "Size of the Poke Ball catching HUD. 0 = hidden, 1 = compact, 5 = default, 10 = large. Hiding the HUD does not disable Overworld Catching.",
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
    description = "Shows each wild Pokemon's behaviour and facing direction above it.",
  },
}
