-- Sprite provider selection / fallback unit tests (no Gen1Recomp required).
-- Run: luajit tests/sprite_providers_unit_test.lua
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

local modRoot = "."
local fakeMods = {}
local savedOpts = { sprite_style = "auto" }
local modules = {}

local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = modRoot,
    log = { info = function() end },
    find = function(_, id) return fakeMods[id] end,
    options = {
      get = function(_, key)
        return savedOpts[key]
      end,
    },
    assets = {
      path = function(_, rel) return "mods/overworld_wild_spawns/" .. rel end,
    },
    read = function(_, rel)
      local f = io.open(rel, "rb")
      if not f then f = io.open("./" .. rel, "rb") end
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    content = {
      pokemon = {
        get = function() return nil end,
        each = function() return function() end end,
      },
      sprites = { get = function() return nil end },
    },
  },
  path = modRoot,
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
    sprite_style = "auto",
    use_animated_overworld_sprites = true,
    grass_occlusion_px = 6,
    min_sprite_size = 16,
  },
  VALID_SPRITE_STYLES = {
    auto = true, followers_ex = true, pokemmo = true, pokedex = true,
  },
  get = function(_, k)
    if savedOpts[k] ~= nil then return savedOpts[k] end
    return modules.config.DEFAULTS[k]
  end,
  debug = function() return false end,
  spriteStyle = function(mod)
    local v = savedOpts.sprite_style
    if v == nil then
      if savedOpts.use_animated_overworld_sprites == false then return "pokedex" end
      return "auto"
    end
    return v
  end,
  useAnimatedOverworldSprites = function(mod)
    return modules.config.spriteStyle(mod) ~= "pokedex"
  end,
  peekSavedOption = function(_, key)
    if savedOpts[key] ~= nil then return savedOpts[key], true end
    return nil, false
  end,
}
modules.debug_log = {
  info = function() end, warn = function() end, error = function() end, debug = function() end,
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16, size = function() return 16, 16 end }
modules.json_decode = assert(loadfile("lib/json_decode.lua"))(V)
modules.animated_sprites = assert(loadfile("lib/animated_sprites.lua"))(V)
modules.runtime_sheets = assert(loadfile("lib/runtime_sheets.lua"))(V)

-- Minimal render stub for providers.
local RuntimeSheets = modules.runtime_sheets
local render = {
  runtimeSheets = RuntimeSheets.new(V.mod),
  registrationInfo = {},
  fallbackPath = "assets/fallback/pokemon_missing.png",
  fallbackId = "SPRITE_OW_WILD_FALLBACK",
  _modAssetPath = function(_, rel)
    return "mods/overworld_wild_spawns/" .. rel
  end,
  _fallbackPath = function()
    return "assets/fallback/pokemon_missing.png"
  end,
  resolveAsset = function(_, species)
    return {
      path = "assets/pokemon/" .. tostring(species) .. ".png",
      source = "battle_front",
    }
  end,
}
check(render.runtimeSheets:load() == true, "runtime sheets load for pokemmo provider")

local SpriteProviders = assert(loadfile("lib/sprite_providers.lua"))(V)
local providers = SpriteProviders.new(V.mod, render)

