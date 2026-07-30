-- Overworld Wild Pokemon: visible wild Pokemon on grass tiles.
--
-- Architecture
--   lib/spawn_state.lua     - fail-safe readiness flags (vanilla suppress gate)
--   lib/spawn_logic.lua     - map enter, periodic spawn, touch -> wild battle
--   lib/spawn_render.lua    - pose()/draw() entities for 2D (+ optional Voxel)
--   lib/debug_hud.lua       - present-only render pipeline HUD (dev mode)
--   lib/debug_overlay.lua   - passable tile marker entities (dev mode)
--   lib/preview_browser.lua - OPTIONS/Start-menu Pokemon preview (dev mode)
--   lib/diagnostics.lua     - status derivation for HUD/logs
--   options.lua             - Mod Manager option schema
--
-- Fail-safe: encounter.roll grass suppression runs ONLY when
-- SpawnLogic:canSuppressVanilla() is true (initialized + map supported +
-- encounter data + eligible tiles + renderer + verified pipeline).
-- Otherwise vanilla wild grass encounters remain active.
--
-- The Pokédex is never a spawn condition. The player is never teleported.
-- DramaticShapeVoxelMod is optional; base Gen1Recomp 2D rendering is enough.

return function(mod)
  local V = { mod = mod, path = mod.path }

  local function chunkFor(rel)
    local source = mod:read(rel)
    if not source then
      error(("overworld_wild_spawns: %s is missing"):format(rel), 0)
    end
    local loadcode = loadstring or load
    local chunk, err = loadcode(source, "@" .. mod.path .. "/" .. rel)
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
  local DebugHud = V.require("debug_hud")
  local DebugOverlay = V.require("debug_overlay")
  local PreviewBrowser = V.require("preview_browser")
  local DebugLog = V.require("debug_log")
  local Diagnostics = V.require("diagnostics")

  Config.defineOptions(mod)

  local render = SpawnRender.new(mod)
  local logic = SpawnLogic.new(mod, render)
  local hud = DebugHud.new(mod, logic)
  local overlay = DebugOverlay.new(mod, logic)
  local browser = PreviewBrowser.new(mod, logic)
  logic:attachDevTools(hud, overlay, browser)

  -- Register public UI / present surfaces (safe even when dev_mode is off;
  -- availability / menu rows gate on the live option).
  hud:register()
  browser:register()

  mod.log:info("overworld_wild_spawns loaded (enabled=%s dev=%s debug=%s)",
               tostring(Config.isEnabled(mod)),
               tostring(Config.devMode(mod)),
               tostring(Config.debug(mod)))

  -- ------- events (always registered; logic no-ops when feature is off)

  mod.events:on("map.entered", function(ev)
    local ok, err = pcall(logic.onMapEntered, logic, ev)
    if not ok then
      DebugLog.error(mod, "map.entered error: %s", tostring(err))
      logic.state:markError(err)
      logic:_restoreVanillaEncounters("map.entered error")
    end
  end)

  mod.events:on("map.exited", function(ev)
    local ok, err = pcall(logic.onMapExited, logic, ev)
    if not ok then
      DebugLog.error(mod, "map.exited error: %s", tostring(err))
      logic:_restoreVanillaEncounters("map.exited error")
    end
  end)

  mod.events:on("map.reloaded", function(ev)
    local ok, err = pcall(logic.onMapReloaded, logic, ev)
    if not ok then
      DebugLog.error(mod, "map.reloaded error: %s", tostring(err))
      logic.state:markError(err)
      logic:_restoreVanillaEncounters("map.reloaded error")
    end
  end)

  mod.events:on("world.stepped", function(ev)
    local ok, err = pcall(logic.onStepped, logic, ev)
    if not ok then
      DebugLog.error(mod, "world.stepped error: %s", tostring(err))
      logic.state:markError(err)
      logic:_restoreVanillaEncounters("world.stepped error")
    end
  end)

  mod.events:on("battle.ended", function()
    logic:onBattleEnded()
  end)

  mod.events:on("save.loaded", function()
    local ok, err = pcall(logic.onSaveLoaded, logic)
    if not ok then
      DebugLog.error(mod, "save.loaded error: %s", tostring(err))
      logic.state:markError(err)
      logic:_restoreVanillaEncounters("save.loaded error")
    end
  end)

  mod.events:on("save.created", function()
    logic:clearAll()
    logic.activeMapId = nil
    logic.stepsOnMap = 0
    if browser then browser:invalidateIndex() end
  end)

  mod.events:on("game.ready", function()
    hud:syncPipelineLevel()
    if Config.debug(mod) then
      DebugLog.info(mod, "game.ready; feature=%s dev=%s",
                    tostring(Config.isEnabled(mod)),
                    tostring(Config.devMode(mod)))
    end
  end)

  -- ------- hooks (installed while enabled; suppress is fail-safe gated)

  local unwraps = {}

  local function removeHooks()
    for key, unwrap in pairs(unwraps) do
      if type(unwrap) == "function" then unwrap() end
      unwraps[key] = nil
    end
    logic.state.vanillaSuppressed = false
  end

  local function restoreVanillaEncounters(reason)
    logic.state.vanillaSuppressed = false
    if Config.debug(mod) then
      DebugLog.info(mod, "vanilla encounters active (%s)", tostring(reason))
    end
  end

  logic:setRestoreVanilla(restoreVanillaEncounters)

  local function installHooks()
    if unwraps.encounter or unwraps.collision then return end

    unwraps.encounter = mod.hooks:wrap("encounter.roll", function(next, encDef, ctx)
      if logic:canSuppressVanilla()
         and ctx and ctx.terrain == "grass" then
        return nil
      end
      return next(encDef, ctx)
    end)

    unwraps.collision = mod.hooks:wrap("movement.collision", function(next, allowed, ctx)
      local ok, result = pcall(function()
        local base = next(allowed, ctx)
        return logic:onCollision(base, ctx)
      end)
      if not ok then
        DebugLog.error(mod, "movement.collision error: %s", tostring(result))
        logic.state:markError(result)
        logic:_restoreVanillaEncounters("collision error")
        return next(allowed, ctx)
      end
      return result
    end)
  end

  local function syncFeatureState()
    if Config.isEnabled(mod) then
      installHooks()
      logic.state.vanillaSuppressed = false
      if Config.debug(mod) then
        DebugLog.info(mod, "hooks installed; vanilla still active until spawn system ready")
      end
    else
      removeHooks()
      logic:clearAll()
    end
  end

  mod.events:on("mod.options_changed", function(payload)
    local ok, err = pcall(logic.onOptionsChanged, logic, payload)
    if not ok then
      DebugLog.error(mod, "options_changed error: %s", tostring(err))
      logic.state:markError(err)
      logic:_restoreVanillaEncounters("options_changed error")
    end
    if payload and payload.mod == mod.id and payload.key == "enabled" then
      syncFeatureState()
    end
  end)

  syncFeatureState()
  hud:syncPipelineLevel()

  -- ------- exports (companion / debug / test surface)

  mod.exports.version = "0.3.0"
  mod.exports.logic = logic
  mod.exports.render = render
  mod.exports.hud = hud
  mod.exports.overlay = overlay
  mod.exports.browser = browser
  mod.exports.lib = V
  mod.exports.clearAll = function() logic:clearAll() end
  mod.exports.removeHooks = removeHooks
  mod.exports.installHooks = installHooks
  mod.exports.canSuppressVanilla = function() return logic:canSuppressVanilla() end
  mod.exports.spawnSystemState = function() return logic.state:snapshot() end
  mod.exports.hudSnapshot = function() return Diagnostics.hudSnapshot(logic) end
  mod.exports.hudLines = function() return Diagnostics.hudLines(logic) end
  mod.exports.testSpawn = function(species, opts) return logic:testSpawn(species, opts) end
  mod.exports.restoreVanillaEncounters = function(reason)
    logic:_restoreVanillaEncounters(reason or "export")
  end

  mod.log:info("overworld_wild_spawns ready")
end
