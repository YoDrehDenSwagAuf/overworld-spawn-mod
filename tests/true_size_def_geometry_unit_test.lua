-- True Size geometry must survive Wild def copy/rebind (follower parity).
-- Run: lua tests/true_size_def_geometry_unit_test.lua
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

package.loaded["src.render.SpriteRenderer"] = {
  DEFAULT_FRAME_WIDTH = 16,
  DEFAULT_FRAME_HEIGHT = 16,
  getFrameGeometry = function() end,
  getPoseGeometry = function() end,
  getScreenOrigin = function() end,
  new = function(def, id)
    local fw = tonumber(def.frameWidth) or 16
    local fh = tonumber(def.frameHeight) or 16
    return {
      def = def,
      id = id,
      frameWidth = fw,
      frameHeight = fh,
      anchorX = tonumber(def.anchorX) or (fw / 2),
      anchorY = tonumber(def.anchorY) or fh,
    }
  end,
}

local modules = {}
local saved = { pokemon_size = "true_size", sprite_style = "pokemmo" }
local V = {
  mod = {
    path = ".",
    find = function() return nil end,
    options = { get = function(_, k) return saved[k] end },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local d = f:read("*a"); f:close(); return d
    end,
    assets = { path = function(_, r) return r end },
    log = { info = function() end },
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
modules.config = {
  DEFAULTS = { pokemon_size = "classic", sprite_style = "pokemmo", water_spawns = "swimming_sprites" },
  peekSavedOption = function(_, k) return saved[k], saved[k] ~= nil end,
  pokemonSizeMode = function() return saved.pokemon_size end,
  normalizePokemonSize = function(v) return v == "true_size" and "true_size" or "classic" end,
  normalizeSpriteStyle = function(v) return v or "pokemmo" end,
  spriteStyle = function() return saved.sprite_style end,
  waterDisplayMode = function() return "swimming_sprites" end,
  wildSilhouettes = function() return false end,
  debug = function() return false end,
}
modules.debug_log = { warn = function() end, info = function() end, error = function() end, debug = function() end }
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }
modules.json_decode = assert(loadfile("lib/json_decode.lua"))(V)
modules.water_display = { isVoxelCameraActive = function() return false end }

local VariableSize = V.require("variable_size")
local SpeciesGeometry = V.require("species_geometry")
local WaterSpriteRegistry = V.require("water_sprite_registry")
local SpriteResolver = V.require("sprite_resolver")

local function geomOk(def, label)
  check(def ~= nil, label .. " def exists")
  if not def then return end
  check(tonumber(def.frameWidth) and def.frameWidth > 0, label .. " frameWidth")
  check(tonumber(def.frameHeight) and def.frameHeight > 0, label .. " frameHeight")
  check(def.frameWidth ~= 16 or def.frameHeight ~= 16
        or (label:find("classic")), label .. " not forced 16x16 for True Size")
end

-- Land provider-style apply
local landPack = SpeciesGeometry.packGeometry(19, "pokemmo")
local landRel = select(1, SpeciesGeometry.relativePath(19, "pokemmo", "normal"))
local landDef = {
  image = landRel, frames = 6, walker = true, trueColor = true, id = "LAND19",
}
landDef = VariableSize.applyToDef(V.mod, landDef, {
  speciesId = 19, style = "pokemmo", packId = "pokemmo", variant = "normal",
})
eq(landDef.frameWidth, landPack.frameWidth, "land apply frameWidth")
eq(landDef.frameHeight, landPack.frameHeight, "land apply frameHeight")

-- Wild Entity.new-style copy MUST keep geometry (regression of the strip bug)
local copied = {
  image = landDef.image,
  frames = landDef.frames,
  trueColor = true,
  id = landDef.id,
  walker = true,
  frameWidth = landDef.frameWidth,
  frameHeight = landDef.frameHeight,
  anchorX = landDef.anchorX,
  anchorY = landDef.anchorY,
}
local spr = package.loaded["src.render.SpriteRenderer"].new(copied, "w")
eq(spr.frameWidth, landPack.frameWidth, "Wild SpriteRenderer land frameWidth")
eq(spr.frameHeight, landPack.frameHeight, "Wild SpriteRenderer land frameHeight")
check(spr.frameWidth ~= 16 or landPack.frameWidth == 16, "Rattata not defaulted to 16")

-- Water registry → resolver must keep swimming geometry + swimming image
local reg = WaterSpriteRegistry.new(V.mod)
assert(reg:load())
local waterDef, waterErr = reg:resolve(129, "normal", "swimming", nil)
check(waterDef ~= nil, "Magikarp swimming resolves (" .. tostring(waterErr) .. ")")
if waterDef then
  geomOk(waterDef, "registry water")
  check(tostring(waterDef.image):find("true_size/swimming", 1, true) ~= nil
        or tostring(waterDef.relativePath or ""):find("true_size/swimming", 1, true) ~= nil
        or tostring(waterDef.image):find("swimming", 1, true) ~= nil,
        "registry water image is swimming pack")

  -- Simulate the FIXED resolver copy (must include geometry)
  local resolverDef = {
    image = waterDef.image,
    frames = waterDef.frames,
    walker = true,
    trueColor = true,
    id = waterDef.id,
    frameWidth = waterDef.frameWidth,
    frameHeight = waterDef.frameHeight,
    anchorX = waterDef.anchorX,
    anchorY = waterDef.anchorY,
  }
  geomOk(resolverDef, "resolver water copy")

  -- applyProviderSprite rebind MUST use swimming presentation, not land
  local rebound = {
    image = resolverDef.image,
    frames = resolverDef.frames,
    walker = true,
    trueColor = true,
    id = resolverDef.id,
    frameWidth = resolverDef.frameWidth,
    frameHeight = resolverDef.frameHeight,
    anchorX = resolverDef.anchorX,
    anchorY = resolverDef.anchorY,
  }
  rebound = VariableSize.applyToDef(V.mod, rebound, {
    speciesId = 129,
    style = "pokemmo",
    variant = "normal",
    presentation = "swimming",
    packId = "swimming",
  })
  local swimPack = SpeciesGeometry.packGeometry(129, "swimming")
  eq(rebound.frameWidth, swimPack.frameWidth, "water rebind keeps swim frameWidth")
  eq(rebound.frameHeight, swimPack.frameHeight, "water rebind keeps swim frameHeight")
  check(tostring(rebound.image):find("true_size/swimming", 1, true) ~= nil
        or tostring(rebound.image):find("/swimming/", 1, true) ~= nil,
        "water rebind does NOT replace with land HGSS pack")

  -- Contrasting bug: land-style rebind (the old wild path) swaps the image
  local wrong = {
    image = waterDef.image, frames = 6, walker = true, trueColor = true, id = "X",
  }
  wrong = VariableSize.applyToDef(V.mod, wrong, {
    speciesId = 129, style = "pokemmo", variant = "normal",
  })
  check(tostring(wrong.image):find("true_size/hgss", 1, true) ~= nil
        or tostring(wrong.image):find("/hgss/", 1, true) ~= nil,
        "control: land-style rebind would swap to HGSS (bug we fixed)")

  local sprW = package.loaded["src.render.SpriteRenderer"].new(rebound, "swim")
  eq(sprW.frameWidth, swimPack.frameWidth, "SpriteRenderer swimming frameWidth")
  check(sprW.frameWidth ~= 16 or swimPack.frameWidth == 16,
        "swimming not defaulted to 16x16")
end

-- Follower-style explicit copy (control: must match wild after fix)
local f = {
  image = landDef.image, frames = 6, walker = true, trueColor = true,
  frameWidth = landDef.frameWidth, frameHeight = landDef.frameHeight,
  anchorX = landDef.anchorX, anchorY = landDef.anchorY,
}
local sprF = package.loaded["src.render.SpriteRenderer"].new(f, "f")
eq(sprF.frameWidth, spr.frameWidth, "follower and wild land geometry match")
eq(sprF.frameHeight, spr.frameHeight, "follower and wild land height match")

-- Comparison table output for the report
print("\n--- comparison table (Rattata land / Magikarp water / follower land) ---")
print(string.format("WILD LAND  fw=%s fh=%s img=%s",
  tostring(spr.frameWidth), tostring(spr.frameHeight), tostring(copied.image)))
if waterDef then
  local swimPack = SpeciesGeometry.packGeometry(129, "swimming")
  print(string.format("WILD WATER fw=%s fh=%s img=%s",
    tostring(swimPack.frameWidth), tostring(swimPack.frameHeight),
    tostring(waterDef.image)))
end
print(string.format("FOLLOWER   fw=%s fh=%s img=%s",
  tostring(sprF.frameWidth), tostring(sprF.frameHeight), tostring(f.image)))

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nPASS true_size_def_geometry_unit_test")
