-- Standalone unit tests for animated overworld sprites (no Gen1Recomp required).
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

-- Minimal V harness mirroring main.lua's require.
local modRoot = "."
local modules = {}
local V = {
  mod = {
    path = modRoot,
    log = {
      info = function(_, fmt, ...)
        -- quiet
      end,
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

-- Stub Config defaults used by animated_sprites.
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
eq(obj.b[1], true, "json true")
eq(obj.b[2], false, "json false")
check(obj.b[3] == nil, "json null")

-- Facing normalize
eq(AnimatedSprites.normalizeFacing("front"), "down", "front->down")
eq(AnimatedSprites.normalizeFacing("back"), "up", "back->up")
eq(AnimatedSprites.normalizeFacing("left"), "left", "left")
eq(AnimatedSprites.normalizeFacing("RIGHT"), "right", "RIGHT")
eq(AnimatedSprites.normalizeFacing("north"), "up", "north->up")
eq(AnimatedSprites.normalizeFacing("south"), "down", "south->down")

-- Species id identity (never by name)
eq(AnimatedSprites.resolveSpeciesId(5, nil, nil), 5, "numeric species id")
eq(AnimatedSprites.resolveSpeciesId("CHARMELEON", {
  data = { pokemon = { CHARMELEON = { name = "Glutexo", dex = 5 } } }
}, nil), 5, "dex from species key ignores localized name")
eq(AnimatedSprites.resolveSpeciesId("CHARMELEON", {
  data = { pokemon = { CHARMELEON = { name = "Reptincel", dex = 5 } } }
}, nil), 5, "French display name still dex 5")
check(AnimatedSprites.resolveSpeciesId("Glutexo", {
  data = { pokemon = { CHARMELEON = { name = "Glutexo", dex = 5 } } }
}, nil) == nil, "localized name alone must not resolve")

-- Loader
local anim = AnimatedSprites.new(V.mod)
local ok = anim:load()
check(ok == true, "animated load succeeds")
check(anim:isReady(), "atlas ready (stub or image)")
eq(anim.mappingFilesFound, 151, "151 mapping files found")
check(anim.validSpeciesCount >= 140, "most mappings valid")
check(anim.partialSpeciesCount >= 1, "partial mappings present")
eq(anim.invalidSpeciesCount, 0, "no invalid mappings")

-- ID cross-check Charmeleon
local m5 = anim:getMapping(5)
check(m5 ~= nil and m5.valid, "species 5 mapping valid")
eq(m5.speciesId, 5, "lookup key 5")
eq(m5.fileName, "pokemon_005_project.json", "filename pattern")
eq(m5.speciesName, "Charmeleon", "speciesName display-only field present")

-- Language independence: same mapping regardless of display name
local gameEn = { data = { pokemon = { CHARMELEON = { name = "Charmeleon", dex = 5 } } } }
local gameDe = { data = { pokemon = { CHARMELEON = { name = "Glutexo", dex = 5 } } } }
local gameFr = { data = { pokemon = { CHARMELEON = { name = "Reptincel", dex = 5 } } } }
eq(AnimatedSprites.resolveSpeciesId("CHARMELEON", gameEn), 5, "EN dex")
eq(AnimatedSprites.resolveSpeciesId("CHARMELEON", gameDe), 5, "DE dex")
eq(AnimatedSprites.resolveSpeciesId("CHARMELEON", gameFr), 5, "FR dex")
check(anim:getMapping(5) == m5, "same mapping object for all languages")

-- Nidoran variants by separate IDs
check(anim:getMapping(29) ~= nil, "Nidoran F id 29")
check(anim:getMapping(32) ~= nil, "Nidoran M id 32")
check(anim:getMapping(29) ~= anim:getMapping(32), "Nidoran variants distinct")

-- Mr. Mime / Farfetch'd by id
check(anim:getMapping(83) and anim:getMapping(83).valid, "Farfetch'd id 83")
check(anim:getMapping(122) and anim:getMapping(122).valid, "Mr. Mime id 122")

-- Frame sizes
local f16 = anim:getFrame(5, "idle", "down", 1)
check(f16 and f16.width == 16 and f16.height == 16, "Charmeleon idle 16x16")
local f32h = anim:getFrame(6, "idle", "down", 1)
check(f32h and f32h.width == 16 and f32h.height == 32, "Charizard idle 16x32")
local f32w = anim:getFrame(6, "idle", "left", 1)
check(f32w and f32w.width == 32 and f32w.height == 16, "Charizard idle left 32x16")

-- Partial Bulbasaur idle left falls back to walk
local frames, used = anim:resolveFrames(1, "idle", "left")
check(frames and #frames >= 1, "Bulbasaur idle.left fallback has frames")
eq(used, "walk", "Bulbasaur idle.left uses walk fallback")

-- Animation update walk/idle
local state = anim:newAnimationState("down")
anim:updateAnimation(state, 5, 0, false, "down")
eq(state.name, "idle", "stationary -> idle")
eq(state.type, "idle", "type alias idle")
anim:updateAnimation(state, 5, 0, true, "left")
eq(state.name, "walk", "moving -> walk")
eq(state.direction, "left", "facing left")
-- Movement-progress driven walk frames
local changed = anim:updateAnimation(state, 5, 0, true, "left", 0.0)
eq(state.frameIndex, 1, "progress 0 -> frame 1")
anim:updateAnimation(state, 5, 0, true, "left", 0.99)
check(state.frameIndex >= 1, "progress near 1 still valid frame")
anim:updateAnimation(state, 5, 0, false, "left")
eq(state.name, "idle", "stop -> idle same direction")
eq(state.direction, "left", "idle keeps last walk direction")

-- Direction change dirties
local s2 = anim:newAnimationState("down")
anim:updateAnimation(s2, 5, 0, false, "up")
check(s2.directionChanged == true or s2.direction == "up", "direction change to up")

-- Scale keeps multi-cell footprint
local scale = AnimatedSprites.calculateAnimatedSpriteScale(nil, f32h, {})
eq(scale.contentH, 32, "scale content height 32")
eq(scale.logicalFootprintTiles, 1, "logical footprint stays 1")
check(scale.visualFootprintTilesH == 2, "visual height 2 tiles")
check(scale.grassOcclusionHeight <= 6, "grass occlusion capped")

-- Quad cache key
eq(anim:quadKey(25, "walk", "left", 3), "25:walk:left:3", "quad cache key")
local q1 = anim:getQuad(25, "walk", "left", 1)
local q2 = anim:getQuad(25, "walk", "left", 1)
check(q1 ~= nil and q1 == q2, "quad cache hit")

-- Out-of-bounds rejection helper: invent invalid frame via normalize
local errors = {}
local bad = anim:_normalizeFrames({ { col = 200, row = 0, w = 1, h = 1 } }, 16, 16, errors)
eq(#bad, 0, "out-of-bounds frame discarded")
check(#errors >= 1, "out-of-bounds error recorded")

-- Filename pattern
eq(AnimatedSprites.mappingFileName(1), "pokemon_001_project.json", "pattern 001")
eq(AnimatedSprites.mappingFileName(151), "pokemon_151_project.json", "pattern 151")

print("")
if failures > 0 then
  io.stderr:write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
print("all animated sprite unit tests passed")
