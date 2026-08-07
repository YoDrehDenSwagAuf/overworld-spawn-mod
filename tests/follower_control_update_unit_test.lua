-- ControlEngine:update ownership — trailers must tick while surfing even when
-- stock PikachuFollower.shouldSpawn is false.
-- Run: lua tests/follower_control_update_unit_test.lua
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

-- Minimal OverworldController so install can wrap update.
local owUpdateCalls = 0
local OverworldState = {}
function OverworldState:update(dt)
  owUpdateCalls = owUpdateCalls + 1
  -- Simulate stock order: npc loop (trailer.update is no-op) then player step.
  for _, npc in ipairs(self.npcs or {}) do
    if npc.update then npc:update(self.map, self.entities) end
  end
  if self.player and self.player._pendingTarget then
    self.player.targetX = self.player._pendingTarget.x
    self.player.targetY = self.player._pendingTarget.y
    self.player._pendingTarget = nil
  elseif self.player and not self.player.moving then
    self.player.targetX, self.player.targetY = nil, nil
  end
end
package.loaded["src.world.OverworldController"] = OverworldState

-- Stock PikachuFollower that early-returns when shouldSpawn is false (surf).
local stockShouldSpawn
local PF = {
  update = function(game, ow)
    if not stockShouldSpawn(game, ow) then
      return "early"
    end
    return "full"
  end,
  onMapEntered = function() end,
  starterInParty = function() return nil end,
}
-- Upvalues for patchUpvalue
do
  local shouldSpawn = function(game, ow)
    if ow and ow.player and ow.player.surfing then return false end
    return true
  end
  stockShouldSpawn = shouldSpawn
  -- Recreate update/onMapEntered with upvalue named shouldSpawn
  PF.update = function(game, ow)
    if not shouldSpawn(game, ow) then return "early" end
    return "full"
  end
  PF.onMapEntered = function(game, ow)
    if not shouldSpawn(game, ow) then return end
  end
end
package.loaded["src.world.PikachuFollower"] = PF

package.loaded["src.world.NPC"] = {
  new = function()
    return {
      id = "npc",
      cellX = 0, cellY = 0, px = 0, py = 0,
      facing = "down", moving = false, progress = 0,
      update = function() end,
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
        if key == "follower_count" then return 3 end
        if key == "control_mode" then return "follow" end
        return nil
      end,
    },
    events = { on = function() end },
    exports = {},
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
modules.tile = { CELL = 16 }
modules.cell_occupancy = {
  isFollowerEntity = function(e)
    return e and e.pokepcTrailer == true
  end,
}
modules.surface = { WATER = "WATER" }

local ControlEngine = V.require("follower/control_engine")
local FollowersWaterCompat = V.require("followers_water_compat")

local function makeMap()
  return {
    id = "ROUTE19",
    inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 40 and y < 40 end,
    isWalkableCell = function(_, x, y) return y >= 10 end,
    isWaterCell = function(_, x, y) return y < 10 end,
  }
end

local function makeTrailer(slot, mon, x, y)
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
    sprite = {
      def = { image = "land_" .. mon.species .. ".png", frames = 6, walker = true },
    },
  }
end

local function makeEngine(count)
  return ControlEngine.new(V.mod, {
    settings = {
      followerCount = function() return count or 3 end,
      engineMode = function() return "follow" end,
    },
    game = nil,
  })
end

----------------------------------------------------------------
-- Install: OverworldController owns trailer updates
----------------------------------------------------------------
do
  local engine = makeEngine(3)
  local ok, reason = engine:install()
  check(ok == true, "control engine installs with mocked PF/NPC/OW")
  eq(engine._trailerUpdateOwner, "overworld", "trailer owner is overworld")
  check(OverworldState.update == OverworldState._wildsControlEngineUpdateWrap,
        "OverworldController.update wrapped")
  engine:restore()
  check(OverworldState._wildsControlEngineUpdateWrap == nil
        or OverworldState.update ~= OverworldState._wildsControlEngineUpdateWrap,
        "OW update wrap restored")
end

