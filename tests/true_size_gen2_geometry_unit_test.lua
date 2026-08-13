-- True Size geometry: Gen1 1..151 snapshot unchanged; Gen2 152..251 present.
-- Run: lua tests/true_size_gen2_geometry_unit_test.lua
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

local src = assert(loadfile("assets/generated/true_size/species_table.lua"))
local table = src()
check(type(table) == "table", "species_table.lua loads")

local function packGeom(entry, pack)
  pack = pack or "pokemmo"
  local p = entry and entry.packs and entry.packs[pack]
  if not p then return nil end
  return {
    frameWidth = p.frameWidth,
    frameHeight = p.frameHeight,
    anchorX = p.anchorX,
    anchorY = p.anchorY,
  }
end

local function hasGeom(dex, pack)
  local g = packGeom(table[dex], pack)
  if not g then return false end
  return type(g.frameWidth) == "number" and g.frameWidth > 0
     and type(g.frameHeight) == "number" and g.frameHeight > 0
     and type(g.anchorX) == "number"
     and type(g.anchorY) == "number"
end

-- Frozen Gen1 snapshot (HGSS/pokemmo pack) from the working True Size output.
-- These must remain identical after extending the generator range to 251.
local GEN1_SNAPSHOT = {
  [19]  = { frameWidth = 25, frameHeight = 28, anchorX = 12.5, anchorY = 26.0 }, -- Rattata
  [25]  = { frameWidth = 18, frameHeight = 18, anchorX = 9.0,  anchorY = 18 },   -- Pikachu
  [9]   = { frameWidth = 31, frameHeight = 30, anchorX = 15.5, anchorY = 28.0 }, -- Blastoise
  [95]  = { frameWidth = 35, frameHeight = 38, anchorX = 17.5, anchorY = 36.0 }, -- Onix
  [130] = { frameWidth = 40, frameHeight = 40, anchorX = 20.0, anchorY = 40 },   -- Gyarados
  [151] = { frameWidth = 21, frameHeight = 21, anchorX = 10.5, anchorY = 21 },   -- Mew
}

-- Read live table for the snapshot keys so the test documents actual values
-- if the frozen numbers above drift from a legitimate prior Gen1 change.
-- The assertion is "current file matches snapshot constants".
for dex, expect in pairs(GEN1_SNAPSHOT) do
  local got = packGeom(table[dex], "pokemmo")
  check(got ~= nil, "Gen1 dex " .. dex .. " exists")
  if got then
    eq(got.frameWidth, expect.frameWidth, "dex " .. dex .. " frameWidth unchanged")
    eq(got.frameHeight, expect.frameHeight, "dex " .. dex .. " frameHeight unchanged")
    eq(got.anchorX, expect.anchorX, "dex " .. dex .. " anchorX unchanged")
    eq(got.anchorY, expect.anchorY, "dex " .. dex .. " anchorY unchanged")
  end
end

local GEN2_IDS = {
  152, -- Chikorita
  155, -- Cyndaquil
  158, -- Totodile
  161, -- Sentret
  248, -- Tyranitar
  249, -- Lugia
  250, -- Ho-Oh
  251, -- Celebi
}

local missingGen2 = {}
for _, dex in ipairs(GEN2_IDS) do
  if not hasGeom(dex, "pokemmo") then
    missingGen2[#missingGen2 + 1] = dex
  else
    local g = packGeom(table[dex], "pokemmo")
    check(g.frameWidth >= 16, "dex " .. dex .. " frameWidth >= 16")
    check(g.frameHeight >= 16, "dex " .. dex .. " frameHeight >= 16")
    check(g.anchorY >= g.frameHeight * 0.4, "dex " .. dex .. " anchorY in-frame")
    print(string.format(
      "ok  Gen2 #%d pokemmo %sx%s anchor=(%s,%s)",
      dex, tostring(g.frameWidth), tostring(g.frameHeight),
      tostring(g.anchorX), tostring(g.anchorY)))
  end
end

if #missingGen2 > 0 then
  check(false, "Gen2 geometry missing for " .. table.concat(missingGen2, ","))
end

-- Shared table may include 1..251; 1 and 151 still present.
check(table[1] ~= nil, "dex 1 still present")
check(table[151] ~= nil, "dex 151 still present")

if failures > 0 then
  io.stderr:write(string.format("\n%d failure(s)\n", failures))
  os.exit(1)
end
print("\nAll True Size Gen2 geometry tests passed.")
