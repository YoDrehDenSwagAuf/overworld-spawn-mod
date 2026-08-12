-- Follower land ↔ water sprite rebind (surface transition regression).
-- Run: lua tests/follower_surface_sprite_unit_test.lua
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
  new = function(def, id)
    return { def = def, id = id }
  end,
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
      pose = function(ent)
        return ent.sprite, ent.px, ent.py, ent.facing, 0, false
      end,
    }
  end,
  walkPhase = function() return 0 end,
}

local modules = {}
local spriteStyle = "pokemmo"
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end },
    find = function() return nil end,
    options = {
      get = function(_, key)
        if key == "follower_count" then return 1 end
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
  DEFAULTS = { sprite_style = "pokemmo", follower_count = 1 },
  get = function(_, k) return modules.config.DEFAULTS[k] end,
  spriteStyle = function() return spriteStyle end,
  normalizeSpriteStyle = function(s) return s end,
  debug = function() return false end,
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end, debug = function() end,
}
modules.tile = { CELL = 16 }
modules.cell_occupancy = {
  isFollowerEntity = function(e)
    return e and (e.pokepcTrailer == true or e.wildsFollower == true)
  end,
}
modules.surface = { WATER = "WATER" }

local ControlEngine = V.require("follower/control_engine")

local function makeMap()
  return {
    id = "ROUTE19",
    widthCells = 40,
    heightCells = 40,
    inBounds = function(_, x, y)
      return x >= 0 and y >= 0 and x < 40 and y < 40
    end,
    isWalkableCell = function(_, x, y)
      return y >= 10 and x >= 0 and x < 40
    end,
    isWaterCell = function(_, x, y)
      return y < 10 and x >= 0 and x < 40
    end,
  }
end

local function waterImage(species, shiny)
  return (shiny and "water_shiny_" or "water_") .. tostring(species) .. ".png"
end

local function landImage(species, shiny)
  return (shiny and "land_shiny_" or "land_") .. tostring(species) .. ".png"
end

local function gscWaterImage(species, shiny)
  return (shiny and "gsc_submerged_shiny_" or "gsc_submerged_")
    .. tostring(species) .. ".png"
end

-- HGSS / True Size water geometry (must survive rebind).
local WATER_GEOM = { frameWidth = 32, frameHeight = 48, anchorX = 16, anchorY = 40 }
local LAND_GEOM = { frameWidth = 16, frameHeight = 16, anchorX = 8, anchorY = 16 }

