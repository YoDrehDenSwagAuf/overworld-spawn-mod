-- Gold party FOLLOW via the REAL Gen2 PartyMenu Runtime.call path.
-- Also locks Gen1 FOLLOW/DISMISS labels and the support-cache install fix.
-- Run: luajit tests/gen2_party_follow_unit_test.lua
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

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function engineRoot()
  local env = os.getenv("GEN1RECOMP_ROOT")
  if type(env) == "string" and env ~= "" and readFile(env .. "/src/ui/gen2/PartyMenu.lua") then
    return env
  end
  for _, root in ipairs({ ".deps/gen1recomp", "/tmp/gen1recomp-src" }) do
    if readFile(root .. "/src/ui/gen2/PartyMenu.lua") then return root end
  end
  return nil
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
package.loaded["src.world.NPC"] = {
  new = function(_, mapId, def)
    return {
      id = "WILDS_TRAILER_" .. tostring(def and def.index or 0),
      mapId = mapId,
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
  follower_count = 0,
  follow_control = "trainer",
  trainer_trail = false,
  sprite_style = "followers",
  debug_logging = true,
  dev_overlay = true,
}
local submenuWrap
local modules = {}
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end, error = function() end },
    find = function() return nil end,
    options = {
      get = function(_, k) return optionStore[k] end,
      -- Gen1Recomp has no :set. Keep it absent for the settings audit.
    },
    events = {
      on = function() return function() end end,
    },
    hooks = {
      wrap = function(_, name, fn)
        if name == "ui.party.submenu" then submenuWrap = fn end
      end,
    },
    world = { game = nil, overworld = function() return nil end },
    save = { get = function() return nil end, set = function() end },
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
  DEFAULTS = optionStore,
  get = function(_, k) return optionStore[k] end,
  setOption = function(_, key, value)
    optionStore[key] = value
    return true
  end,
  spriteStyle = function() return "followers" end,
  normalizeSpriteStyle = function(s) return s or "followers" end,
  pokemonSizeMode = function() return "classic" end,
  debug = function() return true end,
  devOverlay = function() return true end,
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end,
  debug = function() end,
  enabled = function() return true end,
  followerGen2 = function() end,
}

local GameCompat = V.require("game_compat")
local Selection = V.require("follower/selection")
local Follower = V.require("follower/init")
local SettingsMenus = V.require("settings_menus")

local function goldMon(species, extra)
  extra = extra or {}
  return {
    species = species,
    hp = extra.hp or 22,
    maxHp = extra.maxHp or 22,
    level = extra.level or 5,
    nickname = extra.nickname,
    otId = extra.otId or 3112,
    dvs = extra.dvs or { attack = 8, defense = 7, speed = 6, special = 5, hp = 15 },
    -- Gold Mon.new does not set catchRate.
    moves = extra.moves or {},
    isEgg = extra.isEgg,
  }
end

local function goldWorld()
  local player = { cellX = 10, cellY = 10, px = 160, py = 160, facing = "down", moving = false }
  local world = {
    map = {
      id = "ROUTE_29",
      inBounds = function() return true end,
      isWalkableCell = function() return true end,
      isWaterCell = function() return false end,
    },
    player = player,
    playerState = "normal",
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
      party = party,
      playerState = "normal",
      pokepcFollowerCount = 0,
    },
    world = world,
    data = {
      sprites = { SPRITE_PIKACHU = { id = "SPRITE_PIKACHU", image = "x.png", frames = 6 } },
      pokemon = { SENTRET = { name = "SENTRET", dex = 161 }, CHIKORITA = { name = "CHIKORITA", dex = 152 } },
      moves = {},
    },
    stack = { push = function() end },
  }
end

-- Mini Hooks:call matching src/mods/Hooks.lua + Runtime.call arity.
local function runtimeCall(vanilla, ...)
  check(type(submenuWrap) == "function", "Wilds ui.party.submenu wrap installed")
  return submenuWrap(vanilla, ...)
end

----------------------------------------------------------------
-- Engine source proof: Gold PartyMenu uses the shared hook + payload
----------------------------------------------------------------
local root = engineRoot()
local src
if root then
  src = readFile(root .. "/src/ui/gen2/PartyMenu.lua")
