-- syncTrailers must reuse one shared no-op for trailer.update (no per-sync alloc).
-- Run: lua tests/follower_sync_trailers_noop_unit_test.lua
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

package.loaded["src.render.SpriteRenderer"] = {
  new = function(def, id) return { def = def, id = id } end,
}

package.loaded["src.world.NPC"] = {
  new = function(_, _, def)
    return {
      id = "WILDS_TRAILER_" .. tostring(def and def.index or 0),
      cellX = def and def.x or 0,
      cellY = def and def.y or 0,
      px = (def and def.x or 0) * 16,
      py = (def and def.y or 0) * 16,
      facing = "down",
      moving = false,
      progress = 0,
      -- Distinct per-instance stub so syncTrailers must replace it with NO_UPDATE.
      update = function() return "stock" end,
      pose = function(ent)
        return ent.sprite, ent.px, ent.py, ent.facing, 0, false
      end,
    }
  end,
  walkPhase = function() return 0 end,
}

local modules = {}
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end },
    find = function() return nil end,
    options = {
      get = function(_, key)
        if key == "follower_count" then return 6 end
        if key == "control_mode" then return "follow" end
        return nil
      end,
    },
  },
  path = ".",
}

function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

modules.config = {
  DEFAULTS = { sprite_style = "pokemmo", follower_count = 6 },
  get = function(_, k) return modules.config.DEFAULTS[k] end,
  spriteStyle = function() return "pokemmo" end,
  debug = function() return false end,
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end, debug = function() end,
}
modules.tile = { CELL = 16 }
modules.cell_occupancy = {
  isFollowerEntity = function(e)
    return e and e.pokepcTrailer == true
  end,
}
modules.surface = { WATER = "WATER" }

local ControlEngine = V.require("follower/control_engine")

local function makeMap()
  return {
    id = "ROUTE1",
    inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 40 and y < 40 end,
    isWalkableCell = function() return true end,
    isWaterCell = function() return false end,
  }
end

local function makeExistingTrailer(slot, mon, x, y, updateFn)
  return {
    id = "trailer" .. slot,
    pokepcTrailerId = "mon:" .. slot,
    pokepcTrailer = true,
    pokepcTrailerKind = "mon",
    wildsFollower = true,
    wildsFollowerRole = "party_trailer",
    pokepcMon = mon,
    cellX = x, cellY = y,
    px = x * 16, py = y * 16,
    facing = "up",
    moving = false,
    progress = 0,
    passable = true,
    update = updateFn or function() return "legacy" end,
    sprite = {
      def = { image = "land_" .. mon.species .. ".png", frames = 6, walker = true },
    },
  }
end

local function makeEngine(count)
  return ControlEngine.new(V.mod, {
    settings = {
      followerCount = function() return count or 6 end,
      engineMode = function() return "follow" end,
    },
    game = nil,
  })
end

----------------------------------------------------------------
-- Existing trailers: repeated syncTrailers share one NO_UPDATE identity
----------------------------------------------------------------
do
  local n = 6
  local engine = makeEngine(n)
  local party = {}
  local trailers = {}
  for i = 1, n do
    party[i] = { species = "MON" .. i, hp = 20 }
    -- Distinct legacy closures so first sync must install the shared no-op.
    trailers[i] = makeExistingTrailer(i, party[i], 5, 8 + i)
  end
  local game = {
    save = { party = party, pokepcFollowerCount = n, pokepcControlMode = "follow" },
  }
  engine._gameRef = game
  local player = { cellX = 5, cellY = 5, facing = "up" }
  local ow = {
    map = makeMap(),
    player = player,
    npcs = trailers,
    entities = trailers,
    pokepcTrailers = trailers,
    pokepcTrailCells = {},
  }
  for i = 1, n do ow.pokepcTrailCells[i] = { x = 5, y = 8 + i } end

  -- First sync installs ownership no-op.
  engine:syncTrailers(game, ow, {})
  local shared = trailers[1].update
  check(type(shared) == "function", "trailer[1].update is a function after sync")
  for i = 1, n do
    eq(trailers[i].update, shared,
      string.format("trailer[%d].update is shared NO_UPDATE after first sync", i))
    check(trailers[i]._wildsFollowerStepOwned == true,
      string.format("trailer[%d] step owned after first sync", i))
    check(trailers[i]._wildsFollowerStep == true,
      string.format("trailer[%d] step flag after first sync", i))
  end

  -- Second sync: identity must be unchanged (0 new no-op allocations).
  engine:syncTrailers(game, ow, {})
  for i = 1, n do
    eq(trailers[i].update, shared,
      string.format("trailer[%d].update identity unchanged after second sync", i))
  end

  -- Extra syncs still keep the same function object.
  for _ = 1, 4 do
    engine:syncTrailers(game, ow, {})
  end
  for i = 1, n do
    eq(trailers[i].update, shared,
      string.format("trailer[%d].update still shared after repeated syncs", i))
  end
end

----------------------------------------------------------------
-- makeTrailer creation path uses the same shared NO_UPDATE
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  local mon = { species = "PSYDUCK", hp = 20 }
  local game = {
    save = { party = { mon }, pokepcFollowerCount = 1, pokepcControlMode = "follow" },
  }
  engine._gameRef = game
  engine.resolveFollowerSprite = function()
    return {
      image = "land_PSYDUCK.png",
      frames = 6,
      walker = true,
      trueColor = true,
    }
  end
  local player = { cellX = 5, cellY = 5, facing = "down" }
  local ow = {
    map = makeMap(),
    player = player,
    npcs = {},
    entities = {},
    pokepcTrailers = {},
  }
  local created = engine:makeTrailer(game, ow, 5, 6, "up", "mon", mon, 1, {
    surface = "land",
  })
  check(created ~= nil, "makeTrailer returns npc")
  check(type(created.update) == "function", "makeTrailer sets update")

  local existing = makeExistingTrailer(2, { species = "ABRA", hp = 20 }, 5, 7)
  ow.pokepcTrailers = { existing }
  ow.npcs = { existing }
  ow.entities = { existing }
  ow.pokepcTrailCells = { { x = 5, y = 7 } }
  engine:syncTrailers(game, ow, {})
  eq(created.update, existing.update,
     "makeTrailer NO_UPDATE is identical to syncTrailers NO_UPDATE")
end

----------------------------------------------------------------
-- Single-follower sync also shares identity across repeats
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  local mon = { species = "PIKACHU", hp = 20 }
  local t1 = makeExistingTrailer(1, mon, 5, 6)
  local game = {
    save = { party = { mon }, pokepcFollowerCount = 1, pokepcControlMode = "follow" },
  }
  engine._gameRef = game
  local ow = {
    map = makeMap(),
    player = { cellX = 5, cellY = 5, facing = "up" },
    npcs = { t1 },
    entities = { t1 },
    pokepcTrailers = { t1 },
    pokepcTrailCells = { { x = 5, y = 6 } },
  }
  engine:syncTrailers(game, ow, {})
  local first = t1.update
  engine:syncTrailers(game, ow, {})
  eq(t1.update, first, "1-follower syncTrailers keeps update identity")
  check(t1._wildsFollowerStepOwned == true, "1-follower ownership retained")
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nall passed")
