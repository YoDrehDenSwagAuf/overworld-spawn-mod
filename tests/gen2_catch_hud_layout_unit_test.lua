-- Gold Catch HUD screen position: logical 160×144 top-left, then letterbox.
-- Run: lua tests/gen2_catch_hud_layout_unit_test.lua
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
  dev_overlay = true,
}

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

local BallHud = V.require("catching/hud")

-- Game2:viewport / Chrome.fitScale+fitOrigin for a 1280×720 host window.
-- scale = floor(min(1280/160, 720/144)) = 5
-- gameX = floor((1280 - 160*5) / 2) = 240
-- gameY = floor((720 - 144*5) / 2) = 0
local function goldViewport(w, h)
  local scale = math.max(1, math.floor(math.min(w / 160, h / 144)))
  local gameX = math.floor((w - 160 * scale) / 2)
  local gameY = math.floor((h - 144 * scale) / 2)
  return {
    width = w, height = h,
    gameX = gameX, gameY = gameY,
    gameWidth = 160 * scale, gameHeight = 144 * scale,
    scale = scale,
  }
end

-- ---- Logical 160×144 Gold origin is the top-left corner ----
optionStore.catch_hud_size = 5
local G5 = BallHud.layout(V.mod, 160, "topleft")
eq(G5.anchor, "topleft", "Gold layout uses topleft anchor")
eq(G5.canvasW, 160, "Gold layout uses logical 160, not host width")
eq(G5.hudOriginX, 4, "Gold hudOriginX is GOLD_LOGICAL_X")
eq(G5.hudOriginY, 2, "Gold hudOriginY is GOLD_LOGICAL_Y")
check(G5.startX <= 8, "Gold startX is in the top-left bounds")
check(G5.iconY <= 8, "Gold iconY is in the top-left bounds")
eq(G5.startX, BallHud.GOLD_LOGICAL_X, "Gold startX is the explicit anchor")
eq(G5.iconY, BallHud.GOLD_LOGICAL_Y, "Gold iconY is the explicit anchor")

-- Whole block shares one origin: meter/qty stay relative to the ball row.
local gen1 = BallHud.layout(V.mod, 160)
eq(G5.iconW, gen1.iconW, "Gold icon size matches Gen1 component")
eq(G5.gap, gen1.gap, "Gold gap matches Gen1 component")
eq(G5.qtyY - G5.iconY, gen1.qtyY - gen1.iconY, "quantity stays under icons")
eq(G5.meterY - G5.iconY, gen1.meterY - gen1.iconY, "meter stays under the row")
eq(G5.meterX - G5.startX, gen1.meterX - gen1.startX, "meter X follows the same origin")
check(G5.meterY > G5.qtyY, "Gold meter is below quantity")
check(G5.startX < 40, "Gold row is not the historic top-right startX")
check(gen1.startX > 80, "Gen1 default layout is still top-right")

-- ---- Catch HUD Size 1 / 5 / 10 stay in the same corner; grow inward ----
optionStore.catch_hud_size = 1
local G1 = BallHud.layout(V.mod, 160, "topleft")
optionStore.catch_hud_size = 10
local G10 = BallHud.layout(V.mod, 160, "topleft")
eq(G1.startX, 4, "size 1 stays at Gold origin X")
eq(G5.startX, 4, "size 5 stays at Gold origin X")
eq(G10.startX, 4, "size 10 stays at Gold origin X")
eq(G1.iconY, 2, "size 1 stays at Gold origin Y")
eq(G5.iconY, 2, "size 5 stays at Gold origin Y")
eq(G10.iconY, 2, "size 10 stays at Gold origin Y")
check(G1.iconW < G5.iconW and G5.iconW < G10.iconW, "icons grow 1 < 5 < 10")
check(G10.qtyY > G5.qtyY, "size 10 quantity expands downward")
check(G10.meterY > G5.meterY, "size 10 meter expands downward")
local row1 = G1.startX + 4 * G1.iconW + 3 * G1.gap
local row5 = G5.startX + 4 * G5.iconW + 3 * G5.gap
local row10 = G10.startX + 4 * G10.iconW + 3 * G10.gap
check(row10 > row5 and row5 > row1, "larger HUD expands right (inward)")
check(row10 < 160, "size 10 still fits in logical 160")

