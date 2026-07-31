-- Presentational half of overworld_wild_spawns.
-- Base Gen1Recomp path: SpriteRenderer + pose()/draw() on OverworldState.entities.
-- DramaticShapeVoxelMod is optional: when VOXEL is active it billboards via pose().
--
-- Lifecycle (non-negotiable):
--   LOAD:  registerContent() writes mod.content.sprites once, builds lookup
--   RUNTIME: spriteIdFor / makeEntity / preview only look up + cache images
--
-- Gen1Recomp freezes content registries after all mods load. Never call
-- register/override/patch/remove from testSpawn, preview, map callbacks, etc.
local V = ...
local Config = V.require("config")
local DebugLog = V.require("debug_log")

local SpawnRender = {}
SpawnRender.__index = SpawnRender

local CELL = 16
local PLACEHOLDER_ID = "SPRITE_OW_WILD_PLACEHOLDER"

local function tryRequire(name)
  local ok, modOrErr = pcall(require, name)
  if ok then return modOrErr, nil end
  return nil, modOrErr
end

local function spriteIdForSpecies(species)
  return "SPRITE_OW_WILD_" .. tostring(species)
end

-- Runtime-only bake: writes a 16x16 sheet into the save cache. Never touches
-- content registries. Returns a filesystem path or nil.
local function bakeSheet(species, sourcePath, log)
  if not (love and love.graphics and love.image) then return nil end
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

  local dirOk, dirErr = pcall(love.filesystem.createDirectory, "overworld_wild_spawns-cache")
  if not dirOk and log then
    log("cache dir create failed: %s", tostring(dirErr))
  end
  local rel = "overworld_wild_spawns-cache/" .. tostring(species):lower() .. ".png"
  local fileData = idata:encode("png")
  if not fileData then return nil end
  love.filesystem.write(rel, fileData:getString())
  if love.filesystem.getSaveDirectory then
    return love.filesystem.getSaveDirectory() .. "/" .. rel
  end
  return rel
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
  self.placeholderId = nil
  self.rendererMode = "base"
  self.lastError = nil
  self.contentRegistrationOpen = true
  self.registeredCount = 0
  self.missingCount = 0
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

-- LOAD PHASE only. Must finish before Gen1Recomp freezes content registries.
function SpawnRender:registerContent()
  if not self.contentRegistrationOpen then
    return nil, "Attempted content registration after mod initialization"
  end

  self:_notice("Registering overworld sprite definitions")

  local placeholderPath = self.mod.assets:path("spawn_placeholder.png")
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

  local registered, missing = 0, 0
  local pokemon = self.mod.content and self.mod.content.pokemon
  if pokemon and pokemon.each then
    for speciesId, def in pokemon:each() do
      local spriteId = spriteIdForSpecies(speciesId)
      local front = def and def.spriteFront
      if type(front) == "string" and front ~= "" then
        -- Prefer a baked 16x16 sheet when the graphics stack is already up
        -- (real love.load). Headless tests keep the battle-front path.
        local imagePath = front
        local kind = "battle_front"
        local baked = bakeSheet(speciesId, front, function(fmt, ...)
          self:_log(fmt, ...)
        end)
        if baked then
          imagePath = baked
          kind = "generated_overworld"
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
            source = front,
            kind = kind,
            status = "REGISTERED",
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
      else
        missing = missing + 1
        self.registrationInfo[speciesId] = {
          spriteId = nil,
          status = "ASSET_MISSING",
          lastError = "no battle front or overworld sprite",
        }
      end
    end
  end

  self.registeredCount = registered
  self.missingCount = missing
  self.contentRegistrationOpen = false

  self:_notice("Registered sprites: %d", registered)
  self:_notice("Missing sprite assets: %d", missing)
  self:_notice("Content registration complete")
  return true
end

function SpawnRender:isContentRegistrationOpen()
  return self.contentRegistrationOpen == true
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
function SpawnRender:spriteIdFor(species)
  if species == nil then
    return nil, "species id is required"
  end
  local spriteId = self.speciesSpriteIds[species]
  if not spriteId then
    DebugLog.warn(self.mod,
      "species=%s has no pre-registered overworld sprite", tostring(species))
    return nil, "No pre-registered overworld sprite for species " .. tostring(species)
  end
  DebugLog.debug(self.mod, "species=%s spriteId=%s", tostring(species), tostring(spriteId))
  return spriteId
