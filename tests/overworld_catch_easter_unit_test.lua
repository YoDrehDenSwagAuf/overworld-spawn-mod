-- NPC / Town Pokémon throw easter eggs + path collision priority.
-- Run: lua tests/overworld_catch_easter_unit_test.lua
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

package.preload["src.inventory.Bag"] = function()
  return {
    remove = function(save, id, qty)
      local n = (save.inventory[id] or 0) - (qty or 1)
      if n <= 0 then save.inventory[id] = nil else save.inventory[id] = n end
    end,
  }
end
package.preload["src.battle.Catching"] = function()
  return {
    attempt = function() return true, 3 end,
  }
end
package.preload["src.render.TextBox"] = function()
  return {
    new = function(game, msg, onDone)
      game._lastText = msg
      game._textCount = (game._textCount or 0) + 1
      return { msg = msg, onDone = onDone, isOpaque = true }
    end,
  }
end
package.preload["src.render.Pipelines"] = function()
  return { setLevel = function() end, rows = function() return {} end }
end

local optionStore = {
  enabled = true, overworld_catching = true, wilds_ai = true, dev_overlay = false,
}
local game = {
  save = {
    inventory = { POKE_BALL = 20, GREAT_BALL = 0, ULTRA_BALL = 0, MASTER_BALL = 0 },
    party = {},
    options = { modOptions = { overworld_wild_spawns = optionStore } },
  },
  mods = { modOptions = { overworld_wild_spawns = optionStore } },
  data = { pokemon = { PIDGEY = { name = "PIDGEY", catchRate = 255 } } },
  audio = { playSfx = function() end },
  _textCount = 0,
}
game.stack = {
  _top = nil,
  top = function(self) return self._top end,
  push = function(self, box)
    self._top = box
    if box and box.msg then
      local cb = box.onDone
      self._top = game._ow
      if cb then cb() end
    end
  end,
}

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    options = {
      get = function(_, k)
        if optionStore[k] ~= nil then return optionStore[k] end
        return nil
      end,
    },
    world = { game = game, overworld = function() return game._ow end },
    assets = { path = function(_, rel) return rel end },
    content = {
      sprites = {
        _defs = {},
        get = function(self, id) return self._defs[id] end,
        register = function(self, id, def) self._defs[id] = def end,
      },
      render_pipelines = { register = function() end },
    },
    ui = {},
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
modules.debug_log = { warn = function() end, info = function() end, error = function() end }
modules.tile = { CELL = 16 }
modules.spawn_regions = {}
modules.cell_occupancy = {
  ownerKey = function() return nil end,
  isFollowerEntity = function() return false end,
  isBlockingEntity = function() return true end,
}
modules.surface = { WATER = "WATER", GRASS = "GRASS", CAVE = "CAVE", BEHAVIORS = {} }
modules.safari_compat = {
  STATUS = { INACTIVE = "INACTIVE", ACTIVE = "ACTIVE", FALLBACK_VANILLA = "FALLBACK_VANILLA" },
  LAND_WEIGHTS = { SAFARI_IDLE = 35, SAFARI_WANDER = 40, SAFARI_FLEE = 25 },
  status = function() return "INACTIVE" end,
  isSafariMap = function() return false end,
}
modules.movement = {
  stop = function() end,
  setFacing = function(e, f) e.facing = f end,
  init = function() end,
  STATE = { ALERT = "ALERT", IDLE = "IDLE", CATCHING = "CATCHING" },
}

local Config = V.require("config")
modules.config = Config
local Behavior = V.require("behavior")
modules.behavior = Behavior
local OverworldCatching = V.require("catching/init")
local Target = OverworldCatching.Target
local Hit = Target.HitKind

local logic = {
  entities = {},
  spawns = {},
  pendingBattle = nil,
  voxel = { unregister = function() end },
  occupancy = { releaseEntity = function() end },
  _despawn = function() end,
  _detachFromWorld = function(_, e) e.registeredInWorld = false end,
  _attach = function(_, e) e.registeredInWorld = true end,
  _onAggressiveAlert = function() end,
}
local catching = OverworldCatching.new(V.mod, logic)
logic.catching = catching
catching:registerContent()

