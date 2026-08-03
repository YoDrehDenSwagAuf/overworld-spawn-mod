-- Hidden Idle + Grass Enc + Water Mons + Spawn FX unit tests.
-- Run: lua tests/hidden_idle_unit_test.lua
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
  grass_encounters = nil, -- unset → default hidden
  water_spawns = nil,     -- unset → default true
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
local HiddenIdle = V.require("hidden_idle")
local Surface = V.require("surface")
local SpawnRegions = V.require("spawn_regions")
local SpawnFx = V.require("spawn_fx")

-- ------- Defaults / option schema -------
eq(Config.DEFAULTS.grass_encounters, "hidden", "default grass_encounters is hidden")
eq(Config.grassEncounters(V.mod), "hidden", "grassEncounters() defaults to hidden")
eq(Config.spawnAmount(V.mod), "normal", "spawnAmount defaults to normal")
check(Config.classicGrassEnabled(V.mod) == false, "classicGrassEnabled false when hidden")
check(Config.hiddenGrassEnabled(V.mod) == true, "hiddenGrassEnabled true when hidden")
check(Config.waterMons(V.mod) == true, "waterMons defaults ON")
eq(Config.DEFAULTS.water_spawns, true, "default water_spawns true")

local schema = assert(loadfile("options.lua"))()
local byKey = {}
for _, row in ipairs(schema) do byKey[row.key] = row end
check(byKey.spawn_density == nil, "spawn_density removed from Mod Settings schema")
check(byKey.grass_encounters ~= nil, "grass_encounters present in Mod Settings")
eq(byKey.grass_encounters.default, "hidden", "grass_encounters schema default")
eq(byKey.grass_encounters.label, "Grass Enc", "Grass Enc label")
check(#byKey.grass_encounters.label <= 14, "Grass Enc label <= 14")
check(byKey.sprite_style ~= nil, "Sprite Style remains in Mod Settings")
check(byKey.water_spawns ~= nil, "water_spawns present in Mod Settings")
eq(byKey.water_spawns.label, "Water Mons", "Water Mons label")
check(#byKey.water_spawns.label <= 14, "Water Mons label <= 14")
eq(byKey.water_spawns.default, true, "water_spawns schema default")

-- Legacy grass key migration paths.
savedOpts.grass_encounters = nil
savedOpts.hidden_encounters = "classic"
eq(Config.grassEncounters(V.mod), "classic", "legacy hidden_encounters maps")
savedOpts.hidden_encounters = nil
savedOpts.use_hidden_grass = true
eq(Config.grassEncounters(V.mod), "hidden", "legacy use_hidden_grass true → hidden")
savedOpts.use_hidden_grass = nil
savedOpts.grass_encounters = "both"
eq(Config.grassEncounters(V.mod), "both", "grass_encounters both")
check(Config.classicGrassEnabled(V.mod) == true, "both → classic on")
check(Config.hiddenGrassEnabled(V.mod) == true, "both → hidden on")
savedOpts.grass_encounters = "classic"
check(Config.hiddenGrassEnabled(V.mod) == false, "classic → hidden off")
savedOpts.grass_encounters = nil -- back to default hidden for later tests

-- ------- Density targets -------
eq(HiddenIdle.targetCount(10, "classic"), 0, "classic → 0 hidden")
local h10 = HiddenIdle.targetCount(10, "hidden")
check(h10 >= 2 and h10 <= 4, "hidden ~30% of 10 (got " .. tostring(h10) .. ")")
eq(h10, 3, "hidden floor(10*0.30+0.5)=3")
local b10 = HiddenIdle.targetCount(10, "both")
check(b10 >= 1 and b10 <= 2, "both ~15% of 10 (got " .. tostring(b10) .. ")")
eq(b10, 2, "both floor(10*0.15+0.5)=2")
eq(HiddenIdle.ratioForMode("hidden"), HiddenIdle.RATIO_HIDDEN, "hidden ratio")
eq(HiddenIdle.ratioForMode("both"), HiddenIdle.RATIO_BOTH, "both ratio")
eq(HiddenIdle.ratioForMode("classic"), 0, "classic ratio 0")

-- ------- Behaviour -------
check(Behavior.HIDDEN_IDLE == "HIDDEN_IDLE", "HIDDEN_IDLE constant")
check(Behavior.WATER_IDLE == "WATER_IDLE", "WATER_IDLE constant")
check(Behavior.WATER_WANDER == "WATER_WANDER", "WATER_WANDER constant")
check(Behavior.isHidden(Behavior.HIDDEN_IDLE), "HIDDEN_IDLE is hidden")
check(Behavior.isHiddenIdle(Behavior.HIDDEN_IDLE), "isHiddenIdle")
check(not Behavior.isHiddenIdle(Behavior.HIDDEN_GRASS), "HIDDEN_GRASS is not HIDDEN_IDLE")
check(Behavior.isWater(Behavior.WATER_IDLE), "isWater IDLE")
check(Behavior.isWater(Behavior.WATER_WANDER), "isWater WANDER")
check(Surface.allowsBehavior(Surface.GRASS, Behavior.HIDDEN_IDLE), "grass allows HIDDEN_IDLE")
check(not Surface.allowsBehavior(Surface.CAVE, Behavior.HIDDEN_IDLE), "cave rejects HIDDEN_IDLE")
check(not Surface.allowsBehavior(Surface.WATER, Behavior.HIDDEN_IDLE), "water rejects HIDDEN_IDLE")
check(Surface.allowsBehavior(Surface.WATER, Behavior.WATER_IDLE), "water allows WATER_IDLE")
check(Surface.allowsBehavior(Surface.WATER, Behavior.WATER_WANDER), "water allows WATER_WANDER")
check(not Surface.allowsBehavior(Surface.WATER, Behavior.GRASS_WANDER), "water rejects GRASS_WANDER")

-- Behavior.pick never returns HIDDEN_IDLE (separate spawn track).
do
  local saw = false
  for i = 1, 80 do
    local b = Behavior.pick("PIDGEY", Surface.GRASS, {
      enable_idle = true, enable_wander = true, enable_aggressive = true,
      enable_hidden = true,
    }, function(n)
      if n then return (i % n) + 1 end
      return (i % 100) / 100
    end)
    if b == Behavior.HIDDEN_IDLE then saw = true end
  end
  check(not saw, "Behavior.pick never yields HIDDEN_IDLE")
end

-- Water pick only yields water behaviours.
do
  local bad = false
  for i = 1, 40 do
    local b = Behavior.pick("MAGIKARP", Surface.WATER, {
      enable_idle = true, enable_wander = true, enable_aggressive = false,
      enable_hidden = false,
    }, function(n)
      if n then return (i % n) + 1 end
      return (i % 100) / 100
    end)
    if not Behavior.isWater(b) then bad = true end
  end
  check(not bad, "water Behavior.pick only WATER_*")
end

-- ------- State machine -------
local st = HiddenIdle.newState(function() return 0.5 end)
check(st.active == true, "hiddenIdle.active")
check(st.revealed == false, "not revealed at spawn")
check(st.battleStarted == false, "battle not started")
check(st.nextRustle >= 1.5 and st.nextRustle <= 4.0, "nextRustle in 1.5–4.0")

local entity = {
  behavior = Behavior.HIDDEN_IDLE,
  hiddenIdle = st,
  cellX = 3, cellY = 5,
  behaviorState = Behavior.initState(Behavior.HIDDEN_IDLE, function() return 0.25 end),
  canTriggerBattle = false,
  hiddenBody = true,
}
check(HiddenIdle.bodyHidden(entity), "body hidden before reveal")
check(HiddenIdle.isUnrevealed(entity), "isUnrevealed")
check(SpawnFx.bodyVisible(entity) == false, "SpawnFx body hidden before reveal")
check(SpawnFx.canAct(entity) == false, "SpawnFx canAct false while lurking")
check(SpawnFx.canBattle(entity) == false, "SpawnFx canBattle false while lurking")

-- Force a rustle immediately.
st.rustleTimer = 99
st.nextRustle = 1.5
local ev = HiddenIdle.tick(entity, 0.016)
eq(ev, "rustle", "rustle event fires")
check(entity.grassEffectActive == true, "grassEffectActive after rustle")
check(entity.canTriggerBattle == false, "battle locked during idle")

-- Reveal via SpawnFx timeline
check(HiddenIdle.beginReveal(entity) == true, "beginReveal ok")
SpawnFx.begin(entity, SpawnFx.KIND.HIDDEN_REVEAL)
check(entity.hiddenIdle.revealStarted == true, "revealStarted")
check(entity.canTriggerBattle == false, "battle locked during reveal")

local sawVisible, sawBattle = false, false
local fakeFx = SpawnFx.new(V.mod)
for _ = 1, 40 do
  local e = SpawnFx.updateEntity(entity, 0.02, { spawnFx = fakeFx, map = nil })
  if e == "reveal_visible" then sawVisible = true end
  if e == "reveal_battle" then
    sawBattle = true
    HiddenIdle.markBattleStarted(entity)
  end
end
check(sawVisible, "SpawnFx reveal_visible fired")
check(entity.hiddenIdle.revealed == true, "revealed flag set")
check(entity.visibleSprite == true, "visibleSprite after reveal")
check(sawBattle, "SpawnFx reveal_battle fired")
check(entity.hiddenIdle.battleStarted == true, "battleStarted once")

-- Second battle tick must not re-fire
local again = SpawnFx.updateEntity(entity, 0.05, { spawnFx = fakeFx })
check(again ~= "reveal_battle", "no second battle event")

-- ------- Grass / water spawn FX -------
do
  local e = { cellX = 1, cellY = 1, canTriggerBattle = true }
  SpawnFx.begin(e, SpawnFx.KIND.GRASS)
  check(SpawnFx.bodyVisible(e) == false, "grass spawn body hidden at t0")
  check(SpawnFx.canAct(e) == false, "grass spawn cannot act at t0")
  check(SpawnFx.canBattle(e) == false, "grass spawn cannot battle at t0")
  local visibleAt = false
  for _ = 1, 30 do
    local ev2 = SpawnFx.updateEntity(e, 0.02, { spawnFx = fakeFx })
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
  check(e._waterSplash ~= nil or e.spawnFx.splashFired == true, "splash fired flag")
end

do
  local fx = SpawnFx.new(V.mod)
  check(fx:grassRustle(nil, 4, 5, "small") == true, "grassRustle queues without map")
  eq(fx:activeRustleCount(), 1, "one rustle active")
  for _ = 1, 5 do fx:update(0.1) end -- duration ~0.30; dt capped at 0.1
  eq(fx:activeRustleCount(), 0, "rustle expires")
  check(fx.rustleEvents >= 1, "rustleEvents counted")
end

-- ------- Reservations -------
local logic = { hiddenReserved = {}, byMap = {}, spawns = {}, entities = {}, mod = V.mod }
HiddenIdle.initReservations(logic)
check(HiddenIdle.reserve(logic, 2, 4, "a") == true, "reserve a")
check(HiddenIdle.reserve(logic, 2, 4, "b") == false, "no double reserve")
check(HiddenIdle.isReserved(logic, 2, 4) == true, "isReserved")
eq(HiddenIdle.reservedId(logic, 2, 4), "a", "reservedId")
HiddenIdle.release(logic, 2, 4, "a")
check(not HiddenIdle.isReserved(logic, 2, 4), "released")

-- ------- Setters persist shared keys -------
local okSpawn = Config.setSpawnAmount(V.mod, "high", "start_menu", {
  game = V.mod.world.game, confirm = false,
})
check(okSpawn == true, "setSpawnAmount accepts high")
eq(savedOpts.spawn_density, "high", "spawn_density written")
eq(Config.spawnAmount(V.mod), "high", "spawnAmount reads high")

local okGrass = Config.setGrassEncounters(V.mod, "both", "start_menu", {
  game = V.mod.world.game, confirm = false,
})
check(okGrass == true, "setGrassEncounters accepts both")
eq(savedOpts.grass_encounters, "both", "grass_encounters written")
eq(Config.grassEncounters(V.mod), "both", "grassEncounters reads both")

local okWater = Config.setWaterMons(V.mod, false, "start_menu", {
  game = V.mod.world.game, confirm = false,
})
check(okWater == true, "setWaterMons accepts false")
eq(savedOpts.water_spawns, false, "water_spawns written false")
check(Config.waterMons(V.mod) == false, "waterMons reads OFF")
Config.setWaterMons(V.mod, true, "start_menu", {
  game = V.mod.world.game, confirm = false,
})
check(Config.waterMons(V.mod) == true, "waterMons back ON")

check(Config.setGrassEncounters(V.mod, "nope", "t", { confirm = false }) == false,
      "rejects invalid grass mode")
check(Config.setSpawnAmount(V.mod, "nope", "t", { confirm = false }) == false,
      "rejects invalid spawn amount")

-- ------- Labels / menu constants -------
local SpriteStyleMenu = assert(loadfile("lib/sprite_style_menu.lua"))(V)
eq(SpriteStyleMenu.LABEL_STYLE, "SPRITE STYLE", "style label")
eq(SpriteStyleMenu.LABEL_SPAWN, "SPAWN AMOUNT", "spawn label")
eq(SpriteStyleMenu.LABEL_GRASS, "GRASS ENC", "grass label")
eq(SpriteStyleMenu.LABEL_WATER, "WATER MONS", "water label")
check(#SpriteStyleMenu.LABEL_STYLE <= 14, "SPRITE STYLE <= 14")
check(#SpriteStyleMenu.LABEL_SPAWN <= 14, "SPAWN AMOUNT <= 14")
check(#SpriteStyleMenu.LABEL_GRASS <= 14, "GRASS ENC <= 14")
check(#SpriteStyleMenu.LABEL_WATER <= 14, "WATER MONS <= 14")
eq(#SpriteStyleMenu.SPAWN_CHOICES, 4, "four spawn choices")
eq(#SpriteStyleMenu.GRASS_CHOICES, 3, "three grass choices")
eq(#SpriteStyleMenu.WATER_CHOICES, 2, "two water choices")

-- Visible spawn target still uses spawn_density values.
local tLow = SpawnRegions.targetCount({
  eligibleTiles = 48, minVisible = 1, maxVisible = 12,
  tilesPerAdditional = 24, density = "low", mapSpan = 30,
})
local tHigh = SpawnRegions.targetCount({
  eligibleTiles = 48, minVisible = 1, maxVisible = 12,
  tilesPerAdditional = 24, density = "high", mapSpan = 30,
})
check(tHigh > tLow, "high density > low density")

-- ------- HUD summary -------
logic.targetHiddenCount = 3
logic.activeMapId = "route1"
logic.byMap.route1 = { "h1", "h2" }
logic.spawns.h1 = { state = "available", behavior = "HIDDEN_IDLE" }
logic.spawns.h2 = { state = "available", behavior = "HIDDEN_IDLE" }
logic.entities.h1 = { hiddenIdle = { active = true, revealed = false } }
logic.entities.h2 = { hiddenIdle = { active = true, revealed = true } }
local sum = HiddenIdle.hudSummary(logic)
eq(sum.mode, "both", "hud mode both")
eq(sum.classicOn, true, "both → classic on")
eq(sum.target, 3, "hud target")
eq(sum.loaded, 2, "hud loaded")
eq(sum.revealed, 1, "hud revealed")

-- Version
local mf = io.open("manifest.json", "r")
local mft = mf:read("*a")
mf:close()
check(mft:find('"version"%s*:%s*"1%.2%.0"') ~= nil, "manifest version 1.2.0")

print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("all hidden_idle unit tests passed")
