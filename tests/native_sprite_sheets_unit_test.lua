-- Native SpriteRenderer runtime-sheet contract tests (0.7.0+ / path fix).
-- Run: lua tests/native_sprite_sheets_unit_test.lua
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

local modRoot = "mods/overworld_wild_spawns"
local modules = {}
local V = {
  mod = {
    path = modRoot,
    log = { info = function() end },
    find = function() return nil end,
    assets = {
      path = function(_, rel)
        return modRoot .. "/" .. rel
      end,
    },
    read = function(_, rel)
      -- Simulate Gen1Recomp mod.read: resolve under real workspace assets.
      local f = io.open(rel, "rb")
      if not f then
        f = io.open("./" .. rel, "rb")
      end
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
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

modules.config = {
  DEFAULTS = {
    wild_step_seconds = 0.28,
    aggressive_step_seconds = 0.18,
    pokemon_grass_render_mode = "immersed",
    grass_occlusion_px = 6,
  },
  get = function(_, k) return modules.config.DEFAULTS[k] end,
  debug = function() return false end,
}
modules.tile = { CELL = 16, WIDTH = 16, HEIGHT = 16,
  pixelsForCell = function(x, y) return x * 16, y * 16 end }

local RuntimeSheets = V.require("runtime_sheets")
local Movement = V.require("movement")
local VoxelAdapter = V.require("voxel_adapter")

-- ---- Sheet assets ----
local sheets = RuntimeSheets.new(V.mod)
local okLoad = sheets:load()
check(okLoad == true, "runtime sheet manifest loads via mod.read")
check(sheets:isReady(), "runtime sheets ready")
local sum = sheets:summary()
check((sum.sheetCount or 0) > 0, "manifest lists sheets")
print("  sheetCount=" .. tostring(sum.sheetCount))

eq(RuntimeSheets.FRAMES, 6, "frames=6")
eq(RuntimeSheets.WALKER, true, "walker=true")
eq(RuntimeSheets.SHEET_W, 16, "sheet width 16")
eq(RuntimeSheets.SHEET_H, 96, "sheet height 96")

eq(RuntimeSheets.STAND.down, 0, "STAND down")
eq(RuntimeSheets.STAND.up, 1, "STAND up")
eq(RuntimeSheets.STAND.left, 2, "STAND left")
eq(RuntimeSheets.STAND.right, 2, "STAND right mirrors left")
eq(RuntimeSheets.WALK.down, 3, "WALK down")
eq(RuntimeSheets.WALK.up, 4, "WALK up")
eq(RuntimeSheets.WALK.left, 5, "WALK left")
eq(RuntimeSheets.WALK.right, 5, "WALK right mirrors left")

-- Manifest keys for Gen1 representatives
for _, dex in ipairs({ 1, 25, 151 }) do
  local entry, key = sheets:getManifestEntry(dex, "normal")
  check(entry ~= nil, ("manifest entry %s:normal"):format(dex))
  eq(key, tostring(dex) .. ":normal", "manifest key " .. dex)
  check(type(entry.path) == "string", "entry.path string for " .. dex)
  check(entry.path:find(("%03d-normal.png"):format(dex), 1, true) ~= nil,
        "entry path filename for " .. dex)

  local rel, used, ent = sheets:resolveRelativePath(dex, "normal")
  check(rel ~= nil, "relative path for dex " .. dex)
  eq(used, "normal", "used variant normal for " .. dex)
  check(rel:find("assets/generated/followsprites_runtime/", 1, true) == 1,
        "relative path under generated dir for " .. dex)

  local loadPath, used2, rel2 = sheets:resolveAssetPath(dex, "normal")
  check(loadPath ~= nil, "load path for dex " .. dex)
  eq(used2, "normal", "asset used variant " .. dex)
  check(loadPath:find(modRoot .. "/", 1, true) == 1,
        "load path uses mod.assets:path prefix for " .. dex)
  check(loadPath:find(rel2, 1, true) ~= nil,
        "load path contains relative for " .. dex)
  -- Must NOT be bare relative
  check(loadPath ~= rel2, "load path differs from relative for " .. dex)

  local def, dUsed, dPath, dRel = sheets:spriteDef(dex, "normal")
  check(def ~= nil, "spriteDef for " .. dex)
  eq(def.frames, 6, "spriteDef frames " .. dex)
  eq(def.walker, true, "spriteDef walker " .. dex)
  eq(def.trueColor, true, "spriteDef trueColor " .. dex)
  check(def.image:find(modRoot, 1, true) == 1, "spriteDef.image is load path " .. dex)
  check(not def.image:match("^assets/"), "spriteDef.image is not bare relative " .. dex)

  local probe = sheets:probeRegistration(dex, "normal")
  eq(probe.manifestEntryFound, true, "probe manifest found " .. dex)
  check(probe.relativePath ~= nil, "probe relative " .. dex)
  check(probe.loadPath ~= nil, "probe loadPath " .. dex)
end

-- Shiny falls back to normal when requested but we have shiny too
local shinyLoad = select(1, sheets:resolveAssetPath(25, "shiny"))
check(shinyLoad ~= nil, "Pikachu shiny resolves")
check(shinyLoad:find("025-shiny.png", 1, true) ~= nil, "Pikachu shiny filename")

local miss = sheets:resolveRelativePath(99999, "shiny")
eq(miss, nil, "missing species returns nil")

-- PNG dimensions (LuaJIT / Lua 5.1 compatible — no string.unpack).
local function u32be(bytes, offset)
  local b1, b2, b3, b4 = bytes:byte(offset, offset + 3)
  return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end
local function pngSize(path)
  local fh = assert(io.open(path, "rb"))
  local hdr = fh:read(24)
  fh:close()
  assert(hdr:sub(1, 8) == "\137PNG\r\n\26\n", "bad png sig")
  return u32be(hdr, 17), u32be(hdr, 21)
end
local w, h = pngSize("assets/generated/followsprites_runtime/001-normal.png")
eq(w, 16, "generated sheet width 16")
eq(h, 96, "generated sheet height 96")
w, h = pngSize("assets/generated/followsprites_runtime/025-normal.png")
eq(w, 16, "025 width")
eq(h, 96, "025 height")
w, h = pngSize("assets/generated/followsprites_runtime/151-normal.png")
eq(w, 16, "151 width")
eq(h, 96, "151 height")

-- love.filesystem.getInfo(relative) alone must NOT be required for success.
-- Simulate: relative getInfo would miss, but mod.read still finds the file.
local relOnly = "assets/generated/followsprites_runtime/001-normal.png"
check(sheets:_assetPresent(relOnly) == true,
      "asset present via mod.read even without love getInfo on relative")

-- ---- Movement walkPhase / stepFlip ----
local e = { facing = "down" }
Movement.init(e, 3, 4, "down")
eq(Movement.walkPhase(e), 0, "idle phase 0")
check(Movement.beginStep(e, 3, 5), "begin step down")
e.movement.progress = (e.movement.duration or 0.28) * 0.5
eq(Movement.walkPhase(e), 1, "mid-step phase 1")
local done = false
for _ = 1, 40 do
  done = Movement.update(e, 0.05)
  if done then break end
end
check(done == true, "step completes")
eq(e.stepFlip, true, "stepFlip toggles on complete")

-- ---- Pose-shaped native entity ----
local load25 = select(1, sheets:resolveAssetPath(25, "normal"))
local wild = {
  overworldWildSpawn = true,
  px = 32, py = 48, cellX = 2, cellY = 3,
  facing = "left",
  stepFlip = false,
  phase = 0,
  visibleSprite = true,
  nativeSpriteRenderer = true,
  pokemonRenderer = "NATIVE_SPRITE_RENDERER",
  usingFallback = false,
  sprite = {
    def = {
      image = load25,
      frames = 6,
      walker = true,
      trueColor = true,
    },
    resolveImage = function(s) return s.image end,
    image = {},
  },
}
Movement.init(wild, 2, 3, "left")
wild.pose = function(self)
  Movement.syncLegacyFields(self)
  return self.sprite, self.px, self.py, self.facing,
         Movement.walkPhase(self), self.stepFlip == true, false
end
local sprite, vx, vy, facing, phase, flip, hop = wild:pose()
check(sprite ~= nil, "pose returns sprite")
check(sprite.def.image:find(modRoot, 1, true) == 1, "pose sprite uses load path")
eq(facing, "left", "pose facing")
eq(phase, 0, "pose idle phase")
check(VoxelAdapter.isPoseSafe(wild), "native entity pose-safe")

local native = { overworldWildSpawn = true, pokemonRenderer = "NATIVE_SPRITE_RENDERER" }
local emergency = { overworldWildSpawn = true, pokemonRenderer = "SPATIAL_OVERLAY_EMERGENCY" }
local kept = {}
for _, ent in ipairs({ native, emergency }) do
  local r = ent.pokemonRenderer
  local isEmerg = r == "SPATIAL_OVERLAY_EMERGENCY" or r == "SPATIAL_OVERLAY_FALLBACK"
  if not (VoxelAdapter.isWildEntity(ent) and isEmerg) then
    kept[#kept + 1] = ent
  end
end
eq(#kept, 1, "filter keeps native, drops emergency")

if failures > 0 then
  io.stderr:write(("\n%d failure(s)\n"):format(failures))
  os.exit(1)
end
print("\nAll native sprite sheet unit tests passed.")
