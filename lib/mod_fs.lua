-- Wilds filesystem / storage access for the Gen1Recomp mod sandbox.
--
-- Production runtime must NOT touch love.filesystem (blocked for mods).
-- Use:
--   * mod:read / mod.assets:path for packaged Wilds assets
--   * engine Assets.exists / ImageData (C-level) for virtual-path probes
--   * mod.storage only for data-only tables (never raw PNG bytes)
--
-- Optional headless `io` is used ONLY when present (unit tests outside sandbox).
local V = ...

local WildsFs = {}

-- Session caches: avoid repeated mod:read / existence probes on hot paths.
local _assetExistCache = {} -- rel -> boolean
local _assetByteCache = {}  -- rel -> string when cacheBytes requested
local _pathExistCache = {}  -- virtual path -> boolean
local _derivedImages = {}   -- virtual path -> love Image (memory cache)
local _assetsBridged = false

WildsFs._stats = {
  assetReads = 0,
  pathProbes = 0,
}

local function hasIo()
  return type(io) == "table" and type(io.open) == "function"
end

--- Reject path traversal / absolute OS paths for relative mod assets.
function WildsFs.isSafeRel(path)
  if type(path) ~= "string" or path == "" then return false end
  if path:find("%.%.") then return false end
  if path:sub(1, 1) == "/" then return false end
  if path:match("^%a:[/\\]") then return false end
  if path:find("\\") then return false end
  return true
end

--- Conservative storage key (letters, digits, _, -, / segments).
function WildsFs.isSafeStorageKey(key)
  if type(key) ~= "string" or key == "" then return false end
  if key:sub(1, 1) == "/" or key:sub(-1) == "/" or key:find("//", 1, true) then
    return false
  end
  for segment in key:gmatch("[^/]+") do
    if not segment:match("^[%w_-]+$") then return false end
  end
  return true
end

function WildsFs.clearCaches()
  _assetExistCache = {}
  _assetByteCache = {}
  _pathExistCache = {}
end

function WildsFs.clearDerivedImages()
  _derivedImages = {}
end

local function tryAssets()
  local ok, Assets = pcall(require, "src.render.Assets")
  if ok and Assets then return Assets end
  return nil
end

-- ------- packaged Wilds assets (mod:read)

function WildsFs.readAsset(mod, rel, opts)
  opts = opts or {}
  WildsFs._stats.assetReads = (WildsFs._stats.assetReads or 0) + 1
  if not WildsFs.isSafeRel(rel) then return nil, "unsafe_path" end
  if opts.cache ~= false and type(_assetByteCache[rel]) == "string" then
    return _assetByteCache[rel]
  end
  if mod and type(mod.read) == "function" then
    local ok, data = pcall(mod.read, mod, rel)
    if ok and type(data) == "string" and data ~= "" then
      if opts.cacheBytes then
        _assetByteCache[rel] = data
      end
      _assetExistCache[rel] = true
      return data
    end
    if ok and data ~= nil and data ~= false and type(data) ~= "string" then
      _assetExistCache[rel] = true
      return data
    end
  end
  -- Unit-test / headless only (sandbox has no io).
  if hasIo() then
    local f = io.open(rel, "rb")
    if not f and V.path then
      f = io.open((V.path or ".") .. "/" .. rel, "rb")
    end
    if f then
      local data = f:read("*a")
      f:close()
      if type(data) == "string" and data ~= "" then
        _assetExistCache[rel] = true
        return data
      end
    end
  end
  _assetExistCache[rel] = false
  return nil, "not_found"
end

function WildsFs.assetExists(mod, rel)
  if not WildsFs.isSafeRel(rel) then return false end
  local cached = _assetExistCache[rel]
  if cached ~= nil then return cached end
  local data = WildsFs.readAsset(mod, rel, { cacheBytes = false })
  return data ~= nil
end

function WildsFs.assetPath(mod, rel)
  if not WildsFs.isSafeRel(rel) then return nil end
  if mod and mod.assets and type(mod.assets.path) == "function" then
    local ok, path = pcall(mod.assets.path, mod.assets, rel)
    if ok and type(path) == "string" and path ~= "" then return path end
  end
  return rel
end

-- ------- virtual-path probes (engine Assets or love.image C API)

