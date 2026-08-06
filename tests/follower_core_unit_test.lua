-- Unified follower core unit tests (PR 1).
-- Run: lua tests/follower_core_unit_test.lua
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

local saveStore = {}
local modules = {}
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end },
    find = function() return nil end,
    save = {
      get = function(_, k) return saveStore[k] end,
      set = function(_, k, v) saveStore[k] = v end,
    },
    hooks = nil,
    events = nil,
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
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
    follow_control = "trainer",
    trainer_trail = false,
    follower_count = 1,
  },
  get = function(_, k)
    return modules.config.DEFAULTS[k]
  end,
  spriteStyle = function() return "pokemmo" end,
  debug = function() return false end,
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end, debug = function() end,
}

local Constants = V.require("follower/constants")
local State = V.require("follower/state")
local Selection = V.require("follower/selection")
local Compatibility = V.require("follower/compatibility")
local Lifecycle = V.require("follower/lifecycle")
local Follower = V.require("follower/init")

----------------------------------------------------------------
-- Fingerprint
----------------------------------------------------------------
do
  local monA = {
    species = "PIDGEY",
    otId = 12345,
    catchRate = 255,
    dvs = { attack = 8, defense = 7, speed = 6, special = 5 },
    hp = 20,
  }
  local monB = {
    species = "PIDGEY",
    otId = 12345,
    catchRate = 255,
    dvs = { attack = 8, defense = 7, speed = 6, special = 5 },
    hp = 10,
  }
  local monC = {
    species = "PIDGEY",
    otId = 99999,
    catchRate = 255,
    dvs = { attack = 1, defense = 1, speed = 1, special = 1 },
    hp = 20,
  }
  eq(Selection.monFingerprint(monA), Selection.monFingerprint(monB),
     "identical DV/OT/catchRate share fingerprint")
  check(Selection.monFingerprint(monA) ~= Selection.monFingerprint(monC),
        "different OT/DVs produce different fingerprints")
  check(Selection.healthy(monA) == true, "healthy mon")
  check(Selection.healthy({ hp = 0 }) == false, "fainted not healthy")
end

----------------------------------------------------------------
-- Selection persistence + slot fallback
----------------------------------------------------------------
do
  saveStore = {}
  V.mod.save.get = function(_, k) return saveStore[k] end
  V.mod.save.set = function(_, k, v) saveStore[k] = v end

  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  local mon1 = {
    species = "CHARMANDER", otId = 1, catchRate = 45, hp = 20,
    dvs = { attack = 10, defense = 10, speed = 10, special = 10 },
  }
  local mon2 = {
    species = "SQUIRTLE", otId = 2, catchRate = 45, hp = 20,
    dvs = { attack = 5, defense = 5, speed = 5, special = 5 },
  }
  local game = { save = { party = { mon1, mon2 } } }

  local ok = selection:selectFollower(mon2, game)
  check(ok == true, "selectFollower succeeds")
  eq(state.selectedSlot, 2, "selected_slot persisted")
  eq(state.selectedMonKey, Selection.monFingerprint(mon2), "selected_mon persisted")

  -- Party sort: swap slots, fingerprint must recover mon2 at new index.
  game.save.party = { mon2, mon1 }
  local active, slot = selection:getActiveFollowerMon(game, true)
  eq(active, mon2, "fingerprint recovers after party sort")
  eq(slot, 1, "slot hint updated after sort")
  eq(state.selectedSlot, 1, "persisted slot refreshed")
end

----------------------------------------------------------------
-- Healthy fallback + empty party + fainted selection
----------------------------------------------------------------
do
  saveStore = {}
  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  local fainted = {
    species = "RATTATA", otId = 3, catchRate = 255, hp = 0,
    dvs = { attack = 1, defense = 1, speed = 1, special = 1 },
  }
  local healthy = {
    species = "PIDGEY", otId = 4, catchRate = 255, hp = 12,
    dvs = { attack = 2, defense = 2, speed = 2, special = 2 },
  }
  selection:selectFollower(fainted, { save = { party = { fainted, healthy } } })
  -- selectFollower rejects fainted
  check(state.selectedMonKey == nil, "cannot select fainted mon")

  state:setSelection(Selection.monFingerprint(fainted), 1)
  local game = { save = { party = { fainted, healthy } } }
  local active = selection:getActiveFollowerMon(game, true)
  eq(active, healthy, "needHealthy skips fainted selected mon via scan miss then fallback")
  -- getActiveFollowerMon with selected fainted key: scan won't find healthy match
  -- for that key, falls through to first healthy
  active = selection:getActiveFollowerMon(game, true)
  eq(active.species, "PIDGEY", "first healthy fallback species")

  game.save.party = {}
  check(selection:getActiveFollowerMon(game, true) == nil, "empty party → nil")
end

