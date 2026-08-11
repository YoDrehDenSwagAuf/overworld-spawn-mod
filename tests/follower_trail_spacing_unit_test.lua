-- True Size visual follower trail spacing (history lag, not collision).
-- Run: lua tests/follower_trail_spacing_unit_test.lua
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
local function near(a, b, eps, msg)
  check(math.abs((a or 0) - (b or 0)) <= (eps or 0.05),
    string.format("%s (got %s expected ~%s)", msg, tostring(a), tostring(b)))
end

package.loaded["src.render.SpriteRenderer"] = {
  new = function(def, id) return { def = def, id = id } end,
  DEFAULT_FRAME_WIDTH = 16,
  DEFAULT_FRAME_HEIGHT = 16,
  getFrameGeometry = function() end,
  getPoseGeometry = function() end,
  getScreenOrigin = function() end,
}

local modules = {}
local savedOpts = { pokemon_size = "true_size", sprite_style = "pokemmo" }
local V = {
  mod = {
    path = ".",
    log = { info = function() end },
    find = function() return nil end,
    options = {
      get = function(_, k) return savedOpts[k] end,
      set = function(_, k, v) savedOpts[k] = v end,
    },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a"); f:close(); return data
    end,
    assets = { path = function(_, rel) return rel end },
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
  DEFAULTS = { pokemon_size = "classic", sprite_style = "followers" },
  peekSavedOption = function(_, k)
    if savedOpts[k] ~= nil then return savedOpts[k], true end
    return nil, false
  end,
  pokemonSizeMode = function()
    return savedOpts.pokemon_size or "classic"
  end,
  normalizePokemonSize = function(v)
    if v == "true_size" then return "true_size" end
    return "classic"
  end,
  normalizeSpriteStyle = function(v) return v or "followers" end,
  spriteStyle = function() return savedOpts.sprite_style or "followers" end,
  debug = function() return false end,
}
modules.debug_log = { warn = function() end, info = function() end, error = function() end, debug = function() end }
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }
modules.json_decode = assert(loadfile("lib/json_decode.lua"))(V)

local SpeciesGeometry = V.require("species_geometry")
local VariableSize = V.require("variable_size")

-- Continuous width-based desired gaps (px)
local pikaPx = SpeciesGeometry.desiredFollowGapPx(nil, 25)
local blastPx = SpeciesGeometry.desiredFollowGapPx(nil, 9)
local onixPx = SpeciesGeometry.desiredFollowGapPx(nil, 95)
check(pikaPx >= 16 and pikaPx < 21, "Pikachu desired gap near Classic (" .. tostring(pikaPx) .. ")")
check(blastPx > pikaPx and blastPx < 25, "Blastoise slightly more than Pikachu, under 2-tile threshold")
check(onixPx >= 25 and onixPx <= 36, "Onix override in exceptional px band")

eq(SpeciesGeometry.followGap(25), 1, "Pikachu cells=1")
eq(SpeciesGeometry.followGap(19), 1, "Rattata cells=1")
eq(SpeciesGeometry.followGap(9), 1, "Blastoise cells=1 (no 2-tile hole)")
eq(SpeciesGeometry.followGap(95), 2, "Onix override cells=2 (not 3)")
eq(SpeciesGeometry.followGap(130), 2, "Gyarados override cells=2 (not 3)")
eq(SpeciesGeometry.followGap(143), 2, "Snorlax override cells=2")
eq(SpeciesGeometry.followGapBetween(nil, 25), 1, "first follower Pikachu gap=1")
eq(SpeciesGeometry.followGapBetween(nil, 9), 1, "first follower Blastoise gap=1")

-- Pair-specific: wide front may push the next link to 2 without a global gap.
local blastRattaPx = SpeciesGeometry.desiredFollowGapPx(9, 19)
local charRattaPx = SpeciesGeometry.desiredFollowGapPx(6, 19)
check(blastRattaPx >= 16, "Blastoise→Rattata pair gap defined")
check(charRattaPx >= blastRattaPx, "Charizard→Rattata needs at least as much room")

