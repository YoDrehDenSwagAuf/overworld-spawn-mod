-- Voxel provider selection + Potato / Dramaless public-module adapters.
-- Mocks only; no real Voxel mods. Run:
--   lua tests/voxel_provider_variable_geometry_unit_test.lua

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

local function makeSpriteBillboards(opts)
  opts = opts or {}
  local SB = {}
  function SB.mesh(def, frame)
    origMeshCalls = origMeshCalls + 1
    return { kind = "original", image = def and def.image, frame = frame }
  end
  SB.shadowQuad = SB.mesh
  if opts.shadowBlob ~= false then
    function SB.shadowBlob()
      return { kind = "blob" }, { kind = "blob_tex" }
    end
  end
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
  local sb = opts.sb or makeSpriteBillboards({ shadowBlob = opts.shadowBlob })
  local v3 = opts.v3 or makeVoxel3D()
  local voxelState = opts.voxelState
  local lib = opts.lib
  if lib == nil and opts.publicLib ~= false then
    lib = makeLib(sb, v3, voxelState)
  end
  return {
    sb = sb,
    v3 = v3,
    voxelState = voxelState,
    exports = {
      version = opts.version or "1.0.0",
      lib = lib,
      variableSpriteGeometry = opts.native or nil,
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
local BattleArt = V.require("compat/battle_art_variable_geometry")
local Potato = V.require("compat/potato_voxel_variable_geometry")
local Dramaless = V.require("compat/dramaless_variable_geometry")

local function resetAll()
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

local onix = SpeciesGeometry.packGeometry(95, "pokemmo", mod)
local rattata = SpeciesGeometry.packGeometry(19, "pokemmo", mod)
local blastoise = SpeciesGeometry.packGeometry(9, "pokemmo", mod)
eq(onix.frameWidth, 35, "Onix fw")
eq(onix.frameHeight, 38, "Onix fh")
eq(rattata.frameWidth, 25, "Rattata fw")
eq(blastoise.frameWidth, 31, "Blastoise fw")

-- ------------------------------------------------------------------ 3. Potato public module
resetAll()
local potatoPub = makeProvider({
  version = "1.4.0",
  shadowBlob = true,
  voxelState = makeVoxelState(true),
})
installed.potato_voxel = potatoPub
local origBlob = potatoPub.sb.shadowBlob
local okP, whyP = Potato.install(mod)
check(okP, "potato install: " .. tostring(whyP))
eq(Potato.supportReason(), "wrapped_mesh", "potato wrapped_mesh")
check(Potato.supportsVariableGeometry(), "potato supports")

local npc = { image = "trainer.png" }
imageSizes["trainer.png"] = { 16, 96 }
eq(potatoPub.sb.mesh(npc, 0).kind, "original", "potato vanilla original mesh")
eq(origMeshCalls, 1, "potato vanilla one orig call")

local onixDef = {
  image = "assets/generated/true_size/hgss/095-normal.png",
  frames = 6, walker = true,
  frameWidth = onix.frameWidth, frameHeight = onix.frameHeight,
  anchorX = onix.anchorX, anchorY = onix.anchorY,
}
imageSizes[onixDef.image] = { 35, 228 }
local mOnix = potatoPub.sb.mesh(onixDef, 0)
eq(mOnix.kind, "variable", "potato Onix variable")
close(mOnix.verts[2][1] - mOnix.verts[1][1], 35, "potato Onix W")
close(mOnix.verts[3][2] - mOnix.verts[1][2], 38, "potato Onix H")
eq(potatoPub.sb.shadowQuad(onixDef, 0), mOnix, "potato shadowQuad same mesh")
eq(potatoPub.sb.shadowBlob, origBlob, "potato shadowBlob function unchanged")
local blob, blobTex = potatoPub.sb.shadowBlob()
eq(blob.kind, "blob", "potato shadowBlob still blob")
eq(blobTex.kind, "blob_tex", "potato shadowBlob texture unchanged")

local ratDef = {
  image = "rattata.png", frames = 6,
  frameWidth = rattata.frameWidth, frameHeight = rattata.frameHeight,
  anchorX = rattata.anchorX, anchorY = rattata.anchorY,
}
imageSizes["rattata.png"] = { 25, 28 * 6 }
close(potatoPub.sb.mesh(ratDef, 0).verts[2][1] - potatoPub.sb.mesh(ratDef, 0).verts[1][1],
  25, "potato Rattata W")
local blaDef = {
  image = "blastoise.png", frames = 6,
  frameWidth = blastoise.frameWidth, frameHeight = blastoise.frameHeight,
  anchorX = blastoise.anchorX, anchorY = blastoise.anchorY,
}
imageSizes["blastoise.png"] = { 31, 30 * 6 }
close(potatoPub.sb.mesh(blaDef, 0).verts[2][1] - potatoPub.sb.mesh(blaDef, 0).verts[1][1],
  31, "potato Blastoise W")

local canP, canWhyP = VariableSize.canUseTrueSizeInVoxel(mod, { voxelActive = true })
check(canP, "potato canUseTrueSizeInVoxel: " .. tostring(canWhyP))
local effP, whyEffP = VariableSize.effectiveMode(mod, { voxelActive = true })
eq(effP, "true_size", "potato HGSS True Size")
eq(whyEffP, "ok", "potato voxel ok")
local _, potatoId = VariableSize.activeVoxelProvider(mod)
eq(potatoId, "potato_voxel", "active provider potato_voxel")

-- ------------------------------------------------------------------ 4. Potato public module unavailable
resetAll()
installed.potato_voxel = {
  exports = { version = "1.4.0" },
  read = function(_m, rel)
    if rel == "lib/SpriteBillboards.lua" then return FIXED_16_SRC end
  end,
}
local okP2, whyP2 = Potato.install(mod)
check(not okP2, "potato without lib does not install")
check(tostring(whyP2):find("exports.lib.require missing", 1, true),
  "potato missing public accessor")
local effP2, whyP2b = VariableSize.effectiveMode(mod, { voxelActive = true })
eq(effP2, "classic", "potato no public module → Classic")
check(whyP2b:find("voxel_ds_incompatible", 1, true) == 1, "potato unavailable reason")
check(not Potato.supportsVariableGeometry(), "potato unsupported")

-- ------------------------------------------------------------------ 5. Dramaless public module
resetAll()
local dramPub = makeProvider({
  version = "1.6.4",
  shadowBlob = false,
  voxelState = makeVoxelState(true),
})
installed.DRAMALESS_SHAPE = dramPub
local okD, whyD = Dramaless.install(mod)
check(okD, "dramaless install: " .. tostring(whyD))
eq(dramPub.sb.mesh(onixDef, 0).kind, "variable", "dramaless Onix variable")
eq(dramPub.sb.shadowQuad(onixDef, 0).kind, "variable", "dramaless shadowQuad wrapped")
check(dramPub.sb.shadowBlob == nil, "dramaless has no shadowBlob")
local canD = VariableSize.canUseTrueSizeInVoxel(mod, { voxelActive = true })
check(canD, "dramaless canUseTrueSizeInVoxel")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "true_size",
  "dramaless HGSS True Size")

-- ------------------------------------------------------------------ 6. Dramaless unavailable
resetAll()
installed.DRAMALESS_SHAPE = {
  exports = { version = "1.6.4" },
  read = function(_m, rel)
    if rel == "lib/SpriteBillboards.lua" then return FIXED_16_SRC end
  end,
}
check(not Dramaless.install(mod), "dramaless without lib does not install")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "classic",
  "dramaless unavailable → Classic")

