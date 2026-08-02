-- Standalone unit tests for follow-sprite overworld sprites (no Gen1Recomp required).
-- Run: lua54 tests/animated_sprites_unit_test.lua
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
    log = {
      info = function(_, fmt, ...) end,
    },
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
    content = { pokemon = { get = function() return nil end } },
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
  DEFAULTS = { grass_occlusion_px = 6, min_sprite_size = 16 },
  get = function() return nil end,
  useAnimatedOverworldSprites = function() return true end,
}
modules.debug_log = {
  info = function() end, warn = function() end, error = function() end, debug = function() end,
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16, size = function() return 16, 16 end }

local JsonDecode = V.require("json_decode")
local AnimatedSprites = V.require("animated_sprites")

-- JSON decode
local obj, err = JsonDecode.decode('{"a":1,"b":[true,false,null],"s":"hi"}')
check(obj ~= nil, "json decodes object")
eq(obj.a, 1, "json number")
eq(obj.s, "hi", "json string")

-- Facing normalize
eq(AnimatedSprites.normalizeFacing("front"), "down", "front->down")
eq(AnimatedSprites.normalizeFacing("back"), "up", "back->up")
eq(AnimatedSprites.normalizeFacing("left"), "left", "left")
eq(AnimatedSprites.normalizeFacing("RIGHT"), "right", "RIGHT")

-- Species id identity (never by name)
eq(AnimatedSprites.resolveSpeciesId(5, nil, nil), 5, "numeric species id")
eq(AnimatedSprites.resolveSpeciesId("CHARMELEON", {
  data = { pokemon = { CHARMELEON = { name = "Glutexo", dex = 5 } } }
}, nil), 5, "dex from species key ignores localized name")
check(AnimatedSprites.resolveSpeciesId("Glutexo", {
  data = { pokemon = { CHARMELEON = { name = "Glutexo", dex = 5 } } }
}, nil) == nil, "localized name alone must not resolve")

-- Filename pattern helpers
eq(AnimatedSprites.mappingFileName(1), "followsprites_mapping.json", "shared mapping name")
eq(AnimatedSprites.mappingRelPath(25),
   "assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json",
   "shared mapping path")

-- Variant normalize / runtime shiny
eq(AnimatedSprites.normalizeVariant("shiny"), "shiny", "shiny variant")
eq(AnimatedSprites.normalizeVariant(true), "shiny", "true -> shiny")
eq(AnimatedSprites.normalizeVariant(nil), "normal", "nil -> normal")
eq(AnimatedSprites.RUNTIME_SHINY_SUPPORT, "NOT_AVAILABLE", "no invented runtime shiny")
eq(AnimatedSprites.resolveRuntimeVariant({ isShiny = true }), "normal",
   "isShiny ignored without runtime support")
eq(AnimatedSprites.resolveRuntimeVariant({}, { forceVariant = "shiny" }), "shiny",
   "preview may force shiny")

-- Loader
local anim = AnimatedSprites.new(V.mod)
local ok = anim:load()
check(ok == true, "follow sprite load succeeds")
check(anim:isReady(), "mapping ready")
eq(anim.mappingFilesFound, 1, "one shared mapping file")
check(anim.mappedSpeciesCount >= 151, "at least Gen1 mapped")
check(anim.mappedSpeciesCount >= 600, "species above 151 retained in mapping")
eq(anim.invalidSpeciesCount, 0, "no invalid mappings")

-- Species 1 / 25 / 151 / 252
local m1 = anim:getMapping(1)
check(m1 ~= nil and m1.valid, "species 1 mapping valid")
eq(m1.normal.fileName, "001-b-n.png", "species 1 normal file")
check(m1.shiny and m1.shiny.valid, "species 1 shiny present")
eq(m1.shiny.fileName, "001-b-s.png", "species 1 shiny file")

local m25 = anim:getMapping(25)
check(m25 ~= nil and m25.valid, "species 25 mapping valid")
eq(m25.preferredForm, "m", "Pikachu prefers male form when no b")
eq(m25.normal.fileName, "025-m-n.png", "species 25 normal file")
check(m25.alternateForms and m25.alternateForms.f ~= nil, "Pikachu female alt form noted")

local m151 = anim:getMapping(151)
check(m151 ~= nil and m151.valid, "species 151 mapping valid")
eq(m151.normal.fileName, "151-b-n.png", "species 151 normal file")

local m252 = anim:getMapping(252)
check(m252 ~= nil and m252.valid, "species 252 mapped for future use")

-- Language independence
local gameEn = { data = { pokemon = { CHARMELEON = { name = "Charmeleon", dex = 5 } } } }
local gameDe = { data = { pokemon = { CHARMELEON = { name = "Glutexo", dex = 5 } } } }
eq(AnimatedSprites.resolveSpeciesId("CHARMELEON", gameEn), 5, "EN dex")
eq(AnimatedSprites.resolveSpeciesId("CHARMELEON", gameDe), 5, "DE dex")
check(anim:getMapping(5) == anim:getMapping(5), "same mapping object")

