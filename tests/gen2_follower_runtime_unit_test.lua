-- Gold follower runtime: World:step update owner, trailer counts, player sprite.
-- Gen1 OverworldController.update ownership must remain unchanged.
-- Run: luajit tests/gen2_follower_runtime_unit_test.lua
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

package.loaded["src.core.GameVersion"] = {
  get = function() return "gold" end,
  isYellow = function() return false end,
  isGold = function() return true end,
  generation = function() return 2 end,
}
package.loaded["src.render.SpriteRenderer"] = {
  new = function(def, id) return { def = def, id = id } end,
}

-- Real Gold: require("src.world.NPC") is an alias of src.world.gen2.Npc.
-- NPC.new(mapId, objDef, spriteDef) — NOT Gen1 NPC.new(data, mapId, def).
-- A mock that accepts both arities hid the live Gold failure.
local function nativeGoldNpcModule()
  return {
    MOVE = {
      STILL = 1, WANDER = 2, STANDING_DOWN = 6,
      STANDING_UP = 7, STANDING_LEFT = 8, STANDING_RIGHT = 9,
    },
    fallbackSpriteDef = function() return nil end,
    new = function(mapId, objDef, spriteDef)
      if type(mapId) == "table" then
        error("Gold native NPC.new received Gen1 arity")
      end
      if type(objDef) ~= "table" then
        error("Gold native NPC.new missing objDef")
      end
      if type(spriteDef) ~= "table" or spriteDef.image == nil then
        error("Gold native NPC.new requires spriteDef.image")
      end
      return {
        id = string.format("%s_obj_%d", tostring(mapId), objDef.index or 0),
        mapId = mapId,
        def = objDef,
        spriteDef = spriteDef,
        sprite = { def = spriteDef, id = "npc" },
        cellX = objDef.x or 0,
        cellY = objDef.y or 0,
        px = (objDef.x or 0) * 16,
        py = (objDef.y or 0) * 16,
        facing = "down",
        moving = false,
        progress = 0,
        passable = false,
        movement = objDef.movement,
        update = function() end,
        pose = function(ent)
          return ent.sprite, ent.px, ent.py, ent.facing, 0, false
        end,
        draw = function(self, ox, oy, scale)
          self._lastGoldDraw = { ox = ox, oy = oy, scale = scale }
        end,
        walkPhase = function() return 0 end,
      }
    end,
    walkPhase = function() return 0 end,
  }
end
local goldNpc = nativeGoldNpcModule()
package.loaded["src.world.NPC"] = goldNpc
package.loaded["src.world.gen2.Npc"] = goldNpc
package.loaded["src.world.OverworldController"] = {
  update = function() end,
  talkTo = function() return false end,
  interact = function() return false end,
}
package.loaded["src.world.PikachuFollower"] = {
  update = function() end,
  onMapEntered = function() end,
  starterInParty = function() return nil end,
  current = function() return nil end,
  talk = function() end,
}
package.loaded["src.world.gen2.World"] = {
  step = function() end,
}

local optionStore = {
  follower_count = 1,
  follow_control = "trainer",
  trainer_trail = false,
  sprite_style = "pokemmo",
}
local events = {}
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end },
    find = function() return nil end,
    options = {
      get = function(_, k) return optionStore[k] end,
      set = function(_, k, v) optionStore[k] = v end,
    },
    events = {
      on = function(_, name, fn)
        events[name] = events[name] or {}
        events[name][#events[name] + 1] = fn
        return function() end
      end,
    },
    hooks = { wrap = function() end },
    world = { game = nil, overworld = function() return nil end },
  },
  path = ".",
}
local modules = {}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end
modules.config = {
  DEFAULTS = optionStore,
  get = function(_, k) return optionStore[k] end,
  spriteStyle = function() return "pokemmo" end,
  normalizeSpriteStyle = function(s) return s or "pokemmo" end,
  debug = function() return false end,
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end,
  debug = function() end, followerGen2 = function() end,
  followerGen2Always = function() end,
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }
modules.cell_occupancy = {
  isFollowerEntity = function(e) return e and e.pokepcTrailer == true end,
}
modules.surface = { WATER = "WATER" }

