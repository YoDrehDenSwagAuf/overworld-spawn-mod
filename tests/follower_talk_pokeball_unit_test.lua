-- Follower talk OKAY/POKEBALL + manual recall selection.
-- Run: luajit tests/follower_talk_pokeball_unit_test.lua
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

local lastChoice = nil
package.loaded["src.render.TextBox"] = {
  new = function(game, text, onDone, opts)
    local box = {
      game = game,
      text = text,
      onDone = onDone,
      choice = opts and opts.choice,
      choiceLabels = opts and opts.choiceLabels,
    }
    lastChoice = box
    if game and game.stack and game.stack.push then
      game.stack:push(box)
    end
    return box
  end,
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
  spriteStyle = function() return "pokemmo" end,
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
  isBlockingEntity = function() return false end,
}
modules.surface = { WATER = "WATER" }

local ControlEngine = V.require("follower/control_engine")
local Selection = V.require("follower/selection")
local State = V.require("follower/state")
local Interaction = V.require("follower/interaction")
local AmbientCries = V.require("ambient_cries")

local function makeMon(species, slot)
  return {
    species = species,
    hp = 20,
    otId = 1000 + slot,
    dvs = { attack = slot, defense = 2, speed = 3, special = 4 },
    catchRate = 45,
    stopFollowing = false,
  }
end

local function makeOw()
  return {
    map = {
      id = "ROUTE1",
      inBounds = function() return true end,
      isWalkableCell = function() return true end,
      isWaterCell = function() return false end,
    },
    player = { cellX = 10, cellY = 10, facing = "down", px = 160, py = 160 },
    npcs = {}, entities = {}, pokepcTrailers = {}, pokepcTrailCells = {},
  }
end

local function makeParty(n)
  local names = { "PIKACHU", "CHARIZARD", "SQUIRTLE", "BULBASAUR", "EEVEE", "MEOWTH" }
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
      resolveFollowerSprite = function()
        return {
          id = "SPRITE_TEST", image = "land.png", frames = 6, walker = true,
          frameWidth = 16, frameHeight = 16,
        }
      end,
    },
  })
  engine._gameRef = game
  return engine, selection
end

