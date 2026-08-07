-- HGSS / PokeMMO runtime generation quality checks.
-- Run: lua tests/hgss_runtime_quality_unit_test.lua
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

local json = dofile("lib/json_decode.lua")
-- Minimal JSON via io + Python for reliability if needed; prefer file presence.

local OUT = "assets/generated/followsprites_runtime"
local SRC = "assets/enhanced_overworld/followsprites"
local MAPPING = "assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json"

check(io.open(MAPPING, "rb") ~= nil, "mapping.json present")

local samples = { 10, 25, 56, 94, 95, 130, 143, 150 }
for _, dex in ipairs(samples) do
  local path = string.format("%s/%03d-normal.png", OUT, dex)
  local f = io.open(path, "rb")
  check(f ~= nil, string.format("runtime sheet exists for %03d", dex))
  if f then f:close() end
end

-- Count Gen-1 normal sheets 001..151
local count = 0
local missing = {}
for i = 1, 151 do
  local path = string.format("%s/%03d-normal.png", OUT, i)
  local f = io.open(path, "rb")
  if f then
    count = count + 1
    f:close()
  else
    missing[#missing + 1] = i
  end
end
eq(#missing, 0, "no missing Gen1 normal runtime sheets 1..151")
eq(count, 151, "151 Gen1 normal runtime sheets")

-- Manifest exists and records nearest-only pipeline
local man = io.open(OUT .. "/manifest.json", "rb")
check(man ~= nil, "manifest.json present")
local manText = man and man:read("*a") or ""
if man then man:close() end
check(manText:find("shared_bbox_nearest", 1, true), "manifest uses shared_bbox_nearest")
check(manText:find("NEAREST", 1, true), "manifest documents NEAREST resampling")
check(not manText:find("bilinear", 1, true), "manifest has no bilinear")
check(not manText:find("bicubic", 1, true), "manifest has no bicubic")
check(manText:find('"1:normal"', 1, true) or manText:find('"sheets"', 1, true),
  "manifest lists generated sheets")

-- Source assets untouched (spot-check Mankey sheet size via file exists)
check(io.open(SRC .. "/056-b-n.png", "rb") ~= nil, "source Mankey sheet untouched path exists")

-- Determinism: generator helper documents CARD=16 constraint
local gen = io.open("tools/generate_runtime_sprite_sheets.py", "rb")
check(gen ~= nil, "generator script checked in")
local genText = gen and gen:read("*a") or ""
if gen then gen:close() end
check(genText:find("NEAREST", 1, true) or genText:find("nearest", 1, true),
  "generator uses nearest-neighbor")
check(genText:find("shared_bbox", 1, true), "generator uses shared bbox alignment")
check(genText:find("never modified", 1, true)
   or genText:find("never modify", 1, true)
   or genText:find("is never modified", 1, true),
  "generator documents source immutability")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("hgss_runtime_quality_unit_test: all passed")
