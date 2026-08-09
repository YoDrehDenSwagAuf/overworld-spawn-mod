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
  sprite_opacity = 1.0, -- legacy numeric; prefer sprite_fade
  sprite_fade = "solid", -- solid | faded (public Sprite Fade)
  sprite_fade_alpha = 0.72, -- Faded look (pre-1.0.0 "Faint")
  -- sprite_color removed: sheets always render true-color (24-bit PNG packs
  -- must never be force-baked to the 4-shade DMG ramp).
  sprite_style = "followers",
  -- Follower control (built-in; replaces FOLLOWERS_EX options).
  follow_control = "trainer", -- trainer | pokemon
  trainer_trail = false,
  follower_count = 1, -- 0–6 extra party trailers
  -- Peaceful ambient NPCs in towns / safe interiors (not wild battles).
  town_pokemon = true,
  -- Legacy key kept for save migration only (Mon Sprites toggle).
  use_animated_overworld_sprites = true,
  pokemon_grass_render_mode = "immersed",
  grass_tuck_px = 0, -- engine drawCellBottom provides grass feet overdraw
  show_pokemon_in_grass = true, -- legacy alias → immersed/above
  enable_grass_movement_effects = true,
  min_sprite_size = 16,
  min_sprite_visible_height = 14,
  target_sprite_visible_height = 16,
  max_sprite_visible_height = 16, -- hard one-tile cap (Gen1Recomp CELL)
  grass_occlusion_px = 6,
  -- Dramatic Shape tall-grass south-row clearance for pokemon_grass_render_mode=above.
  -- Applied as pose visualY lift only (lift = e.py - visualY); does not change e.py.
  grass_above_lift_px = 8,
  enable_idle = true,
  enable_wander = true,
  enable_aggressive = true,
  enable_hidden = true,
  -- Classic step-based random encounters (grass / cave / water).
  -- Public label "Random Enc"; independent of visible overworld spawns.
  random_encounters = true,
  aggressive_frequency = 1.0,
  aggressive_sight_range = 4,
  aggressive_reaction_delay = 0.55,
  aggressive_step_seconds = 0.18,
  wild_step_seconds = 0.28,
  idle_look_min_s = 5,
  idle_look_max_s = 10,
  enable_water_spawns = true, -- legacy internal alias (spawn-enabled modes)
  -- Public "Water Mons" choice: swimming_sprites | hidden_silhouettes |
  -- silhouettes | classic_encounters | disabled. Legacy bool true/false migrates.
  water_spawns = "swimming_sprites",
  -- Water spawn zones (tile distance from walkable land). Internal only.
  water_near_shore_max = 2,
  water_mid_water_max = 5,
  water_deep_min = 6,
  -- Share of visible water spawns that may be WATER_AGGRESSIVE (0–1).
  water_aggressive_chance = 0.15,
  -- Land→water chase: land mon must be ≤ this many tiles from water;
  -- player must be ≤ this many tiles from shore while surfing.
  land_water_chase_shore_max = 1,
  land_water_chase_player_max = 5,
  water_aggressive_sight_range = 5,
  enable_cave_spawns = true, -- internal master; public choice is cave_spawns
  -- Public "Cave Spawns": reachable (default) | mixed (~20% scenery).
  cave_spawns = "reachable",
  -- Public developer overlay (behaviour + facing labels).
  dev_overlay = false,
  -- Internal-only (no longer public options). Kept as defaults for code paths.
  debug_logging = false,
  force_test_spawn = false,
  -- Legacy keys retained for one-shot migration into dev_overlay.
  dev_mode = false,
  debug_hud_always_visible = false,
  allow_debug_spawn_outside_encounter_areas = false,
  show_spawn_tile_overlay = false,
  show_behavior_overlays = false,
  preview_filter = "all",
  preview_search = "",
  preview_map_filter = "",
  preview_encounter_kind = "any",
  strict_world_billboard_debug = false,
  strict_magenta_billboard_probe = false,
  -- Water spacing (Manhattan tiles). Scaled by Spawn Amount.
  water_min_spacing_low = 5,
  water_min_spacing_normal = 4,
  water_min_spacing_high = 3,
  water_min_spacing_very_high = 3,
  -- Water density scale vs Normal.
  water_density_low = 0.60,
  water_density_normal = 1.0,
  water_density_high = 1.40,
  water_density_very_high = 1.60,
  max_water_mons = 6, -- soft global cap for visible water mons
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

-- Public Dev Overlay toggle. Migrates legacy debug / Dev Mode when unset.
function Config.devOverlay(mod)
  local raw, present = Config.peekSavedOption(mod, "dev_overlay")
  if present then
    return raw == true
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local v = mod.options:get("dev_overlay")
    if v ~= nil then return v == true end
  end
  -- One-shot legacy: general debug / Dev Mode ON → Dev Overlay ON.
  local legacyDebug, legacyPresent = Config.peekSavedOption(mod, "debug")
  if legacyPresent and legacyDebug == true then return true end
  local legacyDev, legacyDevPresent = Config.peekSavedOption(mod, "dev_mode")
  if legacyDevPresent and legacyDev == true then return true end
  if mod and mod.options and type(mod.options.get) == "function" then
    if mod.options:get("dev_mode") == true then return true end
  end
  return Config.DEFAULTS.dev_overlay == true
end

