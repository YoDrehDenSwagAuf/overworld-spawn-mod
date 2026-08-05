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
  -- Public styles: pokemmo / followers / pokedex (HGSS/PokeMMO default).
  sprite_style = "pokemmo",
  -- original = pixel-identical prior sheets; relative = height-scaled land sheets.
  sprite_size_mode = "original",
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
  enable_water_spawns = true, -- legacy internal alias
  water_spawns = true,        -- public "Water Mons" toggle
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
  enable_cave_spawns = true,
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

-- Public selectable styles (Mod Settings).
local PUBLIC_SPRITE_STYLES = {
  pokemmo = true,
  followers = true,
  pokedex = true,
}

-- Accepted on read (legacy saves / external callers) before normalization.
local VALID_SPRITE_STYLES = {
  pokemmo = true,
  followers = true,
  pokedex = true,
  -- Legacy aliases (migrated / not publicly selectable).
  auto = true,
  gold = true,
  crystal = true,
  followers_ex = true,
}

local SPRITE_STYLE_ALIASES = {
  auto = "pokemmo",
  gold = "pokemmo",
  crystal = "pokemmo",
  followers_ex = "followers",
  followers = "followers",
  pokemmo = "pokemmo",
  pokedex = "pokedex",
}

local SPRITE_STYLE_CONFIRM = {
  pokemmo = "HGSS / POKEMMO",
  followers = "POKE FOLLOWERS",
  pokedex = "POKEDEX",
  -- Legacy confirm labels (migration / old menus).
  auto = "HGSS / POKEMMO",
  gold = "HGSS / POKEMMO",
  crystal = "HGSS / POKEMMO",
  followers_ex = "POKE FOLLOWERS",
}

local VALID_SPRITE_SIZE_MODES = {
  original = true,
  relative = true,
}

local SPRITE_SIZE_CONFIRM = {
  original = "ORIGINAL",
  relative = "RELATIVE",
}

function Config.normalizeSpriteStyle(value)
  if type(value) ~= "string" or value == "" then
    return "pokemmo"
  end
  local key = string.lower(value)
  local mapped = SPRITE_STYLE_ALIASES[key]
  if mapped then return mapped end
  if PUBLIC_SPRITE_STYLES[key] then return key end
  return "pokemmo"
end

function Config.normalizeSpriteSizeMode(value)
  if type(value) ~= "string" or value == "" then
    return "original"
  end
  local key = string.lower(value)
  if VALID_SPRITE_SIZE_MODES[key] then return key end
  return "original"
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
--   true  -> pokemmo
--   false -> pokedex
-- Legacy style values (auto/gold/crystal/followers_ex) normalize once.
function Config.spriteStyle(mod)
  local rawStyle, stylePresent = Config.peekSavedOption(mod, "sprite_style")
  if stylePresent and type(rawStyle) == "string" and VALID_SPRITE_STYLES[rawStyle] then
    return Config.normalizeSpriteStyle(rawStyle)
  end

  local v = nil
  if mod and mod.options and type(mod.options.get) == "function" then
    v = mod.options:get("sprite_style")
  end
  if type(v) == "string" and VALID_SPRITE_STYLES[v] then
    -- Schema default is pokemmo. If the save never stored sprite_style but still
    -- has legacy Mon Sprites = off, prefer pokedex once.
    local normalized = Config.normalizeSpriteStyle(v)
    if (v == "auto" or v == "pokemmo") and not stylePresent then
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
  return "pokemmo"
end

function Config.spriteSizeMode(mod)
  local raw, present = Config.peekSavedOption(mod, "sprite_size_mode")
  if present and type(raw) == "string" then
    return Config.normalizeSpriteSizeMode(raw)
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local v = mod.options:get("sprite_size_mode")
    if type(v) == "string" then
      return Config.normalizeSpriteSizeMode(v)
    end
  end
  return Config.DEFAULTS.sprite_size_mode or "original"
end

