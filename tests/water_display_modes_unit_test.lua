-- Water Pokémon display modes unit tests.
-- Run: lua tests/water_display_modes_unit_test.lua
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
  random_encounters = true,
  water_spawns = nil,
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
local WaterDisplay = V.require("water_display")
local Behavior = V.require("behavior")

-- ------- Schema -------
local schema = assert(loadfile("options.lua"))()
local byKey = {}
for _, row in ipairs(schema) do byKey[row.key] = row end
check(byKey.water_spawns ~= nil, "water_spawns present")
eq(byKey.water_spawns.type, "choice", "water_spawns is choice")
eq(byKey.water_spawns.default, "swimming_sprites", "default swimming_sprites")
eq(byKey.water_spawns.label, "Water Mons", "label Water Mons")
check(#byKey.water_spawns.label <= 14, "label <= 14")
eq(#byKey.water_spawns.choices, 5, "five water choices")
for _, c in ipairs(byKey.water_spawns.choices) do
  check(#c[1] <= 14, "choice display <= 14: " .. tostring(c[1]))
end

-- ------- Defaults / readers -------
savedOpts.water_spawns = nil
eq(Config.waterDisplayMode(V.mod), "swimming_sprites", "unset → swimming_sprites")
check(Config.waterMons(V.mod) == true, "default waterMons spawn-enabled")
check(not Config.waterClassicEncountersForced(V.mod), "default not classic forced")
check(not Config.waterEncountersDisabled(V.mod), "default not disabled")
check(WaterDisplay.isSwimmingSprites(V.mod), "WaterDisplay swimming")

-- ------- Legacy bool migration -------
savedOpts.water_spawns = true
eq(Config.waterDisplayMode(V.mod), "swimming_sprites", "legacy true → swimming")
savedOpts.water_spawns = false
eq(Config.waterDisplayMode(V.mod), "classic_encounters", "legacy false → classic")
check(Config.waterMons(V.mod) == false, "classic does not spawn")
check(Config.waterClassicEncountersForced(V.mod) == true, "classic forced")

Config.migrateWaterDisplayMode(V.mod)
eq(savedOpts.water_spawns, "classic_encounters", "migrate writes string mode")
eq(savedOpts.enable_water_spawns, false, "migrate sets enable_water_spawns false")

-- ------- Mode matrix -------
local modes = {
  swimming_sprites = { spawn = true, classicForce = false, disabled = false },
  hidden_silhouettes = { spawn = true, classicForce = false, disabled = false },
  silhouettes = { spawn = true, classicForce = false, disabled = false },
  classic_encounters = { spawn = false, classicForce = true, disabled = false },
  disabled = { spawn = false, classicForce = false, disabled = true },
}
for mode, expect in pairs(modes) do
  savedOpts.water_spawns = mode
  eq(Config.waterDisplayMode(V.mod), mode, "mode " .. mode)
  eq(Config.waterMons(V.mod), expect.spawn, mode .. " spawn")
  eq(Config.waterClassicEncountersForced(V.mod), expect.classicForce, mode .. " classic")
  eq(Config.waterEncountersDisabled(V.mod), expect.disabled, mode .. " disabled")
end

-- ------- Setter -------
local ok, written = Config.setWaterMons(V.mod, "silhouettes", "test", {
  game = V.mod.world.game, confirm = false,
})
check(ok == true, "setWaterMons accepts silhouettes")
eq(written, "silhouettes", "setter returns mode")
eq(savedOpts.water_spawns, "silhouettes", "persisted silhouettes")
eq(savedOpts.enable_water_spawns, true, "enable alias true for silhouettes")

ok = Config.setWaterMons(V.mod, false, "test", { game = V.mod.world.game, confirm = false })
check(ok == true, "setWaterMons accepts legacy false")
eq(savedOpts.water_spawns, "classic_encounters", "false coerces to classic")

ok = Config.setWaterMons(V.mod, true, "test", { game = V.mod.world.game, confirm = false })
eq(savedOpts.water_spawns, "swimming_sprites", "true coerces to swimming")

check(Config.setWaterMons(V.mod, "nope", "t", { confirm = false }) == false,
      "rejects invalid mode")

-- ------- Terrain helpers -------
check(WaterDisplay.isWaterTerrain({ terrain = "water" }), "terrain water")
check(WaterDisplay.isWaterTerrain({ terrain = "fishing" }), "terrain fishing")
check(WaterDisplay.isWaterTerrain({ terrain = "SURF" }), "terrain SURF")
check(not WaterDisplay.isWaterTerrain({ terrain = "grass" }), "terrain grass false")
check(not WaterDisplay.isWaterTerrain({ terrain = "cave" }), "terrain cave false")

check(WaterDisplay.isWaterEntity({ surface = "WATER" }), "entity surface WATER")
check(WaterDisplay.isWaterEntity({ behavior = Behavior.WATER_IDLE }), "entity WATER_IDLE")
check(not WaterDisplay.isWaterEntity({ surface = "GRASS", behavior = Behavior.IDLE_LOOK }),
      "land entity not water")

-- ------- Silhouette tint / proximity -------
local farEnt = { cellX = 10, cellY = 10, surface = "WATER" }
local nearEnt = { cellX = 5, cellY = 5, surface = "WATER" }
local player = { cellX = 5, cellY = 5 }
local farB = WaterDisplay.proximityBrightness(farEnt, player)
local nearB = WaterDisplay.proximityBrightness(nearEnt, player)
check(farB <= 1.05, "far brightness ~1")
check(nearB > farB, "near brighter than far")
check(nearB <= (WaterDisplay.SILHOUETTE.nearBright or 1.85) + 0.01,
      "near brightness capped")

local r, g, b, a = WaterDisplay.silhouetteColor(farEnt, player)
check(r < 0.2 and g < 0.25 and b < 0.3, "far tint is dark")
check(a >= 0.75 and a <= 0.90, "alpha in 75–90%")
local r2, g2, b2 = WaterDisplay.silhouetteColor(nearEnt, player)
check(r2 >= r and g2 >= g and b2 >= b, "near tint not darker than far")
check(r2 < 0.4 and g2 < 0.45, "near still detail-free / dark")

eq(WaterDisplay.silhouetteSink(V.mod), 0, "sink 0 when not silhouettes")
savedOpts.water_spawns = "silhouettes"
eq(WaterDisplay.silhouetteSink(V.mod), 3, "sink 3px in silhouettes")
eq(WaterDisplay.silhouetteSink(V.mod, farEnt), 3, "water entity gets sink")
eq(WaterDisplay.silhouetteSink(V.mod, { surface = "GRASS" }), 0,
   "land entity never gets silhouette sink")
check(WaterDisplay.needsOverlayPresentation(V.mod, farEnt) == false,
      "silhouettes do not force overlay (native sheets in Voxel)")
check(WaterDisplay.needsNativeSilhouetteSheet(V.mod, farEnt) == true,
      "silhouettes need native sheet flag")
savedOpts.water_spawns = "swimming_sprites"
check(WaterDisplay.needsOverlayPresentation(V.mod, farEnt) == false,
      "swimming does not force overlay")
savedOpts.water_spawns = "hidden_silhouettes"
check(WaterDisplay.needsOverlayPresentation(V.mod, farEnt) == false,
      "hidden no longer forces emergency overlay")
check(WaterDisplay.needsNativeHiddenShadow(V.mod, farEnt) == true,
      "hidden needs native flat shadow marker")
check(WaterDisplay.needsNativeSilhouetteSheet(V.mod, farEnt) == false,
      "hidden does not use native silhouette sheet")
check(WaterDisplay.useNativeHiddenShadow(V.mod, farEnt, true) == true,
      "voxel hidden uses native shadow")
check(WaterDisplay.useNativeHiddenShadow(V.mod, farEnt, false) == false,
      "flat hidden keeps circle path")

-- ------- shouldSuppressClassicEncounter -------
local SpawnLogic = V.require("spawn_logic")
local logic = {
  mod = V.mod,
  activeMapId = "ROUTE_19",
}
-- Minimal stub: bind method from prototype via setmetatable if needed.
local suppress = SpawnLogic.shouldSuppressClassicEncounter

-- Mock Safari off by ensuring no safari map helpers trip; use empty world.
V.mod.world.overworld = function()
  return { map = { id = "ROUTE_19" }, player = player }
end

savedOpts.random_encounters = false
savedOpts.water_spawns = "swimming_sprites"
check(suppress(logic, { terrain = "grass", mapId = "ROUTE_1" }) == true,
      "Random Enc OFF suppresses grass")
check(suppress(logic, { terrain = "water", mapId = "ROUTE_19" }) == true,
      "swimming + Random OFF suppresses water")

savedOpts.water_spawns = "classic_encounters"
check(suppress(logic, { terrain = "grass", mapId = "ROUTE_1" }) == true,
      "classic mode still suppresses grass when Random OFF")
check(suppress(logic, { terrain = "water", mapId = "ROUTE_19" }) == false,
      "classic mode allows water when Random OFF")
check(suppress(logic, { terrain = "fishing", mapId = "ROUTE_19" }) == false,
      "classic mode allows fishing when Random OFF")

savedOpts.water_spawns = "disabled"
check(suppress(logic, { terrain = "water", mapId = "ROUTE_19" }) == true,
      "disabled suppresses water")
check(suppress(logic, { terrain = "fishing", mapId = "ROUTE_19" }) == true,
      "disabled suppresses fishing")
savedOpts.random_encounters = true
check(suppress(logic, { terrain = "water", mapId = "ROUTE_19" }) == true,
      "disabled suppresses water even when Random ON")
check(suppress(logic, { terrain = "grass", mapId = "ROUTE_1" }) == false,
      "disabled does not suppress grass when Random ON")

savedOpts.water_spawns = "silhouettes"
savedOpts.random_encounters = true
check(suppress(logic, { terrain = "water" }) == false,
      "silhouettes + Random ON allows classic water (unchanged Random Enc rule)")
savedOpts.random_encounters = false
check(suppress(logic, { terrain = "water" }) == true,
      "silhouettes + Random OFF suppresses water")

-- ------- Menu choices -------
local SpriteStyleMenu = assert(loadfile("lib/sprite_style_menu.lua"))(V)
eq(#SpriteStyleMenu.WATER_CHOICES, 5, "menu has five water choices")
for _, c in ipairs(SpriteStyleMenu.WATER_CHOICES) do
  check(#c.label <= 14, "menu label <= 14: " .. c.label)
  check(Config.VALID_WATER_MODES[c.value] == true, "menu value valid: " .. c.value)
end

-- ------- Label validator -------
local okPy = os.execute("python3 tools/validate_option_labels.py >/dev/null 2>&1")
-- os.execute returns true/0 depending on Lua version
check(okPy == true or okPy == 0, "validate_option_labels passes")

print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("all water_display_modes unit tests passed")
