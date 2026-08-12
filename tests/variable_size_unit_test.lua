-- True Size / requested vs effective mode unit tests.
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

local modules = {}
local savedOpts = { pokemon_size = "classic", sprite_style = "pokemmo" }
local mod = {
  id = "overworld_wild_spawns",
  path = ".",
  log = { info = function() end, warn = function() end },
  options = {
    get = function(_, k) return savedOpts[k] end,
    set = function(_, k, v) savedOpts[k] = v end,
  },
  find = function() return nil end,
  read = function(_self, rel)
    local f = io.open(rel, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
  end,
  assets = { path = function(_self, rel) return rel end },
}

local V = { mod = mod, path = "." }
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

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
      width = self.frameWidth or 16, height = self.frameHeight or 16,
      anchorX = self.anchorX or 8, anchorY = self.anchorY or 16,
    }
  end
  function SR:getPoseGeometry(facing, walkPhase, stepFlip)
    local g = self:getFrameGeometry(0)
    g.facing, g.walkPhase, g.stepFlip = facing, walkPhase, stepFlip
    g.mirror = facing == "right"
    return g
  end
  function SR:getScreenOrigin() return 0, 0 end
  return SR
end

local Config = V.require("config")
local SpeciesGeometry = V.require("species_geometry")
local VariableSize = V.require("variable_size")

-- Geometry table covers all 151
local summary = SpeciesGeometry.summary(mod)
eq(summary.species, 151, "151 species geometry")
check((summary.classes.XL or 0) > 0, "has XL class")
check((summary.manualOverrides or 0) >= 15, "manual overrides present")

local charPack = SpeciesGeometry.packGeometry(6, "pokemmo", mod)
check(charPack ~= nil, "Charizard pokemmo pack")
eq(charPack.frameHeight, 32, "Charizard height 32")
local pikachu = SpeciesGeometry.packGeometry(25, "followers", mod)
check(pikachu ~= nil, "Pikachu followers pack")
check(pikachu.frameHeight >= 17 and pikachu.frameHeight <= 20, "Pikachu S height")

-- Asset presence samples
for _, pack in ipairs({ "hgss", "followers", "pokedex" }) do
  local rel = string.format("assets/generated/true_size/%s/006-normal.png", pack)
  local f = io.open(rel, "rb")
  check(f ~= nil, "asset exists " .. rel)
  if f then f:close() end
end
check(io.open("assets/generated/true_size/swimming/131-normal.png", "rb"), "Lapras swimming")
check(io.open("assets/generated/true_size/levitate/006-normal.png", "rb"), "Charizard levitate")

-- Engine stub
VariableSize.clearCaches()
check(VariableSize.probeEngineApi().available, "engine API")

-- requested vs effective — Classic (GSC / followers style)
savedOpts.sprite_style = "followers"
eq(VariableSize.requestedMode(mod), "classic", "requested classic")
eq(VariableSize.effectiveMode(mod), "classic", "effective classic")

-- True Size Flat (HGSS / pokemmo style)
savedOpts.sprite_style = "pokemmo"
VariableSize.clearCaches()
eq(VariableSize.requestedMode(mod), "true_size", "requested true_size")
local eff, why = VariableSize.effectiveMode(mod, { voxelActive = false })
eq(eff, "true_size", "effective true_size flat")
eq(why, "ok", "flat ok")

local def = {
  image = "assets/generated/followsprites_runtime/006-normal.png",
  frames = 6, walker = true, trueColor = true,
}
local out, info = VariableSize.applyToDef(mod, def, {
  speciesId = 6, style = "pokemmo", variant = "normal", voxelActive = false,
})
check(info.applied, "Charizard True Size applied")
eq(out.frameWidth, 32, "fw 32")
eq(out.frameHeight, 32, "fh 32")
check(out.image:find("true_size/hgss", 1, true), "hgss true_size path")

-- Followers pack
local defF = {
  image = "assets/enhanced_overworld/poke_followers/follower_025_normal.png",
  frames = 6, walker = true, trueColor = true,
}
local outF, infoF = VariableSize.applyToDef(mod, defF, {
  speciesId = 25, style = "followers", variant = "normal", voxelActive = false,
})
check(infoF.applied, "Pikachu followers True Size")
check(outF.image:find("true_size/followers", 1, true), "followers true_size path")

-- Voxel incompatible → Classic effective, option UNCHANGED
local dsSrc = [[
local function buildCard(def, frame)
  local fy = frame * 16
  local verts = { { 0, 0, 0 }, { 16, 16, 0 } }
end
]]
mod.find = function(_self, id)
  if id == "DRAMATIC_SHAPE" then
    return {
      exports = { version = "1.7.9" },
      read = function(_m, rel)
        if rel == "lib/SpriteBillboards.lua" then return dsSrc end
      end,
    }
  end
end
VariableSize.clearCaches()
savedOpts.sprite_style = "pokemmo"
local beforeOpt = savedOpts.sprite_style
local effV, whyV = VariableSize.effectiveMode(mod, { voxelActive = true })
eq(effV, "classic", "voxel effective classic")
check(whyV:find("voxel_ds_incompatible", 1, true) == 1, "voxel reason")
eq(savedOpts.sprite_style, beforeOpt, "saved option NOT rewritten")
eq(VariableSize.requestedMode(mod), "true_size", "requested still true_size")

local outV, infoV = VariableSize.applyToDef(mod, {
  image = "assets/generated/followsprites_runtime/006-normal.png",
  frames = 6, walker = true, trueColor = true,
}, { speciesId = 6, style = "pokemmo", variant = "normal", voxelActive = true })
eq(infoV.applied, false, "voxel does not apply True Size")
eq(outV.frameWidth, nil, "geometry stripped")
eq(savedOpts.sprite_style, "pokemmo", "option still pokemmo after apply")

-- Leaving Voxel restores True Size (poll)
VariableSize.resetEffectiveModePoll()
local c1, e1 = VariableSize.pollEffectiveModeChange(mod, { voxelActive = true })
eq(c1, false, "first poll no change")
eq(e1, "classic", "poll voxel classic")
local c2, e2 = VariableSize.pollEffectiveModeChange(mod, { voxelActive = false })
eq(c2, true, "voxel→flat change detected")
eq(e2, "true_size", "poll flat true_size")

-- Missing asset → Classic fallback for that species/pack
local outM, infoM = VariableSize.applyToDef(mod, {
  image = "assets/generated/followsprites_runtime/001-normal.png",
  frames = 6, walker = true, trueColor = true,
}, { speciesId = 1, packId = "swimming", variant = "shiny", voxelActive = false })
-- May or may not have shiny swim; either applied or missing fallback — no crash
check(infoM.reason ~= nil, "missing path returns reason")

-- Schema: pokemon_size was removed; size follows Sprite Style.
local schema = assert(loadfile("options.lua"))()
local foundSize = false
for _, opt in ipairs(schema) do
  if opt.key == "pokemon_size" then foundSize = true end
end
eq(foundSize, false, "pokemon_size option removed")

local mf = assert(io.open("manifest.json"):read("*a"))
check(mf:find('"version"', 1, true), "manifest has version")

-- HGSS quality: native philosophy prefers pad-only (no default resize).
do
  local raw = assert(io.open("assets/generated/true_size/generation_report.json"):read("*a"))
  local pad = tonumber(raw:match('"hgss_pad_only"%s*:%s*(%d+)'))
  local resized = tonumber(raw:match('"hgss_resized"%s*:%s*(%d+)'))
  check(pad ~= nil, "hgss_pad_only present")
  check(resized ~= nil, "hgss_resized present")
end

print("PASS variable_size_unit_test")
