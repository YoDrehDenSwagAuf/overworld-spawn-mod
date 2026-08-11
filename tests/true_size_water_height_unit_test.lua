-- HGSS True Size water/levitate: LAND opaque footprint is absolute size authority.
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

local WIDTH_LIMIT = 1.30
local AREA_LIMIT = 1.30
local HEIGHT_TOL = 1

local function assertLandAuthority(sheet, label)
  check(sheet ~= nil, label .. " sheet present")
  if not sheet then return end
  eq(sheet.hgssReferenceSource, "hgss_land_opaque_bounds",
    label .. " uses opaque land bounds authority")
  local landW = tonumber(sheet.landReferenceVisibleWidth)
  local landH = tonumber(sheet.landReferenceVisibleHeight)
  local landA = tonumber(sheet.landReferenceVisibleArea)
  local runW = tonumber(sheet.runtimeOpaqueWidth)
  local runH = tonumber(sheet.runtimeOpaqueHeight)
  local runA = tonumber(sheet.runtimeOpaqueArea)
  check(landW and landH and landA and runW and runH and runA,
    label .. " land/runtime opaque metadata present")
  if not (landW and landH and runW and runH) then return end
  check(runH <= landH + HEIGHT_TOL,
    string.format("%s height %d <= land %d +%d", label, runH, landH, HEIGHT_TOL))
  check(runW <= math.floor(landW * WIDTH_LIMIT + 1e-9),
    string.format("%s width %d <= floor(landW*%.2f)=%d",
      label, runW, WIDTH_LIMIT, math.floor(landW * WIDTH_LIMIT + 1e-9)))
  check(runA <= math.floor(landA * AREA_LIMIT + 1e-9),
    string.format("%s area %d <= floor(landA*%.2f)", label, runA, AREA_LIMIT))
  check(tonumber(sheet.finalVisualScale) ~= nil and tonumber(sheet.finalVisualScale) <= 1.0 + 1e-9,
    label .. " finalVisualScale <= 1 (no upscale past land)")
  local bias = tonumber(sheet.presentationBias)
  check(bias ~= nil and bias > 0.92 and bias <= 1.0,
    label .. " presentationBias in (0.92,1.0]")
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

-- Primary regressions
local rattata = swimMan.sheets["19:normal"]
assertLandAuthority(rattata, "Rattata")
if rattata then
  eq(tonumber(rattata.landReferenceVisibleWidth), 19, "Rattata land W")
  eq(tonumber(rattata.landReferenceVisibleHeight), 20, "Rattata land H")
  check(tonumber(rattata.runtimeOpaqueWidth) <= 24, "Rattata swim width capped")
  check(tonumber(rattata.runtimeOpaqueHeight) <= 20, "Rattata swim height <= land")
  check(tonumber(rattata.areaRatio) ~= nil and tonumber(rattata.areaRatio) <= AREA_LIMIT + 1e-6,
    "Rattata area ratio <= limit")
end

local blast = swimMan.sheets["9:normal"]
assertLandAuthority(blast, "Blastoise")
if blast then
  -- Wide swimming pose may remain wider than land, but within the ratio cap.
  check(tonumber(blast.runtimeOpaqueWidth) > tonumber(blast.landReferenceVisibleWidth),
    "Blastoise may stay wider than land")
  -- With presentation bias, height may be equal or a tick under land — never over.
  check(tonumber(blast.runtimeOpaqueHeight) <= tonumber(blast.landReferenceVisibleHeight),
    "Blastoise height <= land")
  check(tonumber(blast.presentationBias) == 0.95, "Blastoise uses 0.95 presentation bias")
end

-- Large / special cases
for _, dex in ipairs({ 66, 130, 131, 129, 54, 72, 7 }) do
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
check(type(swimAudit.sortedByAreaRatio) == "table" and #swimAudit.sortedByAreaRatio > 0,
  "swimming audit sorted list present")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("true_size_water_height_unit_test: all passed")