-- Hysteresis: no 1↔2 flicker around the midpoint
eq(SpeciesGeometry.applyGapHysteresis(24, 1), 1, "stay 1 below up-threshold")
eq(SpeciesGeometry.applyGapHysteresis(25, 1), 2, "switch 1→2 at 25px")
eq(SpeciesGeometry.applyGapHysteresis(22, 2), 2, "stay 2 above down-threshold")
eq(SpeciesGeometry.applyGapHysteresis(20, 2), 1, "switch 2→1 below 21px")

-- Classic effective → visualFollowGap always 1
savedOpts.pokemon_size = "classic"
eq(VariableSize.visualFollowGap(V.mod, 95), 1, "Classic mode Onix gap=1")
savedOpts.pokemon_size = "true_size"
eq(VariableSize.visualFollowGap(V.mod, 95), 2, "True Size Onix gap=2")

-- ControlEngine history lag assignment
local ControlEngine = V.require("follower/control_engine")
local engine = setmetatable({
  mod = V.mod,
  diag = {},
}, ControlEngine)

check(engine:_visualTrailSpacingActive() == true, "trail spacing active in True Size")

local ow = { pokepcTrailHistory = {} }
local path = {
  {0,0},{0,1},{0,2},{0,3},{0,4},{0,5},{0,6},{0,7},{0,8},{0,9},
}
for _, c in ipairs(path) do
  engine:_pushTrailHistory(ow, c[1], c[2])
end

local blastoise = { _wildsFollowerDex = 9, _wildsFollowerSpecies = "BLASTOISE" }
local pikachu = { _wildsFollowerDex = 25, _wildsFollowerSpecies = "PIKACHU" }
local goals = engine:_goalsFromTrailHistory(ow, { blastoise, pikachu }, 0, 9)
-- Blastoise pair gap=1 → history[1]=(0,9); Pikachu pair gap=1 → lag=2 → (0,8)
eq(goals[1].y, 9, "Blastoise follows lag=1")
eq(goals[2].y, 8, "Pikachu follows lag=2 (accumulates behind Blastoise)")

local onix = { _wildsFollowerDex = 95 }
local snorlax = { _wildsFollowerDex = 143 }
local goals2 = engine:_goalsFromTrailHistory(ow, { onix, snorlax, pikachu }, 0, 9)
-- Pair gaps: Onix=2 → lag2; Snorlax behind Onix=2 → lag4; Pikachu behind
-- wide Snorlax crosses 25px → 2 → lag6
eq(goals2[1].y, 8, "Onix lag=2")
eq(goals2[2].y, 6, "Snorlax lag=4")
eq(goals2[3].y, 4, "Pikachu lag=6 behind wide Snorlax")

-- Warmup forces Classic 1-cell gaps for 2 committed steps
local owWarm = { pokepcTrailHistory = {} }
for _, c in ipairs(path) do
  engine:_pushTrailHistory(owWarm, c[1], c[2])
end
engine:_beginSpacingWarmup(owWarm, 2)
eq(owWarm._wildsSpacingWarmupSteps, 2, "warmup armed at 2")
local warmGoals = engine:_goalsFromTrailHistory(owWarm, { onix, snorlax }, 0, 9)
eq(warmGoals[1].y, 9, "warmup Onix lag=1")
eq(warmGoals[2].y, 8, "warmup Snorlax lag=2 (classic snake)")
engine:_tickSpacingWarmup(owWarm)
engine:_tickSpacingWarmup(owWarm)
check(owWarm._wildsSpacingWarmupSteps == nil, "warmup cleared after 2 ticks")
local after = engine:_goalsFromTrailHistory(owWarm, { onix }, 0, 9)
eq(after[1].y, 8, "after warmup Onix uses adaptive lag=2")

-- Classic deactivates spacing
savedOpts.pokemon_size = "classic"
check(engine:_visualTrailSpacingActive() == false, "Classic disables visual trail spacing")
eq(engine:_followGapForSource(onix), 1, "Classic Onix follow gap=1")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nPASS follower_trail_spacing_unit_test")
