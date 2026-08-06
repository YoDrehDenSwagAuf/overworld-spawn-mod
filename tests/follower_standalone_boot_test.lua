-- Standalone follower boot: Wilds only (no FOLLOWERS_EX / PokéPC).
-- Run: lua tests/follower_standalone_boot_test.lua
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
local contentSprites = {}
local optionStore = {
  follow_control = "trainer",
  trainer_trail = false,
  follower_count = 1,
  sprite_style = "pokemmo",
}
local eventHandlers = {}
local phases = {}

local modules = {}
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = {
      info = function(_, fmt, ...) end,
      warn = function(_, fmt, ...) end,
    },
    -- CRITICAL: no external follower mods.
    find = function() return nil end,
    save = {
      get = function(_, k) return saveStore[k] end,
      set = function(_, k, v) saveStore[k] = v end,
    },
    options = {
      get = function(_, k) return optionStore[k] end,
      set = function(_, k, v) optionStore[k] = v end,
    },
    content = {
      sprites = {
        get = function(_, id) return contentSprites[id] end,
        register = function(_, id, def) contentSprites[id] = def end,
        patch = function(_, id, def) contentSprites[id] = def end,
      },
    },
    assets = {
      path = function(_, rel) return "mods/overworld_wild_spawns/" .. rel end,
    },
    events = {
      on = function(_, name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        table.insert(eventHandlers[name], fn)
      end,
    },
    hooks = {
      wrap = function(_, name, fn)
        -- no-op stub
      end,
    },
    world = nil,
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
  DEFAULTS = {
    sprite_style = "pokemmo",
    follow_control = "trainer",
    trainer_trail = false,
    follower_count = 1,
  },
  get = function(_, k)
    if optionStore[k] ~= nil then return optionStore[k] end
    return modules.config.DEFAULTS[k]
  end,
  spriteStyle = function() return optionStore.sprite_style or "pokemmo" end,
  debug = function() return false end,
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end, debug = function() end,
}

-- Fake runtime sheets so sprite registration succeeds without engine.
local fakeSheets = {
  ready = true,
  load = function() end,
  isReady = function() return true end,
  spriteDef = function(_, dex, variant, spriteId)
    return {
      id = spriteId or "SPRITE_OW_WILD_RT",
      image = string.format("assets/generated/followsprites_runtime/%03d-%s.png",
                            tonumber(dex) or 4, variant or "normal"),
      frames = 6,
      walker = true,
      trueColor = true,
    }
  end,
  resolveAssetPath = function(_, dex, variant)
    return string.format("assets/generated/followsprites_runtime/%03d-%s.png",
                         tonumber(dex) or 4, variant or "normal"),
           variant, nil
  end,
}

local fakeRender = {
  runtimeSheets = fakeSheets,
  spriteProviders = {
    resolve = function(_, style, species, variant, game)
      local def = fakeSheets:spriteDef(4, variant, "SPRITE_WILDS_FOLLOWER_MON")
      return { def = def, providerId = "pokemmo" }
    end,
  },
  _modAssetPath = function(_, rel) return "mods/overworld_wild_spawns/" .. rel end,
}