-- ------------------------------------------------------------------ 7. Original Dramatic Shape
resetAll()
installed.DRAMATIC_SHAPE = {
  exports = { version = "1.7.9" },
  read = function(_m, rel)
    if rel == "lib/SpriteBillboards.lua" then return FIXED_16_SRC end
  end,
}
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "classic",
  "original DS → Classic")
local dsReport = VariableSize.probeDramaticShape(mod)
eq(dsReport.modId, "DRAMATIC_SHAPE", "original DS id")
eq(dsReport.supportsVariableGeometry, false, "original DS no variable geom")

-- ------------------------------------------------------------------ 8. Multiple installed, Battle Art active
resetAll()
local baActive = makeProvider({
  version = "1.8.3",
  shadowBlob = false,
  voxelState = makeVoxelState(true),
})
local potatoQuiet = makeProvider({
  version = "1.4.0",
  shadowBlob = true,
  voxelState = makeVoxelState(false),
})
installed.BATTLE_ART_VOXEL_FORK = baActive
installed.potato_voxel = potatoQuiet
local found, foundId = VariableSize.findVoxelRenderer(mod)
eq(foundId, "BATTLE_ART_VOXEL_FORK", "multi: active Battle Art wins")
check(BattleArt.install(mod), "multi: Battle Art adapter")
local canBA = VariableSize.canUseTrueSizeInVoxel(mod, { voxelActive = true })
check(canBA, "multi Battle Art active → True Size capability")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "true_size",
  "multi Battle Art active → True Size")

