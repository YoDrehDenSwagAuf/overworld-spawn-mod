-- Resolve pre-built Gen1Recomp SpriteRenderer sheets for follow-sprites.
-- Sheets live under assets/generated/followsprites_runtime/ (Original) and
-- assets/generated/followsprites_runtime_relative/ (Relative size mode).
--
-- Path types (do not mix):
--   relativePath  — mod-root relative, e.g. assets/generated/.../001-normal.png
--   loadPath      — love.filesystem path via mod.assets:path(relativePath)
--                   e.g. mods/overworld_wild_spawns/assets/generated/.../001-normal.png
--
-- SpriteRenderer / Assets.image MUST receive loadPath, never a bare relativePath
-- and never an OS absolute path.
--
-- Relative sizing is baked into the PNG cards at build time — never scaled at
-- draw time. Original mode uses the prior followsprites_runtime/ folder so
-- hashes stay pixel-identical to previous releases.
local V = ...
local JsonDecode = V.require("json_decode")
local Config = V.require("config")

local RuntimeSheets = {}
RuntimeSheets.__index = RuntimeSheets

RuntimeSheets.DIR_ORIGINAL = "assets/generated/followsprites_runtime"
RuntimeSheets.DIR_RELATIVE = "assets/generated/followsprites_runtime_relative"
-- Back-compat alias: historical constant pointed at Original sheets.
RuntimeSheets.DIR_REL = RuntimeSheets.DIR_ORIGINAL
RuntimeSheets.MANIFEST_REL = RuntimeSheets.DIR_ORIGINAL .. "/manifest.json"
RuntimeSheets.FRAMES = 6
RuntimeSheets.WALKER = true
RuntimeSheets.SHEET_W = 16
RuntimeSheets.SHEET_H = 96

-- Verified against Gen1Recomp src/render/SpriteRenderer.lua:
--   STAND = { down = 0, up = 1, left = 2, right = 2 }
--   WALK  = { down = 3, up = 4, left = 5, right = 5 }
RuntimeSheets.STAND = { down = 0, up = 1, left = 2, right = 2 }
RuntimeSheets.WALK = { down = 3, up = 4, left = 5, right = 5 }

function RuntimeSheets.dirForSizeMode(sizeMode)
  if sizeMode == "relative" then
    return RuntimeSheets.DIR_RELATIVE
  end
  return RuntimeSheets.DIR_ORIGINAL
end

function RuntimeSheets.sheetFileName(speciesId, variant)
  local n = tonumber(speciesId)
  if not n or n < 1 then return nil end
  local v = (variant == "shiny" or variant == "s" or variant == true) and "shiny" or "normal"
  return string.format("%03d-%s.png", math.floor(n), v)
end

function RuntimeSheets.sheetRelPath(speciesId, variant, sizeMode)
  local name = RuntimeSheets.sheetFileName(speciesId, variant)
  if not name then return nil end
  return RuntimeSheets.dirForSizeMode(sizeMode) .. "/" .. name
end

function RuntimeSheets.manifestKey(speciesId, variant)
  local n = tonumber(speciesId)
  if not n or n < 1 then return nil end
  local v = (variant == "shiny" or variant == "s" or variant == true) and "shiny" or "normal"
  return tostring(math.floor(n)) .. ":" .. v
end

function RuntimeSheets.new(mod)
  local self = setmetatable({}, RuntimeSheets)
  self.mod = mod
  self.manifest = nil
  self.ready = false
  self.sheetCount = 0
  self.loadError = nil
  self._probeLog = {}
  self.sizeMode = "original"
  self.activeDir = RuntimeSheets.DIR_ORIGINAL
  self.manifestRel = RuntimeSheets.DIR_ORIGINAL .. "/manifest.json"
  return self
end

function RuntimeSheets:_modPath(rel)
  if type(rel) ~= "string" or rel == "" then return nil end
  if self.mod and self.mod.assets and type(self.mod.assets.path) == "function" then
    local ok, path = pcall(self.mod.assets.path, self.mod.assets, rel)
    if ok and type(path) == "string" and path ~= "" then
      return path
    end
  end
  -- Headless / unit tests: relative path is already loadable from cwd.
  return rel
end

function RuntimeSheets:_readBytes(rel)
  if type(rel) ~= "string" or rel == "" then return nil end
  if self.mod and type(self.mod.read) == "function" then
    local ok, data = pcall(self.mod.read, self.mod, rel)
    if ok and data ~= nil then
      if type(data) == "string" and data ~= "" then return data end
      -- Some stubs return truthy non-string; treat as present.
      if data ~= false then return data end
    end
  end
  local loadPath = self:_modPath(rel)
  if love and love.filesystem and love.filesystem.read and loadPath then
    local ok, data = pcall(love.filesystem.read, loadPath)
    if ok and type(data) == "string" and data ~= "" then return data end
  end
  -- Unit-test / tooling fallback (never used as SpriteRenderer def.image).
  local f = io.open(rel, "rb")
  if not f and V.path then
    f = io.open((V.path or ".") .. "/" .. rel, "rb")
  end
  if f then
    local data = f:read("*a")
    f:close()
    if type(data) == "string" and data ~= "" then return data end
  end
  return nil