function Config.migrateSpriteStyleOption(mod)
  local style = Config.spriteStyle(mod)
  local sizeMode = Config.spriteSizeMode(mod)
  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    local cur = bucket[mod.id].sprite_style
    -- Normalize legacy values in-place so dead options disappear from saves.
    if cur == nil or (type(cur) == "string" and VALID_SPRITE_STYLES[cur]) then
      bucket[mod.id].sprite_style = style
    end
    if bucket[mod.id].sprite_size_mode == nil then
      bucket[mod.id].sprite_size_mode = sizeMode
    else
      bucket[mod.id].sprite_size_mode = Config.normalizeSpriteSizeMode(
        bucket[mod.id].sprite_size_mode)
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

Config.migrateSpriteSizeModeOption = Config.migrateSpriteStyleOption

-- Compatibility: true when style is not the static Pokedex path.
function Config.useAnimatedOverworldSprites(mod)
  return Config.spriteStyle(mod) ~= "pokedex"
end

local function refreshSpritesAfterOption(mod, opts)
  opts = opts or {}
  local game = opts.game
  if not game and mod and mod.world then
    game = mod.world.game
  end
  local render = opts.render
  local logic = opts.logic
  if (not render or not logic) and mod and mod.exports then
    render = render or mod.exports.render
    logic = logic or mod.exports.logic
  end
  local refreshed = 0
  if render and type(render.setRuntimeSheetSizeMode) == "function" then
    pcall(render.setRuntimeSheetSizeMode, render, Config.spriteSizeMode(mod))
  end
  if render and logic and type(render.refreshAllEntitySprites) == "function" then
    if type(render.invalidateAssetCache) == "function" then
      pcall(render.invalidateAssetCache, render)
    end
    local ok, n = pcall(render.refreshAllEntitySprites, render, logic, game)
    if ok and type(n) == "number" then refreshed = n end
  end
  return refreshed, game, render, logic
end

-- Central setter used by Start Menu and any non-Mod-Manager UI path.
-- Mod Settings already persist sprite_style via the engine; both share this key.
-- opts: { game=, logic=, render=, confirm=, message= }
function Config.setSpriteStyle(mod, value, source, opts)
  opts = opts or {}
  value = Config.normalizeSpriteStyle(tostring(value or ""))
  if not PUBLIC_SPRITE_STYLES[value] then
    return false, "invalid sprite_style: " .. tostring(value)
  end

  local game = opts.game
  if not game and mod and mod.world then
    game = mod.world.game
  end

  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    bucket[mod.id].sprite_style = value
  end

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
  if game and type(game.writeOptions) == "function" then
    pcall(game.writeOptions, game)
  end

  local refreshed = select(1, refreshSpritesAfterOption(mod, opts))

  local confirmMsg = opts.message
  if not confirmMsg and opts.confirm ~= false then
    confirmMsg = "SPRITES: " .. (SPRITE_STYLE_CONFIRM[value] or value:upper())
  end
  if confirmMsg and game and mod and mod.ui and mod.ui.TextBox and game.stack then
    pcall(function()
      game.stack:push(mod.ui.TextBox.new(game, confirmMsg))
    end)
  end

  if source and mod and mod.log and type(mod.log.info) == "function" then
    pcall(mod.log.info, mod.log,
      "sprite_style set to %s via %s (refreshed=%d)",
      value, tostring(source), refreshed)
  end

  return true, value, refreshed
end

