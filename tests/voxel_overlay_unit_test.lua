-- ROM-free tests for world-billboard + overlay-emergency architecture (0.5.6+).
-- Run: lua54 tests/voxel_overlay_unit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. tostring(msg) .. "\n")
  else
    print("ok  " .. tostring(msg))
  end
end
local function eq(a, b, msg)
  check(a == b, string.format("%s (got %s expected %s)", msg, tostring(a), tostring(b)))
end

local modRoot = "."
local modules = {}
local V = {
  mod = {
    path = modRoot,
    log = { info = function() end },
    find = function() return nil end,
    read = function(_, rel)
      local f = io.open(modRoot .. "/" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
  },
  path = modRoot,
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

modules.config = {
  DEFAULTS = { pokemon_grass_render_mode = "immersed", grass_occlusion_px = 6 },
  get = function(_, k) return modules.config.DEFAULTS[k] end,
  debug = function() return false end,
}
modules.debug_log = {
  info = function() end, warn = function() end, error = function() end, debug = function() end,
}
modules.movement = { syncLegacyFields = function() end }
modules.surface = {
  GRASS = "GRASS",
  usesGrassOverlay = function(s) return s == "GRASS" end,
}
modules.tile = { CELL = 16 }
modules.grass_occlusion = nil -- loaded via require

local VoxelAdapter = V.require("voxel_adapter")
local AnimatedSprites = V.require("animated_sprites")

-- getBillboardCard returns result table (headless: TEMPORARILY_UNAVAILABLE)
local anim = AnimatedSprites.new(V.mod)
anim:load()
local card = anim:getBillboardCard(5, "idle", "down", 1)
check(type(card) == "table", "getBillboardCard returns table")
check(card.status == "READY" or card.status == "TEMPORARILY_UNAVAILABLE"
      or card.status == "VOXEL_CARD_BUILD_ERROR" or card.status == "PERMANENT_INVALID"
      or card.status == "FRAME_MISSING",
      "billboard status taxonomy")
check(card.status ~= "LEGACY_PNG", "adapter must not invent LEGACY status")

local wild = {
  overworldWildSpawn = true,
  px = 32, py = 48, cellX = 2, cellY = 3,
  visibleSprite = true,
  spriteSource = "ENHANCED_ATLAS",
  usingEnhancedSprite = true,
  sprite = {
    def = { image = "x", frames = 1, trueColor = true },
    resolveImage = function(s) return s.image end,
    image = {},
  },
  pose = function(self)
    return self.sprite, self.px, self.py, "down", 0, false, false
  end,
}
check(VoxelAdapter.isWildEntity(wild), "wild entity detected")
check(VoxelAdapter.isPoseSafe(wild), "pose-safe with sprite")

local adapter = VoxelAdapter.new(V.mod)
adapter:updateEntity(wild)
eq(wild.pokemonRenderer, "WILDS_2D", "flat path uses WILDS_2D")
eq(wild.worldRenderer, "GEN1_FLAT", "flat world renderer")
eq(wild.grassRenderer, "ENGINE_2D", "flat grass renderer ENGINE_2D")

-- Emergency filter keeps world billboards, drops emergency bodies
local npc = { overworldWildSpawn = false }
local enhanced = {
  overworldWildSpawn = true,
  pokemonRenderer = "WORLD_BILLBOARD_ENHANCED",
}
local emergency = {
  overworldWildSpawn = true,
  pokemonRenderer = "SPATIAL_OVERLAY_EMERGENCY",
}
local legacyAlias = {
  overworldWildSpawn = true,
  pokemonRenderer = "SPATIAL_OVERLAY_FALLBACK",
}
local function filterKeep(entities)
  local kept = {}
  for _, e in ipairs(entities) do
    local r = e.pokemonRenderer
    local isEmerg = r == "SPATIAL_OVERLAY_EMERGENCY" or r == "SPATIAL_OVERLAY_FALLBACK"
    if not (VoxelAdapter.isWildEntity(e) and isEmerg) then
      kept[#kept + 1] = e
    end
  end
  return kept
end
local kept = filterKeep({ npc, enhanced, emergency, legacyAlias })
eq(#kept, 2, "filter removes only emergency-overlay wilds")
check(kept[1] == npc and kept[2] == enhanced, "npc + enhanced remain in posesOf")

adapter:markFallback(wild, "test")
eq(wild.pokemonRenderer, "SPATIAL_OVERLAY_EMERGENCY", "markFallback sets emergency")
eq(wild.depthIntegration, "INACTIVE", "depth inactive on emergency")
eq(wild.spriteSource2D, "ENHANCED_ATLAS", "emergency keeps ENHANCED_ATLAS source")
eq(wild.grassRenderer, "EMERGENCY_OVERLAY", "emergency grass label")

if failures > 0 then
  io.stderr:write(("\n%d failure(s)\n"):format(failures))
  os.exit(1)
end
print("\nAll voxel overlay unit tests passed.")
