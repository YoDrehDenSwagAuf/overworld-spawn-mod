-- Optional Dramatic Shape Voxel Mod adapter.
--
-- The Voxel Mod (DRAMATIC_SHAPE) billboards every entry in ow.entities via
-- pose() → sprite.def / sprite:resolveImage() / px,py / cellX,cellY
-- (see DramaticShapeVoxelMod lib/VoxelScene.lua posesOf / drawEntity).
--
-- A single throw inside that path marks the entire voxel render pipeline
-- broken for the session (Gen1Recomp Pipelines.guard). Wilds of Kanto must
-- therefore never put unsafe entities into ow.entities, and must never mutate
-- private Voxel Mod structures.
--
-- This adapter is read-mostly: it validates / prepares entity fields that the
-- Voxel Mod will observe, and on failure disables Voxel presentation for that
-- one entity while keeping 2D + world simulation alive.
local V = ...
local DebugLog = V.require("debug_log")
local Movement = V.require("movement")

local VoxelAdapter = {}
VoxelAdapter.__index = VoxelAdapter

function VoxelAdapter.new(mod)
  local self = setmetatable({}, VoxelAdapter)
  self.mod = mod
  self.present = false
  self.lastScanAt = 0
  return self
end

function VoxelAdapter:refreshPresence()
  local dramatic = self.mod.find and self.mod.find("DRAMATIC_SHAPE")
  self.present = dramatic ~= nil
  return self.present
end

function VoxelAdapter:isPresent()
  if self.present then return true end
  return self:refreshPresence()
end

-- Fields the Voxel Mod reads from every ow.entities entry.
function VoxelAdapter.isPoseSafe(entity)
  if not entity then
    return false, "nil entity"
  end
  if entity.hiddenEncounter or entity.visibleSprite == false then
    return false, "hidden entity must not join ow.entities for Voxel"
  end
  if entity.voxelDisabled then
    return false, entity.voxelLastError or "voxel disabled for entity"
  end
  local sprite = entity.sprite
  if sprite == nil then
    return false, "sprite is nil"
  end
  if type(sprite) ~= "table" and type(sprite) ~= "userdata" then
    return false, "sprite is not a table"
  end
  if sprite.def == nil then
    return false, "sprite.def missing"
  end
  if type(sprite.resolveImage) ~= "function" then
    return false, "sprite:resolveImage missing"
  end
  if type(entity.pose) ~= "function" then
    return false, "entity:pose missing"
  end
  if entity.px == nil or entity.py == nil then
    return false, "px/py missing"
  end
  if entity.cellX == nil or entity.cellY == nil then
    return false, "cellX/cellY missing"
  end
  if type(entity.px) ~= "number" or type(entity.py) ~= "number" then
    return false, "px/py not numeric"
  end
  if type(entity.cellX) ~= "number" or type(entity.cellY) ~= "number" then
    return false, "cellX/cellY not numeric"
  end
  return true
end

-- Probe pose() the way VoxelScene.posesOf does, without drawing.
function VoxelAdapter.probePose(entity)
  local okSafe, why = VoxelAdapter.isPoseSafe(entity)
  if not okSafe then return false, why end
  local ok, sprite, vx, vy, facing, phase, flip = pcall(function()
    return entity:pose()
  end)
  if not ok then
    return false, "pose() threw: " .. tostring(sprite)
  end
  if sprite == nil then
    return false, "pose() returned nil sprite"
  end
  if sprite.def == nil then
    return false, "pose() sprite.def nil"
  end
  if type(sprite.resolveImage) ~= "function" then
    return false, "pose() sprite lacks resolveImage"
  end
  if type(vx) ~= "number" or type(vy) ~= "number" then
    return false, "pose() pixel coords invalid"
  end
  -- Mirror VoxelScene: py comes from entity.py, lift = entity.py - visualY.
  if entity.py == nil then
    return false, "entity.py nil after pose"
  end
  return true, {
    sprite = sprite,
    px = vx,
    py = entity.py,
    facing = facing,
    phase = phase,
    flip = flip,
    lift = entity.py - vy,
  }
end

function VoxelAdapter:markFallback(entity, err)
  if not entity then return end
  entity.voxelDisabled = true
  entity.voxelRegistered = false
  entity.voxelUpdateOk = false
  entity.voxelLastError = tostring(err)
  entity.render2DFallback = true
  local okLog, logErr = pcall(DebugLog.error, self.mod,
    "Voxel entity update failed for %s. Falling back to 2D rendering for this entity. (%s)",
    tostring(entity.id or entity.spawnId or "?"),
    tostring(err))
  if not okLog and self.mod and self.mod.log and self.mod.log.info then
    self.mod.log:info("[WildsOfKanto][ERROR] Voxel entity update failed for %s. Falling back to 2D rendering for this entity. (%s)",
      tostring(entity.id or entity.spawnId or "?"), tostring(err))
  elseif not okLog then
    -- Headless tests may lack mod.log; keep the entity flag anyway.
    logErr = logErr
  end
end

-- Keep movement/position fields Voxel-readable. Never writes into DRAMATIC_SHAPE.
function VoxelAdapter:updateEntity(entity)
  if not entity or entity.state == "removed" then return false end
  if entity.hiddenEncounter or entity.visibleSprite == false then
    entity.voxelRegistered = false
    return false
  end
  if entity.voxelDisabled then
    entity.voxelRegistered = false
    return false
  end

  local okMove, moveErr = pcall(Movement.syncLegacyFields, entity)
  if not okMove then
    self:markFallback(entity, moveErr)
    return false
  end

  local ok, detail = VoxelAdapter.probePose(entity)
  if not ok then
    self:markFallback(entity, detail)
    return false
  end

  entity.voxelRegistered = self:isPresent()
  entity.voxelUpdateOk = true
  entity.voxelLastError = nil
  -- Voxel billboards are always a 16×16 card from the sprite sheet.
  -- Never feed the 2D finalScale into Voxel as a world scale.
  entity.voxelScale = 1
  return true
end

function VoxelAdapter:unregister(entity)
  if not entity then return end
  entity.voxelRegistered = false
  entity.voxelUpdateOk = false
end

function VoxelAdapter.statusLines(entity)
  if not entity then return {} end
  local lines = {}
  if entity.voxelDisabled or entity.render2DFallback then
    lines[#lines + 1] = "Voxel rendering: DISABLED FOR ENTITY"
    lines[#lines + 1] = "2D fallback: ACTIVE"
    if entity.voxelLastError then
      lines[#lines + 1] = ("Last voxel error: %s"):format(
        tostring(entity.voxelLastError))
    end
  else
    lines[#lines + 1] = ("Voxel registered: %s"):format(
      entity.voxelRegistered and "YES" or "NO")
    lines[#lines + 1] = ("Voxel update: %s"):format(
      entity.voxelUpdateOk and "OK" or "n/a")
  end
  return lines
end

return VoxelAdapter