----------------------------------------------------------------
-- Migration of legacy save keys (once)
----------------------------------------------------------------
do
  saveStore = {
    selected_mon = "1:8:7:6:5:255",
    selected_slot = 2,
  }
  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  local compat = Compatibility.new(V.mod, state)
  eq(state.migrated, false, "not migrated yet")
  local imported, reason = compat:migrateSelection(nil, selection)
  check(imported == true, "legacy selected_mon imported")
  eq(state.selectedMonKey, "1:8:7:6:5:255", "migrated fingerprint")
  eq(tonumber(state.selectedSlot), 2, "migrated slot")
  check(state.migrated == true, "migration flagged")
  local imported2 = compat:migrateSelection(nil, selection)
  check(imported2 == false, "migration runs only once")
  -- Legacy keys must still exist.
  eq(saveStore.selected_mon, "1:8:7:6:5:255", "legacy key not deleted")
end

----------------------------------------------------------------
-- Legacy game.save.followerPartyIndex migration
----------------------------------------------------------------
do
  saveStore = {}
  local state = State.new(V.mod)
  local selection = Selection.new(V.mod, state)
  local compat = Compatibility.new(V.mod, state)
  local mon = {
    species = "BULBASAUR", otId = 7, catchRate = 45, hp = 20,
    dvs = { attack = 4, defense = 4, speed = 4, special = 4 },
  }
  local game = { save = { party = { mon }, followerPartyIndex = 1 } }
  local imported = compat:migrateSelection(game, selection)
  check(imported == true, "followerPartyIndex migrated")
  eq(state.selectedMonKey, Selection.monFingerprint(mon), "index → fingerprint")
end

----------------------------------------------------------------
-- Single-owner: Wilds always owns; legacy mods are migration-only
----------------------------------------------------------------
do
  V.mod.find = function(_, id)
    if id == "FOLLOWERS_EX" then
      return {
        id = id,
        version = "1.0.19",
        exports = {
          _followersExControlEngine = true,
          getActiveFollowerMon = function() end,
          setControlMode = function() end,
          syncTrailers = function() end,
        },
      }
    end
    return nil
  end
  saveStore = {}
  local state = State.new(V.mod)
  local compat = Compatibility.new(V.mod, state)
  local mode, detected = compat:resolveOwnerMode()
  eq(mode, Constants.OWNER.wilds, "FOLLOWERS_EX present → Wilds still owns")
  eq(detected, "FOLLOWERS_EX", "detected id")
  local msg = compat:logExternalOwnerWarning(detected)
  check(msg:find("Legacy follower mod detected", 1, true) ~= nil,
        "warning mentions legacy detection")
  check(msg:find("Wilds now owns follower runtime", 1, true) ~= nil,
        "warning asserts Wilds runtime ownership")

  -- Lifecycle hooks still install (control engine may wrap instead at runtime).
  local selection = Selection.new(V.mod, state)
  local life = Lifecycle.new(V.mod, state, selection)
  -- Without PikachuFollower module, install returns no_pikachu_follower.
  local ok, reason = life:installHooks()
  check(ok == false or ok == true, "lifecycle install does not hard-crash")
  check(reason == "no_pikachu_follower" or reason == "installed" or reason == "already",
        "lifecycle install reason ok: " .. tostring(reason))
end

----------------------------------------------------------------
-- Hot-reload / idempotent restore (mocked PikachuFollower)
----------------------------------------------------------------
do
  V.mod.find = function() return nil end
  saveStore = {}
  package.loaded["src.world.PikachuFollower"] = nil

  local calls = { shouldSpawn = 0 }
  local function vanillaShouldSpawn()
    calls.shouldSpawn = calls.shouldSpawn + 1
    return true
  end
  local function makeUpdate()
    local shouldSpawn = vanillaShouldSpawn
    return function(game, ow)
      return shouldSpawn(game, ow)
    end
  end

  local PF = {
    update = makeUpdate(),
    onMapEntered = function() end,
    talk = function() end,
    starterInParty = function() end,
    current = function() return nil end,
  }
  package.preload["src.world.PikachuFollower"] = function() return PF end
  -- Also support require path via package.loaded for tryRequire pcall(require)
  package.loaded["src.world.PikachuFollower"] = PF

  -- Upvalue name must be shouldSpawn for replaceUpvalue to work.
  -- Recreate update with named upvalue:
  local function buildUpdateWithUpvalue(spawnFn)
    local shouldSpawn = spawnFn
    return function(game, ow)
      return shouldSpawn(game, ow)
    end
  end
  PF.update = buildUpdateWithUpvalue(vanillaShouldSpawn)

  local state = State.new(V.mod)
  state.ownerMode = Constants.OWNER.wilds
  local selection = Selection.new(V.mod, state)
  local life = Lifecycle.new(V.mod, state, selection)
  local refreshCount = 0
  life:setSpriteRefreshHandler(function()
    refreshCount = refreshCount + 1
  end)

  local ok1, r1 = life:installHooks()
  check(ok1 == true, "first hook install")
  check(rawget(PF, Constants.STATE_KEY) ~= nil, "state key set")

  local ok2, r2 = life:installHooks()
  eq(r2, "already", "second install is idempotent")

  -- Re-install after restore should not chain wrappers.
  life:restoreHooks()
  check(rawget(PF, Constants.STATE_KEY) == nil, "state key cleared on restore")
  local ok3 = life:installHooks()
  check(ok3 == true, "reinstall after restore")
  life:restoreHooks()
  package.loaded["src.world.PikachuFollower"] = nil
  package.preload["src.world.PikachuFollower"] = nil