-- ------------------------------------------------------------------ 9. Multiple installed, Potato active unsupported
resetAll()
local baIdle = makeProvider({
  version = "1.8.3",
  shadowBlob = false,
  voxelState = makeVoxelState(false),
})
installed.BATTLE_ART_VOXEL_FORK = baIdle
installed.potato_voxel = {
  exports = { version = "1.4.0", lib = nil },
  read = function(_m, rel)
    if rel == "lib/SpriteBillboards.lua" then return FIXED_16_SRC end
  end,
}
-- Give unsupported Potato a VoxelState so it is uniquely active.
installed.potato_voxel.exports = {
  version = "1.4.0",
  lib = {
    require = function(name)
      if name == "VoxelState" then return makeVoxelState(true) end
      error("no public SpriteBillboards")
    end,
  },
}
check(BattleArt.install(mod), "Battle Art still installs while idle")
check(BattleArt.supportsVariableGeometry(), "Battle Art adapter is installed")
local foundP, foundPid = VariableSize.activeVoxelProvider(mod)
eq(foundPid, "potato_voxel", "multi: Potato is the active provider")
local canBad = VariableSize.canUseTrueSizeInVoxel(mod, { voxelActive = true })
check(not canBad, "multi Potato unsupported must NOT borrow Battle Art capability")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "classic",
  "multi Potato unsupported → Classic")

-- ------------------------------------------------------------------ 10. Provider switch invalidates capability
resetAll()
local baSwitch = makeProvider({
  version = "1.8.3",
  voxelState = makeVoxelState(true),
})
local potatoSwitch = makeProvider({
  version = "1.4.0",
  shadowBlob = true,
  voxelState = makeVoxelState(false),
  publicLib = false,
})
potatoSwitch.exports.lib = {
  require = function(name)
    if name == "VoxelState" then return potatoSwitch.voxelState end
    error("no SpriteBillboards")
  end,
}
installed.BATTLE_ART_VOXEL_FORK = baSwitch
installed.potato_voxel = potatoSwitch
check(VariableSize.canUseTrueSizeInVoxel(mod, { voxelActive = true }),
  "switch start: Battle Art True Size")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "true_size",
  "switch start effective True Size")
VariableSize.resetEffectiveModePoll()
local c0 = VariableSize.pollEffectiveModeChange(mod, { voxelActive = true })
eq(c0, false, "switch first poll")