-- Host-window ctx.width must not become the layout canvas.
local wide = BallHud.layout(V.mod, 1280, "topleft")
eq(wide.canvasW, 160, "canvasW > 200 clamps to logical 160")
eq(wide.startX, 4, "wide host width still uses Gold top-left origin")

-- ---- 1280×720 host: project to the game viewport corner, not window center ----
local vp = goldViewport(1280, 720)
eq(vp.scale, 5, "1280×720 Chrome.fitScale is 5")
eq(vp.gameX, 240, "1280×720 letterbox origin X")
eq(vp.gameY, 0, "1280×720 letterbox origin Y")
eq(vp.width, 1280, "viewport.width is the host window, not 160")

optionStore.catch_hud_size = 5
local L = BallHud.layout(V.mod, vp.width, "topleft")
eq(L.canvasW, 160, "Gold ignores host ctx.width for layout")
local sx, sy = BallHud.projectLogical(vp, L.hudOriginX, L.hudOriginY)
eq(sx, vp.gameX + 4 * vp.scale, "screen X = gameX + logicalX * scale")
eq(sy, vp.gameY + 2 * vp.scale, "screen Y = gameY + logicalY * scale")
check(sx <= vp.gameX + 8 * vp.scale, "projected origin stays at playfield top-left")
check(sy <= vp.gameY + 8 * vp.scale, "projected origin stays at playfield top")
check(sx < 1280 * 0.35, "Gold HUD is not at the host-window center")
check(math.abs(sx - 640) > 200, "Gold HUD is far from 1280/2")

-- Historic top-right + letterbox landed near the window center — the bug.
local old = BallHud.layout(V.mod, 160)
local oldSx = vp.gameX + old.startX * vp.scale
check(math.abs(oldSx - 640) < 80, "old top-right mapping was near window center")
check(sx < oldSx, "new Gold origin is left of the old centered mapping")

-- Meter projects with the same origin.
local mx, my = BallHud.projectLogical(vp, L.meterX, L.meterY)
check(mx > sx, "meter stays to the right of the Gold origin (same block)")
check(my > sy, "meter stays below the Gold origin")
check(mx < vp.gameX + 160 * vp.scale, "meter stays inside the playfield")

-- Windowed native / 2× / large / "fullscreen" all pin to gameX/gameY.
local function assertCorner(w, h, label)
  local v = goldViewport(w, h)
  local originX, originY = BallHud.projectLogical(v, 4, 2)
  eq(originX, v.gameX + 4 * v.scale, label .. " X uses letterbox origin")
  eq(originY, v.gameY + 2 * v.scale, label .. " Y uses letterbox origin")
  check(originX < w * 0.45, label .. " is not host-centered")
end
assertCorner(160, 144, "native")
assertCorner(320, 288, "2x")
assertCorner(1280, 720, "desktop")
assertCorner(1920, 1080, "fullscreen")

-- Survey zoom must not be part of the HUD transform (viewport.scale is frameFit).
local zoomed = {
  width = 1280, height = 720, gameX = 240, gameY = 0, scale = 5,
}
local zx, zy = BallHud.projectLogical(zoomed, 4, 2)
eq(zx, 260, "HUD ignores World:zoomScale (uses viewport.scale only)")
eq(zy, 10, "HUD Y ignores survey zoom")

-- Flat / Voxel share the same screen-space origin (no world renderer fields).
local flatSx, flatSy = BallHud.projectLogical(vp, 4, 2)
local voxelVp = {
  width = vp.width, height = vp.height,
  gameX = vp.gameX, gameY = vp.gameY, scale = vp.scale,
  cameraMode = "VOXEL",
}
local voxelSx, voxelSy = BallHud.projectLogical(voxelVp, 4, 2)
eq(flatSx, voxelSx, "Voxel HUD X matches Flat")
eq(flatSy, voxelSy, "Voxel HUD Y matches Flat")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("gen2_catch_hud_layout_unit_test: all passed")
