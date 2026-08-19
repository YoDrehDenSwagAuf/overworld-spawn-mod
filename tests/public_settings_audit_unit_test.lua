-- Public settings schema is the source of truth for defaults, menus, and README.
-- Run: lua tests/public_settings_audit_unit_test.lua
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

local schema = assert(loadfile("options.lua"))()
local schemaByKey = {}
for _, row in ipairs(schema) do
  schemaByKey[row.key] = row
end

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    find = function() return nil end,
    options = { get = function() return nil end },
    read = function(_, rel)
      local f = io.open(rel, "rb") or io.open("./" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a"); f:close(); return data
    end,
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

local Config = V.require("config")
local SettingsMenus = V.require("settings_menus")

local publicKeys = {}
for _, row in ipairs(schema) do publicKeys[#publicKeys + 1] = row.key end

local menuKeys = {}
for _, k in ipairs(SettingsMenus.FOLLOWERS_OPTION_KEYS) do menuKeys[k] = true end
for _, k in ipairs(SettingsMenus.WILDS_OPTION_KEYS) do menuKeys[k] = true end

for _, key in ipairs(publicKeys) do
  check(menuKeys[key] == true, "menu lists public key " .. key)
  local def = schemaByKey[key].default
  local cfg = Config.DEFAULTS[key]
  eq(cfg, def, "Config.DEFAULTS matches schema for " .. key)
end

for key in pairs(menuKeys) do
  check(schemaByKey[key] ~= nil, "menu key is public schema: " .. key)
end

check(schemaByKey.indoor_pokemon == nil, "indoor_pokemon is not public")
check(schemaByKey.wilds_ai == nil, "wilds_ai is not public")
check(schemaByKey.wild_silhouettes ~= nil, "wild_silhouettes is public")
eq(schemaByKey.wild_silhouettes.default, false, "Enc Silhouette default off")
eq(schemaByKey.sprite_style.default, "followers", "Sprite Style default followers")
eq(schemaByKey.enabled.default, true, "Show Wild Mons default on")
eq(schemaByKey.follower_count.default, 1, "Followers default 1")
eq(schemaByKey.catch_hud_size.default, 5, "Catch HUD Size default 5")

local readme = assert(io.open("README.md", "r")):read("*a")
check(not readme:find("Indoor Pokémon", 1, true), "README has no Indoor Pokémon setting")
check(not readme:find("Indoor Pokemon", 1, true), "README has no Indoor Pokemon setting")
check(readme:find("Enc Silhouette", 1, true), "README documents Enc Silhouette")
check(readme:find("| Off |", 1, true) or readme:find("| Off |", 1, true),
      "README has Off defaults")
check(readme:find("Poke Followers / GSC", 1, true), "README sprite style default")
check(readme:find("| 1 |", 1, true), "README Followers default 1")
check(not readme:find("WILDS AI", 1, true), "README does not expose WILDS AI")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("public_settings_audit_unit_test: all passed")
