-- Presentational half of overworld-spawns.
-- Builds sprite ids and SpawnEntity objects that satisfy pose()/draw() for
-- both vanilla 2D SpriteRenderer and Dramatic Shape VoxelScene billboards.
local V = ...
local Config = V.require("config")

local SpawnRender = {}
SpawnRender.__index = SpawnRender

local CELL = 16

local function tryRequire(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil
end

local function bakeSheet(species, sourcePath)
  if not (love and love.graphics and love.image) then return nil end
  local Assets = tryRequire("src.render.Assets")
  if not Assets then return nil end

  local ok, src = pcall(Assets.image, sourcePath)
  if not ok or not src then return nil end

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

  pcall(love.filesystem.createDirectory, "overworld-spawns-cache")
  local rel = "overworld-spawns-cache/" .. tostring(species):lower() .. ".png"
  local fileData = idata:encode("png")
  if not fileData then return nil end
  love.filesystem.write(rel, fileData:getString())
  return love.filesystem.getSaveDirectory() .. "/" .. rel
end

function SpawnRender.new(mod)
  local self = setmetatable({}, SpawnRender)
  self.mod = mod
  self.spriteIds = {}
  self.placeholderId = nil
  self:_ensurePlaceholder()
  return self
end

function SpawnRender:_ensurePlaceholder()
  if self.placeholderId then return self.placeholderId end
  local id = "SPRITE_OW_SPAWN_PLACEHOLDER"
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

function SpawnRender:spriteIdFor(species, game)
  if self.spriteIds[species] then return self.spriteIds[species] end

  local id = "SPRITE_OW_SPAWN_" .. tostring(species)
  if self.mod.content.sprites:get(id) then
    self.spriteIds[species] = id
    return id
  end

  local def = game and game.data and game.data.pokemon
              and game.data.pokemon[species]
  local front = def and def.spriteFront
  if front then
    local baked = bakeSheet(species, front)
    if baked then
      self.mod.content.sprites:register(id, {
        image = baked,
        frames = 1,
        trueColor = true,
      })
      -- Also stamp into the live data table so SpriteRenderer can resolve
      -- immediately without waiting for a rematch merge.
      if game.data.sprites then
        game.data.sprites[id] = {
          image = baked, frames = 1, trueColor = true, id = id,
        }
      end
      self.spriteIds[species] = id
      return id
    end
  end

  self.spriteIds[species] = self:_ensurePlaceholder()
  return self.spriteIds[species]
end

local Entity = {}
Entity.__index = Entity

function Entity.new(game, mod, render, record)
  local self = setmetatable({}, Entity)
  self.overworldSpawn = true
  self.passable = true
  self.spawnId = record.id
  self.species = record.species
  self.level = record.level
  self.mapId = record.mapId
  self.cellX = record.x
  self.cellY = record.y
  self.px = record.x * CELL
  self.py = record.y * CELL
  self.facing = "down"
  self.mod = mod
  self.render = render
  self.tuck = Config.DEFAULTS.grass_tuck_px

  local spriteId = render:spriteIdFor(record.species, game)
  local spriteDef = game.data.sprites and game.data.sprites[spriteId]
  if not spriteDef then
    spriteId = render:_ensurePlaceholder()
    spriteDef = game.data.sprites and game.data.sprites[spriteId]
  end
  assert(spriteDef, "overworld-spawns: placeholder sprite missing")
  local SpriteRenderer = require("src.render.SpriteRenderer")
  self.sprite = SpriteRenderer.new(spriteDef, self.spawnId)
  return self
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

return SpawnRender