local GameCompat = V.require("game_compat")
local ControlEngine = V.require("follower/control_engine")
local SpriteService = V.require("follower/sprite_service")
local Selection = V.require("follower/selection")
local State = V.require("follower/state")

local function healthy(species)
  return {
    species = species, hp = 20, level = 5, otId = 1,
    dvs = { attack = 1, defense = 2, speed = 3, special = 4 },
  }
end

local function goldWorld()
  local player = {
    cellX = 10, cellY = 10, px = 160, py = 160,
    facing = "down", moving = false, stepFrames = 16,
    setSprite = function(self, def)
      self.spriteDef = def
      self.sprite = { def = def, id = "player" }
    end,
  }
  local world = {
    map = {
      id = "ROUTE_29",
      inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 40 and y < 40 end,
      isWalkableCell = function() return true end,
      isWaterCell = function() return false end,
    },
    player = player,
    playerState = "normal",
    npcs = {},
    entities = {},
    applyPlayerState = function(self, state)
      self.playerState = state or "normal"
      self._restored = true
    end,
  }
  return world, player
end

local function goldGame(world, party)
  return {
    generation = 2,
    version = "gold",
    save = {
      party = party,
      playerState = "normal",
      pokepcFollowerCount = 1,
      pokepcControlMode = "follow",
    },
    world = world,
    data = {
      sprites = {},
      pokemon = {
        SENTRET = { name = "SENTRET", dex = 161 },
        PIDGEY = { name = "PIDGEY", dex = 16 },
        CHIKORITA = { name = "CHIKORITA", dex = 152 },
      },
    },
  }
end

local function makeEngine(n, spriteFn)
  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  return ControlEngine.new(V.mod, {
    selection = selection,
    settings = {
      followerCount = function() return n or 1 end,
      engineMode = function() return "follow" end,
      alignSave = function(_, game)
        if game and game.save then game.save.pokepcFollowerCount = n or 1 end
      end,
    },
    spriteService = {
      resolveFollowerSprite = spriteFn or function(_, opts)
        local species = opts.species or "SENTRET"
        return {
          id = (opts.role == "player_controlled") and "SPRITE_WILDS_PLAYER_MON"
            or "SPRITE_WILDS_FOLLOWER_MON",
          image = "land_" .. species .. ".png",
          frames = 6, walker = true, trueColor = true,
          dex = ({ SENTRET = 161, PIDGEY = 16, CHIKORITA = 152 })[species],
          fallback = false,
        }
      end,
      dexOf = function(_, species, game)
        return GameCompat.speciesId(species, game, V.mod)
      end,
      hasSpritePikachu = function() return true end,
    },
  })
end

