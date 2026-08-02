-- Presentational half of overworld_wild_spawns.
-- Base Gen1Recomp path: SpriteRenderer + pose()/draw() on OverworldState.entities.
-- DramaticShapeVoxelMod is optional: when VOXEL is active it billboards via pose().
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
--
-- Temporary overworld presentation: Gen1 battle-front sprites (scaled to
-- 16x16) are used when no dedicated overworld PNG ships with the mod.
local V = ...
local Config = V.require("config")
local DebugLog = V.require("debug_log")
local SpriteScale = V.require("sprite_scale")
local Behavior = V.require("behavior")
local Surface = V.require("surface")
local Tile = V.require("tile")
local Movement = V.require("movement")
local AnimatedSprites = V.require("animated_sprites")
local GrassOcclusion = V.require("grass_occlusion")
local EnhancedWorldSprite = V.require("enhanced_world_sprite")
local RenderDiagnostics = V.require("render_diagnostics")

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

-- Render status taxonomy (voxel world billboard path).
SpawnRender.RENDERER = {
  WORLD_BILLBOARD_ENHANCED = "WORLD_BILLBOARD_ENHANCED",
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
  if pokemon and pokemon.each then
    for speciesId, def in pokemon:each() do
      local spriteId = spriteIdForSpecies(speciesId)
      local front = def and def.spriteFront
      local imagePath = fallbackPath
      local kind = "fallback"
      local source = nil

      if type(front) == "string" and front ~= "" and not isOsAbsolutePath(front) then
        source = front
        imagePath = front
        kind = "battle_front"
        -- Prefer a baked 16x16 sheet when the graphics stack is already up
        -- (real love.load). Headless tests keep the battle-front path.
        local baked = bakeSheet(speciesId, front, function(fmt, ...)
          self:_log(fmt, ...)
        end)
        if baked then
          imagePath = baked
          kind = "generated_overworld"
        end
      else
        -- Still register a sprite id so runtime spawn can use fallback.
        missing = missing + 1
      end

      local ok, err = self:_registerSprite(spriteId, {
        image = imagePath,
        frames = 1,
        trueColor = true,
      })
      if ok then
        self.speciesSpriteIds[speciesId] = spriteId
        self.registrationInfo[speciesId] = {
          spriteId = spriteId,
          image = imagePath,
          source = source,
          kind = kind,
          status = (kind == "fallback") and "FALLBACK_REGISTERED" or "REGISTERED",
        }
        registered = registered + 1
      else
        missing = missing + 1
        self.registrationInfo[speciesId] = {
          spriteId = nil,
          status = "REGISTER_ERROR",
          lastError = tostring(err),
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

  self:_notice("Registered sprites: %d", registered)
  self:_notice("Missing real sprite sources at register: %d", missing)
  self:_notice("Fallback available: yes")
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
  Movement.init(self, record.x, record.y, self.facing)

  -- Hidden encounters never load a Pokemon sprite / fallback and must not
  -- join ow.entities (VoxelScene would retire the pipeline on nil sprite).
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

  -- Prefer resolved runtime path (baked relative cache, battle front, or
  -- fallback). Never feed OS absolute paths to SpriteRenderer.
  local drawPath = spriteDef.image
  if resolved and resolved.path and not isOsAbsolutePath(resolved.path) then
    drawPath = resolved.path
  elseif runtime and runtime.bakedPath and not isOsAbsolutePath(runtime.bakedPath) then
    drawPath = runtime.bakedPath
  end
  if isOsAbsolutePath(drawPath) then
    drawPath = (render.fallbackPath or render:_fallbackPath())
    self.usingFallback = true
    self.entityPhase = "ASSET_LOAD_ERROR"
    DebugLog.error(mod,
      "refusing OS absolute sprite path for %s; using fallback",
      tostring(record.species))
  end

  local function buildDef(id, path)
    return {
      image = path,
      frames = 1,
      trueColor = true,
      id = id,
    }
  end

  local drawDef = buildDef(spriteId, drawPath)

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
      fbDef = buildDef(fbId, render.fallbackPath or render:_fallbackPath())
    end
    local okFb, fbSpriteOrErr = pcall(SpriteRenderer.new, fbDef, self.spawnId)
    if not okFb then
      self.entityPhase = "ENTITY_CREATE_ERROR"
      error("ENTITY CREATE ERROR: " .. tostring(fbSpriteOrErr), 0)
    end
    self.sprite = fbSpriteOrErr
    self.spriteId = fbId
    self.usingFallback = true
    self.entityPhase = "FALLBACK_LOADED"
  else
    self.sprite = spriteOrErr
    self.spriteId = spriteId
    if self.usingFallback then
      self.entityPhase = "FALLBACK_LOADED"
    else
      self.entityPhase = "REAL_ASSET_LOADED"
    end
  end

  -- Immutable legacy SpriteRenderer reference (never wrap/mutate for voxel).
  self.legacySprite = self.sprite
  if self.usingFallback then
    self.blackFallbackSprite = self.sprite
  end
  self.worldSprite = nil
  self.worldBillboardReady = false
  self.worldSpriteAdapterStatus = "N/A"
  self.grassRenderer = "ENGINE_2D"

  if self.sprite and self.sprite.image and self.sprite.image.setFilter then
    self.sprite.image:setFilter("nearest", "nearest")
  end

  -- Single final 2D scale: readability floor capped by one-tile maximum.
  -- Camera zoom is applied by the engine separately and must not be folded in.
  local minSize = Config.get(mod, "min_sprite_size") or Config.DEFAULTS.min_sprite_size
  self.scaleInfo = SpriteScale.compute(record.species,
    self.sprite and self.sprite.image, { minSpriteSizeOption = minSize })
  self.visualScale = self.scaleInfo.final2DScale or self.scaleInfo.scale or 1
  self.final2DScale = self.visualScale
  self.grassOcclusionHeight = self.scaleInfo.grassOcclusionHeight or 0
  self.voxelScale = 1

  -- Optional enhanced atlas animation (identity = dex / speciesId only).
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
  local worldBillboard = pokemonRenderer == SpawnRender.RENDERER.WORLD_BILLBOARD_ENHANCED
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
  return (self.py or 0) + tuck + (self.waterSink or 0)
end

-- Priority: Enhanced world adapter → legacy species → black fallback.
function Entity:getWorldSprite()
  if self.hiddenEncounter or self.visibleSprite == false then
    return nil
  end
  -- Only use the enhanced adapter when THIS entity's bind succeeded,
  -- or when strict debug forces the enhanced path (no silent legacy).
  if self.worldSprite
     and self.animation
     and self.animation.source == "FOLLOW_SPRITES"
     and self.usingEnhancedSprite then
    if self.worldBillboardReady == true
       or RenderDiagnostics.strictEnabled(self.mod) then
      return self.worldSprite
    end
  end
  if self.legacySprite then
    return self.legacySprite
  end
  if self.blackFallbackSprite then
    return self.blackFallbackSprite
  end
  return self.sprite
end

function Entity:pose()
  -- Contract expected by Gen1Recomp + DramaticShapeVoxelMod VoxelScene.posesOf:
  --   sprite, visualX, visualY, facing, phase, flip [, hop]
  Movement.syncLegacyFields(self)
  local sprite = self:getWorldSprite()
  local d = RenderDiagnostics.ensure(self)
  d.poseCalls = (d.poseCalls or 0) + 1
  d.lastPoseSpriteType = RenderDiagnostics.spriteTypeName(sprite)
  if sprite and sprite.def then
    d.lastDefImage = sprite.def.image
  end
  if sprite == nil then
    d.lastFailureReason = "pose() nil sprite"
    return nil, self.px or 0, self.py or 0, self.facing or "down", 0, false, false
  end
  local visualY = self:calculateVisualY()
  self._lastVisualY = visualY
  self._lastLift = (self.py or 0) - visualY
  return sprite, self.px or 0, visualY, self.facing or "down", 0, false, false
end

-- When Dramatic Shape owns the body as a world billboard, Entity:draw must
-- not paint a second body (that would sit on top of grass with no depth).
function Entity:_voxelBillboardOwnsBody()
  if self.worldRenderer ~= "DRAMATIC_SHAPE" then return false end
  local r = self.pokemonRenderer
  return r == SpawnRender.RENDERER.WORLD_BILLBOARD_ENHANCED
    or r == SpawnRender.RENDERER.WORLD_BILLBOARD_LEGACY
    or r == SpawnRender.RENDERER.WORLD_BILLBOARD_BLACK_FALLBACK
end

function Entity:_strictHidesBody()
  return RenderDiagnostics.strictEnabled(self.mod)
    and self.worldRenderer == "DRAMATIC_SHAPE"
end

function Entity:_drawHiddenEffect(camX, camY)
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
  local baseY = math.floor(self.py + tuck + (self.waterSink or 0)
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
  if self.usingEnhancedSprite then
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
  local baseY = math.floor(self.py + tuck + (self.waterSink or 0)
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
  local d = RenderDiagnostics.ensure(self)
  local skipBody = false
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

  if self.hiddenEncounter or not self.visibleSprite then
    self:_drawHiddenEffect(camX, camY)
  elseif not skipBody then
    d.entityDrawBodyCalls = (d.entityDrawBodyCalls or 0) + 1
    if self.worldRenderer == "DRAMATIC_SHAPE" then
      d.postVoxelBodyDrawCalls = (d.postVoxelBodyDrawCalls or 0) + 1
    end
    local opacity = Config.get(self.mod, "sprite_opacity") or 1
    local scale = self.final2DScale or self.visualScale or 1
    if self.usingEnhancedSprite then
      self:_drawAnimatedSprite(camX, camY, opacity)
    elseif love and love.graphics and (scale ~= 1 or self.facing == "left"
        or self.facing == "right"
        or (self.scaleInfo and (self.scaleInfo.offsetX or 0) ~= 0)) then
      d.legacySpriteDrawCalls = (d.legacySpriteDrawCalls or 0) + 1
      self:_drawScaledSprite(camX, camY, opacity)
    else
      d.legacySpriteDrawCalls = (d.legacySpriteDrawCalls or 0) + 1
      local sprite, px, py, facing, phase, flip = self:pose()
      if sprite then
        if opacity < 1 and love and love.graphics and love.graphics.setColor then
          love.graphics.setColor(1, 1, 1, opacity)
          sprite:draw(px, py, camX, camY, facing, phase, flip)
          love.graphics.setColor(1, 1, 1, 1)
        else
          sprite:draw(px, py, camX, camY, facing, phase, flip)
        end
      end
    end

    -- Spatial emergency overlay only: world billboards get DS tall-grass.
    -- Never draw custom grass for WORLD_BILLBOARD_* success paths.
    local emergency = self.pokemonRenderer == SpawnRender.RENDERER.SPATIAL_OVERLAY_EMERGENCY
      or self.pokemonRenderer == "SPATIAL_OVERLAY_FALLBACK"
    if emergency and not RenderDiagnostics.strictEnabled(self.mod)
       and GrassOcclusion.shouldOcclude(self, self.mod) then
      local world = self.mod and self.mod.world
      local ow = world and world.overworld and world:overworld()
      GrassOcclusion.drawForeground(self, camX, camY, ow and ow.map)
    end
  end

  -- Optional debug marker (dev mode): outline + species / behaviour.
  if self.render.debugMarkers and Config.devMode(self.mod)
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
    self:_drawBehaviorOverlay(camX, camY)
  end
end

function Entity:_drawBehaviorOverlay(camX, camY)
  local x = math.floor(self.px - (camX or 0))
  local y = math.floor(self.py - (camY or 0))
  local bx = self.behaviorState
  if self.homeRegion then
    love.graphics.setColor(0.2, 0.7, 1.0, 0.12)
    for _, t in ipairs(self.homeRegion.tiles or {}) do
      love.graphics.rectangle("fill",
        t.x * CELL - (camX or 0), t.y * CELL - (camY or 0), CELL, CELL)
    end
  end
  if self.behavior == Behavior.AGGRESSIVE and bx then
    local range = Config.DEFAULTS.aggressive_sight_range or 4
    local dx, dy = 0, 0
    local f = bx.facing or self.facing or "down"
    if f == "up" then dy = -1 elseif f == "down" then dy = 1
    elseif f == "left" then dx = -1 elseif f == "right" then dx = 1 end
    love.graphics.setColor(1, 0.85, 0.1, 0.22)
    for i = 1, range do
      love.graphics.rectangle("fill",
        x + dx * i * CELL, y + dy * i * CELL, CELL, CELL)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
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

function SpawnRender:attachEnhancedToEntity(entity, game)
  if not entity or entity.hiddenEncounter or not entity.visibleSprite then
    return false
  end
  entity.animation = entity.animation or nil
  entity.usingEnhancedSprite = false
  entity.enhancedDexId = nil
  entity.spriteSource = entity.usingFallback and "BLACK_FALLBACK" or "LEGACY_PNG"
  entity.worldBillboardReady = false
  entity.worldSpriteAdapterStatus = "N/A"
  entity.renderDirty = entity.renderDirty or {
    frame = false, direction = false, position = false,
    visibility = false, grassState = false,
  }

  if not self:animatedEnabled() then
    -- Keep any prior worldSprite idle; point presentation at legacy.
    if entity.legacySprite then
      entity.sprite = entity.legacySprite
    end
    entity.worldSprite = nil
    return false
  end

  local enh = self:enhancedStatusFor(entity.species, game)
  entity.enhancedDexId = enh.dexId
  entity.enhancedStatus = enh.status
  if not enh.available then
    if enh.dexId then
      self.animated:logFallbackOnce(enh.dexId, "using legacy PNG")
    end
    if entity.legacySprite then
      entity.sprite = entity.legacySprite
    end
    entity.worldSprite = nil
    return false
  end

  local variant = AnimatedSprites.resolveRuntimeVariant(entity)
  if variant == "shiny" and not self.animated:hasVariant(enh.dexId, "shiny") then
    variant = "normal"
  end
  entity.spriteVariant = variant
  entity.usingEnhancedSprite = true
  entity.spriteSource = "FOLLOW_SPRITES"
  entity.spriteSource2D = "FOLLOW_SPRITES"
  entity.voxelSource = "FOLLOW_SPRITES"
  if not entity.animation or not entity.animation.usingEnhancedSprite then
    entity.animation = self.animated:newAnimationState(entity.facing or "down")
  end
  entity.animation.usingEnhancedSprite = true
  entity.animation.fallbackLevel = enh.status
  entity.animation.source = "FOLLOW_SPRITES"
  entity.animation.variant = variant
  entity.animation.renderRevision = entity.animation.renderRevision or 0
  self:refreshEnhancedScale(entity)
  self:bindWorldBillboard(entity, true)
  return true
end

-- Bind stable EnhancedWorldSprite; never mutate legacySprite.def / resolveImage.
-- ENHANCED is only claimed after card READY + Assets.image(def.image) + mesh probe.
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

  if not entity.usingEnhancedSprite or not entity.animation or not self.animated then
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
    -- Honest flags only after mesh/assets probe for legacy def.
    local def = entity.sprite and entity.sprite.def
    local meshOk, meshErr, meshKey = RenderDiagnostics.probeMesh(def, 0)
    d.lastMeshOk = meshOk
    d.lastMeshKey = meshKey
    d.lastDefImage = def and def.image
    if meshOk then
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

  -- Prefer transparent base; fall back to the always-registered missing PNG
  -- carrier so Assets.image always has a real mods/... path.
  local basePath = self:_billboardBasePath()
  local fbPath = self.fallbackPath or self:_fallbackPath()
  if type(basePath) ~= "string" or basePath == "" then
    basePath = fbPath
  end
  -- Validate carrier is loadable; if base fails, use fallback path.
  local okBase = RenderDiagnostics.probeAssetsImage(basePath)
  if not okBase and fbPath and fbPath ~= basePath then
    basePath = fbPath
    okBase = RenderDiagnostics.probeAssetsImage(basePath)
  end
  if not okBase or type(basePath) ~= "string" or basePath == "" then
    d.lastFailureReason = "no loadable def.image carrier path"
    entity.worldBillboardReady = false
    entity.worldSpriteAdapterStatus = "PERMANENT_INVALID"
    if strict then
      entity.pokemonRenderer = R.TEMPORARILY_UNAVAILABLE
      entity.depthIntegration = "INACTIVE"
      entity.objectOcclusion = "INACTIVE"
      entity.dramaticBillboardSkipped = true
      entity.grassRenderer = "NONE"
      entity.spriteSource2D = "FOLLOW_SPRITES"
      return false, d.lastFailureReason
    end
    entity.pokemonRenderer = R.SPATIAL_OVERLAY_EMERGENCY
    entity.depthIntegration = "INACTIVE"
    entity.objectOcclusion = "INACTIVE"
    entity.dramaticBillboardSkipped = true
    entity.grassRenderer = "EMERGENCY_OVERLAY"
    entity.spriteSource2D = "FOLLOW_SPRITES"
    return false, d.lastFailureReason
  end

  if not entity.worldSprite then
    entity.worldSprite = EnhancedWorldSprite.new({
      entity = entity,
      animatedSprites = self.animated,
      legacySprite = entity.legacySprite,
      baseImagePath = basePath,
      id = "SPRITE_OW_WILD_ENH_" .. tostring(entity.enhancedDexId or entity.species),
      seed = entity.id or entity.spawnId,
    })
  else
    entity.worldSprite.entity = entity
    entity.worldSprite.animatedSprites = self.animated
    entity.worldSprite.legacySprite = entity.legacySprite
    entity.worldSprite:setBaseImagePath(basePath)
  end

  entity.sprite = entity.worldSprite
  d.lastDefImage = basePath

  local key = self.animated:getCurrentBillboardKey(entity)
  local result = self.animated:prepareBillboardImage(entity, key)

  entity.voxelCardKey = key
  entity._voxelCardKey = key

  local function markEmergency(reason, status)
    entity.worldBillboardReady = false
    entity.worldSpriteAdapterStatus = status or "TEMPORARILY_UNAVAILABLE"
    entity.depthIntegration = "INACTIVE"
    entity.objectOcclusion = "INACTIVE"
    entity.dramaticBillboardSkipped = true
    entity.spriteSource2D = "FOLLOW_SPRITES"
    entity.voxelSource = "FOLLOW_SPRITES"
    d.lastFailureReason = reason
    if strict then
      -- Strict: stay invisible rather than paper over with overlay.
      entity.pokemonRenderer = R.TEMPORARILY_UNAVAILABLE
      entity.grassRenderer = "NONE"
      return false, reason
    end
    entity.pokemonRenderer = R.SPATIAL_OVERLAY_EMERGENCY
    entity.grassRenderer = "EMERGENCY_OVERLAY"
    return false, reason
  end

  if type(result) ~= "table" then
    return markEmergency("prepareBillboardImage non-table", "TEMPORARILY_UNAVAILABLE")
  end

  entity.voxelCardStatus = result.status
  entity.voxelCardReason = result.reason
  entity.voxelCardType = result.type
  entity.voxelCardSize = result.width
    and string.format("%dx%d", result.width, result.height) or "16x16"
  entity.voxelFrameCacheStatus =
    (result._fromCache and "HIT") or (result.status == "READY" and "READY") or result.status

  if result.status ~= "READY" or not result.image then
    if result.status == "TEMPORARILY_UNAVAILABLE"
       or result.status == "VOXEL_CARD_BUILD_ERROR" then
      return markEmergency(tostring(result.status), "TEMPORARILY_UNAVAILABLE")
    end
    -- Permanent enhanced miss → legacy world billboard (still depth path).
    entity.sprite = entity.legacySprite or entity.sprite
    entity.worldSprite = nil
    entity.worldBillboardReady = true
    entity.worldSpriteAdapterStatus = "PERMANENT_INVALID"
    entity.pokemonRenderer = entity.usingFallback
      and R.WORLD_BILLBOARD_BLACK_FALLBACK or R.WORLD_BILLBOARD_LEGACY
    entity.depthIntegration = "ACTIVE"
    entity.objectOcclusion = "ACTIVE"
    entity.dramaticBillboardSkipped = false
    entity.grassRenderer = "DRAMATIC_SHAPE_NATIVE"
    entity.voxelSource = entity.usingFallback and "BLACK_FALLBACK" or "LEGACY_PNG"
    d.lastFailureReason = tostring(result.status)
    return false, result.status
  end

  -- Card ready — still require DS mesh carrier to resolve.
  local meshOk, meshErr, meshKey = RenderDiagnostics.probeMesh(entity.worldSprite.def, 0)
  d.lastMeshOk = meshOk
  d.lastMeshKey = meshKey
  if not meshOk then
    -- Try fallback carrier once more on the existing adapter.
    if fbPath and fbPath ~= basePath then
      entity.worldSprite:setBaseImagePath(fbPath)
      meshOk, meshErr, meshKey = RenderDiagnostics.probeMesh(entity.worldSprite.def, 0)
      d.lastMeshOk = meshOk
      d.lastMeshKey = meshKey
      d.lastDefImage = fbPath
    end
  end
  if not meshOk then
    return markEmergency(
      "SpriteBillboards mesh unavailable: " .. tostring(meshErr),
      "TEMPORARILY_UNAVAILABLE")
  end

  entity.worldBillboardReady = true
  entity.worldSpriteAdapterStatus = "READY"
  entity.pokemonRenderer = R.WORLD_BILLBOARD_ENHANCED
  -- Honest depth/grass only once actual path is proven at runtime via counters.
  -- Until pose+resolveImage+mesh observations exist, mark UNVERIFIED not ACTIVE.
  entity.depthIntegration = "UNVERIFIED"
  entity.objectOcclusion = "UNVERIFIED"
  entity.grassRenderer = "UNVERIFIED"
  entity.dramaticBillboardSkipped = false
  entity.spriteSource2D = "FOLLOW_SPRITES"
  entity.voxelSource = "FOLLOW_SPRITES"
  entity.voxelLastError = nil
  d.lastFailureReason = nil
  return true, "READY"
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

  if not entity.usingEnhancedSprite or not entity.animation or not self.animated then
    return false
  end

  local progress = nil
  if moving and entity.movement and entity.movement.duration
     and entity.movement.duration > 0 then
    progress = (entity.movement.progress or 0) / entity.movement.duration
  end

  local prevRev = entity.animation.renderRevision or 0
  local changed = self.animated:updateAnimation(
    entity.animation,
    entity.enhancedDexId,
    dt or 0,
    moving,
    entity.facing or "down",
    progress)

  if entity.animation.directionChanged then
    entity.renderDirty.direction = true
  end
  if entity.animation.frameChanged or changed then
    entity.renderDirty.frame = true
  end
  if moving then
    entity.renderDirty.position = true
  end

  self:refreshEnhancedScale(entity)

  local R = SpawnRender.RENDERER
  local needBind = entity.renderDirty.frame or entity.renderDirty.direction
    or entity.pokemonRenderer ~= R.WORLD_BILLBOARD_ENHANCED
    or entity.worldBillboardReady ~= true
    or (entity.animation.renderRevision or 0) ~= prevRev
  if needBind then
    self:bindWorldBillboard(entity, false)
    entity.renderDirty.frame = false
    entity.renderDirty.direction = false
  end
  entity.spriteSource2D = "FOLLOW_SPRITES"
  if entity.pokemonRenderer == R.WORLD_BILLBOARD_ENHANCED then
    entity.voxelSource = "FOLLOW_SPRITES"
    entity.grassRenderer = "DRAMATIC_SHAPE_NATIVE"
  end
  return changed
end

function SpawnRender:refreshEnhancedScale(entity)
  if not entity or not entity.usingEnhancedSprite or not self.animated then return end
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
  local n = 0
  for _, entity in pairs(logic.entities) do
    if entity and not entity.hiddenEncounter and entity.visibleSprite ~= false then
      local wasEnhanced = entity.usingEnhancedSprite == true
      self:attachEnhancedToEntity(entity, game)
      if wasEnhanced and not entity.usingEnhancedSprite then
        -- Restore legacy scale from the still-held SpriteRenderer image.
        local minSize = Config.get(self.mod, "min_sprite_size") or Config.DEFAULTS.min_sprite_size
        entity.scaleInfo = SpriteScale.compute(entity.species,
          entity.legacySprite and entity.legacySprite.image
            or (entity.sprite and entity.sprite.image),
          { minSpriteSizeOption = minSize })
        entity.visualScale = entity.scaleInfo.final2DScale or entity.scaleInfo.scale or 1
        entity.final2DScale = entity.visualScale
        entity.grassOcclusionHeight = entity.scaleInfo.grassOcclusionHeight or 0
        entity.animation = nil
        entity.worldSprite = nil
        entity.sprite = entity.legacySprite
        entity.worldBillboardReady = true
        entity.worldSpriteAdapterStatus = "LEGACY"
      end
      n = n + 1
    end
  end
  return n
end

function SpawnRender:countAnimatedEntities(logic)
  local n = 0
  if not logic or not logic.entities then return 0 end
  for _, entity in pairs(logic.entities) do
    if entity and entity.usingEnhancedSprite then n = n + 1 end
  end
  return n
end

return SpawnRender
