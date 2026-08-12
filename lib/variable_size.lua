-- Variable-size / True Size support for Gen1Recomp SpriteRenderer (#1016 / PR #1020).
--
-- requestedMode  = derived from Sprite Style (GSC→Classic, HGSS→True Size) —
--                   never rewritten when Voxel toggles
-- effectiveMode  = what rendering actually uses (Classic while Voxel + incompatible DS)
--
-- Dramatic Shape / Dramaless without variable geometry → effective Classic.
-- Battle Art Voxel: a small in-memory SpriteBillboards.mesh wrap (see
-- lib/compat/battle_art_variable_geometry.lua) may enable True Size.
-- Visual only; logical footprint stays one cell.
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

VariableSize.VOXEL_RENDERER_IDS = {
  "DRAMATIC_SHAPE",
  "BATTLE_ART_VOXEL_FORK",
}

local function findDramaticShape(mod)
  if not mod or type(mod.find) ~= "function" then return nil, nil end
  for _, id in ipairs(VariableSize.VOXEL_RENDERER_IDS) do
    local hit = mod:find(id)
    if hit then return hit, id end
  end
  return nil, nil
end

--- Shared finder for Dramatic Shape / Battle Art Voxel (not Dramaless).
function VariableSize.findVoxelRenderer(mod)
  return findDramaticShape(mod)
end

local function battleArtAdapter()
  local ok, Adapter = pcall(V.require, "compat/battle_art_variable_geometry")
  if ok then return Adapter end
  return nil
end

local function tryInstallBattleArtAdapter(mod)
  local Adapter = battleArtAdapter()
  if not Adapter or type(Adapter.install) ~= "function" then
    return false
  end
  local ok, installed = pcall(Adapter.install, mod)
  return ok and installed == true
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
  tryInstallBattleArtAdapter(mod)
  local Adapter = battleArtAdapter()
  local adapterOn = Adapter and Adapter.supportsVariableGeometry
    and Adapter.supportsVariableGeometry()
  -- Adapter may install after an earlier "absent" / 16×16 probe; rebuild.
  if adapterOn and _cachedDs and not _cachedDs.supportsVariableGeometry then
    _cachedDs = nil
  end
  if _cachedDs ~= nil then
    if adapterOn then
      _cachedDs.supportsVariableGeometry = true
      _cachedDs.reason = (Adapter.supportReason and Adapter.supportReason()) or "wilds_adapter"
    end
    return _cachedDs
  end
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
  if Adapter and Adapter.supportsVariableGeometry and Adapter.supportsVariableGeometry() then
    report.supportsVariableGeometry = true
    report.reason = (Adapter.supportReason and Adapter.supportReason()) or "wilds_adapter"
    _cachedDs = report
    return report
  end
  if ds.exports and (ds.exports.variableSpriteGeometry == true
      or ds.exports.supportsVariableSizeSprites == true
      or ds.exports.supportsVariableSpriteGeometry == true) then
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
    tryInstallBattleArtAdapter(mod)
    local ds = VariableSize.probeDramaticShape(mod)
    if not ds.supportsVariableGeometry then
      return VariableSize.MODE_CLASSIC, "voxel_ds_incompatible:" .. tostring(ds.reason)
    end
  end
  return VariableSize.MODE_TRUE_SIZE, "ok"
end

--- True when Voxel is active AND the live renderer can consume variable SpriteDefs.
function VariableSize.canUseTrueSizeInVoxel(mod, opts)
  opts = opts or {}
  local voxel = opts.voxelActive
  if voxel == nil then
    voxel = VariableSize.isVoxelActive(mod)
  end
  if not voxel then return false, "voxel_inactive" end
  local ds = VariableSize.probeDramaticShape(mod)
  return ds.supportsVariableGeometry == true, ds.reason
end

function VariableSize.canApplyTrueSize(mod, opts)
  local mode, why = VariableSize.effectiveMode(mod, opts)
  return mode == VariableSize.MODE_TRUE_SIZE, why
end

--- Visual follower trail gap in cells when True Size is effective; else 1.
function VariableSize.visualFollowGap(mod, speciesId, opts)
  if not VariableSize.canApplyTrueSize(mod, opts) then
    return 1
  end
  return SpeciesGeometry.followGap(speciesId, mod)
end

function VariableSize.logVoxelFallback(mod, reason)
  if _loggedFallback then return end
  _loggedFallback = true
  local msg = string.format(
    "[WildsOfKanto][DEV] True Size suspended while Voxel renderer is active (%s). "
      .. "Sprite size follows Sprite Style (HGSS→True Size); Flat restores it automatically.",
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
  if type(pack) ~= "table" then return false end
  local fw = tonumber(pack.frameWidth)
  local fh = tonumber(pack.frameHeight)
  return fw and fw > 0 and fh and fh > 0
end

local function looksLikeTrueSizePath(path)
  return type(path) == "string" and path:find("true_size/", 1, true) ~= nil
end

--- Resolve speciesId to a Gen1 dex number. Wild entities often store
--- entity.species as a name ("ONIX"); packGeometry only accepts 1..151.
local function resolveDex(mod, speciesId, opts)
  local dex = SpeciesGeometry.normalizeDex(speciesId)
  if dex then return dex end
  if speciesId == nil then return nil end
  opts = opts or {}
  local ok, AnimatedSprites = pcall(V.require, "animated_sprites")
  if ok and AnimatedSprites and type(AnimatedSprites.resolveSpeciesId) == "function" then
    local resolved = AnimatedSprites.resolveSpeciesId(speciesId, opts.game, mod)
    dex = SpeciesGeometry.normalizeDex(resolved)
    if dex then return dex end
  end
  return nil
end

--- Preserve already-stamped True Size geometry when rebind cannot resolve a pack.
-- CRITICAL: never clear frameWidth/Height while leaving a true_size/ image —
-- SpriteRenderer.new would then bake 16×16 quads on a tall sheet (Wild crop).
local function preserveExistingTrueSize(def, reason, extra)
  extra = extra or {}
  if geometryValid(def) and looksLikeTrueSizePath(def.image) then
    if def.anchorX == nil then def.anchorX = tonumber(def.frameWidth) / 2 end
    if def.anchorY == nil then def.anchorY = tonumber(def.frameHeight) end
    local info = {
      applied = true,
      reason = reason or "preserve_existing_geometry",
      frameWidth = tonumber(def.frameWidth),
      frameHeight = tonumber(def.frameHeight),
      anchorX = def.anchorX,
      anchorY = def.anchorY,
      requestedMode = VariableSize.MODE_TRUE_SIZE,
      effectiveMode = VariableSize.MODE_TRUE_SIZE,
    }
    for k, v in pairs(extra) do info[k] = v end
    return def, info
  end
  return nil
end

--- Apply True Size geometry when effective; otherwise strip to Classic defaults.
--- Never mutates saved pokemon_size. Never changes collision fields.
--- opts.keepImage: caller already served pre-shaded art (e.g. a wild
--- silhouette sheet derived from the true_size image). Geometry is still
--- applied, but def.image and def.trueColor are left untouched and no
--- luminance ramp is derived. Implies skipLuminance.
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
    -- Classic effective: drop variable geometry. Image may still be swapped
    -- by the caller; consumers must not pass true_size sheets without geometry.
    stripGeometry(def)
    return def, {
      applied = false,
      reason = why,
      requestedMode = VariableSize.requestedMode(mod),
      effectiveMode = effective,
    }
  end

  local speciesId = opts.speciesId or opts.dex
  local dex = resolveDex(mod, speciesId, opts)
  local style = opts.style or (Config.spriteStyle and Config.spriteStyle(mod)) or "followers"
  local packId = opts.packId or VariableSize.packIdForStyle(style, opts.presentation)
  local pack = select(1, SpeciesGeometry.packGeometry(dex or speciesId, packId, mod))
  if not pack or not geometryValid(pack) then
    local keptDef, keptInfo = preserveExistingTrueSize(def, "preserve_existing_geometry", {
      packId = packId,
      dex = dex,
      unresolvedSpeciesId = speciesId,
    })
    if keptDef then
      if DebugLog and DebugLog.debug then
        DebugLog.debug(mod,
          "True Size: preserved existing geometry (unresolved speciesId=%s)",
          tostring(speciesId))
      end
      return keptDef, keptInfo
    end
    stripGeometry(def)
    return def, {
      applied = false,
      reason = "no_geometry",
      unresolvedSpeciesId = speciesId,
      requestedMode = VariableSize.MODE_TRUE_SIZE,
      effectiveMode = VariableSize.MODE_TRUE_SIZE,
    }
  end

  local variant = opts.variant
  local keepImage = opts.keepImage == true
  local rel = nil
  local loadPath = nil
  if not keepImage then
    rel = select(1, SpeciesGeometry.relativePath(dex or speciesId, packId, variant, mod))
    if not rel or not assetPresent(mod, rel) then
      if variant == "shiny" or variant == "s" or variant == true then
        rel = select(1, SpeciesGeometry.relativePath(dex or speciesId, packId, "normal", mod))
      end
    end
    if not rel or not assetPresent(mod, rel) then
      local keptDef, keptInfo = preserveExistingTrueSize(def, "preserve_existing_geometry_asset", {
        packId = packId,
        dex = dex,
      })
      if keptDef then return keptDef, keptInfo end
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
    loadPath = modAssetPath(mod, rel)
    def.image = loadPath
  end
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
  -- Luminance-based shading for the True Size sheets (parity with the
  -- Classic/GSC art path): in every COLORS mode EXCEPT ADVANCED, derive the
  -- 3-shade luminance ramp from the colored true_size sheet at load (cached
  -- in the save dir — no separate -grayscale assets) and serve it with
  -- trueColor = false so the engine's zone pass colors it out of the mode
  -- palette; ADVANCED (redpp) keeps the colored sheet raw (trueColor = true).
  -- Derivation is unavailable headless / without love → colored art stays
  -- raw.  opts.skipLuminance lets callers serving pre-shaded art (silhouette
  -- sheets, water runtime ramps) opt out.
  local lumaServed = false
  if not opts.skipLuminance and not keepImage then
    local redpp = false
    if Config and Config.paletteFxRedpp then
      redpp = Config.paletteFxRedpp() == true
    end
    if not redpp then
      local okLS, LuminanceSheet = pcall(function() return V.require("luminance_sheet") end)
      if okLS and LuminanceSheet and LuminanceSheet.pathFor then
        local luma = LuminanceSheet.pathFor(loadPath)
        if luma then
          def.image = luma
          lumaServed = true
        end
      end
    end
  end
  if lumaServed then
    def.trueColor = false
  elseif opts.skipLuminance or keepImage then
    -- Caller owns the flag (pre-shaded art / silhouette sheets).
  else
    -- Colored true_size sheet served raw (ADVANCED or headless).
    def.trueColor = true
  end

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
