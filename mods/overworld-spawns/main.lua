-- Overworld Spawns: visible wild Pokémon on grass tiles.
--
-- Architecture
--   lib/spawn_logic.lua   — map enter, periodic spawn, touch → wild battle
--   lib/spawn_render.lua  — pose()/draw() entities for 2D + VoxelScene
--
-- Logic never draws. Rendering never starts battles. Both share Config.
-- Entities ride OverworldState.entities so Dramatic Shape's VoxelScene
-- billboards them automatically when VOXEL mode is on; otherwise the
-- engine's SpriteRenderer path draws them in 2D.

local mod = ...

local V = { mod = mod, path = mod.path }

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then
    error(("overworld-spawns: %s is missing"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("overworld-spawns: %s did not compile: %s"):format(rel, tostring(err)), 0)
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

-- ------- events

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

-- ------- hooks

-- Optional: suppress vanilla random grass rolls so visible spawns are the
-- primary wild encounter path. Surf / indoor cave rolls pass through.
mod.hooks:wrap("encounter.roll", function(next, encDef, ctx)
  if Config.get(mod, "suppress_random_grass")
     and ctx and ctx.terrain == "grass" then
    return nil
  end
  return next(encDef, ctx)
end)

-- Bump-into safety net if a spawn is ever non-passable.
mod.hooks:wrap("movement.collision", function(next, allowed, ctx)
  local result = next(allowed, ctx)
  return logic:onCollision(result, ctx)
end)

-- ------- exports (companion / debug surface)

mod.exports.version = "1.0.0"
mod.exports.logic = logic
mod.exports.render = render
mod.exports.lib = V

mod.log:info("overworld-spawns ready (2D + optional DRAMATIC_SHAPE)")
