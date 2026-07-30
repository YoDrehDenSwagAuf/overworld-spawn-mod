-- Presentational half of overworld_wild_spawns.
-- Base Gen1Recomp path: SpriteRenderer + pose()/draw() on OverworldState.entities.
-- DramaticShapeVoxelMod is optional: when VOXEL is active it billboards via pose().
--
-- Asset classes tracked for the developer browser:
--   battle_front / battle_back / menu_icon / overworld / generated_overworld / voxel
-- Spawn success depends on a usable overworld representation, not a battle pic alone.
local V = ...
local Config = V.require("config")

local SpawnRender = {}
SpawnRender.__index = SpawnRender

local CELL = 16

local function tryRequire(name)
  local ok, modOrErr = pcall(require, name)
  if ok then return modOrErr, nil end
  return nil, modOrErr
end

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
  return love.filesystem.getSaveDirectory() .. "/" .. rel
end

function SpawnRender.new(mod)
  local self = setmetatable({}, SpawnRender)
  self.mod = mod
  self.spriteIds = {}
  self.assetInfo = {} -- species -> status table
  self.placeholderId = nil
  self.rendererMode = "base" -- "base" | unavailable
  self.lastError = nil
  self:_ensurePlaceholder()
  return self
end

function SpawnRender:_log(fmt, ...)
  if Config.debug(self.mod) then
    self.mod.log:info("[owwild/render] " .. fmt, ...)
  end
end

function SpawnRender:_ensurePlaceholder()
  if self.placeholderId then return self.placeholderId end
  local id = "SPRITE_OW_WILD_PLACEHOLDER"
  local path = self.mod.assets:path("spawn_placeholder.png")
  if not self.mod.content.sprites:get(id) then
    self.mod.content.sprites:register(id, {
      image = path,
      frames = 1,
      trueColor = true,
    })
  end
  self.placeholderId = id
  return id
end

-- Probe that the base Gen1Recomp SpriteRenderer path is usable. Does not
-- require DramaticShapeVoxelMod.
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
  local placeholder = self:_ensurePlaceholder()
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

function SpawnRender:assetStatusFor(species, game)
  if self.assetInfo[species] then return self.assetInfo[species] end

  local def = game and game.data and game.data.pokemon
              and game.data.pokemon[species]
  local info = {
    species = species,
    battleFront = def and def.spriteFront or nil,
    battleBack = def and def.spriteBack or nil,
    menuIcon = def and def.icon or nil,
    overworldSprite = nil,
    generatedOverworld = nil,
    voxel = nil,
    overworldKind = nil, -- overworld | generated_overworld | placeholder
    status = "MISSING",
    renderer = "UNKNOWN",
    entityReady = false,
    lastError = nil,
  }

  local owId = "SPRITE_OW_WILD_" .. tostring(species)
  local existing = self.mod.content.sprites:get(owId)
                 or (game and game.data and game.data.sprites and game.data.sprites[owId])
  if existing then
    info.overworldSprite = existing.image
    info.overworldKind = "overworld"
    info.status = "LOADED"
  elseif def and def.spriteFront then
    -- Attempt bake (same path as makeEntity). Result may be nil headlessly.
    local baked = bakeSheet(species, def.spriteFront, function(fmt, ...)
      self:_log(fmt, ...)
    end)
    if baked then
      info.generatedOverworld = baked
      info.overworldKind = "generated_overworld"
      info.status = "LOADED"
    else
      -- Placeholder is NOT counted as a real overworld representation for
      -- diagnostics, but entity creation can still proceed with it.
      info.overworldKind = "placeholder"
      info.status = "PLACEHOLDER"
      info.lastError = "no overworld sprite; using placeholder"
    end
  else
    info.overworldKind = "placeholder"
    info.status = "MISSING"
    info.lastError = "no battle front or overworld sprite"
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

  info.entityReady = info.status == "LOADED" or info.status == "PLACEHOLDER"
  self.assetInfo[species] = info
  return info
end

function SpawnRender:spriteIdFor(species, game)
  if self.spriteIds[species] then return self.spriteIds[species] end

  local id = "SPRITE_OW_WILD_" .. tostring(species)
  if self.mod.content.sprites:get(id) then
    self.spriteIds[species] = id
    self:assetStatusFor(species, game)
    return id
  end

  local def = game and game.data and game.data.pokemon
              and game.data.pokemon[species]
  local front = def and def.spriteFront
  if front then
    local baked = bakeSheet(species, front, function(fmt, ...)
      self:_log(fmt, ...)
    end)
    if baked then
      self.mod.content.sprites:register(id, {
        image = baked,
        frames = 1,
        trueColor = true,
      })
      if game.data.sprites then
        game.data.sprites[id] = {
          image = baked, frames = 1, trueColor = true, id = id,
        }
      end
      self.spriteIds[species] = id
      self.assetInfo[species] = nil
      self:assetStatusFor(species, game)
      return id
    end
  end

  self.spriteIds[species] = self:_ensurePlaceholder()
  self.assetInfo[species] = nil
  self:assetStatusFor(species, game)
  return self.spriteIds[species]
end

function SpawnRender:countAssets(speciesList, game)
  local required, loaded = 0, 0
  for _, species in ipairs(speciesList or {}) do
    required = required + 1
    local info = self:assetStatusFor(species, game)
    -- LOADED means a real overworld or generated overworld representation.
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

  local spriteId = render:spriteIdFor(record.species, game)
  local spriteDef = game.data.sprites and game.data.sprites[spriteId]
  if not spriteDef then
    spriteId = render:_ensurePlaceholder()
    spriteDef = game.data.sprites and game.data.sprites[spriteId]
  end
  if not spriteDef then
    local contentDef = mod.content.sprites:get(spriteId)
    if contentDef then
      spriteDef = {
        image = contentDef.image or mod.assets:path("spawn_placeholder.png"),
        frames = contentDef.frames or 1,
        trueColor = contentDef.trueColor ~= false,
        id = spriteId,
      }
      game.data.sprites = game.data.sprites or {}
      game.data.sprites[spriteId] = spriteDef
    end
  end
  if not spriteDef then
    error("overworld_wild_spawns: placeholder sprite missing", 0)
  end
  local SpriteRenderer, err = tryRequire("src.render.SpriteRenderer")
  if not SpriteRenderer then
    error("SpriteRenderer unavailable: " .. tostring(err), 0)
  end
  self.sprite = SpriteRenderer.new(spriteDef, self.spawnId)
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

-- Probe whether a species can become an overworld entity without mutating world.
function SpawnRender:probeEntity(game, species)
  local info = self:assetStatusFor(species, game)
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
  elseif info.status == "PLACEHOLDER" then
    info.entityStatus = "PLACEHOLDER"
  else
    info.entityStatus = Config.STATUS.NOT_AVAILABLE
  end
  return info, entityOrErr
end

function SpawnRender:previewImagePath(species, game)
  local info = self:assetStatusFor(species, game)
  if info.generatedOverworld then return info.generatedOverworld, "generated_overworld" end
  if info.overworldSprite then return info.overworldSprite, "overworld" end
  -- Do not fall back to battle front for "success" preview; expose kind.
  if info.battleFront then return info.battleFront, "battle_front" end
  return self.mod.assets:path("spawn_placeholder.png"), "placeholder"
end

return SpawnRender
