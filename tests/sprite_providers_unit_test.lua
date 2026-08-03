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
local fsPaths = {}

-- Stub love.filesystem so Gold / Followers path probes can succeed in tests.
love = love or {}
love.filesystem = {
  getInfo = function(path)
    if fsPaths[path] then return { type = "file" } end
    return nil
  end,
}

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
    auto = true, gold = true, followers_ex = true, pokemmo = true, pokedex = true,
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
eq(#("Gold Sprites"), 12, "Gold Sprites choice <= 14")
eq(#("Followers EX"), 12, "Followers EX choice <= 14")
eq(#("PokeMMO"), 7, "PokeMMO choice <= 14")
eq(#("Pokedex"), 7, "Pokedex choice <= 14")
eq(#("Auto"), 4, "Auto choice <= 14")
eq(#("SPRITE STYLE"), 12, "SPRITE STYLE menu <= 14")
eq(#("GOLD SPRITES"), 12, "GOLD SPRITES menu <= 14")
eq(#("FOLLOWERS EX"), 12, "FOLLOWERS EX menu <= 14")
eq(#("POKEMMO"), 7, "POKEMMO menu <= 14")
eq(#("POKEDEX"), 7, "POKEDEX menu <= 14")
eq(#("AUTO"), 4, "AUTO menu <= 14")

-- Built-in registration
check(providers:get("pokemmo") ~= nil, "pokemmo provider registered")
check(providers:get("pokedex") ~= nil, "pokedex provider registered")
check(providers:get("gold") ~= nil, "gold adapter registered")
check(providers:get("followers_ex") ~= nil, "followers_ex adapter registered")
check(providers:get("black") ~= nil, "black provider registered")

-- Central AUTO order
eq(SpriteProviders.AUTO_PROVIDER_ORDER[1], "gold", "AUTO order starts gold")
eq(SpriteProviders.AUTO_PROVIDER_ORDER[2], "followers_ex", "AUTO then followers_ex")
eq(SpriteProviders.AUTO_PROVIDER_ORDER[3], "pokemmo", "AUTO then pokemmo")
eq(SpriteProviders.AUTO_PROVIDER_ORDER[4], "pokedex", "AUTO then pokedex")
eq(SpriteProviders.STYLE_CHAINS.auto[1], "gold", "STYLE_CHAINS.auto uses AUTO order")
eq(SpriteProviders.STYLE_CHAINS.gold[1], "gold", "gold chain starts gold")
eq(SpriteProviders.STYLE_CHAINS.gold[2], "pokemmo", "gold falls to pokemmo")

local pokemmoOk = select(1, providers:providerAvailable("pokemmo", nil))
check(pokemmoOk == true, "pokemmo available with runtime sheets")

local goldOk = select(1, providers:providerAvailable("gold", nil))
check(goldOk == false, "gold unavailable without pack")

local followersOk = select(1, providers:providerAvailable("followers_ex", nil))
check(followersOk == false, "followers_ex unavailable without pack")

-- Auto without external mods -> PokeMMO (skips gold + followers)
local r = providers:resolve("auto", 25, "normal", {
  data = { pokemon = { PIKACHU = { dex = 25, spriteFront = "assets/front/25.png" } } },
})
eq(r.providerId, "pokemmo", "auto without externals -> pokemmo")
check(r.def and r.def.frames == 6 and r.def.walker == true, "pokemmo def is walker sheet")
eq(r.fallbackStep, 3, "auto skipped gold+followers then used pokemmo (step 3)")

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

-- Explicit gold without provider -> pokemmo fallback
r = providers:resolve("gold", 25, "normal", {
  data = { pokemon = { PIKACHU = { dex = 25 } } },
})
eq(r.providerId, "pokemmo", "explicit gold without pack -> pokemmo")

-- Explicit followers_ex without provider -> pokemmo fallback
r = providers:resolve("followers_ex", 25, "normal", {
  data = { pokemon = { PIKACHU = { dex = 25 } } },
})
eq(r.providerId, "pokemmo", "explicit followers_ex without pack -> pokemmo")

-- Register fake gold provider
local goldCalls = 0
local goldMissing = {}
check(providers:register({
  id = "gold",
  modId = "Gold_Silver_Sprites",
  isAvailable = function() return true, "test gold" end,
  resolve = function(_, speciesId, variant)
    goldCalls = goldCalls + 1
    local key = tostring(speciesId)
    if goldMissing[key] or key == "MISSING" or key == "999" then
      return nil, nil, "missing gold species"
    end
    if variant == "shiny" then
      return nil, nil, "gold shiny unavailable"
    end
    return {
      image = "mods/Gold_Silver_Sprites/gold/battle/front/" .. string.lower(key) .. ".png",
      frames = 1,
      trueColor = true,
    }, {
      usedVariant = "normal",
      providerMod = "Gold_Silver_Sprites",
      providerVersion = "1.0.1",
      frames = 1,
      walker = false,
    }, nil
  end,
}) == true, "can register gold override")

r = providers:resolve("auto", "PIKACHU", "normal", nil)
eq(r.providerId, "gold", "auto with gold provider -> gold")
eq(r.fallbackStep, 1, "gold is first auto step")
check(r.def.frames == 1 and r.def.walker ~= true, "gold def is 1-frame non-walker")
check(r.def.image:find("gold/battle/front/pikachu", 1, true), "gold uses battle front path")

r = providers:resolve("gold", "PIKACHU", "normal", nil)
eq(r.providerId, "gold", "explicit gold with provider")

-- Missing gold species -> next provider (pokemmo) when followers absent
goldMissing.MISSING = true
r = providers:resolve("gold", "MISSING", "normal", {
  data = { pokemon = { MISSING = { dex = 25 } } },
})
eq(r.providerId, "pokemmo", "missing gold species -> pokemmo")

-- Gold shiny unavailable -> gold normal
r = providers:resolve("auto", "PIKACHU", "shiny", nil)
eq(r.providerId, "gold", "shiny falls back within gold provider")
eq(r.meta.usedVariant, "normal", "shiny -> normal on gold")
check(r.meta.shinyFallback == true, "shinyFallback flagged for gold")

-- Auto without gold, with followers -> followers
providers:unregister("gold")
providers:register(providers:_makeGoldProvider()) -- restore unavailable builtin
check(providers:register({
  id = "followers_ex",
  modId = "PokePCFollowers_VoxelMerge",
  isAvailable = function() return true, "test provider" end,
  resolve = function(_, speciesId, variant)
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
eq(r.providerId, "followers_ex", "auto without gold, with followers -> followers_ex")
eq(r.fallbackStep, 2, "followers is second auto step when gold missing")

r = providers:resolve("followers_ex", "PIKACHU", "normal", nil)
eq(r.providerId, "followers_ex", "explicit followers with provider")

-- Missing species in followers -> pokemmo
r = providers:resolve("followers_ex", "MISSING", "normal", {
  data = { pokemon = { MISSING = { dex = 25 } } },
})
eq(r.providerId, "pokemmo", "followers miss with resolvable dex -> pokemmo")

-- Shiny unavailable on followers -> followers normal
r = providers:resolve("followers_ex", "PIKACHU", "shiny", nil)
eq(r.providerId, "followers_ex", "shiny falls back within followers provider")
eq(r.meta.usedVariant, "normal", "shiny -> normal on same provider")
check(r.meta.shinyFallback == true, "shinyFallback flagged")

-- Missing from pokemmo -> pokedex
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

-- Hot-switch simulation
local SpriteRendererStub = {
  new = function(def, id)
    return { def = def, id = id, resolveImage = function() end }
  end,
}
package.preload["src.render.SpriteRenderer"] = function() return SpriteRendererStub end

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
check(#listed >= 4, "listSpriteProviders returns entries")
check(providers:unregister("followers_ex") == true, "can unregister non-core override")
providers:register(providers:_makeFollowersExProvider())

-- Diagnostics lines
local lines = providers:diagnostics("auto", nil, entity)
local joined = table.concat(lines, "\n")
check(joined:find("Requested style: AUTO", 1, true), "HUD requested style")
check(joined:find("Gold Sprites:", 1, true), "HUD gold status")
check(joined:find("Followers EX:", 1, true), "HUD followers status")
check(joined:find("Quick menu: READY", 1, true), "HUD quick menu")
check(joined:find("Body renderer: NATIVE_SPRITE_RENDERER", 1, true), "HUD body renderer")

lines = providers:diagnostics("gold", nil, entity)
joined = table.concat(lines, "\n")
check(joined:find("Requested style: GOLD", 1, true), "HUD gold requested")
check(joined:find("Gold provider: NOT INSTALLED", 1, true)
      or joined:find("Gold Sprites: NOT INSTALLED", 1, true),
      "HUD gold not installed")
check(joined:find("Fallback reason: provider unavailable", 1, true),
      "HUD gold fallback reason")

-- Gold path discovery via filesystem probe
fsPaths["mods/Gold_Silver_Sprites/gold/battle/front/bulbasaur.png"] = true
fsPaths["mods/Gold_Silver_Sprites/gold/battle/front/pikachu.png"] = true
fsPaths["mods/Gold_Silver_Sprites/gold/battle/front/mew.png"] = true
fakeMods.Gold_Silver_Sprites = { id = "Gold_Silver_Sprites", version = "1.0.1", path = "mods/Gold_Silver_Sprites" }
local goldProvider = providers:_makeGoldProvider()
providers:register(goldProvider)
goldOk = select(1, goldProvider:isAvailable(nil))
check(goldOk == true, "gold available when fronts exist")
r = goldProvider:resolve("PIKACHU", "normal", {
  data = { pokemon = { PIKACHU = { dex = 25 } } },
})
check(r ~= nil and r.image, "gold resolve returns def")
eq(r.frames, 1, "gold frames=1 from release format")
check(r.walker ~= true, "gold walker=false")
check(r.trueColor == true, "gold trueColor")
eq(r.image, "mods/Gold_Silver_Sprites/gold/battle/front/pikachu.png", "gold image path")

-- Config migration helpers (real config module)
modules.config = nil
local Config = V.require("config")
savedOpts = {}
eq(Config.spriteStyle(V.mod), "auto", "missing style defaults auto")
savedOpts = { use_animated_overworld_sprites = false }
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
savedOpts = { sprite_style = "gold" }
V.mod.world.game.save.options.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.loader.modOptions.overworld_wild_spawns = savedOpts
eq(Config.spriteStyle(V.mod), "gold", "gold is a valid sprite_style")

-- setSpriteStyle writes the same key used by Mod Settings
local refreshed = 0
local fakeLogic = { entities = {} }
local fakeRender = {
  invalidateAssetCache = function() end,
  refreshAllEntitySprites = function()
    refreshed = refreshed + 1
    return 0
  end,
}
local okSet = Config.setSpriteStyle(V.mod, "gold", "start_menu", {
  game = V.mod.world.game,
  logic = fakeLogic,
  render = fakeRender,
  confirm = false,
})
check(okSet == true, "setSpriteStyle accepts gold")
eq(V.mod.world.game.save.options.modOptions.overworld_wild_spawns.sprite_style,
   "gold", "start menu writes save sprite_style")
eq(V.mod.world.game.mods.modOptions.overworld_wild_spawns.sprite_style,
   "gold", "start menu writes mod-manager cache")
eq(refreshed, 1, "setSpriteStyle refreshes sprites once")

okSet = Config.setSpriteStyle(V.mod, "pokemmo", "mod_settings", {
  game = V.mod.world.game,
  logic = fakeLogic,
  render = fakeRender,
  confirm = false,
})
check(okSet == true, "setSpriteStyle accepts pokemmo from mod settings path")
eq(V.mod.world.game.save.options.modOptions.overworld_wild_spawns.sprite_style,
   "pokemmo", "mod settings path writes same sprite_style key")

-- Menu module registers once
local SpriteStyleMenu = assert(loadfile("lib/sprite_style_menu.lua"))(V)
local menu = SpriteStyleMenu.new(V.mod, fakeLogic)
local wraps = 0
V.mod.hooks = {
  wrap = function(_, name, fn)
    if name == "ui.start_menu.items" then wraps = wraps + 1 end
    -- Immediately exercise uniqueness: call twice through register.
    local items = { { label = "POKeDEX" }, { label = "SAVE" } }
    local out = fn(function(_, items2) return items2 end, nil, items)
    local order = {}
    for _, it in ipairs(out) do
      if it.label == "SPRITE STYLE" or it.label == "SPAWN AMOUNT"
         or it.label == "GRASS ENC" or it.label == "WATER MONS" then
        order[#order + 1] = it.label
      end
    end
    eq(#order, 4, "start menu inserts four Wilds entries")
    eq(order[1], "SPRITE STYLE", "menu order 1 SPRITE STYLE")
    eq(order[2], "SPAWN AMOUNT", "menu order 2 SPAWN AMOUNT")
    eq(order[3], "GRASS ENC", "menu order 3 GRASS ENC")
    eq(order[4], "WATER MONS", "menu order 4 WATER MONS")
  end,
}
V.mod.content = {
  screens = {
    register = function() end,
  },
}
V.mod.ui = {
  insertBefore = function(items, before, entry)
    local out = {}
    for _, it in ipairs(items) do
      if it.label == before then out[#out + 1] = entry end
      out[#out + 1] = it
    end
    return out
  end,
  ListMenu = { new = function() return {} end },
  push = function() end,
}
menu:register()
menu:register() -- second call must no-op
eq(wraps, 1, "start menu hook registered only once")
eq(menu._registered, true, "menu marked registered")

-- options.lua includes gold
local schema = assert(loadfile("options.lua"))()
local styleOpt
for _, row in ipairs(schema) do
  if row.key == "sprite_style" then styleOpt = row end
end
check(styleOpt ~= nil, "options has sprite_style")
local sawGold = false
for _, choice in ipairs(styleOpt.choices) do
  check(#choice[1] <= 14, "choice label <= 14: " .. tostring(choice[1]))
  if choice[2] == "gold" then sawGold = true end
end
check(sawGold, "options sprite_style includes gold")

-- No hard dependency cycle in manifest
local manifest = assert(io.open("manifest.json", "r")):read("*a")
check(not manifest:find("FOLLOWERS_EX", 1, true), "manifest has no FOLLOWERS_EX dependency")
check(not manifest:find("PokePCFollowers_VoxelMerge", 1, true),
      "manifest has no PokePC hard dependency")
check(not manifest:find("Gold_Silver_Sprites", 1, true),
      "manifest has no Gold Sprites hard dependency")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("sprite_providers_unit_test: all passed")
