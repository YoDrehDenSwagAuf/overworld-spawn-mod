-- Thrown Overworld Catching Ball art: ID mapping, cache, HUD independence.
-- Run: lua tests/overworld_catch_projectile_assets_unit_test.lua
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

package.loaded["src.core.GameVersion"] = {
  get = function() return "red" end,
  isYellow = function() return false end,
  isGold = function() return false end,
  generation = function() return 1 end,
}

local gen1NpcCalls = {}
package.loaded["src.world.NPC"] = {
  new = function(data, mapId, objDef)
    gen1NpcCalls[#gen1NpcCalls + 1] = {
      data = data, mapId = mapId, objDef = objDef,
    }
    return {
      cellX = objDef.x, cellY = objDef.y,
      px = (objDef.x or 0) * 16, py = (objDef.y or 0) * 16,
      sprite = objDef.sprite,
      movement = objDef.movement,
      pose = function(self)
        return self.sprite, self.px, self.py, "down", 0, false
      end,
    }
  end,
}

local goldNewCalls = 0
package.loaded["src.world.gen2.Npc"] = {
  MOVE = { STANDING_DOWN = 6 },
  new = function(mapId, objDef, spriteDef)
    goldNewCalls = goldNewCalls + 1
    return {
      mapId = mapId,
      def = objDef,
      spriteDef = spriteDef,
      cellX = objDef.x, cellY = objDef.y,
      px = (objDef.x or 0) * 16, py = (objDef.y or 0) * 16,
      movement = objDef.movement,
      frozen = false,
      pose = function(self)
        return self.sprite, self.px, self.py, "down", 0, false
      end,
    }
  end,
}

package.preload["src.inventory.Bag"] = function()
  return {
    remove = function(save, id, qty)
      local n = (save.inventory[id] or 0) - (qty or 1)
      if n <= 0 then save.inventory[id] = nil else save.inventory[id] = n end
    end,
  }
end
package.preload["src.battle.Catching"] = function()
  return { attempt = function() return false, 0 end }
end
package.preload["src.core.Sound"] = function()
  return { play = function() end }
end

