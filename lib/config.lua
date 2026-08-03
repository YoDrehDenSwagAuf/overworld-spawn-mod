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
  sprite_style = "auto",
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
  aggressive_frequency = 1.0,
  aggressive_sight_range = 4,
  aggressive_reaction_delay = 0.55,
  aggressive_step_seconds = 0.18,
  wild_step_seconds = 0.28,
  idle_look_min_s = 5,
  idle_look_max_s = 10,
  enable_water_spawns = true,
  enable_cave_spawns = true,
  debug_logging = false,
  force_test_spawn = false,
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

function Config.devMode(mod)
  return Config.get(mod, "dev_mode") == true
end

function Config.debug(mod)
  -- Developer mode forces structured diagnostics logging.
  if Config.devMode(mod) then return true end
  return Config.get(mod, "debug_logging") == true
end

function Config.hudAlwaysVisible(mod)
  return Config.devMode(mod) and Config.get(mod, "debug_hud_always_visible") == true
end

function Config.allowOutsideEncounter(mod)
  return Config.devMode(mod)
     and Config.get(mod, "allow_debug_spawn_outside_encounter_areas") == true
end

function Config.showSpawnTileOverlay(mod)
  return Config.devMode(mod)
     and Config.get(mod, "show_spawn_tile_overlay") == true
end

function Config.showBehaviorOverlays(mod)
  return Config.devMode(mod)
     and Config.get(mod, "show_behavior_overlays") == true
end

local VALID_SPRITE_STYLES = {
  auto = true,
  gold = true,
  followers_ex = true,
  pokemmo = true,
  pokedex = true,
}

local SPRITE_STYLE_CONFIRM = {
  auto = "AUTO",
  gold = "GOLD",
  followers_ex = "FOLLOWERS EX",
  pokemmo = "POKEMMO",
  pokedex = "POKEDEX",
}

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
--   true  -> auto
--   false -> pokedex
function Config.spriteStyle(mod)
  local rawStyle, stylePresent = Config.peekSavedOption(mod, "sprite_style")
  if stylePresent and type(rawStyle) == "string" and VALID_SPRITE_STYLES[rawStyle] then
    return rawStyle
  end

  local v = nil
  if mod and mod.options and type(mod.options.get) == "function" then
    v = mod.options:get("sprite_style")
  end
  if type(v) == "string" and VALID_SPRITE_STYLES[v] then
    -- Schema default is "auto". If the save never stored sprite_style but still
    -- has legacy Mon Sprites = off, prefer pokedex once.
    if v == "auto" and not stylePresent then
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
    return v
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
  return "auto"
end

function Config.migrateSpriteStyleOption(mod)
  local style = Config.spriteStyle(mod)
  local function write(bucket)
    if type(bucket) ~= "table" then return end
    bucket[mod.id] = bucket[mod.id] or {}
    if bucket[mod.id].sprite_style == nil then
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

-- Central setter used by Start Menu and any non-Mod-Manager UI path.
-- Mod Settings already persist sprite_style via the engine; both share this key.
-- opts: { game=, logic=, render=, confirm=, message= }
function Config.setSpriteStyle(mod, value, source, opts)
  opts = opts or {}
  value = tostring(value or "")
  if not VALID_SPRITE_STYLES[value] then
    return false, "invalid sprite_style: " .. value
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

Config.VALID_SPRITE_STYLES = VALID_SPRITE_STYLES
Config.SPRITE_STYLE_CONFIRM = SPRITE_STYLE_CONFIRM

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
  return Config.get(mod, "spawn_density") or "normal"
end

function Config.refillSteps(mod)
  local v = Config.get(mod, "spawn_refill_interval")
  if v == nil then v = Config.get(mod, "spawn_every_steps") end
  return tonumber(v) or Config.DEFAULTS.spawn_every_steps
end

return Config
