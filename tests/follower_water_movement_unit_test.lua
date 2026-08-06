-- Surface-aware follower trailer movement (water freeze fix).
-- Run: lua tests/follower_water_movement_unit_test.lua
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

-- Stub SpriteRenderer so applySpriteDef can replace sprites in-process.
package.loaded["src.render.SpriteRenderer"] = {
  new = function(def, id)
    return { def = def, id = id }
  end,
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
        if key == "follower_count" then return 3 end
        if key == "control_mode" then return "follow" end
        return nil
      end,
    },
    exports = {
      getActiveFollowerMon = function()
        return { species = "PSYDUCK", hp = 20 }
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
  DEFAULTS = { sprite_style = "pokemmo", follower_count = 3 },
  get = function(_, k) return modules.config.DEFAULTS[k] end,
  spriteStyle = function() return "pokemmo" end,
  debug = function() return false end,
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end, debug = function() end,
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }
modules.cell_occupancy = {
  isFollowerEntity = function(e)
    return e and (e.pokepcTrailer == true or e.wildsFollower == true)
  end,
}
modules.surface = { WATER = "WATER", GRASS = "GRASS" }

local ControlEngine = V.require("follower/control_engine")
local FollowersWaterCompat = V.require("followers_water_compat")

----------------------------------------------------------------
-- Fake map: land walkable on y>=10, water on y<10
----------------------------------------------------------------
local function makeMap()
  return {
    id = "ROUTE19",
    widthCells = 40,
    heightCells = 40,
    inBounds = function(_, x, y)
      return x >= 0 and y >= 0 and x < 40 and y < 40
    end,
    isWalkableCell = function(_, x, y)
      -- Normal NPC land walkability: only shore/land (y >= 10)
      return y >= 10 and x >= 0 and x < 40
    end,
    isWaterCell = function(_, x, y)
      return y < 10 and x >= 0 and x < 40
    end,
  }
end

local function makeTrailer(slot, mon, x, y)
  return {
    id = "trailer" .. tostring(slot),
    pokepcTrailerId = "mon:" .. tostring(slot),
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
    sprite = {
      def = {
        id = "SPRITE_POKEPC_MON",
        image = "land_" .. tostring(mon.species) .. ".png",
        frames = 6,
        walker = true,
      },
    },
  }
end

local function makeEngine(count)
  return ControlEngine.new(V.mod, {
    settings = {
      followerCount = function(_, _g) return count or 3 end,
      engineMode = function(_, _g) return "follow" end,
    },
  })
end

local function makeGame(party, count)
  return {
    save = {
      party = party,
      pokepcFollowerCount = count or #party,
      pokepcControlMode = "follow",
    },
  }
end

----------------------------------------------------------------
-- 1. Land walkability unchanged for normal checks / trainer role
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  local map = makeMap()
  local ow = { map = map, player = { cellX = 5, cellY = 12, surfing = false } }
  local game = makeGame({ { species = "PSYDUCK", hp = 20 } }, 1)

  check(engine:isFollowerCellAllowed(game, ow, {
    wildsFollowerRole = "party_trailer",
  }, 5, 12, { surface = "land" }) == true, "land trailer on land cell")

  check(engine:isFollowerCellAllowed(game, ow, {
    wildsFollowerRole = "party_trailer",
  }, 5, 5, { surface = "land" }) == false, "land trailer rejects water on land surface")

  check(engine:isFollowerCellAllowed(game, ow, {
    wildsFollowerRole = "trainer_trailer",
  }, 5, 5, { surface = "water" }) == false, "trainer trailer never gets water exception")

  -- Normal NPCs still use map:isWalkableCell (unchanged).
  check(map:isWalkableCell(5, 5) == false, "map water not walkable for normal NPCs")
  check(map:isWalkableCell(5, 12) == true, "map land still walkable")
end

----------------------------------------------------------------
-- 2. Water surface allows water cells for party trailers
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  local map = makeMap()
  local ow = { map = map, player = { cellX = 5, cellY = 5, surfing = true } }
  local game = makeGame({ { species = "PSYDUCK", hp = 20 } }, 1)
  local entity = { wildsFollowerRole = "party_trailer" }

  check(engine:isFollowerCellAllowed(game, ow, entity, 5, 5, {
    surface = "water",
  }) == true, "water trailer allowed on water cell")

  check(engine:isFollowerCellAllowed(game, ow, entity, 5, 10, {
    surface = "water",
  }) == true, "water trailer may occupy shore during surf")

  check(engine:isFollowerCellAllowed(game, ow, {
    wildsFollowerRole = "primary",
  }, 5, 4, { surface = "water" }) == true, "primary role allowed on water")