end
check(src ~= nil, "Gen2 PartyMenu.lua available")
if src then
  check(src:find('Runtime.call%("ui.party.submenu"', 1) ~= nil,
        "Gold PartyMenu calls Runtime.call ui.party.submenu")
  check(src:find("self.game, items, mon, ctx", 1, true) ~= nil,
        "Gold PartyMenu payload is (game, items, mon, ctx)")
  check(src:find("same hook name", 1, true) ~= nil
        or src:find("same %(game, items, mon, ctx%) payload", 1) ~= nil,
        "Gold documents the shared Gen1 hook contract")
end

----------------------------------------------------------------
-- Install Wilds follower against a live Gold game
----------------------------------------------------------------
local world = select(1, goldWorld())
local sentret = goldMon("SENTRET")
local fainted = goldMon("CHIKORITA", { hp = 0, otId = 99 })
local game = goldGame(world, { sentret, fainted })
V.mod.world = { game = game, overworld = function() return world end }
V.mod.game = game
V.mod.options.set = nil

local follower = Follower.new(V.mod, {})
check(follower._supported == nil, "support is not cached at Follower.new")
local installed = follower:install({ game = game })
check(installed == true, "Follower:install(Gold)")
eq(follower._supported, true, "support evaluated at install")

-- Gold PartyMenu:submenuItems identity vanilla.
local function sameItems(_, items) return items end

local function goldVanillaRows(mon)
  if mon and mon.isEgg then
    return {
      { id = "STATS", label = "STATS" },
      { id = "SWITCH", label = "SWITCH" },
      { id = "CANCEL", label = "CANCEL" },
    }
  end
  return {
    { id = "STATS", label = "STATS" },
    { id = "SWITCH", label = "SWITCH" },
    { id = "MOVE", label = "MOVE" },
    { id = "ITEM", label = "ITEM" },
    { id = "CANCEL", label = "CANCEL" },
  }
end

