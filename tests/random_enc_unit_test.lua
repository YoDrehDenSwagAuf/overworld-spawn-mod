-- Random Enc + Water Mons + Spawn FX unit tests.
-- Run: lua tests/random_enc_unit_test.lua
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

local savedOpts = {
  sprite_style = "auto",
  spawn_density = "normal",
  random_encounters = nil, -- unset → default true
  water_spawns = nil,
  grass_encounters = nil,
}

local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    options = {
      get = function(_, key) return savedOpts[key] end,
    },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    world = {
      game = {
        save = { options = { modOptions = { overworld_wild_spawns = savedOpts } } },
        mods = { modOptions = { overworld_wild_spawns = savedOpts } },
      },
    },
  },
  path = ".",
}

local modules = {}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

local Config = V.require("config")
local Behavior = V.require("behavior")
local Surface = V.require("surface")
local SpawnRegions = V.require("spawn_regions")
local SpawnFx = V.require("spawn_fx")

-- ------- Defaults / option schema -------
eq(Config.DEFAULTS.random_encounters, true, "default random_encounters is true")
check(Config.randomEncountersEnabled(V.mod) == true, "randomEncountersEnabled defaults ON")
eq(Config.spawnAmount(V.mod), "normal", "spawnAmount defaults to normal")
check(Config.waterMons(V.mod) == true, "waterMons defaults ON (spawn-enabled)")
eq(Config.waterDisplayMode(V.mod), "swimming_sprites", "waterDisplayMode defaults swimming")