local ow = {
  player = { cellX = 5, cellY = 5, facing = "right" },
  entities = {},
  npcs = {},
  map = { id = "PALLET_TOWN" },
  runner = { isRunning = function() return false end },
}
game._ow = ow
game.stack._top = ow

-- Legacy fixture (top-level index) — still supported.
local function placeHuman(x, y, id)
  local npc = {
    id = id or "npc_1",
    index = 12,
    cellX = x, cellY = y,
    facing = "down",
    sprite = { def = { walker = true } },
    name = "YOUNGSTER",
    trainer = true,
  }
  table.insert(ow.npcs, npc)
  table.insert(ow.entities, npc)
  return npc
end

-- Canonical Gen1Recomp NPC shape: index/trainer live on entity.def only
-- (see src/world/NPC.lua — NPC.new does NOT copy objDef.index to self.index).
local function placeNativePerson(x, y, opts)
  opts = opts or {}
  local index = opts.index or 3
  local npc = {
    id = opts.id or ("PALLET_TOWN_obj_" .. tostring(index)),
    def = {
      index = index,
      x = x,
      y = y,
      sprite = opts.spriteId or "SPRITE_GIRL",
      movement = opts.movement or "STAY",
      range = opts.range or "DOWN",
      text = opts.text or "TEXT_PALLETTOWN_GIRL",
      name = opts.name or "GIRL",
      trainerClass = opts.trainerClass,
      trainerParty = opts.trainerParty,
      item = opts.item,
      pokemon = opts.pokemon,
      pushable = opts.pushable,
    },
    cellX = x,
    cellY = y,
    facing = opts.facing or "down",
    sprite = { def = { walker = true, frames = 6 } },
    wanders = false,
  }
  if opts.trainerClass then
    -- Native trainers also only expose trainerClass on def, not entity.
  end
  table.insert(ow.npcs, npc)
  table.insert(ow.entities, npc)
  return npc
end

local function placeTown(x, y, id)
  local mon = {
    id = id or "town_1",
    cellX = x, cellY = y,
    facing = "left",
    sprite = {},
    wildsAmbientPokemon = true,
    ambientSpecies = "MEOWTH",
    overworldWildSpawn = false,
    visibleSprite = true,
  }
  table.insert(ow.entities, mon)
  return mon
end

local function placeWild(x, y, id)
  local ent = {
    id = id or "wild_1",
    cellX = x, cellY = y,
    species = "PIDGEY",
    level = 5,
    facing = "left",
    overworldWildSpawn = true,
    visibleSprite = true,
    canTriggerBattle = true,
    state = "available",
    behavior = Behavior.GRASS_WANDER,
  }
  Behavior.attach(ent, Behavior.GRASS_WANDER, nil, function() return 1 end)
  logic.entities[ent.id] = ent
  logic.spawns[ent.id] = {
    id = ent.id, mapId = "PALLET_TOWN", x = x, y = y,
    species = "PIDGEY", level = 5, state = Config.STATE.AVAILABLE,
    behavior = Behavior.GRASS_WANDER,
  }
  table.insert(ow.entities, ent)
  return ent
end

local function finishFlight()
  for _ = 1, 120 do
    catching.projectile:update(game, ow, 0.05, logic.voxel)
    if catching.phase == "idle" and not catching.projectile:isBusy() then break end
  end
end

-- Classifiers
check(Target.isHumanNpc(placeHuman(8, 5, "h0")), "trainer classified human")
ow.npcs, ow.entities = {}, {}
check(Target.isTownPokemon(placeTown(8, 5, "t0")), "ambient classified town")
ow.entities = {}
check(not Target.isHumanNpc(placeTown(8, 5, "t0b")), "town not human")
ow.entities = {}
check(not Target.isTownPokemon(placeWild(8, 5, "w0")), "wild not town")
logic.entities, logic.spawns, ow.entities = {}, {}, {}

