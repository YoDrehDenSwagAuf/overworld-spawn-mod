-- Presentational half of overworld_wild_spawns.
-- Base Gen1Recomp path: SpriteRenderer + pose()/draw() on OverworldState.entities.
-- DramaticShapeVoxelMod is optional: when VOXEL is active it billboards via pose().
--
-- Wild Pokemon use the same native SpriteRenderer contract as trainers/NPCs:
--   static 16×96 sheet, frames=6, walker=true, pose() → facing/phase/flip.
-- EnhancedWorldSprite dynamic cards are deprecated for the body path.
--
-- Lifecycle (non-negotiable):
--   LOAD:  registerContent() writes mod.content.sprites once, builds lookup
--   RUNTIME: spriteIdFor / makeEntity / preview only look up + resolve images
--
-- Gen1Recomp freezes content registries after all mods load. Never call
-- register/override/patch/remove from testSpawn, preview, map callbacks, etc.
--
-- Asset identity is the species id (e.g. "PIDGEY"). Display names are never
-- used as the sole filename. Optional save-dir cache is never required.
local V = ...
local Config = V.require("config")
local DebugLog = V.require("debug_log")
local SpriteScale = V.require("sprite_scale")
local Behavior = V.require("behavior")
local Surface = V.require("surface")
local Tile = V.require("tile")
local Movement = V.require("movement")
local AnimatedSprites = V.require("animated_sprites")
local RuntimeSheets = V.require("runtime_sheets")
local GrassOcclusion = V.require("grass_occlusion")
local EnhancedWorldSprite = V.require("enhanced_world_sprite") -- deprecated body path
local RenderDiagnostics = V.require("render_diagnostics")
local SpriteProviders = V.require("sprite_providers")
local WaterSpriteRegistry = V.require("water_sprite_registry")
local SpriteResolver = V.require("sprite_resolver")

local SpawnRender = {}
SpawnRender.__index = SpawnRender

-- Gen1Recomp walk-grid cell size (see lib/tile.lua / NPC.lua).
local CELL = Tile.CELL
local PLACEHOLDER_ID = "SPRITE_OW_WILD_PLACEHOLDER"
local FALLBACK_ID = "SPRITE_OW_WILD_FALLBACK"
local CACHE_DIR = "overworld_wild_spawns-cache"
local FALLBACK_REL = "assets/fallback/pokemon_missing.png"
local PLACEHOLDER_REL = "assets/spawn_placeholder.png"
local BILLBOARD_BASE_REL = EnhancedWorldSprite.BASE_ASSET_REL
local RUNTIME_SHEET_DIR = RuntimeSheets.DIR_REL

-- Render status taxonomy (voxel world billboard path).
SpawnRender.RENDERER = {
  NATIVE_SPRITE_RENDERER = "NATIVE_SPRITE_RENDERER",
  WORLD_BILLBOARD_ENHANCED = "WORLD_BILLBOARD_ENHANCED", -- deprecated body path
  WORLD_BILLBOARD_LEGACY = "WORLD_BILLBOARD_LEGACY",
  WORLD_BILLBOARD_BLACK_FALLBACK = "WORLD_BILLBOARD_BLACK_FALLBACK",
  TEMPORARILY_UNAVAILABLE = "TEMPORARILY_UNAVAILABLE",
  SPATIAL_OVERLAY_EMERGENCY = "SPATIAL_OVERLAY_EMERGENCY",
  -- Alias kept for older call sites / tests.
  SPATIAL_OVERLAY_FALLBACK = "SPATIAL_OVERLAY_EMERGENCY",
  HIDDEN = "HIDDEN",
  WILDS_2D = "WILDS_2D",
}

-- Optional explicit speciesId -> mod-relative asset path (under the mod root).
-- Species id is the primary key; keep this table sparse and deterministic.
local speciesAssetPaths = {
  -- Example: PIDGEY = "assets/pokemon/016.png",
}

local function tryRequire(name)
  local ok, modOrErr = pcall(require, name)
  if ok then return modOrErr, nil end
  return nil, modOrErr
end

local function spriteIdForSpecies(species)
  return "SPRITE_OW_WILD_" .. tostring(species)
end

local function fsExists(path)
  if type(path) ~= "string" or path == "" then return false end
  local fs = love and love.filesystem
  if fs and fs.getInfo then
    local ok, info = pcall(fs.getInfo, path)
    if ok and info then return true end
  end
  return false
end

local function isOsAbsolutePath(path)
  if type(path) ~= "string" then return false end
  if path:match("^%a:[/\\]") then return true end -- Windows drive
  if path:sub(1, 1) == "/" and not path:match("^mods/")
     and not path:match("^assets/")
     and not path:match("^save/")
     and not path:match("^" .. CACHE_DIR) then
    -- Absolute POSIX path that is not a known LÖVE virtual root.
    return true
  end
  return false
end

