-- Flat 2D water presentation contract / regression tests.
-- Ensures Hidden circle + Silhouette tint helpers stay pixel-contract stable.
-- Run: luajit tests/water_flat_presentation_contract_test.lua
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

local savedOpts = { water_spawns = "swimming_sprites", sprite_style = "pokemmo" }
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    options = { get = function(_, key) return savedOpts[key] end },
    world = {
      game = {
        save = { options = { modOptions = { overworld_wild_spawns = savedOpts } } },
        mods = { modOptions = { overworld_wild_spawns = savedOpts } },
      },
      overworld = function()
        return { cameraMode = "FLAT", player = { cellX = 5, cellY = 5 } }
      end,
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

local WaterDisplay = V.require("water_display")

-- Snapshot of Flat 2D Hidden circle contract (must not drift).
local H = WaterDisplay.HIDDEN
eq(H.r, 0.05, "HIDDEN.r")
eq(H.g, 0.08, "HIDDEN.g")
eq(H.b, 0.10, "HIDDEN.b")
eq(H.alphaFar, 0.55, "HIDDEN.alphaFar")
eq(H.alphaNear, 0.78, "HIDDEN.alphaNear")
eq(H.radius, 3.5, "HIDDEN.radius")
eq(H.bobAmp, 0.8, "HIDDEN.bobAmp")

-- Snapshot of Flat 2D Silhouette tint contract.
local S = WaterDisplay.SILHOUETTE
eq(S.r, 0.04, "SILHOUETTE.r")
eq(S.g, 0.11, "SILHOUETTE.g")
eq(S.b, 0.14, "SILHOUETTE.b")
eq(S.alpha, 0.82, "SILHOUETTE.alpha")
eq(S.sinkPx, 3, "SILHOUETTE.sinkPx")
eq(S.farTiles, 3, "SILHOUETTE.farTiles")
eq(S.nearTiles, 2, "SILHOUETTE.nearTiles")
eq(S.nearBright, 1.85, "SILHOUETTE.nearBright")

savedOpts.water_spawns = "silhouettes"
local water = { surface = "WATER", cellX = 5, cellY = 5 }
eq(WaterDisplay.silhouetteSink(V.mod, water), 3, "flat sink still 3")
local player = { cellX = 5, cellY = 5 }
local r, g, b, a = WaterDisplay.silhouetteColor(water, player)
check(r > 0 and r < 0.35, "silhouetteColor r in range")
check(g > 0 and g < 0.40, "silhouetteColor g in range")
check(b > 0 and b < 0.42, "silhouetteColor b in range")
eq(a, 0.82, "silhouetteColor alpha")
local brightNear = WaterDisplay.proximityBrightness(water, player)
check(brightNear > 1.3, "near proximity brightens")
local brightFar = WaterDisplay.proximityBrightness(water, { cellX = 20, cellY = 20 })
eq(brightFar, 1, "far proximity = 1")

-- Call-contract: helpers are callable without love.graphics (no crash).
local drew = false
WaterDisplay.withSilhouetteTint(water, player, function()
  drew = true
end)
check(drew, "withSilhouetteTint invokes drawFn without love")

-- drawHiddenCircle is a no-op without love.graphics (must not error).
local okCircle = pcall(WaterDisplay.drawHiddenCircle, {
  px = 16, py = 32, cellX = 1, cellY = 2, surfaceVisualOffset = 2, waterSink = 2,
}, 0, 0, { player = player })
check(okCircle, "drawHiddenCircle safe without love")

-- Land entities never take silhouette sink / water presentation helpers wrongly.
eq(WaterDisplay.silhouetteSink(V.mod, { surface = "GRASS" }), 0, "land sink 0")
check(WaterDisplay.isWaterEntity({ surface = "GRASS" }) == false, "grass not water")

-- Voxel-only helpers must not alter Flat routing.
check(WaterDisplay.useWaterShadowPresentation(V.mod, water, false) == false,
      "flat camera never uses voxel water shadow presentation")
check(WaterDisplay.needsOverlayPresentation(V.mod, water) == false,
      "overlay presentation stays false")

print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("all water_flat_presentation_contract tests passed")
