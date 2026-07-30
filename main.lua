-- Overworld Wild Pokemon: visible wild Pokemon on grass tiles.
--
-- Architecture
--   lib/spawn_logic.lua   - map enter, periodic spawn, wander, touch -> wild battle
--   lib/spawn_render.lua  - pose()/draw() entities for 2D + VoxelScene
--   options.lua           - Mod Manager option schema (manifest options_schema)
--
-- Logic never draws. Rendering never starts battles. Both share Config.
-- Entities ride OverworldState.entities so Dramatic Shape's VoxelScene
-- billboards them automatically when VOXEL mode is on; otherwise the
-- engine's SpriteRenderer path draws them in 2D.
--
-- This mod does NOT change the player spawn point, warp the player, or
-- teleport on map enter / save load / mod enable.
--
-- Mod Manager disable -> entry chunk never loaded (vanilla).
-- Option enabled=false -> clear entities, unwrap hooks, restore vanilla rolls.

return function(mod)
  local V = { mod = mod, path = mod.path }

  local function chunkFor(rel)
    local source = mod:read(rel)
    if not source then
      error(("overworld_wild_spawns: %s is missing"):format(rel), 0)
    end
    local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
    if not chunk then
      error(("overworld_wild_spawns: %s did not compile: %s"):format(rel, tostring(err)), 0)
    end
    return chunk
  end

  local modules = {}
  function V.require(name)
    local hit = modules[name]
    if hit ~= nil then return hit end
    local value = chunkFor("lib/" .. name .. ".lua")(V)
    modules[name] = value
    return value
  end

  local Config = V.require("config")
  local SpawnRender = V.require("spawn_render")
  local SpawnLogic = V.require("spawn_logic")

  Config.defineOptions(mod)

  local render = SpawnRender.new(mod)
  local logic = SpawnLogic.new(mod, render)

  -- ------- events (always registered; logic no-ops when feature is off)

  mod.events:on("map.entered", function(ev)
    logic:onMapEntered(ev)
  end)

  mod.events:on("map.exited", function(ev)
    logic:onMapExited(ev)
  end)

  mod.events:on("world.stepped", function(ev)
    logic:onStepped(ev)
  end)

  mod.events:on("battle.ended", function()
    logic:onBattleEnded()
  end)

  mod.events:on("save.loaded", function()
    logic:onSaveLoaded()
  end)

  mod.events:on("save.created", function()
    logic:clearAll()
    logic.activeMapId = nil
    logic.stepsOnMap = 0
  end)

  -- ------- hooks (installed only while enabled == true)

  local unwraps = {}

  local function removeHooks()
    for key, unwrap in pairs(unwraps) do
      if type(unwrap) == "function" then unwrap() end
      unwraps[key] = nil
    end
  end

  local function installHooks()
    if unwraps.encounter or unwraps.collision then return end

    -- Optional: suppress vanilla random grass rolls so visible spawns are the
    -- primary wild encounter path. Surf / fishing / other terrains pass through.
    unwraps.encounter = mod.hooks:wrap("encounter.roll", function(next, encDef, ctx)
      if Config.isEnabled(mod)
         and Config.get(mod, "suppress_random_grass")
         and ctx and ctx.terrain == "grass" then
        return nil
      end
      return next(encDef, ctx)
    end)

    -- Bump-into safety net if a spawn is ever non-passable.
    unwraps.collision = mod.hooks:wrap("movement.collision", function(next, allowed, ctx)
      local result = next(allowed, ctx)
      return logic:onCollision(result, ctx)
    end)
  end

  local function syncFeatureState()
    if Config.isEnabled(mod) then
      installHooks()
    else
      removeHooks()
      logic:clearAll()
    end
  end

  mod.events:on("mod.options_changed", function(payload)
    logic:onOptionsChanged(payload)
    if payload and payload.mod == mod.id and payload.key == "enabled" then
      syncFeatureState()
    end
  end)

  syncFeatureState()

  -- ------- exports (companion / debug / test surface)

  mod.exports.version = "0.1.0"
  mod.exports.logic = logic
  mod.exports.render = render
  mod.exports.lib = V
  mod.exports.clearAll = function() logic:clearAll() end
  mod.exports.removeHooks = removeHooks
  mod.exports.installHooks = installHooks

  mod.log:info("overworld_wild_spawns ready")
end
