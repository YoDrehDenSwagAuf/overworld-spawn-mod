-- Config.catchHudSize + BallHud layout + CatchSfx helper.
-- Run: lua tests/overworld_catch_hud_sfx_unit_test.lua
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

local optionStore = {
  enabled = true,
  overworld_catching = true,
  catch_hud_size = 5,
}
local soundCalls = {}
package.preload["src.core.Sound"] = function()
  return {
    play = function(data, name)
      soundCalls[#soundCalls + 1] = { data = data, name = name }
    end,
  }
end

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    options = {
      get = function(_, k)
        if optionStore[k] ~= nil then return optionStore[k] end
        return nil
      end,
      set = function(_, k, v) optionStore[k] = v end,
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

local Config = V.require("config")
local BallHud = V.require("catching/hud")
local CatchSfx = V.require("catching/catch_sfx")

-- ---- Config.catchHudSize clamping ----
optionStore.catch_hud_size = nil
eq(Config.catchHudSize(V.mod), 5, "nil -> 5")
optionStore.catch_hud_size = 0
eq(Config.catchHudSize(V.mod), 0, "0 -> 0 (hidden)")
eq(Config.catchHudEnabled(V.mod), false, "size 0 → HUD disabled")
eq(Config.catchHudScale(V.mod), 1, "size 0 scale is unused 1, not 0")
optionStore.catch_hud_size = -3
eq(Config.catchHudSize(V.mod), 0, "-3 -> 0")
optionStore.catch_hud_size = 1
eq(Config.catchHudSize(V.mod), 1, "1 -> 1")
eq(Config.catchHudEnabled(V.mod), true, "size 1 → HUD enabled")
optionStore.catch_hud_size = 5
eq(Config.catchHudSize(V.mod), 5, "5 -> 5")
optionStore.catch_hud_size = 10
eq(Config.catchHudSize(V.mod), 10, "10 -> 10")
optionStore.catch_hud_size = 11
eq(Config.catchHudSize(V.mod), 10, "11 -> 10")
optionStore.catch_hud_size = 5.9
eq(Config.catchHudSize(V.mod), 5, "5.9 floors to 5")
optionStore.catch_hud_size = "7"
eq(Config.catchHudSize(V.mod), 7, "string 7 -> 7")

-- ---- Scale + pixel mapping: 1 < 5 < 10, clearly stepped ----
optionStore.catch_hud_size = 1
local s1 = Config.catchHudScale(V.mod)
local px1 = Config.catchHudIconPx(V.mod)
optionStore.catch_hud_size = 5
local s5 = Config.catchHudScale(V.mod)
local px5 = Config.catchHudIconPx(V.mod)
optionStore.catch_hud_size = 10
local s10 = Config.catchHudScale(V.mod)
local px10 = Config.catchHudIconPx(V.mod)
check(math.abs(s1 - 0.75) < 1e-6, "size 1 scale 0.75")
check(math.abs(s5 - (0.75 + 4 * 0.75 / 9)) < 1e-6, "size 5 scale ~1.083")
check(math.abs(s10 - 1.5) < 1e-6, "size 10 scale 1.50")
eq(px1, 11, "size 1 -> 11px")
eq(px5, 15, "size 5 -> 15px")
eq(px10, 21, "size 10 -> 21px")
check(px1 < px5 and px5 < px10, "1 < 5 < 10 pixel mapping")
check(px10 - px5 >= 5, "size 10 clearly larger than size 5")
eq(BallHud.iconPx(V.mod), 21, "BallHud.iconPx follows setting")

-- ---- Layout adapts as a component; four icons fit; meter below quantity ----
optionStore.catch_hud_size = 1
local L1 = BallHud.layout(V.mod, 160)
optionStore.catch_hud_size = 5
local L5 = BallHud.layout(V.mod, 160)
optionStore.catch_hud_size = 10
local L10 = BallHud.layout(V.mod, 160)
check(L1.iconW < L5.iconW and L5.iconW < L10.iconW, "layout iconW grows with setting")
check(L1.startX > 0 and L5.startX > 0 and L10.startX >= 2, "icons stay on canvas")
local function rowFits(L)
  local rowW = 4 * L.iconW + 3 * L.gap
  return L.startX + rowW <= 160 - 2
end
check(rowFits(L1) and rowFits(L5) and rowFits(L10), "four icons fit at 1/5/10")
check(L10.gap <= L5.gap, "gap shrinks or stays at large size")
check(L5.qtyY > L5.iconY + L5.iconW - 1, "quantity below icons")
check(L10.qtyY > L5.qtyY, "quantity Y moves down as icons grow")
check(L5.meterY > L5.qtyY, "power meter below quantity")
check(L10.meterY > L10.qtyY, "large HUD meter below quantity")
check(L10.meterY > L5.meterY, "meter Y moves down with larger HUD")
eq(L5.selectedBorder, L5.iconW + 2, "selected border follows icon size (5)")
eq(L10.selectedBorder, L10.iconW + 2, "selected border follows icon size (10)")
-- Gen1 coordinates must stay exactly the historic top-right row.
eq(L1.startX, 106, "Gen1 size 1 startX unchanged")
eq(L5.startX, 87, "Gen1 size 5 startX unchanged")
eq(L10.startX, 69, "Gen1 size 10 startX unchanged")
eq(L1.iconY, 2, "Gen1 size 1 iconY unchanged")
eq(L5.iconY, 2, "Gen1 size 5 iconY unchanged")
eq(L10.iconY, 2, "Gen1 size 10 iconY unchanged")
eq(L5.meterX, 138, "Gen1 meter stays at canvasW-22")
eq(L1.anchor, "topright", "default layout anchor is topright")

-- Live: changing option updates layout without re-register
optionStore.catch_hud_size = 3
eq(BallHud.iconPx(V.mod), 13, "live size 3 -> 13px")
optionStore.catch_hud_size = 9
eq(BallHud.iconPx(V.mod), 20, "live size 9 -> 20px")

-- Saved-bucket preference (menus write loader/save buckets, not always options:get)
do
  local bucket = {}
  local modBucket = {
    id = "overworld_wild_spawns",
    world = {
      game = {
        mods = { loader = { modOptions = { overworld_wild_spawns = bucket } } },
      },
    },
    options = {
      get = function(_, k)
        -- Stale options:get still says 5 while bucket says 10.
        if k == "catch_hud_size" then return 5 end
        return nil
      end,
    },
  }
  bucket.catch_hud_size = 10
  eq(Config.catchHudSize(modBucket), 10, "peekSavedOption wins over stale options:get")
  eq(Config.catchHudIconPx(modBucket), 21, "bucket size 10 -> 21px icons")
end

-- Schema
local schema = assert(loadfile("options.lua"))()
local byKey = {}
for _, row in ipairs(schema) do byKey[row.key] = row end
check(byKey.catch_hud_size ~= nil, "catch_hud_size in schema")
eq(byKey.catch_hud_size.type, "number", "number type")
eq(byKey.catch_hud_size.default, 5, "default 5")
eq(byKey.catch_hud_size.min, 0, "min 0")
eq(byKey.catch_hud_size.max, 10, "max 10")
eq(Config.DEFAULTS.catch_hud_size, 5, "DEFAULTS.catch_hud_size")

-- Verified Gen1 keys (do not guess SFX_* names)
eq(CatchSfx.keyFor("throw"), "Ball_Toss", "throw key")
eq(CatchSfx.keyFor("impact"), "Ball_Poof", "impact key")
eq(CatchSfx.keyFor("wobble"), "Tink", "wobble key")
eq(CatchSfx.keyFor("break"), "Ball_Poof", "break key")
eq(CatchSfx.keyFor("click"), nil, "no native click key")
eq(CatchSfx.keyFor("caught"), "Caught_Mon", "caught fanfare key")

-- Audio helper safety
soundCalls = {}
check(CatchSfx.playNativeCatchSfx(nil, "throw") == false, "missing game -> no crash")
check(CatchSfx.playNativeCatchSfx({}, "throw") == false, "missing data -> no crash")
check(#soundCalls == 0, "no Sound.play without data")

local gameMissingKey = {
  data = { audio = { sfx = { Ball_Toss = {} } } },
}
soundCalls = {}
check(CatchSfx.playNativeCatchSfx(gameMissingKey, "wobble") == false, "missing key -> no crash")
eq(#soundCalls, 0, "missing key does not call Sound.play")

local gameOk = {
  data = {
    audio = {
      sfx = {
        Ball_Toss = { address = 1 },
        Ball_Poof = { address = 2 },
        Tink = { address = 3 },
        Caught_Mon = { address = 4 },
      },
    },
  },
}
soundCalls = {}
check(CatchSfx.playNativeCatchSfx(gameOk, "throw") == true, "verified key plays")
eq(#soundCalls, 1, "Sound.play called once")
eq(soundCalls[1].name, "Ball_Toss", "played Ball_Toss")
eq(soundCalls[1].data, gameOk.data, "passed game.data")

soundCalls = {}
CatchSfx.playNativeCatchSfx(gameOk, "caught")
eq(soundCalls[1].name, "Caught_Mon", "caught uses Caught_Mon")

soundCalls = {}
check(CatchSfx.playNativeCatchSfx(gameOk, "click") == false, "click role is silent")
eq(#soundCalls, 0, "click does not invent a sound")

-- Projectile size contract untouched — HUD scale must never couple to world Ball.
local Projectile = V.require("catching/projectile")
eq(Projectile.BALL_VISUAL_PX, 6, "projectile visual unchanged")
local projSrc = assert(io.open("lib/catching/projectile.lua", "r")):read("*a")
check(not projSrc:find("catch_hud_size", 1, true), "projectile.lua ignores catch_hud_size")
check(not projSrc:find("catchHudIconPx", 1, true), "projectile.lua ignores catchHudIconPx")
check(not projSrc:find("BallHud", 1, true), "projectile.lua ignores BallHud")
local hudSrc = assert(io.open("lib/catching/hud.lua", "r")):read("*a")
check(hudSrc:find("ballHudImage", 1, true) ~= nil, "HUD uses ballHudImage path")
check(hudSrc:find("Thrown Balls stay", 1, true) ~= nil
   or hudSrc:find("thrown Balls stay", 1, true) ~= nil,
  "HUD documents world Ball separation")
local catchSrc = assert(io.open("lib/catching/init.lua", "r")):read("*a")
check(catchSrc:find("function OverworldCatching:ballHudImage", 1, true) ~= nil,
  "ballHudImage helper exists")
check(catchSrc:find("BALL_ASSET_SM", 1, true) ~= nil, "projectile still has sm assets")
-- Full HUD assets are larger-opaque than *_sm (root cause of invisible scaling).
local function fileBytes(path)
  local f = assert(io.open(path, "rb")); local d = f:read("*a"); f:close(); return d
end
check(#fileBytes("assets/balls/poke_ball.png") > 0, "full poke_ball asset present")
check(#fileBytes("assets/balls/poke_ball_sm.png") > 0, "sm poke_ball asset present")
check(fileBytes("assets/balls/poke_ball.png") ~= fileBytes("assets/balls/poke_ball_sm.png"),
  "HUD full asset differs from world sm asset")

-- ---- shouldDraw: size 0 hides HUD; 1–10 still draw when catching allows ----
do
  local hud = BallHud.new(V.mod, {
    canShowHud = function() return true end,
  })
  optionStore.catch_hud_size = 5
  eq(hud:shouldDraw({}, {}), true, "CASE A: size 5 shouldDraw")
  optionStore.catch_hud_size = 0
  eq(hud:shouldDraw({}, {}), false, "CASE B: size 0 shouldDraw")
  optionStore.catch_hud_size = 5
  eq(hud:shouldDraw({}, {}), true, "CASE F: live 0→5 shouldDraw again")
  optionStore.catch_hud_size = 0
  eq(hud:draw("canvas", {}), "canvas", "size 0 draw early-outs")
end

-- Settings menu lists CATCH HUD near OW CATCH
local SettingsMenus = V.require("settings_menus")
check(SettingsMenus.WILDS_OPTION_KEYS, "WILDS_OPTION_KEYS present")
local hasHudKey = false
for _, k in ipairs(SettingsMenus.WILDS_OPTION_KEYS) do
  if k == "catch_hud_size" then hasHudKey = true end
end
check(hasHudKey, "catch_hud_size in WILDS_OPTION_KEYS")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("overworld_catch_hud_sfx_unit_test: all passed")
