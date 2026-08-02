-- Render-path diagnostics + strict body-skip tests (0.5.7+).
-- Run: lua54 tests/render_diagnostics_unit_test.lua
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
local opts = {
  strict_world_billboard_debug = false,
  strict_magenta_billboard_probe = false,
  dev_mode = true,
}
local V = {
  mod = {
    path = modRoot,
    log = { info = function() end },
    find = function() return nil end,
    options = { get = function(_, k) return opts[k] end },
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
  DEFAULTS = {
    pokemon_grass_render_mode = "immersed",
    grass_occlusion_px = 6,
    grass_above_lift_px = 8,
    strict_world_billboard_debug = false,
    strict_magenta_billboard_probe = false,
  },
  get = function(_, k)
    if opts[k] ~= nil then return opts[k] end
    return modules.config.DEFAULTS[k]
  end,
  devMode = function() return opts.dev_mode == true end,
  debug = function() return false end,
}
modules.debug_log = {
  info = function() end, warn = function() end, error = function() end, debug = function() end,
}
modules.tile = { CELL = 16 }
modules.surface = { GRASS = "GRASS", usesGrassOverlay = function() return true end }
modules.movement = { syncLegacyFields = function() end }
modules.grass_occlusion = {
  shouldOcclude = function() return false end,
  MODE_ABOVE = "above", MODE_IMMERSED = "immersed",
  mode = function() return "immersed" end,
  tuckDelta = function() return 0 end,
  statusLines = function() return {} end,
}

local RenderDiagnostics = V.require("render_diagnostics")
local VoxelAdapter = V.require("voxel_adapter")

local entity = {
  id = "wild_5",
  overworldWildSpawn = true,
  pokemonRenderer = "WORLD_BILLBOARD_ENHANCED",
  worldRenderer = "DRAMATIC_SHAPE",
  usingEnhancedSprite = true,
  spriteSource2D = "ENHANCED_ATLAS",
  mod = V.mod,
  px = 0, py = 0, cellX = 0, cellY = 0,
}
local d = RenderDiagnostics.ensure(entity)
eq(d.poseCalls, 0, "fresh counters")
d.poseCalls = 3
d.lastFilterKept = true
d.enhancedResolveImageCalls = 6
d.dramaticBillboardDrawAttempts = 6
d.meshOkObservations = 2
d.lastMeshOk = true
d.postVoxelBodyDrawCalls = 0
d.emergencyOverlayBodyDrawCalls = 0
d.entityDrawBodyCalls = 0
eq(RenderDiagnostics.deriveActualBodyRenderer(entity), "DRAMATIC_SPRITE_BILLBOARD",
   "honest DS billboard actual")
check(RenderDiagnostics.honestDepthActive(entity), "honest depth active")

d.emergencyOverlayBodyDrawCalls = 4
d.enhancedResolveImageCalls = 0
d.lastMeshOk = false
eq(RenderDiagnostics.deriveActualBodyRenderer(entity), "SPATIAL_OVERLAY_EMERGENCY",
   "emergency actual when overlay counters fire")

-- Strict disables emergency overlay draw
opts.strict_world_billboard_debug = true
check(RenderDiagnostics.strictEnabled(V.mod), "strict enabled in dev mode")
local adapter = VoxelAdapter.new(V.mod)
local drew = false
love = nil
adapter:drawOverlayFallbackBodies({
  state = { entities = { entity } },
  cam = { x = 0, y = 0 },
  scale = 1,
}, function() drew = true; return 1, 1, 1 end, 1)
check(drew == false, "strict mode draws no emergency overlay")

-- Filter marks accepted/rejected
entity.pokemonRenderer = "SPATIAL_OVERLAY_EMERGENCY"
entity.renderDiagnostics = nil
local entities = {
  { overworldWildSpawn = false },
  { overworldWildSpawn = true, pokemonRenderer = "WORLD_BILLBOARD_ENHANCED",
    renderDiagnostics = nil },
  entity,
}
-- Re-run filter logic inline like adapter
local kept = {}
for _, e in ipairs(entities) do
  local dd = RenderDiagnostics.ensure(e)
  local emerg = e.overworldWildSpawn
    and (e.pokemonRenderer == "SPATIAL_OVERLAY_EMERGENCY"
         or e.pokemonRenderer == "SPATIAL_OVERLAY_FALLBACK")
  if emerg then
    dd.lastFilterKept = false
  else
    if e.overworldWildSpawn then dd.lastFilterKept = true end
    kept[#kept + 1] = e
  end
end
eq(#kept, 2, "filter drops emergency only")
check(entities[2].renderDiagnostics.lastFilterKept == true, "enhanced kept=YES")
check(entity.renderDiagnostics.lastFilterKept == false, "emergency kept=NO")

if failures > 0 then
  io.stderr:write(("\n%d failure(s)\n"):format(failures))
  os.exit(1)
end
print("\nAll render_diagnostics unit tests passed.")