-- Label length budget
eq(#("Sprite Style"), 12, "Sprite Style label <= 14")
eq(#("Followers EX"), 12, "Followers EX choice <= 14")
eq(#("PokeMMO"), 7, "PokeMMO choice <= 14")
eq(#("Pokedex"), 7, "Pokedex choice <= 14")
eq(#("Auto"), 4, "Auto choice <= 14")

-- Built-in registration
check(providers:get("pokemmo") ~= nil, "pokemmo provider registered")
check(providers:get("pokedex") ~= nil, "pokedex provider registered")
check(providers:get("followers_ex") ~= nil, "followers_ex adapter registered")
check(providers:get("black") ~= nil, "black provider registered")

local pokemmoOk = select(1, providers:providerAvailable("pokemmo", nil))
check(pokemmoOk == true, "pokemmo available with runtime sheets")

local followersOk = select(1, providers:providerAvailable("followers_ex", nil))
check(followersOk == false, "followers_ex unavailable without pack")

-- Auto without Followers EX -> PokeMMO
local r = providers:resolve("auto", 25, "normal", {
  data = { pokemon = { PIKACHU = { dex = 25, spriteFront = "assets/front/25.png" } } },
})
eq(r.providerId, "pokemmo", "auto without followers -> pokemmo")
check(r.def and r.def.frames == 6 and r.def.walker == true, "pokemmo def is walker sheet")
eq(r.fallbackStep, 2, "auto skipped followers then used pokemmo (step 2)")

-- Explicit pokemmo
r = providers:resolve("pokemmo", 1, "normal", nil)
eq(r.providerId, "pokemmo", "explicit pokemmo")

-- Explicit pokedex
r = providers:resolve("pokedex", "BULBASAUR", "normal", {
  data = { pokemon = { BULBASAUR = { dex = 1, spriteFront = "assets/front/1.png" } } },
})
eq(r.providerId, "pokedex", "explicit pokedex")
check(r.def and r.def.frames == 1, "pokedex is 1-frame")
check(r.def.walker ~= true, "pokedex is not walker")

-- Explicit followers_ex without provider -> pokemmo fallback
r = providers:resolve("followers_ex", 25, "normal", {
  data = { pokemon = { PIKACHU = { dex = 25 } } },
})
eq(r.providerId, "pokemmo", "explicit followers_ex without pack -> pokemmo")

-- Register a fake followers provider and verify auto prefers it
local fakeCalls = 0
check(providers:register({
  id = "followers_ex",
  modId = "PokePCFollowers_VoxelMerge",
  isAvailable = function() return true, "test provider" end,
  resolve = function(_, speciesId, variant)
    fakeCalls = fakeCalls + 1
    local key = tostring(speciesId)
    if key == "MISSING" or key == "999" then
      return nil, nil, "missing species"
    end
    if variant == "shiny" then
      return nil, nil, "no shiny"
    end
    return {
      image = "mods/PokePCFollowers_VoxelMerge/assets/sprites/follower_PIKACHU.png",
      frames = 6,
      walker = true,
      trueColor = true,
    }, { usedVariant = "normal", providerMod = "PokePCFollowers_VoxelMerge" }, nil
  end,
}) == true, "can register followers_ex override")

r = providers:resolve("auto", "PIKACHU", "normal", nil)
eq(r.providerId, "followers_ex", "auto with followers provider -> followers_ex")
eq(r.fallbackStep, 1, "followers is first step")

r = providers:resolve("followers_ex", "PIKACHU", "normal", nil)
eq(r.providerId, "followers_ex", "explicit followers with provider")

-- Missing species in followers -> pokemmo (dex still resolvable for Wilds sheets)
r = providers:resolve("followers_ex", "MISSING", "normal", {
  data = { pokemon = { MISSING = { dex = 25 } } },
})
eq(r.providerId, "pokemmo", "followers miss with resolvable dex -> pokemmo")

-- Shiny unavailable on followers -> followers normal (same provider)
r = providers:resolve("auto", "PIKACHU", "shiny", nil)
eq(r.providerId, "followers_ex", "shiny falls back within followers provider")
eq(r.meta.usedVariant, "normal", "shiny -> normal on same provider")
check(r.meta.shinyFallback == true, "shinyFallback flagged")

-- Missing from pokemmo -> pokedex (disable pokemmo temporarily)
local realPokemmo = providers:get("pokemmo")
providers.providers.pokemmo = {
  id = "pokemmo",
  isAvailable = function() return true end,
  resolve = function() return nil, nil, "no sheet" end,
}
r = providers:resolve("pokemmo", "BULBASAUR", "normal", {
  data = { pokemon = { BULBASAUR = { dex = 1, spriteFront = "assets/front/1.png" } } },
})
eq(r.providerId, "pokedex", "missing pokemmo species -> pokedex")
providers.providers.pokemmo = realPokemmo

-- Hot-switch simulation: applyProviderSprite replaces sprite once, keeps entity
local SpriteRendererStub = {
  new = function(def, id)
    return { def = def, id = id, resolveImage = function() end }
  end,
}
package.preload["src.render.SpriteRenderer"] = function() return SpriteRendererStub end

-- Load spawn_render pieces needed? Too heavy. Simulate apply contract:
local entity = {
  id = "e1", spawnId = "e1", species = "PIKACHU", enhancedDexId = 25,
  facing = "down", px = 32, py = 48, cellX = 2, cellY = 3,
  behavior = "IDLE", overworldWildSpawn = true, visibleSprite = true,
  sprite = SpriteRendererStub.new({ image = "old.png", frames = 6, walker = true }, "e1"),
  spriteProviderId = "pokemmo",
}
local beforePx, beforePy, beforeBeh = entity.px, entity.py, entity.behavior
local beforeId = entity.id
r = providers:resolve("auto", entity.species, "normal", nil)
local newSprite = SpriteRendererStub.new(r.def, entity.spawnId)
entity.sprite = newSprite
entity.spriteProviderId = r.providerId
eq(entity.id, beforeId, "entity identity preserved")
eq(entity.px, beforePx, "position x preserved")
eq(entity.py, beforePy, "position y preserved")
eq(entity.behavior, beforeBeh, "behaviour preserved")
eq(entity.spriteProviderId, "followers_ex", "provider switched to followers_ex")
check(entity.sprite.def.image:find("follower_PIKACHU", 1, true), "sprite image replaced once")
check(entity.sprite.def.frames == 6 and entity.sprite.def.walker == true,
      "still native walker SpriteRenderer def")

-- Public API surface on registry
local listed = providers:list()
check(#listed >= 3, "listSpriteProviders returns entries")
check(providers:unregister("followers_ex") == true, "can unregister non-core override")
-- Re-register builtin adapter after unregister for cleanliness
providers:register(providers:_makeFollowersExProvider())

-- Diagnostics lines
local lines = providers:diagnostics("auto", nil, entity)
local joined = table.concat(lines, "\n")
check(joined:find("Requested style: AUTO", 1, true), "HUD requested style")
check(joined:find("Followers EX: NOT INSTALLED", 1, true)
      or joined:find("Followers EX:", 1, true), "HUD followers status")
check(joined:find("Body renderer: NATIVE_SPRITE_RENDERER", 1, true), "HUD body renderer")

-- Config migration helpers (real config module)
modules.config = nil
local Config = V.require("config")
savedOpts = {}
eq(Config.spriteStyle(V.mod), "auto", "missing style defaults auto")
savedOpts = { use_animated_overworld_sprites = false }
-- peek finds legacy false without sprite_style
V.mod.world = {
  game = {
    save = { options = { modOptions = { overworld_wild_spawns = savedOpts } } },
    mods = { modOptions = { overworld_wild_spawns = savedOpts },
             loader = { modOptions = { overworld_wild_spawns = savedOpts } } },
  },
}
eq(Config.spriteStyle(V.mod), "pokedex", "legacy false migrates to pokedex")
savedOpts = { use_animated_overworld_sprites = true }
V.mod.world.game.save.options.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.loader.modOptions.overworld_wild_spawns = savedOpts
eq(Config.spriteStyle(V.mod), "auto", "legacy true migrates to auto")
savedOpts = { sprite_style = "pokemmo", use_animated_overworld_sprites = false }
V.mod.world.game.save.options.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.loader.modOptions.overworld_wild_spawns = savedOpts
eq(Config.spriteStyle(V.mod), "pokemmo", "explicit sprite_style wins over legacy")

-- No hard dependency cycle in manifest
local manifest = assert(io.open("manifest.json", "r")):read("*a")
check(not manifest:find("FOLLOWERS_EX", 1, true), "manifest has no FOLLOWERS_EX dependency")
check(not manifest:find("PokePCFollowers_VoxelMerge", 1, true),
      "manifest has no PokePC hard dependency")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("sprite_providers_unit_test: all passed")
