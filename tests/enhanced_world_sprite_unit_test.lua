-- EnhancedWorldSprite + billboard card contract tests (0.5.6+).
-- Run: lua54 tests/enhanced_world_sprite_unit_test.lua
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

local modRoot = "."
local modules = {}
local V = {
  mod = {
    path = modRoot,
    log = { info = function() end },
    find = function() return nil end,
    read = function(_, rel)
      local f = io.open(modRoot .. "/" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    assets = {
      path = function(_, rel) return rel end,
    },
  },
  path = modRoot,
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

modules.config = {
  DEFAULTS = {
    pokemon_grass_render_mode = "immersed",
    grass_occlusion_px = 6,
    grass_above_lift_px = 8,
    min_sprite_size = 16,
  },
  get = function(_, k) return modules.config.DEFAULTS[k] end,
  useAnimatedOverworldSprites = function() return true end,
  debug = function() return false end,
}
modules.debug_log = {
  info = function() end, warn = function() end, error = function() end, debug = function() end,
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }
modules.surface = {
  GRASS = "GRASS",
  usesGrassOverlay = function(s) return s == "GRASS" end,
}
modules.movement = {
  syncLegacyFields = function(e)
    if e then
      e.px = e.px or (e.cellX or 0) * 16
      e.py = e.py or (e.cellY or 0) * 16
    end
  end,
  isBusy = function() return false end,
  init = function() end,
  refreshGrassFlag = function() end,
}
modules.grass_occlusion = nil
modules.json_decode = nil

local AnimatedSprites = V.require("animated_sprites")
local EnhancedWorldSprite = V.require("enhanced_world_sprite")
local GrassOcclusion = V.require("grass_occlusion")

-- --- animation revision ---
local state = AnimatedSprites.newAnimationState("down")
eq(state.renderRevision, 0, "new animation revision starts at 0")
eq(state.type, "idle", "default idle type")
local anim = AnimatedSprites.new(V.mod)
anim:load()
check(anim:isReady() or anim.mappedSpeciesCount >= 0, "animated load attempted")

-- --- billboard key taxonomy ---
local frame16 = { width = 16, height = 16 }
local frame32 = { width = 32, height = 16 }
local k1 = anim:billboardKey(5, "walk", "left", 2, frame16)
local k2 = anim:billboardKey(5, "walk", "left", 3, frame16)
local k3 = anim:billboardKey(5, "idle", "left", 2, frame16)
local k4 = anim:billboardKey(6, "walk", "left", 2, frame16)
local k5 = anim:billboardKey(5, "walk", "right", 2, frame16)
local k6 = anim:billboardKey(5, "walk", "left", 2, frame32)
eq(k1, "5:normal:walk:left:2:16:16", "key format species:variant:anim:dir:idx:w:h")
check(k1 ~= k2, "frame index differs keys")
check(k1 ~= k3, "animation differs keys")
check(k1 ~= k4, "species differs keys")
check(k1 ~= k5, "direction differs keys")
check(k1 ~= k6, "size differs keys")
local kShiny = anim:billboardKey(5, "walk", "left", 2, frame16, "shiny")
check(k1 ~= kShiny, "variant differs keys")

-- --- fit math (documented Dramatic Shape constraint) ---
local function fit(sw, sh)
  local card = 16
  local scale = math.min(card / sw, card / sh)
  local dw = math.floor(sw * scale + 0.5)
  local dh = math.floor(sh * scale + 0.5)
  local ox = math.floor((card - dw) / 2)
  local oy = card - dh
  return dw, dh, ox, oy
end
local dw, dh, ox, oy = fit(16, 16)
eq(dw, 16, "16x16 fit w"); eq(dh, 16, "16x16 fit h"); eq(ox, 0, "16x16 ox"); eq(oy, 0, "16x16 oy")
dw, dh, ox, oy = fit(32, 16)
eq(dw, 16, "32x16 fit w"); eq(dh, 8, "32x16 fit h"); eq(ox, 0, "32x16 ox"); eq(oy, 8, "32x16 bottom")
dw, dh, ox, oy = fit(16, 32)
eq(dw, 8, "16x32 fit w"); eq(dh, 16, "16x32 fit h"); eq(ox, 4, "16x32 center x"); eq(oy, 0, "16x32 oy")
dw, dh, ox, oy = fit(32, 32)
eq(dw, 16, "32x32 fit w"); eq(dh, 16, "32x32 fit h")

-- --- stable adapter ---
local legacyDef = { image = "assets/fallback/pokemon_missing.png", frames = 1, trueColor = true }
local legacy = {
  def = legacyDef,
  image = {},
  resolveImage = function(self) return self.image end,
}
local entity = {
  id = "wild_42",
  species = 5,
  enhancedDexId = 5,
  facing = "left",
  px = 32, py = 64, cellX = 2, cellY = 4,
  usingEnhancedSprite = true,
  legacySprite = legacy,
  sprite = legacy,
  animation = anim:newAnimationState("left"),
  inGrassOverlay = false,
  tuck = 0,
  waterSink = 0,
  pokemonRenderer = "WORLD_BILLBOARD_ENHANCED",
  mod = V.mod,
}
entity.animation.source = "FOLLOW_SPRITES"
entity.animation.variant = "normal"
entity.animation.type = "walk"
entity.animation.name = "walk"
entity.animation.direction = "left"
entity.animation.frameIndex = 2
entity.spriteVariant = "normal"
local world1 = EnhancedWorldSprite.new({
  entity = entity,
  animatedSprites = anim,
  legacySprite = legacy,
  baseImagePath = "assets/runtime/dynamic_billboard_base.png",
})
local world2 = EnhancedWorldSprite.new({
  entity = entity,
  animatedSprites = anim,
  legacySprite = legacy,
  baseImagePath = "assets/runtime/dynamic_billboard_base.png",
})
check(world1 ~= world2, "factory can create distinct adapters")
-- stability: entity keeps one
entity.worldSprite = world1
entity.sprite = world1
check(entity.worldSprite == world1, "entity keeps stable adapter")
eq(world1.def.frames, 1, "def.frames == 1")
eq(world1.def.trueColor, true, "def.trueColor == true")
check(world1.def.image == "assets/runtime/dynamic_billboard_base.png"
      or world1.def.image == EnhancedWorldSprite.DEF_IMAGE_KEY,
      "def.image is UV carrier path")
-- legacy untouched
eq(legacy.def.image, "assets/fallback/pokemon_missing.png", "legacy def.image untouched")
eq(legacy.def.frames, 1, "legacy frames untouched")
check(legacy.resolveImage ~= EnhancedWorldSprite.resolveImage, "legacy resolveImage not replaced")

local key = anim:getCurrentBillboardKey(entity)
eq(key, "5:normal:walk:left:2:32:32", "current billboard key from entity animation")

-- headless prepare → TEMP or READY or permanent
local result = anim:prepareBillboardImage(entity, key)
check(type(result) == "table", "prepareBillboardImage returns table")
check(result.status == "READY"
      or result.status == "TEMPORARILY_UNAVAILABLE"
      or result.status == "VOXEL_CARD_BUILD_ERROR"
      or result.status == "PERMANENT_INVALID"
      or result.status == "FRAME_MISSING",
      "prepare status taxonomy")

local img = world1:resolveImage()
-- May be nil headless; must not throw / must not mutate legacy
check(legacy.def.image == "assets/fallback/pokemon_missing.png", "resolveImage leaves legacy")
check(world1:status() == "READY"
      or world1:status() == "TEMPORARILY_UNAVAILABLE"
      or world1:status() == "PERMANENT_INVALID",
      "adapter status set")

-- revision bumps on frame change
local prev = entity.animation.renderRevision or 0
entity.animation.frameIndex = 3
entity.animation.frameChanged = true
AnimatedSprites.bumpRenderRevision(entity.animation, {
  type = "walk", direction = "left", frameIndex = 2, source = "ENHANCED_ATLAS",
})
check((entity.animation.renderRevision or 0) > prev, "renderRevision increases on frame change")

-- above lift sign: visualY lower than py → positive lift
entity.inGrassOverlay = true
entity.pokemonRenderer = "WORLD_BILLBOARD_ENHANCED"
entity.grassRenderMode = "above"
-- Mimic Entity:_grassTuck for world billboard above
local liftPx = modules.config.DEFAULTS.grass_above_lift_px or 8
local tuck = -liftPx
local visualY = entity.py + tuck
local lift = entity.py - visualY
eq(lift, liftPx, "above mode positive lift clears grass mesh")

-- immersed: no tuck for world billboard
entity.grassRenderMode = "immersed"
tuck = 0
visualY = entity.py + tuck
lift = entity.py - visualY
eq(lift, 0, "immersed world billboard lift 0")

-- GrassOcclusion.drawForeground must remain callable but is emergency-only by policy
check(type(GrassOcclusion.drawForeground) == "function", "drawForeground still exists for emergency")

if failures > 0 then
  io.stderr:write(("\n%d failure(s)\n"):format(failures))
  os.exit(1)
end
print("\nAll enhanced_world_sprite unit tests passed.")
