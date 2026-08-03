-- Native SpriteRenderer runtime-sheet contract tests (0.7.0+).
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

local modRoot = "."
local modules = {}
local V = {
  mod = {
    path = modRoot,
    log = { info = function() end },
    find = function() return nil end,
    read = function(_, rel)
      local f = io.open(modRoot .. "/" .. rel, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
  },
  path = modRoot,
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
check(okLoad == true, "runtime sheet manifest loads")
check(sheets:isReady(), "runtime sheets ready")
local sum = sheets:summary()
check((sum.sheetCount or 0) > 0, "manifest lists sheets")
eq(RuntimeSheets.FRAMES, 6, "frames=6")
eq(RuntimeSheets.WALKER, true, "walker=true")
eq(RuntimeSheets.SHEET_W, 16, "sheet width 16")
eq(RuntimeSheets.SHEET_H, 96, "sheet height 96")

-- Verified Gen1Recomp SpriteRenderer tables
eq(RuntimeSheets.STAND.down, 0, "STAND down")
eq(RuntimeSheets.STAND.up, 1, "STAND up")
eq(RuntimeSheets.STAND.left, 2, "STAND left")
eq(RuntimeSheets.STAND.right, 2, "STAND right mirrors left")
eq(RuntimeSheets.WALK.down, 3, "WALK down")
eq(RuntimeSheets.WALK.up, 4, "WALK up")
eq(RuntimeSheets.WALK.left, 5, "WALK left")
eq(RuntimeSheets.WALK.right, 5, "WALK right mirrors left")

local path25 = sheets:resolvePath(25, "normal")
check(path25 ~= nil, "Pikachu normal sheet resolves")
check(path25:find("025%-normal%.png", 1) ~= nil, "Pikachu path name")
local f = io.open(path25, "rb")
check(f ~= nil, "Pikachu sheet file exists")
if f then f:close() end

local pathShiny = sheets:resolvePath(25, "shiny")
check(pathShiny ~= nil, "Pikachu shiny sheet resolves")

local def, used = sheets:spriteDef(1, "normal")
check(def ~= nil, "spriteDef for species 1")
eq(def.frames, 6, "spriteDef frames")
eq(def.walker, true, "spriteDef walker")
eq(def.trueColor, true, "spriteDef trueColor")
check(type(def.image) == "string", "spriteDef image path")
eq(used, "normal", "used variant normal")

-- Fallback shiny → normal when requesting missing (use huge id)
local miss = sheets:resolvePath(99999, "shiny")
eq(miss, nil, "missing species returns nil")

-- ---- PNG dimensions via Python-free size check (IHDR) ----
local function pngSize(path)
  local fh = assert(io.open(path, "rb"))
  local hdr = fh:read(24)
  fh:close()
  assert(hdr:sub(1, 8) == "\137PNG\r\n\26\n", "bad png sig")
  local w = string.unpack(">I4", hdr, 17)
  local h = string.unpack(">I4", hdr, 21)
  return w, h
end
local w, h = pngSize("assets/generated/followsprites_runtime/001-normal.png")
eq(w, 16, "generated sheet width 16")
eq(h, 96, "generated sheet height 96")
w, h = pngSize("assets/generated/followsprites_runtime/001-shiny.png")
eq(w, 16, "shiny sheet width 16")
eq(h, 96, "shiny sheet height 96")

-- ---- Movement walkPhase / stepFlip (NPC contract) ----
local e = { facing = "down" }
Movement.init(e, 3, 4, "down")
eq(Movement.walkPhase(e), 0, "idle phase 0")
eq(e.stepFlip, false, "initial stepFlip false")
check(Movement.beginStep(e, 3, 5), "begin step down")
-- Mid-step at 50% of duration → progress maps into [4,12) of 16 ticks
e.movement.progress = (e.movement.duration or 0.28) * 0.5
eq(Movement.walkPhase(e), 1, "mid-step phase 1")
-- Complete the step
local done = false
for _ = 1, 40 do
  done = Movement.update(e, 0.05)
  if done then break end
end
check(done == true, "step completes")
eq(e.stepFlip, true, "stepFlip toggles on complete")
eq(Movement.walkPhase(e), 0, "idle after step")

-- ---- Pose-shaped entity (native) ----
local wild = {
  overworldWildSpawn = true,
  px = 32, py = 48, cellX = 2, cellY = 3,
  facing = "left",
  stepFlip = false,
  phase = 0,
  visibleSprite = true,
  nativeSpriteRenderer = true,
  pokemonRenderer = "NATIVE_SPRITE_RENDERER",
  sprite = {
    def = {
      image = "assets/generated/followsprites_runtime/025-normal.png",
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
eq(facing, "left", "pose facing")
eq(phase, 0, "pose idle phase")
eq(flip, false, "pose flip")
eq(hop, false, "pose hop false")
check(VoxelAdapter.isPoseSafe(wild), "native entity pose-safe")

-- World-billboard filter keeps NATIVE in posesOf
local function filterKeep(entities)
  local kept = {}
  for _, ent in ipairs(entities) do
    local r = ent.pokemonRenderer
    local isEmerg = r == "SPATIAL_OVERLAY_EMERGENCY" or r == "SPATIAL_OVERLAY_FALLBACK"
    if not (VoxelAdapter.isWildEntity(ent) and isEmerg) then
      kept[#kept + 1] = ent
    end
  end
  return kept
end
local native = { overworldWildSpawn = true, pokemonRenderer = "NATIVE_SPRITE_RENDERER" }
local emergency = { overworldWildSpawn = true, pokemonRenderer = "SPATIAL_OVERLAY_EMERGENCY" }
local kept = filterKeep({ native, emergency })
eq(#kept, 1, "filter keeps native, drops emergency")
check(kept[1] == native, "native remains in posesOf")

eq(VoxelAdapter.POKEMON_NATIVE, "NATIVE_SPRITE_RENDERER", "adapter native constant")

if failures > 0 then
  io.stderr:write(("\n%d failure(s)\n"):format(failures))
  os.exit(1)
end
print("\nAll native sprite sheet unit tests passed.")
