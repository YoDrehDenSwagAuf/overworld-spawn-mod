-- HGSS True Size water/levitate: opaque body height matches LAND reference.
-- Run: lua tests/true_size_water_height_unit_test.lua
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

local V = { path = ".", mod = {}, require = function() error("no nested require") end }
local json = assert(loadfile("lib/json_decode.lua"))(V)

local function read(path)
  local f = assert(io.open(path, "rb"))
  local d = f:read("*a")
  f:close()
  return d
end

local geom = assert(json.decode(read("assets/generated/true_size/species_geometry.json")))
local swimMan = assert(json.decode(read("assets/generated/true_size/swimming/manifest.json")))

-- Native prototype species with True Size swimming art.
local NATIVE_WATER = { 19, 9, 95 } -- Rattata, Blastoise, Onix
-- Integer NN scaling may differ by ±1 px from the exact reference height.
local TOL = 1

for _, dex in ipairs(NATIVE_WATER) do
  local entry = geom[tostring(dex)] or geom[dex]
  check(entry ~= nil, string.format("#%03d geometry entry", dex))
  if entry then
    eq(entry.sizing, "native", string.format("#%03d sizing=native", dex))
    local landRef = tonumber(entry.landReferenceVisibleHeight)
    check(landRef ~= nil and landRef > 0,
      string.format("#%03d landReferenceVisibleHeight present", dex))

    local pack = entry.packs and entry.packs.swimming
    check(pack ~= nil, string.format("#%03d swimming pack", dex))
    if pack then
      -- Canvas may be wider than land; do not require frameWidth equality.
      local land = entry.packs.pokemmo
      check(land ~= nil, string.format("#%03d land pack", dex))
      if land then
        check(pack.frameWidth >= land.frameWidth - 2,
          string.format("#%03d swimming may be as wide or wider", dex))
      end
    end

    for _, variant in ipairs({ "normal", "shiny" }) do
      local key = string.format("%d:%s", dex, variant)
      local sheet = swimMan.sheets and swimMan.sheets[key]
      check(sheet ~= nil, string.format("#%03d swimming %s manifest", dex, variant))
      if sheet then
        eq(sheet.hgssReferenceSource, "hgss_land_opaque_height",
          string.format("#%03d %s uses opaque land height", dex, variant))
        local refH = tonumber(sheet.hgssReferenceVisibleHeight)
        local opaqueH = tonumber(sheet.runtimeOpaqueHeight)
        check(refH ~= nil and opaqueH ~= nil,
          string.format("#%03d %s opaque/ref heights present", dex, variant))
        if refH and opaqueH then
          local d = math.abs(opaqueH - refH)
          check(d <= TOL,
            string.format("#%03d %s opaqueH=%d ~= landRef=%d (tol %d, d=%d)",
              dex, variant, opaqueH, refH, TOL, d))
        end
        -- Explicit: do not force swimming canvas == land canvas.
        check(tonumber(sheet.runtimeFrameWidth) ~= nil,
          string.format("#%03d %s has frame width", dex, variant))
      end
    end
  end
end

-- Rattata primary regression: swimming body must not exceed land opaque height
-- by more than NN tolerance (previously matched inflated 24px crop window).
local rattata = swimMan.sheets["19:normal"]
check(rattata ~= nil, "Rattata swimming normal sheet")
if rattata then
  eq(tonumber(rattata.hgssReferenceVisibleHeight), 20, "Rattata land opaque ref = 20")
  eq(tonumber(rattata.runtimeOpaqueHeight), 20, "Rattata swimming opaque height = 20")
  check(tonumber(rattata.runtimeFrameWidth) > 25,
    "Rattata swimming canvas may stay wider than land")
end

-- Blastoise: height-matched, wider canvas allowed.
local blast = swimMan.sheets["9:normal"]
check(blast ~= nil, "Blastoise swimming normal sheet")
if blast then
  eq(tonumber(blast.hgssReferenceVisibleHeight), 24, "Blastoise land opaque ref = 24")
  eq(tonumber(blast.runtimeOpaqueHeight), 24, "Blastoise swimming opaque height = 24")
  check(tonumber(blast.runtimeFrameWidth) >= 35, "Blastoise swimming remains wide")
end

-- Confirm HUD/projectile separation still documented in generator notes.
local notes = swimMan.notes or {}
local noteBlob = table.concat(notes, " ")
check(noteBlob:find("HGSS", 1, true) ~= nil, "swimming manifest mentions HGSS reference")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("true_size_water_height_unit_test: all passed")