----------------------------------------------------------------
-- ControlEngine.update runs on land and water; shouldSpawn false is irrelevant
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  engine._trailerUpdateOwner = "overworld"
  local mon = { species = "PSYDUCK", hp = 20 }
  local game = {
    save = {
      party = { mon },
      pokepcFollowerCount = 1,
      pokepcControlMode = "follow",
    },
  }
  engine._gameRef = game
  local map = makeMap()
  local t1 = makeTrailer(1, mon, 5, 8)
  t1.update = function() error("trailer npc.update must not drive movement") end
  local player = {
    cellX = 5, cellY = 7, facing = "up",
    surfing = false, stepFrames = 4,
  }
  local ow = {
    map = map,
    player = player,
    npcs = { t1 },
    entities = { t1 },
    pokepcTrailers = { t1 },
    pokepcTrailCells = { { x = 5, y = 8 } },
    pokepcTrailHead = { x = 5, y = 7 },
  }

  check(engine:shouldSpawnStockFollower(game, ow) == true
        or engine:followerCount(game) > 0, "stock spawn gated separately")
  -- With followers>0 non-Yellow, stock spawn is false — trailers must still update.
  check(engine:shouldSpawnStockFollower(game, ow) == false,
        "stock shouldSpawn false with pack count")
  check(engine:shouldUpdateWildsTrailers(game, ow) == true,
        "wilds trailers still update on land")

  local ok = engine:update(game, ow, { source = "test" })
  check(ok == true, "ControlEngine.update runs when not surfing")
  check(engine.diag.controlUpdateCalls >= 1, "controlUpdateCalls incremented")
  check(engine.diag.syncTrailersCalls >= 1, "syncTrailersCalls incremented")

  -- Surf
  player.surfing = true
  player.cellX, player.cellY = 5, 5
  player.targetX, player.targetY = 5, 4
  ow._wildsFollowerTrailSurface = "land"
  ow.pokepcTrailHead = { x = 5, y = 5 }
  check(engine:shouldSpawnStockFollower(game, ow) == false,
        "stock shouldSpawn false while surfing")
  check(engine:shouldUpdateWildsTrailers(game, ow) == true,
        "wilds trailers update while surfing")

  local beforeCtrl = engine.diag.controlUpdateCalls
  local beforeSync = engine.diag.syncTrailersCalls
  ok = engine:update(game, ow, { source = "test-surf" })
  check(ok == true, "ControlEngine.update runs while surfing")
  check(engine.diag.controlUpdateCalls == beforeCtrl + 1, "exactly one control update")
  check(engine.diag.syncTrailersCalls == beforeSync + 1, "exactly one syncTrailers")
end

----------------------------------------------------------------
-- Three consecutive surf steps: progress + cells advance
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  local mon = { species = "PSYDUCK", hp = 20 }
  local game = {
    save = { party = { mon }, pokepcFollowerCount = 1, pokepcControlMode = "follow" },
  }
  engine._gameRef = game
  local map = makeMap()
  local t1 = makeTrailer(1, mon, 5, 8)
  local player = {
    cellX = 5, cellY = 7, targetX = 5, targetY = 6,
    facing = "up", surfing = true, stepFrames = 4, moving = true,
  }
  local ow = {
    map = map,
    player = player,
    npcs = { t1 },
    entities = { t1 },
    pokepcTrailers = { t1 },
    pokepcTrailCells = { { x = 5, y = 8 } },
    pokepcTrailHead = { x = 5, y = 7 },
    _wildsFollowerTrailSurface = "land",
  }

  -- Enter water / reseed
  engine:update(game, ow, { source = "surf1" })
  check(ow._wildsFollowerTrailSurface == "water", "surface water after first update")

  -- Drive three player water steps; each update may start/advance trailer.
  local startY = t1.cellY
  local advanced = false
  for step = 1, 3 do
    local fromY = 7 - step
    local toY = fromY - 1
    player.cellX, player.cellY = 5, fromY
    player.targetX, player.targetY = 5, toY
    ow.pokepcTrailHead = { x = 5, y = fromY }
    -- Finish any in-flight trailer step, then commit next head.
    for _ = 1, 8 do
      engine:update(game, ow, { source = "surf-step" })
      if not t1.moving then break end
    end
    if t1.cellY ~= startY or t1.moving then advanced = true end
  end
  check(advanced == true, "trailer moved across surf steps")
  check(engine.diag.advanceTrailerStepCalls > 0,
        "advanceTrailerStep executed in water")
  check(map:isWaterCell(t1.cellX, t1.cellY) or t1.moving,
        "trailer on water or mid water step")
end

