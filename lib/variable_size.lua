-- Variable-size / True Size support for Gen1Recomp SpriteRenderer (#1016 / PR #1020).
--
-- Uses the ACTUAL engine fields: frameWidth, frameHeight, anchorX, anchorY plus
-- SpriteRenderer:getFrameGeometry / :getPoseGeometry / :getScreenOrigin.
--
-- Dramatic Shape 1.7.9 still builds fixed 16×16 billboards and does NOT call the
-- geometry API. When Voxel is active without DS support, True Size falls back to
-- Classic (16×16) geometry — no renderer monkey-patches.
local V = ...
local Config = V.require("config")
local SpeciesGeometry = V.require("species_geometry")
local DebugLog = V.require("debug_log")

local VariableSize = {}

VariableSize.MODE_CLASSIC = "classic"
VariableSize.MODE_TRUE_SIZE = "true_size"

VariableSize.SPRITE_TEST_CHARIZARD = "SPRITE_TEST_CHARIZARD"

local _loggedFallback = false
local _cachedEngine = nil
local _cachedDs = nil

local DS_FIND_IDS = {
  "DRAMATIC_SHAPE",
  "BATTLE_ART_VOXEL_FORK",
}

local function findDramaticShape(mod)
  if not mod or type(mod.find) ~= "function" then return nil, nil end
  for _, id in ipairs(DS_FIND_IDS) do
    local hit = mod:find(id)
    if hit then return hit, id end
  end
  return nil, nil
end

-- Probe Gen1Recomp SpriteRenderer for the merged #1020 contract.
function VariableSize.probeEngineApi()
  if _cachedEngine ~= nil then return _cachedEngine end
  local report = {
    available = false,
    hasFrameWidthField = false,
    hasGetFrameGeometry = false,
    hasGetPoseGeometry = false,
    hasGetScreenOrigin = false,
    defaultsBottomCenter = true,
    commitNote = "Gen1Recomp PR #1020 (closes #1016), merged 2026-08-10",
  }
  local ok, SR = pcall(require, "src.render.SpriteRenderer")
  if not ok or type(SR) ~= "table" then
    _cachedEngine = report
    return report
  end
  report.hasGetFrameGeometry = type(SR.getFrameGeometry) == "function"
  report.hasGetPoseGeometry = type(SR.getPoseGeometry) == "function"
  report.hasGetScreenOrigin = type(SR.getScreenOrigin) == "function"
  -- Schema / constructor fields: present when DEFAULT_FRAME_* exist and
  -- getFrameGeometry is exported (issue proposal names were kept in the merge).
  report.hasFrameWidthField = SR.DEFAULT_FRAME_WIDTH == 16
    and SR.DEFAULT_FRAME_HEIGHT == 16
  report.available = report.hasGetFrameGeometry
    and report.hasGetPoseGeometry
    and report.hasGetScreenOrigin
    and report.hasFrameWidthField
  report.defaultsBottomCenter = (SR.DEFAULT_ANCHOR_X == 8 and SR.DEFAULT_ANCHOR_Y == 16)
    or true
  _cachedEngine = report
  return report
end

function VariableSize.clearCaches()
  _cachedEngine = nil
  _cachedDs = nil
  _loggedFallback = false
end

-- Does Dramatic Shape's SpriteBillboards consume variable geometry?
-- 1.7.9: NO — buildCard hardcodes 16×16 verts/UVs and never calls getPoseGeometry.
function VariableSize.probeDramaticShape(mod)
  if _cachedDs ~= nil then return _cachedDs end
  local report = {
    present = false,
    modId = nil,
    version = nil,
    supportsVariableGeometry = false,
    reason = "dramatic_shape_absent",
    files = {
      "lib/SpriteBillboards.lua (buildCard)",
      "lib/VoxelScene.lua (drawEntity / frameFor / billboardMatrix)",
      "lib/Mat4.lua (billboard / caster hard-coded ±8 for 16-wide cards)",
    },
  }
  local ds, id = findDramaticShape(mod)
  if not ds then
    _cachedDs = report
    return report
  end
  report.present = true
  report.modId = id
  report.version = ds.exports and ds.exports.version or (ds.manifest and ds.manifest.version)
  -- Future official opt-in marker (not present in 1.7.9).
  if ds.exports and (ds.exports.variableSpriteGeometry == true
      or ds.exports.supportsVariableSizeSprites == true) then
    report.supportsVariableGeometry = true
    report.reason = "exports_flag"
    _cachedDs = report
    return report
  end
  -- Source sniff: if SpriteBillboards still hardcodes "frame * 16" / verts 16, no.
  local src = nil
  if type(ds.read) == "function" then
    local ok, data = pcall(ds.read, ds, "lib/SpriteBillboards.lua")
    if ok and type(data) == "string" then src = data end
  end
  if type(src) == "string" and src ~= "" then
    local usesGeometryApi = src:find("getPoseGeometry", 1, true)
      or src:find("getFrameGeometry", 1, true)
      or src:find("frameWidth", 1, true)
    local fixed16 = src:find("frame %*% 16", 1) or src:find("frame * 16", 1, true)
      or src:find("{ 16, 16, 0", 1, true)
    if usesGeometryApi and not fixed16 then
      report.supportsVariableGeometry = true
      report.reason = "sprite_billboards_geometry_api"
    else
      report.supportsVariableGeometry = false
      report.reason = "sprite_billboards_fixed_16x16"
    end
  else
    -- Conservative: unknown DS without flag → treat as incompatible.
    report.supportsVariableGeometry = false
    report.reason = "unable_to_inspect_sprite_billboards"
  end
  _cachedDs = report
  return report
end

function VariableSize.isVoxelActive(mod)
  local WaterDisplay = V.require("water_display")
  if WaterDisplay and type(WaterDisplay.isVoxelCameraActive) == "function" then
    local ok, active = pcall(WaterDisplay.isVoxelCameraActive, mod)
    if ok then return active == true end
  end
  return false
end

function VariableSize.requestedMode(mod)
  if Config and type(Config.pokemonSizeMode) == "function" then
    return Config.pokemonSizeMode(mod)
  end
  if Config and type(Config.normalizePokemonSize) == "function" then
    local raw = nil
    if Config.peekSavedOption then
      raw = select(1, Config.peekSavedOption(mod, "pokemon_size"))
    end
    if raw == nil and mod and mod.options and mod.options.get then
      raw = mod.options:get("pokemon_size")
    end
    return Config.normalizePokemonSize(raw)
  end
  return VariableSize.MODE_CLASSIC
end

-- True Size may apply only when:
--   * user selected true_size
--   * Gen1Recomp geometry API is present
--   * either Voxel is off, OR Dramatic Shape consumes the geometry contract
function VariableSize.canApplyTrueSize(mod, opts)
  opts = opts or {}
  local mode = opts.mode or VariableSize.requestedMode(mod)
  if mode ~= VariableSize.MODE_TRUE_SIZE then
    return false, "classic_mode"
  end
  local engine = VariableSize.probeEngineApi()
  if not engine.available then
    return false, "engine_api_missing"
  end
  local voxel = opts.voxelActive
  if voxel == nil then
    voxel = VariableSize.isVoxelActive(mod)
  end
  if voxel then
    local ds = VariableSize.probeDramaticShape(mod)
    if not ds.supportsVariableGeometry then
      return false, "voxel_ds_incompatible:" .. tostring(ds.reason)
    end
  end
  return true, "ok"
end

function VariableSize.logVoxelFallback(mod, reason)
  if _loggedFallback then return end
  _loggedFallback = true
  local msg = string.format(
    "[WildsOfKanto][DEV] True Size → Classic fallback (%s). "
      .. "Dramatic Shape 1.7.9 SpriteBillboards.buildCard is fixed 16×16 and "
      .. "does not call SpriteRenderer:getPoseGeometry. No renderer monkey-patch applied.",
    tostring(reason))
  if DebugLog and DebugLog.warn then
    DebugLog.warn(mod, "%s", msg)
  elseif mod and mod.log and mod.log.info then
    mod.log:info("%s", msg)
  end
end

local function modAssetPath(mod, rel)
  if type(rel) ~= "string" or rel == "" then return nil end
  if mod and mod.assets and type(mod.assets.path) == "function" then
    local ok, path = pcall(mod.assets.path, mod.assets, rel)
    if ok and type(path) == "string" and path ~= "" then return path end
  end
  return rel
end

local function assetPresent(mod, rel)
  if type(rel) ~= "string" or rel == "" then return false end
  if mod and type(mod.read) == "function" then
    local ok, data = pcall(mod.read, mod, rel)
    if ok and data ~= nil then return true end
  end
  local f = io.open(rel, "rb")
  if f then f:close(); return true end
  if V.path then
    f = io.open((V.path or ".") .. "/" .. rel, "rb")
    if f then f:close(); return true end
  end
  return false
end

-- Map public sprite_style → species_geometry pack key.
function VariableSize.packIdForStyle(style)
  if Config and type(Config.normalizeSpriteStyle) == "function" then
    style = Config.normalizeSpriteStyle(style)
  end
  if style == "pokemmo" then return "pokemmo" end
  if style == "followers" then return "followers" end
  if style == "pokedex" then return "pokedex" end
  return style
end

-- If True Size is active and a prototype sheet exists for this species/pack,
-- rewrite def.image + geometry fields. Otherwise leave Classic untouched.
-- Never mutates collision / cell fields (those live on the entity, not the def).
function VariableSize.applyToDef(mod, def, opts)
  opts = opts or {}
  if type(def) ~= "table" or type(def.image) ~= "string" then
    return def, { applied = false, reason = "bad_def" }
  end

  local okApply, why = VariableSize.canApplyTrueSize(mod, opts)
  if not okApply then
    if type(why) == "string" and why:find("voxel_ds_incompatible", 1, true) == 1 then
      VariableSize.logVoxelFallback(mod, why)
    end
    -- Strip any leftover geometry so Classic stays 16×16 defaults.
    def.frameWidth = nil
    def.frameHeight = nil
    def.anchorX = nil
    def.anchorY = nil
    return def, { applied = false, reason = why }
  end

  local speciesId = opts.speciesId or opts.dex
  local style = opts.style or Config.spriteStyle(mod)
  local packId = VariableSize.packIdForStyle(style)
  local pack, dex = SpeciesGeometry.packGeometry(speciesId, packId)
  if not pack or not pack.prototype then
    return def, { applied = false, reason = "no_prototype_for_species_pack" }
  end

  local variant = opts.variant
  local rel, pack2 = SpeciesGeometry.prototypeRelativePath(speciesId, packId, variant)
  pack = pack2 or pack
  if not rel or not assetPresent(mod, rel) then
    -- Shiny missing → try normal.
    if variant == "shiny" or variant == "s" or variant == true then
      rel = select(1, SpeciesGeometry.prototypeRelativePath(speciesId, packId, "normal"))
    end
  end
  if not rel or not assetPresent(mod, rel) then
    return def, { applied = false, reason = "prototype_asset_missing" }
  end

  local loadPath = modAssetPath(mod, rel)
  def.image = loadPath
  def.frames = tonumber(pack.frames) or def.frames or 6
  if pack.walker ~= false then def.walker = true end
  def.frameWidth = tonumber(pack.frameWidth) or 32
  def.frameHeight = tonumber(pack.frameHeight) or 32
  def.anchorX = tonumber(pack.anchorX)
  if def.anchorX == nil then def.anchorX = def.frameWidth / 2 end
  def.anchorY = tonumber(pack.anchorY)
  if def.anchorY == nil then def.anchorY = def.frameHeight end
  def.id = opts.spriteId or VariableSize.SPRITE_TEST_CHARIZARD
  def.trueColor = def.trueColor ~= false

  return def, {
    applied = true,
    reason = "ok",
    dex = dex,
    packId = packId,
    relativePath = rel,
    loadPath = loadPath,
    frameWidth = def.frameWidth,
    frameHeight = def.frameHeight,
    anchorX = def.anchorX,
    anchorY = def.anchorY,
    logicalFootprint = "16x16_cell",
  }
end

function VariableSize.summary(mod)
  local engine = VariableSize.probeEngineApi()
  local ds = VariableSize.probeDramaticShape(mod)
  local mode = VariableSize.requestedMode(mod)
  local can, why = VariableSize.canApplyTrueSize(mod)
  return {
    mode = mode,
    canApply = can,
    reason = why,
    engine = engine,
    dramaticShape = ds,
    voxelActive = VariableSize.isVoxelActive(mod),
    prototypeSpecies = { 6 },
  }
end

return VariableSize