local schema = assert(loadfile("options.lua"))()
local byKey = {}
for _, row in ipairs(schema) do byKey[row.key] = row end
check(byKey.spawn_density ~= nil, "spawn_density present in Mod Settings schema")
eq(byKey.spawn_density.label, "Spawn Amount", "Spawn Amount label")
eq(byKey.spawn_density.default, "normal", "spawn_density schema default")
check(#byKey.spawn_density.label <= 14, "Spawn Amount label <= 14")
check(byKey.grass_encounters == nil, "grass_encounters removed from Mod Settings")
check(byKey.suppress_random_grass == nil, "suppress_random_grass removed from Mod Settings")
check(byKey.random_encounters ~= nil, "random_encounters present in Mod Settings")
eq(byKey.random_encounters.default, true, "random_encounters schema default")
eq(byKey.random_encounters.label, "Random Enc", "Random Enc label")
check(#byKey.random_encounters.label <= 14, "Random Enc label <= 14")
eq(byKey.random_encounters.type, "toggle", "random_encounters is toggle")
check(byKey.sprite_style ~= nil, "Sprite Style remains in Mod Settings")
check(byKey.water_spawns ~= nil, "water_spawns present in Mod Settings")
eq(byKey.water_spawns.label, "Water Mons", "Water Mons label")
eq(byKey.water_spawns.type, "choice", "water_spawns is choice")
eq(byKey.water_spawns.default, "swimming_sprites", "water_spawns default swimming_sprites")
eq(#byKey.water_spawns.choices, 5, "five water display modes")
check(byKey.dev_overlay ~= nil, "dev_overlay present in Mod Settings")
eq(byKey.dev_overlay.default, false, "dev_overlay defaults OFF")
eq(byKey.dev_overlay.label, "Dev Overlay", "Dev Overlay label")
check(byKey.dev_mode == nil, "dev_mode removed from public schema")
check(byKey.debug_hud_always_visible == nil, "debug_hud_always_visible removed")
check(byKey.show_behavior_overlays == nil, "show_behavior_overlays removed")
check(byKey.force_test_spawn == nil, "force_test_spawn removed")
check(byKey.preview_filter == nil, "preview_filter removed")
check(byKey.debug_logging == nil, "debug_logging removed from public schema")

-- ------- Migration from grass_encounters -------
savedOpts.random_encounters = nil
savedOpts.grass_encounters = "classic"
check(Config.randomEncountersEnabled(V.mod) == true, "classic → random ON")
savedOpts.grass_encounters = "hidden"
check(Config.randomEncountersEnabled(V.mod) == false, "hidden → random OFF")
savedOpts.grass_encounters = "both"
check(Config.randomEncountersEnabled(V.mod) == true, "both → random ON")
savedOpts.grass_encounters = nil
savedOpts.random_encounters = nil

-- migrate writes random_encounters and clears grass_encounters
savedOpts.grass_encounters = "hidden"
Config.migrateRandomEncountersOption(V.mod)
eq(savedOpts.random_encounters, false, "migrate hidden → false")
eq(savedOpts.grass_encounters, nil, "migrate clears grass_encounters")
savedOpts.random_encounters = nil

-- ------- Setters -------
local okRand = Config.setRandomEncounters(V.mod, false, "start_menu", {
  game = V.mod.world.game, confirm = false,
})
check(okRand == true, "setRandomEncounters accepts false")
eq(savedOpts.random_encounters, false, "random_encounters written false")
check(Config.randomEncountersEnabled(V.mod) == false, "reads OFF")
Config.setRandomEncounters(V.mod, true, "start_menu", {
  game = V.mod.world.game, confirm = false,
})
check(Config.randomEncountersEnabled(V.mod) == true, "reads ON")
check(Config.setRandomEncounters(V.mod, "nope", "t", { confirm = false }) == false,
      "rejects invalid random value")

local okSpawn = Config.setSpawnAmount(V.mod, "high", "start_menu", {
  game = V.mod.world.game, confirm = false,
})
check(okSpawn == true, "setSpawnAmount accepts high")
eq(Config.spawnAmount(V.mod), "high", "spawnAmount reads high")

Config.setWaterMons(V.mod, false, "start_menu", {
  game = V.mod.world.game, confirm = false,
})
check(Config.waterMons(V.mod) == false, "legacy false → spawn disabled")
eq(Config.waterDisplayMode(V.mod), "classic_encounters", "legacy false → classic_encounters")
Config.setWaterMons(V.mod, true, "start_menu", {
  game = V.mod.world.game, confirm = false,
})
check(Config.waterMons(V.mod) == true, "legacy true → spawn enabled")
eq(Config.waterDisplayMode(V.mod), "swimming_sprites", "legacy true → swimming_sprites")
Config.setWaterMons(V.mod, "silhouettes", "start_menu", {
  game = V.mod.world.game, confirm = false,
})
eq(Config.waterDisplayMode(V.mod), "silhouettes", "set silhouettes mode")
Config.setWaterMons(V.mod, "swimming_sprites", "start_menu", {
  game = V.mod.world.game, confirm = false,
})
eq(Config.waterDisplayMode(V.mod), "swimming_sprites", "restore swimming_sprites")

-- ------- No HIDDEN_IDLE -------
check(Behavior.HIDDEN_IDLE == nil, "HIDDEN_IDLE constant removed")
check(Behavior.isHiddenIdle == nil, "isHiddenIdle removed")
check(Behavior.isHidden(Behavior.HIDDEN_GRASS), "HIDDEN_GRASS still hidden marker")
check(not Surface.allowsBehavior(Surface.GRASS, "HIDDEN_IDLE"), "grass rejects HIDDEN_IDLE")
check(Surface.allowsBehavior(Surface.WATER, Behavior.WATER_IDLE), "water allows WATER_IDLE")
check(Surface.allowsBehavior(Surface.WATER, Behavior.WATER_WANDER), "water allows WATER_WANDER")
check(Surface.allowsBehavior(Surface.WATER, Behavior.WATER_AGGRESSIVE),
      "water allows WATER_AGGRESSIVE")
check(Behavior.isWater(Behavior.WATER_AGGRESSIVE), "WATER_AGGRESSIVE is water")

do
  local saw = false
  for i = 1, 40 do
    local b = Behavior.pick("PIDGEY", Surface.GRASS, {
      enable_idle = true, enable_wander = true, enable_aggressive = true,
      enable_hidden = true,
    }, function(n)
      if n then return (i % n) + 1 end
      return (i % 100) / 100
    end)
    if b == "HIDDEN_IDLE" then saw = true end
  end
  check(not saw, "Behavior.pick never yields HIDDEN_IDLE")
end

-- ------- Spawn FX (no rustle / no hidden reveal) -------
check(SpawnFx.KIND.HIDDEN_REVEAL == nil, "no HIDDEN_REVEAL kind")
check(SpawnFx.KIND.GRASS == "grass", "grass spawn kind")
check(SpawnFx.KIND.WATER == "water", "water spawn kind")

do
  local e = { cellX = 1, cellY = 1, canTriggerBattle = true }
  SpawnFx.begin(e, SpawnFx.KIND.GRASS)
  check(SpawnFx.bodyVisible(e) == false, "grass spawn body hidden at t0")
  check(SpawnFx.canAct(e) == false, "grass spawn cannot act at t0")
  check(SpawnFx.canBattle(e) == false, "grass spawn cannot battle at t0")
  local visibleAt = false
  for _ = 1, 30 do
    local ev2 = SpawnFx.updateEntity(e, 0.02, {})
    if ev2 == "spawn_visible" then visibleAt = true end
    if ev2 == "spawn_done" then break end
  end
  check(visibleAt, "grass spawn_visible fired")
  check(e.spawnFx.done == true, "grass spawn FX done")
  check(SpawnFx.canAct(e) == true, "grass spawn can act after done")
end

do
  local e = { cellX = 2, cellY = 2, surfaceVisualOffset = 2 }
  SpawnFx.begin(e, SpawnFx.KIND.WATER)
  check(SpawnFx.bodyVisible(e) == false, "water spawn body hidden at t0")
  local splash = false
  for _ = 1, 40 do
    local ev2 = SpawnFx.updateEntity(e, 0.02, {})
    if ev2 == "water_splash" then splash = true end
    if ev2 == "spawn_done" then break end
  end
  check(splash, "water splash event")
  check(e.spawnFx.done == true, "water spawn FX done")
end

local fx = SpawnFx.new(V.mod)
eq(fx:activeRustleCount(), 0, "no rustle FX")
check(type(fx.grassRustle) ~= "function", "grassRustle removed")

-- ------- Menu constants -------
local SpriteStyleMenu = assert(loadfile("lib/sprite_style_menu.lua"))(V)
eq(SpriteStyleMenu.LABEL_STYLE, "SPRITE STYLE", "style label")
eq(SpriteStyleMenu.LABEL_SPAWN, "SPAWN AMOUNT", "spawn label")
eq(SpriteStyleMenu.LABEL_RANDOM, "RANDOM ENC", "random label")
eq(SpriteStyleMenu.LABEL_WATER, "WATER MONS", "water label")
check(#SpriteStyleMenu.LABEL_STYLE <= 14, "SPRITE STYLE <= 14")
check(#SpriteStyleMenu.LABEL_SPAWN <= 14, "SPAWN AMOUNT <= 14")
check(#SpriteStyleMenu.LABEL_RANDOM <= 14, "RANDOM ENC <= 14")
check(#SpriteStyleMenu.LABEL_WATER <= 14, "WATER MONS <= 14")
eq(#SpriteStyleMenu.SPAWN_CHOICES, 4, "four spawn choices")
eq(#SpriteStyleMenu.RANDOM_CHOICES, 2, "two random choices")
eq(#SpriteStyleMenu.WATER_CHOICES, 5, "five water choices")

-- Density still works.
local tLow = SpawnRegions.targetCount({
  eligibleTiles = 48, minVisible = 1, maxVisible = 12,
  tilesPerAdditional = 24, density = "low", mapSpan = 30,
})
local tHigh = SpawnRegions.targetCount({
  eligibleTiles = 48, minVisible = 1, maxVisible = 12,
  tilesPerAdditional = 24, density = "high", mapSpan = 30,
})
check(tHigh > tLow, "high density > low density")

-- Version
local mf = io.open("manifest.json", "r")
local mft = mf:read("*a")
mf:close()
check(mft:find('"version"%s*:%s*"1%.12%.0"') ~= nil, "manifest version 1.12.0")

-- Start menu no longer injects Wilds gameplay settings.
do
  local wraps = 0
  V.mod.hooks = {
    wrap = function(_, name)
      if name == "ui.start_menu.items" then wraps = wraps + 1 end
    end,
  }
  V.mod.content = { screens = { register = function() end } }
  local menu = SpriteStyleMenu.new(V.mod, {})
  menu:register()
  eq(wraps, 0, "sprite style menu does not wrap start menu")
end

print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("all random_enc unit tests passed")
