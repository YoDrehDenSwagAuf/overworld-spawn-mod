-- Native HGSS True Size prototype: Rattata / Blastoise / Onix.
-- Run: lua tests/native_hgss_prototype_unit_test.lua
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

-- Stub Gen1Recomp SpriteRenderer API so VariableSize.effectiveMode → true_size.
package.loaded["src.render.SpriteRenderer"] = {
  DEFAULT_FRAME_WIDTH = 16,
  DEFAULT_FRAME_HEIGHT = 16,
  getFrameGeometry = function() end,
  getPoseGeometry = function() end,
  getScreenOrigin = function() end,
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
  DEFAULTS = { pokemon_size = "classic", sprite_style = "pokemmo" },
  peekSavedOption = function(_, k) return saved[k], saved[k] ~= nil end,
  pokemonSizeMode = function() return saved.pokemon_size end,
  normalizePokemonSize = function(v) return v == "true_size" and "true_size" or "classic" end,
  normalizeSpriteStyle = function(v) return v or "pokemmo" end,
  spriteStyle = function() return saved.sprite_style end,
  debug = function() return false end,
}
modules.debug_log = { warn = function() end, info = function() end, error = function() end, debug = function() end }
modules.json_decode = assert(loadfile("lib/json_decode.lua"))(V)

local SpeciesGeometry = V.require("species_geometry")
local VariableSize = V.require("variable_size")

SpeciesGeometry.clearCache()

-- Expected native-union canvases from generator (pad=2; Onix visualScale 1.15).
local EXPECT = {
  [19] = { fw = 25, fh = 28, resized = false, name = "Rattata" },
  [9]  = { fw = 31, fh = 30, resized = false, name = "Blastoise" },
  [95] = { fw = 35, fh = 38, resized = true,  name = "Onix" },
}

for dex, exp in pairs(EXPECT) do
  local entry = select(1, SpeciesGeometry.entryFor(dex))
  check(entry ~= nil, exp.name .. " geometry entry")
  if entry then
    eq(entry.sizing, "native", exp.name .. " sizing=native")
    check((tonumber(entry.nativeVisualWidth) or 0) > 0, exp.name .. " nativeVisualWidth")
    check((tonumber(entry.nativeVisualHeight) or 0) > 0, exp.name .. " nativeVisualHeight")
    local pack = entry.packs and entry.packs.pokemmo
    check(pack ~= nil, exp.name .. " pokemmo pack")
    if pack then
      eq(pack.frameWidth, exp.fw, exp.name .. " frameWidth")
      eq(pack.frameHeight, exp.fh, exp.name .. " frameHeight")
      check(pack.anchorY == pack.frameHeight - 2 or pack.anchorY == (2 + (entry.scaledVisualHeight or 0)),
            exp.name .. " feet anchor near content bottom")
    end
  end

  local rel = select(1, SpeciesGeometry.relativePath(dex, "pokemmo", "normal"))
  check(type(rel) == "string", exp.name .. " relative path")
  local f = rel and io.open(rel, "rb")
  check(f ~= nil, exp.name .. " HGSS asset exists (" .. tostring(rel) .. ")")
  if f then f:close() end

  local def = {
    image = "placeholder.png", frames = 6, walker = true, trueColor = true, id = "T",
  }
  def = VariableSize.applyToDef(V.mod, def, {
    speciesId = dex, style = "pokemmo", packId = "pokemmo", variant = "normal",
  })
  eq(def.frameWidth, exp.fw, exp.name .. " applyToDef frameWidth")
  eq(def.frameHeight, exp.fh, exp.name .. " applyToDef frameHeight")
  check(tostring(def.image):find("true_size/hgss", 1, true) ~= nil,
        exp.name .. " binds native HGSS sheet")
end

-- Onix follower gap override still 3; Rattata small gap 1.
eq(SpeciesGeometry.followGap(95), 3, "Onix follow gap override")
check(SpeciesGeometry.followGap(19) >= 1, "Rattata follow gap >= 1")

-- Classic mode strips geometry (no regression).
saved.pokemon_size = "classic"
SpeciesGeometry.clearCache()
local classicDef = {
  image = "assets/generated/true_size/hgss/019-normal.png",
  frames = 6, walker = true, trueColor = true,
  frameWidth = 25, frameHeight = 28,
}
classicDef = VariableSize.applyToDef(V.mod, classicDef, {
  speciesId = 19, style = "pokemmo", packId = "pokemmo",
})
check(classicDef.frameWidth == nil and classicDef.frameHeight == nil,
      "Classic strips True Size geometry")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nPASS native_hgss_prototype_unit_test")