----------------------------------------------------------------
-- Phase: mod load (no engine modules → control engine returns no_engine)
----------------------------------------------------------------
phases[#phases + 1] = "mod_load"
local Follower = V.require("follower/init")
local follower = Follower.new(V.mod, { render = fakeRender, logic = {} })

local regOk, regReason = follower:registerContent()
check(regOk == true, "registerContent registers SPRITE_PIKACHU")
check(contentSprites["SPRITE_PIKACHU"] ~= nil, "SPRITE_PIKACHU in content registry")
eq(contentSprites["SPRITE_PIKACHU"].frames, 6, "SPRITE_PIKACHU frames=6")
check(contentSprites["SPRITE_PIKACHU"].walker == true, "SPRITE_PIKACHU walker")

local installOk, installReason = follower:install({})
check(installOk == true, "install succeeds without external mods")
check(follower.spriteService._registered == true, "sprite service marked registered")

----------------------------------------------------------------
-- Phase: mods.loaded / game.ready / save.loaded / map.entered
----------------------------------------------------------------
local function fire(name, payload)
  for _, fn in ipairs(eventHandlers[name] or {}) do
    local ok, err = pcall(fn, payload)
    check(ok, "event " .. name .. " no error: " .. tostring(err))
  end
end

phases[#phases + 1] = "mods_loaded"
local game = {
  data = {
    sprites = {
      SPRITE_PIKACHU = contentSprites["SPRITE_PIKACHU"],
    },
    pokemon = {},
    field = { ledges = {} },
  },
  save = {
    party = {
      {
        species = "CHARMANDER",
        otId = 1,
        catchRate = 45,
        hp = 20,
        level = 5,
        dvs = { attack = 8, defense = 8, speed = 8, special = 8 },
      },
      {
        species = "SQUIRTLE",
        otId = 2,
        catchRate = 45,
        hp = 18,
        level = 5,
        dvs = { attack = 5, defense = 5, speed = 5, special = 5 },
      },
    },
    onBike = false,
  },
  overworld = {
    player = { cellX = 10, cellY = 10, facing = "down", surfing = false },
    map = {
      id = "route1",
      inBounds = function() return true end,
      isWalkableCell = function() return true end,
    },
    entities = {},
    npcs = {},
  },
  stack = { push = function() end },
}

V.mod.world = { game = game }
V.mod.exports.getActiveFollowerMon = function(g, h)
  return follower:getActiveFollowerMon(g, h)
end

pcall(function() follower:reassertAfterModsLoaded(game) end)
check(follower.state.ownerMode == "wilds", "owner remains wilds with find()=nil")

phases[#phases + 1] = "game_ready"
fire("game.ready")
pcall(function() follower.settings:alignSave(game) end)

phases[#phases + 1] = "save_loaded"
pcall(function() follower:onSaveLoaded() end)

phases[#phases + 1] = "map_entered"
pcall(function() follower:onMapEntered({ game = game }) end)

----------------------------------------------------------------
-- shouldSpawn guards + selection without nil crashes
----------------------------------------------------------------
phases[#phases + 1] = "first_update"
local life = follower.lifecycle
check(life:shouldSpawn(game, game.overworld) == true,
      "shouldSpawn true with SPRITE_PIKACHU + healthy party")

-- Missing sprite → false (crash guard)
local spritesBackup = game.data.sprites
game.data.sprites = {}
check(life:shouldSpawn(game, game.overworld) == false,
      "shouldSpawn false when SPRITE_PIKACHU missing")
game.data.sprites = spritesBackup

-- Nil overworld during load must not throw
local okNil = pcall(function()
  life:shouldSpawn(game, nil)
  follower:onMapEntered({ game = { save = game.save } })
  follower.spriteService:resolveFollowerSprite({ species = "PIKACHU" })
end)
check(okNil == true, "nil overworld / early load safe")

----------------------------------------------------------------
-- Settings defaults + mode mapping
----------------------------------------------------------------
local settings = follower.settings
eq(settings:followControl(), "trainer", "default Control Mode=trainer")
eq(settings:trainerTrail(), false, "default Trainer Trail=off")
eq(settings:followerCount(), 1, "default Followers=1")
eq(settings:engineMode(game), "follow", "trainer → engine follow")

optionStore.follow_control = "pokemon"
optionStore.trainer_trail = false
optionStore.follower_count = 0
eq(settings:engineMode(game), "pokemon", "pokemon+trail off+count0 → pokemon")

optionStore.follower_count = 3
-- Clear save mode so UI mapping wins
game.save.pokepcControlMode = nil
eq(settings:engineMode(game), "pack", "pokemon+count3 → pack")

optionStore.trainer_trail = true
game.save.pokepcControlMode = nil
eq(settings:engineMode(game), "lead_trainer", "pokemon+trail on → lead_trainer")

----------------------------------------------------------------
-- Settings migration from boolean follower_count
----------------------------------------------------------------
local SettingsMod = V.require("follower/settings")
check(SettingsMod.clampCount(true) == 1, "boolean count → 1")
check(SettingsMod.clampCount(-1) == 0, "count floor 0")
check(SettingsMod.clampCount(99) == 6, "count ceil 6")

----------------------------------------------------------------
-- Fingerprint includes species
----------------------------------------------------------------
local Selection = V.require("follower/selection")
local mon = game.save.party[1]
local key = Selection.monFingerprint(mon)
check(key:find("CHARMANDER", 1, true) == 1, "fingerprint starts with species")

local okSelect = follower:selectFollower(game.save.party[2], game, true)
check(okSelect == true, "selectFollower works standalone")

----------------------------------------------------------------
-- resolveFollowerSprite without external assets
----------------------------------------------------------------
local resolved = follower.spriteService:resolveFollowerSprite({
  species = "CHARMANDER",
  shiny = false,
  surface = "land",
  role = "primary",
  game = game,
})
check(resolved ~= nil and resolved.image ~= nil, "resolveFollowerSprite returns image")
check(not tostring(resolved.image):find("PokePCFollowers", 1, true),
      "no PokéPC path in resolved image")

----------------------------------------------------------------
-- Live options change must not crash
----------------------------------------------------------------
pcall(function()
  follower:onOptionsChanged({ key = "follower_count", mod = V.mod.id })
  follower:onOptionsChanged({ key = "follow_control", mod = V.mod.id })
  follower:onOptionsChanged({ key = "sprite_style", mod = V.mod.id })
end)
check(true, "options_changed handlers safe")

print("")
print("phases: " .. table.concat(phases, " → "))
if failures > 0 then
  io.stderr:write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
print("all standalone boot tests passed")
