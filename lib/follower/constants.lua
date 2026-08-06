-- Unified follower constants (PR 1).
-- Single global ownership key; no per-module flags.
local Constants = {}

Constants.STATE_KEY = "__wildsUnifiedFollowerState"
-- Control engine owns shouldSpawn/update/onMapEntered when installed.
-- Separate from STATE_KEY so lifecycle and control engine do not fight.
Constants.CONTROL_ENGINE_STATE_KEY = "__wildsFollowerControlEngine"
Constants.FOLLOWER_STATE_VERSION = 1

-- External mod IDs (detection only; no hard dependency).
Constants.FOLLOWERS_EX_ID = "FOLLOWERS_EX"
Constants.POKEPC_ID = "PokePCFollowers_VoxelMerge"
Constants.KNOWN_EXTERNAL_IDS = {
  "FOLLOWERS_EX",
  "PokePCFollowers_VoxelMerge",
  "WILDS_FOLLOWER_SPRITES",
  "FOLLOWER_MODES",
}

-- Engine sprite id used by stock PikachuFollower.
Constants.SPRITE_ID = "SPRITE_PIKACHU"
Constants.ENTITY_ID = "pikachu"

-- Wilds mod.save keys (versioned).
Constants.SAVE = {
  version = "follower_state_version",
  selected_mon = "follower_selected_mon",
  selected_slot = "follower_selected_slot",
  migrated = "follower_selection_migrated",
}

-- Legacy keys to import once (never delete).
Constants.LEGACY = {
  pokepc_selected_mon = "selected_mon",
  pokepc_selected_slot = "selected_slot",
  game_follower_index = "followerPartyIndex",
  game_follower_species = "followerSpecies",
}

Constants.SURFACE = {
  land = "land",
  surfing = "surfing",
  return_to_land = "return_to_land",
}

Constants.OWNER = {
  wilds = "wilds",
  external = "external",
  deferred = "deferred",
}

return Constants