end

----------------------------------------------------------------
-- 3. Land → water seed produces water goals (not frozen shore)
----------------------------------------------------------------
do
  local engine = makeEngine(3)
  local map = makeMap()
  local player = { cellX = 5, cellY = 5, facing = "up", surfing = true }
  local ow = { map = map, player = player }
  local game = makeGame({
    { species = "PSYDUCK", hp = 20 },
    { species = "ABRA", hp = 20 },
    { species = "SQUIRTLE", hp = 20 },
  }, 3)

  local bx, by = engine:_walkableBehind(ow, 5, 5, "up", 1, nil, game, "party_trailer")
  check(map:isWaterCell(bx, by) == true, "behind cell on water is water")
  check(engine:isFollowerCellAllowed(game, ow, nil, bx, by, {
    surface = "water", role = "party_trailer",
  }) == true, "seeded behind cell allowed")

  local goals = engine:_seedTrailBehind(ow, player, "up", 3, game, "party_trailer")
  eq(#goals, 3, "seeded 3 goals")
  local seen = {}
  for i, g in ipairs(goals) do
    check(engine:isFollowerCellAllowed(game, ow, nil, g.x, g.y, {
      surface = "water", role = "party_trailer",
    }) == true, "goal " .. i .. " allowed on water")
    local key = g.x .. "," .. g.y
    check(seen[key] ~= true, "goal " .. i .. " unique cell")
    seen[key] = true
  end
end

----------------------------------------------------------------
-- 4. Water trailer advances several steps via advanceTrailerStep
----------------------------------------------------------------
do
  local npc = makeTrailer(1, { species = "PSYDUCK", hp = 20 }, 5, 8)
  npc.targetX, npc.targetY = 5, 7
  npc.moving = true
  npc.stepFrames = 4
  npc.progress = 0

  for _ = 1, 4 do
    ControlEngine.advanceTrailerStep(npc, nil, nil)
  end
  eq(npc.cellX, 5, "water step cellX")
  eq(npc.cellY, 7, "water step cellY")
  check(npc.moving == false, "water step completed")
  eq(npc.progress, 0, "progress reset after step")

  -- Second step further into water
  npc.targetX, npc.targetY = 5, 6
  npc.moving = true
  npc.stepFrames = 4
  for _ = 1, 4 do
    ControlEngine.advanceTrailerStep(npc, nil, nil)
  end
  eq(npc.cellY, 6, "second water step")
end

----------------------------------------------------------------
-- 5. syncTrailers: land→water commits move trailers onto water goals
----------------------------------------------------------------
do
  local engine = makeEngine(3)
  local map = makeMap()
  local mons = {
    { species = "PSYDUCK", hp = 20 },
    { species = "ABRA", hp = 20 },
    { species = "SQUIRTLE", hp = 20 },
  }
  local game = makeGame(mons, 3)
  local t1 = makeTrailer(1, mons[1], 5, 11)
  local t2 = makeTrailer(2, mons[2], 5, 12)
  local t3 = makeTrailer(3, mons[3], 5, 13)
  -- Custom update like makeTrailer installs.
  for _, t in ipairs({ t1, t2, t3 }) do
    t.update = function(self, map, ents)
      ControlEngine.advanceTrailerStep(self, map, ents)
    end
  end

  local player = {
    cellX = 5, cellY = 8, targetX = 5, targetY = 7,
    facing = "up", surfing = true, stepFrames = 8,
  }
  local ow = {
    map = map,
    player = player,
    npcs = { t1, t2, t3 },
    entities = { t1, t2, t3 },
    pokepcTrailers = { t1, t2, t3 },
    pokepcTrailCells = {
      { x = 5, y = 11 }, { x = 5, y = 12 }, { x = 5, y = 13 },
    },
    pokepcTrailHead = { x = 5, y = 8 },
    _wildsFollowerTrailSurface = "land", -- force surface transition reseed
  }

  engine:syncTrailers(game, ow, { catchUp = true })
  check(ow._wildsFollowerTrailSurface == "water", "surface marker water")

  -- After surface reseed, trailers should be on water/shore goals, not stuck
  -- on old land cells alone without valid water goals.
  local goals = ow.pokepcTrailCells or {}
  check(#goals >= 1, "trail goals present after water enter")
  for i, g in ipairs(goals) do
    check(engine:isFollowerCellAllowed(game, ow, ow.pokepcTrailers[i], g.x, g.y, {
      surface = "water", role = "party_trailer",
    }) == true, "post-surf goal " .. i .. " allowed")
  end
end

----------------------------------------------------------------
-- 6. Water → land restores land movement targets
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  local map = makeMap()
  local mon = { species = "PSYDUCK", hp = 20 }
  local game = makeGame({ mon }, 1)
  local t1 = makeTrailer(1, mon, 5, 8)
  t1.wildsFollowerWater = true
  t1.spriteState = "water"
  t1.update = function(self, map, ents)
    ControlEngine.advanceTrailerStep(self, map, ents)
  end
  local player = {
    cellX = 5, cellY = 11, targetX = 5, targetY = 12,
    facing = "down", surfing = false, stepFrames = 8,
  }
  local ow = {
    map = map,
    player = player,
    npcs = { t1 },
    entities = { t1 },
    pokepcTrailers = { t1 },
    pokepcTrailCells = { { x = 5, y = 8 } },
    pokepcTrailHead = { x = 5, y = 11 },
    _wildsFollowerTrailSurface = "water",
  }
  engine:syncTrailers(game, ow, { catchUp = true })
  eq(ow._wildsFollowerTrailSurface, "land", "surface marker land")
  local g = ow.pokepcTrailCells[1]
  check(g ~= nil, "land goal exists")
  check(map:isWalkableCell(g.x, g.y) == true
        or map:isWaterCell(g.x, g.y) == true,
        "exit goal is land or transitional water")
end

----------------------------------------------------------------
-- 7. Trainer trailer excluded from want while surfing
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  engine.settings = {
    followerCount = function() return 1 end,
    engineMode = function() return "lead_trainer" end,
  }
  local map = makeMap()
  local mon = { species = "PSYDUCK", hp = 20 }
  local mon2 = { species = "ABRA", hp = 20 }
  local game = {
    save = {
      party = { mon, mon2 },
      pokepcFollowerCount = 1,
      pokepcControlMode = "lead_trainer",
      pokepcLeader = { source = "party", index = 1 },
    },
  }
  -- lead_trainer is pokemon-front: party trail = non-leader mons; trainer
  -- trailer is appended only when not surfing (mirrors syncTrailers).
  local surfing = true
  local mode = engine:controlMode(game)
  local want = {}
  for _, entry in ipairs(engine:partyTrailMons(game)) do
    want[#want + 1] = { kind = "mon", mon = entry.mon }
  end
  if not surfing then
    want[#want + 1] = { kind = "trainer", mon = nil }
  end
  local hasTrainer = false
  for _, w in ipairs(want) do
    if w.kind == "trainer" then hasTrainer = true end
  end
  check(hasTrainer == false, "no trainer want entry while surfing")
  check(#want >= 1, "pokemon trailers still wanted while surfing")
  eq(mode, "lead_trainer", "lead_trainer mode retained")

  -- On land, trainer is appended.
  surfing = false
  want = {}
  for _, entry in ipairs(engine:partyTrailMons(game)) do
    want[#want + 1] = { kind = "mon", mon = entry.mon }
  end
  if not surfing then
    want[#want + 1] = { kind = "trainer", mon = nil }
  end
  hasTrainer = false
  for _, w in ipairs(want) do
    if w.kind == "trainer" then hasTrainer = true end
  end
  check(hasTrainer == true, "trainer want restored on land")
end

----------------------------------------------------------------
-- 8. Pack of 3 keeps order; pack of 6 unique cells
----------------------------------------------------------------
do
  local engine = makeEngine(6)
  local map = makeMap()
  local party = {}
  for i = 1, 6 do
    party[i] = { species = "MON" .. i, hp = 20 }
  end
  local game = makeGame(party, 6)
  local player = { cellX = 5, cellY = 4, facing = "up", surfing = true }
  local ow = { map = map, player = player }
  local goals = engine:_seedTrailBehind(ow, player, "up", 6, game, "party_trailer")
  eq(#goals, 6, "6 goals seeded")
  local seen = {}
  for i, g in ipairs(goals) do
    local key = g.x .. "," .. g.y
    check(not seen[key], "pack6 goal " .. i .. " not double-occupied")
    seen[key] = true
  end
  -- Facing up → behind is +y; later slots are further behind.
  check(goals[1].y <= goals[3].y, "pack slot3 further behind than slot1")
  check(goals[3].y <= goals[6].y, "pack slot6 further behind than slot3")
end

----------------------------------------------------------------
-- 9–11. Water compat: per-entity species + movement fields preserved
----------------------------------------------------------------
do
  local compat = FollowersWaterCompat.new(V.mod, {
    resolveWaterSprite = function(species, shiny, form)
      return {
        image = "water_" .. tostring(species) .. ".png",
        frames = 6,
        walker = true,
        kind = "swimming",
        id = "SPRITE_WATER_" .. tostring(species),
      }, { kind = "swimming" }
    end,
    resolveLandSprite = function(species)
      return {
        image = "land_" .. tostring(species) .. ".png",
        frames = 6,
        walker = true,
        id = "SPRITE_LAND_" .. tostring(species),
      }, { kind = "pokemmo" }
    end,
  })

  local a = makeTrailer(1, { species = "PSYDUCK", hp = 20 }, 5, 5)
  local b = makeTrailer(2, { species = "ABRA", hp = 20 }, 5, 6)
  local c = makeTrailer(3, { species = "SQUIRTLE", hp = 20 }, 5, 7)
  a.moving = true
  a.targetX, a.targetY = 5, 4
  a.progress = 3
  a.stepFrames = 8

  local ow = {
    player = { cellX = 5, cellY = 3, surfing = true, surface = "WATER" },
    entities = { a, b, c },
    pokepcTrailers = { a, b, c },
  }

  local newsBefore = compat._spriteRendererNews or 0
  compat:tick(nil, ow)
  check(a.sprite.def.image:find("PSYDUCK", 1, true), "trailer1 keeps PSYDUCK species")
  check(b.sprite.def.image:find("ABRA", 1, true), "trailer2 keeps ABRA species")
  check(c.sprite.def.image:find("SQUIRTLE", 1, true), "trailer3 keeps SQUIRTLE species")
  eq(a.moving, true, "sprite rebind keeps moving")
  eq(a.targetX, 5, "sprite rebind keeps targetX")
  eq(a.targetY, 4, "sprite rebind keeps targetY")
  eq(a.progress, 3, "sprite rebind keeps progress")
  check(a.wildsFollowerWater == true, "trailer1 water flag")
  check(b.wildsFollowerWater == true, "trailer2 water flag")
  check(c.wildsFollowerWater == true, "trailer3 water flag")

  local newsMid = compat._spriteRendererNews or 0
  check(newsMid > newsBefore, "SpriteRenderer.new used on water enter")
  compat:tick(nil, ow)
  eq(compat._spriteRendererNews, newsMid, "no SpriteRenderer.new per frame")
  eq(compat.status.lastAction, "cached", "pack water tick cached")

  -- Trainer trailer ignored
  local trainer = {
    id = "trainer1",
    pokepcTrailer = true,
    pokepcTrailerKind = "trainer",
    wildsFollowerRole = "trainer_trailer",
    cellX = 5, cellY = 9,
    sprite = { def = { image = "trainer.png", frames = 6, walker = true } },
  }
  ow.pokepcTrailers = { a, b, c, trainer }
  ow.entities = { a, b, c, trainer }
  compat:tick(nil, ow)
  eq(trainer.sprite.def.image, "trainer.png", "trainer sprite untouched")
  check(trainer.wildsFollowerWater ~= true, "trainer not marked water")
end

----------------------------------------------------------------
-- 12. Global active mon must not overwrite pack trailer species
----------------------------------------------------------------
do
  V.mod.exports.getActiveFollowerMon = function()
    return { species = "PIKACHU", hp = 20 }
  end
  local compat = FollowersWaterCompat.new(V.mod, {
    resolveWaterSprite = function(species)
      return {
        image = "water_" .. tostring(species) .. ".png",
        frames = 6, walker = true, kind = "swimming",
      }, { kind = "swimming" }
    end,
  })
  local a = makeTrailer(1, { species = "PSYDUCK", hp = 20 }, 1, 1)
  local b = makeTrailer(2, { species = "ABRA", hp = 20 }, 1, 2)
  local ow = {
    player = { surfing = true, surface = "WATER" },
    pokepcTrailers = { a, b },
    entities = { a, b },
  }
  compat:tick(nil, ow)
  check(a.sprite.def.image:find("PSYDUCK", 1, true), "pack uses pokepcMon not global active")
  check(b.sprite.def.image:find("ABRA", 1, true), "second trailer own species")
  check(not a.sprite.def.image:find("PIKACHU", 1, true), "global active not applied to pack")
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll follower_water_movement tests passed.")
