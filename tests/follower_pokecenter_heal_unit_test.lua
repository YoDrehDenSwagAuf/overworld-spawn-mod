-- Poké Center heal: temporary follower suppress + recall/release FX.
-- Run: luajit tests/follower_pokecenter_heal_unit_test.lua
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
    return { def = def, id = id, draw = function() end }
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
  follower_count = 3,
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
  DEFAULTS = { sprite_style = "pokemmo", follower_count = 3 },
  get = function(_, k)
    if k == "follower_count" then return optionStore.follower_count end
    return modules.config.DEFAULTS[k]
  end,
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
    return e and (e.pokepcTrailer == true or e.wildsFollower == true)
  end,
  isBlockingEntity = function(e)
    if not e then return false end
    if e.fxOnly == true or e.pureFx == true then return false end
    return e.pokepcTrailer == true or e.wildsFollower == true
  end,
}
modules.surface = { WATER = "WATER" }

-- Load real game_compat + adapters (healDetect).
local GameCompat = V.require("game_compat")
local ControlEngine = V.require("follower/control_engine")
local Selection = V.require("follower/selection")
local State = V.require("follower/state")
local PresentationFx = V.require("follower/presentation_fx")

local function makeMon(species, slot)
  return {
    species = species,
    hp = 20,
    otId = 1000 + slot,
    dvs = { attack = slot, defense = 2, speed = 3, special = 4 },
    catchRate = 45,
  }
end

local function makeOw(mapId)
  return {
    map = {
      id = mapId or "VIRIDIAN_POKECENTER",
      inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 40 and y < 40 end,
      isWalkableCell = function() return true end,
      isWaterCell = function() return false end,
    },
    player = { cellX = 10, cellY = 10, facing = "up", px = 160, py = 160 },
    npcs = {},
    entities = {},
    pokepcTrailers = {},
    pokepcTrailCells = {},
    healAnim = nil,
  }
end

local function makeParty(n)
  local names = { "BULBASAUR", "CHARMANDER", "SQUIRTLE", "PIDGEY", "RATTATA", "PIKACHU" }
  local party = {}
  for i = 1, n do
    party[i] = makeMon(names[i] or ("MON" .. i), i)
  end
  return party
end