local function labelsOf(rows)
  local out = {}
  for _, row in ipairs(rows or {}) do out[#out + 1] = tostring(row.label) end
  return table.concat(out, ",")
end

local function hasLabel(rows, want)
  for _, row in ipairs(rows or {}) do
    if row.label == want then return row end
  end
  return nil
end

----------------------------------------------------------------
-- A. Real Runtime.call arity against Wilds wrap
----------------------------------------------------------------
do
  local vanilla = goldVanillaRows(sentret)
  local ctx = { battle = false, overworld = game.world }
  local hooked = runtimeCall(sameItems, game, vanilla, sentret, ctx)
  check(hasLabel(hooked, "FOLLOW") ~= nil,
        "A. Runtime.call arity appends FOLLOW (" .. labelsOf(hooked) .. ")")
end

----------------------------------------------------------------
-- Optional: load the real Gen2 PartyMenu class and call submenuItems
----------------------------------------------------------------
if root then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
  package.loaded["src.render.Assets"] = package.loaded["src.render.Assets"] or {}
  package.loaded["src.ui.gen2.Chrome"] = package.loaded["src.ui.gen2.Chrome"] or {}
  package.loaded["src.render.Font"] = package.loaded["src.render.Font"] or {}
  package.loaded["src.render.GbcPalette"] = package.loaded["src.render.GbcPalette"] or {}
  package.loaded["src.battle.gen2.HpBar"] = package.loaded["src.battle.gen2.HpBar"] or {}
  package.loaded["src.core.Logger"] = package.loaded["src.core.Logger"]
    or { error = function() end, warn = function() end, info = function() end }
  package.loaded["src.core.gen2.Mail"] = { monHoldsMail = function() return false end }
  package.loaded["src.battle.gen2.Mon"] = {
    refreshStats = function() end,
    stampOT = function(_, mon) return mon end,
  }
  package.loaded["src.mods.Runtime"] = {
    call = function(name, vanilla, ...)
      eq(name, "ui.party.submenu", "real PartyMenu hook name")
      return runtimeCall(vanilla, ...)
    end,
    wants = function() return false end,
    wantsHook = function() return true end,
  }
  package.loaded["src.ui.Screens"] = { push = function() end }
  local okLoad, PartyMenu = pcall(function()
    package.loaded["src.ui.gen2.PartyMenu"] = nil
    return assert(loadfile(root .. "/src/ui/gen2/PartyMenu.lua"))()
  end)
  check(okLoad and type(PartyMenu) == "table" and PartyMenu.submenuItems ~= nil,
        "loaded real Gen2 PartyMenu (" .. tostring(PartyMenu) .. ")")
  if okLoad and PartyMenu and PartyMenu.submenuItems then
    local menu = PartyMenu.new(game, { party = game.save.party, submenu = true })
    local rows = menu:submenuItems(sentret)
    check(hasLabel(rows, "FOLLOW") ~= nil,
          "A. real PartyMenu:submenuItems appends FOLLOW (" .. labelsOf(rows) .. ")")
    local faintRows = menu:submenuItems(fainted)
    check(hasLabel(faintRows, "FOLLOW") == nil,
          "B. real PartyMenu fainted mon has no FOLLOW")
  end
end

----------------------------------------------------------------
-- B. Fainted Gold mon (shared wrap, Gen1-identical healthy() rule)
----------------------------------------------------------------
do
  local vanilla = goldVanillaRows(fainted)
  local hooked = runtimeCall(sameItems, game, vanilla, fainted, { battle = false })
  check(hasLabel(hooked, "FOLLOW") == nil, "B. fainted Gold mon has no FOLLOW")
end

----------------------------------------------------------------
-- C. FOLLOW persists selection on Wilds state + save mirror
----------------------------------------------------------------
do
  local vanilla = goldVanillaRows(sentret)
  local hooked = runtimeCall(sameItems, game, vanilla, sentret, { battle = false })
  local follow = hasLabel(hooked, "FOLLOW")
  check(follow ~= nil, "C. FOLLOW row")
  follow.onSelect(sentret, game)
  eq(follower.selection.state.selectedSlot, 1, "C. selectedSlot=1")
  check(follower.selection.state.selectedMonKey ~= nil, "C. selectedMonKey set")
  eq(game.save.followerPartyIndex, 1, "C. followerPartyIndex mirrored")
  check((game.save.pokepcFollowerCount or 0) >= 1, "C. follower_count >= 1")
  eq(#(world.pokepcTrailers or {}), 1, "F. trailer spawned")
  local npc = world.pokepcTrailers[1]
  eq(npc.pokepcTrailer, true, "F. pokepcTrailer")
  eq(npc.overworldWildSpawn, false, "F. not a wild spawn")
  local ow = GameCompat.liveOverworld(V.mod, game)
  check(ow == world, "E. liveOverworld is game.world")
  check(game.overworld == nil, "E. game.overworld is nil")
end

----------------------------------------------------------------
-- D. DISMISS clears selection
----------------------------------------------------------------
do
  local vanilla = goldVanillaRows(sentret)
  local hooked = runtimeCall(sameItems, game, vanilla, sentret, { battle = false })
  local dismiss = hasLabel(hooked, "DISMISS")
  check(dismiss ~= nil, "D. DISMISS row after FOLLOW")
  dismiss.onSelect(sentret, game)
  eq(follower.selection.state.selectedMonKey, nil, "D. selectedMonKey cleared")
  eq(follower.selection.state.selectedSlot, nil, "D. selectedSlot cleared")
  eq(game.save.pokepcFollowerCount, 0, "D. follower count 0")
  eq(#(world.pokepcTrailers or {}), 0, "D. trailer removed")
end

----------------------------------------------------------------
-- 7 / 8. Settings: Config.setOption is canonical without options:set
----------------------------------------------------------------
do
  check(V.mod.options.set == nil, "8. no mod.options:set (engine parity)")
  local menus = SettingsMenus.new(V.mod, { onOptionsChanged = function() end }, follower, nil)
  menus:setOptionsChangedHandler(function(payload)
    follower:onOptionsChanged(payload)
  end)
  menus:_applyFollowerCount(game, 3)
  eq(optionStore.follower_count, 3, "13. FOLLOWERS writes Config bucket")
  eq(game.save.pokepcFollowerCount, 3, "9. pokepcFollowerCount mirrored")
  menus:_applyControlMode(game, "pokemon")
  eq(optionStore.follow_control, "pokemon", "14. CONTROL writes Config bucket")
  menus:_applyTrainerTrail(game, true)
  eq(optionStore.trainer_trail, true, "15. TRAIL writes Config bucket")
  menus:_applyControlMode(game, "trainer")
  menus:_applyTrainerTrail(game, false)
  menus:_applyFollowerCount(game, 1)
end

----------------------------------------------------------------
-- J. Red FOLLOW/DISMISS labels unchanged
----------------------------------------------------------------
do
  package.loaded["src.core.GameVersion"] = {
    get = function() return "red" end,
    isYellow = function() return false end,
    generation = function() return 1 end,
  }
  local ow = {
    map = { id = "PALLET_TOWN", inBounds = function() return true end,
            isWalkableCell = function() return true end,
            isWaterCell = function() return false end },
    player = { cellX = 5, cellY = 5, px = 80, py = 80, facing = "down" },
    npcs = {}, entities = {},
  }
  local redMon = {
    species = "CHARMANDER", hp = 20, level = 5, otId = 1, catchRate = 45,
    dvs = { attack = 8, defense = 8, speed = 8, special = 8 },
  }
  local redGame = {
    generation = 1, version = "red",
    overworld = ow,
    save = { party = { redMon }, pokepcFollowerCount = 0 },
    data = { sprites = { SPRITE_PIKACHU = { id = "SPRITE_PIKACHU" } },
             pokemon = { CHARMANDER = { name = "CHARMANDER", dex = 4 } } },
    stack = { push = function() end },
  }
  submenuWrap = nil
  V.mod.game = redGame
  V.mod.world = { game = redGame, overworld = function() return ow end }
  local redFollower = Follower.new(V.mod, {})
  local ok = redFollower:install({ game = redGame })
  check(ok == true, "J. Red Follower:install")
  local vanilla = goldVanillaRows(redMon)
  local hooked = submenuWrap(sameItems, redGame, vanilla, redMon, { battle = false })
  check(hasLabel(hooked, "FOLLOW") ~= nil, "J. Red FOLLOW label unchanged")
  hasLabel(hooked, "FOLLOW").onSelect(redMon, redGame)
  local hooked2 = submenuWrap(sameItems, redGame, vanilla, redMon, { battle = false })
  check(hasLabel(hooked2, "DISMISS") ~= nil, "J. Red DISMISS label unchanged")
  eq(GameCompat.liveOverworld(V.mod, redGame), ow, "J. Red liveOverworld is OverworldState")
  hasLabel(hooked2, "DISMISS").onSelect(redMon, redGame)
  redFollower:restore()

  package.loaded["src.core.GameVersion"] = {
    get = function() return "blue" end,
    isYellow = function() return false end,
    generation = function() return 1 end,
  }
  redGame.version = "blue"
  redGame.save.pokepcFollowerCount = 0
  redGame.save.followerPartyIndex = nil
  submenuWrap = nil
  local blueFollower = Follower.new(V.mod, {})
  check(blueFollower:install({ game = redGame }) == true, "K. Blue install")
  local hookedB = submenuWrap(sameItems, redGame, vanilla, redMon, { battle = false })
  check(hasLabel(hookedB, "FOLLOW") ~= nil, "K. Blue FOLLOW unchanged")
  blueFollower:restore()

  package.loaded["src.core.GameVersion"] = {
    get = function() return "yellow" end,
    isYellow = function() return true end,
    generation = function() return 1 end,
  }
  redGame.version = "yellow"
  redGame.save.pokepcFollowerCount = 0
  submenuWrap = nil
  local yelFollower = Follower.new(V.mod, {})
  check(yelFollower:install({ game = redGame }) == true, "L. Yellow install")
  local hookedY = submenuWrap(sameItems, redGame, vanilla, redMon, { battle = false })
  check(hasLabel(hookedY, "FOLLOW") ~= nil, "L. Yellow FOLLOW unchanged")
  yelFollower:restore()
end

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll Gen2 party FOLLOW tests passed.")