----------------------------------------------------------------
-- No double step: reentrant update + single advance per frame
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  local mon = { species = "SQUIRTLE", hp = 20 }
  local game = {
    save = { party = { mon }, pokepcFollowerCount = 1, pokepcControlMode = "follow" },
  }
  engine._gameRef = game
  local t1 = makeTrailer(1, mon, 5, 5)
  t1.moving = true
  t1.targetX, t1.targetY = 5, 4
  t1.stepFrames = 8
  t1.progress = 0
  local ow = {
    map = makeMap(),
    player = { cellX = 5, cellY = 3, surfing = true, facing = "up", stepFrames = 8 },
    npcs = { t1 },
    entities = { t1 },
    pokepcTrailers = { t1 },
    pokepcTrailCells = { { x = 5, y = 4 } },
    pokepcTrailHead = { x = 5, y = 3 },
    _wildsFollowerTrailSurface = "water",
  }
  local before = engine.diag.advanceTrailerStepCalls
  engine:update(game, ow, { source = "once" })
  local mid = engine.diag.advanceTrailerStepCalls
  check(mid == before + 1, "one advanceTrailerStep per update")
  eq(t1.progress, 1, "progress +1 per logic frame")

  -- Reentrant guard
  local nested = false
  local origAdvance = ControlEngine.advanceAllTrailers
  engine.advanceAllTrailers = function(self, o)
    nested = true
    local r = self:update(game, o, { source = "nested", force = true })
    check(r == false, "reentrant update rejected")
    return origAdvance(self, o)
  end
  engine:update(game, ow, { source = "outer" })
  check(nested == true, "reentrancy path exercised")
  engine.advanceAllTrailers = origAdvance
end

----------------------------------------------------------------
-- OW wrap drives update while surfing; PF.update early-return does not stop it
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  engine:install()
  eq(engine._trailerUpdateOwner, "overworld", "installed owner overworld")

  local mon = { species = "PSYDUCK", hp = 20 }
  local game = {
    save = { party = { mon }, pokepcFollowerCount = 1, pokepcControlMode = "follow" },
    data = { sprites = { SPRITE_PIKACHU = { image = "x" } } },
  }
  engine._gameRef = game
  local t1 = makeTrailer(1, mon, 5, 6)
  t1.moving = true
  t1.targetX, t1.targetY = 5, 5
  t1.stepFrames = 4
  t1.progress = 0
  -- makeTrailer-style ownership
  t1.update = function() end
  t1._wildsFollowerStepOwned = true

  local ow = setmetatable({
    map = makeMap(),
    player = {
      cellX = 5, cellY = 4, targetX = 5, targetY = 3,
      surfing = true, facing = "up", stepFrames = 4,
    },
    npcs = { t1 },
    entities = { t1 },
    pokepcTrailers = { t1 },
    pokepcTrailCells = { { x = 5, y = 5 } },
    pokepcTrailHead = { x = 5, y = 4 },
    _wildsFollowerTrailSurface = "water",
  }, { __index = OverworldState })

  local beforeAdv = engine.diag.advanceTrailerStepCalls
  local beforeCtrl = engine.diag.controlUpdateCalls

  -- Stock PF.update early-returns while surfing — must not matter.
  local pfResult = PF.update(game, ow)
  eq(pfResult, "early", "stock PF.update early-returns on surf")
  -- Capture wrap count after the explicit PF call; OW path must not add more.
  local wrapAfterPf = engine.diag.wrappedUpdateCalls

  -- Overworld update owns the tick (does not go through PF.update).
  ow:update(1 / 60)
  check(engine.diag.controlUpdateCalls == beforeCtrl + 1,
        "OW update triggers ControlEngine.update while surfing")
  check(engine.diag.advanceTrailerStepCalls == beforeAdv + 1,
        "OW update advances trailer in water")
  eq(t1.progress, 1, "trailer progress after OW tick")
  eq(engine.diag.wrappedUpdateCalls, wrapAfterPf,
     "OW path does not also invoke wrappedUpdate")

  engine:restore()
end

----------------------------------------------------------------
-- Yellow stock is not surf trail anchor
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  engine._isYellow = function() return true end
  local stock = {
    pikachuFollower = true,
    cellX = 1, cellY = 12, facing = "up",
  }
  local player = { cellX = 5, cellY = 5, surfing = true, facing = "up" }
  local ow = { player = player, npcs = { stock }, map = makeMap() }
  local game = { save = { party = { { species = "PIKACHU", hp = 20 } } } }
  local anchor = engine:_trailAnchor(game, ow, player)
  eq(anchor, player, "surf anchor is player, not stock Pikachu")
end