local function sanitizeNameToken(name)
  if type(name) ~= "string" then return nil end
  local s = name:lower()
  -- Strip gender marks / punctuation used in display names (Mr. Mime, Farfetch'd…)
  s = s:gsub("♀", "f"):gsub("♂", "m")
  s = s:gsub("[^%w]+", "")
  if s == "" then return nil end
  return s
end

local function dexPadded(dex)
  local n = tonumber(dex)
  if not n or n < 0 then return nil end
  return string.format("%03d", math.floor(n))
end

-- Runtime-only bake: writes a 16x16 sheet into the LÖVE save cache.
-- Returns a LÖVE-virtual relative path (never an OS absolute path).
local function bakeSheet(species, sourcePath, log)
  if not (love and love.graphics and love.image) then return nil end
  if type(sourcePath) ~= "string" or sourcePath == "" then return nil end
  if isOsAbsolutePath(sourcePath) then
    if log then log("bake refused OS absolute source: %s", sourcePath) end
    return nil
  end

  local Assets, assetsErr = tryRequire("src.render.Assets")
  if not Assets then
    if log then log("Assets unavailable for bake: %s", tostring(assetsErr)) end
    return nil
  end

  local ok, src = pcall(Assets.image, sourcePath)
  if not ok or not src then
    if log then log("bake source missing for %s: %s", tostring(species), tostring(src)) end
    return nil
  end

  local sw, sh = src:getDimensions()
  if sw < 1 or sh < 1 then return nil end

  local canvasOk, canvas = pcall(love.graphics.newCanvas, CELL, CELL)
  if not canvasOk or not canvas then return nil end

  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(src, 0, 0, 0, CELL / sw, CELL / sh)
  love.graphics.setCanvas()

  local idata = canvas:newImageData()
  canvas:release()

  if not (love.filesystem and idata.encode and love.filesystem.write) then
    return nil
  end

  local dirOk, dirErr = pcall(love.filesystem.createDirectory, CACHE_DIR)
  if not dirOk and log then
    log("cache dir create failed: %s", tostring(dirErr))
  end

  local rel = CACHE_DIR .. "/" .. tostring(species):lower() .. ".png"
  local fileData = idata:encode("png")
  if not fileData then return nil end

  local writeOk, writeErr = love.filesystem.write(rel, fileData:getString())
  if not writeOk then
    if log then log("cache write failed for %s: %s", tostring(species), tostring(writeErr)) end
    return nil
  end

  -- Verify via the same API SpriteRenderer / Assets.image will use.
  if not fsExists(rel) then
    if log then log("cache write ok but getInfo missing for %s", rel) end
    return nil
  end

  -- CRITICAL: return the LÖVE virtual relative path only.
  -- Never prefix with love.filesystem.getSaveDirectory(); Assets.image and
  -- love.graphics.newImage reject OS absolute paths.
  return rel
end

local function probeImageLoad(path)
  if type(path) ~= "string" or path == "" then
    return false, "empty path", nil, nil
  end
  if isOsAbsolutePath(path) then
    return false, "OS absolute path rejected (use love.filesystem virtual path): " .. path, nil, nil
  end

  local fs = love and love.filesystem
  local infoKnownMissing = false
  if fs and fs.getInfo then
    local okInfo, info = pcall(fs.getInfo, path)
    if okInfo and info == nil then
      infoKnownMissing = true
    end
  end

  if not (love and love.graphics and love.graphics.newImage) then
    if infoKnownMissing then
      return false, path .. ": Does not exist.", nil, nil
    end
    return true, nil, nil, nil
  end

  -- Always attempt newImage for non-absolute paths. Real LÖVE fails on
  -- missing files; headless stubs may still construct a stand-in Image.
  -- When getInfo already reported missing, treat as not loaded so status
  -- reporting / search order can fall through to the next candidate.
  if infoKnownMissing then
    return false, path .. ": Does not exist.", nil, nil
  end

  local ok, imageOrErr = pcall(love.graphics.newImage, path)
  if not ok or not imageOrErr then
    return false, tostring(imageOrErr), nil, nil
  end
  if imageOrErr.setFilter then
    imageOrErr:setFilter("nearest", "nearest")
  end
  local w, h = imageOrErr:getDimensions()
  return true, nil, w, h
end

function SpawnRender.new(mod)
  local self = setmetatable({}, SpawnRender)
  self.mod = mod
  -- Immutable after registerContent(): species id -> registered sprite id.
  self.speciesSpriteIds = {}
  -- Per-species status recorded at registration time (kind / source path).
  self.registrationInfo = {}
  -- Runtime image cache only (paths / bake results). Never a content registry.
  self.runtimeImageCache = {}
  self.assetInfo = {}
  -- Deterministic resolution cache: speciesId -> { source, path, status, ... }
  self.resolvedAssetBySpeciesId = {}
  self.placeholderId = nil
  self.fallbackId = nil
  self.fallbackPath = nil
  self.rendererMode = "base"
  self.lastError = nil
  self.contentRegistrationOpen = true
  self.registeredCount = 0
  self.missingCount = 0
  self.realAssetsFound = 0
  self.realAssetsMissing = 0
  self.fallbackAvailable = false
  self.debugMarkers = false
  self.animated = AnimatedSprites.new(mod)
  self.runtimeSheets = RuntimeSheets.new(mod)
  self.spriteProviders = SpriteProviders.new(mod, self)
  self.waterSpriteRegistry = WaterSpriteRegistry.new(mod)
  self.spriteResolver = SpriteResolver.new(mod, self.spriteProviders, self.waterSpriteRegistry)
  self._providerMakeWrapped = false
  self._pendingSpriteRefresh = false
  return self
end

function SpawnRender:_log(fmt, ...)
  if Config.debug(self.mod) then
    self.mod.log:info("[owwild/render] " .. fmt, ...)
  end
end

function SpawnRender:_notice(fmt, ...)
  local msg = fmt
  if select("#", ...) > 0 then
    msg = string.format(fmt, ...)
  end
  self.mod.log:info("[WildsOfKanto][INFO] %s", msg)
end

function SpawnRender:_warn(fmt, ...)
  local msg = fmt
  if select("#", ...) > 0 then
    msg = string.format(fmt, ...)
  end
  self.mod.log:info("[WildsOfKanto][WARN] %s", msg)
end

function SpawnRender:_modAssetPath(rel)
  -- Always address files under the mod root via the public assets helper.
  if type(rel) ~= "string" or rel == "" then return nil end
  if rel:sub(1, 1) == "/" then return nil end
  return self.mod.assets:path(rel)
end

function SpawnRender:_fallbackPath()
  return self:_modAssetPath(FALLBACK_REL)
end

function SpawnRender:_billboardBasePath()
  return self:_modAssetPath(BILLBOARD_BASE_REL)
end

function SpawnRender:_placeholderPath()
  return self:_modAssetPath(PLACEHOLDER_REL)
end

function SpawnRender:_registerSprite(id, def)
  if not self.contentRegistrationOpen then
    return nil, "Attempted content registration after mod initialization"
  end
  if not self.mod.content or not self.mod.content.sprites then
    return nil, "sprites content registry unavailable"
  end
  if self.mod.content.sprites:get(id) then
    return id
  end
  self.mod.content.sprites:register(id, def)
  return id
end

-- Build ordered candidate list for a species. Does not load images.
function SpawnRender:assetCandidates(speciesId, game, mon)
  mon = mon or (game and game.data and game.data.pokemon and game.data.pokemon[speciesId])
  if not mon and self.mod.content and self.mod.content.pokemon then
    mon = self.mod.content.pokemon:get(speciesId)
  end
  local reg = self.registrationInfo[speciesId]
  local candidates = {}
  local function push(path, source)
    if type(path) ~= "string" or path == "" then return end
    if isOsAbsolutePath(path) then return end
    candidates[#candidates + 1] = { path = path, source = source }
  end

  local explicit = speciesAssetPaths[speciesId]
  if explicit then
    push(self:_modAssetPath(explicit), "explicit_map")
  end

  local padded = mon and dexPadded(mon.dex)
  if padded then
    push(self:_modAssetPath("assets/pokemon/" .. padded .. ".png"), "dex_padded")
    push(self:_modAssetPath("assets/pokemon/species_" .. padded .. ".png"), "species_dex")
  end

  local idLower = tostring(speciesId):lower()
  push(self:_modAssetPath("assets/pokemon/" .. idLower .. ".png"), "species_id")

  local nameToken = sanitizeNameToken(mon and mon.name)
  if nameToken and nameToken ~= idLower then
    push(self:_modAssetPath("assets/pokemon/" .. nameToken .. ".png"), "display_name")
  end

  local front = (mon and mon.spriteFront)
             or (reg and reg.source)
  if type(front) == "string" and front ~= "" then
    push(front, "battle_front")
  end
  if mon and type(mon.spriteBack) == "string" and mon.spriteBack ~= "" then
    push(mon.spriteBack, "battle_back")
  end
  if mon and type(mon.icon) == "string" and mon.icon ~= "" then
    push(mon.icon, "menu_icon")
  elseif mon and type(mon.icon) == "table" and type(mon.icon.image) == "string" then
    push(mon.icon.image, "menu_icon")
  end

  -- Optional cache — never required; listed last among real sources.
  push(CACHE_DIR .. "/" .. idLower .. ".png", "runtime_cache")

  return candidates, mon
end

-- Resolve once and cache. Never mutates content registries.
function SpawnRender:resolveAsset(speciesId, game, opts)
  opts = opts or {}
  if not opts.force and self.resolvedAssetBySpeciesId[speciesId] then
    return self.resolvedAssetBySpeciesId[speciesId]
  end

  local candidates, mon = self:assetCandidates(speciesId, game)
  local tried = {}
  local result = {
    speciesId = speciesId,
    speciesName = mon and mon.name or tostring(speciesId),
    dex = mon and mon.dex or nil,
    source = nil,
    path = nil,
    status = "REAL_ASSET_MISSING",
    kind = nil,
    realAssetPath = nil,
    realAssetExists = false,
    realAssetLoaded = false,
    fallbackUsed = false,
    fallbackAvailable = self.fallbackAvailable == true,
    loadError = nil,
    tried = tried,
    width = nil,
    height = nil,
  }

  for _, cand in ipairs(candidates) do
    local exists = fsExists(cand.path)
    local entry = {
      path = cand.path,
      source = cand.source,
      exists = exists,
      loaded = false,
      error = nil,
    }
    tried[#tried + 1] = entry

    local loaded, err, w, h = probeImageLoad(cand.path)
    if loaded then
      entry.loaded = true
      entry.exists = true
      result.path = cand.path
      result.source = cand.source
      result.realAssetPath = cand.path
      result.realAssetExists = true
      result.realAssetLoaded = true
      result.width = w
      result.height = h
      result.loadError = nil

      -- Optionally bake battle art down to a 16x16 overworld sheet.
      if cand.source == "battle_front" or cand.source == "battle_back" then
        local baked = bakeSheet(speciesId, cand.path, function(fmt, ...)
          self:_log(fmt, ...)
        end)
        if baked then
          result.path = baked
          result.source = "generated_overworld"
          result.kind = "generated_overworld"
          result.status = "LOADED"
          tried[#tried + 1] = {
            path = baked, source = "generated_overworld",
            exists = true, loaded = true,
          }
        else
          result.kind = cand.source
          result.status = "LOADED"
        end
      elseif cand.source == "runtime_cache" then
        result.kind = "generated_overworld"
        result.status = "LOADED"
      else
        result.kind = cand.source
        result.status = "LOADED"
      end
      self.resolvedAssetBySpeciesId[speciesId] = result
      return result
    end

    entry.error = err or "load failed"
    result.loadError = entry.error
    self:_log("asset load failed species=%s path=%s err=%s",
              tostring(speciesId), tostring(cand.path), tostring(entry.error))
  end

  -- Fallback — never blocks spawn. The path is pre-registered at load time;
  -- even if getInfo cannot see the ZIP entry in a stub, entity creation can
  -- still use the registered FALLBACK sprite id.
  local fb = self.fallbackPath or self:_fallbackPath()
  if fb then
    local loaded, err, w, h = probeImageLoad(fb)
    result.fallbackAvailable = true
    result.path = fb
    result.source = "fallback"
    result.kind = "fallback"
    result.status = "FALLBACK_LOADED"
    result.fallbackUsed = true
    result.width = w or CELL
    result.height = h or CELL
    if not loaded and err then
      result.loadError = result.loadError or err
    end
    tried[#tried + 1] = {
      path = fb, source = "fallback",
      exists = loaded == true or fsExists(fb),
      loaded = loaded == true,
      error = err,
    }
  else
    result.status = "REAL_ASSET_MISSING"
    result.fallbackAvailable = false
  end

  self.resolvedAssetBySpeciesId[speciesId] = result
  return result
end

function SpawnRender:invalidateAssetCache(speciesId)
  if speciesId then
    self.resolvedAssetBySpeciesId[speciesId] = nil
    self.runtimeImageCache[speciesId] = nil
    self.assetInfo[speciesId] = nil
  else
    self.resolvedAssetBySpeciesId = {}
    self.runtimeImageCache = {}
    self.assetInfo = {}
  end
end

-- LOAD PHASE only. Must finish before Gen1Recomp freezes content registries.
function SpawnRender:registerContent()
  if not self.contentRegistrationOpen then
    return nil, "Attempted content registration after mod initialization"
  end

  self:_notice("Registering overworld sprite definitions")

  local placeholderPath = self:_placeholderPath()
  local okPlace, placeErr = self:_registerSprite(PLACEHOLDER_ID, {
    image = placeholderPath,
    frames = 1,
    trueColor = true,
  })
  if not okPlace then
    self.contentRegistrationOpen = false
    return nil, placeErr
  end
  self.placeholderId = PLACEHOLDER_ID

  local fallbackPath = self:_fallbackPath()
  local okFall, fallErr = self:_registerSprite(FALLBACK_ID, {
    image = fallbackPath,
    frames = 1,
    trueColor = true,
  })
  if not okFall then
    self.contentRegistrationOpen = false
    return nil, fallErr or "fallback sprite registration failed"
  end
  self.fallbackId = FALLBACK_ID
  self.fallbackPath = fallbackPath
  self.fallbackAvailable = true

  local registered, missing = 0, 0
  local pokemon = self.mod.content and self.mod.content.pokemon

  -- Build-time native sheets (preferred over battle-front bake).
  local okSheets, sheetsErr = pcall(function()
    return self.runtimeSheets:load()
  end)
  if not okSheets then
    DebugLog.warn(self.mod, "runtime sheet load failed: %s", tostring(sheetsErr))
  else
    local rs = self.runtimeSheets:summary()
    self:_notice("Runtime sheets load: ready=%s sheetCount=%s err=%s",
      tostring(rs.ready), tostring(rs.sheetCount), tostring(rs.loadError or "none"))
  end

  -- Prove path resolution for representative dex ids (developer log).
  local probeDex = { 1, 25, 151 }
  for _, dex in ipairs(probeDex) do
    local probe = self.runtimeSheets:probeRegistration(dex, "normal")
    self:_notice(
      "RuntimeSheet probe dex=%s key=%s rel=%s load=%s manifest=%s assets=%s dims=%sx%s getInfo(rel)=%s err=%s",
      tostring(probe.speciesId),
      tostring(probe.manifestKey),
      tostring(probe.relativePath),
      tostring(probe.loadPath),
      tostring(probe.manifestEntryFound),
      tostring(probe.assetsImageOk),
      tostring(probe.imageWidth),
      tostring(probe.imageHeight),
      tostring(probe.loveGetInfoRelative),
      tostring(probe.assetsImageError))
  end

  if pokemon and pokemon.each then
    for speciesId, def in pokemon:each() do
      local spriteId = spriteIdForSpecies(speciesId)
      local front = def and def.spriteFront
      local imagePath = fallbackPath
      local kind = "fallback"
      local source = nil
      local frames = 1
      local walker = nil
      local relativePath = nil
      local fallbackReason = nil

      local dexId = nil
      if def and def.dex ~= nil then
        dexId = tonumber(def.dex)
      end
      if not dexId then
        dexId = AnimatedSprites.resolveSpeciesId(speciesId, nil, self.mod)
      end

      local runtimeLoadPath, usedVariant, runtimeRel, runtimeEntry = nil, nil, nil, nil
      if dexId and self.runtimeSheets and self.runtimeSheets:isReady() then
        runtimeLoadPath, usedVariant, runtimeRel, runtimeEntry =
          self.runtimeSheets:resolveAssetPath(dexId, "normal")
        -- Always go through mod.assets:path for registration.
        if runtimeRel then
          local viaAssets = self:_modAssetPath(runtimeRel)
          if viaAssets then
            runtimeLoadPath = viaAssets
          end
        end
      elseif dexId and self.runtimeSheets and not self.runtimeSheets:isReady() then
        fallbackReason = "runtimeSheets not ready: " .. tostring(self.runtimeSheets.loadError)
      elseif not dexId then
        fallbackReason = "dexId unresolved for species key " .. tostring(speciesId)
      end

      if runtimeLoadPath and runtimeRel then
        imagePath = runtimeLoadPath
        source = runtimeLoadPath
        relativePath = runtimeRel
        kind = "native_runtime_sheet"
        frames = RuntimeSheets.FRAMES
        walker = true
        fallbackReason = nil
      elseif type(front) == "string" and front ~= "" and not isOsAbsolutePath(front) then
        source = front
        imagePath = front
        kind = "battle_front"
        fallbackReason = fallbackReason
          or "no runtime sheet; using battle front"
        local baked = bakeSheet(speciesId, front, function(fmt, ...)
          self:_log(fmt, ...)
        end)
        if baked then
          imagePath = baked
          kind = "generated_overworld"
        end
      else
        missing = missing + 1
        fallbackReason = fallbackReason
          or "no runtime sheet and no battle front"
      end

      local spriteDef = {
        image = imagePath,
        frames = frames,
        trueColor = true,
      }
      if walker then
        spriteDef.walker = true
      end
      local ok, err = self:_registerSprite(spriteId, spriteDef)
      if ok then
        self.speciesSpriteIds[speciesId] = spriteId
        self.registrationInfo[speciesId] = {
          spriteId = spriteId,
          image = imagePath,
          relativePath = relativePath,
          source = source,
          kind = kind,
          frames = frames,
          walker = walker == true,
          dexId = dexId,
          usedVariant = usedVariant or "normal",
          fallbackReason = fallbackReason,
          status = (kind == "fallback") and "FALLBACK_REGISTERED" or "REGISTERED",
        }
        registered = registered + 1
        -- Extra detail for the probe species.
        if dexId == 1 or dexId == 25 or dexId == 151 then
          self:_notice(
            "REGISTER species=%s dex=%s kind=%s frames=%s walker=%s rel=%s image=%s reason=%s",
            tostring(speciesId), tostring(dexId), tostring(kind),
            tostring(frames), tostring(walker == true),
            tostring(relativePath), tostring(imagePath),
            tostring(fallbackReason or "ok"))
        end
      else
        missing = missing + 1
        self.registrationInfo[speciesId] = {
          spriteId = nil,
          status = "REGISTER_ERROR",
          lastError = tostring(err),
          dexId = dexId,
          fallbackReason = tostring(err),
        }
        DebugLog.warn(self.mod,
          "failed to register overworld sprite for %s: %s",
          tostring(speciesId), tostring(err))
      end
    end
  end

  self.registeredCount = registered
  self.missingCount = missing
  self.contentRegistrationOpen = false

  -- Follow-sprite mapping: load-once, no registry writes.
  local okAnim, animErr = pcall(function()
    self.animated:load()
  end)
  if not okAnim then
    DebugLog.warn(self.mod, "follow sprite load failed: %s", tostring(animErr))
  end

  local okWater, waterErr = pcall(function()
    return self.waterSpriteRegistry:load()
  end)
  if not okWater then
    DebugLog.warn(self.mod, "water sprite registry failed: %s", tostring(waterErr))
  elseif self.waterSpriteRegistry:isReady() then
    local ws = self.waterSpriteRegistry:summary()
    local st = ws.stats or {}
    self:_notice(
      "Water sprites: READY (swim=%s lev=%s unique=%s)",
      tostring(st.swimmingMapped or 0),
      tostring(st.levitatesMapped or 0),
      tostring(st.uniqueSpecies or 0))
  else
    self:_warn("Water sprites: UNAVAILABLE (%s)",
      tostring(self.waterSpriteRegistry.loadError or waterErr or "?"))
  end

  self:_notice("Registered sprites: %d", registered)
  self:_notice("Missing real sprite sources at register: %d", missing)
  self:_notice("Fallback available: yes")
  if self.runtimeSheets and self.runtimeSheets:isReady() then
    local rs = self.runtimeSheets:summary()
    self:_notice("Native runtime sheets: READY (%d entries)", rs.sheetCount or 0)
    self:_notice("Native sheet dir: %s", tostring(rs.dir))
  else
    self:_warn("Native runtime sheets: UNAVAILABLE (legacy/fallback still work)")
  end
  if self.animated and self.animated:isReady() then
    local s = self.animated:summary()
    self:_notice("Follow sprites: READY (%d mapped species)", s.mappedSpeciesCount or 0)
    self:_notice("Follow mappings valid/partial/invalid: %d/%d/%d",
                 s.validSpeciesCount, s.partialSpeciesCount, s.invalidSpeciesCount)
    self:_notice("Runtime shiny support: %s", tostring(s.runtimeShinySupport))
    -- Preview browser can list mapped species above Gen1.
    local previewRows = {}
    for id, entry in pairs(self.animated.mappingsBySpeciesId or {}) do
      if type(id) == "number" and entry and entry.valid then
        previewRows[#previewRows + 1] = {
          id = tostring(id),
          name = ("SPECIES_%03d"):format(id),
          dex = id,
        }
      end
    end
    self.mod._owwildFollowPreviewRows = previewRows
  else
    self:_warn("Follow sprites: UNAVAILABLE (legacy/fallback sprites still work)")
    self.mod._owwildFollowPreviewRows = nil
  end
  self:_notice("Content registration complete")
  return true
end

function SpawnRender:isContentRegistrationOpen()
  return self.contentRegistrationOpen == true
end

-- Dev-mode asset audit. Logs a summary; does not flood the HUD.
function SpawnRender:auditAssets(game)
  local found, missing = 0, 0
  local pokemon = (game and game.data and game.data.pokemon) or {}
  local ids = {}
  for id in pairs(pokemon) do ids[#ids + 1] = id end
  if self.mod.content and self.mod.content.pokemon and self.mod.content.pokemon.each then
    for id in self.mod.content.pokemon:each() do
      if not pokemon[id] then ids[#ids + 1] = id end
    end
  end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)

  for _, speciesId in ipairs(ids) do
    self:invalidateAssetCache(speciesId)
    local resolved = self:resolveAsset(speciesId, game)
    if resolved.realAssetLoaded then
      found = found + 1
    else
      missing = missing + 1
    end
    if Config.debug(self.mod) then
      self:_log(
        "audit species=%s name=%s path=%s exists=%s load=%s fallback=%s",
        tostring(speciesId),
        tostring(resolved.speciesName),
        tostring(resolved.realAssetPath or resolved.path),
        tostring(resolved.realAssetExists),
        tostring(resolved.realAssetLoaded),
        tostring(resolved.fallbackUsed))
    end
  end

  self.realAssetsFound = found
  self.realAssetsMissing = missing
  self:_notice("Real Pokemon assets found: %d", found)
  if missing > 0 then
    self:_warn("Real Pokemon assets missing: %d", missing)
  else
    self:_notice("Real Pokemon assets missing: 0")
  end
  self:_notice("Fallback available: %s", self.fallbackAvailable and "yes" or "no")
  return found, missing
end

-- Probe that the base Gen1Recomp SpriteRenderer path is usable. Does not
-- require DramaticShapeVoxelMod. Never registers content.
function SpawnRender:checkAvailable(game)
  self.lastError = nil
  local SpriteRenderer, err = tryRequire("src.render.SpriteRenderer")
  if not SpriteRenderer then
    self.rendererMode = "unavailable"
    self.lastError = "SpriteRenderer unavailable: " .. tostring(err)
    return false, self.lastError
  end
  if type(SpriteRenderer.new) ~= "function" then
    self.rendererMode = "unavailable"
    self.lastError = "SpriteRenderer.new missing"
    return false, self.lastError
  end
  local placeholder = self.placeholderId or PLACEHOLDER_ID
  local spriteDef = game and game.data and game.data.sprites and game.data.sprites[placeholder]
  if not spriteDef then
    spriteDef = self.mod.content.sprites:get(placeholder)
  end
  if not spriteDef then
    self.rendererMode = "unavailable"
    self.lastError = "placeholder sprite missing"
    return false, self.lastError
  end
  local fallback = self.fallbackId or FALLBACK_ID
  local fbDef = game and game.data and game.data.sprites and game.data.sprites[fallback]
  if not fbDef then
    fbDef = self.mod.content.sprites:get(fallback)
  end
  if not fbDef then
    self.rendererMode = "unavailable"
    self.lastError = "fallback sprite missing"
    return false, self.lastError
  end
  self.rendererMode = "base"
  local dramatic = self.mod.find and self.mod.find("DRAMATIC_SHAPE")
  if dramatic then
    self:_log("DRAMATIC_SHAPE present; wild Pokemon use WORLD_BILLBOARD depth path")
  else
    self:_log("base Gen1Recomp 2D renderer path active")
  end
  return true, self.rendererMode
end

function SpawnRender:isEntityRegistered(ow, entity)
  if not ow or not ow.entities or not entity then return false end
  for _, e in ipairs(ow.entities) do
    if e == entity then return true end
  end
  return false
end

-- Pure lookup. No registry mutation, no bake, no world changes.
-- Falls back to the shared FALLBACK_ID when a species was never registered
-- (late ROM entries) so spawn can still proceed with a visible sprite.
function SpawnRender:spriteIdFor(species)
  if species == nil then
    return nil, "species id is required"
  end
  local spriteId = self.speciesSpriteIds[species]
  if spriteId then
    DebugLog.debug(self.mod, "species=%s spriteId=%s", tostring(species), tostring(spriteId))
    return spriteId
  end
  if self.fallbackId then
    DebugLog.warn(self.mod,
      "species=%s has no pre-registered overworld sprite; using fallback id",
      tostring(species))
    return self.fallbackId, nil, true
  end
  DebugLog.warn(self.mod,
    "species=%s has no pre-registered overworld sprite", tostring(species))
  return nil, "No pre-registered overworld sprite for species " .. tostring(species)
end

-- Runtime asset resolution / bake cache. Never touches content registries.
function SpawnRender:getRuntimeImage(species, game)
  if self.runtimeImageCache[species] then
    return self.runtimeImageCache[species]
  end
  local resolved = self:resolveAsset(species, game)
  local spriteId = self.speciesSpriteIds[species] or self.fallbackId
  local entry = {
    spriteId = spriteId,
    registeredImage = self.registrationInfo[species]
                      and self.registrationInfo[species].image,
    sourcePath = resolved.realAssetPath or resolved.path,
    bakedPath = (resolved.kind == "generated_overworld") and resolved.path or nil,
    status = "NOT_AVAILABLE",
    kind = resolved.kind,
    resolved = resolved,
    fallbackUsed = resolved.fallbackUsed == true,
  }
  if resolved.status == "LOADED" then
    entry.status = "LOADED"
  elseif resolved.status == "FALLBACK_LOADED" then
    entry.status = "FALLBACK_LOADED"
  elseif resolved.path then
    entry.status = "LOADED"
  else
    entry.status = "ASSET_MISSING"
  end
  self.runtimeImageCache[species] = entry
  return entry
end

function SpawnRender:assetStatusFor(species, game)
  if self.assetInfo[species] then return self.assetInfo[species] end

  local def = game and game.data and game.data.pokemon
              and game.data.pokemon[species]
  local reg = self.registrationInfo[species]
  local runtime = self:getRuntimeImage(species, game)
  local resolved = runtime.resolved or self:resolveAsset(species, game)
  local info = {
    species = species,
    battleFront = def and def.spriteFront or (reg and reg.source) or nil,
    battleBack = def and def.spriteBack or nil,
    menuIcon = def and def.icon or nil,
    overworldSprite = nil,
    generatedOverworld = runtime.bakedPath,
    voxel = nil,
    overworldKind = runtime.kind,
    spriteRegistered = self.speciesSpriteIds[species] ~= nil
                       or (runtime.fallbackUsed and self.fallbackId ~= nil),
    spriteId = self.speciesSpriteIds[species] or (
      runtime.fallbackUsed and self.fallbackId or nil),
    registration = reg and reg.status or (
      runtime.fallbackUsed and "FALLBACK" or "ASSET_MISSING"),
    runtimeStatus = runtime.status,
    status = "MISSING",
    renderer = "UNKNOWN",
    entityReady = false,
    lastError = reg and reg.lastError or resolved.loadError or nil,
    realAssetPath = resolved.realAssetPath,
    realAssetExists = resolved.realAssetExists == true,
    realAssetLoaded = resolved.realAssetLoaded == true,
    fallbackUsed = resolved.fallbackUsed == true,
    fallbackAvailable = self.fallbackAvailable == true,
    tried = resolved.tried,
    resolvedSource = resolved.source,
    resolvedPath = resolved.path,
    phase = nil,
  }

  if runtime.status == "LOADED" then
    info.overworldSprite = runtime.bakedPath or runtime.sourcePath or resolved.path
    info.overworldKind = runtime.kind or "battle_front"
    info.status = "LOADED"
    info.phase = "REAL_ASSET_LOADED"
  elseif runtime.status == "FALLBACK_LOADED" then
    info.overworldSprite = resolved.path
    info.overworldKind = "fallback"
    info.status = "FALLBACK_LOADED"
    info.phase = "FALLBACK_LOADED"
  elseif info.spriteRegistered then
    info.status = "REGISTERED"
    info.lastError = info.lastError or "registered but runtime asset not loaded"
    info.phase = "ASSET_LOAD_ERROR"
  else
    info.status = "MISSING"
    info.lastError = info.lastError
      or ("No pre-registered overworld sprite for species " .. tostring(species))
    info.phase = "REAL_ASSET_MISSING"
  end

  local dramatic = self.mod.find and self.mod.find("DRAMATIC_SHAPE")
  if dramatic then
    info.voxel = "DRAMATIC_SHAPE WORLD_BILLBOARD"
  end

  if self.rendererMode == "base" then
    info.renderer = "2D READY"
  elseif self.rendererMode == "unavailable" then
    info.renderer = "ERROR"
  else
    info.renderer = tostring(self.rendererMode)
  end

  -- Entity can be created whenever we have any draw path (real or fallback).
  info.entityReady = (info.status == "LOADED" or info.status == "FALLBACK_LOADED")
                     and self.rendererMode == "base"

  local enh = self:enhancedStatusFor(species, game)
  info.enhanced = enh
  info.enhancedStatus = enh.status
  info.enhancedAvailable = enh.available == true
  info.enhancedDexId = enh.dexId
  info.mappingFile = enh.fileName
  info.mappingName = enh.speciesName
  if enh.available then
    info.spriteSource = "FOLLOW_SPRITES"
    info.phase = enh.status
  elseif info.fallbackUsed then
    info.spriteSource = "BLACK_FALLBACK"
  elseif info.status == "LOADED" then
    info.spriteSource = "LEGACY_PNG"
  else
    info.spriteSource = info.phase or info.status
  end

  self.assetInfo[species] = info
  return info
end

function SpawnRender:countAssets(speciesList, game)
  local required, loaded = 0, 0
  for _, species in ipairs(speciesList or {}) do
    required = required + 1
    local info = self:assetStatusFor(species, game)
    if info.status == "LOADED" or info.status == "FALLBACK_LOADED" then
      loaded = loaded + 1
    end
  end
  return required, loaded
end

function SpawnRender:formatTried(resolved, maxLines)
  maxLines = maxLines or 4
  local lines = {}
  for i, t in ipairs((resolved and resolved.tried) or {}) do
    if i > maxLines then break end
    lines[#lines + 1] = string.format("- %s (%s)", tostring(t.path), tostring(t.source))
  end
  return lines
end

local Entity = {}
Entity.__index = Entity

function Entity.new(game, mod, render, record)
  local self = setmetatable({}, Entity)
  self.overworldWildSpawn = true
  self._owwildEntity = true
  self.passable = true
  -- Stable public id for the entity's full lifetime (never regenerates).
  self.id = record.id
  self.spawnId = record.id
  self.species = record.species
  self.level = record.level
  self.mapId = record.mapId
  self.state = record.state or Config.STATE.AVAILABLE
  self.cellX = record.x
  self.cellY = record.y
  self.px = record.x * CELL
  self.py = record.y * CELL
  self.facing = record.facing or "down"
  self.mod = mod
  self.render = render
  self.tuck = Config.get(mod, "grass_tuck_px") or Config.DEFAULTS.grass_tuck_px or 0
  self.registeredInWorld = false
  self.registered2D = false
  self.voxelRegistered = false
  self.voxelDisabled = false
  self.voxelUpdateOk = false
  self.voxelScale = 1
  self.render2DFallback = false
  self.worldRenderer = "GEN1_FLAT"
  self.pokemonRenderer = "WILDS_2D"
  self.dramaticBillboardSkipped = false
  self.spriteSource2D = nil
  self.voxelSource = nil
  self.alertIcon = false
  self.usingFallback = false
  self.entityPhase = "CREATING"
  self.surface = record.surface or Surface.GRASS
  self.encounterKind = record.encounterKind or "grass"
  self.visibleSprite = record.visibleSprite ~= false
  self.hiddenEncounter = record.hiddenEncounter == true
  self.inGrassOverlay = Surface.usesGrassOverlay(self.surface)
  self.scaleInfo = nil
  self.visualScale = 1
  self.final2DScale = 1
  self.grassOcclusionHeight = 0
  self.grassOcclusionActive = false
  self.grassRenderMode = GrassOcclusion.MODE_IMMERSED
  self.waterSink = (self.surface == Surface.WATER) and 2 or 0
  self.assetInfo = nil
  self.canTriggerBattle = record.canTriggerBattle ~= false
  Movement.init(self, record.x, record.y, self.facing)

  -- Legacy HIDDEN_GRASS / HIDDEN_CAVE: never load a Pokemon sprite and must
  -- not join ow.entities (VoxelScene would retire the pipeline on nil sprite).
  if self.hiddenEncounter or not self.visibleSprite then
    self.sprite = nil
    self.spriteId = nil
    self.entityPhase = "HIDDEN"
    self.usingFallback = false
    self.visualScale = 1
    self.final2DScale = 1
    self.scaleInfo = {
      scale = 1, final2DScale = 1, contentW = 0, contentH = 0,
      renderedW = 0, renderedH = 0, originalW = 0, originalH = 0,
      logicalFootprintTiles = 1,
    }
    return self
  end

  self.assetInfo = render:assetStatusFor(record.species, game)

  local spriteId, spriteErr, usedSharedFallback = render:spriteIdFor(record.species)
  if not spriteId then
    self.entityPhase = "ENTITY_CREATE_ERROR"
    error(spriteErr or "No pre-registered overworld sprite", 0)
  end

  local runtime = render:getRuntimeImage(record.species, game)
  local resolved = runtime.resolved or render:resolveAsset(record.species, game)
  self.usingFallback = runtime.fallbackUsed == true or usedSharedFallback == true

  local function lookupDef(id)
    local spriteDef = game.data.sprites and game.data.sprites[id]
    if spriteDef then return spriteDef end
    local contentDef = mod.content.sprites:get(id)
    if contentDef then
      spriteDef = {
        image = contentDef.image,
        frames = contentDef.frames or 1,
        trueColor = contentDef.trueColor ~= false,
        walker = contentDef.walker,
        id = id,
      }
      -- Runtime view only: keep the merged Data table in sync for consumers
      -- that read game.data.sprites. This is not a content-registry write.
      game.data.sprites = game.data.sprites or {}
      game.data.sprites[id] = spriteDef
      return spriteDef
    end
    return nil
  end

  local spriteDef = lookupDef(spriteId)
  if not spriteDef and render.fallbackId then
    spriteId = render.fallbackId
    spriteDef = lookupDef(spriteId)
    self.usingFallback = true
  end
  if not spriteDef then
    self.entityPhase = "ASSET_LOAD_ERROR"
    error("overworld_wild_spawns: pre-registered sprite missing from data: "
          .. tostring(spriteId), 0)
  end

  -- Prefer sprite providers (Followers EX / PokeMMO / Pokedex). Same native
  -- SpriteRenderer contract for every style — only the image source changes.
  local dexId = nil
  if record.dex ~= nil then
    dexId = tonumber(record.dex)
  end
  if not dexId then
    dexId = AnimatedSprites.resolveSpeciesId(record.species, game, mod)
  end
  local variant = AnimatedSprites.resolveRuntimeVariant(self)
  self.enhancedDexId = dexId
  self.spriteVariant = variant

  local function buildDef(id, path, frames, walker)
    local def = {
      image = path,
      frames = frames or 1,
      trueColor = true,
      id = id,
    }
    if walker then def.walker = true end
    return def
  end

  local style = Config.spriteStyle(mod)
  local resolvedProvider = nil
  if render.spriteResolver then
    resolvedProvider = render.spriteResolver:resolveForEntity(self, {
      style = style,
      game = game,
      surface = self.surface,
      speciesId = dexId or record.species,
      variant = variant,
    })
  elseif render.spriteProviders then
    resolvedProvider = render.spriteProviders:resolve(
      style, record.species or dexId, variant, game)
  end

  local drawDef = nil
  local nativeSheet = false
  local drawPath = spriteDef.image

  if resolvedProvider and resolvedProvider.def
     and type(resolvedProvider.def.image) == "string"
     and not isOsAbsolutePath(resolvedProvider.def.image) then
    drawDef = {
      image = resolvedProvider.def.image,
      frames = resolvedProvider.def.frames or 1,
      trueColor = resolvedProvider.def.trueColor ~= false,
      id = resolvedProvider.def.id or spriteId,
    }
    if resolvedProvider.def.walker then
      drawDef.walker = true
    end
    if resolvedProvider.def.pokepcShiny then
      drawDef.pokepcShiny = true
    end
    drawPath = drawDef.image
    nativeSheet = (drawDef.walker == true and (drawDef.frames or 1) >= 6)
    self.usingFallback = (resolvedProvider.providerId == "black")
    self.spriteVariant = (resolvedProvider.meta and resolvedProvider.meta.usedVariant)
      or variant
    self.spriteProviderId = resolvedProvider.providerId
    self.spriteFallbackStep = resolvedProvider.fallbackStep
    self.spriteProviderMeta = resolvedProvider.meta
    self.requestedSpriteStyle = style
    if render.spriteResolver then
      render.spriteResolver:applyEntityMeta(self, resolvedProvider)
    end
    if resolvedProvider.meta then
      self.runtimeLoadPath = resolvedProvider.meta.loadPath
      self.runtimeRelativePath = resolvedProvider.meta.relativePath
    end
  else
    -- Legacy path if providers unavailable (should not happen).
    local nativeLoadPath, usedVariant, nativeRel = nil, nil, nil
    if dexId and render.runtimeSheets and Config.useAnimatedOverworldSprites(mod) then
      if not render.runtimeSheets.ready and render.runtimeSheets.load then
        pcall(function() render.runtimeSheets:load() end)
      end
      nativeLoadPath, usedVariant, nativeRel =
        render.runtimeSheets:resolveAssetPath(dexId, variant)
      if nativeRel then
        local viaAssets = render:_modAssetPath(nativeRel)
        if viaAssets then nativeLoadPath = viaAssets end
      end
    end
    local drawFrames = spriteDef.frames or 1
    local drawWalker = spriteDef.walker == true
    drawPath = spriteDef.image
    if nativeLoadPath and not isOsAbsolutePath(nativeLoadPath) then
      drawPath = nativeLoadPath
      drawFrames = RuntimeSheets.FRAMES
      drawWalker = true
      nativeSheet = true
      self.usingFallback = false
      self.spriteVariant = usedVariant or variant
      self.runtimeRelativePath = nativeRel
      self.runtimeLoadPath = nativeLoadPath
      self.spriteProviderId = "pokemmo"
    elseif resolved and resolved.path and not isOsAbsolutePath(resolved.path) then
      drawPath = resolved.path
      self.spriteProviderId = "pokedex"
    elseif runtime and runtime.bakedPath and not isOsAbsolutePath(runtime.bakedPath) then
      drawPath = runtime.bakedPath
      self.spriteProviderId = "pokedex"
    end
    drawDef = buildDef(spriteId, drawPath, drawFrames, drawWalker)
  end

  if isOsAbsolutePath(drawPath) then
    drawPath = (render.fallbackPath or render:_fallbackPath())
    self.usingFallback = true
    self.entityPhase = "ASSET_LOAD_ERROR"
    nativeSheet = false
    drawDef = buildDef(spriteId, drawPath, 1, false)
    self.spriteProviderId = "black"
    DebugLog.error(mod,
      "refusing OS absolute sprite path for %s; using fallback",
      tostring(record.species))
  end

  local SpriteRenderer, err = tryRequire("src.render.SpriteRenderer")
  if not SpriteRenderer then
    self.entityPhase = "ENTITY_CREATE_ERROR"
    error("SpriteRenderer unavailable: " .. tostring(err), 0)
  end

  local okSprite, spriteOrErr = pcall(SpriteRenderer.new, drawDef, self.spawnId)
  if not okSprite then
    DebugLog.error(mod,
      "ASSET LOAD ERROR SpriteRenderer.new failed for %s path=%s err=%s — retry fallback",
      tostring(record.species), tostring(drawPath), tostring(spriteOrErr))
    local fbId = render.fallbackId or FALLBACK_ID
    local fbDef = lookupDef(fbId)
    if not fbDef then
      fbDef = buildDef(fbId, render.fallbackPath or render:_fallbackPath(), 1, false)
    end
    local okFb, fbSpriteOrErr = pcall(SpriteRenderer.new, fbDef, self.spawnId)
    if not okFb then
      self.entityPhase = "ENTITY_CREATE_ERROR"
      error("ENTITY CREATE ERROR: " .. tostring(fbSpriteOrErr), 0)
    end
    self.sprite = fbSpriteOrErr
    self.spriteId = fbId
    self.usingFallback = true
    self.nativeSpriteRenderer = false
    self.spriteProviderId = "black"
    self.entityPhase = "FALLBACK_LOADED"
  else
    self.sprite = spriteOrErr
    self.spriteId = drawDef.id or spriteId
    self.nativeSpriteRenderer = nativeSheet
    if self.usingFallback then
      self.entityPhase = "FALLBACK_LOADED"
    elseif nativeSheet then
      self.entityPhase = "NATIVE_SHEET_LOADED"
    else
      self.entityPhase = "REAL_ASSET_LOADED"
    end
  end

  -- Stable SpriteRenderer for the entity lifetime. Never mutate def.image.
  self.legacySprite = self.sprite
  if self.usingFallback then
    self.blackFallbackSprite = self.sprite
  end
  self.worldSprite = nil
  self.worldBillboardReady = self.nativeSpriteRenderer == true
  self.worldSpriteAdapterStatus = self.nativeSpriteRenderer and "NATIVE" or "N/A"
  self.grassRenderer = "ENGINE_2D"
  self.enhancedDexId = dexId
  self.usingFollowerSprite = (self.spriteProviderId == "followers_ex")
  if self.spriteKind == "swimming" or self.spriteKind == "levitates" then
    self.spriteSource = "WATER_" .. string.upper(self.spriteKind)
    self.spriteSource2D = self.spriteSource
    self.voxelSource = self.spriteSource
  end

  if self.sprite and self.sprite.image and self.sprite.image.setFilter then
    self.sprite.image:setFilter("nearest", "nearest")
  end

  -- Instrument resolveImage so diagnostics see Dramatic Shape texture fetches.
  render:_instrumentResolveImage(self, self.sprite)

  -- Native 16×16 sheets need no extra 2D scale. Legacy battle fronts still do.
  if self.nativeSpriteRenderer then
    self.scaleInfo = {
      scale = 1, final2DScale = 1, contentW = CELL, contentH = CELL,
      renderedW = CELL, renderedH = CELL, originalW = CELL, originalH = RuntimeSheets.SHEET_H,
      logicalFootprintTiles = 1, grassOcclusionHeight = 6,
    }
    self.visualScale = 1
    self.final2DScale = 1
    self.grassOcclusionHeight = 6
    self.voxelScale = 1
  else
    local minSize = Config.get(mod, "min_sprite_size") or Config.DEFAULTS.min_sprite_size
    self.scaleInfo = SpriteScale.compute(record.species,
      self.sprite and self.sprite.image, { minSpriteSizeOption = minSize })
    self.visualScale = self.scaleInfo.final2DScale or self.scaleInfo.scale or 1
    self.final2DScale = self.visualScale
    self.grassOcclusionHeight = self.scaleInfo.grassOcclusionHeight or 0
    self.voxelScale = 1
  end

  -- Attach follow-sprite metadata + bind native world billboard presentation.
  render:attachEnhancedToEntity(self, game)
  return self
end

-- Legacy helper kept for tests / callers. Prefer Movement.beginStep.
function Entity:setCell(x, y)
  if Movement.isBusy(self) then
    Movement.stop(self, self.movement and self.movement.state or "IDLE")
  end
  Movement.init(self, x, y, self.facing or "down")
  Movement.refreshGrassFlag(self, self.mod)
end

function Entity:update(dt)
  if Movement.isBusy(self) then
    local done = Movement.update(self, dt or 0)
    if done then
      Movement.refreshGrassFlag(self, self.mod)
    end
  else
    Movement.syncLegacyFields(self)
  end

  if self.render and self.render.syncEntityAnimation then
    self.render:syncEntityAnimation(self, dt or 0)
  end
end

function Entity:_grassTuck()
  local pokemonRenderer = self.pokemonRenderer
  local overlayEmergency = pokemonRenderer == SpawnRender.RENDERER.SPATIAL_OVERLAY_EMERGENCY
    or pokemonRenderer == "SPATIAL_OVERLAY_FALLBACK"
  local mode = GrassOcclusion.mode(self.mod)
  local worldBillboard = pokemonRenderer == SpawnRender.RENDERER.NATIVE_SPRITE_RENDERER
    or pokemonRenderer == SpawnRender.RENDERER.WORLD_BILLBOARD_ENHANCED
    or pokemonRenderer == SpawnRender.RENDERER.WORLD_BILLBOARD_LEGACY
    or pokemonRenderer == SpawnRender.RENDERER.WORLD_BILLBOARD_BLACK_FALLBACK

  -- World billboards: immersed uses DS native grass (no tuck). Above uses a
  -- small visualY lift so feet clear the late grass mesh (object occlusion stays).
  if worldBillboard then
    if mode == GrassOcclusion.MODE_ABOVE and self.inGrassOverlay then
      local lift = Config.get(self.mod, "grass_above_lift_px")
        or Config.DEFAULTS.grass_above_lift_px
        or GrassOcclusion.ENGINE_BOTTOM_COVER_PX
      return -(tonumber(lift) or 8)
    end
    return self.tuck or 0
  end

  -- Flat path and emergency overlay.
  return GrassOcclusion.tuckDelta(self, {
    mode = mode,
    engineOverdrawExpected = (mode == GrassOcclusion.MODE_ABOVE)
      and not overlayEmergency,
  })
end

function Entity:calculateVisualY()
  Movement.syncLegacyFields(self)
  local tuck = self:_grassTuck()
  local SpawnFx = V.require("spawn_fx")
  local hopPx = SpawnFx.visualLift(self)
  local water = tonumber(self.surfaceVisualOffset) or (self.waterSink or 0)
  if self.surface == Surface.WATER and (not self.spawnFx or self.spawnFx.done) then
    -- Settled water sit offset.
    hopPx = hopPx
  end
  -- Silhouette mode: sit a few pixels deeper under the surface (presentation).
  local WaterDisplay = V.require("water_display")
  water = water + WaterDisplay.silhouetteSink(self.mod, self)
  return (self.py or 0) + tuck + water - hopPx
end

-- Native SpriteRenderer first (trainer contract). EnhancedWorldSprite is unused
-- for body presentation after the 0.7.0 migration.
function SpawnRender:isBodyVisible(entity)
  if not entity then return false end
  local SpawnFx = V.require("spawn_fx")
  return SpawnFx.bodyVisible(entity)
end

function Entity:getWorldSprite()
  local render = self.render
  if render and render.isBodyVisible and not render:isBodyVisible(self) then
    return nil
  end
  local SpawnFx = V.require("spawn_fx")
  if not SpawnFx.bodyVisible(self) then
    return nil
  end
  if self.hiddenEncounter or self.visibleSprite == false then
    return nil
  end
  if self.sprite and self.sprite.def then
    return self.sprite
  end
  if self.legacySprite then
    return self.legacySprite
  end
  if self.blackFallbackSprite then
    return self.blackFallbackSprite
  end
  return nil
end

function Entity:pose()
  -- Same contract as Gen1Recomp NPC:pose / Player:pose:
  --   sprite, visualX, visualY, facing, phase, flip [, hop]
  local SpawnFx = V.require("spawn_fx")
  Movement.syncLegacyFields(self)
  if not SpawnFx.bodyVisible(self) then
    local d = RenderDiagnostics.ensure(self)
    d.poseCalls = (d.poseCalls or 0) + 1
    d.lastFailureReason = "pose() skipped (body hidden / spawn FX)"
    d.lastPoseSpriteType = "nil"
    self.hopping = false
    return nil, self.px or 0, self.py or 0, self.facing or "down", 0, false, false
  end
  local sprite = self:getWorldSprite()
  local d = RenderDiagnostics.ensure(self)
  d.poseCalls = (d.poseCalls or 0) + 1
  d.lastPoseSpriteType = RenderDiagnostics.spriteTypeName(sprite)
  if sprite and sprite.def then
    d.lastDefImage = sprite.def.image
    d.lastSpriteFrames = sprite.def.frames
    d.lastSpriteWalker = sprite.def.walker == true
  end
  if sprite == nil then
    d.lastFailureReason = "pose() nil sprite"
    return nil, self.px or 0, self.py or 0, self.facing or "down", 0, false, false
  end
  local visualY = self:calculateVisualY()
  self._lastVisualY = visualY
  self._lastLift = (self.py or 0) - visualY
  local phase = Movement.walkPhase(self)
  local flip = self.stepFlip == true
  self.phase = phase
  self.flip = flip
  self.walkFlip = flip
  local hop = self.hopping == true
  if not hop then self.hopping = false end
  return sprite, self.px or 0, visualY, self.facing or "down", phase, flip, hop
end

-- When Dramatic Shape owns the body as a world billboard, Entity:draw must
-- not paint a second body (that would sit on top of grass with no depth).
function Entity:_voxelBillboardOwnsBody()
  if self.worldRenderer ~= "DRAMATIC_SHAPE" then return false end
  local r = self.pokemonRenderer
  return r == SpawnRender.RENDERER.NATIVE_SPRITE_RENDERER
    or r == SpawnRender.RENDERER.WORLD_BILLBOARD_ENHANCED
    or r == SpawnRender.RENDERER.WORLD_BILLBOARD_LEGACY
    or r == SpawnRender.RENDERER.WORLD_BILLBOARD_BLACK_FALLBACK
end

function Entity:_strictHidesBody()
  return RenderDiagnostics.strictEnabled(self.mod)
    and self.worldRenderer == "DRAMATIC_SHAPE"
end

function Entity:_drawHiddenEffect(camX, camY)
  -- Legacy HIDDEN_GRASS / HIDDEN_CAVE keep the subtle marker.
  if not (love and love.graphics) then return end
  if Config.get(self.mod, "enable_grass_movement_effects") == false then return end
  local x = math.floor(self.px - (camX or 0))
  local y = math.floor(self.py - (camY or 0))
  local active = self.grassEffectActive == true
  if self.behavior == Behavior.HIDDEN_GRASS or self.surface == Surface.GRASS then
    -- Subtle grass tuft wiggle (no Pokemon sprite).
    local amp = active and 2 or 0
    local phase = (self.behaviorState and self.behaviorState.shakePhase) or 0
    local ox = (phase % 2 == 0) and amp or -amp
    love.graphics.setColor(0.25, 0.65, 0.28, active and 0.55 or 0.22)
    love.graphics.rectangle("fill", x + 3 + ox, y + 10, 10, 5)
    love.graphics.setColor(0.18, 0.5, 0.2, active and 0.7 or 0.3)
    love.graphics.rectangle("fill", x + 5 + ox, y + 8, 6, 3)
  else
    -- Cave dust / shadow pulse (no grass animation underground).
    local a = active and 0.45 or 0.18
    love.graphics.setColor(0.15, 0.12, 0.1, a)
    love.graphics.ellipse("fill", x + 8, y + 12, active and 6 or 4, active and 3 or 2)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Entity:_drawAnimatedSprite(camX, camY, opacity)
  local d = RenderDiagnostics.ensure(self)
  d.animatedSpriteDrawCalls = (d.animatedSpriteDrawCalls or 0) + 1
  local render = self.render
  local animated = render and render.animated
  local anim = self.animation
  if not animated or not anim or not self.enhancedDexId then return end
  if not (love and love.graphics) then return end

  local variant = anim.variant or self.spriteVariant or "normal"
  local frame, frameCount, frameIndex = animated:getFrame(
    self.enhancedDexId, anim.name, anim.direction, anim.frameIndex, variant)
  if not frame then return end
  local quad = animated:getQuad(
    self.enhancedDexId, anim.name, anim.direction, frameIndex or anim.frameIndex, variant)
  local img = animated:getImage(self.enhancedDexId, variant)
  if not img or not quad or quad._owwildStub then return end
  if img.setFilter then img:setFilter("nearest", "nearest") end

  local scale = self.final2DScale or 1
  local contentW = frame.width
  local contentH = frame.height
  local renderedW = contentW * scale
  local renderedH = contentH * scale

  local baseX = math.floor(self.px - (camX or 0))
  local tuck = self:_grassTuck()
  local WaterDisplay = V.require("water_display")
  local waterY = (self.waterSink or 0)
    + WaterDisplay.silhouetteSink(self.mod, self)
  local baseY = math.floor(self.py + tuck + waterY
                           - (camY or 0) - 4)

  -- Anchor: center X, feet on tile floor (anchorX=0.5, anchorY=1.0).
  local dx = baseX + (CELL - renderedW) * 0.5
  local dy = baseY + (CELL - renderedH)

  if opacity < 1 then love.graphics.setColor(1, 1, 1, opacity) end
  -- Dedicated left/right atlas frames — do not mirror.
  love.graphics.draw(img, quad, dx, dy, 0, scale, scale)
  if opacity < 1 then love.graphics.setColor(1, 1, 1, 1) end

  local ok, PaletteFX = pcall(require, "src.render.PaletteFX")
  if ok and PaletteFX and PaletteFX.markTrueColor then
    PaletteFX.markTrueColor(dx, dy, renderedW, renderedH)
  end

  anim._lastFrameCount = frameCount
  anim._lastFrameSize = { contentW, contentH }
end

function Entity:_drawScaledSprite(camX, camY, opacity)
  -- Deprecated atlas path only when explicitly enhanced AND not a native walker.
  if self.usingEnhancedSprite and not self.nativeSpriteRenderer then
    self:_drawAnimatedSprite(camX, camY, opacity)
    return
  end
  local sprite = self.sprite
  if not sprite or not sprite.image then return end
  -- One final 2D scale only — no species*grass*camera multiplication here.
  local scale = self.final2DScale or self.visualScale or 1
  local img = sprite.image
  if img.setFilter then img:setFilter("nearest", "nearest") end

  local info = self.scaleInfo or {}
  local contentW = info.contentW or CELL
  local contentH = info.contentH or CELL
  local ox = info.offsetX or 0
  local oy = info.offsetY or 0
  local iw = info.imageW or contentW
  local ih = info.imageH or contentH

  -- Anchor: horizontally centered on the tile, feet (visible bottom) on tile floor.
  local baseX = math.floor(self.px - (camX or 0))
  local tuck = self:_grassTuck()
  local WaterDisplay = V.require("water_display")
  local waterY = (self.waterSink or 0)
    + WaterDisplay.silhouetteSink(self.mod, self)
  local baseY = math.floor(self.py + tuck + waterY
                           - (camY or 0) - 4)

  local renderedW = contentW * scale
  local renderedH = contentH * scale
  local dx = baseX + (CELL - renderedW) * 0.5
  local dy = baseY + (CELL - renderedH) -- grow up from feet / tile floor

  local flip = (self.facing == "left")
  if opacity < 1 then love.graphics.setColor(1, 1, 1, opacity) end

  -- Prefer a quad over the visible bounds when the sheet is larger than content.
  local quad = nil
  if love and love.graphics and love.graphics.newQuad
     and (ox ~= 0 or oy ~= 0 or contentW ~= iw or contentH ~= ih) then
    local okQ, q = pcall(love.graphics.newQuad, ox, oy, contentW, contentH, iw, ih)
    if okQ then quad = q end
  end

  if quad then
    if flip then
      love.graphics.draw(img, quad, dx + renderedW, dy, 0, -scale, scale)
    else
      love.graphics.draw(img, quad, dx, dy, 0, scale, scale)
    end
  else
    -- Fallback: scale the full image (bake path is already ~one tile).
    if flip then
      love.graphics.draw(img, dx + renderedW, dy, 0, -scale, scale)
    else
      love.graphics.draw(img, dx, dy, 0, scale, scale)
    end
  end
  if opacity < 1 then love.graphics.setColor(1, 1, 1, 1) end

  local ok, PaletteFX = pcall(require, "src.render.PaletteFX")
  if ok and PaletteFX and PaletteFX.markTrueColor then
    PaletteFX.markTrueColor(dx, dy, renderedW, renderedH)
  end
end

function Entity:draw(camX, camY)
  -- 2D renderer: read-only with respect to world simulation state.
  local SpawnFx = V.require("spawn_fx")
  local WaterDisplay = V.require("water_display")
  local d = RenderDiagnostics.ensure(self)
  local skipBody = false
  if not SpawnFx.bodyVisible(self) then
    return
  end

  -- Hidden water silhouettes (Flat 2D only): circle marker, no Pokémon sprite.
  -- Voxel Hidden uses the native flat underwater shadow sheet on the DS path
  -- (waterHiddenShadow) — do not paint the 2D circle as an overlay.
  if WaterDisplay.isHiddenSilhouettes(self.mod)
     and WaterDisplay.isWaterEntity(self)
     and not self.hiddenEncounter
     and not (self.waterHiddenShadow == true and self.waterVoxelActive == true) then
    WaterDisplay.drawHiddenCircle(self, camX, camY, {
      player = WaterDisplay.resolvePlayer(self.mod),
    })
    if self.render.debugMarkers and Config.devOverlay(self.mod)
       and love and love.graphics then
      local x = math.floor(self.px - (camX or 0))
      local y = math.floor(self.py - (camY or 0)) - 4
      love.graphics.setColor(1, 0.2, 0.2, 1)
      love.graphics.rectangle("line", x, y, CELL, CELL)
      love.graphics.setColor(1, 1, 1, 1)
    end
    if Config.showBehaviorOverlays(self.mod) and love and love.graphics then
      local DevOverlay = V.require("dev_overlay")
      DevOverlay.drawOnEntity(self, camX, camY)
    end
    return
  end

  if self:_voxelBillboardOwnsBody() then
    -- Body belongs to Dramatic Shape SpriteBillboards — never double-draw.
    skipBody = true
    d.lastFailureReason = d.lastFailureReason
      or "Entity:draw skipped body (WORLD_BILLBOARD owns body)"
  elseif self:_strictHidesBody() then
    -- Strict debug: no emergency/post-voxel body; only DS billboard may show.
    skipBody = true
    d.lastFailureReason = "strict_world_billboard_debug: Entity:draw body suppressed"
  end

  if (self.hiddenEncounter or not self.visibleSprite) then
    self:_drawHiddenEffect(camX, camY)
  elseif not skipBody then
    d.entityDrawBodyDrawCalls = (d.entityDrawBodyDrawCalls or 0) + 1
    d.entityDrawBodyCalls = (d.entityDrawBodyCalls or 0) + 1
    if self.worldRenderer == "DRAMATIC_SHAPE" then
      d.postVoxelBodyDrawCalls = (d.postVoxelBodyDrawCalls or 0) + 1
    end
    -- Sprite Fade applies only to normal visible wild Pokémon bodies.
    -- Never fade followers, ambient Town Pokémon, hidden markers, water
    -- silhouettes, voxel shadow quads, or UI previews.
    local opacity = 1.0
    local mayFade = self.overworldWildSpawn == true
      and self.wildsAmbientPokemon ~= true
      and not self.hiddenEncounter
      and self.visibleSprite ~= false
      and not (self.wildsFollower or self.pokepcTrailer or self.pikachuFollower)
    if mayFade and Config.spriteOpacity then
      opacity = Config.spriteOpacity(self.mod) or 1.0
    elseif mayFade then
      opacity = Config.get(self.mod, "sprite_opacity") or 1
    end
    -- Flat 2D silhouettes: runtime tint. Voxel silhouettes: baked sheet (no tint).
    local silhouette = WaterDisplay.isSilhouettes(self.mod)
      and WaterDisplay.isWaterEntity(self)
      and self.waterSilhouetteSheet ~= true
    local player = silhouette and WaterDisplay.resolvePlayer(self.mod) or nil

    local function drawBody()
      -- Preferred: native SpriteRenderer:draw (same as trainers / flat NPC path).
      if self.nativeSpriteRenderer and self.sprite and type(self.sprite.draw) == "function" then
        d.legacySpriteDrawCalls = (d.legacySpriteDrawCalls or 0) + 1
        local sprite, px, py, facing, phase, flip = self:pose()
        if sprite then
          if (not silhouette) and opacity < 1
             and love and love.graphics and love.graphics.setColor then
            love.graphics.setColor(1, 1, 1, opacity)
            sprite:draw(px, py, camX, camY, facing, phase, flip)
            love.graphics.setColor(1, 1, 1, 1)
          else
            sprite:draw(px, py, camX, camY, facing, phase, flip)
          end
        end
      elseif love and love.graphics and self.sprite and type(self.sprite.draw) == "function"
             and (self.final2DScale or 1) == 1 then
        d.legacySpriteDrawCalls = (d.legacySpriteDrawCalls or 0) + 1
        local sprite, px, py, facing, phase, flip = self:pose()
        if sprite then
          if (not silhouette) and opacity < 1 then
            love.graphics.setColor(1, 1, 1, opacity)
          end
          sprite:draw(px, py, camX, camY, facing, phase, flip)
          if (not silhouette) and opacity < 1 then
            love.graphics.setColor(1, 1, 1, 1)
          end
        end
      elseif self.usingEnhancedSprite and not self.nativeSpriteRenderer then
        -- Deprecated multi-frame atlas path (kept for option-off / tests).
        self:_drawAnimatedSprite(camX, camY, opacity)
      else
        d.legacySpriteDrawCalls = (d.legacySpriteDrawCalls or 0) + 1
        self:_drawScaledSprite(camX, camY, opacity)
      end
    end

    if silhouette then
      WaterDisplay.withSilhouetteTint(self, player, drawBody)
    else
      drawBody()
    end

    -- Spatial emergency overlay only: world billboards get DS tall-grass.
    -- Never draw custom grass for NATIVE / WORLD_BILLBOARD_* success paths.
    local emergency = self.pokemonRenderer == SpawnRender.RENDERER.SPATIAL_OVERLAY_EMERGENCY
      or self.pokemonRenderer == "SPATIAL_OVERLAY_FALLBACK"
    if emergency and not RenderDiagnostics.strictEnabled(self.mod)
       and GrassOcclusion.shouldOcclude(self, self.mod) then
      local world = self.mod and self.mod.world
      local ow = world and world.overworld and world:overworld()
      GrassOcclusion.drawForeground(self, camX, camY, ow and ow.map)
    end
  end

  -- Optional debug marker (Dev Overlay): outline + species / behaviour.
  if self.render.debugMarkers and Config.devOverlay(self.mod)
     and love and love.graphics then
    local x = math.floor(self.px - (camX or 0))
    local y = math.floor(self.py - (camY or 0)) - 4
    love.graphics.setColor(1, 0.2, 0.2, 1)
    love.graphics.rectangle("line", x, y, CELL, CELL)
    love.graphics.setColor(1, 1, 1, 1)
    if love.graphics.print then
      local label = tostring(self.species or "HIDDEN")
      if self.behavior then label = label .. " " .. tostring(self.behavior) end
      love.graphics.print(label, x, y - 8)
    end
  end

  if Config.showBehaviorOverlays(self.mod) and love and love.graphics then
    -- Legacy sight/region fill removed; compact Dev Overlay labels instead.
    local DevOverlay = V.require("dev_overlay")
    DevOverlay.drawOnEntity(self, camX, camY)
  end
end

function SpawnRender:makeEntity(game, record)
  return Entity.new(game, self.mod, self, record)
end

-- Probe whether a species can become an overworld entity without mutating world
-- or content registries.
function SpawnRender:probeEntity(game, species)
  local info = self:assetStatusFor(species, game)
  if not info.entityReady and info.status ~= "LOADED"
     and info.status ~= "FALLBACK_LOADED" then
    -- Still try when fallback exists.
    if not self.fallbackId then
      info.entityReady = false
      info.entityStatus = Config.STATUS.NOT_AVAILABLE
      info.lastError = info.lastError
        or ("No pre-registered overworld sprite for species " .. tostring(species))
      info.phase = info.phase or "REAL_ASSET_MISSING"
      return info, nil
    end
  end
  local ok, entityOrErr = pcall(function()
    return self:makeEntity(game, {
      id = "owwild_probe",
      mapId = "_probe",
      x = 0, y = 0,
      species = species,
      level = 1,
      state = Config.STATE.AVAILABLE,
    })
  end)
  if not ok then
    info.entityReady = false
    info.lastError = tostring(entityOrErr)
    info.entityStatus = Config.STATUS.ERROR
    info.phase = "ENTITY_CREATE_ERROR"
    return info, nil
  end
  if not entityOrErr then
    info.entityReady = false
    info.lastError = "makeEntity returned nil"
    info.entityStatus = Config.STATUS.NOT_AVAILABLE
    info.phase = "ENTITY_CREATE_ERROR"
    return info, nil
  end
  info.entityReady = true
  if entityOrErr.usingFallback then
    info.entityStatus = "FALLBACK READY"
    info.phase = "FALLBACK_LOADED"
  elseif info.status == "LOADED" and self.rendererMode == "base" then
    info.entityStatus = Config.STATUS.READY
    info.phase = "REAL_ASSET_LOADED"
  else
    info.entityStatus = Config.STATUS.READY
  end
  return info, entityOrErr
end

function SpawnRender:previewImagePath(species, game)
  local info = self:assetStatusFor(species, game)
  if info.generatedOverworld then return info.generatedOverworld, "generated_overworld" end
  if info.overworldSprite then return info.overworldSprite, info.overworldKind or "overworld" end
  if info.battleFront then return info.battleFront, "battle_front" end
  if self.fallbackPath then return self.fallbackPath, "fallback" end
  return self:_placeholderPath(), "placeholder"
end

-- Numeric Pokedex id for atlas mapping (identity). Display names never used.
function SpawnRender:resolveDexId(speciesKey, game)
  return AnimatedSprites.resolveSpeciesId(speciesKey, game, self.mod)
end

function SpawnRender:animatedEnabled()
  return Config.useAnimatedOverworldSprites(self.mod)
     and self.animated and self.animated:isReady()
end

function SpawnRender:enhancedStatusFor(speciesKey, game)
  local dexId = self:resolveDexId(speciesKey, game)
  if not self.animated or not self.animated.loaded then
    return {
      dexId = dexId,
      status = AnimatedSprites.STATUS.DISABLED,
      available = false,
    }
  end
  if not Config.useAnimatedOverworldSprites(self.mod) then
    return {
      dexId = dexId,
      status = AnimatedSprites.STATUS.DISABLED,
      available = false,
    }
  end
  if not self.animated:isReady() then
    return {
      dexId = dexId,
      status = AnimatedSprites.STATUS.DISABLED,
      available = false,
      reason = self.animated.error or "follow sprites unavailable",
    }
  end
  if not dexId then
    return {
      dexId = nil,
      status = AnimatedSprites.STATUS.MAPPING_MISSING,
      available = false,
      reason = "no numeric speciesId/dex",
    }
  end
  local mapping = self.animated:getMapping(dexId)
  if not mapping then
    return {
      dexId = dexId,
      status = AnimatedSprites.STATUS.MAPPING_MISSING,
      available = false,
    }
  end
  return {
    dexId = dexId,
    status = mapping.status,
    available = mapping.valid == true,
    mapping = mapping,
    speciesName = mapping.speciesName,
    fileName = mapping.fileName,
    missingDirs = mapping.missingDirs,
    partial = mapping.partial,
  }
end


-- Replace entity.sprite exactly once from the selected provider. Preserves
-- facing / phase / flip / position / behaviour. No registry mutation.
-- Land vs water sprite source is selected via SpriteResolver (same native
-- SpriteRenderer contract either way).
function SpawnRender:applyProviderSprite(entity, game)
  if not entity then return false end
  if entity.hiddenEncounter or entity.visibleSprite == false then
    return false
  end
  if not self.spriteProviders and not self.spriteResolver then
    return false
  end

  -- Always read the live option — never trust a stale entity field alone.
  local style = Config.spriteStyle(self.mod)
  entity.requestedSpriteStyle = style
  -- PaletteFX COLORS mode gate: a flip between redpp (ADVANCED, colored art)
  -- and any other mode must force a re-resolve below.
  local redpp = Config.paletteFxRedpp()
  local variant = AnimatedSprites.resolveRuntimeVariant(entity)
  local species = entity.species or entity.enhancedDexId
  local map = game and game.overworld and game.overworld.map
  local WaterDisplay = V.require("water_display")
  local voxelActive = WaterDisplay.isVoxelCameraActive(self.mod)
  local waterMode = "swimming_sprites"
  if type(Config.waterDisplayMode) == "function" then
    waterMode = Config.waterDisplayMode(self.mod) or waterMode
  end
  local WaterShadowRenderer = V.require("water_shadow_renderer")
  local shadowMode = WaterShadowRenderer.shadowModeFor(self.mod, entity, voxelActive)
  local result
  if self.spriteResolver then
    result = self.spriteResolver:resolveForEntity(entity, {
      style = style,
      game = game,
      map = map,
      surface = entity.surface,
      speciesId = entity.enhancedDexId or species,
      variant = variant,
      voxelActive = voxelActive,
      nativeSilhouette = voxelActive
        and WaterDisplay.needsNativeSilhouetteSheet(self.mod, entity),
      nativeHiddenShadow = voxelActive
        and WaterDisplay.needsNativeHiddenShadow(self.mod, entity),
    })
  else
    result = self.spriteProviders:resolve(style, species, variant, game)
  end
  if not (result and result.def and type(result.def.image) == "string") then
    return false
  end
  if isOsAbsolutePath(result.def.image) then
    return false
  end

  -- Hard rule: explicit PokeMMO land must never keep a Followers sheet.
  if style == "pokemmo" and (result.spriteState == "land" or not result.waterOverride)
     and result.providerId == "followers_ex" then
    result = self.spriteProviders:resolve("pokemmo", species, variant, game)
    if not (result and result.def and type(result.def.image) == "string") then
      return false
    end
    result.spriteState = result.spriteState or "land"
  end

  local wantSilSheet = result.waterSilhouetteSheet == true
  local wantHiddenShadow = result.waterHiddenShadow == true
  local wantFlatShadow = result.waterFlatShadow == true
  local resultShadowMode = result.shadowRendererMode
    or (result.meta and result.meta.shadowRendererMode)
    or shadowMode
  -- Skip rebuild when the same provider image / surface / water mode is bound.
  local cur = entity.sprite and entity.sprite.def
  if cur and cur.image == result.def.image
     and (cur.frames or 1) == (result.def.frames or 1)
     and (cur.walker == true) == (result.def.walker == true)
     and entity.spriteProviderId == result.providerId
     and entity.spriteState == result.spriteState
     and entity.requestedSpriteStyle == style
     and entity.waterDisplayMode == waterMode
     and entity.waterSilhouetteSheet == wantSilSheet
     and entity.waterHiddenShadow == wantHiddenShadow
     and entity.waterFlatShadow == wantFlatShadow
     and entity.shadowRendererMode == resultShadowMode
     and entity.waterVoxelActive == voxelActive
     and entity.paletteRedpp == redpp then
    entity.requestedSpriteStyle = style
    entity.spriteFallbackStep = result.fallbackStep
    entity.spriteProviderMeta = result.meta
    entity.waterDisplayMode = waterMode
    entity.waterSilhouetteSheet = wantSilSheet
    entity.waterHiddenShadow = wantHiddenShadow
    entity.waterFlatShadow = wantFlatShadow
    entity.shadowRendererMode = resultShadowMode
    entity.waterVoxelActive = voxelActive
    entity.paletteRedpp = redpp
    if self.spriteResolver then
      self.spriteResolver:applyEntityMeta(entity, result)
    end
    return true
  end

  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not SpriteRenderer then
    return false
  end

  -- Preserve owner movement / pose contract across the swap. Only the
  -- SpriteRenderer + presentation metadata may change.
  local preserved = {
    facing = entity.facing,
    stepFlip = entity.stepFlip,
    walkFlip = entity.walkFlip,
    flip = entity.flip,
    movement = entity.movement,
    position = entity.position,
    cellX = entity.cellX,
    cellY = entity.cellY,
    px = entity.px,
    py = entity.py,
    targetX = entity.targetX,
    targetY = entity.targetY,
    moving = entity.moving,
    behavior = entity.behavior,
    behaviorState = entity.behaviorState,
    surface = entity.surface,
    spawnId = entity.spawnId,
    id = entity.id,
  }

  -- Copy provider def exactly for native walkers; never invent walker=true.
  local def = {
    image = result.def.image,
    frames = result.def.frames or 1,
    trueColor = result.def.trueColor ~= false,
    id = result.def.id or ("SPRITE_OW_WILD_" .. tostring(species)),
  }
  if result.def.walker == true then def.walker = true end
  if result.def.pokepcShiny then def.pokepcShiny = true end
  -- Retain any extra SpriteRenderer fields the provider already published.
  for k, v in pairs(result.def) do
    if def[k] == nil then def[k] = v end
  end

  local ok, sprite = pcall(SpriteRenderer.new, def, entity.spawnId or entity.id)
  if not ok or not sprite then
    return false
  end
  self._spriteRendererNews = (self._spriteRendererNews or 0) + 1
  entity._wildsSpriteRendererNews = (entity._wildsSpriteRendererNews or 0) + 1

  local nativeSheet = (def.walker == true and (def.frames or 1) >= 6)
  entity.sprite = sprite
  entity.legacySprite = sprite
  entity.spriteId = def.id
  entity.nativeSpriteRenderer = nativeSheet
  entity.usingFallback = (result.providerId == "black")
  entity.spriteProviderId = result.providerId
  entity.spriteFallbackStep = result.fallbackStep
  entity.spriteProviderMeta = result.meta
  entity.requestedSpriteStyle = style
  entity.paletteRedpp = redpp
  entity.spriteVariant = (result.meta and result.meta.usedVariant) or variant
  entity.usingFollowerSprite = (result.providerId == "followers_ex")
  -- Native walker sheets are driven solely by SpriteRenderer + Movement.walkPhase.
  -- Never mark them as the deprecated enhanced-atlas body path.
  entity.usingEnhancedSprite = false
  entity.worldSprite = nil
  entity.waterDisplayMode = waterMode
  entity.waterSilhouetteSheet = wantSilSheet
  entity.waterHiddenShadow = wantHiddenShadow
  entity.waterFlatShadow = wantFlatShadow
  entity.shadowRendererMode = resultShadowMode
  entity.waterVoxelActive = voxelActive
  if self.spriteResolver then
    self.spriteResolver:applyEntityMeta(entity, result)
  end
  if result.meta then
    entity.runtimeLoadPath = result.meta.loadPath
    entity.runtimeRelativePath = result.meta.relativePath
    if result.meta.silhouetteFallback then
      entity.waterSilhouetteFallback = true
    end
  end

  if nativeSheet then
    if wantHiddenShadow then
      entity.spriteSource = "WATER_HIDDEN_SHADOW"
    elseif result.spriteKind == "swimming" or result.spriteKind == "levitates" then
      entity.spriteSource = wantSilSheet
        and ("WATER_" .. string.upper(result.spriteKind) .. "_SILHOUETTE")
        or ("WATER_" .. string.upper(result.spriteKind))
    elseif result.providerId == "followers_ex" then
      entity.spriteSource = "FOLLOWERS_EX"
    else
      entity.spriteSource = "FOLLOW_SPRITES"
    end
    entity.spriteSource2D = entity.spriteSource
    entity.voxelSource = entity.spriteSource
    entity.pokemonRenderer = SpawnRender.RENDERER.NATIVE_SPRITE_RENDERER
    entity.scaleInfo = {
      scale = 1, final2DScale = 1, contentW = CELL, contentH = CELL,
      renderedW = CELL, renderedH = CELL, originalW = CELL,
      originalH = RuntimeSheets.SHEET_H, logicalFootprintTiles = 1,
      grassOcclusionHeight = entity.grassOcclusionHeight or 6,
    }
    entity.visualScale = 1
    entity.final2DScale = 1
    entity.grassOcclusionHeight = entity.grassOcclusionHeight or 6
    -- Optional HUD/diagnostic animation metadata only. Must not claim the
    -- enhanced atlas owns the body, and must not reset Movement phase.
    if entity.animation then
      entity.animation.usingEnhancedSprite = false
      entity.animation.source = entity.spriteSource
      entity.animation.variant = entity.spriteVariant
    end
    if entity.entityPhase == "FALLBACK_LOADED" or entity.entityPhase == "CREATING" then
      entity.entityPhase = "NATIVE_SHEET_LOADED"
    end
  else
    if result.providerId == "gold" then
      entity.spriteSource = "GOLD_SPRITES"
    elseif entity.usingFallback then
      entity.spriteSource = "BLACK_FALLBACK"
    else
      entity.spriteSource = "LEGACY_PNG"
    end
    entity.spriteSource2D = entity.spriteSource
    entity.voxelSource = entity.spriteSource
    entity.pokemonRenderer = entity.usingFallback
      and SpawnRender.RENDERER.WORLD_BILLBOARD_BLACK_FALLBACK
      or SpawnRender.RENDERER.WORLD_BILLBOARD_LEGACY
    local minSize = Config.get(self.mod, "min_sprite_size") or Config.DEFAULTS.min_sprite_size
    entity.scaleInfo = SpriteScale.compute(entity.species,
      entity.sprite and entity.sprite.image, { minSpriteSizeOption = minSize })
    entity.visualScale = entity.scaleInfo.final2DScale or entity.scaleInfo.scale or 1
    entity.final2DScale = entity.visualScale
    entity.grassOcclusionHeight = entity.scaleInfo.grassOcclusionHeight
      or entity.grassOcclusionHeight or 0
  end

  -- Restore identity / simulation fields. Phase is recomputed from Movement
  -- below — do not treat a stashed phase as an animation fix.
  entity.facing = preserved.facing or entity.facing
  entity.stepFlip = preserved.stepFlip
  entity.walkFlip = preserved.walkFlip
  entity.flip = preserved.flip
  entity.movement = preserved.movement
  entity.position = preserved.position
  entity.cellX = preserved.cellX
  entity.cellY = preserved.cellY
  entity.px = preserved.px
  entity.py = preserved.py
  entity.targetX = preserved.targetX
  entity.targetY = preserved.targetY
  entity.moving = preserved.moving
  entity.behavior = preserved.behavior
  entity.behaviorState = preserved.behaviorState
  entity.surface = preserved.surface
  entity.spawnId = preserved.spawnId
  entity.id = preserved.id

  Movement.syncLegacyFields(entity)

  if entity.sprite and entity.sprite.image and entity.sprite.image.setFilter then
    entity.sprite.image:setFilter("nearest", "nearest")
  end
  self:_instrumentResolveImage(entity, entity.sprite)
  self:bindWorldBillboard(entity, true)
  return true
end

function SpawnRender:attachEnhancedToEntity(entity, game)
  -- Provider-driven bind: preserves entity identity, replaces SpriteRenderer only.
  return self:applyProviderSprite(entity, game)
end

-- Bind native SpriteRenderer for Dramatic Shape. EnhancedWorldSprite is no
-- longer the primary body renderer (kept in-repo for deprecated tests only).
function SpawnRender:bindWorldBillboard(entity, force)
  if not entity then
    return false, "no entity"
  end

  local R = SpawnRender.RENDERER
  local d = RenderDiagnostics.ensure(entity)
  local strict = RenderDiagnostics.strictEnabled(self.mod)

  if entity.hiddenEncounter or entity.visibleSprite == false then
    entity.pokemonRenderer = R.HIDDEN
    entity.worldBillboardReady = false
    return false, "hidden"
  end

  -- Native trainer-contract sheet.
  if entity.nativeSpriteRenderer and entity.sprite and entity.sprite.def
     and entity.sprite.def.walker and (entity.sprite.def.frames or 1) >= 6 then
    entity.worldSprite = nil -- deprecated adapter unused
    entity.spriteSource2D = "FOLLOW_SPRITES"
    entity.voxelSource = "FOLLOW_SPRITES"
    d.lastDefImage = entity.sprite.def.image
    local meshOk, meshErr, meshKey = RenderDiagnostics.probeMesh(entity.sprite.def, 0)
    d.lastMeshOk = meshOk
    d.lastMeshKey = meshKey
    if meshOk then
      d.meshOkObservations = (d.meshOkObservations or 0) + 1
      entity.worldBillboardReady = true
      entity.worldSpriteAdapterStatus = "NATIVE"
      entity.pokemonRenderer = R.NATIVE_SPRITE_RENDERER
      entity.depthIntegration = entity.depthIntegration or "UNVERIFIED"
      entity.objectOcclusion = entity.objectOcclusion or "UNVERIFIED"
      entity.grassRenderer = entity.grassRenderer or "UNVERIFIED"
      entity.dramaticBillboardSkipped = false
      d.lastFailureReason = nil
      return true, "NATIVE"
    end
    d.meshFailObservations = (d.meshFailObservations or 0) + 1
    d.lastFailureReason = meshErr
    if strict then
      entity.pokemonRenderer = R.TEMPORARILY_UNAVAILABLE
      entity.worldBillboardReady = false
      entity.dramaticBillboardSkipped = true
      entity.depthIntegration = "INACTIVE"
      entity.objectOcclusion = "INACTIVE"
      entity.grassRenderer = "NONE"
      return false, meshErr
    end
    -- Keep posing the native sprite anyway; DS may still draw if Assets works.
    entity.pokemonRenderer = R.NATIVE_SPRITE_RENDERER
    entity.worldBillboardReady = true
    entity.worldSpriteAdapterStatus = "NATIVE"
    entity.dramaticBillboardSkipped = false
    return true, "NATIVE_UNVERIFIED"
  end

  -- Legacy / black fallback SpriteRenderer (still a real sheet path).
  if entity.legacySprite then
    entity.sprite = entity.legacySprite
  end
  entity.worldSprite = nil
  entity.worldBillboardReady = true
  entity.worldSpriteAdapterStatus = "LEGACY"
  if entity.usingFallback then
    entity.pokemonRenderer = R.WORLD_BILLBOARD_BLACK_FALLBACK
    entity.spriteSource2D = "BLACK_FALLBACK"
  else
    entity.pokemonRenderer = R.WORLD_BILLBOARD_LEGACY
    entity.spriteSource2D = entity.spriteSource2D or "LEGACY_PNG"
  end
  local def = entity.sprite and entity.sprite.def
  local meshOk, meshErr, meshKey = RenderDiagnostics.probeMesh(def, 0)
  d.lastMeshOk = meshOk
  d.lastMeshKey = meshKey
  d.lastDefImage = def and def.image
  if meshOk then
    d.meshOkObservations = (d.meshOkObservations or 0) + 1
    entity.depthIntegration = "ACTIVE"
    entity.objectOcclusion = "ACTIVE"
    entity.dramaticBillboardSkipped = false
    entity.grassRenderer = "DRAMATIC_SHAPE_NATIVE"
  else
    entity.depthIntegration = "UNVERIFIED"
    entity.objectOcclusion = "UNVERIFIED"
    entity.dramaticBillboardSkipped = false
    entity.grassRenderer = "UNVERIFIED"
    d.lastFailureReason = meshErr
  end
  return true, "legacy"
end

-- Count Dramatic Shape resolveImage fetches without mutating def.image.
function SpawnRender:_instrumentResolveImage(entity, sprite)
  if not entity or not sprite or type(sprite.resolveImage) ~= "function" then
    return
  end
  if sprite._owwildResolveInstrumented then return end
  local orig = sprite.resolveImage
  sprite.resolveImage = function(self, ...)
    local d = RenderDiagnostics.ensure(entity)
    d.dramaticBillboardDrawAttempts = (d.dramaticBillboardDrawAttempts or 0) + 1
    d.lastDefImage = self.def and self.def.image
    local img = orig(self, ...)
    local dim = RenderDiagnostics.describeImage(img)
    d.lastResolvedImage = img
    d.lastResolvedType = dim.typeName
    d.lastResolvedW = dim.w
    d.lastResolvedH = dim.h
    if dim.w and dim.h then
      -- Full sheet is 16×96; DS UVs into a 16×16 frame.
      d.assetsImageOk = true
    end
    return img
  end
  sprite._owwildResolveInstrumented = true
end

-- Single simulation→presentation sync. Call from BehaviorTick (not Draw).
function SpawnRender:syncEntityAnimation(entity, dt)
  if not entity or entity.hiddenEncounter or not entity.visibleSprite then
    return false
  end
  entity.renderDirty = entity.renderDirty or {
    frame = false, direction = false, position = false,
    visibility = false, grassState = false,
  }

  Movement.syncLegacyFields(entity)
  local moving = Movement.isBusy(entity)
  entity.isMoving = moving == true

  -- Native path: SpriteRenderer derives the frame from facing/phase/flip.
  -- Keep light HUD animation fields in sync; never swap def.image or cards.
  if entity.animation then
    local prevDir = entity.animation.direction
    entity.animation.name = moving and "walk" or "idle"
    entity.animation.type = entity.animation.name
    entity.animation.direction = AnimatedSprites.normalizeFacing(entity.facing or "down")
    entity.animation.phase = entity.phase or 0
    entity.animation.flip = entity.stepFlip == true
    if prevDir ~= entity.animation.direction then
      entity.animation.directionChanged = true
      entity.renderDirty.direction = true
    end
  end

  if moving then
    entity.renderDirty.position = true
  end

  local R = SpawnRender.RENDERER
  if entity.nativeSpriteRenderer then
    if entity.pokemonRenderer ~= R.NATIVE_SPRITE_RENDERER
       or entity.worldBillboardReady ~= true then
      self:bindWorldBillboard(entity, false)
    end
    entity.spriteSource2D = "FOLLOW_SPRITES"
    entity.voxelSource = "FOLLOW_SPRITES"
    if entity.pokemonRenderer == R.NATIVE_SPRITE_RENDERER
       and RenderDiagnostics.honestDepthActive(entity) then
      entity.grassRenderer = "DRAMATIC_SHAPE_NATIVE"
    end
    return false
  end

  return false
end

function SpawnRender:refreshEnhancedScale(entity)
  if not entity then return end
  if entity.nativeSpriteRenderer then
    entity.visualScale = 1
    entity.final2DScale = 1
    entity.grassOcclusionHeight = entity.grassOcclusionHeight or 6
    entity.grassRenderMode = GrassOcclusion.mode(entity.mod)
    return
  end
  if not entity.usingEnhancedSprite or not self.animated then return end
  local dexId = entity.enhancedDexId
  local anim = entity.animation
  if not dexId or not anim then return end
  local variant = anim.variant or entity.spriteVariant or "normal"
  local frame = self.animated:getFrame(
    dexId, anim.name or anim.type, anim.direction, anim.frameIndex, variant)
  if not frame then return end
  local minSize = Config.get(self.mod, "min_sprite_size") or Config.DEFAULTS.min_sprite_size
  entity.scaleInfo = AnimatedSprites.calculateAnimatedSpriteScale(entity, frame, {
    minSpriteSizeOption = minSize,
    defaultGrassOcclusion = Config.DEFAULTS.grass_occlusion_px,
  })
  entity.visualScale = entity.scaleInfo.final2DScale or 1
  entity.final2DScale = entity.visualScale
  entity.grassOcclusionHeight = entity.scaleInfo.grassOcclusionHeight
    or GrassOcclusion.computeOcclusionHeight(
      (entity.scaleInfo.renderedH or CELL))
  entity.grassRenderMode = GrassOcclusion.mode(self.mod)
end

-- Live option toggle: re-bind presentation without respawning entities.
function SpawnRender:refreshAllEntitySprites(logic, game)
  if not logic or not logic.entities then return 0 end
  self:ensureStyleOwnedMakeEntity(game)
  if self.spriteResolver and self.spriteResolver.invalidateCache then
    self.spriteResolver:invalidateCache()
  end
  local n = 0
  for _, entity in pairs(logic.entities) do
    if entity then
      if not entity.hiddenEncounter and entity.visibleSprite ~= false
         and self:applyProviderSprite(entity, game) then
        n = n + 1
      end
    end
  end
  return n
end

-- Followers EX (priority 160) may wrap makeEntity on mods.loaded. Always
-- re-assert an outermost wrap so explicit Sprite Style wins on every spawn.
function SpawnRender:installLateMakeEntityWrap()
  local render = self
  local inner = self.makeEntity
  -- Avoid infinite self-wrap if we are already outermost with same inner.
  if self._styleWrapFn and self.makeEntity == self._styleWrapFn
     and self._styleWrapInner == inner then
    return true
  end
  -- If makeEntity is already our wrap, peel to the previous inner.
  if self._styleWrapFn and self.makeEntity == self._styleWrapFn then
    inner = self._styleWrapInner or inner
  end
  local function styleWrap(selfRef, game, record)
    local entity = inner(selfRef, game, record)
    if entity and not entity.hiddenEncounter and entity.visibleSprite ~= false then
      pcall(function()
        render:applyProviderSprite(entity, game)
      end)
    end
    return entity
  end
  self._styleWrapInner = inner
  self._styleWrapFn = styleWrap
  self.makeEntity = styleWrap
  self._providerMakeWrapped = true
  return true
end

function SpawnRender:finalizeSpriteProviders(game)
  if self.spriteProviders then
    self.spriteProviders:finalize(game)
  end
  self:installLateMakeEntityWrap()
end

-- Call before spawning so a late Followers wrap cannot stay outermost.
function SpawnRender:ensureStyleOwnedMakeEntity(game)
  if self.spriteProviders and game then
    pcall(function() self.spriteProviders:finalize(game) end)
  end
  self:installLateMakeEntityWrap()
end

function SpawnRender:countAnimatedEntities(logic)
  local n = 0
  if not logic or not logic.entities then return 0 end
  for _, entity in pairs(logic.entities) do
    if entity and (entity.nativeSpriteRenderer or entity.usingEnhancedSprite) then
      n = n + 1
    end
  end
  return n
end

return SpawnRender
