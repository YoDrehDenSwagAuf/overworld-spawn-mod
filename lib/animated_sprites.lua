-- Follow-sprite overworld Pokemon: one PNG per species/variant (normal/shiny).
--
-- Identity = numeric National Pokedex / speciesId (never localized names).
-- Shared mapping JSON + lazy per-species image/quad caches.
-- Old Anima atlas path is intentionally unused at runtime.
local V = ...
local Config = V.require("config")
local JsonDecode = V.require("json_decode")
local Tile = V.require("tile")

local AnimatedSprites = {}
AnimatedSprites.__index = AnimatedSprites

local CELL = Tile.CELL
local MAX_SPECIES_GAME = 151

AnimatedSprites.MAPPING_REL =
  "assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json"
AnimatedSprites.SPRITE_DIR = "assets/enhanced_overworld/followsprites"
-- Legacy Anima atlas kept on disk / gitignored; not a runtime source.
AnimatedSprites.LEGACY_ATLAS_REL =
  "assets/enhanced_overworld/Pokemon_Sprites/POKEMON 1.png"
AnimatedSprites.LEGACY_MAPPING_DIR = "assets/enhanced_overworld/pokedex_mapping"

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

AnimatedSprites.RUNTIME_SHINY_SUPPORT = "NOT_AVAILABLE"
AnimatedSprites.SOURCE_FOLLOW = "FOLLOW_SPRITES"

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

AnimatedSprites.IDLE_FPS = 3
AnimatedSprites.WALK_FPS = 7
AnimatedSprites.IDLE_FRAME_DURATION = 1 / AnimatedSprites.IDLE_FPS
AnimatedSprites.WALK_FRAME_DURATION = 1 / AnimatedSprites.WALK_FPS
AnimatedSprites.VOXEL_CARD = 16
AnimatedSprites.BILLBOARD_CARD = 16

function AnimatedSprites.normalizeFacing(facing)
  if facing == nil then return "down" end
  local key = tostring(facing):lower()
  return FACING_MAP[key] or "down"
end

function AnimatedSprites.normalizeVariant(variant)
  if variant == true or variant == "shiny" or variant == "s" or variant == "SHINY" then
    return "shiny"
  end
  return "normal"
end

-- Compatibility aliases for older call sites / tests.
function AnimatedSprites.mappingFileName(_speciesId)
  return "followsprites_mapping.json"
end

function AnimatedSprites.mappingRelPath(_speciesId)
  return AnimatedSprites.MAPPING_REL
end

function AnimatedSprites.resolveSpeciesId(speciesKey, game, mod)
  if speciesKey == nil then return nil end
  local n = tonumber(speciesKey)
  if n and n >= 1 and math.floor(n) == n then
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

-- Gen1 / Gen1Recomp wild spawns currently have no reliable pre-battle shiny flag.
-- Do not invent random shinies for the overworld. Preview may force shiny.
function AnimatedSprites.resolveRuntimeVariant(entity, opts)
  opts = opts or {}
  if opts.forceVariant then
    return AnimatedSprites.normalizeVariant(opts.forceVariant)
  end
  if entity and entity.previewForceVariant then
    return AnimatedSprites.normalizeVariant(entity.previewForceVariant)
  end
  if AnimatedSprites.RUNTIME_SHINY_SUPPORT == "AVAILABLE" then
    if entity and (entity.isShiny == true or entity.shiny == true) then
      return "shiny"
    end
  end
  return "normal"
end

local function emptyAnimDirs()
  return { down = {}, up = {}, left = {}, right = {} }
end

local function framePixelRect(frame, cellW, cellH)
  local col = tonumber(frame.col)
  local row = tonumber(frame.row)
  local wCells = tonumber(frame.w) or 1
  local hCells = tonumber(frame.h) or 1
  if not col or not row then
    return nil, "frame missing col/row"
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

