-- Battle Art variable SpriteBillboards adapter (no LOVE / no real Voxel mod).
-- Run: lua tests/battle_art_variable_geometry_unit_test.lua

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

local function close(a, b, msg, eps)
  eps = eps or 1e-6
  if math.abs((a or 0) - (b or 0)) > eps then
    fail(string.format("%s (got %s expected %s)", msg, tostring(a), tostring(b)))
  end
end

package.path = "./?.lua;./?/init.lua;" .. package.path

local imageSizes = {}
package.preload["src.render.Assets"] = function()
  return {
    image = function(path)
      local sz = imageSizes[path] or { 16, 96 }
      return {
        getDimensions = function() return sz[1], sz[2] end,
      }
    end,
    register = function() end,
  }
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

local modules = {}
local savedOpts = { pokemon_size = "true_size", sprite_style = "pokemmo" }
local origMeshCalls = 0
local builtCards = {}

local function makeSpriteBillboards()
  local SB = {}
  function SB.mesh(def, frame)
    origMeshCalls = origMeshCalls + 1
    return { kind = "original", image = def and def.image, frame = frame }
  end
  SB.shadowQuad = SB.mesh
  function SB.invalidate()
    -- orig cache clear
  end
  return SB
end

local function makeVoxel3D()
  return {
    pushQuad = function(map, n)
      local b = n * 4
      map[#map + 1] = b + 1
      map[#map + 1] = b + 2
      map[#map + 1] = b + 3
      map[#map + 1] = b + 1
      map[#map + 1] = b + 3
      map[#map + 1] = b + 4
    end,
    newMesh = function(verts, indices)
      local card = { kind = "variable", verts = verts, indices = indices }
      builtCards[#builtCards + 1] = card
      return card
    end,
  }
end

local SpriteBillboards = makeSpriteBillboards()
local Voxel3D = makeVoxel3D()
local battleArtSrc = [[
local function buildCard(def, frame)
  local fy = frame * 16
  local verts = { { 0, 0, 0 }, { 16, 16, 0 } }
end
]]

local lib = {
  require = function(name)
    if name == "SpriteBillboards" then return SpriteBillboards end
    if name == "Voxel3D" then return Voxel3D end
    error("unexpected lib.require " .. tostring(name))
  end,
}

local battleArtMod = {
  exports = { version = "1.8.3", lib = lib },
  read = function(_m, rel)
    if rel == "lib/SpriteBillboards.lua" then return battleArtSrc end
  end,
}

local mod = {
  id = "overworld_wild_spawns",
  path = ".",
  log = { info = function() end, warn = function() end },
  options = {
    get = function(_, k) return savedOpts[k] end,
    set = function(_, k, v) savedOpts[k] = v end,
  },
  find = function(_self, id)
    if id == "BATTLE_ART_VOXEL_FORK" then return battleArtMod end
    return nil
  end,
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

local SpeciesGeometry = V.require("species_geometry")
local VariableSize = V.require("variable_size")
local Adapter = V.require("compat/battle_art_variable_geometry")

-- ------------------------------------------------------------------ geometry
local onix = SpeciesGeometry.packGeometry(95, "pokemmo", mod)
check(onix ~= nil, "Onix HGSS pack exists")
eq(onix.frameWidth, 35, "Onix frameWidth from generated table")
eq(onix.frameHeight, 38, "Onix frameHeight from generated table")
eq(onix.anchorX, 17.5, "Onix anchorX from generated table")
eq(onix.anchorY, 36.0, "Onix anchorY from generated table")

local rattata = SpeciesGeometry.packGeometry(19, "pokemmo", mod)
eq(rattata.frameWidth, 25, "Rattata fw")
eq(rattata.frameHeight, 28, "Rattata fh")

local blastoise = SpeciesGeometry.packGeometry(9, "pokemmo", mod)
eq(blastoise.frameWidth, 31, "Blastoise fw")
eq(blastoise.frameHeight, 30, "Blastoise fh")

local swim = SpeciesGeometry.packGeometry(95, "swimming", mod)
check(swim.frameWidth > 16 and swim.frameHeight > 16, "Onix swimming variable")
local levitate = SpeciesGeometry.packGeometry(95, "levitate", mod)
eq(levitate.frameWidth, 35, "Onix levitate fw")
eq(levitate.frameHeight, 38, "Onix levitate fh")

check(not Adapter.needsVariableGeometry({ image = "npc.png" }), "vanilla no geom")
check(not Adapter.needsVariableGeometry({
  image = "npc.png", frameWidth = 16, frameHeight = 16, anchorX = 8, anchorY = 16,
}), "explicit 16x16 is vanilla")
check(Adapter.needsVariableGeometry(onix), "Onix needs variable")

local x0, y0, x1, y1 = Adapter.localQuad(16, 16, 8, 16)
eq(x0, 0, "vanilla x0")
eq(y0, 0, "vanilla y0")
eq(x1, 16, "vanilla x1")
eq(y1, 16, "vanilla y1")

x0, y0, x1, y1 = Adapter.localQuad(onix.frameWidth, onix.frameHeight, onix.anchorX, onix.anchorY)
close(x0, 8 - 17.5, "Onix x0 = pivot - anchorX")
close(x1, x0 + 35, "Onix width 35")
close(y0, 36 - 38, "Onix y0 = anchorY - frameHeight")
close(y1, 36, "Onix y1 = anchorY")
close(x1 - x0, 35, "Onix billboard W")
close(y1 - y0, 38, "Onix billboard H")

-- After Battle Art T(-8,0,0), the anchor column is at x=0 (cell centre).
close((x0 - 8) + onix.anchorX, 0, "anchor maps to T(-8) origin")

local u0, v0, u1, v1, fy = Adapter.uvRect(35, 38, 0, 35, 228)
check(u0 ~= nil, "frame 0 UVs")
eq(fy, 0, "frame 0 fy")
close(u1, (35 - 0.02) / 35, "u1 uses frameWidth")
close(v1, (38 - 0.05) / 228, "v1 uses frameHeight")

u0, v0, u1, v1, fy = Adapter.uvRect(35, 38, 5, 35, 228)
eq(fy, 5 * 38, "frame 5 fy = frame * fh")
local overflow, why = Adapter.uvRect(35, 38, 6, 35, 228)
eq(overflow, nil, "frame 6 overflows 6*38 sheet")
eq(why, "frame_overflow", "overflow reason")

local key = Adapter.cacheKey({ image = "onix.png" }, 3, 35, 38, 17.5, 36)
check(key:find("onix.png", 1, true) and key:find("35", 1, true)
  and key:find("38", 1, true) and key:find("17.5", 1, true),
  "cache key includes image/frame/geometry")

-- ------------------------------------------------------------------ install
Adapter.reset()
origMeshCalls = 0
builtCards = {}
SpriteBillboards = makeSpriteBillboards()
Voxel3D = makeVoxel3D()
lib.require = function(name)
  if name == "SpriteBillboards" then return SpriteBillboards end
  if name == "Voxel3D" then return Voxel3D end
  error("unexpected " .. tostring(name))
end

check(not Adapter.isInstalled(), "not installed yet")
local okInstall, whyInstall = Adapter.install(mod)
check(okInstall, "install ok: " .. tostring(whyInstall))
check(Adapter.supportsVariableGeometry(), "supports after install")
eq(Adapter.supportReason(), "wrapped_mesh", "reason wrapped_mesh")

local ok2, why2 = Adapter.install(mod)
check(ok2, "idempotent install")
eq(why2, "wrapped_mesh", "second install does not double-wrap")

-- Vanilla NPC: original mesh path
local npc = { image = "trainer.png" }
imageSizes["trainer.png"] = { 16, 96 }
local mNpc = SpriteBillboards.mesh(npc, 0)
eq(mNpc.kind, "original", "vanilla uses original mesh")
eq(origMeshCalls, 1, "one orig call")

-- Same via shadowQuad
local mNpcS = SpriteBillboards.shadowQuad(npc, 0)
eq(mNpcS.kind, "original", "shadowQuad vanilla original")

-- Onix variable card
local onixDef = {
  image = "assets/generated/true_size/hgss/095-normal.png",
  frames = 6, walker = true,
  frameWidth = onix.frameWidth,
  frameHeight = onix.frameHeight,
  anchorX = onix.anchorX,
  anchorY = onix.anchorY,
}
imageSizes[onixDef.image] = { 35, 228 }
local mOnix = SpriteBillboards.mesh(onixDef, 0)
eq(mOnix.kind, "variable", "Onix uses variable mesh")
check(mOnix.verts, "Onix verts present")
close(mOnix.verts[1][1], 8 - 17.5, "Onix vert x0")
close(mOnix.verts[2][1], 8 - 17.5 + 35, "Onix vert x1")
close(mOnix.verts[1][2], 36 - 38, "Onix vert y0")
close(mOnix.verts[3][2], 36, "Onix vert y1")
close(mOnix.verts[1][5], (0 + 38 - 0.05) / 228, "Onix bottom V")
close(mOnix.verts[3][5], (0 + 0.05) / 228, "Onix top V")

local mOnix2 = SpriteBillboards.mesh(onixDef, 0)
eq(mOnix2, mOnix, "Onix mesh cached")
eq(#builtCards, 1, "one GPU mesh built")

local mShadow = SpriteBillboards.shadowQuad(onixDef, 0)
eq(mShadow, mOnix, "shadow uses same variable mesh")

-- All six walk frames
for frame = 0, 5 do
  local m = SpriteBillboards.mesh(onixDef, frame)
  eq(m.kind, "variable", "frame " .. frame .. " variable")
end
eq(#builtCards, 6, "six cached frames")

-- Overflow frame falls back to original
local beforeOrig = origMeshCalls
local mBad = SpriteBillboards.mesh(onixDef, 9)
eq(mBad.kind, "original", "overflow falls back to original")
check(origMeshCalls > beforeOrig, "overflow called orig")

-- Rattata / Blastoise
local ratDef = {
  image = "rattata.png", frames = 6,
  frameWidth = rattata.frameWidth, frameHeight = rattata.frameHeight,
  anchorX = rattata.anchorX, anchorY = rattata.anchorY,
}
imageSizes["rattata.png"] = { 25, 28 * 6 }
local mRat = SpriteBillboards.mesh(ratDef, 0)
eq(mRat.kind, "variable", "Rattata variable")
close(mRat.verts[2][1] - mRat.verts[1][1], 25, "Rattata W")
close(mRat.verts[3][2] - mRat.verts[1][2], 28, "Rattata H")

local blaDef = {
  image = "blastoise.png", frames = 6,
  frameWidth = blastoise.frameWidth, frameHeight = blastoise.frameHeight,
  anchorX = blastoise.anchorX, anchorY = blastoise.anchorY,
}
imageSizes["blastoise.png"] = { 31, 30 * 6 }
local mBla = SpriteBillboards.mesh(blaDef, 0)
eq(mBla.kind, "variable", "Blastoise variable")
close(mBla.verts[2][1] - mBla.verts[1][1], 31, "Blastoise W")
close(mBla.verts[3][2] - mBla.verts[1][2], 30, "Blastoise H")

-- ------------------------------------------------------------------ VariableSize
VariableSize.clearCaches()
savedOpts.sprite_style = "pokemmo"
local can, canWhy = VariableSize.canUseTrueSizeInVoxel(mod, { voxelActive = true })
check(can, "canUseTrueSizeInVoxel after adapter: " .. tostring(canWhy))
local eff, why = VariableSize.effectiveMode(mod, { voxelActive = true })
eq(eff, "true_size", "effective True Size in Voxel with adapter")
eq(why, "ok", "voxel ok")

local def = {
  image = "assets/generated/followsprites_runtime/095-normal.png",
  frames = 6, walker = true, trueColor = true,
}
local out, info = VariableSize.applyToDef(mod, def, {
  speciesId = 95, style = "pokemmo", variant = "normal", voxelActive = true,
})
check(info.applied, "Onix True Size applied under Voxel")
eq(out.frameWidth, 35, "applied fw 35")
eq(out.frameHeight, 38, "applied fh 38")
check(out.image:find("true_size/hgss", 1, true), "true_size hgss path")

-- GSC / Classic requested stays Classic
savedOpts.sprite_style = "followers"
VariableSize.clearCaches()
-- Re-install: clearCaches does not unwrap; adapter still installed.
local effG, whyG = VariableSize.effectiveMode(mod, { voxelActive = true })
eq(effG, "classic", "GSC Classic in Voxel")
eq(whyG, "classic_requested", "classic requested")

-- Dramaless / no Battle Art: Classic fallback
Adapter.reset()
SpriteBillboards = makeSpriteBillboards()
mod.find = function() return nil end
VariableSize.clearCaches()
savedOpts.sprite_style = "pokemmo"
local effD, whyD = VariableSize.effectiveMode(mod, { voxelActive = true })
eq(effD, "classic", "no voxel renderer → Classic")
check(whyD:find("voxel_ds_incompatible", 1, true) == 1, "incompatible reason")
check(not Adapter.supportsVariableGeometry(), "adapter not supported")

-- Failed wrap logs once and stays Classic
Adapter.reset()
local badLib = {
  require = function() error("nope") end,
}
mod.find = function(_self, id)
  if id == "BATTLE_ART_VOXEL_FORK" then
    return { exports = { version = "1.8.3", lib = badLib } }
  end
end
VariableSize.clearCaches()
local warnCount = 0
mod.log.warn = function() warnCount = warnCount + 1 end
local effF, whyF = VariableSize.effectiveMode(mod, { voxelActive = true })
eq(effF, "classic", "failed adapter → Classic")
check(whyF:find("voxel_ds_incompatible", 1, true) == 1, "failed reason")
check(warnCount >= 1, "failure logged")
local _effF2 = VariableSize.effectiveMode(mod, { voxelActive = true })
eq(warnCount, 1, "failure logged once")

-- Native export: no wrap needed
Adapter.reset()
mod.find = function(_self, id)
  if id == "BATTLE_ART_VOXEL_FORK" then
    return {
      exports = { version = "1.9.0", variableSpriteGeometry = true, lib = lib },
      read = function() return battleArtSrc end,
    }
  end
end
VariableSize.clearCaches()
local okN, whyN = Adapter.install(mod)
check(okN, "native install")
eq(whyN, "exports_flag", "uses export flag, no wrap")
eq(Adapter.state(), "native", "native state")
local effN = VariableSize.effectiveMode(mod, { voxelActive = true })
eq(effN, "true_size", "native export keeps True Size")

-- Shared finder
mod.find = function(_self, id)
  if id == "BATTLE_ART_VOXEL_FORK" then return battleArtMod end
end
local found, foundId = VariableSize.findVoxelRenderer(mod)
check(found ~= nil, "findVoxelRenderer finds Battle Art")
eq(foundId, "BATTLE_ART_VOXEL_FORK", "id is Battle Art")

print("PASS battle_art_variable_geometry_unit_test")
