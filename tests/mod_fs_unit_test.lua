-- WildsFs: sandbox-safe asset/storage helpers.
-- Run: lua tests/mod_fs_unit_test.lua
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

local modules = {}
local V = { path = ".", mod = nil }
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

local WildsFs = V.require("mod_fs")

check(WildsFs.isSafeRel("assets/foo.png") == true, "safe relative asset")
check(WildsFs.isSafeRel("../etc/passwd") == false, "reject .. traversal")
check(WildsFs.isSafeRel("/etc/passwd") == false, "reject absolute")
check(WildsFs.isSafeRel("C:\\Windows") == false, "reject windows abs")

check(WildsFs.isSafeStorageKey("cache/luma/v3") == true, "safe storage key")
check(WildsFs.isSafeStorageKey("../x") == false, "reject storage traversal")
check(WildsFs.isSafeStorageKey("/abs") == false, "reject storage abs")

local files = {
  ["assets/generated/followsprites_runtime/manifest.json"] = '{"sheets":{}}',
}
local mod = {
  read = function(_, rel)
    return files[rel]
  end,
  assets = {
    path = function(_, rel) return "mods/test/" .. rel end,
  },
  storage = {
    _data = {},
    write = function(self, game, key, value)
      self._data[key] = value
      return true
    end,
    read = function(self, game, key)
      local v = self._data[key]
      if v == nil then return nil, "not_found" end
      return v
    end,
  },
}

local data = WildsFs.readAsset(mod, "assets/generated/followsprites_runtime/manifest.json",
  { cacheBytes = true })
check(type(data) == "string" and data:find("sheets"), "read packaged asset")
check(WildsFs.assetExists(mod, "assets/generated/followsprites_runtime/manifest.json"),
      "assetExists hit")
check(WildsFs.assetExists(mod, "assets/missing.png") == false, "missing packaged asset")
check(WildsFs.readAsset(mod, "../secret") == nil, "read rejects traversal")

local path = WildsFs.assetPath(mod, "assets/x.png")
check(path == "mods/test/assets/x.png", "assetPath via mod.assets")

local ok = WildsFs.writeStorage(mod, {}, "cache/meta", { format = 1, n = 2 })
check(ok == true, "storage write table")
local got = WildsFs.readStorage(mod, {}, "cache/meta")
check(got and got.n == 2, "storage read same table")
check(WildsFs.writeStorage(mod, {}, "cache/meta", "nope") == false,
      "storage rejects non-table")
check(WildsFs.writeStorage(mod, {}, "../bad", { a = 1 }) == false,
      "storage rejects bad key")
check(WildsFs.storageExists(mod, {}, "cache/missing") == false, "missing storage")

-- Simulate sandboxed love: filesystem access errors.
local blocked = false
love = setmetatable({
  image = {},
  graphics = {},
  timer = { getTime = function() return 0 end },
}, {
  __index = function(_, key)
    if key == "filesystem" then
      blocked = true
      error("love.filesystem is not available to mods; use mod.storage and mod:read", 2)
    end
    return nil
  end,
})

-- Touching love.filesystem must error; WildsFs.pathExists must not.
local fsErr = false
local okFs, errFs = pcall(function() return love.filesystem end)
-- __index may not fire on love.filesystem if love is empty table with mt...
-- Our love table doesn't have filesystem key, so __index fires.
check(okFs == false or love.filesystem == nil or blocked,
      "filesystem access blocked or absent")

local exists = WildsFs.pathExists("mods/nope/missing.png")
check(exists == false, "pathExists safe when filesystem blocked")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("ALL PASS")
