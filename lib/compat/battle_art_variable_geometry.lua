-- In-memory compatibility adapter: Battle Art Voxel SpriteBillboards.mesh
-- consumes Wilds / Gen1Recomp variable SpriteDef geometry.
--
-- Battle Art 1.8.x still hardcodes 16×16 in lib/SpriteBillboards.lua
-- (fy = frame * 16, UV 16-wide, verts 0..16). It does expose
-- exports.lib.require, the same public module table VoxelScene already
-- uses. Wilds wraps SpriteBillboards.mesh / shadowQuad on that table —
-- the same pattern as VoxelScene.drawEntity for water shadows.
--
-- Wilds does NOT copy VoxelScene, shaders, camera, or mesher code.
-- Vanilla 16×16 defs call the original mesh() unchanged.
--
-- Pivot: Mat4.billboard / caster still apply T(-8,0,0). Variable quads
-- are authored so the SpriteDef anchor lands on that pivot (vanilla
-- 16×16 + default anchors produce identical 0..16 verts).
local V = ...
local DebugLog = V.require("debug_log")

local Adapter = {}

Adapter.BATTLE_ART_ID = "BATTLE_ART_VOXEL_FORK"
Adapter.FAIL_LOG =
  "Battle Art variable sprite adapter unavailable; using Classic Voxel geometry."

local INSET_U = 0.02
local INSET_V = 0.05
-- Battle Art's billboard / caster matrices always apply T(-8, 0, 0).
local PIVOT_X = 8

local _state = "idle" -- idle | installed | native | failed | absent
local _reason = nil
local _loggedFail = false
local _origMesh = nil
local _origInvalidate = nil
local _varMeshes = {}
local _wrappedTable = nil
local _Voxel3D = nil
local _Assets = nil

local function logFail(mod, why)
  if _loggedFail then return end
  _loggedFail = true
  local msg = Adapter.FAIL_LOG
  if why and why ~= "" then
    msg = msg .. " (" .. tostring(why) .. ")"
  end
  if DebugLog and DebugLog.warn then
    DebugLog.warn(mod, "%s", msg)
  elseif mod and mod.log and mod.log.warn then
    mod.log:warn("[WildsOfKanto][WARN] %s", msg)
  end
end

local function logOk(mod, detail)
  if DebugLog and DebugLog.info then
    DebugLog.info(mod, "Battle Art variable sprite adapter installed (%s)",
      tostring(detail or "mesh wrap"))
  end
end

function Adapter.findBattleArt(mod)
  if not mod or type(mod.find) ~= "function" then return nil end
  local ok, hit = pcall(mod.find, mod, Adapter.BATTLE_ART_ID)
  if ok and hit then return hit end
  return nil
end

function Adapter.reset()
  if _wrappedTable and _origMesh then
    _wrappedTable.mesh = _origMesh
    _wrappedTable.shadowQuad = _origMesh
    if _origInvalidate then
      _wrappedTable.invalidate = _origInvalidate
    end
    _wrappedTable._wildsVariableGeometryWrapped = nil
  end
  _state = "idle"
  _reason = nil
  _loggedFail = false
  _origMesh = nil
  _origInvalidate = nil
  _varMeshes = {}
  _wrappedTable = nil
  _Voxel3D = nil
  _Assets = nil
end

function Adapter.isInstalled()
  return _state == "installed" or _state == "native"
end

function Adapter.isSupported()
  return Adapter.isInstalled()
end

function Adapter.supportsVariableGeometry()
  return _state == "installed" or _state == "native"
end

function Adapter.supportReason()
  return _reason
end

function Adapter.state()
  return _state
end

--- True when the def needs a non-16×16 card (or a non-default anchor).
function Adapter.needsVariableGeometry(def)
  if type(def) ~= "table" then return false end
  local fw = tonumber(def.frameWidth)
  local fh = tonumber(def.frameHeight)
  local ax = tonumber(def.anchorX)
  local ay = tonumber(def.anchorY)
  if fw == nil and fh == nil and ax == nil and ay == nil then
    return false
  end
  fw = fw or 16
  fh = fh or 16
  if ax == nil then ax = fw / 2 end
  if ay == nil then ay = fh end
  if fw == 16 and fh == 16 and ax == 8 and ay == 16 then
    return false
  end
  return fw > 0 and fh > 0
