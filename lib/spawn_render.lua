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

local SpawnRender = {}
SpawnRender.__index = SpawnRender

local CELL = 16
local PLACEHOLDER_ID = "SPRITE_OW_WILD_PLACEHOLDER"
local FALLBACK_ID = "SPRITE_OW_WILD_FALLBACK"
local CACHE_DIR = "overworld_wild_spawns-cache"
local FALLBACK_REL = "assets/fallback/pokemon_missing.png"
local PLACEHOLDER_REL = "assets/spawn_placeholder.png"

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
  self.mod.log:info("[OverworldSpawn][INFO] %s", msg)
end

function SpawnRender:_warn(fmt, ...)
  local msg = fmt
  if select("#", ...) > 0 then
    msg = string.format(fmt, ...)
  end
  self.mod.log:info("[OverworldSpawn][WARN] %s", msg)
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

  self:_notice("Registered sprites: %d", registered)
  self:_notice("Missing real sprite sources at register: %d", missing)
  self:_notice("Fallback available: yes")
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
    self:_log("DRAMATIC_SHAPE present; using shared pose()/entities billboard path")
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
    info.voxel = "DRAMATIC_SHAPE present (pose billboard)"
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
  self.passable = true
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
  self.usingFallback = false
  self.entityPhase = "CREATING"
  self.surface = record.surface or Surface.GRASS
  self.encounterKind = record.encounterKind or "grass"
  self.visibleSprite = record.visibleSprite ~= false
  self.hiddenEncounter = record.hiddenEncounter == true
  self.inGrassOverlay = Surface.usesGrassOverlay(self.surface)
  self.scaleInfo = nil
  self.visualScale = 1
  self.waterSink = (self.surface == Surface.WATER) and 2 or 0
  self.assetInfo = nil

  -- Hidden encounters never load a Pokemon sprite / fallback.
  if self.hiddenEncounter or not self.visibleSprite then
    self.sprite = nil
    self.spriteId = nil
    self.entityPhase = "HIDDEN"
    self.usingFallback = false
    self.visualScale = 1
    self.scaleInfo = {
      scale = 1, contentW = 0, contentH = 0,
      renderedW = 0, renderedH = 0, originalW = 0, originalH = 0,
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

  if self.sprite and self.sprite.image and self.sprite.image.setFilter then
    self.sprite.image:setFilter("nearest", "nearest")
  end

  -- Bounds-aware visual scale (collision stays one cell).
  local minSize = Config.get(mod, "min_sprite_size") or Config.DEFAULTS.min_sprite_size
  self.scaleInfo = SpriteScale.compute(record.species,
    self.sprite and self.sprite.image, { minSpriteSizeOption = minSize })
  self.visualScale = self.scaleInfo.scale or 1
  return self
end

function Entity:setCell(x, y)
  self.cellX = x
  self.cellY = y
  self.px = x * CELL
  self.py = y * CELL
  -- Refresh grass-overlay flag from live map when available.
  local world = self.mod.world
  local ow = world and world.overworld and world:overworld()
  if ow and ow.map and ow.map.isGrassCell then
    self.inGrassOverlay = ow.map:isGrassCell(x, y)
      and Config.get(self.mod, "show_pokemon_in_grass") ~= false
  end
end

function Entity:pose()
  -- Feet stay on the cell; water mons sink slightly. No artificial tuck —
  -- Gen1Recomp drawCellBottom overdraws feet for every entity on grass.
  local visualY = self.py + (self.tuck or 0) + (self.waterSink or 0)
  return self.sprite, self.px, visualY, self.facing, 0, false, false
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

function Entity:_drawScaledSprite(camX, camY, opacity)
  local sprite = self.sprite
  if not sprite or not sprite.image then return end
  local scale = self.visualScale or 1
  local img = sprite.image
  if img.setFilter then img:setFilter("nearest", "nearest") end

  -- SpriteRenderer draws at (px - camX, py - camY - 4). Match that anchor,
  -- feet-biased: larger scales grow upward so grass overdraw still covers feet.
  local baseX = math.floor(self.px - (camX or 0))
  local baseY = math.floor(self.py + (self.tuck or 0) + (self.waterSink or 0)
                           - (camY or 0) - 4)
  local drawW = CELL * scale
  local drawH = CELL * scale
  local dx = baseX - (drawW - CELL) * 0.5
  local dy = baseY - (drawH - CELL) -- grow up from feet

  local flip = (self.facing == "left")
  if opacity < 1 then love.graphics.setColor(1, 1, 1, opacity) end
  if flip then
    love.graphics.draw(img, dx + drawW, dy, 0, -scale, scale)
  else
    love.graphics.draw(img, dx, dy, 0, scale, scale)
  end
  if opacity < 1 then love.graphics.setColor(1, 1, 1, 1) end

  -- Mark true-color rect roughly covering the sprite when PaletteFX exists.
  local ok, PaletteFX = pcall(require, "src.render.PaletteFX")
  if ok and PaletteFX and PaletteFX.markTrueColor then
    PaletteFX.markTrueColor(dx, dy, drawW, drawH)
  end
end

function Entity:draw(camX, camY)
  if self.hiddenEncounter or not self.visibleSprite then
    self:_drawHiddenEffect(camX, camY)
  else
    local opacity = Config.get(self.mod, "sprite_opacity") or 1
    local scale = self.visualScale or 1
    if love and love.graphics and (scale ~= 1 or self.facing == "left" or self.facing == "right") then
      self:_drawScaledSprite(camX, camY, opacity)
    else
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

return SpawnRender