end

-- Runtime asset resolution / bake cache. Never touches content registries.
function SpawnRender:getRuntimeImage(species, game)
  if self.runtimeImageCache[species] then
    return self.runtimeImageCache[species]
  end
  local spriteId = self.speciesSpriteIds[species]
  local reg = self.registrationInfo[species]
  local contentDef = nil
  if spriteId then
    contentDef = (game and game.data and game.data.sprites and game.data.sprites[spriteId])
              or (self.mod.content.sprites and self.mod.content.sprites:get(spriteId))
  end
  local sourcePath = (reg and reg.source)
                  or (contentDef and contentDef.image)
                  or (reg and reg.image)
  local entry = {
    spriteId = spriteId,
    registeredImage = contentDef and contentDef.image or (reg and reg.image),
    sourcePath = sourcePath,
    bakedPath = nil,
    status = "NOT_AVAILABLE",
    kind = reg and reg.kind or nil,
  }
  if not spriteId then
    entry.status = "ASSET_MISSING"
    self.runtimeImageCache[species] = entry
    return entry
  end
  if reg and reg.kind == "generated_overworld" and reg.image then
    entry.bakedPath = reg.image
    entry.status = "LOADED"
    entry.kind = "generated_overworld"
    self.runtimeImageCache[species] = entry
    return entry
  end
  if sourcePath then
    local baked = bakeSheet(species, sourcePath, function(fmt, ...)
      self:_log(fmt, ...)
    end)
    if baked then
      entry.bakedPath = baked
      entry.status = "LOADED"
      entry.kind = "generated_overworld"
    else
      -- Registered battle-front (or other) path is still a usable draw source.
      entry.status = "LOADED"
      entry.kind = entry.kind or "battle_front"
    end
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
  local info = {
    species = species,
    battleFront = def and def.spriteFront or (reg and reg.source) or nil,
    battleBack = def and def.spriteBack or nil,
    menuIcon = def and def.icon or nil,
    overworldSprite = nil,
    generatedOverworld = runtime.bakedPath,
    voxel = nil,
    overworldKind = runtime.kind,
    spriteRegistered = self.speciesSpriteIds[species] ~= nil,
    spriteId = self.speciesSpriteIds[species],
    registration = reg and reg.status or "ASSET_MISSING",
    runtimeStatus = runtime.status,
    status = "MISSING",
    renderer = "UNKNOWN",
    entityReady = false,
    lastError = reg and reg.lastError or nil,
  }

  if info.spriteRegistered and runtime.status == "LOADED" then
    if runtime.kind == "generated_overworld" then
      info.overworldSprite = runtime.bakedPath or runtime.registeredImage
      info.overworldKind = "generated_overworld"
      info.status = "LOADED"
    elseif runtime.kind == "battle_front" then
      info.overworldSprite = runtime.registeredImage or runtime.sourcePath
      info.overworldKind = "battle_front"
      -- Battle fronts are a valid registered overworld representation for
      -- this mod (scaled at draw via SpriteRenderer / optional bake).
      info.status = "LOADED"
    else
      info.overworldSprite = runtime.registeredImage
      info.status = "LOADED"
    end
  elseif info.spriteRegistered then
    info.status = "REGISTERED"
    info.lastError = info.lastError or "registered but runtime asset not loaded"
  else
    info.status = "MISSING"
    info.lastError = info.lastError
      or ("No pre-registered overworld sprite for species " .. tostring(species))
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

  info.entityReady = info.spriteRegistered == true and info.status == "LOADED"
  self.assetInfo[species] = info
  return info
end

