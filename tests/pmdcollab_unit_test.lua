-- PMDCollab importer + sprite/portrait/idle unit tests (no full SpriteCollab).
-- Run: luajit tests/pmdcollab_unit_test.lua
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

------------------------------------------------------------------------
-- A) Importer against checked-in mini fixture (no 1.9GB clone)
------------------------------------------------------------------------
print("== importer fixture ==")
local rc = os.execute([[python3 - <<'PY'
import sys
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location("import_pmdcollab", "scripts/import_pmdcollab.py")
imp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(imp)
imp.ROOT = Path("/tmp/wilds_pmd_import_test")
imp.OUT = imp.ROOT / "assets" / "pmdcollab"
sys.argv = ["import_pmdcollab.py", "tests/fixtures/spritecollab_mini", "--dex-max", "2", "--clean"]
raise SystemExit(imp.main())
PY]])
check(rc == true or rc == 0, "importer exits 0 on fixture")

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end
check(exists("/tmp/wilds_pmd_import_test/assets/pmdcollab/sprites/001-normal.png"),
  "fixture produced bulbasaur walk sheet")
check(exists("/tmp/wilds_pmd_import_test/assets/pmdcollab/portraits/001/normal/normal.png"),
  "fixture produced bulbasaur normal portrait")
check(exists("/tmp/wilds_pmd_import_test/assets/pmdcollab/SOURCE.json"), "SOURCE.json written")
check(exists("/tmp/wilds_pmd_import_test/assets/pmdcollab/CREDITS.txt"), "CREDITS.txt written")
check(exists("/tmp/wilds_pmd_import_test/assets/pmdcollab/LICENSE.txt"), "LICENSE.txt written")