-- NPC short throw: no hit
local npc = placeHuman(8, 5, "npc_short") -- dist 3
local hit = Target.scanThrowPath(logic, ow, ow.player, 2)
eq(hit.kind, Hit.NONE, "power 2 does not reach NPC at 3")
game._lastText = nil
game._textCount = 0
local before = catching:ballCount(game, "POKE_BALL")
catching.meter.active = true
catching.meter.power = 2
catching.phase = "metering"
catching:_releaseThrow(game, ow)
finishFlight()
eq(catching:ballCount(game, "POKE_BALL"), before - 1, "short throw still consumes")
check(game._lastText ~= "Ouch, yo, WTF", "short throw no NPC dialogue")
ow.npcs, ow.entities = {}, {}

-- NPC exact reach
npc = placeHuman(8, 5, "npc_hit")
hit = Target.scanThrowPath(logic, ow, ow.player, 3)
eq(hit.kind, Hit.NPC, "power 3 reaches NPC")
eq(hit.distance, 3, "NPC distance 3")
before = catching:ballCount(game, "POKE_BALL")
game._lastText = nil
catching.meter.active = true
catching.meter.power = 3
catching.phase = "metering"
catching:_releaseThrow(game, ow)
eq(catching.phase, "flying", "NPC hit starts flight")
finishFlight()
eq(game._lastText, "Ouch, yo, WTF", "NPC dialogue exact wording")
eq(catching:ballCount(game, "POKE_BALL"), before - 1, "NPC hit consumes ball")
check(not catching.projectile:isBusy(), "NPC hit cleans Ball")
check(npc.cellX == 8, "NPC stays in place")
ow.npcs, ow.entities = {}, {}

-- Town Pokémon
local town = placeTown(8, 5, "town_hit")
hit = Target.scanThrowPath(logic, ow, ow.player, 3)
eq(hit.kind, Hit.TOWN_MON, "town mon on path")
before = catching:ballCount(game, "POKE_BALL")
game._lastText = nil
catching.meter.active = true
catching.meter.power = 3
catching.phase = "metering"
catching:_releaseThrow(game, ow)
finishFlight()
eq(game._lastText, "Grrrr...", "town dialogue")
check(town.wildsAmbientPokemon == true, "town mon remains")
check(logic.entities["town_hit"] == nil, "town not in wilds entity table")
ow.entities = {}

-- Priority: NPC before wild behind it
npc = placeHuman(8, 5, "npc_first") -- dist 3
local wild = placeWild(10, 5, "wild_behind") -- dist 5
hit = Target.scanThrowPath(logic, ow, ow.player, 6)
eq(hit.kind, Hit.NPC, "NPC wins over wild behind")
eq(hit.entity, npc, "NPC entity selected")
game._lastText = nil
catching.meter.active = true
catching.meter.power = 6
catching.phase = "metering"
catching:_releaseThrow(game, ow)
finishFlight()
eq(game._lastText, "Ouch, yo, WTF", "NPC dialogue when ahead of wild")
check(logic.entities["wild_behind"] ~= nil, "wild behind untouched")
logic.entities, logic.spawns, ow.entities, ow.npcs = {}, {}, {}, {}

-- Priority: Town before NPC behind it
town = placeTown(7, 5, "town_first") -- dist 2
npc = placeHuman(9, 5, "npc_second") -- dist 4
hit = Target.scanThrowPath(logic, ow, ow.player, 6)
eq(hit.kind, Hit.TOWN_MON, "town before NPC")
eq(hit.distance, 2, "town at 2")
game._lastText = nil
catching.meter.active = true
catching.meter.power = 6
catching.phase = "metering"
catching:_releaseThrow(game, ow)
finishFlight()
eq(game._lastText, "Grrrr...", "town dialogue beats NPC behind")

-- Uncertain entity: sign-like without trainer/index sprite → not human
local sign = { id = "sign", cellX = 8, cellY = 5, name = "SIGN" }
ow.entities = { sign }
check(not Target.isHumanNpc(sign), "uncertain sign not human")
ow.npcs, ow.entities = {}, {}

