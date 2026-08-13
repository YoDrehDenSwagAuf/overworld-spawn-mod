-- Gold / Gen2 follower runtime: liveOverworld, party FOLLOW, trailers,
-- containers, movement, map resync, surf sprites, True Size, pack order.
-- Gen1 follower tests stay in tests/follower_* and must remain unchanged.
-- Run: luajit tests/gen2_followers_unit_test.lua
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

-- Real Gold NPC contract: NPC.new(mapId, objDef, spriteDef).
-- Do not silently accept Gen1 NPC.new(data, mapId, def).
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

local owUpdateCalls = 0
local OverworldState = {
  talkTo = function() return false end,
  interact = function() return false end,
}
function OverworldState:update(dt)
  owUpdateCalls = owUpdateCalls + 1
end
package.loaded["src.world.OverworldController"] = OverworldState

package.loaded["src.world.PikachuFollower"] = {
  update = function() end,
  onMapEntered = function() end,
  starterInParty = function() return nil end,
  current = function() return nil end,
  talk = function() end,
}

-- Gold World:step is the exclusive Gen2 trailer driver. A no-op body is
-- enough: ControlEngine wraps this and calls update after origStep.
package.loaded["src.world.gen2.World"] = {
  step = function() end,
}

local optionStore = {
  follower_count = 1,
  follow_control = "trainer",
  trainer_trail = false,
  sprite_style = "pokemmo",
  pokemon_size = "true_size",
}
local events = {}
local submenuWrap
local modules = {}
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
    hooks = {
      wrap = function(_, name, fn)
        if name == "ui.party.submenu" then submenuWrap = fn end
      end,
    },
    world = { game = nil, overworld = function() return nil end },
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
  DEFAULTS = {
    sprite_style = "pokemmo",
    pokemon_size = "true_size",
    follower_count = 1,
    follow_control = "trainer",
    trainer_trail = false,
  },
  get = function(_, k) return optionStore[k] or modules.config.DEFAULTS[k] end,
  spriteStyle = function() return optionStore.sprite_style or "pokemmo" end,
  normalizeSpriteStyle = function(s) return s or "pokemmo" end,
  pokemonSizeMode = function() return optionStore.pokemon_size or "true_size" end,
  debug = function() return false end,
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end, debug = function() end,
  followerGen2 = function() end, followerGen2Always = function() end,
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }
modules.cell_occupancy = {
  isFollowerEntity = function(e) return e and e.pokepcTrailer == true end,
}
modules.surface = { WATER = "WATER" }

local GameCompat = V.require("game_compat")
local State = V.require("follower/state")
local Selection = V.require("follower/selection")
local ControlEngine = V.require("follower/control_engine")
local Follower = V.require("follower/init")

local function healthy(species, extra)
  extra = extra or {}
  return {
    species = species,
    hp = extra.hp or 20,
    level = extra.level or 5,
    nickname = extra.nickname,
    otId = extra.otId or 1,
    dvs = extra.dvs or { attack = 1, defense = 2, speed = 3, special = 4 },
  }
end

local function goldMap(id)
  return {
    id = id or "ROUTE_29",
    inBounds = function(_, x, y) return x >= 0 and y >= 0 and x < 40 and y < 40 end,
    isWalkableCell = function() return true end,
    isWaterCell = function(_, x, y) return y < 4 end,
  }
end

local function goldWorld(opts)
  opts = opts or {}
  local player = opts.player or {
    cellX = 10, cellY = 10, px = 160, py = 160,
    facing = "down", moving = false, stepFrames = 16,
    setSprite = function(self, def)
      self.spriteDef = def
      self.sprite = { def = def, id = "player" }
    end,
  }
  local world = {
    map = opts.map or goldMap(opts.mapId),
    player = player,
    playerState = opts.playerState or "normal",
    npcs = {},
    entities = {},
    showText = function(self, text, onDone)
      self._shownText = text
      if onDone then onDone() end
    end,
  }
  return world, player
