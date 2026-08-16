-- Stadium2 (STADIUM2_OVERWORLD_MODELS) variable SpriteBillboards adapter.
-- Mocks only; no real Voxel mod. Run:
--   lua tests/stadium2_variable_geometry_unit_test.lua

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

local FIXED_16_SRC = [[
local function buildCard(def, frame)
  local fy = frame * 16
  local verts = { { 0, 0, 0 }, { 16, 16, 0 } }
end
]]

local NATIVE_SRC = [[
local function buildCard(def, frame)
  local fw = def.frameWidth or 16
  local geom = getFrameGeometry(def, frame)
  local fy = frame * fw
end
]]

local function makeSpriteBillboards()
  local SB = {}
  function SB.mesh(def, frame)
    origMeshCalls = origMeshCalls + 1
    return { kind = "original", image = def and def.image, frame = frame }
  end
  SB.shadowQuad = SB.mesh
  function SB.invalidate() end
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

local function makeVoxelState(active)
  return {
    active = function() return active == true end,
  }
end

local function makeLib(sb, v3, voxelState)
  return {
    require = function(name)
      if name == "SpriteBillboards" then return sb end
      if name == "Voxel3D" then return v3 end
      if name == "VoxelState" then
        if voxelState == nil then error("VoxelState missing") end
        return voxelState
      end
      error("unexpected lib.require " .. tostring(name))
    end,
  }
end

local function makeProvider(opts)
  opts = opts or {}
  local sb = opts.sb or makeSpriteBillboards()
  local v3 = opts.v3 or makeVoxel3D()
  local voxelState = opts.voxelState or makeVoxelState(true)
  local lib = opts.lib
  if lib == nil and opts.publicLib ~= false then
    lib = makeLib(sb, v3, voxelState)
  end
  return {
    sb = sb,
    v3 = v3,
    voxelState = voxelState,
    exports = {
      version = opts.version or "0.1.0",
      lib = lib,
      variableSpriteGeometry = opts.native or nil,
      embeddedWilds = opts.embeddedWilds,
    },
    read = function(_m, rel)
      if rel == "lib/SpriteBillboards.lua" then
        return opts.src or FIXED_16_SRC
      end
    end,
  }
end

local installed = {}