------------------------------------------------------------------------
-- B) Runtime tables from real committed assets
------------------------------------------------------------------------
print("== runtime assets ==")
local modules = {}
local savedOpts = { sprite_style = "pmdcollab" }
local V = {
  mod = {
    path = ".",
    id = "overworld_wild_spawns",
    log = { info = function() end, warn = function() end, error = function() end },
    find = function() return nil end,
    options = {
      get = function(_, key) return savedOpts[key] end,
    },
    assets = {
      path = function(_, rel) return "mods/overworld_wild_spawns/" .. rel end,
    },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    content = {
      pokemon = { get = function() return nil end, each = function() return function() end end },
      sprites = { get = function() return nil end },
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

modules.config = {
  DEFAULTS = { sprite_style = "followers" },
  spriteStyle = function() return savedOpts.sprite_style or "followers" end,
  normalizeSpriteStyle = function(v)
    if v == "pmdcollab" or v == "pokemmo" or v == "followers" or v == "pokedex" then
      return v
    end
    return "followers"
  end,
  pokemonSizeMode = function()
    local s = savedOpts.sprite_style
    if s == "pokemmo" or s == "pmdcollab" then return "true_size" end
    return "classic"
  end,
  VALID_SPRITE_STYLES = {
    pokemmo = true, followers = true, pokedex = true, pmdcollab = true,
  },
}
modules.debug_log = {
  warn = function() end, info = function() end, error = function() end, debug = function() end,
}
modules.wilds_fs = {
  pathExists = function() return true end,
  assetExists = function() return true end,
}
modules.runtime_sheets = { new = function() return { ready = false, load = function() end, isReady = function() return false end } end }
modules.animated_sprites = {
  normalizeVariant = function(v)
    if v == true or v == "shiny" or v == "s" then return "shiny" end
    return "normal"
  end,
  normalizeFacing = function(f) return f or "down" end,
}
modules.variable_size = {
  applyToDef = function(_, def) return def, { applied = false } end,
  effectiveMode = function() return "classic" end,
}
modules.luminance_sheet = {}
modules.json_decode = { decode = function() return nil end }
modules.tile = { CELL = 16 }

local SpeciesAssets = V.require("species_assets")
local Assets = V.require("pmdcollab_assets")
check(Assets.load(V.mod) == true, "pmdcollab assets load")
local entry = Assets.spriteEntry(1, "normal")
check(entry ~= nil, "bulbasaur sprite entry")
eq(entry.frameWidth, 40, "bulbasaur frameWidth")
check((entry.idleFrameCount or 0) > 0, "bulbasaur has idle frames")
local ivy = Assets.spriteEntry(2, "normal")
check(ivy ~= nil, "ivysaur sprite entry")
check(entry.rel ~= ivy.rel, "bulbasaur != ivysaur sheet")

-- Species identity: PIKACHU → 25, not dex position
eq(SpeciesAssets.idFor("PIKACHU"), 25, "PIKACHU asset id")
local pika = Assets.spriteEntry(SpeciesAssets.idFor("PIKACHU"), "normal")
check(pika ~= nil, "pikachu via species identity")
-- Fakemon
eq(SpeciesAssets.idFor("FAKEMON_X"), nil, "unknown fakemon → nil asset id")
check(Assets.spriteEntry(SpeciesAssets.idFor("FAKEMON_X"), "normal") == nil,
  "fakemon no pmd sprite")

-- Shiny fallback
local shiny = Assets.spriteEntry(1, "shiny")
check(shiny ~= nil, "shiny bulbasaur or fallback")

------------------------------------------------------------------------
-- C) Provider resolve
------------------------------------------------------------------------
print("== sprite provider ==")
local render = {
  runtimeSheets = { ready = false, load = function() end, isReady = function() return false end },
  _modAssetPath = function(_, rel) return "mods/overworld_wild_spawns/" .. rel end,
  fallbackPath = "assets/fallback/pokemon_missing.png",
}
local SpriteProviders = V.require("sprite_providers")
local providers = SpriteProviders.new(V.mod, render)
local okAvail = providers:providerAvailable("pmdcollab", nil)
check(okAvail == true, "pmdcollab provider available")
local result = providers:resolve("pmdcollab", "BULBASAUR", "normal", nil)
check(result and result.def, "resolve bulbasaur")
eq(result.providerId, "pmdcollab", "provider id")
check(result.def.walker == true, "walker")
check(tonumber(result.def.frameWidth) == 40, "native frameWidth preserved")
local result2 = providers:resolve("pmdcollab", "IVYSAUR", "normal", nil)
check(result2 and result2.def and result2.def.image ~= result.def.image,
  "ivysaur distinct from bulbasaur")
local fake = providers:resolve("pmdcollab", "FAKEMON_X", "normal", nil)
check(fake == nil or fake.providerId == "black" or fake.providerId == "pokedex"
  or (fake.meta and fake.meta.fallback), "fakemon falls through chain safely")

-- Directions mapping documented in idle helpers
local PmdIdle = V.require("pmd_idle")
eq(PmdIdle.idleFrameBase(3, "down"), 6, "idle base down")
eq(PmdIdle.idleFrameBase(3, "up"), 9, "idle base up")
eq(PmdIdle.idleFrameBase(3, "left"), 12, "idle base left")
eq(PmdIdle.idleFrameBase(3, "right"), 15, "idle base right")

------------------------------------------------------------------------
-- D) Idle schedule / interrupt (seeded RNG)
------------------------------------------------------------------------
print("== idle presentation ==")
local seq = { 0.1, 0.1, 0.1, 0.9, 0.1 }
local si = 0
local function rng()
  si = si + 1
  return seq[((si - 1) % #seq) + 1]
end
local ent = {
  facing = "down",
  moving = false,
  _pmdIdleMeta = { idleFrameCount = 3, idleDurations = { 4, 4, 4 } },
  spriteProviderId = "pmdcollab",
  visibleSprite = true,
}
PmdIdle.schedule(ent, rng)
check(ent._pmdIdle and ent._pmdIdle.delay >= 3 and ent._pmdIdle.delay <= 8,
  "idle delay in 3–8s")
-- Not eligible while moving
ent.moving = true
check(PmdIdle.isEligible(ent) == false, "ineligible while moving")
ent.moving = false
check(PmdIdle.isEligible(ent) == true, "eligible when standing")
-- Force start by exhausting delay
ent._pmdIdle.elapsed = 100
ent._pmdIdle.delay = 1
-- PLAY_CHANCE gate: force pass with rng returning 0.0
si = 0
seq = { 0.0 }
PmdIdle.update(ent, 0.01, rng)
check(ent._pmdIdle.playing == true, "idle starts after delay")
check(PmdIdle.frameOverride(ent) == 6, "frame override stand-down idle0")
-- Interrupt on movement
ent.moving = true
PmdIdle.update(ent, 0.01, rng)
check(ent._pmdIdle.playing ~= true, "idle interrupts on movement")

------------------------------------------------------------------------
-- E) Portraits independent of sprite style
------------------------------------------------------------------------
print("== portraits vs sprite styles ==")
local PortraitRegistry = V.require("portrait_registry")
local styles = { "followers", "pokemmo", "pokedex", "pmdcollab" }
for _, style in ipairs(styles) do
  savedOpts.sprite_style = style
  local p = PortraitRegistry.resolve("PIKACHU", {
    mod = V.mod,
    randomGeneric = false,
    mood = "normal",
  })
  check(p ~= nil and p.rel ~= nil,
    "portrait resolves with sprite style=" .. style)
  check(p.rel:find("pmdcollab/portraits", 1, true) ~= nil,
    "portrait path is pmdcollab for style=" .. style)
end

-- Random generic from safe pool, stable call returns one emotion
local seed = 0.42
local p2 = PortraitRegistry.resolve("PIKACHU", {
  mod = V.mod,
  randomGeneric = true,
  rng = function() return seed end,
})
check(p2 and p2.emotion, "random generic emotion picked")
local pool = {}
for _, e in ipairs(PortraitRegistry.GENERIC_POOL) do pool[e] = true end
check(pool[p2.emotion] == true, "emotion in safe pool")

-- Missing portrait / fakemon → nil (normal TextBox)
local miss = PortraitRegistry.resolve("FAKEMON_X", { mod = V.mod, randomGeneric = true })
check(miss == nil, "fakemon portrait nil")

-- PokemonDialogue wrapper does not crash without love
local PokemonDialogue = V.require("pokemon_dialogue")
modules.game_compat = {
  presentText = function() return "textBox" end,
  presentTextChoice = function() return "textBoxChoice" end,
}
local r = PokemonDialogue.presentText(V.mod, { stack = { top = function() return nil end } },
  nil, "Pika!", function() end, { species = "PIKACHU", randomGeneric = true })
eq(r, "textBox", "presentText delegates")

------------------------------------------------------------------------
-- F) Option label validation
------------------------------------------------------------------------
print("== option labels ==")
local labelRc = os.execute("python3 tools/validate_option_labels.py >/tmp/opt_labels.txt 2>&1")
check(labelRc == true or labelRc == 0, "validate_option_labels ok")
local asciiRc = os.execute("python3 scripts/validate-manager-ascii.py >/tmp/ascii.txt 2>&1")
check(asciiRc == true or asciiRc == 0, "validate-manager-ascii ok")

------------------------------------------------------------------------
-- G) Config normalization
------------------------------------------------------------------------
print("== config ==")
-- Use real Config module
modules.config = nil
package.loaded["lib/config"] = nil
-- Reload config properly
local ConfigChunk = assert(loadfile("lib/config.lua"))
local Config = ConfigChunk(V)
modules.config = Config
eq(Config.normalizeSpriteStyle("pmdcollab"), "pmdcollab", "normalize keeps pmdcollab")
eq(Config.normalizeSpriteStyle("nope"), "followers", "unknown → followers default")
savedOpts.sprite_style = "pmdcollab"
eq(Config.pokemonSizeMode(V.mod), "true_size", "pmdcollab size mode true_size")
savedOpts.sprite_style = "followers"
eq(Config.pokemonSizeMode(V.mod), "classic", "followers still classic")

print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("ALL PASSED")
