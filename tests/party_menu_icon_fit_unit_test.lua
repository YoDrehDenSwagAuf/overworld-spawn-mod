-- Party/OPTIONS menu icon fit: fixed UI box, aspect-preserving, True Size ignored.
-- Run: lua tests/party_menu_icon_fit_unit_test.lua
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
  check(math.abs((a or 0) - (b or 0)) <= (eps or 1e-6),
    string.format("%s (got %s expected %s)", msg, tostring(a), tostring(b)))
end

local modules = {}
local savedOpts = { pokemon_size = "true_size", sprite_style = "pokemmo" }
local V = {
  mod = {
    path = ".",
    log = { info = function() end },
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
  pokemonSizeMode = function() return savedOpts.pokemon_size or "classic" end,
  normalizePokemonSize = function(v)
    if v == "true_size" then return "true_size" end
    return "classic"
  end,
  normalizeSpriteStyle = function(v) return v or "followers" end,
  spriteStyle = function() return savedOpts.sprite_style or "followers" end,
  paletteFxRedpp = function() return false end,
  debug = function() return false end,
}
modules.debug_log = { warn = function() end, info = function() end, error = function() end, debug = function() end }
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16 }
modules.json_decode = assert(loadfile("lib/json_decode.lua"))(V)
modules["follower/constants"] = {
  SPRITE_ID = "SPRITE_PIKACHU",
  CONTROL_ENGINE_STATE_KEY = "_wildsControlEngine",
}

local SpriteService = V.require("follower/sprite_service")

eq(SpriteService.PARTY_ICON_BOX, 16, "party icon box is Classic 16")

-- Classic 16×16: identity fit
local s, ox, oy, dw, dh = SpriteService.partyIconFit(16, 16, 16)
eq(s, 1, "classic scale=1")
eq(ox, 0, "classic ox=0")
eq(oy, 0, "classic oy=0")
eq(dw, 16, "classic drawW=16")
eq(dh, 16, "classic drawH=16")

-- Onix True Size frame 35×38 → uniform fit into 16×16 (no stretch)
s, ox, oy, dw, dh = SpriteService.partyIconFit(35, 38, 16)
near(s, 16 / 38, 1e-6, "Onix uniform scale by height")
check(math.abs(s - 16 / 35) > 1e-6, "Onix does not use non-uniform width scale")
check(dw <= 16 + 1e-6 and dh <= 16 + 1e-6, "Onix draw stays inside box")
near(dh, 16, 1e-6, "Onix height fills box")
check(ox > 0, "Onix horizontally centered")

-- Prefer visible body bounds when padded frame is larger (padding may
-- overflow the box; drawPartyIcon scissors to the fixed slot).
s, ox, oy, dw, dh = SpriteService.partyIconFit(35, 38, 16, 27, 30)
near(s, 16 / 30, 1e-6, "visible-bounds scale")
check(s > 16 / 38, "visible-bounds larger than padded-frame fit")

-- Footprint invariant: Classic vs True Size both claim the same UI box.
eq(SpriteService.PARTY_ICON_BOX, 16, "claimed UI box stays 16 for Classic")
local sTS = select(1, SpriteService.partyIconFit(35, 38, 16, 27, 30))
check(sTS > 0 and sTS <= 1, "True Size still scales into the same 16 box")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nPASS party_menu_icon_fit_unit_test")