function SpawnRender:countAssets(speciesList, game)
  local required, loaded = 0, 0
  for _, species in ipairs(speciesList or {}) do
    required = required + 1
    local info = self:assetStatusFor(species, game)
    if info.status == "LOADED" then
      loaded = loaded + 1
    end
  end
  return required, loaded
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
  self.facing = "down"
  self.mod = mod
  self.render = render
  self.tuck = Config.DEFAULTS.grass_tuck_px
  self.registeredInWorld = false
  self.assetInfo = render:assetStatusFor(record.species, game)

  local spriteId, spriteErr = render:spriteIdFor(record.species)
  if not spriteId then
    error(spriteErr or "No pre-registered overworld sprite", 0)
  end

  local runtime = render:getRuntimeImage(record.species, game)
  local spriteDef = game.data.sprites and game.data.sprites[spriteId]
  if not spriteDef then
    local contentDef = mod.content.sprites:get(spriteId)
    if contentDef then
      spriteDef = {
        image = contentDef.image,
        frames = contentDef.frames or 1,
        trueColor = contentDef.trueColor ~= false,
        id = spriteId,
      }
      -- Runtime view only: keep the merged Data table in sync for consumers
      -- that read game.data.sprites. This is not a content-registry write.
      game.data.sprites = game.data.sprites or {}
      game.data.sprites[spriteId] = spriteDef
    end
  end
  if not spriteDef then
    error("overworld_wild_spawns: pre-registered sprite missing from data: "
          .. tostring(spriteId), 0)
  end

  -- Prefer a runtime-baked 16x16 sheet when available; never re-register.
  local drawDef = spriteDef
  if runtime and runtime.bakedPath and runtime.bakedPath ~= spriteDef.image then
    drawDef = {
      image = runtime.bakedPath,
      frames = 1,
      trueColor = true,
      id = spriteId,
    }
  end

  local SpriteRenderer, err = tryRequire("src.render.SpriteRenderer")
  if not SpriteRenderer then
    error("SpriteRenderer unavailable: " .. tostring(err), 0)
  end
  self.sprite = SpriteRenderer.new(drawDef, self.spawnId)
  self.spriteId = spriteId
  return self
end

function Entity:setCell(x, y)
  self.cellX = x
  self.cellY = y
  self.px = x * CELL
  self.py = y * CELL
end

function Entity:pose()
  local visualY = self.py + self.tuck
  return self.sprite, self.px, visualY, self.facing, 0, false, false
end

function Entity:draw(camX, camY)
  local opacity = Config.get(self.mod, "sprite_opacity") or 1
  local sprite, px, py, facing, phase, flip = self:pose()
  if opacity < 1 and love and love.graphics and love.graphics.setColor then
    love.graphics.setColor(1, 1, 1, opacity)
    sprite:draw(px, py, camX, camY, facing, phase, flip)
    love.graphics.setColor(1, 1, 1, 1)
  else
    sprite:draw(px, py, camX, camY, facing, phase, flip)
  end
end

function SpawnRender:makeEntity(game, record)
  return Entity.new(game, self.mod, self, record)
end

-- Probe whether a species can become an overworld entity without mutating world
-- or content registries.
function SpawnRender:probeEntity(game, species)
  local info = self:assetStatusFor(species, game)
  if not info.spriteRegistered then
    info.entityReady = false
    info.entityStatus = Config.STATUS.NOT_AVAILABLE
    info.lastError = info.lastError
      or ("No pre-registered overworld sprite for species " .. tostring(species))
    return info, nil
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
    return info, nil
  end
  if not entityOrErr then
    info.entityReady = false
    info.lastError = "makeEntity returned nil"
    info.entityStatus = Config.STATUS.NOT_AVAILABLE
    return info, nil
  end
  info.entityReady = true
  if info.status == "LOADED" and self.rendererMode == "base" then
    info.entityStatus = Config.STATUS.READY
  else
    info.entityStatus = Config.STATUS.NOT_AVAILABLE
  end
  return info, entityOrErr
end

function SpawnRender:previewImagePath(species, game)
  local info = self:assetStatusFor(species, game)
  if info.generatedOverworld then return info.generatedOverworld, "generated_overworld" end
  if info.overworldSprite then return info.overworldSprite, info.overworldKind or "overworld" end
  if info.battleFront then return info.battleFront, "battle_front" end
  return self.mod.assets:path("spawn_placeholder.png"), "placeholder"
end

return SpawnRender