local function missingCoreDirs(entry)
  local missing = {}
  for _, anim in ipairs(CORE_ANIMS) do
    for _, dir in ipairs(DIRECTIONS) do
      local list = entry[anim] and entry[anim][dir]
      if type(list) ~= "table" or #list == 0 then
        missing[#missing + 1] = anim .. "." .. dir
      end
    end
  end
  return missing
end

local function deepCopyAnimTemplate(template)
  local out = emptyAnimDirs()
  if type(template) ~= "table" then return out end
  for _, dir in ipairs(DIRECTIONS) do
    local src = template[dir]
    local dest = {}
    if type(src) == "table" then
      for i, fr in ipairs(src) do
        dest[i] = {
          col = fr.col, row = fr.row,
          w = fr.w or 1, h = fr.h or 1,
        }
      end
    end
    out[dir] = dest
  end
  return out
end

function AnimatedSprites.new(mod)
  local self = setmetatable({}, AnimatedSprites)
  self.mod = mod
  self.mappingRoot = nil
  self.layout = nil
  self.animTemplate = nil
  self.rawSpecies = {}
  self.mappingsBySpeciesId = {}
  self.imageCache = {}       -- "speciesId:variant" -> Image|stub
  self.quadCache = {}        -- "speciesId:variant:anim:dir:frame"
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
  self.atlasReady = false -- kept for API compat (= mapping ready)
  self.mappingReady = false
  self.error = nil
  self._fallbackLogged = {}
  self._mappingWarnLogged = false
  -- Compat: some callers still read atlasImage; prefer getImage().
  self.atlasImage = nil
  self.atlasWidth = 0
  self.atlasHeight = 0
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

function AnimatedSprites:_normalizeFrames(rawList, cellW, cellH, errors, imageW, imageH)
  local out = {}
  if type(rawList) ~= "table" then return out end
  local maxW = imageW or self.atlasWidth or 0
  local maxH = imageH or self.atlasHeight or 0
  for _, raw in ipairs(rawList) do
    if type(raw) == "table" then
      local fr, err = framePixelRect(raw, cellW, cellH)
      if not fr then
        errors[#errors + 1] = err or "bad frame"
      else
        local x2 = fr.x + fr.width
        local y2 = fr.y + fr.height
        if maxW > 0 and maxH > 0
           and (fr.x < 0 or fr.y < 0 or x2 > maxW or y2 > maxH) then
          errors[#errors + 1] = string.format(
            "frame out of image bounds col=%s row=%s",
            tostring(raw.col), tostring(raw.row))
        else
          out[#out + 1] = fr
        end
      end
    end
  end
  return out
end

function AnimatedSprites:_buildVariantEntry(speciesId, variantName, rawVariant, animTemplate)
  -- The colored sheets are the default "normal" art (rawVariant.file/path);
  -- the explicit -grayscale sheets serve every PaletteFX mode except redpp
  -- (ADVANCED), which bakes real per-tile color onto overworld sprites.
  -- Headless / unknown mode defaults to the colored art.
  local useGray = not Config.paletteFxRedpp() and rawVariant ~= nil
    and ((type(rawVariant.grayscaleFile) == "string" and rawVariant.grayscaleFile ~= "")
      or (type(rawVariant.grayscalePath) == "string" and rawVariant.grayscalePath ~= ""))
  local grayFile = useGray
    and (rawVariant.grayscaleFile or rawVariant.file) or nil
  local entry = {
    speciesId = speciesId,
    variant = variantName,
    speciesName = nil,
    fileName = rawVariant and (grayFile or rawVariant.file) or nil,
    relPath = rawVariant and (grayFile
      and (rawVariant.grayscalePath
        or "assets/enhanced_overworld/followsprites/" .. grayFile)
      or (rawVariant.path or rawVariant.relPath)) or nil,
    form = rawVariant and rawVariant.form or nil,
    cellWidth = tonumber(rawVariant and rawVariant.tileWidth) or 0,
    cellHeight = tonumber(rawVariant and rawVariant.tileHeight) or 0,
    imageWidth = tonumber(rawVariant and rawVariant.imageWidth) or 0,
    imageHeight = tonumber(rawVariant and rawVariant.imageHeight) or 0,
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

  if not rawVariant then
    entry.errors[#entry.errors + 1] = variantName .. " variant missing"
    return entry
  end

  if entry.cellWidth <= 0 or entry.cellHeight <= 0 then
    entry.status = AnimatedSprites.STATUS.MAPPING_INVALID
    entry.errors[#entry.errors + 1] = "tileWidth/tileHeight must be > 0"
    return entry
  end
  if entry.imageWidth <= 0 or entry.imageHeight <= 0 then
    entry.status = AnimatedSprites.STATUS.MAPPING_INVALID
    entry.errors[#entry.errors + 1] = "imageWidth/imageHeight must be > 0"
    return entry
  end
  if (entry.imageWidth % 4) ~= 0 or (entry.imageHeight % 4) ~= 0 then
    entry.status = AnimatedSprites.STATUS.MAPPING_INVALID
    entry.errors[#entry.errors + 1] = "image size not divisible by 4"
    return entry
  end

  local frameErrors = {}
  local function ingest(animName)
    local rawAnim = animTemplate and animTemplate[animName]
    local dest = entry[animName] or emptyAnimDirs()
    entry[animName] = dest
    if type(rawAnim) ~= "table" then
      if animName == "idle" or animName == "walk" then
        frameErrors[#frameErrors + 1] = animName .. " missing"
      end
      return
    end
    for _, dir in ipairs(DIRECTIONS) do
      dest[dir] = self:_normalizeFrames(
        rawAnim[dir], entry.cellWidth, entry.cellHeight, frameErrors,
        entry.imageWidth, entry.imageHeight)
    end
  end

  for _, name in ipairs(CORE_ANIMS) do ingest(name) end

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
  end
  return entry
end

function AnimatedSprites:_materializeSpecies(speciesId)
  local raw = self.rawSpecies[speciesId] or self.rawSpecies[tostring(speciesId)]
  if not raw then
    return {
      speciesId = speciesId,
      normal = nil,
      shiny = nil,
      preferredForm = nil,
      alternateForms = nil,
      valid = false,
      status = AnimatedSprites.STATUS.MAPPING_MISSING,
      fileName = nil,
      usableFrameCount = 0,
      idle = emptyAnimDirs(),
      walk = emptyAnimDirs(),
      missingDirs = {},
      errors = { "species not in follow-sprite mapping" },
      partial = false,
    }
  end

  local normal = self:_buildVariantEntry(
    speciesId, "normal", raw.normal, self.animTemplate)
  local shiny = nil
  if raw.shiny then
    shiny = self:_buildVariantEntry(
      speciesId, "shiny", raw.shiny, self.animTemplate)
  end

  local primary = normal.valid and normal or (shiny and shiny.valid and shiny) or normal
  local entry = {
    speciesId = speciesId,
    preferredForm = raw.preferredForm,
    alternateForms = raw.alternateForms,
    normal = normal,
    shiny = shiny,
    -- Flatten primary variant for callers that read entry.idle/walk directly.
    idle = primary.idle,
    walk = primary.walk,
    cellWidth = primary.cellWidth,
    cellHeight = primary.cellHeight,
    imageWidth = primary.imageWidth,
    imageHeight = primary.imageHeight,
    fileName = primary.fileName,
    relPath = primary.relPath,
    form = primary.form,
    valid = primary.valid == true,
    partial = primary.partial == true,
    status = primary.status,
    errors = primary.errors,
    missingDirs = primary.missingDirs,
    usableFrameCount = primary.usableFrameCount,
    speciesName = nil,
  }
  return entry
end

function AnimatedSprites:load()
  if self.loaded then return true end

  self:_notice("Loading follow-sprite mapping")
  local text = self:_readText(AnimatedSprites.MAPPING_REL)
  if not text then
    self.loaded = true
    self.mappingReady = false
    self.atlasReady = false
    self.error = "followsprites mapping missing"
    if not self._mappingWarnLogged then
      self._mappingWarnLogged = true
      self:_warn("Follow-sprite mapping missing; using legacy/Pokédex sprites")
    end
    return false
  end

  local data, err = JsonDecode.decode(text)
  if not data then
    self.loaded = true
    self.mappingReady = false
    self.atlasReady = false
    self.error = "followsprites mapping decode failed: " .. tostring(err)
    self:_error("%s", self.error)
    return false
  end

  self.mappingRoot = data
  self.layout = data.layout or {}
  self.animTemplate = (self.layout.animations)
    or {
      idle = {
        down = { { col = 0, row = 0, w = 1, h = 1 } },
        left = { { col = 0, row = 1, w = 1, h = 1 } },
        right = { { col = 0, row = 2, w = 1, h = 1 } },
        up = { { col = 0, row = 3, w = 1, h = 1 } },
      },
      walk = {
        down = {
          { col = 0, row = 0, w = 1, h = 1 }, { col = 1, row = 0, w = 1, h = 1 },
          { col = 2, row = 0, w = 1, h = 1 }, { col = 3, row = 0, w = 1, h = 1 },
        },
        left = {
          { col = 0, row = 1, w = 1, h = 1 }, { col = 1, row = 1, w = 1, h = 1 },
          { col = 2, row = 1, w = 1, h = 1 }, { col = 3, row = 1, w = 1, h = 1 },
        },
        right = {
          { col = 0, row = 2, w = 1, h = 1 }, { col = 1, row = 2, w = 1, h = 1 },
          { col = 2, row = 2, w = 1, h = 1 }, { col = 3, row = 2, w = 1, h = 1 },
        },
        up = {
          { col = 0, row = 3, w = 1, h = 1 }, { col = 1, row = 3, w = 1, h = 1 },
          { col = 2, row = 3, w = 1, h = 1 }, { col = 3, row = 3, w = 1, h = 1 },
        },
      },
    }

  self.rawSpecies = {}
  local speciesTable = data.species or {}
  local count = 0
  for key, raw in pairs(speciesTable) do
    local id = tonumber(raw and raw.speciesId) or tonumber(key)
    if id then
      self.rawSpecies[id] = raw
      count = count + 1
    end
  end
  self.mappingFilesFound = 1

  self.validSpeciesCount = 0
  self.partialSpeciesCount = 0
  self.invalidSpeciesCount = 0
  self.missingSpeciesCount = 0
  self.mappedSpeciesCount = 0
  self.mappingsBySpeciesId = {}

  -- Materialize all known species (including >151) for preview; gameplay
  -- still only spawns supported Gen1 IDs.
  for id, _ in pairs(self.rawSpecies) do
    local entry = self:_materializeSpecies(id)
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
    end
  end

  -- Ensure 1..151 slots exist for diagnostics even if a Gen1 ID is absent.
  for id = 1, MAX_SPECIES_GAME do
    if not self.mappingsBySpeciesId[id] then
      local entry = self:_materializeSpecies(id)
      self.mappingsBySpeciesId[id] = entry
      self.missingSpeciesCount = self.missingSpeciesCount + 1
    end
  end

  self.loaded = true
  self.mappingReady = self.mappedSpeciesCount > 0
  self.atlasReady = self.mappingReady
  if self.mappingReady then
    self:_notice("Follow-sprite mapping ready: %d species (%d valid, %d partial)",
      self.mappedSpeciesCount, self.validSpeciesCount, self.partialSpeciesCount)
    self:_notice("Runtime shiny support: %s", AnimatedSprites.RUNTIME_SHINY_SUPPORT)
  else
    self.error = "no usable follow-sprite species"
    self:_warn("%s", self.error)
  end
  return self.mappingReady
end

function AnimatedSprites:isReady()
  return self.loaded and self.mappingReady == true
end

function AnimatedSprites:getMapping(speciesId)
  speciesId = tonumber(speciesId)
  if not speciesId then return nil end
  local cached = self.mappingsBySpeciesId[speciesId]
  if cached then return cached end
  if self.rawSpecies[speciesId] then
    local entry = self:_materializeSpecies(speciesId)
    self.mappingsBySpeciesId[speciesId] = entry
    return entry
  end
  return nil
end

function AnimatedSprites:getVariantMapping(speciesId, variant)
  local m = self:getMapping(speciesId)
  if not m then return nil end
  variant = AnimatedSprites.normalizeVariant(variant)
  if variant == "shiny" then
    if m.shiny and m.shiny.valid then return m.shiny end
    if m.normal and m.normal.valid then return m.normal end
    return m.shiny or m.normal
  end
  return m.normal or m
end

function AnimatedSprites:isEnhancedAvailable(speciesId, variant)
  if not self:isReady() then return false end
  local vm = self:getVariantMapping(speciesId, variant or "normal")
  return vm and vm.valid == true and vm.usableFrameCount > 0
end

function AnimatedSprites:hasVariant(speciesId, variant)
  local m = self:getMapping(speciesId)
  if not m then return false end
  variant = AnimatedSprites.normalizeVariant(variant)
  if variant == "shiny" then
    return m.shiny and m.shiny.valid == true
  end
  return m.normal and m.normal.valid == true
end

function AnimatedSprites:imageCacheKey(speciesId, variant)
  return string.format("%d:%s",
    tonumber(speciesId) or 0,
    AnimatedSprites.normalizeVariant(variant))
end

function AnimatedSprites:getImage(speciesId, variant)
  variant = AnimatedSprites.normalizeVariant(variant)
  local key = self:imageCacheKey(speciesId, variant)
  local cached = self.imageCache[key]
  if cached ~= nil then
    if cached == false then return nil end
    return cached
  end

  local vm = self:getVariantMapping(speciesId, variant)
  if not vm or not vm.relPath then
    self.imageCache[key] = false
    return nil
  end

  -- If shiny requested but fell back to normal mapping, load the normal file.
  local effectiveVariant = vm.variant or variant
  local effectiveKey = self:imageCacheKey(speciesId, effectiveVariant)
  if effectiveKey ~= key and self.imageCache[effectiveKey] ~= nil then
    local img = self.imageCache[effectiveKey]
    self.imageCache[key] = img
    return img ~= false and img or nil
  end

  local path = self:_modPath(vm.relPath)
  if not (love and love.graphics and love.graphics.newImage) then
    local stub = {
      _owwildStub = true,
      width = vm.imageWidth,
      height = vm.imageHeight,
      getDimensions = function(s) return s.width, s.height end,
      setFilter = function() end,
    }
    self.imageCache[key] = stub
    if effectiveKey ~= key then self.imageCache[effectiveKey] = stub end
    return stub
  end

  local ok, imageOrErr = pcall(love.graphics.newImage, path or vm.relPath)
  if not ok or not imageOrErr then
    self:_warn("follow sprite load failed species=%s variant=%s path=%s err=%s",
      tostring(speciesId), tostring(effectiveVariant),
      tostring(vm.relPath), tostring(imageOrErr))
    self.imageCache[key] = false
    return nil
  end
  if imageOrErr.setFilter then
    imageOrErr:setFilter("nearest", "nearest")
  end
  self.imageCache[key] = imageOrErr
  if effectiveKey ~= key then self.imageCache[effectiveKey] = imageOrErr end
  return imageOrErr
end

function AnimatedSprites:resolveFrames(speciesId, animName, direction, variant)
  local vm = self:getVariantMapping(speciesId, variant or "normal")
  if not vm or not vm.valid then return nil, nil end
  direction = AnimatedSprites.normalizeFacing(direction)
  animName = (animName == "walk") and "walk" or "idle"

  local function first(list)
    if type(list) == "table" and #list > 0 then return list end
    return nil
  end

  local primary = vm[animName] and first(vm[animName][direction])
  if primary then return primary, animName end

  if animName == "idle" then
    local walkSame = vm.walk and first(vm.walk[direction])
    if walkSame then return { walkSame[1] }, "walk" end
    local idleDown = vm.idle and first(vm.idle.down)
    if idleDown then return idleDown, "idle" end
    local walkDown = vm.walk and first(vm.walk.down)
    if walkDown then return { walkDown[1] }, "walk" end
  else
    local idleSame = vm.idle and first(vm.idle[direction])
    if idleSame then return idleSame, "idle" end
    local walkDown = vm.walk and first(vm.walk.down)
    if walkDown then return walkDown, "walk" end
    local idleDown = vm.idle and first(vm.idle.down)
    if idleDown then return idleDown, "idle" end
  end
  return nil, nil
end

function AnimatedSprites:getFrame(speciesId, animName, direction, frameIndex, variant)
  local frames = self:resolveFrames(speciesId, animName, direction, variant)
  if not frames or #frames == 0 then return nil end
  local idx = ((tonumber(frameIndex) or 1) - 1) % #frames + 1
  return frames[idx], #frames, idx
end

function AnimatedSprites:quadKey(speciesId, animName, direction, frameIndex, variant)
  return string.format("%d:%s:%s:%s:%d",
    tonumber(speciesId) or 0,
    AnimatedSprites.normalizeVariant(variant),
    tostring(animName),
    tostring(direction),
    tonumber(frameIndex) or 1)
end

function AnimatedSprites:getQuad(speciesId, animName, direction, frameIndex, variant)
  variant = AnimatedSprites.normalizeVariant(variant)
  local key = self:quadKey(speciesId, animName, direction, frameIndex, variant)
  local cached = self.quadCache[key]
  if cached ~= nil then return cached ~= false and cached or nil end

  local frame = self:getFrame(speciesId, animName, direction, frameIndex, variant)
  if not frame then
    self.quadCache[key] = false
    return nil
  end

  local vm = self:getVariantMapping(speciesId, variant)
  local imgW = (vm and vm.imageWidth) or 0
  local imgH = (vm and vm.imageHeight) or 0

  if not (love and love.graphics and love.graphics.newQuad) then
    local stub = {
      x = frame.x, y = frame.y, w = frame.width, h = frame.height,
      _owwildStub = true, frame = frame,
    }
    self.quadCache[key] = stub
    return stub
  end

  local img = self:getImage(speciesId, variant)
  if not img or img._owwildStub then
    -- Still allow stub quads in headless.
    if img and img._owwildStub then
      local stub = {
        x = frame.x, y = frame.y, w = frame.width, h = frame.height,
        _owwildStub = true, frame = frame,
      }
      self.quadCache[key] = stub
      return stub
    end
    self.quadCache[key] = false
    return nil
  end

  if imgW < 1 or imgH < 1 then
    local w, h = img:getDimensions()
    imgW, imgH = w or 0, h or 0
  end

  local ok, quad = pcall(love.graphics.newQuad,
    frame.x, frame.y, frame.width, frame.height, imgW, imgH)
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
  local scale = 1.0
  local minOpt = tonumber(opts.minSpriteSizeOption)
  if minOpt and minOpt > 0 then
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
    name = "idle",
    direction = AnimatedSprites.normalizeFacing(direction),
    frameIndex = 1,
    elapsed = 0,
    frameDuration = AnimatedSprites.IDLE_FRAME_DURATION,
    usingEnhancedSprite = true,
    fallbackLevel = nil,
    frameChanged = false,
    directionChanged = false,
    source = AnimatedSprites.SOURCE_FOLLOW,
    variant = "normal",
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
    or (prev.variant ~= nil and prev.variant ~= state.variant)
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

function AnimatedSprites:updateAnimation(state, speciesId, dt, moving, facing, movementProgress)
  if not state or not state.usingEnhancedSprite then return false end
  state.frameChanged = false
  state.directionChanged = false

  local prevName = state.name or state.type or "idle"
  local prevDir = state.direction
  local prevFrame = state.frameIndex or 1
  local variant = state.variant or "normal"

  local dir = AnimatedSprites.normalizeFacing(facing or state.direction)
  local name = moving and "walk" or "idle"
  self:setAnim(state, name, dir, false)

  local frames = self:resolveFrames(speciesId, state.name, state.direction, variant)
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
      variant = variant,
    })
  end

  return state.frameChanged or state.directionChanged
end

function AnimatedSprites:billboardKey(speciesId, animName, direction, frameIndex, frame, variant)
  local w = frame and frame.width or 16
  local h = frame and frame.height or 16
  return string.format("%d:%s:%s:%s:%d:%d:%d",
    tonumber(speciesId) or 0,
    AnimatedSprites.normalizeVariant(variant),
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
  local variant = anim.variant or entity.spriteVariant or "normal"
  return speciesId, animName, direction, frameIndex, anim, variant
end

function AnimatedSprites:getCurrentBillboardKey(entity)
  local speciesId, animName, direction, frameIndex, _, variant = self:entityAnimParts(entity)
  local frame = self:getFrame(speciesId, animName, direction, frameIndex, variant)
  return self:billboardKey(speciesId, animName, direction, frameIndex, frame, variant)
end

function AnimatedSprites:peekBillboardImage(key)
  local cached = self.voxelCardCache[key]
  if type(cached) == "table" and cached.status == "READY" and cached.image then
    return cached.image
  end
  return nil
end

function AnimatedSprites:prepareBillboardImage(entity, key)
  local speciesId, animName, direction, frameIndex, _, variant = self:entityAnimParts(entity)
  key = key or self:billboardKey(speciesId, animName, direction, frameIndex,
    self:getFrame(speciesId, animName, direction, frameIndex, variant), variant)
  local result = self:getBillboardCard(speciesId, animName, direction, frameIndex, variant)
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

function AnimatedSprites:getBillboardCard(speciesId, animName, direction, frameIndex, variant)
  variant = AnimatedSprites.normalizeVariant(variant)
  local frame = self:getFrame(speciesId, animName, direction, frameIndex, variant)
  local key = self:billboardKey(speciesId, animName, direction, frameIndex, frame, variant)
  local cached = self.voxelCardCache[key]
  if type(cached) == "table" and cached.status == "READY" and cached.image then
    self.voxelCacheHits = self.voxelCacheHits + 1
    cached._fromCache = true
    self.billboardCache = self.billboardCache or {}
    self.billboardCache[key] = cached.image
    return cached
  end
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
    self.voxelCardCache[key] = result
    return result
  end

  local sheet = self:getImage(speciesId, variant)
  if not sheet or sheet._owwildStub then
    if not (love and love.graphics and love.graphics.newImage) then
      return {
        status = "TEMPORARILY_UNAVAILABLE",
        reason = "graphics unavailable",
        key = key,
        retry = true,
      }
    end
    return {
      status = "TEMPORARILY_UNAVAILABLE",
      reason = "follow sprite image not ready",
      key = key,
      retry = true,
    }
  end

  if not (love and love.graphics and love.graphics.newCanvas) then
    return {
      status = "TEMPORARILY_UNAVAILABLE",
      reason = "newCanvas unavailable",
      key = key,
      retry = true,
    }
  end

  local quad = self:getQuad(speciesId, animName, direction, frameIndex, variant)
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
    if sheet.setFilter then sheet:setFilter("nearest", "nearest") end
    love.graphics.draw(sheet, quad, ox, oy, 0, fit, fit)
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

function AnimatedSprites:getVoxelCard(speciesId, animName, direction, frameIndex, variant)
  return self:getBillboardCard(speciesId, animName, direction, frameIndex, variant)
end

function AnimatedSprites:logFallbackOnce(speciesId, reason)
  local key = tostring(speciesId) .. ":" .. tostring(reason)
  if self._fallbackLogged[key] then return end
  self._fallbackLogged[key] = true
  self:_warn("species=%s follow sprite unavailable; %s",
             tostring(speciesId), tostring(reason))
end

function AnimatedSprites:summary()
  return {
    loaded = self.loaded,
    atlasReady = self.atlasReady,
    mappingReady = self.mappingReady,
    atlasWidth = self.atlasWidth,
    atlasHeight = self.atlasHeight,
    atlasPath = AnimatedSprites.MAPPING_REL,
    mappingDir = "assets/enhanced_overworld/followsprites_mapping",
    mappingPattern = "followsprites_mapping.json",
    spriteDir = AnimatedSprites.SPRITE_DIR,
    mappingFilesFound = self.mappingFilesFound,
    mappedSpeciesCount = self.mappedSpeciesCount,
    validSpeciesCount = self.validSpeciesCount,
    partialSpeciesCount = self.partialSpeciesCount,
    invalidSpeciesCount = self.invalidSpeciesCount,
    missingSpeciesCount = self.missingSpeciesCount,
    runtimeShinySupport = AnimatedSprites.RUNTIME_SHINY_SUPPORT,
    imageCacheEntries = (function()
      local n = 0
      for _, v in pairs(self.imageCache) do
        if v and v ~= false then n = n + 1 end
      end
      return n
    end)(),
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
  if not self.mappingReady then return "MAPPING_FAILED" end
  return "READY"
end

return AnimatedSprites
