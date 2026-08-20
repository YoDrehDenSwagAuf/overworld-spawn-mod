-- Gold pokedex/provider priority + Gen1-in-Gen2 species audit.
-- Run: lua5.1 tests/gold_pokedex_sprite_unit_test.lua
--
-- Proves Farfetch'd (and other Gen1 species in Gold) prefer the live
-- generation-native spriteFront over stale Gen1 registrationInfo art when
-- style=pokedex. HGSS / Followers styles are unchanged.
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

local savedOpts = { sprite_style = "pokedex", wild_silhouettes = "off" }
local modules = {}

package.preload["src.render.Assets"] = function()
  return { exists = function() return false end }
end
package.preload["src.render.SpriteRenderer"] = function()
  return {
    DEFAULT_FRAME_WIDTH = 16, DEFAULT_FRAME_HEIGHT = 16,
    DEFAULT_ANCHOR_X = 8, DEFAULT_ANCHOR_Y = 16,
  }
end
package.preload["src.core.GameVersion"] = function()
  return {
    get = function() return "gold" end,
    isYellow = function() return false end,
    isGold = function() return true end,
    generation = function(which)
      which = which or "gold"
      if which == "gold" or which == "silver" or which == "crystal" then
        return 2
      end
      return 1
    end,
  }
end