-- Back-compat alias: older call sites treated "dev mode" as developer tools.
-- Now maps onto Dev Overlay (no separate public Dev Mode option).
function Config.devMode(mod)
  return Config.devOverlay(mod)
end

function Config.debug(mod)
  -- Dev Overlay forces structured diagnostics logging.
  if Config.devOverlay(mod) then return true end
  return Config.get(mod, "debug_logging") == true
end

function Config.hudAlwaysVisible(mod)
  -- Detail HUD may show while Dev Overlay is on (no separate public toggle).
  return Config.devOverlay(mod)
end

function Config.allowOutsideEncounter(mod)
  -- Outside-encounter test spawn no longer has a public toggle.
  return false
end

function Config.showSpawnTileOverlay(mod)
  return false
end

function Config.showBehaviorOverlays(mod)
  -- Replaced by Dev Overlay world labels.
  return Config.devOverlay(mod)
end

function Config.migrateDevOverlayOption(mod)
  local on = Config.devOverlay(mod)
  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    if bucket[mod.id].dev_overlay == nil then
      bucket[mod.id].dev_overlay = on
    end
    -- Drop obsolete public developer keys (ignore on load; no crash).
    bucket[mod.id].dev_mode = nil
    bucket[mod.id].debug_hud_always_visible = nil
    bucket[mod.id].show_spawn_tile_overlay = nil
    bucket[mod.id].show_behavior_overlays = nil
    bucket[mod.id].allow_debug_spawn_outside_encounter_areas = nil
    bucket[mod.id].debug_logging = nil
    bucket[mod.id].force_test_spawn = nil
    bucket[mod.id].preview_filter = nil
    bucket[mod.id].preview_search = nil
    bucket[mod.id].preview_map_filter = nil
    bucket[mod.id].preview_encounter_kind = nil
    bucket[mod.id].debug = nil
  end
  local world = mod.world
  local game = world and world.game
  if game and game.save and game.save.options then
    game.save.options.modOptions = game.save.options.modOptions or {}
    write(game.save.options.modOptions)
  end
  if game and game.mods then
    if game.mods.modOptions then write(game.mods.modOptions) end
    if game.mods.loader and game.mods.loader.modOptions then
      write(game.mods.loader.modOptions)
    end
  end
  return on
end

-- Manhattan spacing between visible water Pokémon (tiles).
function Config.waterMinSpacing(mod)
  local amount = Config.spawnAmount(mod)
  if amount == "low" then
    return tonumber(Config.DEFAULTS.water_min_spacing_low) or 5
  elseif amount == "high" then
    return tonumber(Config.DEFAULTS.water_min_spacing_high) or 3
  elseif amount == "very_high" then
    return tonumber(Config.DEFAULTS.water_min_spacing_very_high) or 3
  end
  return tonumber(Config.DEFAULTS.water_min_spacing_normal) or 4
end

-- Moderate Spawn Amount scale for water targets.
function Config.waterDensityFactor(mod)
  local amount = Config.spawnAmount(mod)
  if amount == "low" then
    return tonumber(Config.DEFAULTS.water_density_low) or 0.60
  elseif amount == "high" then
    return tonumber(Config.DEFAULTS.water_density_high) or 1.40
  elseif amount == "very_high" then
    return tonumber(Config.DEFAULTS.water_density_very_high) or 1.60
  end
  return tonumber(Config.DEFAULTS.water_density_normal) or 1.0
end

-- Public Sprite Style choices (Mod Settings). Internal providers may differ
-- (e.g. visible "followers" → provider "followers_ex").
local VALID_SPRITE_STYLES = {
  pokemmo = true,
  followers = true,
  pokedex = true,
}

local SPRITE_STYLE_CONFIRM = {
  followers = "POKE FOLLOWERS / GSC",
  pokemmo = "HGSS / POKEMMO",
  pokedex = "POKEDEX",
}

-- Migrate legacy / unknown save values onto the public three-choice set.
-- Internal provider ids (followers_ex / poke_followers) map to public "followers".
function Config.normalizeSpriteStyle(value)
  if value == true or value == "true" or value == "on" or value == "ON" then
    return "pokemmo"
  end
  if value == false or value == "false" or value == "off" or value == "OFF" then
    return "pokedex"
  end
  if type(value) ~= "string" then
    return "followers"
  end
  local v = value
  if v == "followers_ex" or v == "poke_followers" then
    return "followers"
  end
  if v == "auto" or v == "gold" or v == "crystal" then
    return "pokemmo"
  end
  if VALID_SPRITE_STYLES[v] then
    return v
  end
  return "followers"
end