end

local function goldGame(world, party)
  return {
    generation = 2,
    version = "gold",
    save = {
      party = party or { healthy("CHIKORITA") },
      playerState = world and world.playerState or "normal",
      pokepcFollowerCount = 1,
      pokepcControlMode = "follow",
    },
    world = world,
    data = {
      sprites = { SPRITE_PIKACHU = { id = "SPRITE_PIKACHU", image = "x.png", frames = 6 } },
      pokemon = {
        CHIKORITA = { name = "CHIKORITA", dex = 152 },
        CYNDAQUIL = { name = "CYNDAQUIL", dex = 155 },
        TOTODILE = { name = "TOTODILE", dex = 158 },
        SENTRET = { name = "SENTRET", dex = 161 },
        ONIX = { name = "ONIX", dex = 95 },
      },
    },
    stack = { push = function() end },
  }
end

local function makeEngine(n)
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
      resolveFollowerSprite = function(_, opts)
        local water = opts.surface == "water" or opts.surface == "surfing"
        local onix = opts.species == "ONIX"
        return {
          id = "SPRITE_WILDS_FOLLOWER_MON",
          image = (water and "water_" or "land_") .. tostring(opts.species) .. ".png",
          frames = 6,
          walker = true,
          trueColor = true,
          frameWidth = onix and 32 or 16,
          frameHeight = onix and 32 or 16,
          anchorX = onix and 16 or 8,
          anchorY = onix and 32 or 16,
          style = opts.style,
        }
      end,
      hasSpritePikachu = function() return true end,
    },
  })
end

----------------------------------------------------------------
-- 1. Capability is on only after adapter paths exist (this file is that gate)
----------------------------------------------------------------
eq(GameCompat.supportsFeature("followers", nil, { generation = 2 }), true,
   "1. Gen2 followers capability is true")
eq(GameCompat.Gen2.capabilities.followers, true, "1. Gen2.capabilities.followers")
eq(GameCompat.supportsFeature("followers", nil, { version = "red" }), true,
   "15. Gen1 followers remain enabled")

----------------------------------------------------------------
-- liveOverworld: Gold world vs Gen1 OverworldState
----------------------------------------------------------------
do
  local world = select(1, goldWorld())
  local game = goldGame(world)
  check(GameCompat.liveOverworld(V.mod, game) == world, "Gold liveOverworld → game.world")
  check(game.overworld == nil, "Gold does not grow a fake game.overworld")
end
do
  package.loaded["src.core.GameVersion"] = {
    get = function() return "red" end,
    isYellow = function() return false end,
    generation = function() return 1 end,
  }
  local ow = { map = { id = "PALLET_TOWN" }, player = { cellX = 2, cellY = 2 } }
  local game = { overworld = ow }
  check(GameCompat.liveOverworld(nil, game) == ow, "15. Gen1 liveOverworld is OverworldState")
  package.loaded["src.core.GameVersion"] = {
    get = function() return "gold" end,
    isYellow = function() return false end,
    isGold = function() return true end,
    generation = function() return 2 end,
  }
end