local function makeSpriteService(opts)
  opts = opts or {}
  local calls = {}
  local gsc = opts.gsc == true
  return {
    calls = calls,
    resolveFollowerSprite = function(_, req)
      calls[#calls + 1] = req
      local species = req.species or "CHARMANDER"
      local shiny = req.shiny == true
      local surface = req.surface or "land"
      if surface == "water" or surface == "surfing" then
        local def = {
          id = "SPRITE_WILDS_FOLLOWER_WATER",
          image = gsc and gscWaterImage(species, shiny) or waterImage(species, shiny),
          frames = 6,
          walker = true,
          trueColor = true,
          providerId = gsc and "followers" or "water",
          role = req.role,
          surface = surface,
        }
        if not gsc then
          def.frameWidth = WATER_GEOM.frameWidth
          def.frameHeight = WATER_GEOM.frameHeight
          def.anchorX = WATER_GEOM.anchorX
          def.anchorY = WATER_GEOM.anchorY
        end
        return def
      end
      return {
        id = "SPRITE_WILDS_FOLLOWER_MON",
        image = landImage(species, shiny),
        frames = 6,
        walker = true,
        trueColor = true,
        frameWidth = LAND_GEOM.frameWidth,
        frameHeight = LAND_GEOM.frameHeight,
        anchorX = LAND_GEOM.anchorX,
        anchorY = LAND_GEOM.anchorY,
        providerId = gsc and "followers" or "pokemmo",
        role = req.role,
        surface = "land",
      }
    end,
  }
end

local function makeEngine(count, spriteService, mode)
  return ControlEngine.new(V.mod, {
    spriteService = spriteService,
    settings = {
      followerCount = function() return count or 1 end,
      engineMode = function() return mode or "follow" end,
    },
  })
end

local function makeGame(party, count, mode)
  return {
    save = {
      party = party,
      pokepcFollowerCount = count or #party,
      pokepcControlMode = mode or "follow",
    },
    data = { sprites = {} },
  }
end

local function makeHandTrailer(slot, mon, x, y)
  return {
    id = "trailer" .. tostring(slot),
    pokepcTrailerId = "mon:" .. tostring(slot),
    pokepcTrailer = true,
    pokepcTrailerKind = "mon",
    wildsFollower = true,
    wildsFollowerRole = "party_trailer",
    pokepcMon = mon,
    pokepcShiny = mon and mon.shiny == true,
    cellX = x, cellY = y,
    px = x * 16, py = y * 16,
    targetX = x, targetY = y + 1,
    facing = "up",
    moving = true,
    progress = 3,
    stepFlip = true,
    animClock = 7,
    passable = true,
    sprite = {
      def = {
        id = "SPRITE_WILDS_FOLLOWER_MON",
        image = landImage(mon.species, mon.shiny),
        frames = 6,
        walker = true,
        frameWidth = LAND_GEOM.frameWidth,
        frameHeight = LAND_GEOM.frameHeight,
        anchorX = LAND_GEOM.anchorX,
        anchorY = LAND_GEOM.anchorY,
      },
    },
  }
end

local function lastCall(svc)
  return svc.calls[#svc.calls]
end

local function callsWithSurface(svc, surface)
  local n = 0
  for _, c in ipairs(svc.calls) do
    if c.surface == surface then n = n + 1 end
  end
  return n
end

----------------------------------------------------------------
-- 1. makeTrailer(surface=water) resolves water art
----------------------------------------------------------------
do
  local svc = makeSpriteService()
  local engine = makeEngine(1, svc)
  local mon = { species = "PSYDUCK", hp = 20 }
  local game = makeGame({ mon }, 1)
  local ow = {
    map = makeMap(),
    player = { cellX = 5, cellY = 5, surfing = true, facing = "up" },
  }
  local npc = engine:makeTrailer(game, ow, 5, 6, "up", "mon", mon, 1, {
    surface = "water",
  })
  check(npc ~= nil, "makeTrailer water returns npc")
  local call = lastCall(svc)
  check(call ~= nil, "makeTrailer water called resolver")
  eq(call.surface, "water", "makeTrailer water resolver surface")
  eq(call.species, "PSYDUCK", "makeTrailer water species")
  eq(call.role, "party_trailer", "makeTrailer water role")
  eq(npc.sprite.def.image, waterImage("PSYDUCK"), "makeTrailer water image")
  eq(npc.spriteState, "water", "makeTrailer water spriteState")
  check(npc.wildsFollowerWater == true, "makeTrailer water flag")
end

----------------------------------------------------------------
-- 2. makeTrailer(surface=land) resolves land art
----------------------------------------------------------------
do
  local svc = makeSpriteService()
  local engine = makeEngine(1, svc)
  local mon = { species = "PSYDUCK", hp = 20 }
  local game = makeGame({ mon }, 1)
  local ow = {
    map = makeMap(),
    player = { cellX = 5, cellY = 12, surfing = false, facing = "down" },
  }
  local npc = engine:makeTrailer(game, ow, 5, 13, "down", "mon", mon, 1, {
    surface = "land",
  })
  check(npc ~= nil, "makeTrailer land returns npc")
  eq(lastCall(svc).surface, "land", "makeTrailer land resolver surface")
  eq(npc.sprite.def.image, landImage("PSYDUCK"), "makeTrailer land image")
  eq(npc.spriteState, "land", "makeTrailer land spriteState")
  check(npc.wildsFollowerWater ~= true, "makeTrailer land not water-flagged")
end

----------------------------------------------------------------
-- 3–6. land → water rebind: same NPC, movement + geometry preserved
----------------------------------------------------------------
do
  local svc = makeSpriteService()
  local engine = makeEngine(1, svc)
  local mon = { species = "LAPRAS", hp = 40 }
  local game = makeGame({ mon }, 1)
  engine._gameRef = game
  local t1 = makeHandTrailer(1, mon, 5, 11)
  t1.update = function() end
  local player = {
    cellX = 5, cellY = 11, facing = "up", surfing = false, stepFrames = 8,
  }
  local ow = {
    map = makeMap(),
    player = player,
    npcs = { t1 },
    entities = { t1 },
    pokepcTrailers = { t1 },
    pokepcTrailCells = { { x = 5, y = 11 } },
    pokepcTrailHead = { x = 5, y = 11 },
    _wildsFollowerTrailSurface = "land",
  }
  engine._lastSyncedCount = 1

  engine:syncTrailers(game, ow, {})
  eq(t1.sprite.def.image, landImage("LAPRAS"), "start on land image")

  player.surfing = true
  player.cellX, player.cellY = 5, 8
  player.targetX, player.targetY = 5, 7
  ow.pokepcTrailHead = { x = 5, y = 8 }
  local before = {
    cellX = t1.cellX, cellY = t1.cellY,
    px = t1.px, py = t1.py,
    targetX = t1.targetX, targetY = t1.targetY,
    facing = t1.facing, moving = t1.moving, progress = t1.progress,
    stepFlip = t1.stepFlip, animClock = t1.animClock, pokepcMon = t1.pokepcMon,
  }
  engine:syncTrailers(game, ow, {})

  eq(ow.pokepcTrailers[1], t1, "land→water keeps trailer identity")
  eq(t1.pokepcMon, before.pokepcMon, "land→water keeps pokepcMon")
  eq(t1.cellX, before.cellX, "rebind keeps cellX")
  eq(t1.cellY, before.cellY, "rebind keeps cellY")
  eq(t1.px, before.px, "rebind keeps px")
  eq(t1.py, before.py, "rebind keeps py")
  eq(t1.targetX, before.targetX, "rebind keeps targetX")
  eq(t1.targetY, before.targetY, "rebind keeps targetY")
  eq(t1.facing, before.facing, "rebind keeps facing")
  eq(t1.moving, before.moving, "rebind keeps moving")
  eq(t1.progress, before.progress, "rebind keeps progress")
  eq(t1.stepFlip, before.stepFlip, "rebind keeps stepFlip")
  eq(t1.animClock, before.animClock, "rebind keeps animClock")
  eq(t1.sprite.def.image, waterImage("LAPRAS"), "land→water image")
  eq(t1.sprite.def.frameWidth, WATER_GEOM.frameWidth, "water frameWidth")
  eq(t1.sprite.def.frameHeight, WATER_GEOM.frameHeight, "water frameHeight")
  eq(t1.sprite.def.anchorX, WATER_GEOM.anchorX, "water anchorX")
  eq(t1.sprite.def.anchorY, WATER_GEOM.anchorY, "water anchorY")
  check(callsWithSurface(svc, "water") >= 1, "land→water resolver used water")
  eq(ow._wildsFollowerTrailSurface, "water", "surface marker water")
end

----------------------------------------------------------------
-- 4. water → land rebind: same NPC, image returns to land
----------------------------------------------------------------
do
  local svc = makeSpriteService()
  local engine = makeEngine(1, svc)
  local mon = { species = "LAPRAS", hp = 40 }
  local game = makeGame({ mon }, 1)
  engine._gameRef = game
  local t1 = makeHandTrailer(1, mon, 5, 8)
  t1.sprite.def.image = waterImage("LAPRAS")
  t1.sprite.def.frameWidth = WATER_GEOM.frameWidth
  t1.sprite.def.frameHeight = WATER_GEOM.frameHeight
  t1.sprite.def.anchorX = WATER_GEOM.anchorX
  t1.sprite.def.anchorY = WATER_GEOM.anchorY
  t1.wildsFollowerWater = true
  t1.spriteState = "water"
  t1.update = function() end
  local player = {
    cellX = 5, cellY = 8, facing = "down", surfing = true, stepFrames = 8,
  }
  local ow = {
    map = makeMap(),
    player = player,
    npcs = { t1 },
    entities = { t1 },
    pokepcTrailers = { t1 },
    pokepcTrailCells = { { x = 5, y = 8 } },
    pokepcTrailHead = { x = 5, y = 8 },
    _wildsFollowerTrailSurface = "water",
  }
  engine._lastSyncedCount = 1

  player.surfing = false
  player.cellX, player.cellY = 5, 12
  player.targetX, player.targetY = 5, 13
  ow.pokepcTrailHead = { x = 5, y = 12 }
  engine:syncTrailers(game, ow, {})

  eq(ow.pokepcTrailers[1], t1, "water→land keeps trailer identity")
  eq(t1.sprite.def.image, landImage("LAPRAS"), "water→land image")
  eq(t1.sprite.def.frameWidth, LAND_GEOM.frameWidth, "land frameWidth restored")
  eq(t1.spriteState, "land", "water→land spriteState")
  check(t1.wildsFollowerWater ~= true, "water→land clears water flag")
  eq(ow._wildsFollowerTrailSurface, "land", "surface marker land")
end

----------------------------------------------------------------
-- 7. Shiny follower keeps shiny water sprite
----------------------------------------------------------------
do
  local svc = makeSpriteService()
  local engine = makeEngine(1, svc)
  local mon = { species = "GYARADOS", hp = 50, shiny = true }
  local game = makeGame({ mon }, 1)
  engine._gameRef = game
  local t1 = makeHandTrailer(1, mon, 5, 11)
  t1.update = function() end
  local player = {
    cellX = 5, cellY = 11, facing = "up", surfing = false, stepFrames = 8,
  }
  local ow = {
    map = makeMap(),
    player = player,
    npcs = { t1 },
    entities = { t1 },
    pokepcTrailers = { t1 },
    pokepcTrailCells = { { x = 5, y = 11 } },
    pokepcTrailHead = { x = 5, y = 11 },
    _wildsFollowerTrailSurface = "land",
  }
  engine._lastSyncedCount = 1
  player.surfing = true
  player.cellX, player.cellY = 5, 8
  engine:syncTrailers(game, ow, {})
  eq(t1.sprite.def.image, waterImage("GYARADOS", true), "shiny water image")
  local waterCall
  for i = #svc.calls, 1, -1 do
    if svc.calls[i].surface == "water" then waterCall = svc.calls[i]; break end
  end
  check(waterCall ~= nil, "shiny water resolver call")
  eq(waterCall.shiny, true, "shiny flag passed to water resolver")
end

----------------------------------------------------------------
-- 8–9. Trainer hidden while surfing; Pokémon trailers remain
----------------------------------------------------------------
do
  local svc = makeSpriteService()
  local engine = makeEngine(1, svc, "lead_trainer")
  local psyduck = { species = "PSYDUCK", hp = 20 }
  local abra = { species = "ABRA", hp = 20 }
  local game = makeGame({ psyduck, abra }, 1, "lead_trainer")
  engine._gameRef = game
  -- lead_trainer is pokemon-front: trail is non-leader mons (ABRA) + trainer.
  local monTrailer = makeHandTrailer(1, abra, 5, 12)
  monTrailer.update = function() end
  local trainer = {
    id = "trainer1",
    pokepcTrailerId = "trainer:2",
    pokepcTrailer = true,
    pokepcTrailerKind = "trainer",
    wildsFollower = true,
    wildsFollowerRole = "trainer_trailer",
    pokepcMon = nil,
    cellX = 5, cellY = 13,
    px = 80, py = 208,
    facing = "up",
    moving = false,
    progress = 0,
    sprite = { def = { image = "trainer.png", frames = 6, walker = true } },
    update = function() end,
  }
  local player = {
    cellX = 5, cellY = 11, facing = "up", surfing = false, stepFrames = 8,
  }
  local ow = {
    map = makeMap(),
    player = player,
    npcs = { monTrailer, trainer },
    entities = { monTrailer, trainer },
    pokepcTrailers = { monTrailer, trainer },
    pokepcTrailCells = { { x = 5, y = 12 }, { x = 5, y = 13 } },
    pokepcTrailHead = { x = 5, y = 11 },
    _wildsFollowerTrailSurface = "land",
  }
  engine._lastSyncedCount = 2

  player.surfing = true
  player.cellX, player.cellY = 5, 8
  engine:syncTrailers(game, ow, {})

  local mons, trainers = 0, 0
  for _, t in ipairs(ow.pokepcTrailers or {}) do
    if t.pokepcTrailerKind == "trainer" then trainers = trainers + 1 end
    if t.pokepcTrailerKind == "mon" then
      mons = mons + 1
      check(t.sprite and t.sprite.def and tostring(t.sprite.def.image):find("water_", 1, true),
            "lead_trainer surf mon uses water image")
    end
  end
  eq(trainers, 0, "trainer trailer hidden while surfing")
  check(mons >= 1, "Pokémon trailers remain while surfing")
end

----------------------------------------------------------------
-- 10. GSC sprite mode keeps GSC water presentation (no HGSS geometry)
----------------------------------------------------------------
do
  spriteStyle = "followers"
  local svc = makeSpriteService({ gsc = true })
  local engine = makeEngine(1, svc)
  local mon = { species = "PSYDUCK", hp = 20 }
  local game = makeGame({ mon }, 1)
  engine._gameRef = game
  local t1 = makeHandTrailer(1, mon, 5, 11)
  t1.update = function() end
  local player = {
    cellX = 5, cellY = 11, facing = "up", surfing = false, stepFrames = 8,
  }
  local ow = {
    map = makeMap(),
    player = player,
    npcs = { t1 },
    entities = { t1 },
    pokepcTrailers = { t1 },
    pokepcTrailCells = { { x = 5, y = 11 } },
    pokepcTrailHead = { x = 5, y = 11 },
    _wildsFollowerTrailSurface = "land",
  }
  engine._lastSyncedCount = 1
  player.surfing = true
  player.cellX, player.cellY = 5, 8
  engine:syncTrailers(game, ow, {})
  eq(t1.sprite.def.image, gscWaterImage("PSYDUCK"), "GSC water image")
  eq(t1.sprite.def.frameWidth, nil, "GSC water does not invent True Size width")
  eq(t1.sprite.def.frameHeight, nil, "GSC water does not invent True Size height")
  spriteStyle = "pokemmo"
end

----------------------------------------------------------------
-- 11. HGSS True Size water geometry preserved on makeTrailer + rebind
----------------------------------------------------------------
do
  local svc = makeSpriteService()
  local engine = makeEngine(1, svc)
  local mon = { species = "SNORLAX", hp = 80 }
  local game = makeGame({ mon }, 1)
  local ow = {
    map = makeMap(),
    player = { cellX = 5, cellY = 5, surfing = true, facing = "up" },
  }
  local npc = engine:makeTrailer(game, ow, 5, 6, "up", "mon", mon, 1, {
    surface = "water",
  })
  eq(npc.sprite.def.frameWidth, WATER_GEOM.frameWidth, "HGSS makeTrailer water width")
  eq(npc.sprite.def.frameHeight, WATER_GEOM.frameHeight, "HGSS makeTrailer water height")
  eq(npc.sprite.def.anchorX, WATER_GEOM.anchorX, "HGSS makeTrailer water anchorX")
  eq(npc.sprite.def.anchorY, WATER_GEOM.anchorY, "HGSS makeTrailer water anchorY")
end

----------------------------------------------------------------
-- 1/3/6 followers: none disappear on surf; all get water art
----------------------------------------------------------------
do
  local function runPack(n)
    local svc = makeSpriteService()
    local engine = makeEngine(n, svc)
    local party, trailers = {}, {}
    for i = 1, n do
      party[i] = { species = "MON" .. i, hp = 20 }
      trailers[i] = makeHandTrailer(i, party[i], 5, 11 + i)
      trailers[i].update = function() end
    end
    local game = makeGame(party, n)
    engine._gameRef = game
    local player = {
      cellX = 5, cellY = 11, facing = "up", surfing = false, stepFrames = 8,
    }
    local ow = {
      map = makeMap(),
      player = player,
      npcs = trailers,
      entities = trailers,
      pokepcTrailers = trailers,
      pokepcTrailCells = {},
      pokepcTrailHead = { x = 5, y = 11 },
      _wildsFollowerTrailSurface = "land",
    }
    for i = 1, n do ow.pokepcTrailCells[i] = { x = 5, y = 11 + i } end
    engine._lastSyncedCount = n
    player.surfing = true
    player.cellX, player.cellY = 5, 8
    engine:syncTrailers(game, ow, {})
    eq(#ow.pokepcTrailers, n, "pack " .. n .. " still present after surf")
    for i, t in ipairs(ow.pokepcTrailers) do
      eq(t, trailers[i], "pack " .. n .. " slot " .. i .. " identity")
      eq(t.sprite.def.image, waterImage("MON" .. i),
         "pack " .. n .. " slot " .. i .. " water image")
    end
    return ow
  end
  runPack(1)
  runPack(3)
  runPack(6)
end

----------------------------------------------------------------
-- CASE 2: surf spawn/rebuild (empty pack) → new trailer already has water sprite
----------------------------------------------------------------
do
  local svc = makeSpriteService()
  local engine = makeEngine(1, svc)
  local mon = { species = "SQUIRTLE", hp = 20 }
  local game = makeGame({ mon }, 1)
  engine._gameRef = game
  -- No existing trailers + land→water marker: dirty composition takes the
  -- mapEnter rebuild path, so makeTrailer must resolve water immediately.
  local player = {
    cellX = 5, cellY = 8, facing = "up", surfing = true, stepFrames = 8,
  }
  local ow = {
    map = makeMap(),
    player = player,
    npcs = {},
    entities = {},
    pokepcTrailers = {},
    pokepcTrailCells = {},
    pokepcTrailHead = { x = 5, y = 8 },
    _wildsFollowerTrailSurface = "land",
  }
  engine:syncTrailers(game, ow, {})
  check(#ow.pokepcTrailers >= 1, "rebuild spawned a trailer")
  local npc = ow.pokepcTrailers[1]
  check(npc ~= nil and npc.pokepcTrailerKind == "mon", "rebuild created a mon trailer")
  eq(npc.sprite.def.image, waterImage("SQUIRTLE"), "rebuild trailer uses water image")
  check(callsWithSurface(svc, "water") >= 1, "rebuild resolver used water")
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll follower_surface_sprite tests passed.")