local mod = {
  id = "overworld_wild_spawns",
  path = ".",
  log = { info = function() end, warn = function() end },
  options = {
    get = function(_, k) return savedOpts[k] end,
    set = function(_, k, v) savedOpts[k] = v end,
  },
  find = function(_self, id)
    return installed[id]
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
local Stadium2 = V.require("compat/stadium2_variable_geometry")
local BattleArt = V.require("compat/battle_art_variable_geometry")
local Potato = V.require("compat/potato_voxel_variable_geometry")
local Dramaless = V.require("compat/dramaless_variable_geometry")

local function resetAll()
  Stadium2.reset()
  BattleArt.reset()
  Potato.reset()
  Dramaless.reset()
  VariableSize.clearCaches()
  VariableSize.resetEffectiveModePoll()
  installed = {}
  origMeshCalls = 0
  builtCards = {}
  savedOpts.sprite_style = "pokemmo"
  savedOpts.pokemon_size = "true_size"
end

-- ------------------------------------------------------------------ SpeciesGeometry (source of truth)
local rattata = SpeciesGeometry.packGeometry(19, "pokemmo", mod)
local pikachu = SpeciesGeometry.packGeometry(25, "pokemmo", mod)
local blastoise = SpeciesGeometry.packGeometry(9, "pokemmo", mod)
local onix = SpeciesGeometry.packGeometry(95, "pokemmo", mod)
local onixSwim = SpeciesGeometry.packGeometry(95, "swimming", mod)
check(rattata and pikachu and blastoise and onix, "HGSS packs exist")
check(rattata.frameWidth < onix.frameWidth, "Rattata smaller than Onix (fw)")
check(rattata.frameHeight < onix.frameHeight, "Rattata smaller than Onix (fh)")
check(onixSwim and onixSwim.frameWidth > 16 and onixSwim.frameHeight > 16,
  "Onix swimming variable")

eq(VariableSize.PROVIDER_STADIUM2, "STADIUM2_OVERWORLD_MODELS",
  "PROVIDER_STADIUM2 id")
local sawStadium2 = false
for _, id in ipairs(VariableSize.VOXEL_RENDERER_IDS) do
  if id == "STADIUM2_OVERWORLD_MODELS" then sawStadium2 = true end
end
check(sawStadium2, "STADIUM2_OVERWORLD_MODELS in VOXEL_RENDERER_IDS")

-- ------------------------------------------------------------------ 1. Provider discovery
resetAll()
local pub = makeProvider({ version = "gen2" })
installed.STADIUM2_OVERWORLD_MODELS = pub
local found, foundId, foundWhy = VariableSize.activeVoxelProvider(mod)
check(found ~= nil, "Stadium2 discovered")
eq(foundId, "STADIUM2_OVERWORLD_MODELS", "active provider Stadium2")
eq(foundWhy, "voxel_state_active", "unique VoxelState.active")
local listed = VariableSize.findInstalledVoxelRenderers(mod)
eq(#listed, 1, "one installed renderer")
eq(listed[1].id, "STADIUM2_OVERWORLD_MODELS", "listed Stadium2")

-- ------------------------------------------------------------------ 2. Default 16×16 geometry → original mesh
resetAll()
pub = makeProvider()
installed.STADIUM2_OVERWORLD_MODELS = pub
check(Stadium2.install(mod), "install for vanilla")
eq(Stadium2.supportReason(), "wrapped_mesh", "wrapped_mesh")
check(not Stadium2.needsVariableGeometry({ image = "npc.png" }), "no geom fields")
check(not Stadium2.needsVariableGeometry({
  image = "npc.png", frameWidth = 16, frameHeight = 16, anchorX = 8, anchorY = 16,
}), "explicit 16x16 is vanilla")
local x0, y0, x1, y1 = Stadium2.localQuad(16, 16, 8, 16)
eq(x0, 0, "vanilla x0")
eq(y0, 0, "vanilla y0")
eq(x1, 16, "vanilla x1")
eq(y1, 16, "vanilla y1")
origMeshCalls = 0
eq(pub.sb.mesh({ image = "trainer.png" }, 0).kind, "original", "vanilla original")
eq(origMeshCalls, 1, "vanilla one orig call")
eq(pub.sb.mesh({
  image = "trainer.png", frameWidth = 16, frameHeight = 16, anchorX = 8, anchorY = 16,
}, 1).kind, "original", "explicit 16×16 original")

-- ------------------------------------------------------------------ 3–5. Variable geometry, anchors, UVs
resetAll()
pub = makeProvider()
installed.STADIUM2_OVERWORLD_MODELS = pub
check(Stadium2.install(mod), "install for variable")

local shapes = {
  { name = "small", fw = 12, fh = 12, ax = 6, ay = 12 },
  { name = "wide", fw = 32, fh = 16, ax = 16, ay = 16 },
  { name = "tall", fw = 16, fh = 32, ax = 8, ay = 32 },
  { name = "large", fw = 32, fh = 32, ax = 16, ay = 32 },
}
for _, sh in ipairs(shapes) do
  check(Stadium2.needsVariableGeometry({
    image = sh.name .. ".png",
    frameWidth = sh.fw, frameHeight = sh.fh, anchorX = sh.ax, anchorY = sh.ay,
  }), sh.name .. " needs variable")
  local qx0, qy0, qx1, qy1 = Stadium2.localQuad(sh.fw, sh.fh, sh.ax, sh.ay)
  close(qx0, 8 - sh.ax, sh.name .. " x0 = pivot - anchorX")
  close(qx1, qx0 + sh.fw, sh.name .. " width")
  close(qy0, sh.ay - sh.fh, sh.name .. " y0 = anchorY - fh")
  close(qy1, sh.ay, sh.name .. " y1 = anchorY")
  -- After Stadium2 T(-8,0,0), the SpriteDef anchor column is at x=0.
  close((qx0 - 8) + sh.ax, 0, sh.name .. " anchor on T(-8) pivot")
  imageSizes[sh.name .. ".png"] = { sh.fw, sh.fh * 6 }
  local def = {
    image = sh.name .. ".png", frames = 6,
    frameWidth = sh.fw, frameHeight = sh.fh, anchorX = sh.ax, anchorY = sh.ay,
  }
  local mesh = pub.sb.mesh(def, 2)
  eq(mesh.kind, "variable", sh.name .. " variable mesh")
  close(mesh.verts[2][1] - mesh.verts[1][1], sh.fw, sh.name .. " mesh W")
  close(mesh.verts[3][2] - mesh.verts[1][2], sh.fh, sh.name .. " mesh H")
  local u0, v0, u1, v1, fy = Stadium2.uvRect(sh.fw, sh.fh, 2, sh.fw, sh.fh * 6)
  check(u0 ~= nil, sh.name .. " UVs")
  eq(fy, 2 * sh.fh, sh.name .. " fy = frame * fh")
  close(u1, (sh.fw - 0.02) / sh.fw, sh.name .. " u1 uses fw")
  close(v1, (2 * sh.fh + sh.fh - 0.05) / (sh.fh * 6), sh.name .. " v1 uses fh")
end

-- ------------------------------------------------------------------ 6. Cache keys
resetAll()
pub = makeProvider()
installed.STADIUM2_OVERWORLD_MODELS = pub
check(Stadium2.install(mod), "install for cache")
local k1 = Stadium2.cacheKey({ image = "same.png" }, 0, 20, 20, 10, 20)
local k2 = Stadium2.cacheKey({ image = "same.png" }, 0, 32, 20, 16, 20)
check(k1 ~= k2, "different geometry → different cache keys")
imageSizes["same.png"] = { 32, 120 }
local a = pub.sb.mesh({
  image = "same.png", frameWidth = 20, frameHeight = 20, anchorX = 10, anchorY = 20,
}, 0)
local b = pub.sb.mesh({
  image = "same.png", frameWidth = 32, frameHeight = 20, anchorX = 16, anchorY = 20,
}, 0)
eq(a.kind, "variable", "cache A variable")
eq(b.kind, "variable", "cache B variable")
check(a ~= b, "same image/frame different geometry must not collide")
eq(pub.sb.mesh({
  image = "same.png", frameWidth = 20, frameHeight = 20, anchorX = 10, anchorY = 20,
}, 0), a, "same geometry reuses mesh")

-- ------------------------------------------------------------------ 7. shadowQuad shares variable geometry
resetAll()
pub = makeProvider()
installed.STADIUM2_OVERWORLD_MODELS = pub
local origShadow = pub.sb.shadowQuad
check(Stadium2.install(mod), "install for shadow")
check(pub.sb.shadowQuad ~= origShadow, "shadowQuad re-pointed")
local onixDef = {
  image = "assets/generated/true_size/hgss/095-normal.png",
  frames = 6, walker = true,
  frameWidth = onix.frameWidth, frameHeight = onix.frameHeight,
  anchorX = onix.anchorX, anchorY = onix.anchorY,
}
imageSizes[onixDef.image] = { onix.frameWidth, onix.frameHeight * 6 }
local mOnix = pub.sb.mesh(onixDef, 0)
eq(mOnix.kind, "variable", "Onix variable")
eq(pub.sb.shadowQuad(onixDef, 0), mOnix, "shadowQuad same mesh")

-- ------------------------------------------------------------------ 8. Native capability — do not wrap
resetAll()
local nativePub = makeProvider({
  native = true,
  src = NATIVE_SRC,
  version = "future",
})
installed.STADIUM2_OVERWORLD_MODELS = nativePub
local origMesh = nativePub.sb.mesh
local okN, whyN = Stadium2.install(mod)
check(okN, "native install")
eq(whyN, "exports_flag", "uses export flag")
eq(Stadium2.state(), "native", "native state")
eq(nativePub.sb.mesh, origMesh, "native does not wrap mesh")
check(Stadium2.supportsVariableGeometry(), "native supports")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "true_size",
  "native keeps True Size")
local sumN = VariableSize.summary(mod)
eq(sumN.capabilityReason, "native_variable_geometry", "diag native reason")
eq(sumN.adapterState, "native", "diag adapter native")

-- Source inspection without export flag
resetAll()
local srcNative = makeProvider({ src = NATIVE_SRC })
srcNative.exports.variableSpriteGeometry = nil
installed.STADIUM2_OVERWORLD_MODELS = srcNative
local origMesh2 = srcNative.sb.mesh
local okS, whyS = Stadium2.install(mod)
check(okS, "source-native install")
eq(whyS, "sprite_billboards_geometry_api", "source inspection")
eq(srcNative.sb.mesh, origMesh2, "source-native does not wrap")

-- ------------------------------------------------------------------ 9. Missing / broken provider → Classic
resetAll()
local okAbs, whyAbs = Stadium2.install(mod)
check(not okAbs, "absent does not install")
eq(whyAbs, "provider_absent", "absent reason")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "classic",
  "absent → Classic")