local optionStore = {
  enabled = true,
  overworld_catching = true,
  catch_hud_size = 5,
}
local imageLoads = {}
love = {
  timer = { getTime = function() return 0 end },
  graphics = {
            newImage = function(path)
      imageLoads[#imageLoads + 1] = path
      return {
        path = path,
        filterMin = nil,
        filterMag = nil,
        setFilter = function(self, min, mag)
          self.filterMin = min
          self.filterMag = mag
        end,
        getDimensions = function() return 16, 16 end,
      }
    end,
  },
}

local modules = {}
local V = {
  mod = {
    id = "overworld_wild_spawns",
    path = ".",
    log = { info = function() end, warn = function() end },
    options = {
      get = function(_, k)
        if optionStore[k] ~= nil then return optionStore[k] end
        return nil
      end,
      set = function(_, k, v) optionStore[k] = v end,
    },
    assets = { path = function(_, rel) return rel end },
    content = {
      sprites = {
        _defs = {},
        get = function(self, id) return self._defs[id] end,
        register = function(self, id, def) self._defs[id] = def end,
      },
      render_pipelines = { register = function() end },
    },
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
modules.debug_log = { warn = function() end, info = function() end, error = function() end }
modules.tile = { CELL = 16 }

local Config = V.require("config")
local GameCompat = V.require("game_compat")
local OverworldCatching = V.require("catching/init")
local Projectile = V.require("catching/projectile")
local BallHud = V.require("catching/hud")

local expectedThrow = {
  POKE_BALL = "assets/balls/throw/poke_ball.png",
  GREAT_BALL = "assets/balls/throw/great_ball.png",
  ULTRA_BALL = "assets/balls/throw/ultra_ball.png",
  MASTER_BALL = "assets/balls/throw/master_ball.png",
}
local expectedHud = {
  POKE_BALL = "assets/balls/poke_ball.png",
  GREAT_BALL = "assets/balls/great_ball.png",
  ULTRA_BALL = "assets/balls/ultra_ball.png",
  MASTER_BALL = "assets/balls/master_ball.png",
}

eq(#OverworldCatching.BALL_TYPES, 4, "Wilds supports four Overworld Catching balls")
eq(OverworldCatching.BALL_TYPES[1], "POKE_BALL", "BALL_TYPES[1] POKE_BALL")
eq(OverworldCatching.BALL_TYPES[2], "GREAT_BALL", "BALL_TYPES[2] GREAT_BALL")
eq(OverworldCatching.BALL_TYPES[3], "ULTRA_BALL", "BALL_TYPES[3] ULTRA_BALL")
eq(OverworldCatching.BALL_TYPES[4], "MASTER_BALL", "BALL_TYPES[4] MASTER_BALL")
eq(OverworldCatching.THROW_SOURCE_PX, 22, "throw source art is 22px")
eq(OverworldCatching.THROW_CANVAS_PX, 16, "throw SpriteDef canvas is 16px")
eq(OverworldCatching.THROW_ART_PX, 8, "visible throw art is 8px")
eq(OverworldCatching.THROW_ART_OFFSET,
  math.floor((OverworldCatching.THROW_CANVAS_PX - OverworldCatching.THROW_ART_PX) / 2),
  "throw art offset is derived from canvas and art size")
eq(OverworldCatching.THROW_ART_OFFSET, 4, "8x8 art is centered at (4,4) on 16x16")
eq(OverworldCatching.THROW_ART_OFFSET * 2 + OverworldCatching.THROW_ART_PX,
  OverworldCatching.THROW_CANVAS_PX,
  "art is exactly centered with equal padding")

-- 1-4 + 5: stable Ball ID -> throw art (not PNG filename gameplay).
for _, ballType in ipairs(OverworldCatching.BALL_TYPES) do
  eq(OverworldCatching.ballThrowAsset(ballType), expectedThrow[ballType],
    ballType .. " throw path")
  eq(OverworldCatching.ballHudAsset(ballType), expectedHud[ballType],
    ballType .. " HUD path")
  check(OverworldCatching.ballThrowAsset(ballType)
      ~= OverworldCatching.ballHudAsset(ballType),
    ballType .. " HUD and throw paths differ")
end
eq(OverworldCatching.ballThrowAsset("pokeball.png"), nil,
  "PNG filename is not a runtime Ball ID")
eq(OverworldCatching.ballThrowAsset("SAFARI_BALL"), nil,
  "unsupported SAFARI_BALL has no throw asset")

local catching = OverworldCatching.new(V.mod, { entities = {}, spawns = {} })
check(catching:registerContent() == true, "registerContent ok")
for _, ballType in ipairs(OverworldCatching.BALL_TYPES) do
  local def = catching:ballSpriteDef(ballType)
  check(type(def) == "table" and def.image ~= nil, ballType .. " SpriteDef.image")
  eq(def.image, expectedThrow[ballType], ballType .. " SpriteDef uses throw PNG")
  eq(def.frames, 1, ballType .. " frames=1")
  eq(def.walker, false, ballType .. " walker=false")
  eq(def.trueColor, true, ballType .. " trueColor=true")
end

-- 6: repeated projectile lookup uses the cache (one newImage per Ball).
imageLoads = {}
catching._ballImages = {}
local first = catching:ballImage("POKE_BALL")
local loadsAfterFirst = #imageLoads
local second = catching:ballImage("POKE_BALL")
eq(first, second, "repeated POKE_BALL lookup returns cached image")
eq(#imageLoads, loadsAfterFirst, "second POKE_BALL lookup does not reload PNG")
eq(first.filterMin, "nearest", "throw image min filter is nearest")
eq(first.filterMag, "nearest", "throw image mag filter is nearest")
local great = catching:ballImage("GREAT_BALL")
check(great ~= first, "GREAT_BALL uses a different cached image")
eq(#imageLoads, loadsAfterFirst + 1, "GREAT_BALL is a new cache entry")
catching:ballImage("GREAT_BALL")
eq(#imageLoads, loadsAfterFirst + 1, "repeated GREAT_BALL stays cached")

-- 7: HUD asset selection remains independent.
imageLoads = {}
catching._ballHudImages = {}
local hudImg = catching:ballHudImage("POKE_BALL")
check(hudImg ~= nil, "HUD image loads")
eq(hudImg.path, expectedHud.POKE_BALL, "HUD image is full poke_ball.png")
check(hudImg.path ~= first.path, "HUD image path is not the throw path")
local hudLoads = #imageLoads
catching:ballHudImage("POKE_BALL")
eq(#imageLoads, hudLoads, "HUD image is cached separately")

-- 8-9: Catch HUD Size does not modify projectile size / hide projectile.
local projSrc = assert(io.open("lib/catching/projectile.lua", "r")):read("*a")
check(not projSrc:find("catch_hud_size", 1, true), "projectile.lua ignores catch_hud_size")
check(not projSrc:find("catchHudIconPx", 1, true), "projectile.lua ignores catchHudIconPx")
check(not projSrc:find("catchHudEnabled", 1, true), "projectile.lua ignores catchHudEnabled")
eq(Projectile.BALL_VISUAL_PX, 6, "projectile visual constant is HUD-independent")
optionStore.catch_hud_size = 0
eq(Config.catchHudEnabled(V.mod), false, "size 0 hides HUD")
eq(Projectile.BALL_VISUAL_PX, 6, "size 0 does not change projectile visual px")
eq(OverworldCatching.ballThrowAsset("POKE_BALL"), expectedThrow.POKE_BALL,
  "size 0 does not change throw asset")
eq(catching:ballThrowAsset("POKE_BALL"), expectedThrow.POKE_BALL,
  "instance ballThrowAsset matches static lookup")
local throwAtZero = catching:ballImage("ULTRA_BALL")
check(throwAtZero ~= nil, "size 0 still resolves projectile image")
optionStore.catch_hud_size = 10
eq(Projectile.BALL_VISUAL_PX, 6, "size 10 does not change projectile visual px")
eq(OverworldCatching.ballThrowAsset("MASTER_BALL"), expectedThrow.MASTER_BALL,
  "size 10 does not change throw asset")
optionStore.catch_hud_size = 5

local hud = BallHud.new(V.mod, { canShowHud = function() return true end })
optionStore.catch_hud_size = 0
eq(hud:shouldDraw({}, {}), false, "size 0 HUD hidden")
check(catching:ballImage("POKE_BALL") ~= nil, "size 0 projectile image still available")
optionStore.catch_hud_size = 5

-- 10: Gen1 projectile construction still works.
package.loaded["src.core.GameVersion"].get = function() return "red" end
package.loaded["src.core.GameVersion"].generation = function() return 1 end
package.loaded["src.core.GameVersion"].isGold = function() return false end
local gen1Game = {
  generation = 1, version = "red",
  data = { sprites = {} },
  save = { inventory = { POKE_BALL = 1 } },
}
local gen1Ow = { map = { id = "ROUTE_1" }, player = { cellX = 5, cellY = 5 } }
gen1NpcCalls = {}
local gen1Ball, gen1Err = GameCompat.makeCatchProjectile(gen1Game, gen1Ow, {
  ballType = "POKE_BALL",
  spriteId = "SPRITE_WILDS_BALL_POKE_BALL",
  spriteDef = catching:ballSpriteDef("POKE_BALL"),
  x = 5, y = 6,
})
check(gen1Ball ~= nil, "Gen1 makeCatchProjectile: " .. tostring(gen1Err))
eq(#gen1NpcCalls, 1, "Gen1 uses NPC.new")
eq(gen1NpcCalls[1].objDef.sprite, "SPRITE_WILDS_BALL_POKE_BALL", "Gen1 sprite id")
check(type(gen1Ball.pose) == "function", "Gen1 ball exposes pose()")
check(gen1Ball:pose() ~= nil, "Gen1 pose() is non-nil")

-- 11: Gold projectile construction still works.
package.loaded["src.core.GameVersion"].get = function() return "gold" end
package.loaded["src.core.GameVersion"].generation = function() return 2 end
package.loaded["src.core.GameVersion"].isGold = function() return true end
modules.game_compat = nil
package.loaded["lib/game_compat"] = nil
-- Force a fresh GameCompat under Gold.
local goldCompat
do
  local chunk = assert(loadfile("lib/game_compat.lua"))
  goldCompat = chunk(V)
end
local goldGame = {
  generation = 2, version = "gold",
  data = { sprites = {} },
  save = { inventory = { POKE_BALL = 1 } },
}
local goldOw = { map = { id = "ROUTE_29" }, player = { cellX = 12, cellY = 8 } }
goldNewCalls = 0
local goldDef = catching:ballSpriteDef("GREAT_BALL")
local goldBall, goldErr = goldCompat.makeCatchProjectile(goldGame, goldOw, {
  ballType = "GREAT_BALL",
  spriteId = "SPRITE_WILDS_BALL_GREAT_BALL",
  spriteDef = goldDef,
  x = 12, y = 8,
})
check(goldBall ~= nil, "Gold makeCatchProjectile: " .. tostring(goldErr))
check(goldNewCalls >= 1, "Gold uses gen2.Npc.new")
check(goldBall.spriteDef and goldBall.spriteDef.image, "Gold spriteDef.image")
eq(goldBall.spriteDef.image, expectedThrow.GREAT_BALL, "Gold projectile uses throw art")

-- 12: missing/unsupported Ball asset fails safely.
eq(catching:ballSpriteDef("SAFARI_BALL"), nil, "unsupported SpriteDef is nil")
eq(catching:ballImage("SAFARI_BALL"), nil, "unsupported ballImage is nil")
eq(OverworldCatching.ballThrowAsset("PREMIER_BALL"), nil, "premier throw asset absent")
local missing, missingErr = goldCompat.makeCatchProjectile(goldGame, goldOw, {
  ballType = "SAFARI_BALL",
  spriteId = "SPRITE_WILDS_BALL_SAFARI_BALL",
})
eq(missing, nil, "Gold missing SpriteDef fails construction")
check(type(missingErr) == "string" and missingErr ~= "", "Gold missing asset has error")

-- 13: no Base64 decode in runtime catching / compat code.
local function read(path)
  local f = assert(io.open(path, "r")); local d = f:read("*a"); f:close(); return d
end
for _, rel in ipairs({
  "lib/catching/init.lua",
  "lib/catching/projectile.lua",
  "lib/catching/hud.lua",
  "lib/game_compat/gen1.lua",
  "lib/game_compat/gen2.lua",
}) do
  local src = read(rel)
  check(not src:lower():find("base64", 1, true), rel .. " has no base64")
  check(not src:find("data:image/png", 1, true), rel .. " has no data URI")
end

-- Packaged throw PNGs exist; old *_sm files are gone.
local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end
for _, ballType in ipairs(OverworldCatching.BALL_TYPES) do
  check(exists(expectedThrow[ballType]), expectedThrow[ballType] .. " exists")
  check(exists(expectedHud[ballType]), expectedHud[ballType] .. " exists")
end
check(not exists("assets/balls/poke_ball_sm.png"), "old poke_ball_sm removed")
check(not exists("assets/balls/great_ball_sm.png"), "old great_ball_sm removed")
check(not exists("assets/balls/ultra_ball_sm.png"), "old ultra_ball_sm removed")
check(not exists("assets/balls/master_ball_sm.png"), "old master_ball_sm removed")

-- Throw canvases are 16×16 PNG (IHDR) with ~8×8 opaque art, same bounds on all Balls.
local function pngSize(path)
  local f = assert(io.open(path, "rb"))
  local hdr = f:read(24)
  f:close()
  local w = hdr:byte(17) * 16777216 + hdr:byte(18) * 65536 + hdr:byte(19) * 256 + hdr:byte(20)
  local h = hdr:byte(21) * 16777216 + hdr:byte(22) * 65536 + hdr:byte(23) * 256 + hdr:byte(24)
  return w, h
end

local ffi = require("ffi")
ffi.cdef[[
  int uncompress(unsigned char *dest, unsigned long *destLen,
                 const unsigned char *source, unsigned long sourceLen);
]]
local zlib = ffi.load("z")

local function pngOpaqueBBox(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  local function u32(i)
    return data:byte(i) * 16777216 + data:byte(i + 1) * 65536
      + data:byte(i + 2) * 256 + data:byte(i + 3)
  end
  local w, h = u32(17), u32(21)
  local i = 9
  local idat = {}
  while i + 8 <= #data do
    local ln = u32(i)
    local typ = data:sub(i + 4, i + 7)
    local payload = data:sub(i + 8, i + 7 + ln)
    if typ == "IDAT" then
      idat[#idat + 1] = payload
    elseif typ == "IEND" then
      break
    end
    i = i + 12 + ln
  end
  local src = table.concat(idat)
  local bound = (w * 4 + 1) * h + 64
  local dest = ffi.new("unsigned char[?]", bound)
  local destLen = ffi.new("unsigned long[1]", bound)
  local srcBuf = ffi.new("unsigned char[?]", #src)
  ffi.copy(srcBuf, src, #src)
  local rc = zlib.uncompress(dest, destLen, srcBuf, #src)
  assert(rc == 0, "zlib uncompress " .. path .. " rc=" .. tostring(rc))
  local raw = ffi.string(dest, tonumber(destLen[0]))
  local stride = w * 4
  local function paeth(a, b, c)
    local p = a + b - c
    local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
    if pa <= pb and pa <= pc then return a end
    if pb <= pc then return b end
    return c
  end
  local prev = {}
  for x = 1, stride do prev[x] = 0 end
  local minX, minY, maxX, maxY
  local off = 1
  for y = 0, h - 1 do
    local ft = raw:byte(off); off = off + 1
    local row = {}
    for x = 1, stride do
      row[x] = raw:byte(off); off = off + 1
    end
    if ft == 1 then
      for x = 1, stride do
        local left = x > 4 and row[x - 4] or 0
        row[x] = (row[x] + left) % 256
      end
    elseif ft == 2 then
      for x = 1, stride do
        row[x] = (row[x] + prev[x]) % 256
      end
    elseif ft == 3 then
      for x = 1, stride do
        local left = x > 4 and row[x - 4] or 0
        row[x] = (row[x] + math.floor((left + prev[x]) / 2)) % 256
      end
    elseif ft == 4 then
      for x = 1, stride do
        local left = x > 4 and row[x - 4] or 0
        local ul = x > 4 and prev[x - 4] or 0
        row[x] = (row[x] + paeth(left, prev[x], ul)) % 256
      end
    elseif ft ~= 0 then
      error("unsupported PNG filter " .. tostring(ft) .. " in " .. path)
    end
    prev = row
    for x = 0, w - 1 do
      local a = row[x * 4 + 4]
      if a > 0 then
        if not minX or x < minX then minX = x end
        if not maxX or x > maxX then maxX = x end
        if not minY or y < minY then minY = y end
        if not maxY or y > maxY then maxY = y end
      end
    end
  end
  return minX, minY, maxX, maxY, maxX - minX + 1, maxY - minY + 1
end

local sharedBBox
for _, ballType in ipairs(OverworldCatching.BALL_TYPES) do
  local w, h = pngSize(expectedThrow[ballType])
  eq(w, 16, ballType .. " throw PNG width 16")
  eq(h, 16, ballType .. " throw PNG height 16")
  local x0, y0, x1, y1, bw, bh = pngOpaqueBBox(expectedThrow[ballType])
  check(bw >= 7 and bw <= 8, ballType .. " opaque width 7-8 (got " .. tostring(bw) .. ")")
  check(bh >= 7 and bh <= 8, ballType .. " opaque height 7-8 (got " .. tostring(bh) .. ")")
  eq(x0, OverworldCatching.THROW_ART_OFFSET, ballType .. " opaque minX is derived offset")
  eq(y0, OverworldCatching.THROW_ART_OFFSET, ballType .. " opaque minY is derived offset")
  if not sharedBBox then
    sharedBBox = { x0, y0, x1, y1, bw, bh }
  else
    eq(x0, sharedBBox[1], ballType .. " shares opaque minX")
    eq(y0, sharedBBox[2], ballType .. " shares opaque minY")
    eq(x1, sharedBBox[3], ballType .. " shares opaque maxX")
    eq(y1, sharedBBox[4], ballType .. " shares opaque maxY")
  end
  -- HUD file stays the independent full asset (not the throw canvas).
  local hw, hh = pngSize(expectedHud[ballType])
  check(hw > 0 and hh > 0, ballType .. " HUD PNG still present")
  local tf = assert(io.open(expectedThrow[ballType], "rb")):read("*a")
  local hf = assert(io.open(expectedHud[ballType], "rb")):read("*a")
  check(tf ~= hf, ballType .. " HUD PNG bytes differ from throw PNG")
end
eq(sharedBBox[5], 8, "shared opaque width is 8")
eq(sharedBBox[6], 8, "shared opaque height is 8")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("overworld_catch_projectile_assets_unit_test: all passed")
