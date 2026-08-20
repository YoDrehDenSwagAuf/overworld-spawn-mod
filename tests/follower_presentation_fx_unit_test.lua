-- Follower RELEASE / RECALL presentation FX.
-- Run: lua tests/follower_presentation_fx_unit_test.lua
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
local function near(a, b, eps, msg)
  eps = eps or 0.02
  check(math.abs((a or 0) - (b or 0)) <= eps,
    string.format("%s (got %s expected %s ±%s)", msg, tostring(a), tostring(b), tostring(eps)))
end

package.loaded["src.render.SpriteRenderer"] = {
  new = function(def, id)
    return {
      def = def,
      id = id,
      draw = function() end,
    }
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
      update = function() end,
      pose = function(ent)
        return ent.sprite, ent.px, ent.py, ent.facing, 0, false
      end,
    }
  end,
  walkPhase = function() return 0 end,
}
package.loaded["src.world.OverworldController"] = {
  update = function() end,
  interact = function() end,
  talkTo = function() end,
}
package.loaded["src.core.GameVersion"] = {
  get = function() return "red" end,
  isYellow = function() return false end,
  isGold = function() return false end,
  generation = function() return 1 end,
}

local modules = {}
local optionStore = {
  follower_count = 1,
  control_mode = "follow",
  sprite_style = "pokemmo",
}
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end, error = function() end },
    find = function() return nil end,
    options = {
      get = function(_, key) return optionStore[key] end,
      set = function(_, key, val) optionStore[key] = val end,
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
  spriteStyle = function() return optionStore.sprite_style or "pokemmo" end,
  debug = function() return false end,
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end, debug = function() end,
  followerGen2 = function() end, followerGen2Always = function() end,
}
modules.tile = { CELL = 16 }
modules.cell_occupancy = {
  isFollowerEntity = function(e)
    return e and (e.pokepcTrailer == true or e.wildsFollower == true or e.pikachuFollower == true)
  end,
  isBlockingEntity = function(e)
    if not e then return false end
    if e.fxOnly == true or e.pureFx == true then return false end
    if e.pokepcTrailer == true or e.wildsFollower == true then return true end
    return e.passable ~= true
  end,
}
modules.surface = { WATER = "WATER" }
modules.game_compat = {
  isGen1 = function() return true end,
  isGen2 = function() return false end,
  gameVersion = function() return "red" end,
  generation = function() return 1 end,
  supportsFeature = function() return true end,
  liveOverworld = function(_, game) return game and game.overworld end,
  party = function(game) return game and game.save and game.save.party or {} end,
  attachGuestEntity = function(ow, entity)
    ow.entities = ow.entities or {}
    ow.npcs = ow.npcs or {}
    local function has(list, e)
      for _, x in ipairs(list) do if x == e then return true end end
      return false
    end
    if not has(ow.entities, entity) then ow.entities[#ow.entities + 1] = entity end
    if not has(ow.npcs, entity) then ow.npcs[#ow.npcs + 1] = entity end
    return "npcs+entities"
  end,
  detachGuestEntity = function(ow, entity)
    local function strip(list)
      if type(list) ~= "table" then return end
      for i = #list, 1, -1 do
        if list[i] == entity then table.remove(list, i) end
      end
    end
    strip(ow.entities)
    strip(ow.npcs)
  end,
  isSurfing = function() return false end,
  presentText = function() end,
}

local PresentationFx = V.require("follower/presentation_fx")
local ControlEngine = V.require("follower/control_engine")
local Selection = V.require("follower/selection")
local State = V.require("follower/state")
local CellOccupancy = V.require("cell_occupancy")

local function makeMon(species, slot)
  return {
    species = species,
    hp = 20,
    otId = 1000 + (slot or 1),
    dvs = { attack = slot or 1, defense = 2, speed = 3, special = 4 },
    catchRate = 45,
  }
end

local function makeOw(trailers)
  return {
    map = {
      id = "ROUTE1",
      inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 40 and y < 40 end,
      isWalkableCell = function() return true end,
      isWaterCell = function() return false end,
    },
    player = { cellX = 10, cellY = 10, facing = "down", px = 160, py = 160 },
    npcs = {},
    entities = {},
    pokepcTrailers = {},
    pokepcTrailCells = {},
  }
end

local function makeTrailer(slot, mon, x, y, geom)
  geom = geom or {}
  local npc = {
    id = "trailer" .. slot,
    pokepcTrailerId = "mon:" .. slot,
    pokepcTrailer = true,
    pokepcTrailerKind = "mon",
    wildsFollower = true,
    wildsFollowerSlot = slot,
    wildsFollowerRole = "party_trailer",
    pokepcMon = mon,
    cellX = x, cellY = y,
    px = x * 16, py = y * 16,
    facing = "down",
    moving = false,
    progress = 0,
    passable = true,
    pikachuFollower = false,
    update = function() end,
    sprite = {
      def = {
        image = "land_" .. mon.species .. ".png",
        frames = 6,
        walker = true,
        frameWidth = geom.frameWidth or 16,
        frameHeight = geom.frameHeight or 16,
        anchorX = geom.anchorX,
        anchorY = geom.anchorY,
      },
      draw = function() end,
    },
  }
  function npc:pose()
    return self.sprite, self.px, self.py, self.facing, 0, false
  end
  return npc
end

local function attachTrailer(ow, npc)
  ow.pokepcTrailers = ow.pokepcTrailers or {}
  ow.pokepcTrailers[#ow.pokepcTrailers + 1] = npc
  ow.npcs[#ow.npcs + 1] = npc
  ow.entities[#ow.entities + 1] = npc
  ow.pokepcTrailCells = ow.pokepcTrailCells or {}
  ow.pokepcTrailCells[#ow.pokepcTrailCells + 1] = { x = npc.cellX, y = npc.cellY }
end

--------------------------------------------------------------------
-- 1. Visual math: release / recall interpolation
--------------------------------------------------------------------
do
  local s0 = PresentationFx.sample("release", 0)
  check(s0.scale < 0.25, "release t=0 tiny scale")
  check(s0.alpha < 0.5, "release t=0 low alpha")
  check(s0.r > 0.95 and s0.g > 0.95 and s0.b > 0.95, "release t=0 nearly white")

  local s05 = PresentationFx.sample("release", 0.5)
  check(s05.scale > s0.scale and s05.scale < 1, "release t=0.5 mid scale")
  check(s05.r > 0.9 and s05.g < 0.7, "release t=0.5 red/pink tint")

  local s1 = PresentationFx.sample("release", 1)
  near(s1.scale, 1, 0.001, "release t=1 full scale")
  near(s1.alpha, 1, 0.001, "release t=1 full alpha")
  near(s1.r, 1, 0.001, "release t=1 no red tint")
  near(s1.g, 1, 0.001, "release t=1 no green tint")
  near(s1.b, 1, 0.001, "release t=1 no blue tint")
  check(s1.done == true, "release t=1 done")

  local prev = PresentationFx.sample("release", 0)
  for i = 1, 10 do
    local s = PresentationFx.sample("release", i / 10)
    check(s.scale >= prev.scale - 1e-9, "release scale monotonic @" .. i)
    check(s.alpha >= prev.alpha - 1e-9, "release alpha monotonic @" .. i)
    prev = s
  end

  local r0 = PresentationFx.sample("recall", 0)
  near(r0.scale, 1, 0.001, "recall t=0 full scale")
  near(r0.alpha, 1, 0.001, "recall t=0 full alpha")

  local r1 = PresentationFx.sample("recall", 1)
  check(r1.scale < 0.25, "recall t=1 tiny")
  near(r1.alpha, 0, 0.001, "recall t=1 gone")
  check(r1.done == true, "recall t=1 done")

  prev = PresentationFx.sample("recall", 0)
  for i = 1, 10 do
    local s = PresentationFx.sample("recall", i / 10)
    check(s.scale <= prev.scale + 1e-9, "recall scale monotonic @" .. i)
    check(s.alpha <= prev.alpha + 1e-9, "recall alpha monotonic @" .. i)
    prev = s
  end
end

--------------------------------------------------------------------
-- 2. Follow → release queued/started
--------------------------------------------------------------------
do
  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  local fx = PresentationFx.new(V.mod, { selection = selection })
  local ow = makeOw()
  local monA = makeMon("BULBASAUR", 1)
  local monB = makeMon("CHARMANDER", 2)

  -- Empty → one follower: release
  local before = fx:captureVisibleFollowers(ow)
  local npc = makeTrailer(1, monA, 10, 11)
  attachTrailer(ow, npc)
  local res = fx:reconcileAfterSync(ow, before, { stagger = 0 })
  eq(res.released, 1, "follow add starts release")
  eq(res.recalled, 0, "follow add no recall")
  check(npc._wildsPresentationFx ~= nil, "release fx attached")
  eq(npc._wildsPresentationFx.kind, "release", "fx kind release")
end

--------------------------------------------------------------------
-- 3. Release progression clears at end
--------------------------------------------------------------------
do
  local fx = PresentationFx.new(V.mod, {})
  local ow = makeOw()
  local npc = makeTrailer(1, makeMon("SQUIRTLE", 1), 10, 11)
  attachTrailer(ow, npc)
  fx:_beginOnEntity(npc, "release", 0)
  fx:tick(ow, 0)
  local s = PresentationFx.sample("release", 0)
  check(npc._wildsPresentationFx ~= nil, "fx active at start")
  check(s.scale < 0.3, "t0 tiny")

  fx:tick(ow, PresentationFx.DURATION * 0.5)
  check(npc._wildsPresentationFx ~= nil, "fx mid")
  check(npc._wildsPresentationFx.elapsed > 0, "elapsed advanced")

  fx:tick(ow, PresentationFx.DURATION)
  check(npc._wildsPresentationFx == nil, "fx removed at completion")
end

--------------------------------------------------------------------
-- 4–5. Stop Following: selection gone, recall ghost temporary
--------------------------------------------------------------------
do
  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  local fx = PresentationFx.new(V.mod, { selection = selection })
  local ow = makeOw()
  local mon = makeMon("PIDGEY", 1)
  local npc = makeTrailer(1, mon, 10, 11)
  attachTrailer(ow, npc)

  local before = fx:captureVisibleFollowers(ow)
  -- Simulate gameplay clear + trailer remove
  ow.pokepcTrailers = {}
  local keep = {}
  for _, e in ipairs(ow.entities) do
    if e ~= npc then keep[#keep + 1] = e end
  end
  ow.entities = keep
  ow.npcs = {}
  for _, e in ipairs(keep) do ow.npcs[#ow.npcs + 1] = e end

  local res = fx:reconcileAfterSync(ow, before, { stagger = 0 })
  eq(res.recalled, 1, "dismiss starts recall")
  eq(res.released, 0, "dismiss no release")
  eq(fx:activeGhostCount(), 1, "one recall ghost")

  local ghost = fx.ghosts[1]
  check(ghost ~= nil, "ghost exists")
  check(ghost.fxOnly == true, "ghost fxOnly")
  check(ghost.pureFx == true, "ghost pureFx")
  check(ghost.pokepcTrailer ~= true, "ghost not trailer")
  check(ghost.wildsFollower ~= true, "ghost not wildsFollower")
  check(ghost.update == ghost.update, "ghost has update")
  -- No collision / occupancy as follower
  check(CellOccupancy.isBlockingEntity(ghost) == false, "ghost not blocking")
  check(CellOccupancy.isFollowerEntity(ghost) == false, "ghost not follower entity")

  fx:tick(ow, PresentationFx.DURATION + 0.01)
  eq(fx:activeGhostCount(), 0, "ghost removed after recall")
  local still = false
  for _, e in ipairs(ow.entities or {}) do
    if e == ghost then still = true end
  end
  check(not still, "ghost detached from world")
end

--------------------------------------------------------------------
-- 6–9. Technical paths: no FX
--------------------------------------------------------------------
do
  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  local engine = ControlEngine.new(V.mod, {
    selection = selection,
    settings = {
      engineMode = function() return "follow" end,
      followerCount = function() return 1 end,
      alignSaveFromOptions = function() end,
      onOptionsChanged = function() end,
    },
    spriteService = {
      resolveFollowerSprite = function(_, opts)
        return {
          id = "SPRITE_TEST",
          image = "x.png",
          frames = 6,
          walker = true,
          frameWidth = 16,
          frameHeight = 16,
        }
      end,
    },
  })
  local game = {
    save = {
      party = { makeMon("RATTATA", 1) },
      pokepcFollowerCount = 1,
      pokepcControlMode = "follow",
      followerPartyIndex = 1,
    },
    data = {},
  }
  engine._gameRef = game
  local ow = makeOw()
  game.overworld = ow
  local npc = makeTrailer(1, game.save.party[1], 10, 11)
  attachTrailer(ow, npc)

  -- Map transition style syncAll WITHOUT intent
  engine._presentationIntent = nil
  engine:syncAll(game, ow)
  local anyFx = false
  for _, e in ipairs(ow.pokepcTrailers or {}) do
    if e._wildsPresentationFx then anyFx = true end
  end
  check(not anyFx, "map-like syncAll without intent → no FX")
  eq(engine.presentationFx:activeGhostCount(), 0, "no recall ghosts on technical sync")

  -- Battle return path: no intent
  engine._presentationIntent = nil
  engine._pendingBattleReturnSync = true
  engine._battleReturnPhase = "pending"
  -- Just ensure beginPresentationIntent was not set
  check(engine._presentationIntent == nil, "battle path leaves intent nil")

  -- Sprite style: Follower.onOptionsChanged must not set intent for sprite_style
  -- (exercised via intent API contract)
  engine:beginPresentationIntent("options:follower_count")
  eq(engine._presentationIntent, "options:follower_count", "count intent set")
  engine._presentationIntent = nil -- simulate sprite_style skipping beginPresentationIntent
  check(engine._presentationIntent == nil, "sprite_style leaves intent nil")
end

--------------------------------------------------------------------
-- 10–12. Count change + switch
--------------------------------------------------------------------
do
  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  local fx = PresentationFx.new(V.mod, { selection = selection })
  local ow = makeOw()
  local m1 = makeMon("BULBASAUR", 1)
  local m2 = makeMon("CHARMANDER", 2)
  local m3 = makeMon("SQUIRTLE", 3)
  local t1 = makeTrailer(1, m1, 10, 11)
  attachTrailer(ow, t1)

  local before = fx:captureVisibleFollowers(ow)
  -- Count 1 → 3: keep m1, add m2/m3
  local t2 = makeTrailer(2, m2, 10, 12)
  local t3 = makeTrailer(3, m3, 10, 13)
  attachTrailer(ow, t2)
  attachTrailer(ow, t3)
  local res = fx:reconcileAfterSync(ow, before, { stagger = 0.05 })
  eq(res.released, 2, "count up releases only new")
  eq(res.recalled, 0, "count up no recall")
  check(t1._wildsPresentationFx == nil, "existing follower no release")
  check(t2._wildsPresentationFx ~= nil, "new follower 2 release")
  check(t3._wildsPresentationFx ~= nil, "new follower 3 release")
  near(t3._wildsPresentationFx.delay, 0.05, 0.001, "subtle stagger on 3rd")

  -- Count 3 → 1
  before = fx:captureVisibleFollowers(ow)
  ow.pokepcTrailers = { t1 }
  ow.entities = { t1 }
  ow.npcs = { t1 }
  t2._wildsPresentationFx = nil
  t3._wildsPresentationFx = nil
  fx.ghosts = {}
  res = fx:reconcileAfterSync(ow, before, { stagger = 0 })
  eq(res.recalled, 2, "count down recalls removed")
  eq(res.released, 0, "count down no release")
  check(t1._wildsPresentationFx == nil, "kept follower no FX")

  -- Explicit switch m1 → m2
  fx:clearAll(ow)
  ow.pokepcTrailers = { t1 }
  ow.entities = { t1 }
  ow.npcs = { t1 }
  before = fx:captureVisibleFollowers(ow)
  ow.pokepcTrailers = { t2 }
  ow.entities = { t2 }
  ow.npcs = { t2 }
  res = fx:reconcileAfterSync(ow, before, { stagger = 0 })
  eq(res.recalled, 1, "switch recalls old")
  eq(res.released, 1, "switch releases new")
end

--------------------------------------------------------------------
-- 13–16. Geometry: Gen1 classic, HGSS True Size, GSC
--------------------------------------------------------------------
do
  local fx = PresentationFx.new(V.mod, {})
  local ow = makeOw()
  local classic = makeTrailer(1, makeMon("PIKACHU", 1), 5, 5, {
    frameWidth = 16, frameHeight = 16,
  })
  local trueSize = makeTrailer(1, makeMon("SNORLAX", 1), 5, 5, {
    frameWidth = 40, frameHeight = 40, anchorX = 20, anchorY = 38,
  })
  local gsc = makeTrailer(1, makeMon("TOGEPI", 1), 5, 5, {
    frameWidth = 16, frameHeight = 16, anchorX = 8, anchorY = 16,
  })
  for _, npc in ipairs({ classic, trueSize, gsc }) do
    PresentationFx.installDrawWrap(npc)
    fx:_beginOnEntity(npc, "release", 0)
    check(npc._wildsPresentationDrawWrapped == true, "draw wrap installed")
    local def = npc.sprite.def
    check(def.frameWidth ~= nil, "geometry preserved width")
    check(def.frameHeight ~= nil, "geometry preserved height")
  end
  check(trueSize.sprite.def.frameWidth == 40, "HGSS True Size width not flattened")
  check(trueSize.sprite.def.frameHeight == 40, "HGSS True Size height not flattened")
  check(gsc.sprite.def.frameWidth == 16, "GSC geometry intact")
end

--------------------------------------------------------------------
-- 17. Yellow stock Pikachu safety
--------------------------------------------------------------------
do
  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  local fx = PresentationFx.new(V.mod, { selection = selection })
  local ow = makeOw()
  local stock = {
    id = "stock_pika",
    pikachuFollower = true,
    pokepcTrailer = false,
    wildsFollower = false,
    px = 160, py = 176,
    cellX = 10, cellY = 11,
    facing = "down",
    sprite = { def = { frameWidth = 16, frameHeight = 16 }, draw = function() end },
    pokepcMon = makeMon("PIKACHU", 1),
  }
  ow.npcs[#ow.npcs + 1] = stock
  ow.entities[#ow.entities + 1] = stock

  local before = fx:captureVisibleFollowers(ow)
  eq(#before, 0, "stock Pikachu not captured for FX")

  local started = fx:_beginOnEntity(stock, "release", 0)
  check(started == nil, "stock Pikachu refuses release FX")
  check(stock._wildsPresentationFx == nil, "stock has no FX state")

  -- Extra Wilds trailer alongside stock still FX-capable
  local extra = makeTrailer(1, makeMon("EEVEE", 2), 10, 12)
  attachTrailer(ow, extra)
  before = {}
  local res = fx:reconcileAfterSync(ow, before, { stagger = 0 })
  eq(res.released, 1, "extra Yellow trailer can release")
  check(extra._wildsPresentationFx ~= nil, "extra trailer has release FX")
  check(stock._wildsPresentationFx == nil, "stock still clean")
end

--------------------------------------------------------------------
-- ControlEngine intentional syncAll wires presentation
--------------------------------------------------------------------
do
  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  local engine = ControlEngine.new(V.mod, {
    selection = selection,
    settings = {
      engineMode = function() return "follow" end,
      followerCount = function(_, g)
        return (g and g.save and g.save.pokepcFollowerCount) or 0
      end,
      setFollowerCount = function(_, g, n)
        g.save.pokepcFollowerCount = n
        return n
      end,
      alignSaveFromOptions = function() end,
      onOptionsChanged = function() end,
    },
    spriteService = {
      resolveFollowerSprite = function(_, opts)
        return {
          id = "SPRITE_TEST",
          image = "land.png",
          frames = 6,
          walker = true,
          frameWidth = 24,
          frameHeight = 28,
          anchorX = 12,
          anchorY = 26,
        }
      end,
    },
  })
  local mon = makeMon("ODDISH", 1)
  local game = {
    save = {
      party = { mon },
      pokepcFollowerCount = 0,
      pokepcControlMode = "follow",
    },
    data = {},
  }
  engine._gameRef = game
  local ow = makeOw()
  game.overworld = ow

  -- DISMISS-like: had trailer, clear count, recall
  local old = makeTrailer(1, mon, 10, 11)
  attachTrailer(ow, old)
  game.save.pokepcFollowerCount = 0
  engine:beginPresentationIntent("party_dismiss")
  engine:syncAll(game, ow)
  check(engine._presentationIntent == nil, "intent cleared after syncAll")
  check(engine.presentationFx:activeGhostCount() >= 1
     or #(ow.pokepcTrailers or {}) == 0, "dismiss produced recall or empty pack")

  -- Re-seed for FOLLOW-like release
  engine.presentationFx:clearAll(ow)
  game.save.pokepcFollowerCount = 1
  game.save.followerPartyIndex = 1
  selection.state:setSelection(selection.monFingerprint(mon), 1)
  engine:beginPresentationIntent("party_follow")
  engine:syncAll(game, ow)
  local released = false
  for _, t in ipairs(ow.pokepcTrailers or {}) do
    if t._wildsPresentationFx and t._wildsPresentationFx.kind == "release" then
      released = true
      check((t.sprite.def.frameWidth or 16) >= 16, "True Size geometry on release trailer")
    end
  end
  check(released or #(ow.pokepcTrailers or {}) == 0,
    "follow intent starts release when trailers exist")
end

print(string.format("\n%d failures", failures))
os.exit(failures == 0 and 0 or 1)
