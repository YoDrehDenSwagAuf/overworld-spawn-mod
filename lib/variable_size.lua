-- Variable-size / True Size support for Gen1Recomp SpriteRenderer (#1016 / PR #1020).
--
-- requestedMode  = user option (pokemon_size) — NEVER rewritten when Voxel toggles
-- effectiveMode  = what rendering actually uses (Classic while Voxel + incompatible DS)
--
-- Dramatic Shape without variableSpriteGeometry → effective Classic.
-- No renderer monkey-patches. Visual only; logical footprint stays one cell.
local V = ...
local Config = V.require("config")
local SpeciesGeometry = V.require("species_geometry")
local DebugLog = V.require("debug_log")

local VariableSize = {}

VariableSize.MODE_CLASSIC = "classic"
VariableSize.MODE_TRUE_SIZE = "true_size"

local _loggedFallback = false
local _cachedEngine = nil
local _cachedDs = nil
local _lastEffective = nil

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
  report.hasFrameWidthField = SR.DEFAULT_FRAME_WIDTH == 16
    and SR.DEFAULT_FRAME_HEIGHT == 16
  report.available = report.hasGetFrameGeometry
    and report.hasGetPoseGeometry
    and report.hasGetScreenOrigin
    and report.hasFrameWidthField
  report.defaultsBottomCenter = true
  _cachedEngine = report
  return report
end

function VariableSize.clearCaches()
  _cachedEngine = nil
  _cachedDs = nil
  _loggedFallback = false
  SpeciesGeometry.clearCache()
end

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
      "lib/Mat4.lua (billboard / caster)",
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
  if ds.exports and (ds.exports.variableSpriteGeometry == true
      or ds.exports.supportsVariableSizeSprites == true) then
    report.supportsVariableGeometry = true
    report.reason = "exports_flag"
    _cachedDs = report
    return report
  end
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

--- Effective presentation mode. Never writes pokemon_size.
function VariableSize.effectiveMode(mod, opts)
  opts = opts or {}
  local requested = opts.mode or VariableSize.requestedMode(mod)
  if requested ~= VariableSize.MODE_TRUE_SIZE then
    return VariableSize.MODE_CLASSIC, "classic_requested"
  end
  local engine = VariableSize.probeEngineApi()
  if not engine.available then
    return VariableSize.MODE_CLASSIC, "engine_api_missing"
  end
  local voxel = opts.voxelActive
  if voxel == nil then
    voxel = VariableSize.isVoxelActive(mod)
  end
  if voxel then
    local ds = VariableSize.probeDramaticShape(mod)
    if not ds.supportsVariableGeometry then
      return VariableSize.MODE_CLASSIC, "voxel_ds_incompatible:" .. tostring(ds.reason)
    end
  end
  return VariableSize.MODE_TRUE_SIZE, "ok"
end

function VariableSize.canApplyTrueSize(mod, opts)
  local mode, why = VariableSize.effectiveMode(mod, opts)
  return mode == VariableSize.MODE_TRUE_SIZE, why
end

function VariableSize.logVoxelFallback(mod, reason)
  if _loggedFallback then return end
  _loggedFallback = true
  local msg = string.format(
    "[WildsOfKanto][DEV] True Size suspended while Voxel renderer is active (%s). "
      .. "Saved pokemon_size option is unchanged; Flat restores True Size automatically.",
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

function VariableSize.packIdForStyle(style, presentation)
  if presentation == "swimming" or presentation == "swim" then
    return "swimming"
  end
  if presentation == "levitate" or presentation == "levitates" or presentation == "hover" then
    return "levitate"
  end
  if Config and type(Config.normalizeSpriteStyle) == "function" then
    style = Config.normalizeSpriteStyle(style)
  end
  if style == "pokemmo" then return "pokemmo" end
  if style == "followers" then return "followers" end
  if style == "pokedex" then return "pokedex" end
  return style
end

local function stripGeometry(def)
  def.frameWidth = nil
  def.frameHeight = nil
  def.anchorX = nil
  def.anchorY = nil
  return def
end

local function geometryValid(pack)
  local fw = tonumber(pack.frameWidth)
  local fh = tonumber(pack.frameHeight)
  return fw and fw > 0 and fh and fh > 0
end

--- Apply True Size geometry when effective; otherwise strip to Classic defaults.
--- Never mutates saved pokemon_size. Never changes collision fields.
function VariableSize.applyToDef(mod, def, opts)
  opts = opts or {}
  if type(def) ~= "table" or type(def.image) ~= "string" then
    return def, { applied = false, reason = "bad_def" }
  end

  local effective, why = VariableSize.effectiveMode(mod, opts)
  if effective ~= VariableSize.MODE_TRUE_SIZE then
    if type(why) == "string" and why:find("voxel_ds_incompatible", 1, true) == 1 then
      VariableSize.logVoxelFallback(mod, why)
    end
    stripGeometry(def)
    return def, {
      applied = false,
      reason = why,
      requestedMode = VariableSize.requestedMode(mod),
      effectiveMode = effective,
    }
  end

  local speciesId = opts.speciesId or opts.dex
  local style = opts.style or (Config.spriteStyle and Config.spriteStyle(mod)) or "followers"
  local packId = opts.packId or VariableSize.packIdForStyle(style, opts.presentation)
  local pack, dex = SpeciesGeometry.packGeometry(speciesId, packId, mod)
  if not pack or not geometryValid(pack) then
    stripGeometry(def)
    return def, {
      applied = false,
      reason = "no_geometry",
      requestedMode = VariableSize.MODE_TRUE_SIZE,
      effectiveMode = VariableSize.MODE_TRUE_SIZE,
    }
  end

  local variant = opts.variant
  local rel = select(1, SpeciesGeometry.relativePath(speciesId, packId, variant, mod))
  if not rel or not assetPresent(mod, rel) then
    if variant == "shiny" or variant == "s" or variant == true then
      rel = select(1, SpeciesGeometry.relativePath(speciesId, packId, "normal", mod))
    end
  end
  if not rel or not assetPresent(mod, rel) then
    stripGeometry(def)
    if DebugLog and DebugLog.debug then
      DebugLog.debug(mod, "True Size asset missing for dex=%s pack=%s — Classic fallback",
        tostring(dex), tostring(packId))
    end
    return def, {
      applied = false,
      reason = "true_size_asset_missing",
      packId = packId,
      dex = dex,
      requestedMode = VariableSize.MODE_TRUE_SIZE,
      effectiveMode = VariableSize.MODE_TRUE_SIZE,
    }
  end

  local loadPath = modAssetPath(mod, rel)
  def.image = loadPath
  def.frames = tonumber(pack.frames) or def.frames or 6
  if pack.walker == false then
    def.walker = nil
  else
    def.walker = true
  end
  def.frameWidth = tonumber(pack.frameWidth)
  def.frameHeight = tonumber(pack.frameHeight)
  def.anchorX = tonumber(pack.anchorX)
  if def.anchorX == nil then def.anchorX = def.frameWidth / 2 end
  def.anchorY = tonumber(pack.anchorY)
  if def.anchorY == nil then def.anchorY = def.frameHeight end
  if opts.spriteId then def.id = opts.spriteId end
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
    requestedMode = VariableSize.MODE_TRUE_SIZE,
    effectiveMode = VariableSize.MODE_TRUE_SIZE,
  }
end

--- Preserve geometry fields when copying defs between systems.
function VariableSize.copyGeometryFields(from, to)
  if type(from) ~= "table" or type(to) ~= "table" then return to end
  for _, k in ipairs({ "frameWidth", "frameHeight", "anchorX", "anchorY" }) do
    if from[k] ~= nil then to[k] = from[k] end
  end
  return to
end

--- Detect Flat↔Voxel effective-mode flips; returns true when consumers should rebind.
function VariableSize.pollEffectiveModeChange(mod, opts)
  local effective = VariableSize.effectiveMode(mod, opts)
  local changed = (_lastEffective ~= nil and _lastEffective ~= effective)
  _lastEffective = effective
  return changed, effective
end

function VariableSize.resetEffectiveModePoll()
  _lastEffective = nil
end

function VariableSize.summary(mod)
  local requested = VariableSize.requestedMode(mod)
  local effective, why = VariableSize.effectiveMode(mod)
  return {
    requestedMode = requested,
    effectiveMode = effective,
    reason = why,
    engine = VariableSize.probeEngineApi(),
    dramaticShape = VariableSize.probeDramaticShape(mod),
    voxelActive = VariableSize.isVoxelActive(mod),
    geometry = SpeciesGeometry.summary(mod),
  }
end

return VariableSize
