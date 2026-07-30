-- Tunables and option defaults for overworld-spawns.
local V = ...

local Config = {}

-- Vanilla Gen 1 encounter slot buckets (out of 256).
Config.ENCOUNTER_BUCKETS = { 51, 102, 141, 166, 191, 216, 229, 242, 253, 256 }

Config.DEFAULTS = {
  max_spawns = 5,
  spawn_every_steps = 8,
  initial_spawns = 3,
  min_player_distance = 3,
  suppress_random_grass = true,
  sprite_opacity = 0.88,
  grass_tuck_px = 2,
}

function Config.defineOptions(mod)
  mod.options:define({
    { key = "max_spawns", label = "MAX SPAWNS", type = "choice",
      default = Config.DEFAULTS.max_spawns,
      choices = {
        { "3", 3 }, { "4", 4 }, { "5", 5 }, { "6", 6 }, { "8", 8 },
      } },
    { key = "spawn_every_steps", label = "SPAWN RATE", type = "choice",
      default = Config.DEFAULTS.spawn_every_steps,
      choices = {
        { "FAST", 4 }, { "NORMAL", 8 }, { "SLOW", 14 },
      } },
    { key = "initial_spawns", label = "ON ENTER", type = "choice",
      default = Config.DEFAULTS.initial_spawns,
      choices = {
        { "1", 1 }, { "2", 2 }, { "3", 3 }, { "4", 4 }, { "5", 5 },
      } },
    { key = "suppress_random_grass", label = "HIDE RANDOM GRASS",
      type = "toggle", default = Config.DEFAULTS.suppress_random_grass },
    { key = "sprite_opacity", label = "SPRITE FADE", type = "choice",
      default = Config.DEFAULTS.sprite_opacity,
      choices = {
        { "SOLID", 1.0 }, { "TUCKED", 0.88 }, { "FAINT", 0.72 },
      } },
  })
end

function Config.get(mod, key)
  local v = mod.options:get(key)
  if v == nil then return Config.DEFAULTS[key] end
  return v
end

return Config