check(not Stadium2.supportsVariableGeometry(), "absent unsupported")

resetAll()
installed.STADIUM2_OVERWORLD_MODELS = {
  exports = { version = "0.1.0" },
  read = function(_m, rel)
    if rel == "lib/SpriteBillboards.lua" then return FIXED_16_SRC end
  end,
}
local okBroken, whyBroken = Stadium2.install(mod)
check(not okBroken, "no lib does not install")
check(tostring(whyBroken):find("exports.lib.require missing", 1, true),
  "missing public accessor")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "classic",
  "broken Stadium2 → Classic")
local sumFail = VariableSize.summary(mod)
eq(sumFail.effectiveMode, "classic", "summary classic on failure")
check(sumFail.fallbackReason ~= nil, "honest fallback reason")
check(sumFail.supportsVariableGeometry ~= true, "no silent support claim")

resetAll()
installed.STADIUM2_OVERWORLD_MODELS = makeProvider({
  lib = {
    require = function() error("nope") end,
  },
})
check(not Stadium2.install(mod), "require boom → fail")
eq(Stadium2.state(), "failed", "failed state")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "classic",
  "failed wrap → Classic")

-- ------------------------------------------------------------------ 10. Existing providers still recognized
resetAll()
installed.BATTLE_ART_VOXEL_FORK = makeProvider({ version = "1.8.3" })
check(BattleArt.install(mod), "Battle Art still installs")
eq(select(2, VariableSize.activeVoxelProvider(mod)), "BATTLE_ART_VOXEL_FORK",
  "Battle Art still discovered")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "true_size",
  "Battle Art True Size unchanged")