end

function Adapter.resolveGeometry(def)
  local fw = tonumber(def.frameWidth) or 16
  local fh = tonumber(def.frameHeight) or 16
  local ax = tonumber(def.anchorX)
  local ay = tonumber(def.anchorY)
  if ax == nil then ax = fw / 2 end
  if ay == nil then ay = fh end
  return fw, fh, ax, ay
end

function Adapter.cacheKey(def, frame, fw, fh, ax, ay)
  return table.concat({
    tostring(def.image),
    tostring(frame or 0),
    tostring(fw),
    tostring(fh),
    tostring(ax),
    tostring(ay),
  }, "#")
end

--- Local-space quad that lands the SpriteDef anchor on Battle Art's T(-8)
--- pivot. Returns x0,y0,x1,y1 (bottom-left / top-right in Y-up mesh space).
function Adapter.localQuad(fw, fh, ax, ay)
  local x0 = PIVOT_X - ax
  local x1 = x0 + fw
  -- 2D anchorY is measured down from the top of the frame. Mesh Y is up
  -- from the feet pivot: top = anchorY, bottom = anchorY - frameHeight.
  local y0 = ay - fh
  local y1 = ay
  return x0, y0, x1, y1
end

function Adapter.uvRect(fw, fh, frame, iw, ih)
  local fy = (tonumber(frame) or 0) * fh
  if fy + fh > ih then
    return nil, "frame_overflow"
  end
  local u0 = INSET_U / iw
  local u1 = (fw - INSET_U) / iw
  local v0 = (fy + INSET_V) / ih
  local v1 = (fy + fh - INSET_V) / ih
  return u0, v0, u1, v1, fy
end

local function sourceLooksNative(src)
  if type(src) ~= "string" or src == "" then return false end
  local usesGeometry = src:find("getPoseGeometry", 1, true)
    or src:find("getFrameGeometry", 1, true)
    or src:find("frameWidth", 1, true)
  local fixed16 = src:find("frame %*% 16", 1)
    or src:find("frame * 16", 1, true)
    or src:find("{ 16, 16, 0", 1, true)
  return usesGeometry and not fixed16
end

local function battleArtIsNative(ds)
  if ds.exports and (ds.exports.variableSpriteGeometry == true
      or ds.exports.supportsVariableSizeSprites == true
      or ds.exports.supportsVariableSpriteGeometry == true) then
    return true, "exports_flag"
  end
  if type(ds.read) == "function" then
    local ok, data = pcall(ds.read, ds, "lib/SpriteBillboards.lua")
    if ok and sourceLooksNative(data) then
      return true, "sprite_billboards_geometry_api"
    end
  end
  return false, nil
end

local function getImageSize(imagePath)
  if _Assets and type(_Assets.image) == "function" then
    local ok, img = pcall(_Assets.image, imagePath)
    if ok and img and type(img.getDimensions) == "function" then
      return img:getDimensions()
    end
  end
  return nil, nil
end

local function buildVariableCard(def, frame)
  local fw, fh, ax, ay = Adapter.resolveGeometry(def)
  local iw, ih = getImageSize(def.image)
  if not iw or not ih or iw <= 0 or ih <= 0 then
    return nil, "image_unavailable"
  end
  local u0, v0, u1, v1, _fy = Adapter.uvRect(fw, fh, frame, iw, ih)
  if not u0 then
    return nil, v0 or "frame_overflow"
  end
  local x0, y0, x1, y1 = Adapter.localQuad(fw, fh, ax, ay)
  local verts = {
    { x0, y0, 0, u0, v1, 1 }, { x1, y0, 0, u1, v1, 1 },
    { x1, y1, 0, u1, v0, 1 }, { x0, y1, 0, u0, v0, 1 },
  }
  local indices = {}
  _Voxel3D.pushQuad(indices, 0)
  local mesh = _Voxel3D.newMesh(verts, indices)
  if not mesh then
    return nil, "newMesh_nil"
  end
  return mesh