----------------------------------------------------------------
-- Gold World:step → ControlEngine:update exactly once
----------------------------------------------------------------
do
  local world = select(1, goldWorld())
  local game = goldGame(world, { healthy("SENTRET") })
  world.game = game
  V.mod.world = { game = game, overworld = function() return world end }
  V.mod.game = game
  local engine = makeEngine(1)
  engine._gameRef = game
  engine:install()
  eq(engine._trailerUpdateOwner, "gen2_world_event", "Gold owner is gen2_world_event")
  check(engine._gen2WorldStepWrapped == true, "Gold World:step wrap installed")
  check(engine._owUpdateWrapped ~= true, "Gen1 OverworldController wrap skipped")
  engine.selection:selectFollower(game.save.party[1], game, {})
  engine:syncAll(game, world)
  eq(#(world.pokepcTrailers or {}), 1, "Gold follower count=1 creates one trailer")
  local before = engine.diag.controlUpdateCalls or 0
  package.loaded["src.world.gen2.World"].step(world)
  eq(engine.diag.controlUpdateCalls, before + 1, "World:step → update exactly once")
  local mid = engine.diag.controlUpdateCalls
  package.loaded["src.world.PikachuFollower"].update(game, world)
  eq(engine.diag.controlUpdateCalls, mid, "PF.update does not double-tick Gold")
  engine:restore()
end

----------------------------------------------------------------
-- Gold follower count=6
----------------------------------------------------------------
do
  local party = {
    healthy("SENTRET"), healthy("PIDGEY"), healthy("CHIKORITA"),
    healthy("SENTRET"), healthy("PIDGEY"), healthy("CHIKORITA"),
  }
  party[4].otId, party[5].otId, party[6].otId = 2, 3, 4
  local world = select(1, goldWorld())
  local game = goldGame(world, party)
  game.save.pokepcFollowerCount = 6
  local engine = makeEngine(6)
  engine._gameRef = game
  engine.selection:selectFollower(party[1], game, {})
  engine:setLeaderParty(game, 1)
  engine:syncAll(game, world)
  eq(#(world.pokepcTrailers or {}), 6, "Gold follower count=6 creates 6 trailers")
  local inNpcs = 0
  for _, n in ipairs(world.npcs) do
    if n.pokepcTrailer then inNpcs = inNpcs + 1 end
  end
  eq(inNpcs, 6, "all 6 trailers on world.npcs")
end

----------------------------------------------------------------
-- Gold Gen2 species player-controlled: no pokemon_missing.png, dex 161
----------------------------------------------------------------
do
  local world, player = goldWorld()
  local mon = healthy("SENTRET")
  local game = goldGame(world, { mon })
  eq(GameCompat.speciesId("SENTRET", game, V.mod), 161, "Sentret dex == 161")
  local engine = makeEngine(0)
  engine._gameRef = game
  engine.settings.engineMode = function() return "pokemon" end
  engine.selection:selectFollower(mon, game, {})
  engine:setLeaderParty(game, 1)
  engine:applyPlayerAsPokemon(game, world, true)
  local def = player.spriteDef
  check(def ~= nil, "Gold player SpriteDef present")
  check(def.image ~= nil, "Gold player SpriteDef has valid image")
  check(not tostring(def.image):find("pokemon_missing.png", 1, true),
        "Gold Gen2 species player-controlled does not use pokemon_missing.png")
  eq(player._pokepcControlSpecies, "SENTRET", "player-controlled species is SENTRET")
  eq(def.id, "SPRITE_WILDS_PLAYER_MON",
     "Gold player sprite id is not a Gen1 SPRITE_PLAYER_POKEMON registration")
end

----------------------------------------------------------------
-- SpriteService dexOf passes Gold game (Sentret 161, not Charmander 4)
----------------------------------------------------------------
do
  local world = select(1, goldWorld())
  local game = goldGame(world, { healthy("SENTRET") })
  local svc = SpriteService.new(V.mod, {})
  eq(svc:dexOf("SENTRET", game), 161, "SpriteService:dexOf(SENTRET, goldGame) == 161")
  local resolved = svc:resolveFollowerSprite({
    species = "SENTRET", role = "player_controlled", game = game, surface = "land",
  })
  -- No runtime sheets in this harness → fallback image, but dex must still be 161.
  eq(resolved.dex, 161, "player_controlled resolve carries dex 161")
end

----------------------------------------------------------------
-- Gen1 update owner unchanged (no Gold World wrap)
----------------------------------------------------------------
do
  package.loaded["src.core.GameVersion"] = {
    get = function() return "red" end,
    isYellow = function() return false end,
    generation = function() return 1 end,
  }
  V.mod.game = nil
  V.mod.world = { game = nil, overworld = function() return nil end }
  local owCalls = 0
  local OW = package.loaded["src.world.OverworldController"]
  function OW:update()
    owCalls = owCalls + 1
  end
  local engine = ControlEngine.new(V.mod, {
    settings = {
      followerCount = function() return 0 end,
      engineMode = function() return "follow" end,
    },
    spriteService = { hasSpritePikachu = function() return true end },
  })
  engine:install()
  eq(engine._trailerUpdateOwner, "overworld", "Gen1 owner remains overworld")
  check(engine._gen2WorldStepWrapped ~= true, "Gen1 does not wrap Gold World:step")
  check(engine._owUpdateWrapped == true, "Gen1 OverworldController.update wrap stays")
  OW:update(1 / 60)
  eq(owCalls, 1, "Gen1 OverworldController.update still runs")
  engine:restore()
  package.loaded["src.core.GameVersion"] = {
    get = function() return "gold" end,
    isYellow = function() return false end,
    isGold = function() return true end,
    generation = function() return 2 end,
  }
end

----------------------------------------------------------------
-- Gold follower count=3
----------------------------------------------------------------
do
  local party = {
    healthy("SENTRET"), healthy("PIDGEY"), healthy("CHIKORITA"),
  }
  party[2].otId, party[3].otId = 2, 3
  local world = select(1, goldWorld())
  local game = goldGame(world, party)
  game.save.pokepcFollowerCount = 3
  local engine = makeEngine(3)
  engine._gameRef = game
  engine.selection:selectFollower(party[1], game, {})
  engine:setLeaderParty(game, 1)
  engine:syncAll(game, world)
  eq(#(world.pokepcTrailers or {}), 3, "Gold follower count=3 creates 3 trailers")
end

----------------------------------------------------------------
-- Late World.lua load: map.entered installs the World:step wrap
----------------------------------------------------------------
do
  events = {}
  V.mod.events.on = function(_, name, fn)
    events[name] = events[name] or {}
    events[name][#events[name] + 1] = fn
    return function() end
  end
  local savedWorld = package.loaded["src.world.gen2.World"]
  package.loaded["src.world.gen2.World"] = { notStep = true }
  local world = select(1, goldWorld())
  local game = goldGame(world, { healthy("SENTRET") })
  world.game = game
  V.mod.world = { game = game, overworld = function() return world end }
  V.mod.game = game
  local engine = makeEngine(1)
  engine._gameRef = game
  engine:install()
  eq(engine._trailerUpdateOwner, "gen2_world_event",
     "Gold owner is gen2_world_event even before World.step exists")
  check(engine._gen2WorldStepWrapped ~= true,
        "World:step wrap waits until World.lua is loaded")
  package.loaded["src.world.gen2.World"] = savedWorld
  for _, fn in ipairs(events["map.entered"] or {}) do
    fn({ mapId = "ROUTE_29" })
  end
  check(engine._gen2WorldStepWrapped == true,
        "map.entered installs Gold World:step wrap")
  local before = engine.diag.controlUpdateCalls or 0
  savedWorld.step(world)
  eq(engine.diag.controlUpdateCalls, before + 1,
     "late-wrapped World:step ticks ControlEngine:update once")
  engine:restore()
end

----------------------------------------------------------------
-- Native Gold NPC.new(mapId, objDef, spriteDef) trailer path
----------------------------------------------------------------
do
  local origNpc = package.loaded["src.world.NPC"]
  local origNpc2 = package.loaded["src.world.gen2.Npc"]
  local nativeCalls = 0
  local goldNative = {
    MOVE = { STANDING_DOWN = 6 },
    fallbackSpriteDef = { image = "chris.png", frames = 6 },
    new = function(mapId, objDef, spriteDef)
      nativeCalls = nativeCalls + 1
      if type(mapId) == "table" then
        error("Gold native NPC.new received Gen1 arity")
      end
      check(type(spriteDef) == "table" and spriteDef.image ~= nil,
            "native Gold NPC.new received spriteDef.image")
      eq(objDef.movement, 6, "native Gold NPC.new uses STANDING_DOWN")
      return {
        id = "WILDS_TRAILER_" .. tostring(objDef and objDef.index or 0),
        mapId = mapId,
        spriteDef = spriteDef,
        sprite = { def = spriteDef, id = "npc" },
        cellX = objDef and objDef.x or 0,
        cellY = objDef and objDef.y or 0,
        px = (objDef and objDef.x or 0) * 16,
        py = (objDef and objDef.y or 0) * 16,
        facing = "down",
        moving = false,
        progress = 0,
        update = function() end,
        draw = function(self, ox, oy, scale)
          self._lastGoldDraw = { ox = ox, oy = oy, scale = scale }
        end,
      }
    end,
    walkPhase = function() return 0 end,
  }
  package.loaded["src.world.NPC"] = goldNative
  package.loaded["src.world.gen2.Npc"] = goldNative
  local world = select(1, goldWorld())
  local game = goldGame(world, { healthy("SENTRET") })
  local engine = makeEngine(1)
  engine._gameRef = game
  engine.selection:selectFollower(game.save.party[1], game, {})
  engine:syncAll(game, world)
  eq(#(world.pokepcTrailers or {}), 1, "native Gold NPC.new created one trailer")
  check(nativeCalls >= 1, "native Gold NPC.new was used")
  check(world.npcs[1] and world.npcs[1].pokepcTrailer == true,
        "native trailer attached to world.npcs")
  check(world.npcs[1] and world.npcs[1].spriteDef ~= nil,
        "native trailer draw contract has spriteDef")
  check(world.entities[1] == world.npcs[1] or (function()
    for _, e in ipairs(world.entities or {}) do
      if e == world.npcs[1] then return true end
    end
    return false
  end)(), "native trailer also in world.entities")
  package.loaded["src.world.NPC"] = origNpc
  package.loaded["src.world.gen2.Npc"] = origNpc2
end

----------------------------------------------------------------
-- Gen2.makeGuestNpc does NOT fall back to Gen1 NPC.new(data, mapId, def)
----------------------------------------------------------------
do
  local origNpc = package.loaded["src.world.NPC"]
  local origNpc2 = package.loaded["src.world.gen2.Npc"]
  local gen1Calls = 0
  package.loaded["src.world.gen2.Npc"] = nil
  package.loaded["src.world.NPC"] = {
    -- No MOVE: this is the old sniff that took fromGen1.
    new = function(data, mapId, def)
      gen1Calls = gen1Calls + 1
      if type(data) == "table" and type(mapId) ~= "table" then
        return { id = "GEN1_FALLBACK", fromGen1 = true }
      end
      error("Gen1 NPC.new expected (data, mapId, def)")
    end,
  }
  local world = select(1, goldWorld())
  local game = goldGame(world, { healthy("SENTRET") })
  local npc, err = GameCompat.makeGuestNpc(game, world, {
    index = 241, name = "WILDS_TRAILER_1",
    spriteId = "SPRITE_PIKACHU",
    spriteDef = { id = "SPRITE_WILDS_FOLLOWER_MON", image = "land_SENTRET.png", frames = 6 },
    x = 10, y = 10,
  })
  check(npc == nil, "Gen2.makeGuestNpc does not succeed via Gen1 arity")
  check(npc == nil or npc.fromGen1 ~= true, "no fromGen1 guest NPC")
  check(err ~= nil, "Gen1-arity Gold NPC.new returns an error")
  package.loaded["src.world.NPC"] = origNpc
  package.loaded["src.world.gen2.Npc"] = origNpc2
end

----------------------------------------------------------------
-- Poisoned package.loaded["src.world.NPC"] (Gen1 arity) must not win
-- when src.world.gen2.Npc is the real Gold module.
-- Unit tests used to pass because mock X exposed Y, real Gold exposes Z:
--   X = package.loaded["src.world.NPC"]
--   Y = Gen1-arity new(_, mapId, def) without MOVE (accepted both arities)
--   Z = src.world.gen2.Npc / alias NPC.new(mapId, objDef, spriteDef)
--       with MOVE.STANDING_DOWN. pcall(require, "src.world.NPC") can also
--       cache Gen1 NPC.lua whose draw(camX, camY) is invisible under Gold.
----------------------------------------------------------------
do
  local origNpc = package.loaded["src.world.NPC"]
  local origNpc2 = package.loaded["src.world.gen2.Npc"]
  local nativeCalls, gen1Calls = 0, 0
  local goldNative = nativeGoldNpcModule()
  local origNew = goldNative.new
  goldNative.new = function(mapId, objDef, spriteDef)
    nativeCalls = nativeCalls + 1
    return origNew(mapId, objDef, spriteDef)
  end
  package.loaded["src.world.gen2.Npc"] = goldNative
  package.loaded["src.world.NPC"] = {
    new = function(data, mapId, def)
      gen1Calls = gen1Calls + 1
      return { id = "GEN1_POISON", fromGen1 = true, mapId = mapId }
    end,
  }
  local world = select(1, goldWorld())
  local game = goldGame(world, { healthy("SENTRET") })
  local npc, err = GameCompat.makeGuestNpc(game, world, {
    index = 241, name = "WILDS_TRAILER_1",
    spriteId = "SPRITE_PIKACHU",
    spriteDef = { id = "SPRITE_WILDS_FOLLOWER_MON", image = "land_SENTRET.png", frames = 6 },
    x = 10, y = 10,
  })
  check(npc ~= nil, "poisoned src.world.NPC does not block gen2.Npc: " .. tostring(err))
  check(npc and npc.fromGen1 ~= true, "guest is not the Gen1-poisoned object")
  eq(nativeCalls, 1, "used src.world.gen2.Npc")
  eq(gen1Calls, 0, "did not call poisoned Gen1 NPC.new")
  eq(npc and npc._wildsGoldNpcSource, "src.world.gen2.Npc", "source is gen2.Npc")
  package.loaded["src.world.NPC"] = origNpc
  package.loaded["src.world.gen2.Npc"] = origNpc2
end

----------------------------------------------------------------
-- Gen2.makeGuestNpc + attach: world.npcs, spriteDef, STANDING_DOWN
----------------------------------------------------------------
do
  local world = select(1, goldWorld())
  local game = goldGame(world, { healthy("SENTRET") })
  local npc, err = GameCompat.makeGuestNpc(game, world, {
    index = 241, name = "WILDS_TRAILER_1",
    spriteId = "SPRITE_PIKACHU",
    spriteDef = {
      id = "SPRITE_WILDS_FOLLOWER_MON", image = "land_SENTRET.png",
      frames = 6, trueColor = true, frameWidth = 16, frameHeight = 16,
    },
    x = 9, y = 11,
  })
  check(npc ~= nil, "Gen2.makeGuestNpc succeeds on native contract: " .. tostring(err))
  eq(npc and npc.cellX, 9, "native NPC cellX from objDef")
  eq(npc and npc.mapId, "ROUTE_29", "native NPC mapId is Gold map id")
  eq(npc and npc.movement, 6, "native NPC movement is STANDING_DOWN")
  check(npc and npc.spriteDef and npc.spriteDef.image ~= nil, "spriteDef valid")
  eq(npc and npc.passable, true, "native NPC passable like Follower.lua")
  eq(npc and npc._wildsGoldGuest, true, "guest persistence marker matches town Pokémon")
  local attached = GameCompat.attachGuestEntity(world, npc, game)
  eq(attached, "npcs+entities", "attachGuestEntity uses npcs+entities")
  local inNpcs, inEntities = false, false
  for _, n in ipairs(world.npcs) do if n == npc then inNpcs = true end end
  for _, e in ipairs(world.entities) do if e == npc then inEntities = true end end
  check(inNpcs, "attached guest is in world.npcs")
  check(inEntities, "attached guest is in world.entities")
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll Gen2 follower runtime tests passed.")