resetAll()
installed.potato_voxel = makeProvider({ version = "1.4.0" })
check(Potato.install(mod), "Potato still installs")
eq(select(2, VariableSize.activeVoxelProvider(mod)), "potato_voxel",
  "Potato still discovered")

resetAll()
installed.DRAMALESS_SHAPE = makeProvider({ version = "1.6.4" })
check(Dramaless.install(mod), "Dramaless still installs")
eq(select(2, VariableSize.activeVoxelProvider(mod)), "DRAMALESS_SHAPE",
  "Dramaless still discovered")

-- Multi: Stadium2 idle, Battle Art active — do not borrow Stadium2
resetAll()
local baActive = makeProvider({ version = "1.8.3", voxelState = makeVoxelState(true) })
local stIdle = makeProvider({ version = "gen2", voxelState = makeVoxelState(false) })
installed.BATTLE_ART_VOXEL_FORK = baActive
installed.STADIUM2_OVERWORLD_MODELS = stIdle
eq(select(2, VariableSize.activeVoxelProvider(mod)), "BATTLE_ART_VOXEL_FORK",
  "active Battle Art wins over idle Stadium2")

-- Multi: Stadium2 active unsupported must not borrow Battle Art
resetAll()
installed.BATTLE_ART_VOXEL_FORK = makeProvider({
  version = "1.8.3", voxelState = makeVoxelState(false),
})
installed.STADIUM2_OVERWORLD_MODELS = {
  exports = {
    version = "gen2",
    lib = {
      require = function(name)
        if name == "VoxelState" then return makeVoxelState(true) end
        error("no SpriteBillboards")
      end,
    },
  },
  read = function(_m, rel)
    if rel == "lib/SpriteBillboards.lua" then return FIXED_16_SRC end
  end,
}
check(BattleArt.install(mod), "Battle Art idle still installs")
eq(select(2, VariableSize.activeVoxelProvider(mod)), "STADIUM2_OVERWORLD_MODELS",
  "Stadium2 is the active provider")
