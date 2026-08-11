-- Wild rebind must not strip True Size geometry when species is a NAME string.
-- Run: lua tests/wild_rebind_geometry_unit_test.lua
--
-- Root cause (PR #58): applyProviderSprite passed entity.species ("ONIX") into
-- VariableSize.applyToDef → packGeometry failed → stripGeometry cleared
-- frameWidth/Height but left the true_size/ image → SpriteRenderer.new baked
-- 16×16 quads on a tall Onix sheet (Wild cropped; Followers fine).
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
      frameWidth = math.floor(fw),
      frameHeight = math.floor(fh),
      anchorX = tonumber(def.anchorX) or (fw / 2),
      anchorY = tonumber(def.anchorY) or fh,
      image = { getDimensions = function() return fw, fh * (tonumber(def.frames) or 6) end },
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
  },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  modules[name] = chunk(V)
  return modules[name]
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
-- Minimal animated_sprites stub: name → dex for Onix/Rattata/Blastoise.
modules.animated_sprites = {
  resolveSpeciesId = function(key)
    if tonumber(key) then return tonumber(key) end
    local map = { ONIX = 95, RATTATA = 19, BLASTOISE = 9, onix = 95, rattata = 19 }
    return map[tostring(key)]
  end,
  resolveRuntimeVariant = function() return "normal" end,
  normalizeVariant = function(v) return v or "normal" end,
}

local VariableSize = V.require("variable_size")
local SpeciesGeometry = V.require("species_geometry")
SpeciesGeometry.clearCache()
VariableSize.clearCaches()

local onixPack = SpeciesGeometry.packGeometry(95, "pokemmo")
check(onixPack ~= nil, "Onix pokemmo pack exists")
local expectW = onixPack and onixPack.frameWidth
local expectH = onixPack and onixPack.frameHeight
check(expectW and expectW > 16, "Onix frameWidth > 16 (got " .. tostring(expectW) .. ")")
check(expectH and expectH > 16, "Onix frameHeight > 16 (got " .. tostring(expectH) .. ")")

-- A) BUG REPRO (pre-fix behavior): name string without resolve → no_geometry
--    We now resolve names inside applyToDef, so this must SUCCEED.
local defName = {
  image = "assets/generated/true_size/hgss/095-normal.png",
  frames = 6, walker = true, trueColor = true,
  frameWidth = expectW, frameHeight = expectH,
  anchorX = onixPack.anchorX, anchorY = onixPack.anchorY,
}
local outName, infoName = VariableSize.applyToDef(V.mod, defName, {
  speciesId = "ONIX", style = "pokemmo", packId = "pokemmo",
})
check(infoName.applied == true, "applyToDef(ONIX name) applies (got " .. tostring(infoName.reason) .. ")")
eq(outName.frameWidth, expectW, "ONIX name keeps frameWidth")
eq(outName.frameHeight, expectH, "ONIX name keeps frameHeight")

-- B) Control: numeric dex
local defDex = {
  image = "assets/generated/true_size/hgss/095-normal.png",
  frames = 6, walker = true, trueColor = true,
}
local outDex, infoDex = VariableSize.applyToDef(V.mod, defDex, {
  speciesId = 95, style = "pokemmo", packId = "pokemmo",
})
check(infoDex.applied == true, "applyToDef(95) applies")
eq(outDex.frameWidth, expectW, "dex 95 frameWidth")

-- C) Preserve existing geometry when species is completely unknown
local defKeep = {
  image = "assets/generated/true_size/hgss/095-normal.png",
  frames = 6, walker = true, trueColor = true,
  frameWidth = 35, frameHeight = 38, anchorX = 17.5, anchorY = 36,
}
local outKeep, infoKeep = VariableSize.applyToDef(V.mod, defKeep, {
  speciesId = "NOT_A_MON", style = "pokemmo", packId = "pokemmo",
})
check(infoKeep ~= nil and infoKeep.applied == true,
  "preserve geometry when unresolved (" .. tostring(infoKeep and infoKeep.reason) .. ")")
eq(outKeep.frameWidth, 35, "preserved frameWidth")
eq(outKeep.frameHeight, 38, "preserved frameHeight")
check(tostring(outKeep.image):find("true_size/", 1, true) ~= nil, "true_size image kept")

-- D) SpriteRenderer instance must match def (the draw-time values)
local spr = package.loaded["src.render.SpriteRenderer"].new(outName, "wild-onix")
eq(spr.frameWidth, expectW, "INSTANCE frameWidth == def")
eq(spr.frameHeight, expectH, "INSTANCE frameHeight == def")
check(spr.frameWidth ~= 16, "INSTANCE is not default 16")

-- E) Simulate the old destructive path: strip while keeping image → 16×16 instance
local bad = {
  image = "assets/generated/true_size/hgss/095-normal.png",
  frames = 6, walker = true, trueColor = true,
}
local badSpr = package.loaded["src.render.SpriteRenderer"].new(bad, "broken")
eq(badSpr.frameWidth, 16, "control: missing geometry → instance 16")
eq(badSpr.frameHeight, 16, "control: missing geometry → instance 16")

print("\n--- Wild Onix rebind geometry ---")
print(string.format("def.frameWidth/Height = %s x %s", tostring(outName.frameWidth), tostring(outName.frameHeight)))
print(string.format("instance.frameWidth/Height = %s x %s", tostring(spr.frameWidth), tostring(spr.frameHeight)))

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nPASS wild_rebind_geometry_unit_test")
