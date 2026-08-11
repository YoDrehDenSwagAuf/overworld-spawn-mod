-- Variable-size / True Size prototype unit tests (Gen1Recomp #1016 contract).
-- Run: lua tests/variable_size_unit_test.lua

local function fail(msg)
  io.stderr:write("FAIL: " .. msg .. "\n")
  os.exit(1)
end

local function check(cond, msg)
  if not cond then fail(msg) end
end

local function eq(a, b, msg)
  if a ~= b then
    fail(string.format("%s (got %s expected %s)", msg, tostring(a), tostring(b)))
  end
end

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Minimal V harness matching main.lua module loading.
local modules = {}
local mod = {
  id = "overworld_wild_spawns",
  path = ".",
  log = { info = function() end, warn = function() end },
  options = {
    _vals = { pokemon_size = "classic", sprite_style = "pokemmo" },
    get = function(self, k) return self._vals[k] end,
    set = function(self, k, v) self._vals[k] = v end,
  },
  find = function() return nil end,
  read = function(_self, rel)
    local f = io.open(rel, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
  end,
  assets = {
    path = function(_self, rel) return rel end,
  },
}

local V = { mod = mod, path = "." }
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

-- Stub SpriteRenderer with #1020 API surface for probeEngineApi.
package.preload["src.render.SpriteRenderer"] = function()
  local SR = {
    DEFAULT_FRAME_WIDTH = 16,
    DEFAULT_FRAME_HEIGHT = 16,
    DEFAULT_ANCHOR_X = 8,
    DEFAULT_ANCHOR_Y = 16,
  }
  function SR:getFrameGeometry(frame)
    return {
      frame = frame or 0, x = 0, y = 0,
      width = self.frameWidth or 16,
      height = self.frameHeight or 16,
      anchorX = self.anchorX or 8,
      anchorY = self.anchorY or 16,
    }
  end
  function SR:getPoseGeometry(facing, walkPhase, stepFlip)
    local g = self:getFrameGeometry(0)
    g.facing = facing
    g.walkPhase = walkPhase
    g.stepFlip = stepFlip
    g.mirror = facing == "right"
    return g
  end
  function SR:getScreenOrigin(px, py, camX, camY)
    return 0, 0
  end
  return SR
end

local Config = V.require("config")
local SpeciesGeometry = V.require("species_geometry")
local VariableSize = V.require("variable_size")

-- ------- Config defaults / normalize
eq(Config.normalizePokemonSize(nil), "classic", "nil → classic")
eq(Config.normalizePokemonSize("true_size"), "true_size", "true_size")
eq(Config.normalizePokemonSize("Classic"), "classic", "Classic")
eq(Config.pokemonSizeMode(mod), "classic", "default classic from options")

mod.options._vals.pokemon_size = "true_size"
eq(Config.pokemonSizeMode(mod), "true_size", "option true_size")

-- ------- Species geometry (Charizard only)
local pack, dex = SpeciesGeometry.packGeometry(6, "pokemmo")
eq(dex, 6, "dex 6")
check(pack ~= nil, "Charizard pokemmo pack")
eq(pack.frameWidth, 32, "frameWidth 32")
eq(pack.frameHeight, 32, "frameHeight 32")
eq(pack.anchorX, 16, "anchorX 16 bottom-center")
eq(pack.anchorY, 32, "anchorY 32 feet")
check(pack.prototype == true, "prototype flag")

local noPack = SpeciesGeometry.packGeometry(25, "pokemmo")
eq(noPack, nil, "Pikachu has no prototype yet")

local rel = SpeciesGeometry.prototypeRelativePath(6, "pokemmo", "normal")
eq(rel, "assets/generated/variable_size_prototype/hgss/006-normal.png", "rel path")
local f = io.open(rel, "rb")
check(f ~= nil, "prototype PNG exists on disk")
if f then f:close() end

-- Verify sheet dimensions via file header (IHDR) without PIL.
do
  local fh = assert(io.open(rel, "rb"))
  local data = fh:read(32)
  fh:close()
  -- PNG IHDR: width/height big-endian at bytes 16..23
  local function be32(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
  end
  local w, h = be32(data, 17), be32(data, 21)
  eq(w, 32, "prototype sheet width 32")
  eq(h, 192, "prototype sheet height 192 (6×32)")
end

-- ------- Engine probe
VariableSize.clearCaches()
local engine = VariableSize.probeEngineApi()
check(engine.available == true, "engine API available via stub")
check(engine.hasGetPoseGeometry == true, "getPoseGeometry")
check(engine.hasGetFrameGeometry == true, "getFrameGeometry")
check(engine.hasGetScreenOrigin == true, "getScreenOrigin")

-- ------- Classic mode never applies geometry
mod.options._vals.pokemon_size = "classic"
local defClassic = {
  image = "assets/generated/followsprites_runtime/006-normal.png",
  frames = 6, walker = true, trueColor = true, id = "SPRITE_OW_WILD_6",
}
local outC, infoC = VariableSize.applyToDef(mod, defClassic, {
  speciesId = 6, style = "pokemmo", variant = "normal",
})
eq(infoC.applied, false, "classic does not apply")
eq(infoC.reason, "classic_mode", "classic reason")
eq(outC.frameWidth, nil, "classic strips frameWidth")
check(outC.image:find("followsprites_runtime", 1, true), "classic keeps 16×16 runtime")

-- ------- True Size Flat applies Charizard geometry
mod.options._vals.pokemon_size = "true_size"
VariableSize.clearCaches()
local defTS = {
  image = "assets/generated/followsprites_runtime/006-normal.png",
  frames = 6, walker = true, trueColor = true, id = "SPRITE_OW_WILD_6",
}
local outT, infoT = VariableSize.applyToDef(mod, defTS, {
  speciesId = 6, style = "pokemmo", variant = "normal", voxelActive = false,
})
check(infoT.applied == true, "true size applied on Flat")
eq(outT.frameWidth, 32, "true size frameWidth")
eq(outT.frameHeight, 32, "true size frameHeight")
eq(outT.anchorX, 16, "true size anchorX")
eq(outT.anchorY, 32, "true size anchorY")
check(outT.image:find("variable_size_prototype", 1, true), "uses prototype asset")
eq(infoT.logicalFootprint, "16x16_cell", "logical footprint unchanged")

-- Non-prototype species stays classic assets even in True Size
local defPika = {
  image = "assets/generated/followsprites_runtime/025-normal.png",
  frames = 6, walker = true, trueColor = true,
}
local _, infoP = VariableSize.applyToDef(mod, defPika, {
  speciesId = 25, style = "pokemmo", variant = "normal", voxelActive = false,
})
eq(infoP.applied, false, "Pikachu no prototype")
eq(infoP.reason, "no_prototype_for_species_pack", "pikachu reason")

-- ------- Voxel + DS 1.7.9 fixed-16 → Classic fallback
VariableSize.clearCaches()
local dsSrc = [[
local function buildCard(def, frame)
  local fy = frame * 16
  local verts = {
    { 0, 0, 0, u0, v1, 1 }, { 16, 0, 0, u1, v1, 1 },
    { 16, 16, 0, u1, v0, 1 }, { 0, 16, 0, u0, v0, 1 },
  }
end
]]
mod.find = function(_self, id)
  if id == "DRAMATIC_SHAPE" or id == "BATTLE_ART_VOXEL_FORK" then
    return {
      exports = { version = "1.7.9" },
      read = function(_m, rel)
        if rel == "lib/SpriteBillboards.lua" then return dsSrc end
        return nil
      end,
    }
  end
  return nil
end

local ds = VariableSize.probeDramaticShape(mod)
check(ds.present == true, "DS present")
eq(ds.supportsVariableGeometry, false, "DS 1.7.9 no variable geometry")
check(ds.reason == "sprite_billboards_fixed_16x16", "fixed 16 reason: " .. tostring(ds.reason))

local can, why = VariableSize.canApplyTrueSize(mod, { voxelActive = true })
eq(can, false, "cannot apply under voxel+DS1.7.9")
check(type(why) == "string" and why:find("voxel_ds_incompatible", 1, true) == 1,
  "voxel incompatible reason")

local defV = {
  image = "assets/generated/followsprites_runtime/006-normal.png",
  frames = 6, walker = true, trueColor = true,
}
local outV, infoV = VariableSize.applyToDef(mod, defV, {
  speciesId = 6, style = "pokemmo", variant = "normal", voxelActive = true,
})
eq(infoV.applied, false, "voxel falls back")
eq(outV.frameWidth, nil, "voxel strips geometry")
check(outV.image:find("followsprites_runtime", 1, true), "voxel keeps classic sheet")

-- Flat still works while DS is installed but Voxel camera off
local outF2, infoF2 = VariableSize.applyToDef(mod, {
  image = "assets/generated/followsprites_runtime/006-normal.png",
  frames = 6, walker = true, trueColor = true,
}, { speciesId = 6, style = "pokemmo", variant = "normal", voxelActive = false })
check(infoF2.applied == true, "Flat True Size while DS installed")

-- Options schema includes pokemon_size default classic
local schema = assert(loadfile("options.lua"))()
local found = false
for _, opt in ipairs(schema) do
  if opt.key == "pokemon_size" then
    found = true
    eq(opt.default, "classic", "schema default classic")
    eq(opt.choices[1][2], "classic", "choice classic")
    eq(opt.choices[2][2], "true_size", "choice true_size")
  end
end
check(found, "pokemon_size in options schema")

-- Manifest version bump
local mf = assert(io.open("manifest.json", "r")):read("*a")
check(mf:find('"1.13.0"', 1, true), "manifest 1.13.0")

print("PASS variable_size_unit_test")
