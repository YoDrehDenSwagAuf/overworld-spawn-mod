-- VoxelAdapter: presence throttle + inactive updateEntity early-out.
-- Run: lua tests/voxel_adapter_perf_unit_test.lua
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

local clock = 0
love = { timer = { getTime = function() return clock end } }

local findCalls = 0
local modules = {}
local V = {
  mod = { path = ".", world = {}, find = function() return nil end,
          log = { info = function() end } },
  path = ".",
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  if name == "debug_log" then
    modules[name] = { warn = function() end, info = function() end }
    return modules[name]
  end
  if name == "movement" then
    modules[name] = { syncLegacyFields = function() return true end }
    return modules[name]
  end
  if name == "config" then
    modules[name] = { debug = function() return false end }
    return modules[name]
  end
  if name == "render_diagnostics" then
    modules[name] = { honestDepthActive = function() return false end, ensure = function(e) return e end }
    return modules[name]
  end
  if name == "variable_size" then
    modules[name] = {
      findVoxelRenderer = function()
        findCalls = findCalls + 1
        return nil
      end,
    }
    return modules[name]
  end
  if name == "water_display" then
    modules[name] = {
      needsWaterShadowPresentation = function() return false end,
      isSilhouettes = function() return false end,
      isHiddenSilhouettes = function() return false end,
    }
    return modules[name]
  end
  if name == "water_shadow_renderer" then
    modules[name] = {
      MODE = { NONE = "none", FLAT_WORLD = "flat", UPRIGHT_FALLBACK = "up" },
      installDrawHook = function() end,
    }
    return modules[name]
  end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

local VoxelAdapter = V.require("voxel_adapter")
local va = VoxelAdapter.new(V.mod)

clock = 0
va:refreshPresence()
local finds1 = findCalls
check(va.present == false, "no dramatic renderer → present false")

clock = 0.1
va:refreshPresence()
check(findCalls == finds1, "throttled refresh does not rescan mods")

clock = 0.6
va:refreshPresence()
check(findCalls > finds1, "refresh after interval rescans")

clock = 0.7
local findsForce = findCalls
va:refreshPresence({ force = true })
check(findCalls > findsForce, "force=true always rescans")

-- Inactive early-out: second update should stay cheap (still correct flags).
local ent = {
  id = "w",
  overworldWildSpawn = true,
  spriteSource = "FOLLOW_SPRITES",
}
va.present = false
va.voxelActive = false
va:updateEntity(ent)
check(ent.pokemonRenderer == "WILDS_2D", "flat path sets WILDS_2D")
local r1 = ent.pokemonRenderer
va:updateEntity(ent)
check(ent.pokemonRenderer == r1, "early-out preserves flat renderer")
check(ent.voxelUpdateOk == true, "voxelUpdateOk on inactive path")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("ALL PASS")