check(not VariableSize.canUseTrueSizeInVoxel(mod, { voxelActive = true }),
  "unsupported Stadium2 must not borrow Battle Art")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "classic",
  "unsupported Stadium2 → Classic")

-- ------------------------------------------------------------------ 11. SpeciesGeometry integration
resetAll()
pub = makeProvider()
installed.STADIUM2_OVERWORLD_MODELS = pub
check(Stadium2.install(mod), "install for species")
local ratDef = {
  image = "rattata.png", frames = 6,
  frameWidth = rattata.frameWidth, frameHeight = rattata.frameHeight,
  anchorX = rattata.anchorX, anchorY = rattata.anchorY,
}
imageSizes["rattata.png"] = { rattata.frameWidth, rattata.frameHeight * 6 }
local pikaDef = {
  image = "pikachu.png", frames = 6,
  frameWidth = pikachu.frameWidth, frameHeight = pikachu.frameHeight,
  anchorX = pikachu.anchorX, anchorY = pikachu.anchorY,
}
imageSizes["pikachu.png"] = { pikachu.frameWidth, pikachu.frameHeight * 6 }
local blaDef = {
  image = "blastoise.png", frames = 6,
  frameWidth = blastoise.frameWidth, frameHeight = blastoise.frameHeight,
  anchorX = blastoise.anchorX, anchorY = blastoise.anchorY,
}
imageSizes["blastoise.png"] = { blastoise.frameWidth, blastoise.frameHeight * 6 }
imageSizes[onixDef.image] = { onix.frameWidth, onix.frameHeight * 6 }
local mRat = pub.sb.mesh(ratDef, 0)
local mPika = pub.sb.mesh(pikaDef, 0)
local mBla = pub.sb.mesh(blaDef, 0)
local mBig = pub.sb.mesh(onixDef, 0)
close(mRat.verts[2][1] - mRat.verts[1][1], rattata.frameWidth, "Rattata W")
close(mPika.verts[2][1] - mPika.verts[1][1], pikachu.frameWidth, "Pikachu W")
close(mBla.verts[2][1] - mBla.verts[1][1], blastoise.frameWidth, "Blastoise W")
close(mBig.verts[2][1] - mBig.verts[1][1], onix.frameWidth, "Onix W")
check((mRat.verts[2][1] - mRat.verts[1][1])
    < (mBig.verts[2][1] - mBig.verts[1][1]),
  "small HGSS species billboard narrower than Onix")

local applied, info = VariableSize.applyToDef(mod, {
  image = "assets/generated/followsprites_runtime/095-normal.png",
  frames = 6, walker = true, trueColor = true,
}, { speciesId = 95, style = "pokemmo", variant = "normal", voxelActive = true })
check(info.applied, "Onix True Size applied under Stadium2 Voxel")
eq(applied.frameWidth, onix.frameWidth, "applied Onix fw from SpeciesGeometry")
eq(applied.frameHeight, onix.frameHeight, "applied Onix fh from SpeciesGeometry")

