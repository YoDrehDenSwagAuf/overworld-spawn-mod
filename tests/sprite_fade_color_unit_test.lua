-- Sprite Fade + Sprite Color defaults, migration, and opacity scope.
-- Run: lua tests/sprite_fade_color_unit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. tostring(msg) .. "\n")
  else
    print("ok  " .. tostring(msg))
  end
end
local function eq(a, b, msg)
  check(a == b, string.format("%s (got %s expected %s)", msg, tostring(a), tostring(b)))
end

local savedOpts = {}
local optionStore = {}
local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    options = {
      get = function(_, k)
        if optionStore[k] ~= nil then return optionStore[k] end
        return nil
      end,
      set = function(_, k, v) optionStore[k] = v end,
    },
    world = {
      game = {
        save = { options = { modOptions = { overworld_wild_spawns = savedOpts } } },
        mods = { modOptions = { overworld_wild_spawns = savedOpts } },
      },
    },
  },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end
modules.debug_log = { warn = function() end, info = function() end }

local Config = V.require("config")

local schema = assert(loadfile("options.lua"))()
local byKey = {}
for _, row in ipairs(schema) do byKey[row.key] = row end

check(byKey.sprite_fade ~= nil, "sprite_fade in schema")
check(byKey.sprite_color ~= nil, "sprite_color in schema")
eq(byKey.sprite_fade.default, "solid", "sprite_fade default solid")
eq(byKey.sprite_color.default, "colored", "sprite_color default colored")
eq(byKey.town_pokemon.default, true, "town_pokemon default true")

eq(Config.spriteFade(V.mod), "solid", "runtime fade default solid")
eq(Config.spriteOpacity(V.mod), 1.0, "solid alpha == 1.0")
eq(Config.spriteColor(V.mod), "colored", "runtime color default colored")
check(Config.spriteTrueColor(V.mod) == true, "colored ⇒ trueColor")

-- Legacy sprite_opacity migration
savedOpts.sprite_opacity = 0.72
savedOpts.sprite_fade = nil
eq(Config.spriteFade(V.mod), "faded", "legacy opacity 0.72 → faded")
check(Config.spriteOpacity(V.mod) < 1.0, "faded opacity < 1")
eq(Config.spriteOpacity(V.mod), 0.72, "faded alpha is 0.72")

Config.migrateSpriteFadeOption(V.mod)
eq(savedOpts.sprite_fade, "faded", "migrate writes sprite_fade")
-- New value wins over legacy
savedOpts.sprite_fade = "solid"
eq(Config.spriteFade(V.mod), "solid", "explicit solid wins")
eq(Config.spriteOpacity(V.mod), 1.0, "solid opacity 1.0")

Config.setSpriteFade(V.mod, "faded", "test", { confirm = false })
eq(optionStore.sprite_fade, "faded", "setSpriteFade writes key")
eq(Config.spriteOpacity(V.mod), 0.72, "set faded opacity")

-- Legacy color_mode = gbc
savedOpts = V.mod.world.game.save.options.modOptions.overworld_wild_spawns
savedOpts.sprite_color = nil
savedOpts.color_mode = "gbc"
eq(Config.spriteColor(V.mod), "classic", "color_mode gbc → classic")
check(Config.spriteTrueColor(V.mod) == false, "classic ⇒ not trueColor")
Config.migrateSpriteColorOption(V.mod)
eq(savedOpts.sprite_color, "classic", "migrate writes sprite_color")
check(savedOpts.color_mode == "gbc", "legacy color_mode preserved")

Config.setSpriteColor(V.mod, "colored", "test", { confirm = false })
eq(optionStore.sprite_color, "colored", "setSpriteColor writes key")
check(Config.spriteTrueColor(V.mod) == true, "set colored trueColor")

-- isBattleableWild
check(Config.isBattleableWild({
  overworldWildSpawn = true, state = "available",
}) == true, "normal wild battleable")
check(Config.isBattleableWild({
  wildsAmbientPokemon = true, overworldWildSpawn = false,
}) == false, "ambient not battleable")
check(Config.isBattleableWild({
  wildsAmbientPokemon = true, wildsBattleable = false,
  wildsAggressive = false, wildsEncounterEnabled = false,
}) == false, "ambient markers not battleable")
check(Config.isBattleableWild(nil) == false, "nil not battleable")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("sprite_fade_color_unit_test: all passed")