-- ---- Native Gen1Recomp NPC.def identity (the real bug) ----
local nativePerson = placeNativePerson(8, 5, { id = "native_girl", index = 4 })
check(nativePerson.index == nil, "native NPC has no top-level index")
check(type(nativePerson.def.index) == "number", "native NPC index lives on def")
check(Target.isHumanNpc(nativePerson), "native person classified human")
hit = Target.scanThrowPath(logic, ow, ow.player, 3)
eq(hit.kind, Hit.NPC, "native person HitKind.NPC at dist 3")
eq(hit.entity, nativePerson, "native person entity selected")
eq(hit.distance, 3, "native person distance 3")
local originalText = nativePerson.def.text
game._lastText = nil
catching.meter.active = true
catching.meter.power = 3
catching.phase = "metering"
catching:_releaseThrow(game, ow)
finishFlight()
eq(game._lastText, "Ouch, yo, WTF", "native person dialogue")
eq(nativePerson.def.text, originalText, "NPC def.text unchanged after impact")
eq(nativePerson.cellX, 8, "native person unmoved")
ow.npcs, ow.entities = {}, {}

-- Native trainer (trainerClass only on def)
local nativeTrainer = placeNativePerson(8, 5, {
  id = "native_trainer", index = 7,
  spriteId = "SPRITE_YOUNGSTER",
  trainerClass = "YOUNGSTER",
  trainerParty = 1,
  text = "TEXT_ROUTE1_YOUNGSTER",
})
check(nativeTrainer.trainerClass == nil, "trainerClass not on entity top-level")
check(nativeTrainer.def.trainerClass == "YOUNGSTER", "trainerClass on def")
check(Target.isHumanNpc(nativeTrainer), "native trainer classified human")
hit = Target.scanThrowPath(logic, ow, ow.player, 3)
eq(hit.kind, Hit.NPC, "native trainer HitKind.NPC")
game._lastText = nil
catching.meter.active = true
catching.meter.power = 3
catching.phase = "metering"
catching:_releaseThrow(game, ow)
finishFlight()
eq(game._lastText, "Ouch, yo, WTF", "native trainer dialogue")
eq(nativeTrainer.def.trainerClass, "YOUNGSTER", "trainer def unchanged")
ow.npcs, ow.entities = {}, {}

-- Item ball / boulder / static map mon must NOT be human
local itemBall = placeNativePerson(8, 5, {
  id = "item_ball", index = 9, spriteId = "SPRITE_BALL", item = "POTION",
})
check(not Target.isHumanNpc(itemBall), "item ball not human")
ow.npcs, ow.entities = {}, {}
local boulder = placeNativePerson(8, 5, {
  id = "boulder", index = 10, spriteId = "SPRITE_BOULDER", pushable = true,
})
check(not Target.isHumanNpc(boulder), "boulder not human")
ow.npcs, ow.entities = {}, {}
local staticMon = placeNativePerson(8, 5, {
  id = "static_mewtwo", index = 11, spriteId = "SPRITE_SLOWBRO",
  pokemon = "MEWTWO",
})
check(not Target.isHumanNpc(staticMon), "static map pokemon not human")
ow.npcs, ow.entities = {}, {}

-- Follower must never be human
local follower = placeNativePerson(8, 5, { id = "follower", index = 20 })
follower.wildsFollower = true
follower.isFollower = true
check(not Target.isHumanNpc(follower), "follower not human")
hit = Target.scanThrowPath(logic, ow, ow.player, 3)
eq(hit.kind, Hit.NONE, "follower does not produce NPC hit")
ow.npcs, ow.entities = {}, {}

-- Wild still WILD; Town still TOWN_MON with native person behind
local wildFront = placeWild(7, 5, "wild_front") -- dist 2
local personBehind = placeNativePerson(9, 5, { id = "person_behind", index = 5 })
hit = Target.scanThrowPath(logic, ow, ow.player, 6)
eq(hit.kind, Hit.WILD, "wild before native person")
eq(hit.entity, wildFront, "wild entity first")
logic.entities, logic.spawns, ow.entities, ow.npcs = {}, {}, {}, {}
local townFront = placeTown(7, 5, "town_front2")
personBehind = placeNativePerson(9, 5, { id = "person_behind2", index = 6 })
hit = Target.scanThrowPath(logic, ow, ow.player, 6)
eq(hit.kind, Hit.TOWN_MON, "town before native person")
eq(hit.entity, townFront, "town entity first")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("overworld_catch_easter_unit_test: all passed")