-- Layout: rows=directions, columns=frames (verified against real PNGs)
local idleDown = anim:getFrame(1, "idle", "down", 1, "normal")
check(idleDown ~= nil, "idle down exists")
eq(idleDown.sourceCol, 0, "idle down col 0")
eq(idleDown.sourceRow, 0, "idle down row 0")
eq(idleDown.width, 32, "tile width 32 for 128 sheet")
eq(idleDown.height, 32, "tile height 32 for 128 sheet")

local idleLeft = anim:getFrame(1, "idle", "left", 1, "normal")
eq(idleLeft.sourceCol, 0, "idle left col 0")
eq(idleLeft.sourceRow, 1, "idle left row 1")

local idleRight = anim:getFrame(1, "idle", "right", 1, "normal")
eq(idleRight.sourceRow, 2, "idle right row 2")

local idleUp = anim:getFrame(1, "idle", "up", 1, "normal")
eq(idleUp.sourceRow, 3, "idle up row 3")

local walkDown, walkCount = anim:getFrame(1, "walk", "down", 1, "normal")
eq(walkCount, 4, "walk down has 4 frames")
eq(walkDown.sourceCol, 0, "walk down frame1 col 0")
local walkDown4 = anim:getFrame(1, "walk", "down", 4, "normal")
eq(walkDown4.sourceCol, 3, "walk down frame4 col 3")
eq(walkDown4.sourceRow, 0, "walk down stays on row 0")

local walkLeft4 = anim:getFrame(1, "walk", "left", 4, "normal")
eq(walkLeft4.sourceRow, 1, "walk left on row 1")
local walkRight2 = anim:getFrame(1, "walk", "right", 2, "normal")
eq(walkRight2.sourceRow, 2, "walk right on row 2")
local walkUp3 = anim:getFrame(1, "walk", "up", 3, "normal")
eq(walkUp3.sourceRow, 3, "walk up on row 3")

-- Shiny selection / fallback
check(anim:hasVariant(1, "shiny") == true, "species 1 has shiny")
local shinyIdle = anim:getFrame(1, "idle", "down", 1, "shiny")
check(shinyIdle ~= nil, "shiny idle frame")
local vmShiny = anim:getVariantMapping(1, "shiny")
eq(vmShiny.fileName, "001-b-s.png", "shiny mapping file")
local vmMissing = anim:getVariantMapping(1, "shiny")
check(vmMissing ~= nil, "shiny request returns mapping")

-- Animation update
local state = anim:newAnimationState("down")
eq(state.source, "FOLLOW_SPRITES", "animation source follow")
anim:updateAnimation(state, 5, 0, false, "down")
eq(state.name, "idle", "stationary -> idle")
anim:updateAnimation(state, 5, 0, true, "left")
eq(state.name, "walk", "moving -> walk")
eq(state.direction, "left", "facing left")
anim:updateAnimation(state, 5, 0, true, "left", 0.0)
eq(state.frameIndex, 1, "progress 0 -> frame 1")
anim:updateAnimation(state, 5, 0, true, "left", 0.99)
check(state.frameIndex >= 1 and state.frameIndex <= 4, "progress near 1 valid")

-- Scale for 32x32 tiles
local scale = AnimatedSprites.calculateAnimatedSpriteScale(nil, idleDown, {})
eq(scale.contentH, 32, "scale content height 32")
eq(scale.logicalFootprintTiles, 1, "logical footprint stays 1")
check(scale.visualFootprintTilesH == 2, "visual height 2 tiles")

-- Quad / image cache keys
eq(anim:quadKey(25, "walk", "left", 3, "normal"), "25:normal:walk:left:3", "quad cache key")
eq(anim:imageCacheKey(25, "shiny"), "25:shiny", "image cache key")
local q1 = anim:getQuad(25, "walk", "left", 1, "normal")
local q2 = anim:getQuad(25, "walk", "left", 1, "normal")
check(q1 ~= nil and q1 == q2, "quad cache hit")
local img = anim:getImage(1, "normal")
check(img ~= nil, "lazy image stub/load")

-- Bounds rejection
local errors = {}
local bad = anim:_normalizeFrames(
  { { col = 200, row = 0, w = 1, h = 1 } }, 32, 32, errors, 128, 128)
eq(#bad, 0, "out-of-bounds frame discarded")
check(#errors >= 1, "out-of-bounds error recorded")

-- Grid validation helpers via mapping sizes
check(m1.normal.imageWidth % 4 == 0, "image width divisible by 4")
check(m1.normal.imageHeight % 4 == 0, "image height divisible by 4")

print("")
if failures > 0 then
  io.stderr:write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
print("all follow-sprite unit tests passed")