-- ------------------------------------------------------------------ 12. Water / swimming SpriteDef retains geometry
resetAll()
pub = makeProvider()
installed.STADIUM2_OVERWORLD_MODELS = pub
check(Stadium2.install(mod), "install for water")
local swimDef = {
  image = "assets/generated/true_size/swimming/095-normal.png",
  frames = 6, walker = true, trueColor = true,
}
local swimOut, swimInfo = VariableSize.applyToDef(mod, swimDef, {
  speciesId = 95, style = "pokemmo", presentation = "swimming",
  variant = "normal", voxelActive = true,
})
check(swimInfo.applied, "Onix swimming True Size applied")
eq(swimOut.frameWidth, onixSwim.frameWidth, "swim fw from SpeciesGeometry")
eq(swimOut.frameHeight, onixSwim.frameHeight, "swim fh from SpeciesGeometry")
imageSizes[swimOut.image] = { onixSwim.frameWidth, onixSwim.frameHeight * 6 }
local mSwim = pub.sb.mesh(swimOut, 1)
eq(mSwim.kind, "variable", "swimming variable mesh")
close(mSwim.verts[2][1] - mSwim.verts[1][1], onixSwim.frameWidth, "swim mesh W")
close(mSwim.verts[3][2] - mSwim.verts[1][2], onixSwim.frameHeight, "swim mesh H")
eq(pub.sb.shadowQuad(swimOut, 1), mSwim, "swim shadowQuad same mesh")
local _, _, _, _, swimFy = Stadium2.uvRect(
  onixSwim.frameWidth, onixSwim.frameHeight, 1,
  onixSwim.frameWidth, onixSwim.frameHeight * 6)
eq(swimFy, onixSwim.frameHeight, "swim fy = 1 * frameHeight")

-- GSC / Classic requested stays Classic under Stadium2
resetAll()
installed.STADIUM2_OVERWORLD_MODELS = makeProvider()
check(Stadium2.install(mod), "install for GSC")
savedOpts.sprite_style = "followers"
VariableSize.clearCaches()
local effG, whyG = VariableSize.effectiveMode(mod, { voxelActive = true })
eq(effG, "classic", "GSC Classic in Stadium2 Voxel")
eq(whyG, "classic_requested", "GSC classic requested")

-- Diagnostics: wrapped adapter
resetAll()
installed.STADIUM2_OVERWORLD_MODELS = makeProvider()
check(Stadium2.install(mod), "install for diag")
local sum = VariableSize.summary(mod)
eq(sum.requestedMode, "true_size", "diag requested")
eq(sum.effectiveMode, "true_size", "diag effective")
eq(sum.provider, "STADIUM2_OVERWORLD_MODELS", "diag provider")
check(sum.providerDetected, "diag detected")
check(sum.adapterInstalled, "diag adapter installed")
check(sum.supportsVariableGeometry, "diag supports")
eq(sum.capabilityReason, "wilds_adapter", "diag wilds_adapter")
check(sum.native == false, "wrapped is not native")
local lines = VariableSize.diagnosticLines(mod)
local joined = table.concat(lines, "\n")
check(joined:find("Size requested: true_size", 1, true), "HUD requested")
check(joined:find("Size effective: true_size", 1, true), "HUD effective")
check(joined:find("STADIUM2_OVERWORLD_MODELS", 1, true), "HUD provider")
check(joined:find("wilds_adapter", 1, true), "HUD wilds_adapter")

-- Embedded Wilds: public export probe only (no disable)
resetAll()
installed.STADIUM2_OVERWORLD_MODELS = makeProvider({ embeddedWilds = true })
local emb, embWhy = Stadium2.detectEmbeddedWilds(mod)
check(emb, "embedded Wilds export detected")
eq(embWhy, "exports_flag", "embedded reason")
resetAll()
installed.STADIUM2_OVERWORLD_MODELS = makeProvider()
local noEmb, noEmbWhy = Stadium2.detectEmbeddedWilds(mod)
check(not noEmb, "no embedded signal")
eq(noEmbWhy, "no_public_embedded_wilds_signal", "no signal reason")

print("PASS stadium2_variable_geometry_unit_test")