function Config.setSpriteSizeMode(mod, value, source, opts)
  opts = opts or {}
  value = Config.normalizeSpriteSizeMode(tostring(value or ""))
  if not VALID_SPRITE_SIZE_MODES[value] then
    return false, "invalid sprite_size_mode: " .. tostring(value)
  end

  local game = opts.game
  if not game and mod and mod.world then
    game = mod.world.game
  end

  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    bucket[mod.id].sprite_size_mode = value
  end

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
  if game and type(game.writeOptions) == "function" then
    pcall(game.writeOptions, game)
  end

  local refreshed = select(1, refreshSpritesAfterOption(mod, opts))

  local confirmMsg = opts.message
  if not confirmMsg and opts.confirm ~= false then
    confirmMsg = "SIZES: " .. (SPRITE_SIZE_CONFIRM[value] or value:upper())
  end
  if confirmMsg and game and mod and mod.ui and mod.ui.TextBox and game.stack then
    pcall(function()
      game.stack:push(mod.ui.TextBox.new(game, confirmMsg))
    end)
  end

  if source and mod and mod.log and type(mod.log.info) == "function" then
    pcall(mod.log.info, mod.log,
      "sprite_size_mode set to %s via %s (refreshed=%d)",
      value, tostring(source), refreshed)
  end

  return true, value, refreshed
end

Config.VALID_SPRITE_STYLES = VALID_SPRITE_STYLES
Config.PUBLIC_SPRITE_STYLES = PUBLIC_SPRITE_STYLES
Config.SPRITE_STYLE_CONFIRM = SPRITE_STYLE_CONFIRM
Config.VALID_SPRITE_SIZE_MODES = VALID_SPRITE_SIZE_MODES
Config.SPRITE_SIZE_CONFIRM = SPRITE_SIZE_CONFIRM
Config.SPRITE_STYLE_ALIASES = SPRITE_STYLE_ALIASES

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

local function writeOptionBucket(mod, game, key, value)
  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    bucket[mod.id][key] = value
  end
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
  if game and type(game.writeOptions) == "function" then
    pcall(game.writeOptions, game)
  end
end

local function resolveGame(mod, opts)
  opts = opts or {}
  if opts.game then return opts.game end
  if mod and mod.world then return mod.world.game end
  return nil
end

local function confirmText(game, mod, message)
  if not message or not game or not mod then return end
  if mod.ui and mod.ui.TextBox and game.stack then
    pcall(function()
      game.stack:push(mod.ui.TextBox.new(game, message))
    end)
  end
end

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
      bucket[mod.id].water_spawns = Config.waterMons(mod)
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

function Config.waterMons(mod)
  local raw, present = Config.peekSavedOption(mod, "water_spawns")
  if present then
    return raw == true
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local v = mod.options:get("water_spawns")
    if v ~= nil then return v == true end
    local legacy = mod.options:get("enable_water_spawns")
    if legacy ~= nil then return legacy == true end
  end
  return Config.DEFAULTS.water_spawns ~= false
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
  local on = (value == true or value == "on" or value == "ON" or value == "true")
  if value == false or value == "off" or value == "OFF" or value == "false" then
    on = false
  elseif value ~= true and value ~= "on" and value ~= "ON" and value ~= "true" then
    if type(value) ~= "boolean" then
      return false, "invalid water_spawns: " .. tostring(value)
    end
  end

  local game = resolveGame(mod, opts)
  writeOptionBucket(mod, game, "water_spawns", on)
  writeOptionBucket(mod, game, "enable_water_spawns", on)

  local logic = opts.logic
  if not logic and mod and mod.exports then
    logic = mod.exports.logic
  end
  if logic and type(logic.applyWaterMons) == "function" then
    pcall(logic.applyWaterMons, logic, on, source)
  elseif logic and type(logic.onOptionsChanged) == "function" then
    pcall(logic.onOptionsChanged, logic, {
      mod = mod.id, key = "water_spawns", value = on, source = source,
    })
  end

  local confirmMsg = opts.message
  if not confirmMsg and opts.confirm ~= false then
    confirmMsg = "WATER: " .. (on and "ON" or "OFF")
  end
  confirmText(game, mod, confirmMsg)

  if source and mod and mod.log and type(mod.log.info) == "function" then
    pcall(mod.log.info, mod.log,
      "water_spawns set to %s via %s", tostring(on), tostring(source))
  end
  return true, on
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

return Config