end

-- True when the mod can read the relative asset. Does NOT use
-- love.filesystem.getInfo(relativePath) alone — that checks the wrong
-- namespace for packaged mods.
function RuntimeSheets:_assetPresent(rel)
  return self:_readBytes(rel) ~= nil
end

function RuntimeSheets:setSizeMode(mode)
  mode = Config.normalizeSpriteSizeMode(mode)
  if self.sizeMode == mode and self.ready then
    return self.ready, self.loadError
  end
  self.sizeMode = mode
  return self:load()
end

function RuntimeSheets:syncFromConfig()
  local mode = "original"
  if self.mod then
    mode = Config.spriteSizeMode(self.mod)
  end
  return self:setSizeMode(mode)
end

function RuntimeSheets:load()
  self.manifest = nil
  self.ready = false
  self.sheetCount = 0
  self.loadError = nil

  local preferred = RuntimeSheets.dirForSizeMode(self.sizeMode)
  local candidates = { preferred }
  -- Relative sheets may be missing on partial installs; fall back to Original.
  if preferred ~= RuntimeSheets.DIR_ORIGINAL then
    candidates[#candidates + 1] = RuntimeSheets.DIR_ORIGINAL
  end

  local chosenDir, chosenManifest, chosenRaw = nil, nil, nil
  for i = 1, #candidates do
    local dir = candidates[i]
    local manRel = dir .. "/manifest.json"
    local raw = self:_readBytes(manRel)
    if type(raw) == "string" and raw ~= "" then
      chosenDir = dir
      chosenManifest = manRel
      chosenRaw = raw
      break
    end
  end

  if not chosenRaw then
    self.activeDir = preferred
    self.manifestRel = preferred .. "/manifest.json"
    self.loadError = "runtime sheet manifest missing (mod.read / assets path)"
    return false, self.loadError
  end

  self.activeDir = chosenDir
  self.manifestRel = chosenManifest

  local ok, data = pcall(JsonDecode.decode, chosenRaw)
  if not ok or type(data) ~= "table" then
    self.loadError = "runtime sheet manifest invalid JSON"
    return false, self.loadError
  end
  self.manifest = data
  local sheets = data.sheets or {}
  local n = 0
  for _ in pairs(sheets) do n = n + 1 end
  self.sheetCount = n
  self.ready = n > 0
  if not self.ready then
    self.loadError = "runtime sheet manifest has zero sheets"
  elseif chosenDir ~= preferred and self.sizeMode == "relative" then
    self.loadError = "relative sheets missing; using original"
  end
  return self.ready, self.loadError
end

function RuntimeSheets:isReady()
  return self.ready == true
end

function RuntimeSheets:getManifestEntry(speciesId, variant)
  if not self.manifest or type(self.manifest.sheets) ~= "table" then
    return nil
  end
  local key = RuntimeSheets.manifestKey(speciesId, variant)
  if not key then return nil end
  local entry = self.manifest.sheets[key]
  if type(entry) ~= "table" then return nil end
  return entry, key
end

-- Returns relativePath, usedVariant, manifestEntry (or nils).
-- Prefers the manifest entry; constructed filename is a fallback only.
function RuntimeSheets:resolveRelativePath(speciesId, variant)
  local n = tonumber(speciesId)
  if not n or n < 1 then return nil, nil, nil end
  n = math.floor(n)
  local wantShiny = (variant == "shiny" or variant == "s" or variant == true)
  local order = wantShiny and { "shiny", "normal" } or { "normal" }
  local activeDir = self.activeDir or RuntimeSheets.DIR_ORIGINAL

  for _, v in ipairs(order) do
    local entry, key = self:getManifestEntry(n, v)
    if entry and type(entry.path) == "string" and entry.path ~= "" then
      -- Prefer written sheets; still accept "cached" from a re-run.
      local status = entry.status
      if status == nil or status == "written" or status == "cached" then
        local path = entry.path
        -- Manifest paths from older builds always pointed at Original.
        -- When activeDir is Relative, rewrite the folder prefix.
        if activeDir == RuntimeSheets.DIR_RELATIVE
           and path:find("^assets/generated/followsprites_runtime/") then
          path = path:gsub(
            "^assets/generated/followsprites_runtime/",
            RuntimeSheets.DIR_RELATIVE .. "/",
            1)
        end
        if self:_assetPresent(path) then
          return path, v, entry
        end
        -- Fall back to the literal manifest path (Original) if rewrite missing.
        if path ~= entry.path and self:_assetPresent(entry.path) then
          return entry.path, v, entry
        end
      end
    end
    local constructed = activeDir .. "/" .. (RuntimeSheets.sheetFileName(n, v) or "")
    if constructed and self:_assetPresent(constructed) then
      return constructed, v, entry
    end
    -- Last resort: Original folder when Relative sheet is absent for one species.
    if activeDir ~= RuntimeSheets.DIR_ORIGINAL then
      local orig = RuntimeSheets.DIR_ORIGINAL .. "/"
        .. (RuntimeSheets.sheetFileName(n, v) or "")
      if self:_assetPresent(orig) then
        return orig, v, entry
      end
    end
  end
  return nil, nil, nil
end

-- Returns loadPath (mod.assets:path), usedVariant, relativePath, entry.
function RuntimeSheets:resolveAssetPath(speciesId, variant)
  local rel, used, entry = self:resolveRelativePath(speciesId, variant)
  if not rel then return nil, nil, nil, nil end
  local loadPath = self:_modPath(rel)
  if type(loadPath) ~= "string" or loadPath == "" then
    return nil, nil, rel, entry
  end
  return loadPath, used, rel, entry
end

-- Back-compat alias: returns the LOAD path suitable for SpriteRenderer.def.image.
function RuntimeSheets:resolvePath(speciesId, variant)
  local loadPath, used = self:resolveAssetPath(speciesId, variant)
  return loadPath, used
end

function RuntimeSheets:hasSheet(speciesId, variant)
  local rel = self:resolveRelativePath(speciesId, variant)
  return rel ~= nil
end

function RuntimeSheets:spriteDef(speciesId, variant, spriteId)
  local loadPath, usedVariant, rel = self:resolveAssetPath(speciesId, variant)
  if not loadPath then return nil end
  return {
    image = loadPath,
    frames = RuntimeSheets.FRAMES,
    walker = true,
    trueColor = true,
    id = spriteId or ("SPRITE_OW_WILD_RT_" .. tostring(speciesId)),
  }, usedVariant, loadPath, rel
end

-- Probe Assets.image for a load path. Returns ok, err, w, h.
function RuntimeSheets.probeImage(loadPath)
  if type(loadPath) ~= "string" or loadPath == "" then
    return false, "empty load path", nil, nil
  end
  local okAssets, Assets = pcall(require, "src.render.Assets")
  if okAssets and Assets and type(Assets.image) == "function" then
    local ok, imgOrErr = pcall(Assets.image, loadPath)
    if ok and imgOrErr and type(imgOrErr.getDimensions) == "function" then
      local w, h = imgOrErr:getDimensions()
      return true, nil, w, h, imgOrErr
    end
    if not ok then
      return false, tostring(imgOrErr), nil, nil
    end
    return false, "Assets.image returned nil", nil, nil
  end
  -- Headless: verify file bytes exist via love or io when possible.
  if love and love.filesystem and love.filesystem.getInfo then
    local okInfo, info = pcall(love.filesystem.getInfo, loadPath)
    if okInfo and info then
      return true, "headless getInfo ok (no Assets)", nil, nil
    end
  end
  local f = io.open(loadPath, "rb")
  if not f and loadPath:match("^assets/") then
    f = io.open(loadPath, "rb")
  end
  if f then
    f:close()
    return true, "headless file present (no Assets)", 16, 96
  end
  return false, "Assets.image unavailable and file not found: " .. loadPath, nil, nil
end

function RuntimeSheets:probeRegistration(speciesId, variant)
  local n = tonumber(speciesId)
  local want = (variant == "shiny" or variant == "s" or variant == true) and "shiny" or "normal"
  local key = RuntimeSheets.manifestKey(n, want)
  local entry = key and self.manifest and self.manifest.sheets and self.manifest.sheets[key]
  local rel, used, entry2 = self:resolveRelativePath(n, want)
  entry = entry or entry2
  local loadPath = rel and self:_modPath(rel) or nil
  local okImg, imgErr, w, h = false, "not probed", nil, nil
  if loadPath then
    okImg, imgErr, w, h = RuntimeSheets.probeImage(loadPath)
  end
  local getInfoRel = nil
  if love and love.filesystem and love.filesystem.getInfo and rel then
    local ok, info = pcall(love.filesystem.getInfo, rel)
    getInfoRel = (ok and info) and "FOUND" or "MISSING"
  end
  return {
    speciesId = n,
    requestedVariant = want,
    usedVariant = used,
    sizeMode = self.sizeMode,
    activeDir = self.activeDir,
    manifestKey = key,
    manifestEntryFound = entry ~= nil,
    manifestStatus = entry and entry.status or nil,
    relativePath = rel,
    loadPath = loadPath,
    loveGetInfoRelative = getInfoRel,
    assetsImageOk = okImg == true,
    assetsImageError = imgErr,
    imageWidth = w,
    imageHeight = h,
    dimensionsOk = (w == RuntimeSheets.SHEET_W and h == RuntimeSheets.SHEET_H)
      or (w == nil and h == nil and okImg == true), -- headless without dims
  }
end

function RuntimeSheets:summary()
  return {
    ready = self.ready,
    sheetCount = self.sheetCount,
    dir = self.activeDir or RuntimeSheets.DIR_REL,
    sizeMode = self.sizeMode,
    frames = RuntimeSheets.FRAMES,
    walker = RuntimeSheets.WALKER,
    loadError = self.loadError,
    rightFacing = self.manifest and self.manifest.rightFacing or "mirror_left",
    manifestRel = self.manifestRel or RuntimeSheets.MANIFEST_REL,
  }
end

return RuntimeSheets