--- True when a LÖVE virtual path is loadable (mods/..., save-dir cache, …).
-- Uses engine Assets.exists when available (engine holds real love.filesystem).
-- Never calls love.filesystem from mod code.
function WildsFs.pathExists(path)
  WildsFs._stats.pathProbes = (WildsFs._stats.pathProbes or 0) + 1
  if type(path) ~= "string" or path == "" then return false end
  if _derivedImages[path] then return true end
  local cached = _pathExistCache[path]
  if cached ~= nil then return cached end

  local Assets = tryAssets()
  if Assets and type(Assets.exists) == "function" then
    local ok, present = pcall(Assets.exists, path)
    if ok then
      _pathExistCache[path] = present == true
      return _pathExistCache[path]
    end
  end

  -- C-level probe via sandboxed love.image (allowed; filesystem Lua is not).
  if love and love.image and type(love.image.newImageData) == "function" then
    local ok, id = pcall(love.image.newImageData, path)
    if ok and id then
      if type(id.release) == "function" then pcall(id.release, id) end
      _pathExistCache[path] = true
      return true
    end
  end

  if hasIo() then
    local f = io.open(path, "rb")
    if f then f:close(); _pathExistCache[path] = true; return true end
  end

  _pathExistCache[path] = false
  return false
end

function WildsFs.invalidatePath(path)
  if type(path) == "string" then
    _pathExistCache[path] = nil
  end
end

-- ------- derived Image registration (memory cache for luminance / bake)

function WildsFs.ensureAssetsBridge()
  if _assetsBridged then return true end
  local Assets = tryAssets()
  if not (Assets and type(Assets.image) == "function") then return false end
  local origImage = Assets.image
  Assets.image = function(path)
    local hit = _derivedImages[path]
    if hit then return hit end
    return origImage(path)
  end
  _assetsBridged = true
  return true
end

function WildsFs.registerDerivedImage(path, image)
  if type(path) ~= "string" or path == "" or not image then return false end
  WildsFs.ensureAssetsBridge()
  _derivedImages[path] = image
  _pathExistCache[path] = true
  return true
end

function WildsFs.getDerivedImage(path)
  return _derivedImages[path]
end

--- Persist ImageData to the LÖVE save namespace via ImageData:encode (C API).
-- Does not call love.filesystem. Prefer flat filenames (no mkdir).
-- Also registers a love Image under `path` for the Assets bridge.
function WildsFs.encodePngToPath(imageData, path)
  if not (imageData and type(path) == "string" and path ~= "") then
    return false, "bad_args"
  end
  if type(imageData.encode) ~= "function" then
    return false, "no_encode"
  end
  local ok, err = pcall(imageData.encode, imageData, "png", path)
  if not ok then
    return false, err
  end
  WildsFs.invalidatePath(path)
  if love and love.graphics and love.graphics.newImage then
    local okImg, img = pcall(love.graphics.newImage, imageData)
    if okImg and img then
      WildsFs.registerDerivedImage(path, img)
    end
  end
  _pathExistCache[path] = true
  return true
end

--- Build Image from ImageData and register under path (memory-only, no disk).
function WildsFs.registerFromImageData(path, imageData)
  if not (love and love.graphics and love.graphics.newImage) then
    return false, "no_graphics"
  end
  local ok, img = pcall(love.graphics.newImage, imageData)
  if not ok or not img then return false, img end
  WildsFs.registerDerivedImage(path, img)
  return true
end

-- ------- mod.storage (data-only tables; optional durable metadata)

function WildsFs.writeStorage(mod, game, key, value)
  if not WildsFs.isSafeStorageKey(key) then
    return false, "invalid_key", "unsafe storage key"
  end
  if type(value) ~= "table" then
    return false, "encode_failed", "Storage values must be data-only tables"
  end
  local storage = mod and mod.storage
  if not (storage and type(storage.write) == "function") then
    return false, "storage_unavailable", "mod.storage missing"
  end
  return storage:write(game, key, value)
end

function WildsFs.readStorage(mod, game, key)
  if not WildsFs.isSafeStorageKey(key) then
    return nil, "invalid_key", "unsafe storage key"
  end
  local storage = mod and mod.storage
  if not (storage and type(storage.read) == "function") then
    return nil, "storage_unavailable", "mod.storage missing"
  end
  return storage:read(game, key)
end

function WildsFs.storageExists(mod, game, key)
  local data = WildsFs.readStorage(mod, game, key)
  return data ~= nil
end

return WildsFs