baSwitch.voxelState = makeVoxelState(false)
baSwitch.exports.lib = makeLib(baSwitch.sb, baSwitch.v3, baSwitch.voxelState)
potatoSwitch.voxelState = makeVoxelState(true)
potatoSwitch.exports.lib.require = function(name)
  if name == "VoxelState" then return potatoSwitch.voxelState end
  error("no SpriteBillboards")
end
-- Do not clearCaches: provider change must drop stale Battle Art capability.
local _, idAfter = VariableSize.activeVoxelProvider(mod)
eq(idAfter, "potato_voxel", "switch now Potato")
check(not VariableSize.canUseTrueSizeInVoxel(mod, { voxelActive = true }),
  "switch: stale Battle Art capability dropped")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "classic",
  "switch Potato unsupported → Classic")
local c1, e1 = VariableSize.pollEffectiveModeChange(mod, { voxelActive = true })
check(c1, "provider switch triggers rebind poll")
eq(e1, "classic", "poll after switch is Classic")

-- ------------------------------------------------------------------ 11. vanilla NPC 16×16 (Dramaless wrap)
resetAll()
local dramNpc = makeProvider({ shadowBlob = false })
installed.DRAMALESS_SHAPE = dramNpc
check(Dramaless.install(mod), "dramaless wrap for NPC")
origMeshCalls = 0
eq(dramNpc.sb.mesh({ image = "npc.png" }, 0).kind, "original", "NPC original")
eq(origMeshCalls, 1, "NPC one orig call")
eq(dramNpc.sb.mesh({
  image = "npc.png", frameWidth = 16, frameHeight = 16, anchorX = 8, anchorY = 16,
}, 1).kind, "original", "explicit 16×16 original")

-- ------------------------------------------------------------------ 12. GSC remains Classic under supported Potato
resetAll()
installed.potato_voxel = makeProvider({ shadowBlob = true })
check(Potato.install(mod), "potato for GSC")
savedOpts.sprite_style = "followers"
VariableSize.clearCaches()
local effG, whyG = VariableSize.effectiveMode(mod, { voxelActive = true })
eq(effG, "classic", "GSC Classic in Potato Voxel")
eq(whyG, "classic_requested", "GSC classic requested")

-- ------------------------------------------------------------------ 13. Flat HGSS remains True Size with unsupported Potato installed
resetAll()
savedOpts.sprite_style = "pokemmo"
installed.potato_voxel = {
  exports = { version = "1.4.0" },
  read = function(_m, rel)
    if rel == "lib/SpriteBillboards.lua" then return FIXED_16_SRC end
  end,
}
local effFlat, whyFlat = VariableSize.effectiveMode(mod, { voxelActive = false })
eq(effFlat, "true_size", "Flat HGSS True Size")
eq(whyFlat, "ok", "flat ok despite unsupported Potato")
local def = {
  image = "assets/generated/followsprites_runtime/095-normal.png",
  frames = 6, walker = true, trueColor = true,
}
local out, info = VariableSize.applyToDef(mod, def, {
  speciesId = 95, style = "pokemmo", variant = "normal", voxelActive = false,
})
check(info.applied, "Flat Onix True Size applied")
eq(out.frameWidth, 35, "Flat Onix fw")

-- Multiple installed, none VoxelState-active, voxel on → Classic (no guess)
resetAll()
installed.BATTLE_ART_VOXEL_FORK = makeProvider({
  voxelState = makeVoxelState(false),
})
installed.potato_voxel = makeProvider({
  shadowBlob = true,
  voxelState = makeVoxelState(false),
})
local _, noneId, noneWhy = VariableSize.activeVoxelProvider(mod)
eq(noneId, nil, "multi none-active: no capability provider")
eq(noneWhy, "multiple_installed_none_active", "multi none-active reason")
eq(VariableSize.effectiveMode(mod, { voxelActive = true }), "classic",
  "multi none-active voxel → Classic")

print("PASS voxel_provider_variable_geometry_unit_test")