local function speciesInTrail(ow)
  local out = {}
  for _, t in ipairs(ow.pokepcTrailers or {}) do
    out[#out + 1] = t.pokepcMon and t.pokepcMon.species
  end
  return out
end

local function hasSpecies(list, species)
  for _, s in ipairs(list) do
    if s == species then return true end
  end
  return false
end

--------------------------------------------------------------------
-- Dialog choice wiring
--------------------------------------------------------------------
do
  local ow = makeOw()
  local party = makeParty(1)
  local game = {
    save = { party = party, pokepcFollowerCount = 1, pokepcControlMode = "follow" },
    data = {},
    overworld = ow,
    stack = {
      items = {},
      push = function(self, box) self.items[#self.items + 1] = box end,
      pop = function(self) self.items[#self.items] = nil end,
    },
    generation = 1,
  }
  local engine = makeEngine(game, 1)
  engine:syncAll(game, ow)
  local interaction = Interaction.new(V.mod, engine.selection, engine)
  local npc = (ow.pokepcTrailers or {})[1]
  lastChoice = nil
  interaction:showFollowMessage(game, ow, npc, party[1])
  check(lastChoice ~= nil, "talk opens choice textbox")
  check(lastChoice.choice ~= nil, "choice callback present")
  eq(lastChoice.choiceLabels[1], "OKAY", "OKAY label")
  eq(lastChoice.choiceLabels[2], "POKEBALL", "POKEBALL label")
  check(tostring(lastChoice.text or ""):find("following", 1, true) ~= nil,
    "follow message precedes choice")
end

--------------------------------------------------------------------
-- CASE 1: OKAY keeps follower
--------------------------------------------------------------------
do
  local ow = makeOw()
  local party = makeParty(1)
  local game = {
    save = { party = party, pokepcFollowerCount = 1, pokepcControlMode = "follow" },
    data = {}, overworld = ow,
    stack = { items = {}, push = function(s, b) s.items[#s.items + 1] = b end },
    generation = 1,
  }
  local engine = makeEngine(game, 1)
  engine:syncAll(game, ow)
  eq(#(ow.pokepcTrailers or {}), 1, "CASE1 one trailer")
  local interaction = Interaction.new(V.mod, engine.selection, engine)
  interaction:showFollowMessage(game, ow, ow.pokepcTrailers[1], party[1])
  lastChoice.choice(true) -- OKAY
  eq(party[1].stopFollowing, false, "CASE1 not stopFollowing")
  eq(engine:followerCount(game), 1, "CASE1 count unchanged")
  eq(#(ow.pokepcTrailers or {}), 1, "CASE1 trailer remains")
end

--------------------------------------------------------------------
-- CASE 2: POKEBALL recalls sole follower
--------------------------------------------------------------------
do
  local ow = makeOw()
  local party = makeParty(1)
  local game = {
    save = { party = party, pokepcFollowerCount = 1, pokepcControlMode = "follow" },
    data = {}, overworld = ow,
    stack = { items = {}, push = function(s, b) s.items[#s.items + 1] = b end },
    generation = 1,
  }
  local engine = makeEngine(game, 1)
  engine:syncAll(game, ow)
  local interaction = Interaction.new(V.mod, engine.selection, engine)
  interaction:showFollowMessage(game, ow, ow.pokepcTrailers[1], party[1])
  lastChoice.choice(false) -- POKEBALL
  eq(party[1].stopFollowing, true, "CASE2 stopFollowing set")
  eq(engine:followerCount(game), 0, "CASE2 count decremented")
  eq(#(ow.pokepcTrailers or {}), 0, "CASE2 trailer gone")
  -- Next sync must not respawn
  engine._presentationIntent = nil
  engine:syncAll(game, ow)
  eq(#(ow.pokepcTrailers or {}), 0, "CASE2 no respawn on sync")
end

--------------------------------------------------------------------
-- CASE 3: 3 followers — recall middle only
--------------------------------------------------------------------
do
  local ow = makeOw()
  local party = makeParty(3)
  local game = {
    save = { party = party, pokepcFollowerCount = 3, pokepcControlMode = "follow" },
    data = {}, overworld = ow, generation = 1,
  }
  local engine = makeEngine(game, 3)
  engine:syncAll(game, ow)
  eq(#(ow.pokepcTrailers or {}), 3, "CASE3 three trailers")
  local mid = party[2] -- CHARIZARD
  engine:manualRecallFollower(game, ow, mid, { source = "talk_pokeball" })
  eq(mid.stopFollowing, true, "CASE3 middle excluded")
  eq(party[1].stopFollowing, false, "CASE3 first kept")
  eq(party[3].stopFollowing, false, "CASE3 last kept")
  eq(engine:followerCount(game), 2, "CASE3 count 2")
  local trail = speciesInTrail(ow)
  eq(#trail, 2, "CASE3 two trailers")
  check(hasSpecies(trail, "PIKACHU"), "CASE3 Pikachu remains")
  check(hasSpecies(trail, "SQUIRTLE"), "CASE3 Squirtle remains")
  check(not hasSpecies(trail, "CHARIZARD"), "CASE3 Charizard gone")
end

--------------------------------------------------------------------
-- CASE 4: 6 followers — recall first / last
--------------------------------------------------------------------
do
  local ow = makeOw()
  local party = makeParty(6)
  local game = {
    save = { party = party, pokepcFollowerCount = 6, pokepcControlMode = "follow" },
    data = {}, overworld = ow, generation = 1,
  }
  local engine = makeEngine(game, 6)
  engine:syncAll(game, ow)
  engine:manualRecallFollower(game, ow, party[1], {})
  eq(engine:followerCount(game), 5, "CASE4a count 5 after first recall")
  check(not hasSpecies(speciesInTrail(ow), "PIKACHU"), "CASE4a first gone")
  eq(#(ow.pokepcTrailers or {}), 5, "CASE4a five remain")

  local last = party[6]
  engine:manualRecallFollower(game, ow, last, {})
  eq(engine:followerCount(game), 4, "CASE4b count 4")
  check(not hasSpecies(speciesInTrail(ow), "MEOWTH"), "CASE4b last gone")
  eq(#(ow.pokepcTrailers or {}), 4, "CASE4b four remain")
end

--------------------------------------------------------------------
-- CASE 5: manual recall survives map-style sync
--------------------------------------------------------------------
do
  local ow = makeOw()
  local party = makeParty(3)
  local game = {
    save = { party = party, pokepcFollowerCount = 3, pokepcControlMode = "follow" },
    data = {}, overworld = ow, generation = 1,
  }
  local engine = makeEngine(game, 3)
  engine:syncAll(game, ow)
  engine:manualRecallFollower(game, ow, party[2], {})
  -- Simulate map re-seed without presentation intent
  engine._presentationIntent = nil
  engine._pendingSpawnAtPlayer = true
  engine:syncAll(game, ow)
  check(not hasSpecies(speciesInTrail(ow), "CHARIZARD"),
    "CASE5 Charizard stays excluded after map sync")
  eq(party[2].stopFollowing, true, "CASE5 stopFollowing persists")
end

--------------------------------------------------------------------
-- CASE 6: battle-style sync does not revive recalled mon
--------------------------------------------------------------------
do
  local ow = makeOw()
  local party = makeParty(2)
  local game = {
    save = { party = party, pokepcFollowerCount = 2, pokepcControlMode = "follow" },
    data = {}, overworld = ow, generation = 1,
  }
  local engine = makeEngine(game, 2)
  engine:syncAll(game, ow)
  engine:manualRecallFollower(game, ow, party[2], {})
  engine._presentationIntent = nil
  engine:syncTrailers(game, ow, { mapEnter = true, spawnAtPlayer = true })
  check(not hasSpecies(speciesInTrail(ow), "CHARIZARD"),
    "CASE6 no revive after battle-like sync")
end

--------------------------------------------------------------------
-- CASE 7: Poké Center restore returns only still-selected followers
--------------------------------------------------------------------
do
  local ow = makeOw("VIRIDIAN_POKECENTER")
  ow.map.id = "VIRIDIAN_POKECENTER"
  local party = makeParty(3)
  local game = {
    save = { party = party, pokepcFollowerCount = 3, pokepcControlMode = "follow" },
    data = {}, overworld = ow, generation = 1,
  }
  local engine = makeEngine(game, 3)
  engine:syncAll(game, ow)
  engine:manualRecallFollower(game, ow, party[2], {}) -- Charizard out
  eq(engine:followerCount(game), 2, "CASE7 configured 2 after manual")
  ow.healAnim = { balls = 3 }
  engine:_pollPokecenterHeal(game, ow, {})
  eq(#(ow.pokepcTrailers or {}), 0, "CASE7 all suppressed during heal")
  eq(engine:followerCount(game), 2, "CASE7 configured unchanged by heal")
  ow.healAnim = nil
  engine:_pollPokecenterHeal(game, ow, {})
  local trail = speciesInTrail(ow)
  eq(#trail, 2, "CASE7 two return")
  check(not hasSpecies(trail, "CHARIZARD"), "CASE7 Charizard still excluded")
  check(hasSpecies(trail, "PIKACHU"), "CASE7 Pikachu returned")
  check(hasSpecies(trail, "SQUIRTLE"), "CASE7 Squirtle returned")
end

--------------------------------------------------------------------
-- CASE 8: OKAY no mutation (already covered; assert party fields)
--------------------------------------------------------------------
do
  local ow = makeOw()
  local party = makeParty(2)
  local hp0, ot0 = party[1].hp, party[1].otId
  local game = {
    save = { party = party, pokepcFollowerCount = 2, pokepcControlMode = "follow" },
    data = {}, overworld = ow,
    stack = { items = {}, push = function(s, b) s.items[#s.items + 1] = b end },
    generation = 1,
  }
  local engine = makeEngine(game, 2)
  engine:syncAll(game, ow)
  local interaction = Interaction.new(V.mod, engine.selection, engine)
  interaction:showFollowMessage(game, ow, ow.pokepcTrailers[1], party[1])
  lastChoice.choice(true)
  eq(party[1].hp, hp0, "CASE8 HP untouched")
  eq(party[1].otId, ot0, "CASE8 OT untouched")
  eq(game.save.party[1], party[1], "CASE8 party order untouched")
end

--------------------------------------------------------------------
-- CASE 9: Yellow stock Pikachu — no POKEBALL choice
--------------------------------------------------------------------
do
  local ow = makeOw()
  local party = { makeMon("PIKACHU", 1) }
  local game = {
    save = { party = party, pokepcFollowerCount = 1, pokepcControlMode = "follow" },
    data = {}, overworld = ow,
    stack = { items = {}, push = function(s, b) s.items[#s.items + 1] = b end },
    generation = 1,
  }
  local engine = makeEngine(game, 1)
  local interaction = Interaction.new(V.mod, engine.selection, engine)
  local stock = {
    pikachuFollower = true,
    pokepcTrailer = false,
    facing = "down",
  }
  lastChoice = nil
  local presented = {}
  local GameCompat = V.require("game_compat")
  local orig = GameCompat.presentText
  local origChoice = GameCompat.presentTextChoice
  GameCompat.presentText = function(_, _, _, text, done)
    presented[#presented + 1] = { kind = "text", text = text }
    if done then done() end
    return "textBox"
  end
  GameCompat.presentTextChoice = function()
    presented[#presented + 1] = { kind = "choice" }
    return "textBoxChoice"
  end
  interaction:showFollowMessage(game, ow, stock, party[1])
  local sawChoice = false
  for _, p in ipairs(presented) do
    if p.kind == "choice" then sawChoice = true end
  end
  check(not sawChoice, "CASE9 stock Pikachu has no POKEBALL choice")
  check(#presented >= 1 and presented[1].kind == "text",
    "CASE9 stock gets plain text")
  GameCompat.presentText = orig
  GameCompat.presentTextChoice = origChoice
end

--------------------------------------------------------------------
-- Ambient fragment regression spot-check
--------------------------------------------------------------------
do
  check(AmbientCries.textFor("RATTATA") ~= "[...]", "ambient uncurated not [...]")
  eq(AmbientCries.fragmentFor("CHARIZARD"), "Chari!", "ambient Chari!")
end

print(string.format("\n%d failures", failures))
os.exit(failures == 0 and 0 or 1)