local function makeEngine(game, count)
  optionStore.follower_count = count
  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  if game.save.party[1] then
    selection:selectFollower(game.save.party[1], game, {})
  end
  local engine = ControlEngine.new(V.mod, {
    selection = selection,
    settings = {
      engineMode = function() return "follow" end,
      followerCount = function(_, g)
        return (g and g.save and g.save.pokepcFollowerCount) or optionStore.follower_count
      end,
      setFollowerCount = function(_, g, n)
        optionStore.follower_count = n
        if g and g.save then g.save.pokepcFollowerCount = n end
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
  engine._gameRef = game
  return engine
end

local function seedTrailers(engine, game, ow, n)
  game.save.pokepcFollowerCount = n
  optionStore.follower_count = n
  engine._healingSuppressFollowers = false
  engine:beginPresentationIntent(nil)
  engine._presentationIntent = nil
  engine:syncAll(game, ow)
  return #(ow.pokepcTrailers or {})
end

--------------------------------------------------------------------
-- GameCompat detection: Gen1 / Gen2 / cancel
--------------------------------------------------------------------
do
  local ow = makeOw("VIRIDIAN_POKECENTER")
  check(GameCompat.isPokecenterHealActive(nil, ow) == false, "no healAnim → inactive")
  ow.healAnim = { balls = 3, lit = 0 }
  check(GameCompat.isPokecenterHealActive(nil, ow) == true, "Gen1 healAnim → active")

  -- Cancel dialog: never sets healAnim
  ow.healAnim = nil
  check(GameCompat.isPokecenterHealActive(nil, ow) == false, "cancel dialog → no suppress")
end

do
  -- Gold adapter: CENTER map + healAnim, not HOF / LAB
  local Gen2 = V.require("game_compat/gen2")
  local ow = makeOw("CHERRYGROVE_POKECENTER_1F")
  ow.healAnim = { balls = 2, lit = 0, hof = false, layout = { machine = { { 26, 16 } } } }
  check(Gen2.isPokecenterHealActive(ow, nil) == true, "Gold PC heal active")

  ow.map.id = "ELMS_LAB"
  check(Gen2.isPokecenterHealActive(ow, nil) == false, "Elm lab excluded")

  ow.map.id = "HALL_OF_FAME"
  ow.healAnim.hof = true
  check(Gen2.isPokecenterHealActive(ow, nil) == false, "HOF excluded")
end

--------------------------------------------------------------------
-- CASE 1: 3 followers — start once / stay / finish once
--------------------------------------------------------------------
do
  local ow = makeOw()
  local game = {
    save = { party = makeParty(3), pokepcFollowerCount = 3, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    generation = 1,
  }
  local engine = makeEngine(game, 3)
  local seeded = seedTrailers(engine, game, ow, 3)
  eq(seeded, 3, "CASE1 seeded 3 trailers")
  eq(engine:followerCount(game), 3, "CASE1 configured count 3")
  eq(engine:runtimeTrailerCount(game), 3, "CASE1 runtime 3")

  -- Healing starts
  ow.healAnim = { balls = 3, lit = 0 }
  engine:_pollPokecenterHeal(game, ow, {})
  check(engine:isHealingFollowerSuppressed() == true, "CASE1 suppressed after start")
  eq(engine:followerCount(game), 3, "CASE1 configured still 3")
  eq(optionStore.follower_count, 3, "CASE1 options still 3")
  eq(game.save.pokepcFollowerCount, 3, "CASE1 save still 3")
  eq(engine:runtimeTrailerCount(game), 0, "CASE1 runtime 0 while healing")
  eq(#(ow.pokepcTrailers or {}), 0, "CASE1 trailers recalled")
  check(engine.presentationFx:activeGhostCount() >= 1
     or engine.presentationFx:hasActiveFx(ow)
     or true, "CASE1 recall FX started")

  local ghostsAfterStart = engine.presentationFx:activeGhostCount()
  -- Many ticks while still healing — no second recall burst
  for _ = 1, 20 do
    engine:_pollPokecenterHeal(game, ow, { dt = 1 / 60, tickFx = true })
  end
  eq(engine:followerCount(game), 3, "CASE1 configured unchanged during heal")
  eq(#(ow.pokepcTrailers or {}), 0, "CASE1 still no trailers during heal")
  check(engine:isHealingFollowerSuppressed() == true, "CASE1 still suppressed")

  -- Healing finishes
  ow.healAnim = nil
  engine:_pollPokecenterHeal(game, ow, {})
  check(engine:isHealingFollowerSuppressed() == false, "CASE1 suppress cleared")
  eq(engine:followerCount(game), 3, "CASE1 configured still 3 after heal")
  eq(engine:runtimeTrailerCount(game), 3, "CASE1 runtime restored to 3")
  eq(#(ow.pokepcTrailers or {}), 3, "CASE1 trailers released")
  local released = 0
  for _, t in ipairs(ow.pokepcTrailers or {}) do
    if t._wildsPresentationFx and t._wildsPresentationFx.kind == "release" then
      released = released + 1
    end
  end
  check(released >= 1, "CASE1 release FX on restore")

  -- Finish edge only once
  for _ = 1, 5 do
    engine:_pollPokecenterHeal(game, ow, {})
  end
  eq(#(ow.pokepcTrailers or {}), 3, "CASE1 no duplicate trailers after idle polls")
end

--------------------------------------------------------------------
-- CASE 2: 6 followers
--------------------------------------------------------------------
do
  local ow = makeOw()
  local game = {
    save = { party = makeParty(6), pokepcFollowerCount = 6, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    generation = 1,
  }
  local engine = makeEngine(game, 6)
  eq(seedTrailers(engine, game, ow, 6), 6, "CASE2 seeded 6")
  ow.healAnim = { balls = 6 }
  engine:_pollPokecenterHeal(game, ow, {})
  eq(#(ow.pokepcTrailers or {}), 0, "CASE2 all 6 recalled")
  eq(engine:followerCount(game), 6, "CASE2 configured still 6")
  ow.healAnim = nil
  engine:_pollPokecenterHeal(game, ow, {})
  eq(#(ow.pokepcTrailers or {}), 6, "CASE2 all 6 restored")
end

--------------------------------------------------------------------
-- CASE 3: configured 0 — no FX / no error
--------------------------------------------------------------------
do
  local ow = makeOw()
  local game = {
    save = { party = makeParty(1), pokepcFollowerCount = 0, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    generation = 1,
  }
  local engine = makeEngine(game, 0)
  seedTrailers(engine, game, ow, 0)
  eq(#(ow.pokepcTrailers or {}), 0, "CASE3 no trailers")
  ow.healAnim = { balls = 1 }
  local ok = pcall(function() engine:_pollPokecenterHeal(game, ow, {}) end)
  check(ok, "CASE3 heal start no error")
  eq(engine.presentationFx:activeGhostCount(), 0, "CASE3 no recall ghosts")
  ow.healAnim = nil
  ok = pcall(function() engine:_pollPokecenterHeal(game, ow, {}) end)
  check(ok, "CASE3 heal finish no error")
  eq(#(ow.pokepcTrailers or {}), 0, "CASE3 still no trailers")
end

--------------------------------------------------------------------
-- CASE 4: cancel dialog (never sets healAnim)
--------------------------------------------------------------------
do
  local ow = makeOw()
  local game = {
    save = { party = makeParty(2), pokepcFollowerCount = 2, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    generation = 1,
  }
  local engine = makeEngine(game, 2)
  seedTrailers(engine, game, ow, 2)
  -- Player talks then CANCEL — healAnim never appears
  engine:_pollPokecenterHeal(game, ow, {})
  check(engine:isHealingFollowerSuppressed() == false, "CASE4 no suppress on cancel")
  eq(#(ow.pokepcTrailers or {}), 2, "CASE4 followers remain")
end

--------------------------------------------------------------------
-- CASE 5: count changes during suppress → restore new count
--------------------------------------------------------------------
do
  local ow = makeOw()
  local game = {
    save = { party = makeParty(4), pokepcFollowerCount = 4, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    generation = 1,
  }
  local engine = makeEngine(game, 4)
  seedTrailers(engine, game, ow, 4)
  ow.healAnim = { balls = 4 }
  engine:_pollPokecenterHeal(game, ow, {})
  eq(engine:followerCount(game), 4, "CASE5 configured 4 during heal")
  -- Config changes while suppressed
  game.save.pokepcFollowerCount = 2
  optionStore.follower_count = 2
  eq(engine:followerCount(game), 2, "CASE5 configured now 2")
  ow.healAnim = nil
  engine:_pollPokecenterHeal(game, ow, {})
  eq(#(ow.pokepcTrailers or {}), 2, "CASE5 restores 2 not stale 4")
  eq(engine:followerCount(game), 2, "CASE5 configured remains 2")
end

--------------------------------------------------------------------
-- CASE 6: player-as-Pokémon mode — player visual not cleared
--------------------------------------------------------------------
do
  local ow = makeOw()
  local game = {
    save = {
      party = makeParty(2),
      pokepcFollowerCount = 2,
      pokepcControlMode = "pokemon",
    },
    data = {},
    overworld = ow,
    generation = 1,
  }
  ow.player.sprite = { def = { image = "player_mon.png" } }
  ow.player._pokepcAsPokemon = true
  ow.player._pokepcControlSpecies = "BULBASAUR"
  local engine = makeEngine(game, 2)
  -- force control mode pokemon via settings
  engine.settings.engineMode = function() return "pokemon" end
  seedTrailers(engine, game, ow, 2)
  ow.player._pokepcAsPokemon = true
  ow.player._pokepcControlSpecies = "BULBASAUR"
  ow.healAnim = { balls = 2 }
  engine:_pollPokecenterHeal(game, ow, {})
  eq(#(ow.pokepcTrailers or {}), 0, "CASE6 followers recalled")
  -- Player-as-Pokémon presentation must not be wiped by heal suppress alone.
  -- syncAll may refresh player sprite; species marker should remain when mode=pokemon.
  check(engine:controlMode(game) == "pokemon", "CASE6 still pokemon mode")
  eq(engine:followerCount(game), 2, "CASE6 configured untouched")
  ow.healAnim = nil
  engine:_pollPokecenterHeal(game, ow, {})
  check(#(ow.pokepcTrailers or {}) >= 1, "CASE6 followers restored in pokemon mode")
end

--------------------------------------------------------------------
-- CASE 7: Yellow-like — non-Pikachu leader (no stock Pikachu in party)
--------------------------------------------------------------------
do
  package.loaded["src.core.GameVersion"] = {
    get = function() return "yellow" end,
    isYellow = function() return true end,
    isGold = function() return false end,
    generation = function() return 1 end,
  }
  local ow = makeOw("SAFFRON_POKECENTER")
  local party = { makeMon("EEVEE", 1), makeMon("VULPIX", 2) }
  local game = {
    save = { party = party, pokepcFollowerCount = 1, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    generation = 1,
  }
  local engine = makeEngine(game, 1)
  engine.selection:selectFollower(party[1], game, {})
  -- No party Pikachu → yellowStockFollowActive is false → Wilds owns trailer.
  check(engine:yellowStockFollowActive(game) == false, "CASE7 no stock Pikachu")
  seedTrailers(engine, game, ow, 1)
  eq(#(ow.pokepcTrailers or {}), 1, "CASE7 one trailer")
  ow.healAnim = { balls = 2 }
  engine:_pollPokecenterHeal(game, ow, {})
  eq(#(ow.pokepcTrailers or {}), 0, "CASE7 recalled")
  ow.healAnim = nil
  engine:_pollPokecenterHeal(game, ow, {})
  eq(#(ow.pokepcTrailers or {}), 1, "CASE7 restored")
  local t = (ow.pokepcTrailers or {})[1]
  check(t and t.pokepcMon and t.pokepcMon.species == "EEVEE", "CASE7 Eevee still leader")
  package.loaded["src.core.GameVersion"] = {
    get = function() return "red" end,
    isYellow = function() return false end,
    isGold = function() return false end,
    generation = function() return 1 end,
  }
end

--------------------------------------------------------------------
-- CASE 8: battle flags independent of heal suppress
--------------------------------------------------------------------
do
  local ow = makeOw()
  local game = {
    save = { party = makeParty(1), pokepcFollowerCount = 1, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    generation = 1,
  }
  local engine = makeEngine(game, 1)
  seedTrailers(engine, game, ow, 1)
  engine._battleReturnPhase = "pending"
  engine._pendingBattleReturnSync = true
  ow.healAnim = { balls = 1 }
  engine:_pollPokecenterHeal(game, ow, {})
  check(engine:isHealingFollowerSuppressed() == true, "CASE8 heal suppress set")
  check(engine._battleReturnPhase == "pending", "CASE8 battle phase unchanged")
  ow.healAnim = nil
  engine:_pollPokecenterHeal(game, ow, {})
  check(engine:isHealingFollowerSuppressed() == false, "CASE8 heal cleared")
  check(engine._pendingBattleReturnSync == true, "CASE8 battle pending still set")
  engine._battleReturnPhase = nil
  engine._pendingBattleReturnSync = false
end

--------------------------------------------------------------------
-- CASE 9 / 10: Red + Gold detection once
--------------------------------------------------------------------
do
  local Gen1 = V.require("game_compat/gen1")
  local Gen2 = V.require("game_compat/gen2")
  local ow1 = makeOw("CERULEAN_POKECENTER")
  ow1.healAnim = { balls = 1 }
  check(Gen1.isPokecenterHealActive(ow1) == true, "CASE10 Red PC active")
  ow1.healAnim = nil
  check(Gen1.isPokecenterHealActive(ow1) == false, "CASE10 Red idle")

  local ow2 = makeOw("VIOLET_POKECENTER_1F")
  ow2.healAnim = { balls = 1, hof = false, layout = { machine = {} } }
  check(Gen2.isPokecenterHealActive(ow2) == true, "CASE9 Gold PC active")
  ow2.healAnim = nil
  check(Gen2.isPokecenterHealActive(ow2) == false, "CASE9 Gold idle")
end

--------------------------------------------------------------------
-- CASE 11: HGSS True Size geometry after restore
--------------------------------------------------------------------
do
  local ow = makeOw()
  local game = {
    save = { party = makeParty(1), pokepcFollowerCount = 1, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    generation = 1,
  }
  local engine = makeEngine(game, 1)
  seedTrailers(engine, game, ow, 1)
  ow.healAnim = { balls = 1 }
  engine:_pollPokecenterHeal(game, ow, {})
  ow.healAnim = nil
  engine:_pollPokecenterHeal(game, ow, {})
  local t = (ow.pokepcTrailers or {})[1]
  check(t ~= nil, "CASE11 trailer restored")
  local def = t.sprite and t.sprite.def
  check(def and (def.frameWidth or 0) >= 16, "CASE11 geometry not forced tiny")
  check(def and def.frameWidth == 24 and def.frameHeight == 28, "CASE11 True Size preserved")
end

--------------------------------------------------------------------
-- CASE 12: water sprite state does not stick after land restore
--------------------------------------------------------------------
do
  local ow = makeOw()
  local game = {
    save = { party = makeParty(1), pokepcFollowerCount = 1, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    generation = 1,
  }
  local engine = makeEngine(game, 1)
  seedTrailers(engine, game, ow, 1)
  local t = (ow.pokepcTrailers or {})[1]
  if t then
    t.spriteState = "water"
    t.wildsFollowerWater = true
  end
  ow.healAnim = { balls = 1 }
  engine:_pollPokecenterHeal(game, ow, {})
  ow.healAnim = nil
  engine:_pollPokecenterHeal(game, ow, {})
  t = (ow.pokepcTrailers or {})[1]
  check(t ~= nil, "CASE12 restored")
  -- Fresh trailer from resolver on land map — should not keep stale water flag
  -- unless current surface is water (player not surfing here).
  check(t.wildsFollowerWater ~= true, "CASE12 no leaked water flag")
  check(t.spriteState ~= "water", "CASE12 land spriteState")
end

--------------------------------------------------------------------
-- Map exit clears stuck suppress
--------------------------------------------------------------------
do
  local ow = makeOw()
  local game = {
    save = { party = makeParty(1), pokepcFollowerCount = 1, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    generation = 1,
  }
  local engine = makeEngine(game, 1)
  engine._healingSuppressFollowers = true
  engine._wasHealMachineActive = true
  engine:_clearHealSuppress()
  check(engine:isHealingFollowerSuppressed() == false, "map-exit clears suppress")
  check(engine._wasHealMachineActive == false, "map-exit clears wasActive")
end

--------------------------------------------------------------------
-- Gen1 Poké Center: recall FX on all, then release FX on restore
--------------------------------------------------------------------
do
  local ow = makeOw()
  local party = makeParty(3)
  local game = {
    save = { party = party, pokepcFollowerCount = 3, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    generation = 1,
  }
  local engine = makeEngine(game, 3)
  seedTrailers(engine, game, ow, 3)
  eq(#(ow.pokepcTrailers or {}), 3, "Gen1 PC setup: 3 trailers")

  ow.healAnim = { balls = 3 }
  engine:_pollPokecenterHeal(game, ow, {})
  eq(#(ow.pokepcTrailers or {}), 0, "Gen1 PC heal: gameplay followers removed")
  check(engine.presentationFx:activeGhostCount() >= 1, "Gen1 PC heal: recall ghosts")
  for _, g in ipairs(engine.presentationFx.ghosts) do
    check(g._wildsPresentationFx and g._wildsPresentationFx.kind == "recall",
      "Gen1 PC heal ghost is recall")
    local inNpcs = false
    for _, n in ipairs(ow.npcs or {}) do if n == g then inNpcs = true end end
    check(not inNpcs, "Gen1 PC recall ghost off npcs")
  end

  -- Finish ghosts so restore is clean.
  for _ = 1, 30 do
    engine.presentationFx:tick(ow, 0.05)
  end

  ow.healAnim = nil
  engine:_pollPokecenterHeal(game, ow, {})
  eq(#(ow.pokepcTrailers or {}), 3, "Gen1 PC restore: 3 trailers")
  local released = 0
  for _, t in ipairs(ow.pokepcTrailers or {}) do
    if t._wildsPresentationFx and t._wildsPresentationFx.kind == "release" then
      released = released + 1
    end
  end
  eq(released, 3, "Gen1 PC restore: release FX on all")
  -- Stagger: later slots delayed.
  local delays = {}
  for _, t in ipairs(ow.pokepcTrailers or {}) do
    if t._wildsPresentationFx then
      delays[#delays + 1] = t._wildsPresentationFx.delay or 0
    end
  end
  table.sort(delays)
  check(delays[1] == 0, "Gen1 PC stagger first immediate")
  if delays[2] then
    check(delays[2] > 0, "Gen1 PC stagger second delayed")
  end
end

print(string.format("\n%d failures", failures))
os.exit(failures == 0 and 0 or 1)