end

----------------------------------------------------------------
-- Map change without double entity + renderer rebuild guard
----------------------------------------------------------------
do
  V.mod.find = function() return nil end
  saveStore = {}
  local state = State.new(V.mod)
  state.ownerMode = Constants.OWNER.wilds
  local selection = Selection.new(V.mod, state)
  local life = Lifecycle.new(V.mod, state, selection)

  local mon = {
    species = "EEVEE", otId = 9, catchRate = 45, hp = 30,
    dvs = { attack = 9, defense = 9, speed = 9, special = 9 },
  }
  selection:selectFollower(mon, { save = { party = { mon } } })

  local rendererNews = 0
  package.loaded["src.render.SpriteRenderer"] = {
    new = function(def, id)
      rendererNews = rendererNews + 1
      return { def = def, id = id, image = "img" }
    end,
  }

  local entity = {
    id = "pikachu",
    wildsFollower = true,
    pikachuFollower = true,
    facing = "down",
    cellX = 5, cellY = 5,
    sprite = {
      def = { image = "path/a.png", frames = 6, walker = true },
      image = "img",
    },
  }
  local ow = { entities = { entity }, player = { surfing = false } }
  local game = {
    data = { sprites = { SPRITE_PIKACHU = { image = "path/a.png", frames = 6, walker = true } } },
    save = { party = { mon }, onBike = false },
  }

  -- Unchanged def → no SpriteRenderer.new
  local before = rendererNews
  local applied, why = life:applyLocalSpriteDef(entity, {
    image = "path/a.png", frames = 6, walker = true,
  })
  eq(why, "unchanged", "unchanged def skips renderer rebuild")
  eq(rendererNews, before, "SpriteRenderer.new = 0 when def unchanged")

  -- Species change → exactly one new
  applied, why = life:applyLocalSpriteDef(entity, {
    image = "path/b.png", frames = 6, walker = true,
  })
  check(applied == true, "rebinding on image change")
  eq(rendererNews, before + 1, "SpriteRenderer.new = 1 on party sprite change")

  -- Map enter must not reset selection.
  local keyBefore = state.selectedMonKey
  life:onMapEntered(game, ow)
  eq(state.selectedMonKey, keyBefore, "map enter preserves selection")

  -- Bike despawn path
  game.save.onBike = true
  check(life:shouldSpawn(game, ow) == false, "bike → no spawn")
  game.save.onBike = false
  ow.player.surfing = true
  check(life:shouldSpawn(game, ow) == false, "surf → no spawn")
  ow.player.surfing = false
  check(life:shouldSpawn(game, ow) == true, "land + healthy → spawn")

  -- Purge must not remove EX trailers
  local trailer = { id = "t1", pokepcTrailer = true }
  ow.entities = { entity, trailer }
  life:purgeFollowerEntities(ow)
  local stillTrailer = false
  for _, e in ipairs(ow.entities) do
    if e.pokepcTrailer then stillTrailer = true end
  end
  check(stillTrailer == true, "purge preserves Followers EX trailers")

  package.loaded["src.render.SpriteRenderer"] = nil
end

----------------------------------------------------------------
-- Follower facade: deferred external + wilds install
----------------------------------------------------------------
do
  V.mod.find = function() return nil end
  saveStore = {}
  -- Provide options stub for settings migration.
  V.mod.options = {
    get = function() return nil end,
    set = function() end,
  }
  package.loaded["src.world.PikachuFollower"] = {
    update = function() end,
    onMapEntered = function() end,
    talk = function() end,
    starterInParty = function() end,
    current = function() return nil end,
  }
  -- Give update a shouldSpawn upvalue
  do
    local shouldSpawn = function() return true end
    package.loaded["src.world.PikachuFollower"].update = function(g, o)
      return shouldSpawn(g, o)
    end
  end

  local follower = Follower.new(V.mod, {})
  local ok, reason = follower:install({})
  check(ok == true, "wilds install ok")
  local snap = follower:snapshot()
  eq(snap.ownerMode, Constants.OWNER.wilds, "owner is wilds")
  eq(snap.version, 1, "follower_state_version = 1")

  follower:restore()
  package.loaded["src.world.PikachuFollower"] = nil
end

----------------------------------------------------------------
-- Duplicate external entity guard helper
----------------------------------------------------------------
do
  saveStore = {}
  local state = State.new(V.mod)
  local compat = Compatibility.new(V.mod, state)
  check(compat:hasExternalFollowerEntity({
    pokepcTrailers = { { pokepcTrailer = true } },
  }) == true, "detects pokepcTrailers list")
  check(compat:hasExternalFollowerEntity({
    entities = { { wildsFollower = true } },
  }) == true, "detects wildsFollower marker")
  check(compat:hasExternalFollowerEntity({ entities = {} }) == false,
        "empty ow has no follower entity")
end

print("")
if failures > 0 then
  io.stderr:write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
print("all follower core tests passed")