local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    find = function() return nil end,
    options = {
      get = function(_, k) return savedOpts[k] end,
      set = function(_, k, v) savedOpts[k] = v end,
    },
    assets = { path = function(_, rel) return rel end },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a"); f:close(); return data
    end,
    content = {
      pokemon = {
        get = function() return nil end,
        each = function() return function() end end,
      },
      sprites = { get = function() return nil end },
    },
    world = {
      game = {
        save = { options = { modOptions = { overworld_wild_spawns = savedOpts } } },
        mods = { modOptions = { overworld_wild_spawns = savedOpts } },
      },
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

local SpeciesAssets = V.require("species_assets")
local Config = V.require("config")
local GameCompat = V.require("game_compat")
local RuntimeSheets = V.require("runtime_sheets")
local SpriteProviders = V.require("sprite_providers")
local VariableSize = V.require("variable_size")
VariableSize.clearCaches()

eq(GameCompat.generation(V.mod), 2, "engine generation is Gen2/Gold")

local STALE_GEN1 = "assets/stale/gen1_farfetchd_front.png"
local GOLD_FRONT = {
  FARFETCHD = "gold/battle/front/farfetchd.png",
  PIKACHU = "gold/battle/front/pikachu.png",
  ONIX = "gold/battle/front/onix.png",
  PIDGEY = "gold/battle/front/pidgey.png",
  CHIKORITA = "gold/battle/front/chikorita.png",
  SENTRET = "gold/battle/front/sentret.png",
  RAIKOU = "gold/battle/front/raikou.png",
  ENTEI = "gold/battle/front/entei.png",
  SUICUNE = "gold/battle/front/suicune.png",
  TYRANITAR = "gold/battle/front/tyranitar.png",
}

local game = {
  data = {
    pokemon = {},
  },
  save = { options = { modOptions = { overworld_wild_spawns = savedOpts } } },
  mods = { modOptions = { overworld_wild_spawns = savedOpts } },
}
for key, front in pairs(GOLD_FRONT) do
  game.data.pokemon[key] = {
    name = key,
    dex = SpeciesAssets.idFor(key),
    spriteFront = front,
  }
end

local render = {
  runtimeSheets = RuntimeSheets.new(V.mod),
  registrationInfo = {
    -- Stale Gen1-looking registration (battle_front / generated) that must
    -- NOT win over Gold's live spriteFront for Gen2 pokedex style.
    FARFETCHD = {
      image = STALE_GEN1,
      kind = "battle_front",
      source = STALE_GEN1,
      status = "REGISTERED",
    },
    PIKACHU = {
      image = "assets/stale/gen1_pikachu_front.png",
      kind = "generated_overworld",
      source = "assets/stale/gen1_pikachu_front.png",
      status = "REGISTERED",
    },
    ONIX = {
      image = "assets/stale/gen1_onix_front.png",
      kind = "registered",
      source = "assets/stale/gen1_onix_front.png",
      status = "REGISTERED",
    },
  },
  resolveAsset = function()
    -- Force the pokedex provider past resolveAsset so spriteFront / reg order
    -- is what we exercise.
    return nil
  end,
  fallbackPath = "assets/fallback/pokemon_missing.png",
  _modAssetPath = function(_, rel) return rel end,
  _fallbackPath = function() return "assets/fallback/pokemon_missing.png" end,
}
check(render.runtimeSheets:load() == true, "runtime sheets load")

local providers = SpriteProviders.new(V.mod, render)

local function audit(species)
  local assetId = SpeciesAssets.idFor(species)
  local result = providers:resolve("pokedex", species, "normal", game)
  local mon = game.data.pokemon[species]
  local reg = render.registrationInfo[species]
  return {
    species = species,
    assetId = assetId,
    style = "pokedex",
    providerId = result and result.providerId,
    kind = result and result.meta and result.meta.kind,
    image = result and result.def and result.def.image,
    trueColor = result and result.def and result.def.trueColor,
    registrationImage = reg and reg.image,
    spriteFront = mon and mon.spriteFront,
    result = result,
  }
end

----------------------------------------------------------------
-- Farfetch'd: Gold spriteFront wins over stale Gen1 registration
----------------------------------------------------------------
do
  local a = audit("FARFETCHD")
  eq(a.assetId, 83, "FARFETCHD asset id 83")
  eq(a.providerId, "pokedex", "FARFETCHD provider pokedex")
  eq(a.kind, "battle_front", "FARFETCHD kind battle_front")
  eq(a.image, GOLD_FRONT.FARFETCHD, "FARFETCHD uses Gold spriteFront")
  check(a.image ~= STALE_GEN1, "FARFETCHD does not use stale Gen1 registration")
  eq(a.trueColor, true, "FARFETCHD trueColor true")
  check(a.registrationImage == STALE_GEN1, "stale registration still present (ignored)")
end

----------------------------------------------------------------
-- Pikachu / Onix / Pidgey Gen1-in-Gen2
----------------------------------------------------------------
for _, species in ipairs({ "PIKACHU", "ONIX", "PIDGEY" }) do
  local a = audit(species)
  eq(a.providerId, "pokedex", species .. " provider pokedex")
  eq(a.image, GOLD_FRONT[species], species .. " uses Gold spriteFront")
  if a.registrationImage then
    check(a.image ~= a.registrationImage,
          species .. " does not use stale registration art")
  end
  eq(a.trueColor, true, species .. " trueColor true")
end

----------------------------------------------------------------
-- Gen2-only controls (no stale registration)
----------------------------------------------------------------
for _, species in ipairs({
  "CHIKORITA", "SENTRET", "RAIKOU", "ENTEI", "SUICUNE", "TYRANITAR",
}) do
  local a = audit(species)
  local expectedDex = ({
    CHIKORITA = 152, SENTRET = 161, RAIKOU = 243,
    ENTEI = 244, SUICUNE = 245, TYRANITAR = 248,
  })[species]
  eq(a.assetId, expectedDex, species .. " asset id")
  eq(a.providerId, "pokedex", species .. " provider pokedex")
  eq(a.image, GOLD_FRONT[species], species .. " uses Gold spriteFront")
  eq(a.trueColor, true, species .. " trueColor true")
  check(a.result and a.result.def and a.result.def.image ~= nil,
        species .. " resolves (no missing fallback)")
end

----------------------------------------------------------------
-- Gen1 preserves registrationInfo-first order
----------------------------------------------------------------
do
  package.loaded["src.core.GameVersion"] = {
    get = function() return "red" end,
    isYellow = function() return false end,
    isGold = function() return false end,
    generation = function() return 1 end,
  }
  -- Bust game_compat generation cache via fresh require path: generation()
  -- reads GameVersion live each call.
  local gen1Game = {
    data = {
      pokemon = {
        FARFETCHD = {
          name = "FARFETCHD", dex = 83,
          spriteFront = "gen1/battle/front/farfetchd.png",
        },
      },
    },
  }
  local stale = "assets/stale/gen1_registered_farfetchd.png"
  render.registrationInfo.FARFETCHD = {
    image = stale, kind = "battle_front", status = "REGISTERED",
  }
  local result = providers:resolve("pokedex", "FARFETCHD", "normal", gen1Game)
  eq(result.providerId, "pokedex", "Gen1 pokedex provider")
  eq(result.def.image, stale, "Gen1 still prefers registrationInfo")
  check(result.def.image ~= gen1Game.data.pokemon.FARFETCHD.spriteFront,
        "Gen1 does not reorder to spriteFront-first")
end

----------------------------------------------------------------
-- HGSS / Followers styles unchanged for Farfetch'd (runtime sheet)
----------------------------------------------------------------
do
  package.loaded["src.core.GameVersion"] = {
    get = function() return "gold" end,
    isYellow = function() return false end,
    isGold = function() return true end,
    generation = function(which)
      which = which or "gold"
      if which == "gold" then return 2 end
      return 1
    end,
  }
  savedOpts.sprite_style = "pokemmo"
  local result = providers:resolve("pokemmo", "FARFETCHD", "normal", game)
  eq(result.providerId, "pokemmo", "HGSS style uses pokemmo provider")
  eq(result.def.trueColor, true, "HGSS Farfetch'd trueColor true")
  check(result.def.frames and result.def.frames >= 6, "HGSS Farfetch'd walker sheet")

  savedOpts.sprite_style = "followers"
  result = providers:resolve("followers", "FARFETCHD", "normal", game)
  check(result.providerId == "followers_ex" or result.providerId == "pokemmo",
        "Followers style uses followers_ex or pokemmo fallback")
  eq(result.def.trueColor, true, "Followers Farfetch'd trueColor true")
end

print("")
if failures > 0 then
  io.stderr:write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
print("all gold_pokedex_sprite tests passed")
