-- HGSS True Size water/levitate: per-species perceived-size vs LAND medians.
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

local swimMan = assert(json.decode(read("assets/generated/true_size/swimming/manifest.json")))
local levMan = assert(json.decode(read("assets/generated/true_size/levitate/manifest.json")))
local swimAudit = assert(json.decode(read("assets/generated/true_size/swimming_size_audit.json")))
local levAudit = assert(json.decode(read("assets/generated/true_size/levitate_size_audit.json")))

local HEIGHT_TOL = 1
local PERC_LO = 0.90
local PERC_HI = 1.04
local PERC_FAIL = 1.06
local BIAS = 0.98

local function assertLandAuthority(sheet, label)
  check(sheet ~= nil, label .. " sheet present")
  if not sheet then return end
  eq(sheet.hgssReferenceSource, "hgss_land_median_frame",
    label .. " uses median-frame land authority")
  eq(sheet.artFamily, "hgss_water", label .. " artFamily hgss_water")
  local landW = tonumber(sheet.landReferenceVisibleWidth)
  local landH = tonumber(sheet.landReferenceVisibleHeight)
  local landA = tonumber(sheet.landReferenceVisibleArea)
  local runW = tonumber(sheet.runtimeOpaqueWidth)
  local runH = tonumber(sheet.runtimeOpaqueHeight)
  local runA = tonumber(sheet.runtimeOpaqueArea)
  local perc = tonumber(sheet.perceivedRatio)
  check(landW and landH and landA and runW and runH and runA and perc,
    label .. " land/runtime/perceived metadata present")
  if not (landW and landH and runW and runH and perc) then return end
  check(runH <= landH + HEIGHT_TOL,
    string.format("%s height %d <= land %d +%d", label, runH, landH, HEIGHT_TOL))
  -- Hard release gate: water must never look substantially larger than land.
  check(perc <= PERC_FAIL + 1e-9,
    string.format("%s perceivedRatio %.4f <= fail %.2f", label, perc, PERC_FAIL))
  check(tonumber(sheet.finalVisualScale) ~= nil and tonumber(sheet.finalVisualScale) <= 1.0 + 1e-9,
    label .. " finalVisualScale <= 1 (no upscale past land)")
  local bias = tonumber(sheet.presentationBias)
  check(bias ~= nil and math.abs(bias - BIAS) < 1e-9,
    label .. " presentationBias " .. tostring(BIAS))
  check(tonumber(sheet.speciesScale) ~= nil and tonumber(sheet.speciesScale) <= 1.0 + 1e-9,
    label .. " speciesScale present and <= 1")
end

-- Broad coverage: every normal swimming sheet honors the contract.
local swimCount = 0
for key, sheet in pairs(swimMan.sheets or {}) do
  if key:match(":normal$") then
    swimCount = swimCount + 1
    assertLandAuthority(sheet, "swim " .. key)
  end
end
check(swimCount >= 100, "regenerated swimming normals >= 100 (got " .. tostring(swimCount) .. ")")

local levCount = 0
for key, sheet in pairs(levMan.sheets or {}) do
  if key:match(":normal$") then
    levCount = levCount + 1
    assertLandAuthority(sheet, "lev " .. key)
  end
end
check(levCount >= 15, "regenerated levitate normals >= 15 (got " .. tostring(levCount) .. ")")

-- Primary regressions: Poliwag + Rattata
local poliwag = swimMan.sheets["60:normal"]
assertLandAuthority(poliwag, "Poliwag")
if poliwag then
  eq(tonumber(poliwag.landReferenceVisibleWidth), 14, "Poliwag land median W")
  eq(tonumber(poliwag.landReferenceVisibleHeight), 15, "Poliwag land median H")
  check(tonumber(poliwag.perceivedRatioBefore) ~= nil
      and tonumber(poliwag.perceivedRatioBefore) > 1.2,
    "Poliwag source was oversized before correction")
  check(tonumber(poliwag.perceivedRatio) >= 0.92
      and tonumber(poliwag.perceivedRatio) <= 1.02,
    "Poliwag perceived ratio in release band")
  check(tonumber(poliwag.runtimeOpaqueHeight) <= 15, "Poliwag swim height <= land")
end

local rattata = swimMan.sheets["19:normal"]
assertLandAuthority(rattata, "Rattata")
if rattata then
  eq(tonumber(rattata.landReferenceVisibleWidth), 12, "Rattata land median W")
  eq(tonumber(rattata.landReferenceVisibleHeight), 15, "Rattata land median H")
  check(tonumber(rattata.runtimeOpaqueHeight) <= 15, "Rattata swim height <= land")
  check(tonumber(rattata.perceivedRatio) >= 0.92
      and tonumber(rattata.perceivedRatio) <= 1.02,
    "Rattata perceived ratio in release band")
end

local blast = swimMan.sheets["9:normal"]
assertLandAuthority(blast, "Blastoise")
if blast then
  check(tonumber(blast.runtimeOpaqueWidth) > tonumber(blast.landReferenceVisibleWidth),
    "Blastoise may stay wider than land (pose)")
  check(tonumber(blast.runtimeOpaqueHeight) <= tonumber(blast.landReferenceVisibleHeight),
    "Blastoise height <= land")
end

-- Small / medium / large + special cases
for _, dex in ipairs({ 7, 54, 66, 129, 130, 131, 72 }) do
  local sheet = swimMan.sheets[string.format("%d:normal", dex)]
  assertLandAuthority(sheet, string.format("#%03d", dex))
end

-- Levitate examples
for _, dex in ipairs({ 92, 93, 109 }) do
  local sheet = levMan.sheets[string.format("%d:normal", dex)]
  assertLandAuthority(sheet, string.format("lev #%03d", dex))
end

-- Audits must be clean at FAIL thresholds.
eq(tonumber(swimAudit.failCount), 0, "swimming audit failCount=0")
eq(tonumber(levAudit.failCount), 0, "levitate audit failCount=0")
check(type(swimAudit.sortedByPerceivedDeviation) == "table"
    and #swimAudit.sortedByPerceivedDeviation > 0,
  "swimming audit sorted-by-perceived list present")
check(tonumber(swimAudit.limits.presentationBias) == BIAS,
  "swimming audit records presentationBias 0.98")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("true_size_water_height_unit_test: all passed")