----------------------------------------------------------------
-- 2–4. Party FOLLOW creates a Gold guest trailer on npcs+entities
----------------------------------------------------------------
do
  local world, player = goldWorld()
  local mon = healthy("CHIKORITA")
  local game = goldGame(world, { mon })
  game.save.pokepcFollowerCount = 0
  optionStore.follower_count = 0
  V.mod.world = { game = game, overworld = function() return world end }
  V.mod.game = game
  local follower = Follower.new(V.mod, {})
  check(follower._supported == nil, "Follower.new does not cache support")
  check(follower:isSupported(game) == true, "isSupported(Gold) is true")
  local ok = follower:install({ game = game })
  check(ok == true, "Follower:install on Gold")
  check(type(submenuWrap) == "function", "2. ui.party.submenu wrap installed")
  follower.control:setFollowerCount(game, 0)

  local items = submenuWrap(function() return {} end, game, {}, mon, {})
  local labels = {}
  local follow
  for _, row in ipairs(items or {}) do
    labels[#labels + 1] = tostring(row.label)
    if row.label == "FOLLOW" then follow = row end
  end
  check(follow ~= nil, "2. FOLLOW row present (" .. table.concat(labels, ",") .. ")")
  if not follow then
    io.stderr:write("FAIL: aborting FOLLOW flow\n")
  else
  follow.onSelect(mon, game)
  eq(game.save.pokepcFollowerCount, 1, "2. follower_count becomes 1")
  check(game.save.followerPartyIndex == 1, "2. selected party slot stored")
  eq(#(world.pokepcTrailers or {}), 1, "3. follower entity created")
  local npc = world.pokepcTrailers[1]
  check(npc ~= nil, "3. trailer exists")
  eq(npc.pokepcTrailer, true, "3. pokepcTrailer marker")
  eq(npc.wildsFollower, true, "3. wildsFollower marker")
  eq(npc.overworldWildSpawn, false, "3. not a wild spawn")
  eq(npc.wildsBattleable, false, "3. not battleable")
  check(GameCompat.entityInDrawList(world, npc, game), "4. attached to Gold npcs")
  local inNpcs, inEnt = false, false
  for _, e in ipairs(world.npcs) do if e == npc then inNpcs = true end end
  for _, e in ipairs(world.entities) do if e == npc then inEnt = true end end
  check(inNpcs, "4. on world.npcs")
  check(inEnt, "4. on world.entities")
  check(world._shownText and tostring(world._shownText):find("following", 1, true),
        "2. confirmation text via world:showText")

  ----------------------------------------------------------------
  -- 5–6. One player step: trailer follows and keeps spacing
  ----------------------------------------------------------------
  local npc = world.pokepcTrailers[1]
  world._wildsEntryCooldown = 0
  npc.cellX, npc.cellY = 10, 9
  npc.px, npc.py = 160, 144
  npc.targetX, npc.targetY = nil, nil
  npc.moving = false
  npc.progress = 0
  player.cellX, player.cellY = 10, 10
  player.targetX, player.targetY = 10, 11
  player.facing = "down"
  player.moving = true
  player.stepFrames = 4
  world.pokepcTrailHead = { x = 10, y = 10 }
  world.pokepcTrailCells = { { x = 10, y = 9 } }
  local startY = npc.cellY
  local moved = false
  for _ = 1, 24 do
    follower.control:update(game, world, { source = "step" })
    if npc.cellY ~= startY or npc.moving or npc.targetY then moved = true end
    if npc.moving then
      -- Finish the in-flight step the same way ControlEngine does.
    end
  end
  check(moved, "5. follower follows one player step")
  local dx = math.abs((npc.cellX or 0) - (player.cellX or player.targetX or 0))
  local dy = math.abs((npc.cellY or 0) - (player.cellY or player.targetY or 0))
  check(dx + dy <= 4, "6. spacing stays near the player (no teleport)")

  ----------------------------------------------------------------
  -- 7. Map transition resync: trailers vanish then respawn, no dupes
  ----------------------------------------------------------------
  local exited = events["map.exited"]
  local entered = events["map.entered"]
  if exited then
    for _, fn in ipairs(exited) do fn({ mapId = "ROUTE_29", toMapId = "CHERRYGROVE_CITY" }) end
  end
  eq(#(world.pokepcTrailers or {}), 0, "7. trailers removed on map.exited")
  world.map = goldMap("CHERRYGROVE_CITY")
  player.cellX, player.cellY = 5, 5
  player.targetX, player.targetY = nil, nil
  player.moving = false
  if entered then
    for _, fn in ipairs(entered) do
      fn({ mapId = "CHERRYGROVE_CITY", via = "warp" })
    end
  end
  follower.control:update(game, world, { source = "map-enter", mapEnter = true })
  eq(#(world.pokepcTrailers or {}), 1, "7. one trailer after warp resync")
  local seen = {}
  local dup = false
  for _, t in ipairs(world.pokepcTrailers or {}) do
    local id = t.id or t
    if seen[id] then dup = true end
    seen[id] = true
  end
  check(not dup, "7. no duplicate trailers after transition")

  ----------------------------------------------------------------
  -- 8–9. land → water → land sprite switch via Gen2.isSurfing
  ----------------------------------------------------------------
  local t = world.pokepcTrailers[1]
  world.playerState = "surf"
  game.save.playerState = "surf"
  eq(GameCompat.isSurfing(game, world), true, "8. Gen2.isSurfing via playerState")
  follower.control._lastTrailSurface = "land"
  follower.control:update(game, world, { source = "surf" })
  t = world.pokepcTrailers[1]
  check(t ~= nil, "8. trailer remains while surfing")
  eq(t.spriteState, "water", "8. swimming sprite after Surf")
  eq(t.wildsFollowerWater, true, "8. water flag from shared surface path")
  eq(t.overworldWildSpawn, false, "8. still not a wild spawn")

  world.playerState = "normal"
  game.save.playerState = "normal"
  follower.control:update(game, world, { source = "land" })
  t = world.pokepcTrailers[1]
  eq(t.spriteState, "land", "9. land sprite after leaving water")
  eq(t.wildsFollowerWater, false, "9. land flag restored")

  ----------------------------------------------------------------
  -- 14. DISMISS
  ----------------------------------------------------------------
  local items2 = submenuWrap(function() return {} end, game, {}, mon, {})
  local dismiss
  for _, row in ipairs(items2 or {}) do
    if row.label == "DISMISS" then dismiss = row end
  end
  check(dismiss ~= nil, "14. DISMISS row present")
  dismiss.onSelect(mon, game)
  eq(game.save.pokepcFollowerCount, 0, "14. selection cleared / count 0")
  eq(#(world.pokepcTrailers or {}), 0, "14. trailer removed")
  eq(#world.npcs, 0, "14. no stale npc")
  follower:restore()
  end
end

----------------------------------------------------------------
-- 10. HGSS True Size geometry survives SpriteDef construction
----------------------------------------------------------------
do
  local world = select(1, goldWorld())
  local mon = healthy("ONIX")
  local game = goldGame(world, { mon })
  game.save.pokepcFollowerCount = 1
  local engine = makeEngine(1)
  engine._gameRef = game
  engine.selection:selectFollower(mon, game, {})
  engine:syncAll(game, world)
  local npc = world.pokepcTrailers and world.pokepcTrailers[1]
  check(npc ~= nil, "10. True Size trailer spawned")
  local def = npc.sprite and npc.sprite.def
  check(def ~= nil, "10. sprite def present")
  eq(def.frameWidth, 32, "10. frameWidth preserved")
  eq(def.frameHeight, 32, "10. frameHeight preserved")
  eq(def.anchorX, 16, "10. anchorX preserved")
  eq(def.anchorY, 32, "10. anchorY preserved")
end

----------------------------------------------------------------
-- 11. Poké Followers style still resolves (GSC land + water path)
----------------------------------------------------------------
do
  optionStore.sprite_style = "followers"
  local world = select(1, goldWorld())
  local mon = healthy("SENTRET")
  local game = goldGame(world, { mon })
  game.save.pokepcFollowerCount = 1
  local engine = makeEngine(1)
  engine._gameRef = game
  engine.selection:selectFollower(mon, game, {})
  engine:syncAll(game, world)
  local npc = world.pokepcTrailers[1]
  check(npc ~= nil, "11. Poke Followers trailer spawned")
  eq(npc.spriteState, "land", "11. land presentation")
  world.playerState = "surf"
  game.save.playerState = "surf"
  engine._lastTrailSurface = "land"
  engine:update(game, world, { source = "gsc-surf" })
  npc = world.pokepcTrailers[1]
  eq(npc.spriteState, "water", "11. Poke Followers water presentation")
  optionStore.sprite_style = "pokemmo"
end

----------------------------------------------------------------
-- 12–13. 3 and 6 follower order
----------------------------------------------------------------
local function packSpecies(trailers)
  local out = {}
  for i, t in ipairs(trailers or {}) do
    out[i] = t.pokepcMon and t.pokepcMon.species
  end
  return out
end

do
  local party = {
    healthy("CHIKORITA"), healthy("CYNDAQUIL"), healthy("TOTODILE"),
    healthy("SENTRET"), healthy("ONIX"), healthy("CHIKORITA", { otId = 9 }),
  }
  local world = select(1, goldWorld())
  local game = goldGame(world, party)
  game.save.pokepcFollowerCount = 3
  local engine = makeEngine(3)
  engine._gameRef = game
  engine.selection:selectFollower(party[1], game, {})
  engine:setLeaderParty(game, 1)
  engine:syncAll(game, world)
  eq(#(world.pokepcTrailers or {}), 3, "12. three followers")
  local order3 = packSpecies(world.pokepcTrailers)
  eq(order3[1], "CHIKORITA", "12. slot 1 is leader")
  check(order3[2] ~= nil and order3[3] ~= nil, "12. slots 2–3 filled")

  game.save.pokepcFollowerCount = 6
  engine = makeEngine(6)
  engine._gameRef = game
  engine.selection:selectFollower(party[1], game, {})
  engine:setLeaderParty(game, 1)
  engine:syncAll(game, world)
  eq(#(world.pokepcTrailers or {}), 6, "13. six followers")
  local order6 = packSpecies(world.pokepcTrailers)
  eq(order6[1], "CHIKORITA", "13. six-pack leader first")
  eq(#order6, 6, "13. six species slots")
end

----------------------------------------------------------------
-- A/B. Healthy Gold mon gets FOLLOW; fainted does not
----------------------------------------------------------------
do
  local world = select(1, goldWorld())
  local healthyMon = healthy("SENTRET")
  local fainted = healthy("SENTRET", { hp = 0, otId = 2 })
  local game = goldGame(world, { healthyMon, fainted })
  V.mod.world = { game = game, overworld = function() return world end }
  V.mod.game = game
  submenuWrap = nil
  local follower = Follower.new(V.mod, {})
  follower:install({ game = game })
  local vanilla = {
    { label = "STATS" }, { label = "SWITCH" }, { label = "MOVE" },
    { label = "ITEM" }, { label = "CANCEL" },
  }
  local healthyRows = submenuWrap(function() return vanilla end, game, vanilla, healthyMon, { battle = false })
  local sawFollow = false
  for _, row in ipairs(healthyRows or {}) do
    if row.label == "FOLLOW" then sawFollow = true end
  end
  check(sawFollow, "A. healthy Gold SENTRET gets FOLLOW")

  local faintRows = submenuWrap(function() return vanilla end, game, vanilla, fainted, { battle = false })
  local faintFollow = false
  for _, row in ipairs(faintRows or {}) do
    if row.label == "FOLLOW" then faintFollow = true end
  end
  check(not faintFollow, "B. fainted Gold mon does not get FOLLOW")
  follower:restore()
end

----------------------------------------------------------------
-- Part 3: construction-time unsupported must not stick after install(Gold)
----------------------------------------------------------------
do
  package.loaded["src.core.GameVersion"] = {
    get = function() return nil end,
    isYellow = function() return false end,
    generation = function() return nil end,
  }
  local lonely = Follower.new({
    path = ".", id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end },
    find = function() return nil end,
    options = optionStore and {
      get = function(_, k) return optionStore[k] end,
      set = function(_, k, v) optionStore[k] = v end,
    } or nil,
    events = V.mod.events,
    hooks = V.mod.hooks,
    world = { game = nil, overworld = function() return nil end },
  }, {})
  check(lonely._supported == nil, "3. support not cached at construct")
  check(lonely:isSupported() == false, "3. no game + unknown version → unsupported")

  package.loaded["src.core.GameVersion"] = {
    get = function() return "gold" end,
    isYellow = function() return false end,
    isGold = function() return true end,
    generation = function() return 2 end,
  }
  local world = select(1, goldWorld())
  local game = goldGame(world, { healthy("SENTRET") })
  lonely.mod.world = { game = game, overworld = function() return world end }
  lonely.mod.game = game
  local ok = lonely:install({ game = game })
  check(ok == true, "3. install(Gold) succeeds after early unsupported")
  eq(lonely._supported, true, "3. support recorded at install, not construct")
  lonely:restore()
end

----------------------------------------------------------------
-- Gold World:step ticks trailers exactly once; liveOverworld is game.world
----------------------------------------------------------------
do
  local world, player = goldWorld()
  local mon = healthy("SENTRET")
  local game = goldGame(world, { mon })
  game.save.pokepcFollowerCount = 1
  V.mod.world = { game = game, overworld = function() return world end }
  V.mod.game = game
  submenuWrap = nil
  local follower = Follower.new(V.mod, {})
  follower:install({ game = game })
  eq(follower.control._trailerUpdateOwner, "gen2_world_event",
     "G. Gold update-owner=gen2_world_event")
  check(follower.control._owUpdateWrapped ~= true, "G. Gen1 OW wrap not installed on Gold")
  check(follower.control._gen2WorldStepWrapped == true, "G. Gold World:step wrap installed")
  follower.control:setFollowerCount(game, 0)
  local items = submenuWrap(function() return {} end, game, {}, mon, {})
  local labels = {}
  local follow
  for _, row in ipairs(items or {}) do
    labels[#labels + 1] = tostring(row and row.label or "?")
    if row.label == "FOLLOW" then follow = row end
  end
  check(follow ~= nil, "E. FOLLOW present for SENTRET (" .. table.concat(labels, ",") .. ")")
  if not follow then
    io.stderr:write("FAIL: aborting Gold World:step tick\n")
  else
  follow.onSelect(mon, game)
  local ow = GameCompat.liveOverworld(V.mod, game)
  check(ow == world, "E. syncAll liveOverworld is game.world")
  check(game.overworld == nil, "E. game.overworld stays nil")
  check(ow ~= game.overworld, "E. not game.overworld")

  local npc = world.pokepcTrailers and world.pokepcTrailers[1]
  check(npc ~= nil, "F. trailer attached after FOLLOW")
  npc.cellX, npc.cellY = 10, 9
  npc.px, npc.py = 160, 144
  npc.moving = false
  player.cellX, player.cellY = 10, 10
  player.targetX, player.targetY = 10, 11
  player.facing = "down"
  player.moving = true
  player.stepFrames = 4
  world.pokepcTrailHead = { x = 10, y = 10 }
  world.pokepcTrailCells = { { x = 10, y = 9 } }
  world.game = game
  local startY = npc.cellY
  local before = follower.control.diag.controlUpdateCalls or 0
  local World = package.loaded["src.world.gen2.World"]
  World.step(world)
  eq(follower.control.diag.controlUpdateCalls, before + 1,
     "G. Gold World:step calls ControlEngine:update exactly once")
  local moved = npc.cellY ~= startY or npc.moving or npc.targetY
  check(moved, "G. Gold World:step produces follower movement")
  local pfBefore = follower.control.diag.controlUpdateCalls
  local pf = package.loaded["src.world.PikachuFollower"]
  pf.update(game, world)
  eq(follower.control.diag.controlUpdateCalls, pfBefore,
     "G. Gold PikachuFollower.update does not double-tick")
  follower:restore()
  end
end

----------------------------------------------------------------
-- Gold fingerprint: catchRate absent, DVs still unique (Gen1 key shape)
----------------------------------------------------------------
do
  local a = {
    species = "SENTRET", otId = 7, hp = 20, level = 5,
    dvs = { attack = 1, defense = 2, speed = 3, special = 4 },
  }
  local b = {
    species = "SENTRET", otId = 7, hp = 20, level = 5,
    dvs = { attack = 8, defense = 2, speed = 3, special = 4 },
  }
  local gen1 = {
    species = "PIDGEY", otId = 12345, catchRate = 255,
    dvs = { attack = 8, defense = 7, speed = 6, special = 5 },
  }
  check(Selection.monFingerprint(a) ~= Selection.monFingerprint(b),
        "10. two Gold Sentrets with different DVs differ")
  eq(Selection.monFingerprint(gen1),
     "PIDGEY:12345:8:7:6:5:255",
     "10. Gen1 fingerprint shape unchanged")
  eq(Selection.healthy(a), true, "4. Gold hp number is healthy")
  eq(Selection.healthy({ species = "SENTRET", hp = 0 }), false,
     "4. Gold hp 0 is fainted")
end

----------------------------------------------------------------
-- CONTROL=POKEMON land: Gen2 species (Sentret dex 161) and Gen1 species
-- (Pidgey) resolve a real image, never pokemon_missing.png. Gold uses
-- player:setSprite, not a registered SPRITE_PLAYER_POKEMON.
----------------------------------------------------------------
do
  local world, player = goldWorld()
  world.applyPlayerState = function(self, state)
    self.playerState = state or "normal"
    self._restoredTrainer = true
  end
  local sentret = healthy("SENTRET")
  local pidgey = healthy("PIDGEY")
  local game = goldGame(world, { sentret, pidgey })
  game.data.pokemon.PIDGEY = { name = "PIDGEY", dex = 16 }
  game.save.pokepcFollowerCount = 0
  game.save.pokepcControlMode = "pokemon"
  optionStore.follow_control = "pokemon"
  optionStore.follower_count = 0
  optionStore.trainer_trail = false
  V.mod.world = { game = game, overworld = function() return world end }
  V.mod.game = game
  local engine = makeEngine(0)
  engine._gameRef = game
  engine.settings = {
    followerCount = function() return 0 end,
    engineMode = function() return "pokemon" end,
    followControl = function() return "pokemon" end,
    alignSave = function() end,
  }
  engine.selection:selectFollower(sentret, game, {})
  engine:setLeaderParty(game, 1)
  engine:applyPlayerAsPokemon(game, world, true)
  eq(GameCompat.speciesId("SENTRET", game, V.mod), 161, "Sentret National Dex is 161")
  check(player.spriteDef ~= nil, "Gold player:setSprite wrote spriteDef")
  check(player.sprite ~= nil, "Gold player sprite renderer present")
  local def = player.spriteDef or (player.sprite and player.sprite.def)
  check(def and def.image, "Gold player SpriteDef has image")
  check(not tostring(def.image):find("pokemon_missing.png", 1, true),
        "Sentret player-controlled does not use pokemon_missing.png")
  check(def.id ~= "SPRITE_PLAYER_POKEMON" or def.image,
        "Gold does not require SPRITE_PLAYER_POKEMON registry")
  eq(player._pokepcAsPokemon, true, "Gold CONTROL=POKEMON marker set")
  eq(player._pokepcControlSpecies, "SENTRET", "Gold player species is SENTRET")

  engine.selection:selectFollower(pidgey, game, {})
  engine:setLeaderParty(game, 2)
  engine:applyPlayerAsPokemon(game, world, true)
  local def2 = player.spriteDef or (player.sprite and player.sprite.def)
  check(def2 and def2.image, "Pidgey-in-Gold player SpriteDef has image")
  check(not tostring(def2.image):find("pokemon_missing.png", 1, true),
        "Gen1 species player-mode in Gold does not use pokemon_missing.png")
  eq(player._pokepcControlSpecies, "PIDGEY", "Gold player species is PIDGEY")
  optionStore.follow_control = "trainer"
  optionStore.follower_count = 1
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll Gen2 follower tests passed.")
