-- Remaining love.filesystem mentions (intentional, not production runtime):
--   this test (simulates the current Sandbox.lua error)
--   CHANGELOG.md historical notes
-- Production lib/ and main.lua must stay at zero.
package.path = "./?.lua;./?/init.lua;" .. package.path

local realIo = io
local realDebug = debug
local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    realIo.stderr:write("FAIL: " .. tostring(msg) .. "\n")
  else
    print("ok  " .. tostring(msg))
  end
end

local function readFile(rel)
  local f = realIo.open(rel, "rb") or realIo.open("./" .. rel, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

-- Same error the current Sandbox.lua love facade raises.
local SANDBOX_FS_ERR = "love.filesystem is not available to mods, use mod.storage and mod:read"

love = setmetatable({
  graphics = { newImage = function() error("newImage unused in this test") end },
  image = {},
  timer = { getTime = function() return 0 end },
}, {
  __index = function(_, key)
    if key == "filesystem" then
      error(SANDBOX_FS_ERR, 2)
    end
    if key == "thread" or key == "system" or key == "event" then
      error(("love.%s is not available to mods"):format(key), 2)
    end
    return nil
  end,
  __newindex = function(_, key)
    error(("mods cannot assign love.%s"):format(tostring(key)), 2)
  end,
})

io = nil
debug = nil

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end, error = function() end },
    find = function() return nil end,
    read = function(_, rel) return readFile(rel) end,
    assets = {
      path = function(_, rel) return "mods/overworld_wild_spawns/" .. rel end,
    },
    options = { get = function() return nil end },
  },
  path = ".",
}

function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local src = readFile("lib/" .. name .. ".lua")
  check(src ~= nil, "can read lib/" .. name .. ".lua via captured io")
  local loader = loadstring or load
  local chunk, err = loader(src, "@lib/" .. name .. ".lua")
  if not chunk then
    check(false, "compile lib/" .. name .. ".lua: " .. tostring(err))
    return nil
  end
  local value = chunk(V)
  modules[name] = value
  return value
end

local function noFsErr(ok, err)
  local msg = tostring(err or "")
  return ok == true or not msg:find("love.filesystem", 1, true)
end

-- Production sources must not name the blocked module.
do
  local hits = {}
  local p = realIo.popen('find lib -name "*.lua" -print')
  if p then
    for line in p:lines() do
      local body = readFile(line)
      if type(body) == "string" and body:find("love.filesystem", 1, true) then
        hits[#hits + 1] = line
      end
    end
    p:close()
  end
  local mainBody = readFile("main.lua")
  if mainBody and mainBody:find("love.filesystem", 1, true) then
    hits[#hits + 1] = "main.lua"
  end
  check(#hits == 0, "production lib/ has zero love.filesystem identifiers ("
    .. table.concat(hits, ", ") .. ")")
end

local WildsFs = V.require("wilds_fs")
check(WildsFs ~= nil, "wilds_fs loads under sandbox love")

check(WildsFs.safeRel("../secret") == nil, "rejects parent segment")
check(WildsFs.safeRel("/etc/hosts") == nil, "rejects absolute path")
check(WildsFs.safeRel("..\\secret") == nil, "rejects backslash")
check(WildsFs.safeRel("assets/fallback/pokemon_missing.png")
  == "assets/fallback/pokemon_missing.png", "accepts packaged relative")

local okFs, fsErr = pcall(function() return love.filesystem end)
check(okFs == false, "love.filesystem access throws")
check(tostring(fsErr):find("mod.storage", 1, true) ~= nil,
  "sandbox error names mod.storage / mod:read")

local okRead, data = pcall(WildsFs.readAsset, V.mod,
  "assets/generated/followsprites_runtime/manifest.json")
check(noFsErr(okRead, data), "readAsset does not touch love.filesystem")
check(okRead and type(data) == "string" and #data > 0,
  "readAsset returns packaged manifest bytes")

local okExists, exists = pcall(WildsFs.assetExists, V.mod,
  "assets/generated/followsprites_runtime/001-normal.png")
check(noFsErr(okExists, exists), "assetExists does not touch love.filesystem")
check(okExists and exists == true, "packaged HGSS sheet exists via cacheable probe")

local okMiss, missing = pcall(WildsFs.assetExists, V.mod,
  "assets/enhanced_overworld/poke_followers/follower_999_normal.png")
check(noFsErr(okMiss, missing), "missing probe does not throw")
check(okMiss and missing == false, "unknown Fakemon path is a cached miss")
check(WildsFs.assetExists(V.mod,
  "assets/enhanced_overworld/poke_followers/follower_999_normal.png") == false,
  "missing path stays cached")

local RuntimeSheets = V.require("runtime_sheets")
local sheets = RuntimeSheets.new(V.mod)
local okLoad, loadErr = pcall(function() return sheets:load() end)
check(noFsErr(okLoad, loadErr), "runtime_sheets:load does not use love.filesystem")
check(okLoad and sheets:isReady(), "runtime sheets load via mod:read")

local okRel, rel = pcall(function()
  return sheets:resolveRelativePath(25, "normal")
end)
check(noFsErr(okRel, rel), "resolveRelativePath does not use love.filesystem")
check(okRel and type(rel) == "string" and rel:find("025%-normal%.png"),
  "Pikachu runtime sheet resolves")

local LuminanceSheet = V.require("luminance_sheet")
local okAvail, avail = pcall(LuminanceSheet.available)
check(noFsErr(okAvail, avail), "LuminanceSheet.available does not probe filesystem")
check(okAvail and not avail,
  "available() is false without love.image.newImageData (no throw)")

local Water = V.require("water_sprite_registry")
local water = Water.new(V.mod)
local okW, wErr = pcall(function() return water:load() end)
check(noFsErr(okW, wErr), "water_sprite_registry:load does not use love.filesystem")

local Animated = V.require("animated_sprites")
local anim = Animated.new(V.mod)
local okMap, mapErr = pcall(function() return anim:load() end)
check(noFsErr(okMap, mapErr), "animated_sprites mapping does not use love.filesystem")

local SpeciesGeometry = V.require("species_geometry")
local okGeo, geo = pcall(SpeciesGeometry.load, V.mod)
check(noFsErr(okGeo, geo), "species_geometry.load does not use love.filesystem")

local SpriteProviders = V.require("sprite_providers")
local providers = SpriteProviders.new(V.mod, nil)
local okF, fWhy = pcall(function()
  return providers:_builtinPokeFollowersReady()
end)
check(noFsErr(okF, fWhy), "poke followers probe does not use love.filesystem")
check(okF and fWhy == true, "built-in poke followers probe succeeds via mod:read")

io = realIo
debug = realDebug

if failures > 0 then
  realIo.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("sandbox_fs_compat_unit_test: all passed")