function Config.peekSavedOption(mod, key)
  if not mod then return nil, false end
  local buckets = {}
  local world = mod.world
  local game = world and world.game
  if game and game.save and game.save.options and game.save.options.modOptions then
    buckets[#buckets + 1] = game.save.options.modOptions[mod.id]
  end
  if game and game.mods then
    if game.mods.modOptions then
      buckets[#buckets + 1] = game.mods.modOptions[mod.id]
    end
    if game.mods.loader and game.mods.loader.modOptions then
      buckets[#buckets + 1] = game.mods.loader.modOptions[mod.id]
    end
  end
  -- Unit-test / harness path: options table may expose raw values via get only.
  for i = 1, #buckets do
    local b = buckets[i]
    if type(b) == "table" and b[key] ~= nil then
      return b[key], true
    end
  end
  return nil, false
end

-- Preferred public style selector. Migrates legacy Mon Sprites boolean:
--   true  -> pokemmo (was auto)
--   false -> pokedex
-- Legacy sprite_style strings (auto/gold/crystal/followers_ex) normalize onto
-- the public three-choice set.
function Config.spriteStyle(mod)
  local rawStyle, stylePresent = Config.peekSavedOption(mod, "sprite_style")
  if stylePresent and type(rawStyle) == "string" then
    return Config.normalizeSpriteStyle(rawStyle)
  end

  local v = nil
  if mod and mod.options and type(mod.options.get) == "function" then
    v = mod.options:get("sprite_style")
  end
  if type(v) == "string" then
    local normalized = Config.normalizeSpriteStyle(v)
    -- Schema default is "followers". If the save never stored sprite_style but
    -- still has legacy Mon Sprites = off, prefer pokedex once.
    if (v == "pokemmo" or v == "auto" or v == "followers") and not stylePresent then
      local legacyRaw, legacyPresent = Config.peekSavedOption(mod, "use_animated_overworld_sprites")
      if legacyPresent and legacyRaw == false then
        return "pokedex"
      end
      if not legacyPresent then
        local legacy = mod.options:get("use_animated_overworld_sprites")
        -- Only treat an explicit false from options storage; schema default true
        -- must not force pokedex.
        if legacy == false then
          return "pokedex"
        end
      end
    end
    return normalized
  end

  local legacyRaw, legacyPresent = Config.peekSavedOption(mod, "use_animated_overworld_sprites")
  if legacyPresent and legacyRaw == false then
    return "pokedex"
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    if mod.options:get("use_animated_overworld_sprites") == false then
      return "pokedex"
    end
  end
  return "followers"
end

function Config.migrateSpriteStyleOption(mod)
  local style = Config.spriteStyle(mod)
  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    local current = bucket[mod.id].sprite_style
    -- Persist the normalized public value whenever missing or legacy.
    if current == nil or Config.normalizeSpriteStyle(current) ~= current then
      bucket[mod.id].sprite_style = style
    end
  end
  local world = mod.world
  local game = world and world.game
  if game and game.save and game.save.options then
    game.save.options.modOptions = game.save.options.modOptions or {}
    write(game.save.options.modOptions)
  end
  if game and game.mods then
    if game.mods.modOptions then write(game.mods.modOptions) end
    if game.mods.loader and game.mods.loader.modOptions then
      write(game.mods.loader.modOptions)
    end
  end
  return style
end

-- Compatibility: true when style is not the static Pokedex path.
function Config.useAnimatedOverworldSprites(mod)
  return Config.spriteStyle(mod) ~= "pokedex"
end

-- Gen1Recomp exposes mod.options:define / :get only — there is NO
-- mod.options:set on the public mod API (see Loader._api). Mod Manager
-- writes through ManagerState:setOption → loader.modOptions + emit
-- mod.options_changed. In-game menus must mirror that bucket write.
local function writeOptionBucket(mod, game, key, value)
  if not (mod and mod.id) then return false end
  local function write(bucket)
    if type(bucket) ~= "table" then return false end
    bucket[mod.id] = bucket[mod.id] or {}
    bucket[mod.id][key] = value
    return true
  end
  local wrote = false
  if game and game.save then
    game.save.options = game.save.options or {}
    game.save.options.modOptions = game.save.options.modOptions or {}
    if write(game.save.options.modOptions) then wrote = true end
  end
  if game and game.mods then
    -- loader.modOptions is what mod.options:get reads.
    game.mods.modOptions = game.mods.modOptions or {}
    if write(game.mods.modOptions) then wrote = true end
    if game.mods.loader then
      game.mods.loader.modOptions = game.mods.loader.modOptions or {}
      if write(game.mods.loader.modOptions) then wrote = true end
    end
  end
  if game and type(game.writeOptions) == "function" then
    pcall(game.writeOptions, game)
  end
  -- Optional: some forks may expose options:set. Prefer bucket write above.
  if mod and mod.options and type(mod.options.set) == "function" then
    local ok = pcall(function() mod.options:set(key, value) end)
    if ok then wrote = true end
  end
  return wrote
end

local function resolveGame(mod, opts)
  opts = opts or {}
  if opts.game then return opts.game end
  if mod and mod.world then return mod.world.game end
  return nil
end

--- Canonical programmatic option writer for non-Mod-Manager UIs.
-- Writes the same loader/save buckets Mod Manager uses, then optionally
-- invokes a shared onChanged callback (main.lua handleOptionsChanged).
-- Does NOT emit engine event `mod.options_changed` (mods cannot forge it).
-- opts: { game=, onChanged=, source= }
function Config.setOption(mod, key, value, source, opts)
  opts = opts or {}
  if not (mod and type(key) == "string" and key ~= "") then
    return false, "invalid setOption args"
  end
  local game = resolveGame(mod, opts)
  local wrote = writeOptionBucket(mod, game, key, value)
  local payload = {
    mod = mod.id,
    key = key,
    value = value,
    source = source or opts.source or "config_set_option",
    game = game,
  }
  if type(opts.onChanged) == "function" then
    pcall(opts.onChanged, payload)
  end
  return wrote, payload
end

-- Test / internal access to the bucket writer.
Config._writeOptionBucket = writeOptionBucket

local function confirmText(game, mod, message)
  if not message or not game or not mod then return end
  if mod.ui and mod.ui.TextBox and game.stack then
    pcall(function()
      game.stack:push(mod.ui.TextBox.new(game, message))
    end)
  end
end

-- Central setter used by Start Menu and any non-Mod-Manager UI path.
-- Mod Settings already persist sprite_style via the engine; both share this key.
-- opts: { game=, logic=, render=, confirm=, message= }
function Config.setSpriteStyle(mod, value, source, opts)
  opts = opts or {}
  value = Config.normalizeSpriteStyle(value)
  if not VALID_SPRITE_STYLES[value] then
    return false, "invalid sprite_style: " .. tostring(value)
  end

  local game = resolveGame(mod, opts)
  writeOptionBucket(mod, game, "sprite_style", value)

  local render = opts.render
  local logic = opts.logic
  if (not render or not logic) and mod and mod.exports then
    render = render or mod.exports.render
    logic = logic or mod.exports.logic
  end
  local refreshed = 0
  if render and logic and type(render.refreshAllEntitySprites) == "function" then
    if type(render.invalidateAssetCache) == "function" then
      pcall(render.invalidateAssetCache, render)
    end
    local ok, n = pcall(render.refreshAllEntitySprites, render, logic, game)
    if ok and type(n) == "number" then refreshed = n end
  end

  local confirmMsg = opts.message
  if not confirmMsg and opts.confirm ~= false then
    confirmMsg = "SPRITES: " .. (SPRITE_STYLE_CONFIRM[value] or value:upper())
  end
  confirmText(game, mod, confirmMsg)

  if source and mod and mod.log and type(mod.log.info) == "function" then
    pcall(mod.log.info, mod.log,
      "sprite_style set to %s via %s (refreshed=%d)",
      value, tostring(source), refreshed)
  end

  return true, value, refreshed
end

Config.VALID_SPRITE_STYLES = VALID_SPRITE_STYLES
Config.SPRITE_STYLE_CONFIRM = SPRITE_STYLE_CONFIRM

local VALID_SPAWN_AMOUNTS = {
  low = true,
  normal = true,
  high = true,
  very_high = true,
}

local SPAWN_AMOUNT_CONFIRM = {
  low = "LOW",
  normal = "NORMAL",
  high = "HIGH",
  very_high = "VERY HIGH",
}

Config.VALID_SPAWN_AMOUNTS = VALID_SPAWN_AMOUNTS
Config.SPAWN_AMOUNT_CONFIRM = SPAWN_AMOUNT_CONFIRM

function Config.spawnAmount(mod)
  local raw, present = Config.peekSavedOption(mod, "spawn_density")
  if present and type(raw) == "string" and VALID_SPAWN_AMOUNTS[raw] then
    return raw
  end
  local v = Config.get(mod, "spawn_density")
  if type(v) == "string" and VALID_SPAWN_AMOUNTS[v] then
    return v
  end
  return "normal"
end

-- Classic step-based random encounters (grass / cave / water / indoor).
-- Independent of visible overworld Pokémon and Water Mons.
function Config.randomEncountersEnabled(mod)
  local raw, present = Config.peekSavedOption(mod, "random_encounters")
  if present then
    return raw == true
  end
  -- One-shot migration from grass_encounters choice.
  local legacy, legPresent = Config.peekSavedOption(mod, "grass_encounters")
  if legPresent and type(legacy) == "string" then
    if legacy == "hidden" then return false end
    if legacy == "classic" or legacy == "both" then return true end
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local v = mod.options:get("random_encounters")
    if v ~= nil then return v == true end
    local g = mod.options:get("grass_encounters")
    if type(g) == "string" then
      if g == "hidden" then return false end
      if g == "classic" or g == "both" then return true end
    end
  end
  if Config.DEFAULTS.random_encounters == false then return false end
  return true
end

function Config.migrateRandomEncountersOption(mod)
  local on = Config.randomEncountersEnabled(mod)
  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    if bucket[mod.id].random_encounters == nil then
      bucket[mod.id].random_encounters = on
    end
    -- Drop obsolete choice key once migrated.
    bucket[mod.id].grass_encounters = nil
    if bucket[mod.id].water_spawns == nil then
      bucket[mod.id].water_spawns = Config.waterDisplayMode(mod)
    end
  end
  local world = mod.world
  local game = world and world.game
  if game and game.save and game.save.options then
    game.save.options.modOptions = game.save.options.modOptions or {}
    write(game.save.options.modOptions)
  end
  if game and game.mods then
    if game.mods.modOptions then write(game.mods.modOptions) end
    if game.mods.loader and game.mods.loader.modOptions then
      write(game.mods.loader.modOptions)
    end
  end
  return on
end

-- Back-compat alias used during transition.
Config.migrateGrassEncountersOption = Config.migrateRandomEncountersOption

local VALID_WATER_MODES = {
  swimming_sprites = true,
  hidden_silhouettes = true,
  silhouettes = true,
  classic_encounters = true,
  disabled = true,
}

local WATER_MODE_CONFIRM = {
  swimming_sprites = "SWIM SPRITES",
  hidden_silhouettes = "HID SILHOUETTE",
  silhouettes = "SILHOUETTES",
  classic_encounters = "CLASSIC ENC",
  disabled = "DISABLED",
}

Config.VALID_WATER_MODES = VALID_WATER_MODES
Config.WATER_MODE_CONFIRM = WATER_MODE_CONFIRM

local function coerceWaterMode(value)
  if value == true or value == "true" or value == "on" or value == "ON" then
    return "swimming_sprites"
  end
  if value == false or value == "false" or value == "off" or value == "OFF" then
    -- Legacy OFF: no visible water mons; classic rolls still followed Random Enc.
    return "classic_encounters"
  end
  if type(value) == "string" and VALID_WATER_MODES[value] then
    return value
  end
  return nil
end

-- Public Water Mons choice (string mode). Migrates legacy boolean saves.
function Config.waterDisplayMode(mod)
  local raw, present = Config.peekSavedOption(mod, "water_spawns")
  if present then
    local mode = coerceWaterMode(raw)
    if mode then return mode end
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local v = mod.options:get("water_spawns")
    local mode = coerceWaterMode(v)
    if mode then return mode end
    local legacy = mod.options:get("enable_water_spawns")
    if legacy ~= nil then
      return coerceWaterMode(legacy) or "swimming_sprites"
    end
  end
  local def = Config.DEFAULTS.water_spawns
  return coerceWaterMode(def) or "swimming_sprites"
end

function Config.migrateWaterDisplayMode(mod)
  local mode = Config.waterDisplayMode(mod)
  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    local cur = bucket[mod.id].water_spawns
    if cur == true or cur == false or cur == nil
       or (type(cur) == "string" and not VALID_WATER_MODES[cur]) then
      bucket[mod.id].water_spawns = mode
    end
    bucket[mod.id].enable_water_spawns = (mode == "swimming_sprites"
      or mode == "hidden_silhouettes"
      or mode == "silhouettes")
  end
  local world = mod.world
  local game = world and world.game
  if game and game.save and game.save.options then
    game.save.options.modOptions = game.save.options.modOptions or {}
    write(game.save.options.modOptions)
  end
  if game and game.mods then
    if game.mods.modOptions then write(game.mods.modOptions) end
    if game.mods.loader and game.mods.loader.modOptions then
      write(game.mods.loader.modOptions)
    end
  end
  return mode
end

-- True when visible water overworld entities may spawn
-- (Swim Sprites / Hidden Silhouettes / Silhouettes).
function Config.waterMons(mod)
  local mode = Config.waterDisplayMode(mod)
  return mode == "swimming_sprites"
    or mode == "hidden_silhouettes"
    or mode == "silhouettes"
end

function Config.waterClassicEncountersForced(mod)
  return Config.waterDisplayMode(mod) == "classic_encounters"
end

function Config.waterEncountersDisabled(mod)
  return Config.waterDisplayMode(mod) == "disabled"
end

function Config.maxWaterMons(mod)
  return tonumber(Config.get(mod, "max_water_mons"))
      or Config.DEFAULTS.max_water_mons or 12
end

-- Central setter for Spawn Amount (Start Menu). Same key as legacy Mod Settings.
-- opts: { game=, logic=, confirm=, message= }
function Config.setSpawnAmount(mod, value, source, opts)
  opts = opts or {}
  value = tostring(value or "")
  if not VALID_SPAWN_AMOUNTS[value] then
    return false, "invalid spawn_density: " .. value
  end

  local game = resolveGame(mod, opts)
  writeOptionBucket(mod, game, "spawn_density", value)

  local logic = opts.logic
  if not logic and mod and mod.exports then
    logic = mod.exports.logic
  end
  if logic and type(logic.applySpawnAmount) == "function" then
    pcall(logic.applySpawnAmount, logic, value, source)
  elseif logic and type(logic.onOptionsChanged) == "function" then
    pcall(logic.onOptionsChanged, logic, {
      mod = mod.id, key = "spawn_density", value = value, source = source,
    })
  end

  local confirmMsg = opts.message
  if not confirmMsg and opts.confirm ~= false then
    confirmMsg = "SPAWN: " .. (SPAWN_AMOUNT_CONFIRM[value] or value:upper())
  end
  confirmText(game, mod, confirmMsg)

  if source and mod and mod.log and type(mod.log.info) == "function" then
    pcall(mod.log.info, mod.log,
      "spawn_density set to %s via %s", value, tostring(source))
  end
  return true, value
end

-- Central setter for Random Enc (Start Menu + Mod Settings).
-- opts: { game=, logic=, confirm=, message= }
function Config.setRandomEncounters(mod, value, source, opts)
  opts = opts or {}
  local on = (value == true or value == "on" or value == "ON" or value == "true")
  if value == false or value == "off" or value == "OFF" or value == "false" then
    on = false
  elseif value ~= true and value ~= "on" and value ~= "ON" and value ~= "true" then
    if type(value) ~= "boolean" then
      return false, "invalid random_encounters: " .. tostring(value)
    end
  end

  local game = resolveGame(mod, opts)
  writeOptionBucket(mod, game, "random_encounters", on)
  -- Clear obsolete choice so readers never prefer it over the toggle.
  writeOptionBucket(mod, game, "grass_encounters", nil)

  local logic = opts.logic
  if not logic and mod and mod.exports then
    logic = mod.exports.logic
  end
  if logic and type(logic.applyRandomEncounters) == "function" then
    pcall(logic.applyRandomEncounters, logic, on, source)
  elseif logic and type(logic.onOptionsChanged) == "function" then
    pcall(logic.onOptionsChanged, logic, {
      mod = mod.id, key = "random_encounters", value = on, source = source,
    })
  end

  local confirmMsg = opts.message
  if not confirmMsg and opts.confirm ~= false then
    confirmMsg = "RANDOM: " .. (on and "ON" or "OFF")
  end
  confirmText(game, mod, confirmMsg)

  if source and mod and mod.log and type(mod.log.info) == "function" then
    pcall(mod.log.info, mod.log,
      "random_encounters set to %s via %s", tostring(on), tostring(source))
  end
  return true, on
end

function Config.setWaterMons(mod, value, source, opts)
  opts = opts or {}
  local mode = coerceWaterMode(value)
  if not mode then
    return false, "invalid water_spawns: " .. tostring(value)
  end

  local game = resolveGame(mod, opts)
  local spawnOn = (mode == "swimming_sprites"
    or mode == "hidden_silhouettes"
    or mode == "silhouettes")
  writeOptionBucket(mod, game, "water_spawns", mode)
  writeOptionBucket(mod, game, "enable_water_spawns", spawnOn)

  local logic = opts.logic
  if not logic and mod and mod.exports then
    logic = mod.exports.logic
  end
  if logic and type(logic.applyWaterMons) == "function" then
    pcall(logic.applyWaterMons, logic, spawnOn, source, mode)
  elseif logic and type(logic.onOptionsChanged) == "function" then
    pcall(logic.onOptionsChanged, logic, {
      mod = mod.id, key = "water_spawns", value = mode, source = source,
    })
  end

  local confirmMsg = opts.message
  if not confirmMsg and opts.confirm ~= false then
    confirmMsg = "WATER: " .. (WATER_MODE_CONFIRM[mode] or mode:upper())
  end
  confirmText(game, mod, confirmMsg)

  if source and mod and mod.log and type(mod.log.info) == "function" then
    pcall(mod.log.info, mod.log,
      "water_spawns set to %s via %s", tostring(mode), tostring(source))
  end
  return true, mode
end

-- Alias used by menus / docs.
Config.setWaterDisplayMode = Config.setWaterMons

local VALID_CAVE_MODES = {
  reachable = true,
  mixed = true,
}

local CAVE_MODE_CONFIRM = {
  reachable = "REACHABLE ONLY",
  mixed = "MIXED",
}

Config.VALID_CAVE_MODES = VALID_CAVE_MODES
Config.CAVE_MODE_CONFIRM = CAVE_MODE_CONFIRM

local function coerceCaveMode(value)
  if value == true or value == "true" or value == "on" or value == "ON"
     or value == "strict" or value == "reachable_only" then
    return "reachable"
  end
  if value == false or value == "false" or value == "off" or value == "OFF"
     or value == "classic" then
    return "mixed"
  end
  if type(value) == "string" and VALID_CAVE_MODES[value] then
    return value
  end
  return nil
end

function Config.caveSpawnMode(mod)
  local raw, present = Config.peekSavedOption(mod, "cave_spawns")
  if present then
    local mode = coerceCaveMode(raw)
    if mode then return mode end
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local v = mod.options:get("cave_spawns")
    local mode = coerceCaveMode(v)
    if mode then return mode end
  end
  return coerceCaveMode(Config.DEFAULTS.cave_spawns) or "reachable"
end

function Config.caveSpawnsMixed(mod)
  return Config.caveSpawnMode(mod) == "mixed"
end

function Config.caveSpawnsEnabled(mod)
  if Config.get(mod, "enable_cave_spawns") == false then return false end
  return true
end

function Config.migrateCaveSpawnMode(mod)
  local mode = Config.caveSpawnMode(mod)
  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    local cur = bucket[mod.id].cave_spawns
    if cur == nil or not VALID_CAVE_MODES[cur] then
      bucket[mod.id].cave_spawns = mode
    end
  end
  local world = mod.world
  local game = world and world.game
  if game and game.save and game.save.options then
    game.save.options.modOptions = game.save.options.modOptions or {}
    write(game.save.options.modOptions)
  end
  if game and game.mods then
    if game.mods.modOptions then write(game.mods.modOptions) end
    if game.mods.loader and game.mods.loader.modOptions then
      write(game.mods.loader.modOptions)
    end
  end
  return mode
end

function Config.setCaveSpawnMode(mod, value, source, opts)
  opts = opts or {}
  local mode = coerceCaveMode(value)
  if not mode then
    return false, "invalid cave_spawns: " .. tostring(value)
  end
  local game = resolveGame(mod, opts)
  writeOptionBucket(mod, game, "cave_spawns", mode)

  local logic = opts.logic
  if not logic and mod and mod.exports then
    logic = mod.exports.logic
  end
  if logic and type(logic.applyCaveSpawnMode) == "function" then
    pcall(logic.applyCaveSpawnMode, logic, mode, source)
  elseif logic and type(logic.onOptionsChanged) == "function" then
    pcall(logic.onOptionsChanged, logic, {
      mod = mod.id, key = "cave_spawns", value = mode, source = source,
    })
  end

  local confirmMsg = opts.message
  if not confirmMsg and opts.confirm ~= false then
    confirmMsg = "CAVE: " .. (CAVE_MODE_CONFIRM[mode] or mode:upper())
  end
  confirmText(game, mod, confirmMsg)
  return true, mode
end

function Config.pokemonGrassRenderMode(mod)
  local GrassOcclusion = V.require("grass_occlusion")
  return GrassOcclusion.mode(mod)
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
  return Config.spawnAmount(mod)
end

function Config.refillSteps(mod)
  local v = Config.get(mod, "spawn_refill_interval")
  if v == nil then v = Config.get(mod, "spawn_every_steps") end
  return tonumber(v) or Config.DEFAULTS.spawn_every_steps
end

-- ------- Sprite Fade (Solid / Faded)

local VALID_SPRITE_FADE = { solid = true, faded = true }
local SPRITE_FADE_CONFIRM = { solid = "SOLID", faded = "FADED" }
Config.VALID_SPRITE_FADE = VALID_SPRITE_FADE
Config.SPRITE_FADE_CONFIRM = SPRITE_FADE_CONFIRM
Config.SPRITE_FADE_ALPHA = Config.DEFAULTS.sprite_fade_alpha or 0.72

local function coerceSpriteFade(value)
  if value == "solid" or value == "SOLID" or value == 1 or value == 1.0
     or value == "1" or value == "1.0" then
    return "solid"
  end
  if value == "faded" or value == "FADED" or value == "tucked" or value == "faint"
     or value == 0.88 or value == 0.72 or value == "0.88" or value == "0.72" then
    return "faded"
  end
  if type(value) == "number" then
    if value >= 0.999 then return "solid" end
    if value > 0 then return "faded" end
  end
  if type(value) == "string" and VALID_SPRITE_FADE[value] then
    return value
  end
  return nil
end

function Config.spriteFade(mod)
  local raw, present = Config.peekSavedOption(mod, "sprite_fade")
  if present then
    local mode = coerceSpriteFade(raw)
    if mode then return mode end
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local v = mod.options:get("sprite_fade")
    local mode = coerceSpriteFade(v)
    if mode then return mode end
  end
  -- Legacy numeric sprite_opacity (pre-1.0.0 public option).
  local legacy, legPresent = Config.peekSavedOption(mod, "sprite_opacity")
  if legPresent then
    local mode = coerceSpriteFade(legacy)
    if mode then return mode end
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local legacyOpt = mod.options:get("sprite_opacity")
    local mode = coerceSpriteFade(legacyOpt)
    if mode then return mode end
  end
  return coerceSpriteFade(Config.DEFAULTS.sprite_fade) or "solid"
end

function Config.spriteOpacity(mod)
  if Config.spriteFade(mod) == "faded" then
    return tonumber(Config.DEFAULTS.sprite_fade_alpha) or 0.72
  end
  return 1.0
end

function Config.migrateSpriteFadeOption(mod)
  local mode = Config.spriteFade(mod)
  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    if bucket[mod.id].sprite_fade == nil
       or not VALID_SPRITE_FADE[bucket[mod.id].sprite_fade] then
      bucket[mod.id].sprite_fade = mode
    end
    -- Keep legacy numeric in sync for old readers; do not delete.
    if bucket[mod.id].sprite_opacity == nil then
      bucket[mod.id].sprite_opacity = (mode == "faded")
        and (tonumber(Config.DEFAULTS.sprite_fade_alpha) or 0.72) or 1.0
    end
  end
  local world = mod.world
  local game = world and world.game
  if game and game.save and game.save.options then
    game.save.options.modOptions = game.save.options.modOptions or {}
    write(game.save.options.modOptions)
  end
  if game and game.mods then
    if game.mods.modOptions then write(game.mods.modOptions) end
    if game.mods.loader and game.mods.loader.modOptions then
      write(game.mods.loader.modOptions)
    end
  end
  return mode
end

function Config.setSpriteFade(mod, value, source, opts)
  opts = opts or {}
  local mode = coerceSpriteFade(value)
  if not mode then
    return false, "invalid sprite_fade: " .. tostring(value)
  end
  local game = resolveGame(mod, opts)
  local alpha = (mode == "faded")
    and (tonumber(Config.DEFAULTS.sprite_fade_alpha) or 0.72) or 1.0
  writeOptionBucket(mod, game, "sprite_fade", mode)
  writeOptionBucket(mod, game, "sprite_opacity", alpha)

  local logic = opts.logic
  if not logic and mod and mod.exports then
    logic = mod.exports.logic
  end
  if logic and type(logic.onOptionsChanged) == "function" then
    pcall(logic.onOptionsChanged, logic, {
      mod = mod.id, key = "sprite_fade", value = mode, source = source,
    })
  end

  local confirmMsg = opts.message
  if not confirmMsg and opts.confirm ~= false then
    confirmMsg = "FADE: " .. (SPRITE_FADE_CONFIRM[mode] or mode:upper())
  end
  confirmText(game, mod, confirmMsg)
  return true, mode
end

-- ------- Sprite Color (removed)
--
-- The Colored/Classic choice was removed: follower, wild, ambient, and
-- party-icon sheets ALWAYS render as true-color. Legacy "classic" saves are
-- ignored and rewritten to "colored" on migration, so old 24-bit PNG packs
-- (e.g. the built-in Poke Followers / GSC sheets, which are 8-bit RGBA) are
-- never force-baked through the 4-shade DMG gray ramp.

local SPRITE_COLOR_CONFIRM = { colored = "COLORED", classic = "CLASSIC" }
Config.SPRITE_COLOR_CONFIRM = SPRITE_COLOR_CONFIRM

function Config.spriteColor(_mod)
  return "colored"
end

--- trueColor flag for shared SpriteRenderer defs. The -grayscale art must
--- flow through the engine's shade/zone colorization so it picks up the active
--- palette (CLASSIC/DMG = green shades, monochrome = gray, etc.), which means
--- trueColor=false everywhere EXCEPT redpp (ADVANCED), where the original
--- colored art is served and must render raw.
function Config.spriteTrueColor(_mod)
  return Config.paletteFxRedpp()
end

-- PaletteFX mode gate for sprite art selection. The colored sheets are the
-- default "normal" art; the explicit -grayscale sheets serve every COLORS
-- mode EXCEPT redpp (ADVANCED): redpp bakes real per-tile color onto
-- overworld sprites and wants the original colored art, while every other
-- mode colorizes through the shade/zone pass where grayscale reads correctly
-- and full-color PNGs look wrong. Unavailable PaletteFX (headless / tests /
-- other engines) defaults to false so the colored targets stay the safe
-- default everywhere.
function Config.paletteFxRedpp()
  local ok, PaletteFX = pcall(require, "src.render.PaletteFX")
  if ok and type(PaletteFX) == "table" and PaletteFX.mode ~= nil then
    return PaletteFX.mode == "redpp"
  end
  return false
end

function Config.migrateSpriteColorOption(mod)
  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    if bucket[mod.id].sprite_color ~= "colored" then
      bucket[mod.id].sprite_color = "colored"
    end
    -- Do not delete legacy keys (color_mode / colored_sprites stay readable).
  end
  local world = mod.world
  local game = world and world.game
  if game and game.save and game.save.options then
    game.save.options.modOptions = game.save.options.modOptions or {}
    write(game.save.options.modOptions)
  end
  if game and game.mods then
    if game.mods.modOptions then write(game.mods.modOptions) end
    if game.mods.loader and game.mods.loader.modOptions then
      write(game.mods.loader.modOptions)
    end
  end
  return "colored"
end

-- Back-compat setter: ignores the requested mode and forces colored. Kept so
-- external callers / older menus never crash, and a stale "classic" selection
-- is visually corrected immediately by refreshing entity sprites.
function Config.setSpriteColor(mod, value, source, opts)
  opts = opts or {}
  local game = resolveGame(mod, opts)
  writeOptionBucket(mod, game, "sprite_color", "colored")

  local render = opts.render
  local logic = opts.logic
  if (not render or not logic) and mod and mod.exports then
    render = render or mod.exports.render
    logic = logic or mod.exports.logic
  end
  local refreshed = 0
  if render and logic and type(render.refreshAllEntitySprites) == "function" then
    if type(render.invalidateAssetCache) == "function" then
      pcall(render.invalidateAssetCache, render)
    end
    local ok, n = pcall(render.refreshAllEntitySprites, render, logic, game)
    if ok and type(n) == "number" then refreshed = n end
  end
  if mod and mod.exports and mod.exports.ambient
     and type(mod.exports.ambient.refreshSprites) == "function" then
    pcall(mod.exports.ambient.refreshSprites, mod.exports.ambient, game)
  end

  local confirmMsg = opts.message
  if not confirmMsg and opts.confirm ~= false then
    confirmMsg = "COLOR: " .. (SPRITE_COLOR_CONFIRM.colored)
  end
  confirmText(game, mod, confirmMsg)
  return true, "colored", refreshed
end

-- ------- Town Pokémon (ambient NPCs)

function Config.townPokemonEnabled(mod)
  local raw, present = Config.peekSavedOption(mod, "town_pokemon")
  if present then
    return raw == true
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local v = mod.options:get("town_pokemon")
    if v ~= nil then return v == true end
  end
  -- Do not treat Followers EX wilds_town_spawns (battleable borrow) as this.
  return Config.DEFAULTS.town_pokemon == true
end

function Config.setTownPokemon(mod, value, source, opts)
  opts = opts or {}
  local on = (value == true or value == "on" or value == "ON" or value == "true")
  if value == false or value == "off" or value == "OFF" or value == "false" then
    on = false
  elseif value ~= true and value ~= "on" and value ~= "ON" and value ~= "true" then
    if type(value) ~= "boolean" then
      return false, "invalid town_pokemon: " .. tostring(value)
    end
  end
  local game = resolveGame(mod, opts)
  writeOptionBucket(mod, game, "town_pokemon", on)

  local ambient = opts.ambient
  if not ambient and mod and mod.exports then
    ambient = mod.exports.ambient
  end
  if ambient and type(ambient.onTownPokemonToggled) == "function" then
    pcall(ambient.onTownPokemonToggled, ambient, on, game)
  end

  local confirmMsg = opts.message
  if not confirmMsg and opts.confirm ~= false then
    confirmMsg = "TOWN: " .. (on and "ON" or "OFF")
  end
  confirmText(game, mod, confirmMsg)
  return true, on
end

--- Central battleability helper for wild / ambient entities.
function Config.isBattleableWild(entity)
  if not entity then return false end
  if entity.wildsAmbientPokemon == true then return false end
  if entity.wildsBattleable == false then return false end
  if entity.wildsEncounterEnabled == false then return false end
  if entity.wildsAggressive == false and entity.overworldWildSpawn ~= true then
    -- Ambient-style NPC without wild spawn marker.
    if entity.wildsAmbientPokemon then return false end
  end
  if entity.overworldWildSpawn == true then
    if entity.hiddenEncounter == true and entity.visibleSprite == false then
      return true -- hidden markers are still battleable on contact
    end
    return entity.state ~= "REMOVED" and entity.state ~= Config.STATE.REMOVED
  end
  return false
end

return Config