end

local function wrappedMesh(def, frame)
  if type(def) ~= "table" or type(def.image) ~= "string" then
    return _origMesh(def, frame)
  end
  if not Adapter.needsVariableGeometry(def) then
    return _origMesh(def, frame)
  end
  local fw, fh, ax, ay = Adapter.resolveGeometry(def)
  local key = Adapter.cacheKey(def, frame, fw, fh, ax, ay)
  if _varMeshes[key] == nil then
    local ok, meshOrErr = pcall(buildVariableCard, def, frame)
    if ok and meshOrErr then
      _varMeshes[key] = meshOrErr
    else
      _varMeshes[key] = false
    end
  end
  if _varMeshes[key] then
    return _varMeshes[key]
  end
  return _origMesh(def, frame)
end

local function wrappedInvalidate()
  _varMeshes = {}
  if _origInvalidate then
    return _origInvalidate()
  end
end

local function wrapBillboards(SpriteBillboards, Voxel3D, Assets)
  if SpriteBillboards._wildsVariableGeometryWrapped then
    return true, "already_wrapped"
  end
  if type(SpriteBillboards.mesh) ~= "function" then
    return false, "SpriteBillboards.mesh missing"
  end
  if not Voxel3D or type(Voxel3D.newMesh) ~= "function"
      or type(Voxel3D.pushQuad) ~= "function" then
    return false, "Voxel3D.newMesh/pushQuad missing"
  end
  _origMesh = SpriteBillboards.mesh
  _origInvalidate = SpriteBillboards.invalidate
  _Voxel3D = Voxel3D
  _Assets = Assets
  _varMeshes = {}
  _wrappedTable = SpriteBillboards
  SpriteBillboards.mesh = wrappedMesh
  -- shadowQuad is assigned as an alias at Battle Art load time; re-point it
  -- so solid / shadow / occlusion silhouette share the same geometry.
  SpriteBillboards.shadowQuad = wrappedMesh
  SpriteBillboards.invalidate = wrappedInvalidate
  SpriteBillboards._wildsVariableGeometryWrapped = true
  if Assets and type(Assets.register) == "function" then
    pcall(Assets.register, wrappedInvalidate)
  end
  return true, "wrapped_mesh"
end

function Adapter.install(mod)
  if _state == "installed" or _state == "native" then
    return true, _reason
  end
  if _state == "failed" then
    return false, _reason
  end

  local ok, err = pcall(function()
    local ds = Adapter.findBattleArt(mod)
    if not ds then
      _state = "absent"
      _reason = "battle_art_absent"
      return
    end
    local native, nativeWhy = battleArtIsNative(ds)
    if native then
      _state = "native"
      _reason = nativeWhy
      return
    end
    local lib = ds.exports and ds.exports.lib
    if not (lib and type(lib.require) == "function") then
      error("exports.lib.require missing")
    end
    local okSB, SpriteBillboards = pcall(lib.require, "SpriteBillboards")
    if not (okSB and type(SpriteBillboards) == "table") then
      error("SpriteBillboards module missing")
    end
    local okV3, Voxel3D = pcall(lib.require, "Voxel3D")
    if not (okV3 and type(Voxel3D) == "table") then
      error("Voxel3D module missing")
    end
    local Assets = nil
    local okA, A = pcall(require, "src.render.Assets")
    if okA and type(A) == "table" then Assets = A end
    local wrapped, why = wrapBillboards(SpriteBillboards, Voxel3D, Assets)
    if not wrapped then
      error(why or "wrap failed")
    end
    _state = "installed"
    _reason = why
  end)

  if not ok then
    _state = "failed"
    _reason = tostring(err)
    logFail(mod, _reason)
    return false, _reason
  end
  if _state == "absent" then
    return false, _reason
  end
  if _state == "failed" then
    logFail(mod, _reason)
    return false, _reason
  end
  logOk(mod, _reason)
  return true, _reason
end

return Adapter
