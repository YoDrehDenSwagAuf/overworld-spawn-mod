-- Voxel water-shadow presentation unit tests (no Gen1Recomp / DS required).
-- Run: luajit tests/water_shadow_unit_test.lua
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
  sprite_style = "pokemmo",
  water_spawns = "swimming_sprites",
}

local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    options = {
      get = function(_, key) return savedOpts[key] end,
    },
    assets = {
      path = function(_, rel) return "mods/overworld_wild_spawns/" .. rel end,
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
      overworld = function()
        return { cameraMode = "FLAT", player = { cellX = 1, cellY = 1 } }
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

local Config = V.require("config")
local WaterDisplay = V.require("water_display")
local VoxelWaterShadows = V.require("voxel_water_shadows")
local WaterShadowRenderer = V.require("water_shadow_renderer")
local SpriteResolver = V.require("sprite_resolver")

------------------------------------------------------------------ assets
local asset = VoxelWaterShadows.HIDDEN_RELATIVE
local f = io.open(asset, "rb")
check(f ~= nil, "water_hidden_shadow.png exists")
if f then
  local data = f:read("*a")
  f:close()
  check(data:sub(1, 8) == "\137PNG\r\n\26\n", "asset is PNG")
  local w = data:byte(17) * 16777216 + data:byte(18) * 65536
    + data:byte(19) * 256 + data:byte(20)
  local h = data:byte(21) * 16777216 + data:byte(22) * 65536
    + data:byte(23) * 256 + data:byte(24)
  eq(w, 16, "asset width 16")
  eq(h, 16, "asset height 16 (single frame)")
  -- No '?' glyph: opaque region must stay a compact oval near centre.
  check(not data:find("?", 1, true), "asset bytes contain no '?' text")
end

------------------------------------------------------------------ defs / modes
local def = VoxelWaterShadows.hiddenDef(V.mod)
eq(def.frames, 1, "hidden def frames=1")
check(def.walker ~= true, "hidden def not a walker sheet")
check(VoxelWaterShadows.isWaterShadowDef(def), "hidden def tagged")
eq(def[VoxelWaterShadows.DEF_KIND], "hidden", "hidden kind")

local silDef = VoxelWaterShadows.tagDef({
  image = "assets/generated/swimming_silhouette_runtime/054-normal.png",
  frames = 6, walker = true, trueColor = true,
}, "silhouette")
check(VoxelWaterShadows.isWaterShadowDef(silDef), "silhouette def tagged")
eq(VoxelWaterShadows.kindFor(silDef), "silhouette", "silhouette kind")

local waterEnt = {
  surface = "WATER", behavior = "WATER_IDLE", overworldWildSpawn = true,
  state = "active", px = 32, py = 48, cellX = 2, cellY = 3,
}
eq(VoxelWaterShadows.shadowModeFor(V.mod, waterEnt, false),
   VoxelWaterShadows.MODE.NONE, "flat → no shadow mode")
savedOpts.water_spawns = "hidden_silhouettes"
eq(VoxelWaterShadows.shadowModeFor(V.mod, waterEnt, true),
   VoxelWaterShadows.MODE.HIDDEN_WORLD_QUAD, "voxel hidden → hidden_world_quad")
eq(VoxelWaterShadows.presentationFor(V.mod, waterEnt, true),
   "HIDDEN_WORLD_QUAD", "presentation HIDDEN_WORLD_QUAD")
savedOpts.water_spawns = "silhouettes"
eq(VoxelWaterShadows.shadowModeFor(V.mod, waterEnt, true),
   VoxelWaterShadows.MODE.SPECIES_WORLD_QUAD, "voxel silhouettes → species_world_quad")
eq(VoxelWaterShadows.presentationFor(V.mod, waterEnt, true),
   "SPECIES_WORLD_QUAD", "presentation SPECIES_WORLD_QUAD")
savedOpts.water_spawns = "swimming_sprites"
eq(VoxelWaterShadows.shadowModeFor(V.mod, waterEnt, true),
   VoxelWaterShadows.MODE.NONE, "voxel swimming → none")
eq(VoxelWaterShadows.presentationFor(V.mod, waterEnt, true),
   "SWIMMING_CHARACTER", "presentation SWIMMING_CHARACTER")
eq(VoxelWaterShadows.presentationFor(V.mod, waterEnt, false),
   "FLAT_2D", "flat water presentation FLAT_2D")

------------------------------------------------------------------ Flat 2D contract
savedOpts.water_spawns = "hidden_silhouettes"
check(WaterDisplay.needsOverlayPresentation(V.mod, waterEnt) == false,
      "no emergency overlay")
check(WaterDisplay.useNativeHiddenShadow(V.mod, waterEnt, false) == false,
      "flat hidden not native sheet")
check(WaterDisplay.useNativeHiddenShadow(V.mod, waterEnt, true) == true,
      "voxel hidden uses native marker")
-- Flat Hidden circle contract (pixel-identical helpers).
eq(WaterDisplay.HIDDEN.radius, 3.5, "flat hidden radius unchanged")
eq(WaterDisplay.HIDDEN.r, 0.05, "flat hidden r unchanged")
eq(WaterDisplay.HIDDEN.g, 0.08, "flat hidden g unchanged")
eq(WaterDisplay.HIDDEN.b, 0.10, "flat hidden b unchanged")
eq(WaterDisplay.HIDDEN.alphaFar, 0.55, "flat hidden alphaFar unchanged")
eq(WaterDisplay.HIDDEN.alphaNear, 0.78, "flat hidden alphaNear unchanged")
eq(WaterDisplay.HIDDEN.bobAmp, 0.8, "flat hidden bobAmp unchanged")
check(type(WaterDisplay.drawHiddenCircle) == "function", "drawHiddenCircle exists")

savedOpts.water_spawns = "silhouettes"
eq(WaterDisplay.silhouetteSink(V.mod, waterEnt), 3, "flat silhouette sink unchanged")
eq(WaterDisplay.SILHOUETTE.r, 0.04, "flat silhouette r unchanged")
eq(WaterDisplay.SILHOUETTE.g, 0.11, "flat silhouette g unchanged")
eq(WaterDisplay.SILHOUETTE.b, 0.14, "flat silhouette b unchanged")
eq(WaterDisplay.SILHOUETTE.alpha, 0.82, "flat silhouette alpha unchanged")
eq(WaterDisplay.SILHOUETTE.sinkPx, 3, "flat silhouette sinkPx unchanged")
eq(WaterDisplay.SILHOUETTE.nearBright, 1.85, "flat silhouette nearBright unchanged")
check(type(WaterDisplay.withSilhouetteTint) == "function", "withSilhouetteTint exists")
eq(WaterDisplay.silhouetteSink(V.mod, { surface = "WATER", waterSilhouetteSheet = true }),
   0, "native sheet skips runtime sink")

------------------------------------------------------------------ resolver routing
local RuntimeSheets = V.require("runtime_sheets")
local render = { runtimeSheets = RuntimeSheets.new(V.mod) }
render.runtimeSheets:load()
local SpriteProviders = V.require("sprite_providers")
local providers = SpriteProviders.new(V.mod, render)
local WaterSpriteRegistry = V.require("water_sprite_registry")
local reg = WaterSpriteRegistry.new(V.mod)
reg:load()
local resolver = SpriteResolver.new(V.mod, providers, reg)

savedOpts.water_spawns = "hidden_silhouettes"
local hidden = resolver:resolveWaterSprite(waterEnt, {
  style = "pokemmo",
  speciesId = 54,
  variant = "normal",
  voxelActive = true,
  nativeHiddenShadow = true,
})
check(hidden ~= nil, "voxel hidden resolves")
eq(hidden.providerId, "water_hidden_shadow", "hidden provider id")
check(hidden.waterHiddenShadow == true, "waterHiddenShadow flag")
check(hidden.waterFlatShadow == true, "waterFlatShadow flag")
check(VoxelWaterShadows.isWaterShadowDef(hidden.def), "resolved def tagged")
check(hidden.def.image:find("water_hidden_shadow", 1, true)
      or hidden.def.image:find("hidden-water-shadow", 1, true),
      "resolved image is shadow marker")
eq(hidden.def.frames, 1, "resolved hidden frames=1")

local flatHidden = resolver:resolveWaterSprite(waterEnt, {
  style = "pokemmo",
  speciesId = 54,
  variant = "normal",
  voxelActive = false,
})
check(flatHidden == nil or flatHidden.providerId ~= "water_hidden_shadow",
      "flat hidden does not bind shadow marker")

local keyFlat = resolver:cacheKey(waterEnt, {
  style = "pokemmo", speciesId = 54, variant = "normal", form = nil,
  voxelActive = false,
}, "water")
local keyVoxel = resolver:cacheKey(waterEnt, {
  style = "pokemmo", speciesId = 54, variant = "normal", form = nil,
  voxelActive = true,
}, "water")
check(keyFlat ~= keyVoxel, "flat/voxel cache keys differ")
check(keyVoxel:find("flat_world", 1, true) ~= nil, "voxel key includes shadow mode")
check(keyVoxel:find("water_hidden_shadow", 1, true) ~= nil
      or keyVoxel:find("hidden-water-shadow", 1, true) ~= nil,
      "voxel hidden key includes asset path")

------------------------------------------------------------------ frame / mirror
local frame, mirror = VoxelWaterShadows.frameFor(silDef, "down", 0, false)
eq(frame, 0, "stand down frame 0")
check(mirror == false, "stand down no mirror")
frame, mirror = VoxelWaterShadows.frameFor(silDef, "up", 0, false)
eq(frame, 1, "stand up frame 1")
frame, mirror = VoxelWaterShadows.frameFor(silDef, "left", 0, false)
eq(frame, 2, "stand left frame 2")
frame, mirror = VoxelWaterShadows.frameFor(silDef, "right", 0, false)
eq(frame, 2, "stand right uses left frame")
check(mirror == true, "right mirrors")
frame, mirror = VoxelWaterShadows.frameFor(silDef, "down", 1, false)
eq(frame, 3, "walk down frame 3")
frame, mirror = VoxelWaterShadows.frameFor(silDef, "down", 1, true)
check(mirror == true, "walk down phase+flip mirrors")
frame, mirror = VoxelWaterShadows.frameFor(def, "right", 1, true)
eq(frame, 0, "hidden ignores facing/phase")
check(mirror == false, "hidden never mirrors")

------------------------------------------------------------------ transform / size / height
check(VoxelWaterShadows.FLAT_TILT_RAD == math.pi / 2, "fully horizontal tilt")
check(VoxelWaterShadows.SURFACE_EPSILON >= 0.02
      and VoxelWaterShadows.SURFACE_EPSILON <= 0.15,
      "surface epsilon in 0.02–0.15")
check(VoxelWaterShadows.HIDDEN_WIDTH >= 8 and VoxelWaterShadows.HIDDEN_WIDTH <= 12,
      "hidden width 8–12")
check(VoxelWaterShadows.HIDDEN_DEPTH >= 5 and VoxelWaterShadows.HIDDEN_DEPTH <= 9,
      "hidden depth 5–9")
check(VoxelWaterShadows.SPECIES_WIDTH >= 14 and VoxelWaterShadows.SPECIES_WIDTH <= 16,
      "species width 14–16")
check(VoxelWaterShadows.SPECIES_DEPTH >= 9 and VoxelWaterShadows.SPECIES_DEPTH <= 13,
      "species depth 9–13")

local y, src = VoxelWaterShadows.waterSurfaceAt(nil, 1, 1, { groundHeight = 0 })
eq(y, VoxelWaterShadows.WATER_SURFACE_FALLBACK_BIAS, "fallback water surface Y")
check(src == "fallback_ground_bias", "fallback source documented")
local y2 = select(1, VoxelWaterShadows.waterSurfaceAt(nil, 1, 1, { groundHeight = 2 }))
eq(y2, 2 + VoxelWaterShadows.WATER_SURFACE_FALLBACK_BIAS, "fallback adds bias to ground")

-- Fake Mat4 to verify horizontal matrix composition (no camera yaw / billboard).
local calls = {}
local Mat4 = {
  translate = function(x, y, z)
    calls[#calls + 1] = { "translate", x, y, z }
    return { kind = "t", x = x, y = y, z = z }
  end,
  rotateX = function(a)
    calls[#calls + 1] = { "rotateX", a }
    return { kind = "rx", a = a }
  end,
  scale = function(x, y, z)
    calls[#calls + 1] = { "scale", x, y, z }
    return { kind = "s", x = x, y = y, z = z }
  end,
  mul = function(a, b)
    calls[#calls + 1] = { "mul", a.kind, b.kind }
    return { kind = "m", a = a, b = b }
  end,
}
calls = {}
local model = VoxelWaterShadows.horizontalMatrix(Mat4, 40, 4.08, 56, 15, 11, true)
check(model ~= nil, "horizontal matrix built")
local hasRot = false
local hasBillboardYaw = false
for _, c in ipairs(calls) do
  if c[1] == "rotateX" and math.abs(c[2] + math.pi / 2) < 1e-9 then
    hasRot = true
  end
  if c[1] == "rotateY" or c[1] == "billboard" then
    hasBillboardYaw = true
  end
end
check(hasRot, "matrix includes rotateX(-π/2)")
check(not hasBillboardYaw, "matrix has no billboard/yaw")

------------------------------------------------------------------ character filter / collect
savedOpts.water_spawns = "hidden_silhouettes"
waterEnt.voxelWaterShadowPresentation = true
check(VoxelWaterShadows.shouldFilterCharacterBody(waterEnt, V.mod) == true,
      "hidden water shadow filtered from character pass")
local land = {
  overworldWildSpawn = true, surface = "GRASS", behavior = "WANDER",
  state = "active", px = 0, py = 0,
}
check(VoxelWaterShadows.shouldFilterCharacterBody(land, V.mod) == false,
      "land entity never water-quad filtered")
savedOpts.water_spawns = "swimming_sprites"
waterEnt.voxelWaterShadowPresentation = false
check(VoxelWaterShadows.shouldFilterCharacterBody(waterEnt, V.mod) == false,
      "swimming sprites stay on character path")

savedOpts.water_spawns = "silhouettes"
waterEnt.voxelWaterShadowPresentation = true
waterEnt.waterSilhouetteSheet = true
local trainer = { overworldWildSpawn = false, surface = "WATER" }
local list = VoxelWaterShadows.collectEntities({
  entities = { waterEnt, land, trainer },
}, nil, V.mod)
eq(#list, 1, "collect only water silhouette wilds")
check(list[1] == waterEnt, "collected entity is water shadow")

VoxelWaterShadows.markPresentation(waterEnt, V.mod, true)
check(waterEnt.voxelWaterShadowPresentation == true, "mark sets presentation flag")
eq(waterEnt.voxelWaterPresentation, "SPECIES_WORLD_QUAD", "mark sets SPECIES_WORLD_QUAD")
VoxelWaterShadows.markPresentation(waterEnt, V.mod, false)
check(waterEnt.voxelWaterShadowPresentation == false, "flat clears presentation flag")
eq(waterEnt.voxelWaterPresentation, "FLAT_2D", "mark flat → FLAT_2D")

------------------------------------------------------------------ facade compat
eq(WaterShadowRenderer.HIDDEN_RELATIVE, VoxelWaterShadows.HIDDEN_RELATIVE,
   "facade shares hidden asset path")
eq(WaterShadowRenderer.shadowModeFor(V.mod, waterEnt, false),
   WaterShadowRenderer.MODE.NONE, "facade none when flat camera")
savedOpts.water_spawns = "hidden_silhouettes"
eq(WaterShadowRenderer.shadowModeFor(V.mod, waterEnt, true),
   WaterShadowRenderer.MODE.FLAT_WORLD, "facade still reports flat_world token")

------------------------------------------------------------------ mesh cache key helper
VoxelWaterShadows.invalidateCache()
check(type(VoxelWaterShadows.meshFor) == "function", "meshFor exists")
-- Without DS, meshFor returns nil (no SpriteBillboards) — contract only.
local mesh, why = VoxelWaterShadows.meshFor(nil, silDef, 0)
check(mesh == nil, "meshFor without lib returns nil")

print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("all water_shadow unit tests passed")
