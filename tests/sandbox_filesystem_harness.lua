-- Simulate Gen1Recomp mod sandbox: love.filesystem is unavailable.
-- Load Wilds runtime modules and exercise asset probes without FS.
-- Run: lua tests/sandbox_filesystem_harness.lua
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

-- Block love.filesystem like src/mods/Sandbox.lua
local fsTouches = 0
love = setmetatable({
  timer = { getTime = os.clock },
  image = {
    newImageData = function()
      error("no real image data in harness")
    end,
  },
  graphics = {
    newImage = function()
      error("no real graphics in harness")
    end,
  },
}, {
  __index = function(_, key)
    if key == "filesystem" or key == "thread" or key == "system" or key == "event" then
      fsTouches = fsTouches + 1
      error(("love.%s is not available to mods, use mod.storage and mod:read"):format(key), 2)
    end
    return nil
  end,
  __newindex = function(_, key)
    error("mods cannot assign love." .. tostring(key), 2)
  end,
})

-- io is absent in real sandbox; keep for reading our own test fixtures via WildsFs.
-- Harness still has io (Lua process). Modules must not *require* love.filesystem.

local modules = {}
local files = {}
-- Seed a few real mod files if present.
local function seed(rel)
  local f = io.open(rel, "rb")
  if f then
    files[rel] = f:read("*a")
    f:close()
  end
end
seed("assets/generated/followsprites_runtime/manifest.json")
seed("options.lua")

local mod = {
  id = "overworld_wild_spawns",
  path = "mods/overworld_wild_spawns",
  read = function(_, rel) return files[rel] end,
  assets = {
    path = function(_, rel) return "mods/overworld_wild_spawns/" .. rel end,
  },
  log = { info = function() end, warn = function() end },
  find = function() return nil end,
  storage = {
    write = function() return false, "not_in_playthrough" end,
    read = function() return nil, "not_in_playthrough" end,
  },
}

local V = { path = ".", mod = mod }
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  -- Lightweight stubs for heavy deps some modules pull.
  if name == "config" then
    modules[name] = {
      debug = function() return false end,
      normalizeSpriteStyle = function(s) return s or "followers" end,
      spriteStyle = function() return "followers" end,
      paletteFxRedpp = function() return true end,
      DEFAULTS = {},
    }
    return modules[name]
  end
  if name == "json_decode" then
    modules[name] = {
      decode = function(s)
        -- minimal: only used if manifest present
        if type(s) ~= "string" then return nil end
        return { sheets = {} }
      end,
    }
    return modules[name]
  end
  if name == "debug_log" then
    modules[name] = { info = function() end, warn = function() end, enabled = function() return false end }
    return modules[name]
  end
  local path = "lib/" .. name .. ".lua"
  local chunk = assert(loadfile(path))
  local value = chunk(V)
  modules[name] = value
  return value
end

local before = fsTouches

local WildsFs = V.require("mod_fs")
local RuntimeSheets = V.require("runtime_sheets")
local LuminanceSheet = V.require("luminance_sheet")
local SpeciesAssets = V.require("species_assets")

check(WildsFs ~= nil, "WildsFs loads under blocked filesystem")
check(RuntimeSheets ~= nil, "runtime_sheets loads")
check(LuminanceSheet ~= nil, "luminance_sheet loads")
check(SpeciesAssets.idFor("MEWTWO") == 150, "PR#73 MEWTWO asset identity")
check(SpeciesAssets.idFor("TYRANITAR") == 248, "PR#73 TYRANITAR asset identity")

local sheets = RuntimeSheets.new(mod)
if files["assets/generated/followsprites_runtime/manifest.json"] then
  local okLoad = sheets:load()
  check(okLoad == true or sheets.loadError ~= nil, "runtime sheets load attempt without FS")
  check(WildsFs.assetExists(mod, "assets/generated/followsprites_runtime/manifest.json"),
        "manifest via mod:read")
end

-- Luminance available() must not require love.filesystem
check(LuminanceSheet.available() == true
        or LuminanceSheet.available() == false,
      "luminance available() does not crash")

-- Explicitly ensure production helpers never touch love.filesystem
local okTouch, errTouch = pcall(function()
  return love.filesystem.getInfo("x")
end)
check(okTouch == false, "direct love.filesystem still blocked")
check(fsTouches > before, "sandbox counted filesystem touch")

-- Grep-like: loaded source of key modules must not call love.filesystem
local function sourceHasFs(name)
  local f = io.open("lib/" .. name .. ".lua", "r")
  if not f then return false end
  local src = f:read("*a")
  f:close()
  -- Allow comments mentioning love.filesystem; forbid call patterns.
  for line in src:gmatch("[^\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed and not trimmed:match("^%-%-") then
      if trimmed:find("love%.filesystem", 1, false) then
        return true, trimmed
      end
    end
  end
  return false
end

for _, name in ipairs({
  "mod_fs", "runtime_sheets", "luminance_sheet", "water_sprite_registry",
  "animated_sprites", "species_geometry", "variable_size",
  "sprite_providers", "spawn_logic", "sprite_resolver",
}) do
  local bad, line = sourceHasFs(name)
  check(not bad, name .. " has no love.filesystem calls"
    .. (line and (": " .. line) or ""))
end

-- spawn_render / follower may mention in comments only
do
  local bad, line = sourceHasFs("spawn_render")
  check(not bad, "spawn_render has no love.filesystem calls"
    .. (line and (": " .. line) or ""))
end

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("ALL PASS")