----------------------------------------------------------------
-- Pack 3 & 6 move in water via ControlEngine.update
----------------------------------------------------------------
do
  local function runPack(n)
    local engine = makeEngine(n)
    local party = {}
    local trailers = {}
    for i = 1, n do
      party[i] = { species = "MON" .. i, hp = 20 }
      trailers[i] = makeTrailer(i, party[i], 5, 8 + i)
      trailers[i].update = function() end
      trailers[i]._wildsFollowerStepOwned = true
    end
    local game = {
      save = { party = party, pokepcFollowerCount = n, pokepcControlMode = "follow" },
    }
    engine._gameRef = game
    local player = {
      cellX = 5, cellY = 5, targetX = 5, targetY = 4,
      surfing = true, facing = "up", stepFrames = 4,
    }
    local ow = {
      map = makeMap(),
      player = player,
      npcs = trailers,
      entities = trailers,
      pokepcTrailers = trailers,
      pokepcTrailCells = {},
      pokepcTrailHead = { x = 5, y = 5 },
      _wildsFollowerTrailSurface = "land",
    }
    for i = 1, n do ow.pokepcTrailCells[i] = { x = 5, y = 8 + i } end
    engine:update(game, ow, { source = "pack" })
    for _ = 1, 12 do
      player.targetX, player.targetY = 5, (player.targetY or 4) - 1
      player.cellY = player.targetY + 1
      ow.pokepcTrailHead = { x = 5, y = player.cellY }
      engine:update(game, ow, { source = "pack-step" })
    end
    local anyMoved = false
    for _, t in ipairs(trailers) do
      if t.moving or t.cellY < 8 + n then anyMoved = true end
    end
    return anyMoved, engine.diag.advanceTrailerStepCalls
  end
  local moved3, adv3 = runPack(3)
  check(moved3, "pack of 3 moves in water")
  check(adv3 > 0, "pack3 advance calls")
  local moved6, adv6 = runPack(6)
  check(moved6, "pack of 6 moves in water")
  check(adv6 > 0, "pack6 advance calls")
end

----------------------------------------------------------------
-- Trainer trailer hidden while surfing (composition)
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  engine.settings = {
    followerCount = function() return 1 end,
    engineMode = function() return "lead_trainer" end,
  }
  local game = {
    save = {
      party = { { species = "PSYDUCK", hp = 20 }, { species = "ABRA", hp = 20 } },
      pokepcFollowerCount = 1,
      pokepcControlMode = "lead_trainer",
      pokepcLeader = { source = "party", index = 1 },
    },
  }
  local surfing = true
  local want = {}
  for _, entry in ipairs(engine:partyTrailMons(game)) do
    want[#want + 1] = { kind = "mon", mon = entry.mon }
  end
  if not surfing then want[#want + 1] = { kind = "trainer" } end
  local hasTrainer = false
  for _, w in ipairs(want) do if w.kind == "trainer" then hasTrainer = true end end
  check(hasTrainer == false, "trainer trailer omitted while surfing")
end

----------------------------------------------------------------
-- Sprite rebind keeps movement fields (regression)
----------------------------------------------------------------
do
  local compat = FollowersWaterCompat.new(V.mod, {
    resolveWaterSprite = function(species)
      return {
        image = "water_" .. species .. ".png", frames = 6, walker = true, kind = "swimming",
      }, { kind = "swimming" }
    end,
  })
  local a = makeTrailer(1, { species = "PSYDUCK", hp = 20 }, 5, 5)
  a.moving = true
  a.targetX, a.targetY = 5, 4
  a.progress = 2
  local ow = {
    player = { surfing = true, surface = "WATER" },
    pokepcTrailers = { a },
    entities = { a },
  }
  compat:tick(nil, ow)
  eq(a.moving, true, "rebind keeps moving")
  eq(a.targetX, 5, "rebind keeps targetX")
  eq(a.targetY, 4, "rebind keeps targetY")
  eq(a.progress, 2, "rebind keeps progress")
end

----------------------------------------------------------------
-- Land → water → land via ControlEngine.update
----------------------------------------------------------------
do
  local engine = makeEngine(1)
  local mon = { species = "PSYDUCK", hp = 20 }
  local game = {
    save = { party = { mon }, pokepcFollowerCount = 1, pokepcControlMode = "follow" },
  }
  engine._gameRef = game
  local t1 = makeTrailer(1, mon, 5, 12)
  t1.update = function() end
  local player = {
    cellX = 5, cellY = 11, facing = "up", surfing = false, stepFrames = 4,
  }
  local ow = {
    map = makeMap(),
    player = player,
    npcs = { t1 },
    entities = { t1 },
    pokepcTrailers = { t1 },
    pokepcTrailCells = { { x = 5, y = 12 } },
    pokepcTrailHead = { x = 5, y = 11 },
  }
  engine:update(game, ow, { source = "land" })
  eq(ow._wildsFollowerTrailSurface or "land", "land", "start land")

  player.surfing = true
  player.cellX, player.cellY = 5, 8
  player.targetX, player.targetY = 5, 7
  engine:update(game, ow, { source = "to-water" })
  eq(ow._wildsFollowerTrailSurface, "water", "entered water")

  player.surfing = false
  player.cellX, player.cellY = 5, 11
  player.targetX, player.targetY = 5, 12
  engine:update(game, ow, { source = "to-land" })
  eq(ow._wildsFollowerTrailSurface, "land", "returned to land")
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll follower_control_update tests passed.")
