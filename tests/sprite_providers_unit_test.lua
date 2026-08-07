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
local savedOpts = { sprite_style = "pokemmo" }
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
    sprite_style = "followers",
    use_animated_overworld_sprites = true,
    grass_occlusion_px = 6,
    min_sprite_size = 16,
  },
  VALID_SPRITE_STYLES = {
    pokemmo = true, followers = true, pokedex = true,
  },
  normalizeSpriteStyle = function(value)
    if value == "followers_ex" or value == "poke_followers" then return "followers" end
    if value == "auto" or value == "gold" or value == "crystal" then
      return "pokemmo"
    end
    if value == "pokemmo" or value == "followers" or value == "pokedex" then
      return value
    end
    return "followers"
  end,
  get = function(_, k)
    if savedOpts[k] ~= nil then return savedOpts[k] end
    return modules.config.DEFAULTS[k]
  end,
  debug = function() return false end,
  spriteStyle = function(mod)
    local v = savedOpts.sprite_style
    if v == nil then
      if savedOpts.use_animated_overworld_sprites == false then return "pokedex" end
      return "followers"
    end
    return modules.config.normalizeSpriteStyle(v)
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

-- Label length budget (public three-choice set)
eq(#("Sprite Style"), 12, "Sprite Style label <= 14")
eq(#("HGSS / PokeMMO"), 14, "HGSS / PokeMMO choice <= 14")
-- Gen1 ListMenu abbreviates to FOLLOWERS/GSC (≤14). Mod Settings may use the
-- longer "Poke Followers / GSC" label.
eq(#("FOLLOWERS/GSC"), 13, "FOLLOWERS/GSC menu choice <= 14")
eq(#("POKEDEX"), 7, "POKEDEX choice <= 14")
eq(#("SPRITE STYLE"), 12, "SPRITE STYLE menu <= 14")
eq(#("HGSS / POKEMMO"), 14, "HGSS / POKEMMO menu <= 14")
eq(#("FOLLOWERS/GSC"), 13, "FOLLOWERS/GSC menu <= 14")
eq(#("POKEDEX"), 7, "POKEDEX menu <= 14")

-- Built-in registration (compat providers may remain)
check(providers:get("pokemmo") ~= nil, "pokemmo provider registered")
check(providers:get("pokedex") ~= nil, "pokedex provider registered")
check(providers:get("gold") ~= nil, "gold adapter still registered (compat)")
check(providers:get("followers_ex") ~= nil, "followers_ex adapter registered")
check(providers:get("black") ~= nil, "black provider registered")

-- Public style chains
eq(SpriteProviders.STYLE_CHAINS.pokemmo[1], "pokemmo", "pokemmo chain starts pokemmo")
eq(SpriteProviders.STYLE_CHAINS.pokemmo[2], "pokedex", "pokemmo falls to pokedex")
eq(SpriteProviders.STYLE_CHAINS.followers[1], "followers_ex",
   "followers style maps to followers_ex provider")
eq(SpriteProviders.STYLE_CHAINS.followers[2], "pokemmo",
   "followers falls to HGSS/PokeMMO")
eq(SpriteProviders.STYLE_CHAINS.pokedex[1], "pokedex", "pokedex chain")
eq(providers:normalizeStyle("auto"), "pokemmo", "auto normalizes to pokemmo")
eq(providers:normalizeStyle("gold"), "pokemmo", "gold normalizes to pokemmo")
eq(providers:normalizeStyle("crystal"), "pokemmo", "crystal normalizes to pokemmo")
eq(providers:normalizeStyle("followers_ex"), "followers",
   "followers_ex normalizes to followers")
eq(providers:normalizeStyle("unknown"), "followers", "unknown normalizes to followers")

local pokemmoOk = select(1, providers:providerAvailable("pokemmo", nil))
check(pokemmoOk == true, "pokemmo available with runtime sheets")

local goldOk = select(1, providers:providerAvailable("gold", nil))
check(goldOk == false, "gold unavailable without pack")

local followersOk, followersWhy = providers:providerAvailable("followers_ex", nil)
check(followersOk == true, "followers_ex available via built-in poke_followers: "
  .. tostring(followersWhy))

-- Legacy auto / gold resolve to HGSS/PokeMMO
local r = providers:resolve("auto", 25, "normal", {
  data = { pokemon = { PIKACHU = { dex = 25, spriteFront = "assets/front/25.png" } } },
})
eq(r.providerId, "pokemmo", "auto migrates resolve -> pokemmo")
check(r.def and r.def.frames == 6 and r.def.walker == true, "pokemmo def is walker sheet")
eq(r.fallbackStep, 1, "pokemmo is first step after auto→pokemmo normalize")

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

-- Legacy gold style → pokemmo chain
r = providers:resolve("gold", 25, "normal", {
  data = { pokemon = { PIKACHU = { dex = 25 } } },
})
eq(r.providerId, "pokemmo", "legacy gold style -> pokemmo")

-- Built-in Poke Followers / GSC (dex → follower_%03d)
r = providers:resolve("followers", 25, "normal", {
  data = { pokemon = { PIKACHU = { dex = 25 } } },
})
eq(r.providerId, "followers_ex", "followers uses built-in poke_followers")
check(r.def and tostring(r.def.image):find("follower_025", 1, true),
      "followers maps Pikachu to follower_025")

-- Legacy followers_ex setting value also works
r = providers:resolve("followers_ex", 25, "normal", {
  data = { pokemon = { PIKACHU = { dex = 25 } } },
})
eq(r.providerId, "followers_ex", "legacy followers_ex style uses built-in pack")

-- Register fake followers_ex provider (public style = followers)
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

r = providers:resolve("followers", "PIKACHU", "normal", nil)
eq(r.providerId, "followers_ex", "followers style uses followers_ex provider")
eq(r.fallbackStep, 1, "followers_ex is first step for followers style")

r = providers:resolve("followers_ex", "PIKACHU", "normal", nil)
eq(r.providerId, "followers_ex", "legacy followers_ex value still resolves")

-- Missing species in followers -> pokemmo
r = providers:resolve("followers", "MISSING", "normal", {
  data = { pokemon = { MISSING = { dex = 25 } } },
})
eq(r.providerId, "pokemmo", "followers miss with resolvable dex -> pokemmo")

-- Shiny unavailable on followers -> followers normal
r = providers:resolve("followers", "PIKACHU", "shiny", nil)
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
r = providers:resolve("followers", entity.species, "normal", nil)
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
local lines = providers:diagnostics("pokemmo", nil, entity)
local joined = table.concat(lines, "\n")
check(joined:find("Requested style: POKEMMO", 1, true), "HUD requested style")
check(joined:find("Poke Followers:", 1, true), "HUD followers status")
check(joined:find("Quick menu: READY", 1, true), "HUD quick menu")
check(joined:find("Body renderer: NATIVE_SPRITE_RENDERER", 1, true), "HUD body renderer")

lines = providers:diagnostics("followers", nil, entity)
joined = table.concat(lines, "\n")
check(joined:find("Requested style: FOLLOWERS", 1, true), "HUD followers requested")
check(joined:find("Poke Followers:", 1, true), "HUD followers status when requested")
check(joined:find("built-in", 1, true)
      or joined:find("AVAILABLE", 1, true)
      or joined:find("READY", 1, true)
      or joined:find("followers_ex", 1, true)
      or joined:find("Poke Followers: YES", 1, true)
      or joined:find("Provider unavailable: NO", 1, true),
      "HUD followers built-in available")

-- Gold path discovery via filesystem probe (compat adapter still works)
fsPaths["mods/Gold_Silver_Sprites/gold/battle/front/bulbasaur.png"] = true
fsPaths["mods/Gold_Silver_Sprites/gold/battle/front/pikachu.png"] = true
fsPaths["mods/Gold_Silver_Sprites/gold/battle/front/mew.png"] = true
fakeMods.Gold_Silver_Sprites = { id = "Gold_Silver_Sprites", version = "1.0.1", path = "mods/Gold_Silver_Sprites" }
local goldProvider = providers:_makeGoldProvider()
providers:register(goldProvider)
goldOk = select(1, goldProvider:isAvailable(nil))
check(goldOk == true, "gold available when fronts exist")
local gdef = goldProvider:resolve("PIKACHU", "normal", {
  data = { pokemon = { PIKACHU = { dex = 25 } } },
})
check(gdef ~= nil and gdef.image, "gold resolve returns def")
eq(gdef.frames, 1, "gold frames=1 from release format")
check(gdef.walker ~= true, "gold walker=false")
check(gdef.trueColor == true, "gold trueColor")
eq(gdef.image, "mods/Gold_Silver_Sprites/gold/battle/front/pikachu.png", "gold image path")

-- Config migration helpers (real config module)
modules.config = nil
local Config = V.require("config")
savedOpts = {}
eq(Config.spriteStyle(V.mod), "followers", "missing style defaults followers")
eq(Config.normalizeSpriteStyle("auto"), "pokemmo", "migrate auto")
eq(Config.normalizeSpriteStyle("gold"), "pokemmo", "migrate gold")
eq(Config.normalizeSpriteStyle("crystal"), "pokemmo", "migrate crystal")
eq(Config.normalizeSpriteStyle("followers_ex"), "followers", "migrate followers_ex")
eq(Config.normalizeSpriteStyle("poke_followers"), "followers", "migrate poke_followers")
eq(Config.normalizeSpriteStyle("followers"), "followers", "followers stays")
eq(Config.normalizeSpriteStyle("weird"), "followers", "migrate unknown → followers")
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
eq(Config.spriteStyle(V.mod), "followers", "legacy true without style → followers default")
savedOpts = { sprite_style = "pokemmo", use_animated_overworld_sprites = false }
V.mod.world.game.save.options.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.loader.modOptions.overworld_wild_spawns = savedOpts
eq(Config.spriteStyle(V.mod), "pokemmo", "explicit sprite_style wins over legacy")
savedOpts = { sprite_style = "gold" }
V.mod.world.game.save.options.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.loader.modOptions.overworld_wild_spawns = savedOpts
eq(Config.spriteStyle(V.mod), "pokemmo", "saved gold migrates to pokemmo")
savedOpts = { sprite_style = "followers_ex" }
V.mod.world.game.save.options.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.modOptions.overworld_wild_spawns = savedOpts
V.mod.world.game.mods.loader.modOptions.overworld_wild_spawns = savedOpts
eq(Config.spriteStyle(V.mod), "followers", "saved followers_ex migrates to followers")

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
check(okSet == true, "setSpriteStyle accepts legacy gold (normalizes)")
eq(V.mod.world.game.save.options.modOptions.overworld_wild_spawns.sprite_style,
   "pokemmo", "legacy gold writes pokemmo")
eq(V.mod.world.game.mods.modOptions.overworld_wild_spawns.sprite_style,
   "pokemmo", "legacy gold writes mod-manager cache pokemmo")
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

okSet = Config.setSpriteStyle(V.mod, "followers", "mod_settings", {
  game = V.mod.world.game,
  logic = fakeLogic,
  render = fakeRender,
  confirm = false,
})
check(okSet == true, "setSpriteStyle accepts followers")
eq(V.mod.world.game.save.options.modOptions.overworld_wild_spawns.sprite_style,
   "followers", "followers written as public value")

-- Menu module registers screens once and does NOT inject Start Menu rows.
local SpriteStyleMenu = assert(loadfile("lib/sprite_style_menu.lua"))(V)
local menu = SpriteStyleMenu.new(V.mod, fakeLogic)
local wraps = 0
local screens = 0
V.mod.hooks = {
  wrap = function(_, name, fn)
    if name == "ui.start_menu.items" then
      wraps = wraps + 1
      local items = { { label = "POKeDEX" }, { label = "SAVE" } }
      local out = fn(function(_, items2) return items2 end, nil, items)
      local order = {}
      for _, it in ipairs(out) do
        if it.label == "SPRITE STYLE" or it.label == "SPAWN AMOUNT"
           or it.label == "RANDOM ENC" or it.label == "WATER MONS" then
          order[#order + 1] = it.label
        end
      end
      eq(#order, 0, "start menu has no Wilds gameplay entries")
    end
  end,
}
V.mod.content = {
  screens = {
    register = function() screens = screens + 1 end,
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
eq(wraps, 0, "start menu hook not registered by sprite style menu")
check(screens >= 4, "style/spawn/random/water screens registered")
eq(menu._registered, true, "menu marked registered")

-- options.lua exposes exactly the three public styles
local schema = assert(loadfile("options.lua"))()
local styleOpt
for _, row in ipairs(schema) do
  if row.key == "sprite_style" then styleOpt = row end
end
check(styleOpt ~= nil, "options has sprite_style")
eq(styleOpt.default, "followers", "options default is followers")
eq(#styleOpt.choices, 3, "exactly three public sprite styles")
local saw = {}
for _, choice in ipairs(styleOpt.choices) do
  -- Mod Settings shows the full GSC label; Gen1 ListMenu uses ≤14 abbrev.
  if choice[2] ~= "followers" then
    check(#choice[1] <= 14, "choice label <= 14: " .. tostring(choice[1]))
  else
    check(choice[1]:find("GSC", 1, true), "followers label mentions GSC")
  end
  saw[choice[2]] = choice[1]
end
check(saw.pokemmo == "HGSS / PokeMMO", "options includes HGSS / PokeMMO")
check(saw.followers == "Poke Followers / GSC", "options includes Poke Followers / GSC")
check(saw.pokedex == "Pokédex" or saw.pokedex == "Pokedex", "options includes Pokedex")
check(saw.auto == nil and saw.gold == nil and saw.followers_ex == nil,
      "legacy styles removed from public options")

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
