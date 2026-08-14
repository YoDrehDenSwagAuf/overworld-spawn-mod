-- Sandbox-safe packaged-asset and generated-image access for Wilds.
--
-- Newest Gen1Recomp Sandbox.lua refuses the Love filesystem module and
-- directs mods to mod:read, mod.assets, and mod.storage. This helper does
-- not emulate that blocked module. It only exposes what Wilds actually needs:
--
--   WildsFs.readAsset(mod, rel)     packaged file bytes
--   WildsFs.assetExists(mod, rel)   packaged existence (cached)
--   WildsFs.pathExists(mod, path)   packaged rel or engine loadPath
--   WildsFs.enginePathExists(path)  SpriteRenderer / Assets loadPath
--   WildsFs.persistImageData(id, p) generated PNG via ImageData:encode
--
-- Path safety matches src/mods/SafePath.lua: relative only, no parent
-- segments, no absolute paths, no backslashes, no drive letters.
--
-- Generated luminance / water / bake sheets still need a path string
-- SpriteRenderer can hand to Assets.image. ImageData:encode("png", file)
-- is a Love image API (allowed) and writes the save directory. Persistent
-- mod.storage is not used: storage is playthrough-scoped data-only tables,
-- not SpriteRenderer paths.
local V = ...

local WildsFs = {}

local _assetExists = {}
local _engineExists = {}

local function cacheGet(cache, key)
  local hit = cache[key]
  if hit == true then return true end
  if hit == false then return false end
  return nil
end

local function hasParentSegment(path)
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then return true end
  end
  return false
end

function WildsFs.safeRel(path)
  if type(path) ~= "string" or path == "" then return nil end
  if path:sub(1, 1) == "/" then return nil end
  if path:find("\\", 1, true) then return nil end
  if path:match("^%a:") then return nil end
  local parts = {}
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then return nil end
    if segment ~= "." then parts[#parts + 1] = segment end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, "/")
end

local function looksPackagedRel(path)
  if type(path) ~= "string" then return false end
  return path:sub(1, 7) == "assets/" or path:sub(1, 4) == "lib/"
end

local function ioOpen(path, mode)
  if not (io and io.open) then return nil end
  local ok, f = pcall(io.open, path, mode or "rb")
  if ok then return f end
  return nil
end

local function headlessBytes(rel)
  local f = ioOpen(rel)
  if not f and V and V.path then
    f = ioOpen((V.path or ".") .. "/" .. rel)
  end
  if not f then
    f = ioOpen("./" .. rel)
  end
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  if type(data) == "string" and data ~= "" then return data end
  return nil
end

function WildsFs.readAsset(mod, path)
  local rel = WildsFs.safeRel(path)
  if not rel then return nil end
  if mod and type(mod.read) == "function" then
    local ok, data = pcall(mod.read, mod, rel)
    if ok and data ~= nil and data ~= false then
      if type(data) == "string" then
        _assetExists[rel] = data ~= ""
        if data ~= "" then return data end
      else
        _assetExists[rel] = true
        return data
      end
    end
  end
  local data = headlessBytes(rel)
  if data then
    _assetExists[rel] = true
    return data
  end
  _assetExists[rel] = false
  return nil
end

local function engineAssetsExists(path)
  local okA, Assets = pcall(require, "src.render.Assets")
  if not (okA and Assets and type(Assets.exists) == "function") then
    return nil
  end
  local ok, present = pcall(Assets.exists, path)
  if not ok then return nil end
  return present == true
end

local function engineImageExists(path)
  if love and love.image and love.image.newImageData then
    local ok = pcall(love.image.newImageData, path)
    if ok then return true end
  end
  if love and love.graphics and love.graphics.newImage then
    local ok, img = pcall(love.graphics.newImage, path)
    if ok and img then return true end
  end
  return false
end

function WildsFs.enginePathExists(path)
  if type(path) ~= "string" or path == "" then return false end
  if path:sub(1, 1) == "/" and not path:match("^mods/")
     and not path:match("^assets/")
     and not path:match("^save/") then
    return false
  end
  if hasParentSegment(path) or path:find("\\", 1, true) or path:match("^%a:") then
    return false
  end
  local cached = cacheGet(_engineExists, path)
  if cached == true then return true end

  local viaAssets = engineAssetsExists(path)
  if viaAssets == true then
    _engineExists[path] = true
    return true
  end
  if engineImageExists(path) then
    _engineExists[path] = true
    return true
  end
  local f = ioOpen(path)
  if not f then f = ioOpen("./" .. path) end
  if f then
    f:close()
    _engineExists[path] = true
    return true
  end
  -- Do not cache misses: other-mod packs can appear after the first probe
  -- (tests, hot-reload). Hits stay cached.
  return false
end

function WildsFs.assetExists(mod, path)
  local rel = WildsFs.safeRel(path)
  if not rel then return false end
  local cached = cacheGet(_assetExists, rel)
  if cached ~= nil then return cached end

  local loadPath = rel
  if mod and mod.assets and type(mod.assets.path) == "function" then
    local ok, p = pcall(mod.assets.path, mod.assets, rel)
    if ok and type(p) == "string" and p ~= "" then
      loadPath = p
    end
  end
  if WildsFs.enginePathExists(loadPath) then
    _assetExists[rel] = true
    return true
  end
  -- Existence-only: do not keep PNG bytes. Cache both hits and misses so
  -- missing Fakemon / unknown species are not re-read every resolve.
  local data = WildsFs.readAsset(mod, rel)
  return data ~= nil
end

function WildsFs.pathExists(mod, path)
  if type(path) ~= "string" or path == "" then return false end
  if looksPackagedRel(path) and WildsFs.assetExists(mod, path) then
    return true
  end
  return WildsFs.enginePathExists(path)
end

-- ImageData:encode("png", filename) writes the LÖVE save directory through
-- the Love image API. SpriteRenderer / Assets.image consume that path.
-- Subdirectory writes may fail without createDirectory; fall back to a
-- flattened filename in the save-dir root.
function WildsFs.persistImageData(imageData, outPath)
  if not (imageData and imageData.encode) then return nil end
  if type(outPath) ~= "string" or outPath == "" then return nil end
  if outPath:find("\\", 1, true) or outPath:match("^%a:")
     or outPath:sub(1, 1) == "/" or hasParentSegment(outPath) then
    return nil
  end
  local ok = pcall(function()
    imageData:encode("png", outPath)
  end)
  if ok then
    _engineExists[outPath] = true
    return outPath
  end
  local flat = outPath:gsub("/", "_")
  if flat ~= outPath then
    ok = pcall(function()
      imageData:encode("png", flat)
    end)
    if ok then
      _engineExists[flat] = true
      return flat
    end
  end
  return nil
end

function WildsFs.resetCaches()
  _assetExists = {}
  _engineExists = {}
end

return WildsFs
