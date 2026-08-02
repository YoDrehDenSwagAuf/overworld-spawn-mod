-- Animated overworld Pokemon sprites from a shared atlas + per-species JSON.
--
-- Identity = numeric National Pokedex / speciesId (never localized names).
-- Display names (JSON speciesName or game localization) are UI/logging only.
--
-- Load once at mod init. No content-registry mutation. Quads live in a
-- mod-owned cache only.
local V = ...
local Config = V.require("config")
local JsonDecode = V.require("json_decode")
local Tile = V.require("tile")
local DebugLog = V.require("debug_log")

local AnimatedSprites = {}
AnimatedSprites.__index = AnimatedSprites

local CELL = Tile.CELL
local MAX_SPECIES = 151

-- Discovered asset layout (repo-relative, LÖVE virtual paths via mod.assets).
AnimatedSprites.ATLAS_REL = "assets/enhanced_overworld/Pokemon_Sprites/POKEMON 1.png"
AnimatedSprites.ATLAS_FILENAME = "POKEMON 1.png"
AnimatedSprites.MAPPING_DIR = "assets/enhanced_overworld/pokedex_mapping"
AnimatedSprites.MAPPING_PATTERN = "pokemon_%03d_project.json"

AnimatedSprites.STATUS = {
  ENHANCED_READY = "ENHANCED_READY",
  ENHANCED_PARTIAL = "ENHANCED_PARTIAL",
  MAPPING_MISSING = "MAPPING_MISSING",
  MAPPING_INVALID = "MAPPING_INVALID",
  ATLAS_FRAME_INVALID = "ATLAS_FRAME_INVALID",
  LEGACY_PNG_FALLBACK = "LEGACY_PNG_FALLBACK",
  BLACK_FALLBACK = "BLACK_FALLBACK",
  DISABLED = "DISABLED",
}

-- Facing values that exist in this mod / Gen1Recomp NPC path.
local FACING_MAP = {
  front = "down",
  down = "down",
  south = "down",
  back = "up",
  up = "up",
  north = "up",
  left = "left",
  west = "left",
  right = "right",
  east = "right",
}

local DIRECTIONS = { "down", "up", "left", "right" }
local CORE_ANIMS = { "idle", "walk" }
local EXTRA_ANIMS = { "fly", "follow", "surf" }

-- Central animation speeds (seconds per frame).
AnimatedSprites.IDLE_FPS = 3
AnimatedSprites.WALK_FPS = 7
AnimatedSprites.IDLE_FRAME_DURATION = 1 / AnimatedSprites.IDLE_FPS
AnimatedSprites.WALK_FRAME_DURATION = 1 / AnimatedSprites.WALK_FPS
-- Voxel billboards are always 16×16 cards (DramaticShape SpriteBillboards).
AnimatedSprites.VOXEL_CARD = 16

function AnimatedSprites.normalizeFacing(facing)
  if facing == nil then return "down" end
  local key = tostring(facing):lower()
  return FACING_MAP[key] or "down"
end

function AnimatedSprites.mappingFileName(speciesId)
  return string.format(AnimatedSprites.MAPPING_PATTERN, tonumber(speciesId) or 0)
end

function AnimatedSprites.mappingRelPath(speciesId)
  return AnimatedSprites.MAPPING_DIR .. "/" .. AnimatedSprites.mappingFileName(speciesId)
end

-- Resolve numeric National Pokedex / speciesId from a game species key.
-- NEVER uses localized display names for lookup.
function AnimatedSprites.resolveSpeciesId(speciesKey, game, mod)
  if speciesKey == nil then return nil end
  local n = tonumber(speciesKey)
  if n and n >= 1 and n <= MAX_SPECIES and math.floor(n) == n then
    return math.floor(n)
  end

  local mon = nil
  if game and game.data and game.data.pokemon then
    mon = game.data.pokemon[speciesKey]
  end
  if not mon and mod and mod.content and mod.content.pokemon then
    mon = mod.content.pokemon:get(speciesKey)
  end
  if mon and mon.dex ~= nil then
    local dex = tonumber(mon.dex)
    if dex and dex >= 1 then
      return math.floor(dex)
    end
  end
  return nil
end

local function emptyAnimDirs()
  return { down = {}, up = {}, left = {}, right = {} }
end

local function framePixelRect(frame, cellW, cellH)
  local col = tonumber(frame.col)
  local row = tonumber(frame.row)
  local wCells = tonumber(frame.w)
  local hCells = tonumber(frame.h)
  if not col or not row or not wCells or not hCells then
    return nil, "frame missing col/row/w/h"
  end
  if col < 0 or row < 0 or wCells <= 0 or hCells <= 0 then
    return nil, "frame has negative or non-positive geometry"
  end
  return {
    x = col * cellW,
    y = row * cellH,
    width = wCells * cellW,
    height = hCells * cellH,
    sourceCol = col,
    sourceRow = row,
    widthCells = wCells,
    heightCells = hCells,
  }
end

local function countFrames(animTable)
  local n = 0
  for _, dir in ipairs(DIRECTIONS) do
    local list = animTable and animTable[dir]
    if type(list) == "table" then n = n + #list end
  end
  return n
end

local function missingCoreDirs(mapping)
  local missing = {}
  for _, anim in ipairs(CORE_ANIMS) do
    for _, dir in ipairs(DIRECTIONS) do
      local list = mapping[anim] and mapping[anim][dir]
      if type(list) ~= "table" or #list == 0 then
        missing[#missing + 1] = anim .. "." .. dir
      end
    end
  end
  return missing
end

function AnimatedSprites.new(mod)
  local self = setmetatable({}, AnimatedSprites)
  self.mod = mod
  self.atlasImage = nil
  self.atlasPath = nil
  self.atlasWidth = 0
  self.atlasHeight = 0
  self.mappingsBySpeciesId = {}
  self.quadCache = {}
  self.voxelCardCache = {}
  self.billboardCache = {}
  self.voxelCacheHits = 0
  self.voxelCacheMisses = 0
  self.voxelConversions = 0
  self.mappedSpeciesCount = 0
  self.validSpeciesCount = 0
  self.partialSpeciesCount = 0
  self.invalidSpeciesCount = 0
  self.missingSpeciesCount = 0
  self.mappingFilesFound = 0
  self.loaded = false
  self.atlasReady = false
  self.error = nil
  self._fallbackLogged = {}
  return self
end

function AnimatedSprites:_notice(fmt, ...)
  local msg = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
  self.mod.log:info("[WildsOfKanto][INFO] %s", msg)
end

function AnimatedSprites:_warn(fmt, ...)
  local msg = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
  self.mod.log:info("[WildsOfKanto][WARN] %s", msg)
end

function AnimatedSprites:_error(fmt, ...)
  local msg = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
  self.mod.log:info("[WildsOfKanto][ERROR] %s", msg)
end

function AnimatedSprites:_modPath(rel)
  if type(rel) ~= "string" or rel == "" then return nil end
  if self.mod.assets and self.mod.assets.path then
    return self.mod.assets:path(rel)
  end
  return rel
end

function AnimatedSprites:_readText(rel)
  if self.mod.read then
    local ok, text = pcall(self.mod.read, self.mod, rel)
    if ok and type(text) == "string" and text ~= "" then
      return text
    end
  end
  local path = self:_modPath(rel)
  if love and love.filesystem and love.filesystem.read and path then
    local ok, data = pcall(love.filesystem.read, path)
    if ok and type(data) == "string" then return data end
  end
  return nil
end

function AnimatedSprites:_loadAtlas()
  self:_notice("Loading animated Pokemon atlas")
  local rel = AnimatedSprites.ATLAS_REL
  local path = self:_modPath(rel)
  self.atlasPath = path or rel

  if not (love and love.graphics and love.graphics.newImage) then
    -- Headless / test: mark atlas metadata-ready without Image userdata.
    self.atlasWidth = 1536
    self.atlasHeight = 480
    self.atlasReady = true
    self.atlasImage = nil
    self:_notice("Atlas stubbed for headless load (%dx%d)", self.atlasWidth, self.atlasHeight)
    return true
  end

  local ok, imageOrErr = pcall(love.graphics.newImage, path or rel)
  if not ok or not imageOrErr then
    self.error = "atlas load failed: " .. tostring(imageOrErr)
    self.atlasReady = false
    self:_error("%s", self.error)
    return false
  end
  if imageOrErr.setFilter then
    imageOrErr:setFilter("nearest", "nearest")
  end
  local w, h = imageOrErr:getDimensions()
  self.atlasImage = imageOrErr
  self.atlasWidth = w or 0
  self.atlasHeight = h or 0
  self.atlasReady = self.atlasWidth > 0 and self.atlasHeight > 0
  if self.atlasReady then
    self:_notice("Atlas loaded: %dx%d", self.atlasWidth, self.atlasHeight)
  else
    self.error = "atlas has invalid dimensions"
    self:_error("%s", self.error)
  end
  return self.atlasReady
end

function AnimatedSprites:_normalizeFrames(rawList, cellW, cellH, errors)
  local out = {}
  if type(rawList) ~= "table" then return out end
  for _, raw in ipairs(rawList) do
    if type(raw) == "table" then
      local fr, err = framePixelRect(raw, cellW, cellH)
      if not fr then
        errors[#errors + 1] = err or "bad frame"
      else
        local x2 = fr.x + fr.width
        local y2 = fr.y + fr.height
        if fr.x < 0 or fr.y < 0
           or x2 > self.atlasWidth or y2 > self.atlasHeight then
          errors[#errors + 1] = string.format(
            "frame out of atlas bounds col=%s row=%s w=%s h=%s",
            tostring(raw.col), tostring(raw.row), tostring(raw.w), tostring(raw.h))
        else
          out[#out + 1] = fr
        end
      end
    end
  end
  return out
end

function AnimatedSprites:_validateSourceSheet(sourceSheet)
  if type(sourceSheet) ~= "string" or sourceSheet == "" then
    return false, "missing sourceSheet"
  end
  local expected = AnimatedSprites.ATLAS_FILENAME
  if sourceSheet == expected then return true end
  if sourceSheet:lower() == expected:lower() then
    -- Case differs — treat as invalid on case-sensitive platforms.
    return false, string.format(
      "sourceSheet case mismatch file=%s expected=%s", sourceSheet, expected)
  end
  return false, string.format(
    "sourceSheet mismatch file=%s expected=%s", sourceSheet, expected)
end

function AnimatedSprites:_loadOneMapping(speciesId)
  local fileName = AnimatedSprites.mappingFileName(speciesId)
  local rel = AnimatedSprites.mappingRelPath(speciesId)
  local entry = {
    speciesId = speciesId,
    speciesName = nil,
    fileName = fileName,
    relPath = rel,
    cellWidth = 16,
    cellHeight = 16,
    sourceSheet = nil,
    idle = emptyAnimDirs(),
    walk = emptyAnimDirs(),
    fly = emptyAnimDirs(),
    follow = emptyAnimDirs(),
    surf = emptyAnimDirs(),
    valid = false,
    partial = false,
    status = AnimatedSprites.STATUS.MAPPING_MISSING,
    errors = {},
    missingDirs = {},
    usableFrameCount = 0,
  }

  local text = self:_readText(rel)
  if not text then
    entry.status = AnimatedSprites.STATUS.MAPPING_MISSING
    entry.errors[#entry.errors + 1] = "mapping file missing"
    return entry
  end
  self.mappingFilesFound = self.mappingFilesFound + 1

  local data, err = JsonDecode.decode(text)
  if not data then
    entry.status = AnimatedSprites.STATUS.MAPPING_INVALID
    entry.errors[#entry.errors + 1] = "json decode: " .. tostring(err)
    return entry
  end

  local jsonId = tonumber(data.speciesId)
  if not jsonId or math.floor(jsonId) ~= speciesId then
    entry.status = AnimatedSprites.STATUS.MAPPING_INVALID
    entry.errors[#entry.errors + 1] = string.format(
      "Mapping ID mismatch: file=%s filenameSpeciesId=%d jsonSpeciesId=%s",
      fileName, speciesId, tostring(data.speciesId))
    self:_warn(
      "Mapping ID mismatch: file=%s filenameSpeciesId=%d jsonSpeciesId=%s fallback=LEGACY_PNG",
      fileName, speciesId, tostring(data.speciesId))
    return entry
  end

  entry.speciesName = data.speciesName -- display / logging only
  entry.sourceSheet = data.sourceSheet
  local sheetOk, sheetErr = self:_validateSourceSheet(data.sourceSheet)
  if not sheetOk then
    entry.status = AnimatedSprites.STATUS.MAPPING_INVALID
    entry.errors[#entry.errors + 1] = sheetErr
    return entry
  end

  local cellW = tonumber(data.cellWidth) or 0
  local cellH = tonumber(data.cellHeight) or 0
  if cellW <= 0 or cellH <= 0 then
    entry.status = AnimatedSprites.STATUS.MAPPING_INVALID
    entry.errors[#entry.errors + 1] = "cellWidth/cellHeight must be > 0"
    return entry
  end
  entry.cellWidth = cellW
  entry.cellHeight = cellH

  if type(data.animations) ~= "table" then
    entry.status = AnimatedSprites.STATUS.MAPPING_INVALID
    entry.errors[#entry.errors + 1] = "animations missing"
    return entry
  end

  local frameErrors = {}
  local function ingest(animName)
    local rawAnim = data.animations[animName]
    local dest = entry[animName] or emptyAnimDirs()
    entry[animName] = dest
    if type(rawAnim) ~= "table" then
      -- Extra anims may be absent; core ones must exist as objects.
      if animName == "idle" or animName == "walk" then
        frameErrors[#frameErrors + 1] = animName .. " missing"
      end
      return
    end
    for _, dir in ipairs(DIRECTIONS) do
      dest[dir] = self:_normalizeFrames(rawAnim[dir], cellW, cellH, frameErrors)
    end
  end

  for _, name in ipairs(CORE_ANIMS) do ingest(name) end
  for _, name in ipairs(EXTRA_ANIMS) do ingest(name) end

  entry.usableFrameCount = countFrames(entry.idle) + countFrames(entry.walk)
  if #frameErrors > 0 and entry.usableFrameCount == 0 then
    entry.status = AnimatedSprites.STATUS.ATLAS_FRAME_INVALID
    for _, e in ipairs(frameErrors) do entry.errors[#entry.errors + 1] = e end
    return entry
  end
  for _, e in ipairs(frameErrors) do entry.errors[#entry.errors + 1] = e end

  if entry.usableFrameCount == 0 then
    entry.status = AnimatedSprites.STATUS.MAPPING_INVALID
    entry.errors[#entry.errors + 1] = "no usable idle/walk frames"
    return entry
  end

  entry.missingDirs = missingCoreDirs(entry)
  if #entry.missingDirs == 0 and #entry.errors == 0 then
    entry.valid = true
    entry.partial = false
    entry.status = AnimatedSprites.STATUS.ENHANCED_READY
  else
    entry.valid = true
    entry.partial = true
    entry.status = AnimatedSprites.STATUS.ENHANCED_PARTIAL
    if #entry.missingDirs > 0 then
      self:_warn("species=%d file=%s reason=%s",
                 speciesId, fileName, table.concat(entry.missingDirs, ","))
    end
  end
  return entry
end

-- LOAD PHASE: atlas once + all 151 mappings once.
function AnimatedSprites:load()
  if self.loaded then return true end

  local atlasOk = self:_loadAtlas()
  if not atlasOk then
    self.loaded = true
    self.atlasReady = false
    self:_warn("Animated atlas unavailable; enhanced sprites disabled globally")
    return false
  end

  self.mappingFilesFound = 0
  self.validSpeciesCount = 0
  self.partialSpeciesCount = 0
  self.invalidSpeciesCount = 0
  self.missingSpeciesCount = 0
  self.mappedSpeciesCount = 0

  for id = 1, MAX_SPECIES do
    local entry = self:_loadOneMapping(id)
    self.mappingsBySpeciesId[id] = entry
    if entry.status == AnimatedSprites.STATUS.ENHANCED_READY then
      self.validSpeciesCount = self.validSpeciesCount + 1
      self.mappedSpeciesCount = self.mappedSpeciesCount + 1
    elseif entry.status == AnimatedSprites.STATUS.ENHANCED_PARTIAL then
      self.partialSpeciesCount = self.partialSpeciesCount + 1
      self.mappedSpeciesCount = self.mappedSpeciesCount + 1
    elseif entry.status == AnimatedSprites.STATUS.MAPPING_MISSING then
      self.missingSpeciesCount = self.missingSpeciesCount + 1
    else
      self.invalidSpeciesCount = self.invalidSpeciesCount + 1
      for _, e in ipairs(entry.errors) do
        self:_warn("species=%d file=%s reason=%s", id, entry.fileName, e)
      end
    end
  end

  self.loaded = true
  self:_notice("Mapping files found: %d", self.mappingFilesFound)
  self:_notice("Valid species mappings: %d", self.validSpeciesCount)
  if self.partialSpeciesCount > 0 then
    self:_warn("Partial species mappings: %d", self.partialSpeciesCount)
  else
    self:_notice("Partial species mappings: 0")
  end
  if self.invalidSpeciesCount > 0 then
    self:_error("Invalid species mappings: %d", self.invalidSpeciesCount)
  else
    self:_notice("Invalid species mappings: 0")
  end
  return true
end

function AnimatedSprites:isReady()
  return self.loaded and self.atlasReady == true
end

function AnimatedSprites:getMapping(speciesId)
  speciesId = tonumber(speciesId)
  if not speciesId then return nil end
  return self.mappingsBySpeciesId[speciesId]
end

function AnimatedSprites:isEnhancedAvailable(speciesId)
  if not self:isReady() then return false end
  local m = self:getMapping(speciesId)
  return m and m.valid == true and m.usableFrameCount > 0
end

-- Frame resolution with controlled internal fallbacks for idle/walk.
function AnimatedSprites:resolveFrames(speciesId, animName, direction)
  local m = self:getMapping(speciesId)
  if not m or not m.valid then return nil, nil end
  direction = AnimatedSprites.normalizeFacing(direction)
  animName = (animName == "walk") and "walk" or "idle"

  local function first(list)
    if type(list) == "table" and #list > 0 then return list end
    return nil
  end

  local primary = m[animName] and first(m[animName][direction])
  if primary then return primary, animName end

  if animName == "idle" then
    local walkSame = m.walk and first(m.walk[direction])
    if walkSame then return { walkSame[1] }, "walk" end
    local idleDown = m.idle and first(m.idle.down)
    if idleDown then return idleDown, "idle" end
    local walkDown = m.walk and first(m.walk.down)
    if walkDown then return { walkDown[1] }, "walk" end
  else
    local idleSame = m.idle and first(m.idle[direction])
    if idleSame then return idleSame, "idle" end
    local walkDown = m.walk and first(m.walk.down)
    if walkDown then return walkDown, "walk" end
    local idleDown = m.idle and first(m.idle.down)
    if idleDown then return idleDown, "idle" end
  end
  return nil, nil
end

function AnimatedSprites:getFrame(speciesId, animName, direction, frameIndex)
  local frames = self:resolveFrames(speciesId, animName, direction)
  if not frames or #frames == 0 then return nil end
  local idx = ((tonumber(frameIndex) or 1) - 1) % #frames + 1
  return frames[idx], #frames, idx
end

function AnimatedSprites:quadKey(speciesId, animName, direction, frameIndex)
  return string.format("%d:%s:%s:%d",
    tonumber(speciesId) or 0,
    tostring(animName),
    tostring(direction),
    tonumber(frameIndex) or 1)
end

function AnimatedSprites:getQuad(speciesId, animName, direction, frameIndex)
  local key = self:quadKey(speciesId, animName, direction, frameIndex)
  local cached = self.quadCache[key]
  if cached ~= nil then return cached end

  local frame = self:getFrame(speciesId, animName, direction, frameIndex)
  if not frame then
    self.quadCache[key] = false
    return nil
  end
  if not (love and love.graphics and love.graphics.newQuad) then
    -- Headless: store a lightweight rect stand-in.
    local stub = {
      x = frame.x, y = frame.y, w = frame.width, h = frame.height,
      _owwildStub = true, frame = frame,
    }
    self.quadCache[key] = stub
    return stub
  end
  if not self.atlasImage or self.atlasWidth < 1 or self.atlasHeight < 1 then
    self.quadCache[key] = false
    return nil
  end
  local ok, quad = pcall(love.graphics.newQuad,
    frame.x, frame.y, frame.width, frame.height,
    self.atlasWidth, self.atlasHeight)
  if not ok or not quad then
    self.quadCache[key] = false
    return nil
  end
  self.quadCache[key] = quad
  return quad
end

function AnimatedSprites.calculateAnimatedSpriteScale(_entity, frame, opts)
  opts = opts or {}
  local tile = opts.tileSize or CELL
  local fw = math.max(1, (frame and frame.width) or tile)
  local fh = math.max(1, (frame and frame.height) or tile)
  -- Native atlas pixels map 1:1 to world pixels. Multi-cell frames may span
  -- multiple tiles visually; logical collision stays one tile.
  local scale = 1.0
  local minOpt = tonumber(opts.minSpriteSizeOption)
  if minOpt and minOpt > 0 then
    -- Upscale only when the shorter side is below the preferred minimum and
    -- the frame is still a single-cell (or smaller) sprite.
    local shorter = math.min(fw, fh)
    if shorter < minOpt and fw <= tile and fh <= tile then
      scale = minOpt / shorter
    end
  end
  local renderedW = fw * scale
  local renderedH = fh * scale
  local GrassOcclusion = V.require("grass_occlusion")
  local grassOcclusionHeight = GrassOcclusion.computeOcclusionHeight(renderedH, {
    engineCover = opts.defaultGrassOcclusion or Config.DEFAULTS.grass_occlusion_px,
  })
  return {
    scale = scale,
    final2DScale = scale,
    contentW = fw,
    contentH = fh,
    offsetX = 0,
    offsetY = 0,
    imageW = fw,
    imageH = fh,
    renderedW = renderedW,
    renderedH = renderedH,
    originalW = fw,
    originalH = fh,
    tileWidth = tile,
    tileHeight = tile,
    grassOcclusionHeight = grassOcclusionHeight,
    logicalFootprintTiles = 1,
    visualFootprintTilesW = renderedW / tile,
    visualFootprintTilesH = renderedH / tile,
    animated = true,
  }
end

function AnimatedSprites:newAnimationState(direction)
  return {
    type = "idle",
    name = "idle", -- alias of type for older call sites
    direction = AnimatedSprites.normalizeFacing(direction),
    frameIndex = 1,
    elapsed = 0,
    frameDuration = AnimatedSprites.IDLE_FRAME_DURATION,
    usingEnhancedSprite = true,
    fallbackLevel = nil,
    frameChanged = false,
    directionChanged = false,
    source = "ENHANCED_ATLAS",
    renderRevision = 0,
  }
end

function AnimatedSprites.bumpRenderRevision(state, prev)
  if not state then return end
  prev = prev or {}
  local typeNow = state.type or state.name
  local changed = (prev.type ~= nil and prev.type ~= typeNow)
    or (prev.direction ~= nil and prev.direction ~= state.direction)
    or (prev.frameIndex ~= nil and prev.frameIndex ~= state.frameIndex)
    or (prev.source ~= nil and prev.source ~= state.source)
  if changed or state.frameChanged or state.directionChanged then
    state.renderRevision = (state.renderRevision or 0) + 1
  end
end

function AnimatedSprites:setAnim(state, name, direction, resetFrame)
  if not state then return end
  local dir = AnimatedSprites.normalizeFacing(direction or state.direction)
  local nextName = (name == "walk") and "walk" or "idle"
  local dirChanged = state.direction ~= dir
  local typeChanged = (state.name ~= nextName) and (state.type ~= nextName)
  state.name = nextName
  state.type = nextName
  state.direction = dir
  state.frameDuration = (nextName == "walk")
    and AnimatedSprites.WALK_FRAME_DURATION
    or AnimatedSprites.IDLE_FRAME_DURATION
  state.directionChanged = dirChanged
  if resetFrame or dirChanged or typeChanged then
    if state.frameIndex ~= 1 then
      state.frameChanged = true
    end
    state.frameIndex = 1
    state.elapsed = 0
  end
end

-- Returns true when frame or direction changed (callers update Voxel card).
-- movementProgress: optional 0..1 tile-step progress; when moving, drives walk
-- frames so 2D and Voxel stay locked to the same step.
function AnimatedSprites:updateAnimation(state, speciesId, dt, moving, facing, movementProgress)
  if not state or not state.usingEnhancedSprite then return false end
  state.frameChanged = false
  state.directionChanged = false

  local prevName = state.name or state.type or "idle"
  local prevDir = state.direction
  local prevFrame = state.frameIndex or 1

  local dir = AnimatedSprites.normalizeFacing(facing or state.direction)
  local name = moving and "walk" or "idle"
  self:setAnim(state, name, dir, false)

  local frames = self:resolveFrames(speciesId, state.name, state.direction)
  local count = frames and #frames or 1

  if moving and type(movementProgress) == "number" and count > 1 then
    local t = movementProgress
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    state.frameIndex = math.floor(t * count) % count + 1
    state.elapsed = 0
  elseif count <= 1 then
    state.frameIndex = 1
    state.elapsed = 0
  else
    state.elapsed = (state.elapsed or 0) + (dt or 0)
    local dur = state.frameDuration or AnimatedSprites.IDLE_FRAME_DURATION
    while state.elapsed >= dur do
      state.elapsed = state.elapsed - dur
      state.frameIndex = (state.frameIndex % count) + 1
    end
  end
  if state.frameIndex < 1 or state.frameIndex > count then
    state.frameIndex = 1
  end

  if state.frameIndex ~= prevFrame then
    state.frameChanged = true
  end
  if state.direction ~= prevDir then
    state.directionChanged = true
  end
  if (state.name or state.type) ~= prevName then
    state.frameChanged = true
  end

  if state.frameChanged or state.directionChanged then
    AnimatedSprites.bumpRenderRevision(state, {
      type = prevName,
      direction = prevDir,
      frameIndex = prevFrame,
      source = state.source,
    })
  end

  return state.frameChanged or state.directionChanged
end

AnimatedSprites.BILLBOARD_CARD = 16

function AnimatedSprites:billboardKey(speciesId, animName, direction, frameIndex, frame)
  local w = frame and frame.width or 16
  local h = frame and frame.height or 16
  return string.format("%d:%s:%s:%d:%d:%d",
    tonumber(speciesId) or 0,
    tostring(animName), tostring(direction),
    tonumber(frameIndex) or 1, w, h)
end

function AnimatedSprites:entityAnimParts(entity)
  if not entity then return nil end
  local anim = entity.animation or {}
  local speciesId = entity.enhancedDexId or entity.speciesId or entity.species
  local animName = anim.type or anim.name or "idle"
  local direction = anim.direction or entity.facing or "down"
  local frameIndex = anim.frameIndex or 1
  return speciesId, animName, direction, frameIndex, anim
end

function AnimatedSprites:getCurrentBillboardKey(entity)
  local speciesId, animName, direction, frameIndex = self:entityAnimParts(entity)
  local frame = self:getFrame(speciesId, animName, direction, frameIndex)
  return self:billboardKey(speciesId, animName, direction, frameIndex, frame)
end

function AnimatedSprites:peekBillboardImage(key)
  local cached = self.voxelCardCache[key]
  if type(cached) == "table" and cached.status == "READY" and cached.image then
    return cached.image
  end
  return nil
end

function AnimatedSprites:prepareBillboardImage(entity, key)
  local speciesId, animName, direction, frameIndex = self:entityAnimParts(entity)
  key = key or self:billboardKey(speciesId, animName, direction, frameIndex,
    self:getFrame(speciesId, animName, direction, frameIndex))
  local result = self:getBillboardCard(speciesId, animName, direction, frameIndex)
  if type(result) == "table" and result.status == "READY" and result.image then
    self.billboardCache = self.billboardCache or {}
    self.billboardCache[key] = result.image
  end
  return result
end

function AnimatedSprites:getCurrentBillboardImage(entity)
  local key = self:getCurrentBillboardKey(entity)
  local img = self:peekBillboardImage(key)
  if img then return img, key, true end
  local result = self:prepareBillboardImage(entity, key)
  if type(result) == "table" and result.image then
    return result.image, key, false
  end
  return nil, key, false
end

-- Bake current atlas frame into a 16×16 Image for Dramatic Shape
-- SpriteBillboards (mesh UVs come from def.image 16×16; live tex = this Image).
-- Returns a result table: status READY | TEMPORARILY_UNAVAILABLE | FRAME_MISSING | ...
function AnimatedSprites:getBillboardCard(speciesId, animName, direction, frameIndex)
  local frame = self:getFrame(speciesId, animName, direction, frameIndex)
  local key = self:billboardKey(speciesId, animName, direction, frameIndex, frame)
  local cached = self.voxelCardCache[key]
  if type(cached) == "table" and cached.status == "READY" and cached.image then
    self.voxelCacheHits = self.voxelCacheHits + 1
    cached._fromCache = true
    self.billboardCache = self.billboardCache or {}
    self.billboardCache[key] = cached.image
    return cached
  end
  -- Do not treat prior TEMP as permanent miss. Drop stale non-READY entries.
  if type(cached) == "table" and cached.status ~= "READY"
     and cached.status ~= "PERMANENT_INVALID" then
    self.voxelCardCache[key] = nil
  end
  self.voxelCacheMisses = self.voxelCacheMisses + 1

  if not frame then
    local result = {
      status = "PERMANENT_INVALID",
      reason = "no frame",
      key = key,
      retry = false,
    }
    -- Permanent asset miss may be cached; never cache TEMP as permanent.
    self.voxelCardCache[key] = result
    return result
  end

  if not self.atlasImage then
    if not (love and love.graphics and love.graphics.newImage) then
      return {
        status = "TEMPORARILY_UNAVAILABLE",
        reason = "graphics unavailable",
        key = key,
        retry = true,
      }
    end
    -- Atlas may have been stubbed headless then graphics appeared.
    local okLoad = self:_loadAtlas()
    if not okLoad or not self.atlasImage then
      return {
        status = "TEMPORARILY_UNAVAILABLE",
        reason = "atlas image not ready",
        key = key,
        retry = true,
      }
    end
  end

  if not (love and love.graphics and love.graphics.newCanvas) then
    return {
      status = "TEMPORARILY_UNAVAILABLE",
      reason = "newCanvas unavailable",
      key = key,
      retry = true,
    }
  end

  local quad = self:getQuad(speciesId, animName, direction, frameIndex)
  if not quad or quad._owwildStub then
    return {
      status = "TEMPORARILY_UNAVAILABLE",
      reason = "quad not ready",
      key = key,
      retry = true,
    }
  end

  local card = AnimatedSprites.BILLBOARD_CARD
  local fw, fh = frame.width, frame.height
  local fit = math.min(card / fw, card / fh)
  local dw, dh = fw * fit, fh * fit
  local ox = (card - dw) * 0.5
  local oy = card - dh

  local okBuild, imgOrErr = pcall(function()
    local okC, canvas = pcall(love.graphics.newCanvas, card, card)
    if not okC or not canvas then
      error("newCanvas failed: " .. tostring(canvas))
    end
    local prevCanvas = love.graphics.getCanvas and love.graphics.getCanvas() or nil
    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setBlendMode("alpha")
    love.graphics.setColor(1, 1, 1, 1)
    if love.graphics.setShader then love.graphics.setShader() end
    if self.atlasImage.setFilter then
      self.atlasImage:setFilter("nearest", "nearest")
    end
    love.graphics.draw(self.atlasImage, quad, ox, oy, 0, fit, fit)
    love.graphics.setCanvas(prevCanvas)
    love.graphics.pop()

    local idata = canvas:newImageData()
    canvas:release()
    local img = love.graphics.newImage(idata)
    if img.setFilter then img:setFilter("nearest", "nearest") end
    img._owwildVoxelCard = true
    img._owwildBoundsKey = "billboard:" .. key
    return img
  end)

  if not okBuild or not imgOrErr then
    return {
      status = "VOXEL_CARD_BUILD_ERROR",
      reason = tostring(imgOrErr),
      key = key,
      retry = true,
    }
  end

  local result = {
    status = "READY",
    image = imgOrErr,
    type = "Image",
    width = card,
    height = card,
    key = key,
    frameWidth = fw,
    frameHeight = fh,
    retry = false,
    _fromCache = false,
  }
  self.voxelCardCache[key] = result
  self.billboardCache = self.billboardCache or {}
  self.billboardCache[key] = imgOrErr
  self.voxelConversions = self.voxelConversions + 1
  return result
end

-- Alias kept for older call sites / tests.
function AnimatedSprites:getVoxelCard(speciesId, animName, direction, frameIndex)
  return self:getBillboardCard(speciesId, animName, direction, frameIndex)
end

function AnimatedSprites:logFallbackOnce(speciesId, reason)
  local key = tostring(speciesId) .. ":" .. tostring(reason)
  if self._fallbackLogged[key] then return end
  self._fallbackLogged[key] = true
  self:_warn("species=%s enhanced sprite unavailable; %s",
             tostring(speciesId), tostring(reason))
end

function AnimatedSprites:summary()
  return {
    loaded = self.loaded,
    atlasReady = self.atlasReady,
    atlasWidth = self.atlasWidth,
    atlasHeight = self.atlasHeight,
    atlasPath = AnimatedSprites.ATLAS_REL,
    mappingDir = AnimatedSprites.MAPPING_DIR,
    mappingPattern = AnimatedSprites.MAPPING_PATTERN,
    mappingFilesFound = self.mappingFilesFound,
    mappedSpeciesCount = self.mappedSpeciesCount,
    validSpeciesCount = self.validSpeciesCount,
    partialSpeciesCount = self.partialSpeciesCount,
    invalidSpeciesCount = self.invalidSpeciesCount,
    missingSpeciesCount = self.missingSpeciesCount,
    voxelCacheEntries = (function()
      local n = 0
      for _, v in pairs(self.voxelCardCache) do
        if type(v) == "table" and v.status == "READY" then n = n + 1 end
      end
      return n
    end)(),
    voxelCacheHits = self.voxelCacheHits,
    voxelCacheMisses = self.voxelCacheMisses,
    voxelConversions = self.voxelConversions,
    error = self.error,
  }
end

function AnimatedSprites:statusLabel()
  if not self.loaded then return "NOT_LOADED" end
  if not self.atlasReady then return "ATLAS_FAILED" end
  return "READY"
end

return AnimatedSprites
