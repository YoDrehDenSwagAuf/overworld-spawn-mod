-- Peaceful ambient Town Pokémon (NPC-like, never battleable).
--
-- Separate from wild spawn / battle managers. Uses native SpriteRenderer via
-- the shared sprite style resolver. Concepts adapted from
-- Gen1PC-OverworldEncounters (NPC.new + ow.npcs/entities) without copying its
-- parallel sprite registry or encounter manager.
local V = ...
local Config = V.require("config")
local AmbientCries = V.require("ambient_cries")
local EncounterIndex = V.require("encounter_index")
local DebugLog = V.require("debug_log")

local AmbientPokemon = {}
AmbientPokemon.__index = AmbientPokemon

AmbientPokemon.SPRITE_PLACEHOLDER = "SPRITE_PIKACHU"
AmbientPokemon.INDEX_BASE = 900

-- Internal density by safe map kind (not a public option).
AmbientPokemon.DENSITY = {
  pokecenter = { min = 1, max = 2 },
  house = { min = 0, max = 1 },
  mart = { min = 0, max = 1 },
  lab = { min = 1, max = 3 },
  town = { min = 1, max = 3 },
  gate = { min = 0, max = 1 },
}

AmbientPokemon.FALLBACK_POOL = {
  "PIKACHU", "CLEFAIRY", "JIGGLYPUFF", "MEOWTH", "PSYDUCK",
  "EEVEE", "VULPIX", "GROWLITHE", "SLOWPOKE", "CHANSEY",
}

AmbientPokemon.LEGENDARY_BLOCK = {
  ARTICUNO = true, ZAPDOS = true, MOLTRES = true, MEWTWO = true, MEW = true,
  RAIKOU = true, ENTEI = true, SUICUNE = true, LUGIA = true, HO_OH = true,
  CELEBI = true,
}

local HOSTILE_ID_PATTERNS = {
  "CAVE", "MT_", "DIGLETT", "ROCK_TUNNEL", "SEAFOAM", "VICTORY_ROAD",
  "POWER_PLANT", "POKEMON_TOWER", "ROCKET", "SILPH", "MANSION",
  "SAFARI", "GYM", "CERULEAN_CAVE", "UNKNOWN_DUNGEON",
}

local HOSTILE_TILESETS = {
  CAVERN = true, CEMETERY = true, FACILITY = true, SHIP = true, MANSION = true,
  GYM = true,
}

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function upper(s)
  return tostring(s or ""):upper()
end

local function randInt(lo, hi)
  if hi < lo then return lo end
  if love and love.math and love.math.random then
    return love.math.random(lo, hi)
  end
  return math.random(lo, hi)
end

local function chance(p)
  if love and love.math and love.math.random then
    return love.math.random() < p
  end
  return math.random() < p
end

function AmbientPokemon.new(mod, opts)
  opts = opts or {}
  local self = setmetatable({}, AmbientPokemon)
  self.mod = mod
  self.render = opts.render
  self.logic = opts.logic
  self.follower = opts.follower
  self.active = {} -- npc -> true
  self.activeMapId = nil
  self._pendingBattleReturnReconcile = false
  self._battleReturnFlushedOnce = false
  self._talkWrapped = false
  self._talkOrig = nil
  self._installed = false
  self._nextIndex = AmbientPokemon.INDEX_BASE
  return self
end

--- Classify a map for ambient eligibility / density.
-- Returns kind string or nil when ineligible.
function AmbientPokemon.classifyMap(game, mapId, map)
  mapId = upper(mapId)
  if mapId == "" then return nil end
  local def = map and map.def
  if not def and game and game.data and game.data.maps then
    def = game.data.maps[mapId]
  end
  local tileset = upper(def and def.tileset)

  for _, pat in ipairs(HOSTILE_ID_PATTERNS) do
    if mapId:find(pat, 1, true) then return nil end
  end
  if HOSTILE_TILESETS[tileset] then return nil end

  if mapId:find("POKECENTER", 1, true) or mapId:find("_CENTER", 1, true)
     or tileset:find("POKECENTER", 1, true) then
    return "pokecenter"
  end
  if mapId:find("MART", 1, true) or tileset:find("MART", 1, true) then
    return "mart"
  end
  if mapId:find("LAB", 1, true) then
    return "lab"
  end
  if mapId:find("_GATE", 1, true) or mapId:find("GATEHOUSE", 1, true)
     or mapId:find("GATE_", 1, true) then
    return "gate"
  end
  if mapId:find("_HOUSE", 1, true) or mapId:find("HOUSE", 1, true)
     or tileset:find("HOUSE", 1, true) or tileset:find("INTERIOR", 1, true) then
    -- Exclude gyms / towers already filtered; remaining interiors as houses.
    return "house"
  end

  local mapType = EncounterIndex.mapTypeOf(game, mapId)
  if mapType == "town" or mapId:find("TOWN", 1, true) or mapId:find("CITY", 1, true)
     or mapId == "CINNABAR_ISLAND" or mapId == "INDIGO_PLATEAU" then
    return "town"
  end

  return nil
end

function AmbientPokemon.isEligibleMap(game, mapId, map)
  local GameCompat = V.require("game_compat")
  if GameCompat.isGen2(nil, game) then
    local Town = V.require("gen2/town_pokemon")
    return Town.forMap(mapId) ~= nil
  end
  return AmbientPokemon.classifyMap(game, mapId, map) ~= nil
end

function AmbientPokemon.targetCount(game, mapId, map)
  local GameCompat = V.require("game_compat")
  if GameCompat.isGen2(nil, game) then
    local Town = V.require("gen2/town_pokemon")
    return Town.targetCount(mapId)
  end
  local kind = AmbientPokemon.classifyMap(game, mapId, map)
  if not kind then return 0 end
  local dens = AmbientPokemon.DENSITY[kind] or { min = 0, max = 1 }
  local n = randInt(dens.min, dens.max)
  -- Outdoor towns: scale slightly with map size.
  if kind == "town" and map then
    local cells = (map.widthCells or 20) * (map.heightCells or 18)
    if cells >= 400 and n < dens.max then
      n = math.min(dens.max, n + 1)
    elseif cells < 200 and n > dens.min then
      n = dens.min
    end
  end
  return n
end

function AmbientPokemon.isLegendary(species)
  return AmbientPokemon.LEGENDARY_BLOCK[upper(species)] == true
end

function AmbientPokemon.speciesPool(game, mapId, map)
  local GameCompat = V.require("game_compat")
  if GameCompat.isGen2(nil, game) then
    local Town = V.require("gen2/town_pokemon")
    if Town.speciesListForMap then
      return Town.speciesListForMap(mapId)
    end
    local curated = Town.speciesForMap(mapId)
    if curated then return { curated } end
    return {}
  end

  local pool = {}
  local seen = {}
  local function add(sp)
    sp = upper(sp)
    if sp == "" or seen[sp] or AmbientPokemon.isLegendary(sp) then return end
    seen[sp] = true
    pool[#pool + 1] = sp
  end

  local encounters = game and game.data and game.data.encounters
  local enc = encounters and encounters[mapId]
  if type(enc) == "table" and type(enc.grass) == "table" and type(enc.grass.slots) == "table" then
    for _, slot in ipairs(enc.grass.slots) do
      if type(slot) == "table" and slot.species then add(slot.species) end
    end
  end

  -- Borrow peaceful species from neighboring routes when town has none.
  if #pool == 0 and map and map.def and type(map.def.connections) == "table" then
    for _, dir in ipairs({ "north", "south", "east", "west" }) do
      local conn = map.def.connections[dir]
      local dest = conn and (conn.map or conn.mapId or conn.dest)
      local neighbor = dest and encounters and encounters[dest]
      if neighbor and neighbor.grass and neighbor.grass.slots then
        for _, slot in ipairs(neighbor.grass.slots) do
          if type(slot) == "table" and slot.species then add(slot.species) end
        end
      end
      if #pool >= 6 then break end
    end
  end

  if #pool == 0 then
    for _, sp in ipairs(AmbientPokemon.FALLBACK_POOL) do add(sp) end
  end
  return pool
end

function AmbientPokemon.pickSpecies(game, mapId, map)
  local pool = AmbientPokemon.speciesPool(game, mapId, map)
  if #pool == 0 then return nil end
  return pool[randInt(1, #pool)]
end

local function cellOccupied(ow, x, y, ignore)
  if not ow then return true end
  if ow.player and ow.player.cellX == x and ow.player.cellY == y then
    return true
  end
  local lists = { ow.entities, ow.npcs }
  for _, list in ipairs(lists) do
    if type(list) == "table" then
      for _, e in ipairs(list) do
        if e and e ~= ignore and e.cellX == x and e.cellY == y then
          if e.passable == true and e.overworldWildOverlay == true then
            -- debug overlay
          else
            return true
          end
        end
      end
    end
  end
  return false
end

local function isBlockedSpecial(map, x, y)
  if not map then return true end
  if map.inBounds and not map:inBounds(x, y) then return true end
  if map.isWalkableCell and not map:isWalkableCell(x, y) then return true end
  if map.isWaterCell and map:isWaterCell(x, y) then return true end
  if map.warpAtCell and map:warpAtCell(x, y) then return true end
  if map.isDoorCell and map:isDoorCell(x, y) then return true end
  if map.isCounterCell and map:isCounterCell(x, y) then return true end
  -- Reject cells immediately in front of a warp/door (block doorway).
  local dirs = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }
  for _, d in ipairs(dirs) do
    local nx, ny = x + d[1], y + d[2]
    if map.inBounds and map:inBounds(nx, ny) then
      if map.warpAtCell and map:warpAtCell(nx, ny) then return true end
      if map.isDoorCell and map:isDoorCell(nx, ny) then return true end
    end
  end
  return false
end

function AmbientPokemon.isSafeSpawnCell(ow, map, x, y, ignore)
  if isBlockedSpecial(map, x, y) then return false end
  if cellOccupied(ow, x, y, ignore) then return false end
  return true
end

function AmbientPokemon:findSpawnCell(ow, map)
  if not (ow and map) then return nil, nil end
  local player = ow.player
  local px = player and player.cellX or 5
  local py = player and player.cellY or 5
  local w = map.widthCells or 20
  local h = map.heightCells or 18

  for _ = 1, 120 do
    local x = randInt(0, math.max(0, w - 1))
    local y = randInt(0, math.max(0, h - 1))
    local dist = math.abs(x - px) + math.abs(y - py)
    if dist >= 2 and dist <= 10 and AmbientPokemon.isSafeSpawnCell(ow, map, x, y) then
      return x, y
    end
  end
  return nil, nil
end

function AmbientPokemon:_resolveSprite(species, game)
  local style = Config.spriteStyle(self.mod)
  -- The art set is mode-dependent (colored in ADVANCED vs luminance
  -- -grayscale everywhere else), so the cache key includes the redpp gate;
  -- a mid-session COLORS toggle must not keep serving stale art.
  local redpp = Config.paletteFxRedpp and Config.paletteFxRedpp() or false
  local cacheKey = tostring(species) .. "|" .. tostring(style) .. "|"
    .. (redpp and "c" or "g") .. "|"
    .. tostring((V.require("variable_size")).effectiveMode(self.mod))
  self._spriteCache = self._spriteCache or {}
  local cached = self._spriteCache[cacheKey]
  if cached then return cached end

  local providers = self.render and self.render.spriteProviders
  local def
  if providers and providers.resolve then
    local result = providers:resolve(style, species, "normal", game)
    if result and result.def and result.def.image then
      -- trueColor travels with the art: luminance sheets (non-ADVANCED) are
      -- false so the engine's zone pass colors them per mode.
      def = {
        id = "SPRITE_WILDS_AMBIENT",
        image = result.def.image,
        frames = result.def.frames or 6,
        walker = result.def.walker ~= false,
        trueColor = result.def.trueColor ~= false,
        frameWidth = result.def.frameWidth,
        frameHeight = result.def.frameHeight,
        anchorX = result.def.anchorX,
        anchorY = result.def.anchorY,
        providerId = result.providerId,
        style = style,
        species = species,
      }
    end
  end
  if not def and self.render and self.render.runtimeSheets then
    local sheets = self.render.runtimeSheets
    local SpeciesAssets = V.require("species_assets")
    local assetId = SpeciesAssets.idFor(species)
    if assetId then
      local sd = sheets:spriteDef(assetId, "normal", "SPRITE_WILDS_AMBIENT")
      if sd and sd.image then
        def = {
          id = "SPRITE_WILDS_AMBIENT",
          image = sd.image,
          frames = sd.frames or 6,
          walker = true,
          trueColor = sd.trueColor ~= false,
          frameWidth = sd.frameWidth,
          frameHeight = sd.frameHeight,
          anchorX = sd.anchorX,
          anchorY = sd.anchorY,
          providerId = "runtime",
          style = style,
          species = species,
        }
        -- Runtime fallback must still receive True Size geometry (Wild parity).
        local VariableSize = V.require("variable_size")
        local geoInfo
        def, geoInfo = VariableSize.applyToDef(self.mod, def, {
          speciesId = assetId,
          style = style,
          variant = "normal",
          spriteId = def.id,
        })
        if geoInfo and geoInfo.applied then
          def.variableSize = true
        end
      end
    end
  end
  if def then
    self._spriteCache[cacheKey] = def
  end
  return def
end

function AmbientPokemon:_markAmbient(npc, species, behavior)
  npc.wildsAmbientPokemon = true
  npc.wildsBattleable = false
  npc.wildsAggressive = false
  npc.wildsEncounterEnabled = false
  npc.overworldWildSpawn = false
  npc.ambientSpecies = species
  npc.ambientBehavior = behavior or "IDLE"
  npc.passable = false -- block like normal NPCs
  npc.pikachuFollower = false
  npc.pokepcTrailer = false
end

function AmbientPokemon:_bindSprite(npc, species, game)
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  local def = self:_resolveSprite(species, game)
  if not (def and def.image and SpriteRenderer and SpriteRenderer.new) then
    return false
  end
  local ok, sprite = pcall(SpriteRenderer.new, {
    id = def.id,
    image = def.image,
    frames = def.frames or 6,
    walker = def.walker ~= false,
    trueColor = def.trueColor ~= false,
    frameWidth = def.frameWidth,
    frameHeight = def.frameHeight,
    anchorX = def.anchorX,
    anchorY = def.anchorY,
  }, npc.id)
  if ok and sprite then
    npc.sprite = sprite
    npc._ambientSpriteKey = tostring(species) .. "|" .. tostring(Config.spriteStyle(self.mod))
      .. "|" .. (def.trueColor ~= false and "1" or "0")
    return true
  end
  return false
end

function AmbientPokemon:_makeGoldGuest(game, ow, species, x, y, behavior)
  self._nextIndex = (self._nextIndex or AmbientPokemon.INDEX_BASE) + 1
  local mapId = ow and ow.map and ow.map.id or "UNKNOWN"
  local npc = {
    id = string.format("%s_ambient_%d", tostring(mapId), self._nextIndex),
    mapId = mapId,
    cellX = x,
    cellY = y,
    homeX = x,
    homeY = y,
    px = (x or 0) * 16,
    py = (y or 0) * 16,
    facing = "down",
    moving = false,
    progress = 0,
    stepFlip = false,
    frozen = false,
    timer = randInt(90, 180),
    roamDirs = { "up", "down", "left", "right" },
    wanders = behavior == "WANDER",
    _wildsGoldGuest = true,
    def = { _wildsAmbientGuard = true, index = self._nextIndex },
  }
  function npc:walkPhase()
    if not self.moving then return 0 end
    local p = (self.progress or 0) % 16
    return (p >= 4 and p < 12) and 1 or 0
  end
  function npc:facePlayer(player)
    if not player then return end
    local dx = (player.cellX or 0) - (self.cellX or 0)
    local dy = (player.cellY or 0) - (self.cellY or 0)
    if math.abs(dx) > math.abs(dy) then
      self.facing = dx > 0 and "right" or "left"
    else
      self.facing = dy > 0 and "down" or "up"
    end
  end
  -- Gold World:drawPeople calls draw(ox, oy, scale). SpriteRenderer then
  -- draws at world px/py inside the camera transform (same as Gold NPC).
  function npc:draw(ox, oy, scale)
    if not (self.sprite and self.sprite.draw) then return end
    local phase = self:walkPhase()
    if scale == nil then
      self.sprite:draw(self.px or 0, self.py or 0, ox or 0, oy or 0,
                       self.facing or "down", phase, self.stepFlip)
      return
    end
    local G = love and love.graphics
    if G and G.push then
      G.push()
      G.translate(ox or 0, oy or 0)
      G.scale(scale, scale)
      self.sprite:draw(self.px or 0, self.py or 0, 0, 0,
                       self.facing or "down", phase, self.stepFlip)
      G.pop()
    else
      self.sprite:draw(self.px or 0, self.py or 0, 0, 0,
                       self.facing or "down", phase, self.stepFlip)
    end
  end
  function npc:update(map, entities)
    if self.frozen then return end
    local stepLen = 16
    local DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
    if self.moving then
      self.progress = (self.progress or 0) + 1
      local d = DELTA[self.facing] or { 0, 1 }
      local moved = math.floor((self.progress or 0) * 16 / stepLen)
      self.px = (self.cellX or 0) * 16 + d[1] * moved
      self.py = (self.cellY or 0) * 16 + d[2] * moved
      if self.progress >= stepLen then
        self.cellX, self.cellY = self.targetX, self.targetY
        self.targetX, self.targetY = nil, nil
        self.px, self.py = (self.cellX or 0) * 16, (self.cellY or 0) * 16
        self.moving = false
        self.stepFlip = not self.stepFlip
        self.progress = 0
      end
      return
    end
    if not self.wanders then return end
    self.timer = (self.timer or 90) - 1
    if self.timer > 0 then
      if self.timer % 45 == 0 and chance(0.35) then
        local dirs = self.roamDirs or { "up", "down", "left", "right" }
        self.facing = dirs[randInt(1, #dirs)]
      end
      return
    end
    self.timer = randInt(90, 220)
    local dirs = self.roamDirs or { "up", "down", "left", "right" }
    local dir = dirs[randInt(1, #dirs)]
    self.facing = dir
    if chance(0.55) then return end
    local d = DELTA[dir] or { 0, 1 }
    local tx, ty = (self.cellX or 0) + d[1], (self.cellY or 0) + d[2]
    if not AmbientPokemon.isSafeSpawnCell(
         { player = ow.player, entities = entities, npcs = ow.npcs },
         map, tx, ty, self) then
      return
    end
    self.targetX, self.targetY = tx, ty
    self.moving = true
    self.progress = 0
  end
  self:_markAmbient(npc, species, behavior)
  self:_bindSprite(npc, species, game)
  return npc
end

function AmbientPokemon:_makeNpc(game, ow, species, x, y, behavior)
  local GameCompat = V.require("game_compat")
  -- Gold has no Gen1 NPC constructor contract (SPRITE_PIKACHU assert, WALK/STAY
  -- strings). Build a guest that Gold World:drawPeople / updatePeople already
  -- iterate — same SpriteRenderer as Gen1 ambient, no second renderer.
  if GameCompat.isGen2(nil, game) then
    return self:_makeGoldGuest(game, ow, species, x, y, behavior)
  end

  local NPC = tryRequire("src.world.NPC")
  if not (NPC and NPC.new and game and game.data) then return nil end

  -- Ensure placeholder sprite exists for NPC.new assert.
  local sprites = game.data.sprites
  if sprites and not sprites[AmbientPokemon.SPRITE_PLACEHOLDER] then
    return nil
  end

  self._nextIndex = self._nextIndex + 1
  local movement = (behavior == "WANDER") and "WALK" or "STAY"
  local range = (behavior == "WANDER") and "ANY_DIR" or "DOWN"
  local npc = NPC.new(game.data, ow.map.id, {
    index = self._nextIndex,
    name = "AMBIENT_" .. tostring(species),
    sprite = AmbientPokemon.SPRITE_PLACEHOLDER,
    movement = movement,
    range = range,
    x = x,
    y = y,
  })
  self:_markAmbient(npc, species, behavior)
  self:_bindSprite(npc, species, game)

  -- Safer wander: longer pauses, avoid special tiles (NPC.update already
  -- avoids warps; we wrap to reject doors/counters too).
  if behavior == "WANDER" then
    local origUpdate = npc.update
    npc.update = function(selfNpc, map, entities)
      if selfNpc.frozen then return end
      if not selfNpc.moving then
        selfNpc.timer = (selfNpc.timer or 90) - 1
        if selfNpc.timer > 0 then
          -- Idle glance: rare facing change without step.
          if selfNpc.timer % 45 == 0 and chance(0.35) then
            local dirs = { "up", "down", "left", "right" }
            selfNpc.facing = dirs[randInt(1, 4)]
          end
          return
        end
        selfNpc.timer = randInt(90, 220)
        local dirs = selfNpc.roamDirs or { "up", "down", "left", "right" }
        local dir = dirs[randInt(1, #dirs)]
        selfNpc.facing = dir
        if chance(0.55) then return end -- pause more often than stock NPCs
        local Collision = tryRequire("src.world.Collision")
        if not Collision then
          if origUpdate then return origUpdate(selfNpc, map, entities) end
          return
        end
        local tx, ty = Collision.target(selfNpc.cellX, selfNpc.cellY, dir)
        if not AmbientPokemon.isSafeSpawnCell(
             { player = ow.player, entities = entities, npcs = ow.npcs },
             map, tx, ty, selfNpc) then
          return
        end
        if Collision.canMove(map, entities, selfNpc, dir) then
          selfNpc.targetX, selfNpc.targetY = tx, ty
          selfNpc.moving = true
          selfNpc.progress = 0
        end
        return
      end
      if origUpdate then return origUpdate(selfNpc, map, entities) end
    end
  end

  return npc
end

local function removeFromArray(array, target)
  if not array then return end
  for i = #array, 1, -1 do
    if array[i] == target then
      table.remove(array, i)
      return
    end
  end
end

function AmbientPokemon:removeNpc(ow, npc)
  if not npc then return end
  if ow then
    removeFromArray(ow.npcs, npc)
    removeFromArray(ow.entities, npc)
  end
  self.active[npc] = nil
end

function AmbientPokemon:clearAll(ow)
  local pending = {}
  for npc in pairs(self.active) do
    pending[#pending + 1] = npc
  end
  for _, npc in ipairs(pending) do
    self:removeNpc(ow, npc)
  end
  self.active = {}
end

function AmbientPokemon:spawnForMap(game, ow)
  if not Config.townPokemonEnabled(self.mod) then
    self:clearAll(ow)
    return 0
  end
  if not (game and ow and ow.map) then return 0 end
  local map = ow.map
  local mapId = map.id
  if not AmbientPokemon.isEligibleMap(game, mapId, map) then
    self:clearAll(ow)
    self.activeMapId = mapId
    return 0
  end

  -- Indoor toggle: skip buildings when Indoor Mons is OFF.
  if not Config.indoorPokemonEnabled(self.mod) then
    local kind = AmbientPokemon.classifyMap(game, mapId, map)
    local indoorKinds = { pokecenter = true, house = true, mart = true, lab = true, gate = true }
    if indoorKinds[kind] then
      self:clearAll(ow)
      self.activeMapId = mapId
      return 0
    end
  end

  -- Already populated for this map.
  if self.activeMapId == mapId then
    local n = 0
    for npc in pairs(self.active) do
      if npc.mapId == mapId or true then n = n + 1 end
    end
    if n > 0 then return n end
  else
    self:clearAll(ow)
  end

  local target = AmbientPokemon.targetCount(game, mapId, map)
  local spawned = 0
  local GameCompat = V.require("game_compat")
  local function placeOne(species, behavior)
    local x, y = self:findSpawnCell(ow, map)
    if not x then return false end
    if not species then return false end
    local npc = self:_makeNpc(game, ow, species, x, y, behavior)
    if not npc then return false end
    npc.mapId = mapId
    ow.npcs = ow.npcs or {}
    ow.entities = ow.entities or {}
    table.insert(ow.npcs, npc)
    table.insert(ow.entities, npc)
    self.active[npc] = true
    return true
  end

  if GameCompat.isGen2(nil, game) then
    local Town = V.require("gen2/town_pokemon")
    for _, entry in ipairs(Town.entriesForMap(mapId)) do
      for _ = 1, (entry.count or 0) do
        local behavior = chance(0.65) and "IDLE" or "WANDER"
        if placeOne(entry.species, behavior) then
          spawned = spawned + 1
        else
          break
        end
      end
    end
  else
    for _ = 1, target do
      local behavior = chance(0.65) and "IDLE" or "WANDER"
      if placeOne(AmbientPokemon.pickSpecies(game, mapId, map), behavior) then
        spawned = spawned + 1
      else
        break
      end
    end
  end
  self.activeMapId = mapId
  if Config.debug(self.mod) then
    DebugLog.info(self.mod, "ambient town pokemon spawned=%d map=%s",
                  spawned, tostring(mapId))
  end
  return spawned
end

local function liveOw(self)
  local world = self.mod and self.mod.world
  local game = world and world.game
  local GameCompat = V.require("game_compat")
  local ow = GameCompat.liveOverworld(self.mod, game)
  if ow then return ow, game end
  if world and world.overworld then
    if type(world.overworld) == "function" then
      local ok, got = pcall(world.overworld, world)
      if ok then return got, game end
    elseif type(world.overworld) == "table" then
      return world.overworld, game
    end
  end
  return nil, game
end

function AmbientPokemon:onMapEntered(ev)
  self._pendingBattleReturnReconcile = false
  self._battleReturnFlushedOnce = false
  local ow, game = liveOw(self)
  if not ow then return end
  local mapId = ev and (ev.mapId or (ev.map and ev.map.id))
  if mapId and self.activeMapId and self.activeMapId ~= mapId then
    self:clearAll(ow)
  end
  self:spawnForMap(game, ow)
end

function AmbientPokemon:onMapExited(ev)
  local ow = liveOw(self)
  self:clearAll(ow)
  self.activeMapId = nil
  self._pendingBattleReturnReconcile = false
  self._battleReturnFlushedOnce = false
end

-- Reattach curated town guests after the engine rebuilds ow.npcs / ow.entities.
-- Does not roll a new town set when the existing NPCs can be reinserted.
function AmbientPokemon:reconcileAfterBattle(ow, game, source)
  ow = ow or select(1, liveOw(self))
  game = game or (self.mod and self.mod.world and self.mod.world.game)
  if not ow or not ow.map or not ow.player then
    return false, "no_overworld"
  end
  if ow.battleActive then return false, "battle_active" end
  if self.activeMapId and self.activeMapId ~= ow.map.id then
    self._pendingBattleReturnReconcile = false
    return false, "map_mismatch"
  end
  local GameCompat = V.require("game_compat")
  local missing, reattached = 0, 0
  for npc in pairs(self.active) do
    if npc then
      local attached = GameCompat.entityInDrawList(ow, npc, game)
      if not attached then
        missing = missing + 1
        GameCompat.attachGuestEntity(ow, npc, game)
        if GameCompat.entityInDrawList(ow, npc, game) then
          reattached = reattached + 1
        end
      end
    end
  end
  if reattached > 0 then
    local logic = self.mod and self.mod.exports and self.mod.exports.logic
    if logic and logic.markOccupancyDirty then
      logic:markOccupancyDirty()
    end
  end
  if Config.debug(self.mod) then
    DebugLog.info(self.mod,
      "[BattleReturn] %s ambientMissing=%d ambientReattached=%d ambient=%d",
      tostring(source or "reconcile"), missing, reattached, self:countActive())
  end
  return true, { missing = missing, reattached = reattached, attached = self:countActive() }
end

function AmbientPokemon:onBattleEnded(ev)
  self._pendingBattleReturnReconcile = true
  local ow, game = liveOw(self)
  local source = ev and ev.source or "battle.ended"
  if source ~= "world.stepped" and self._battleReturnFlushedOnce then
    return true, "already_flushed"
  end
  local ok, info = self:reconcileAfterBattle(ow, game, source)
  if ok then
    self._battleReturnFlushedOnce = true
    if source == "world.stepped" then
      self._pendingBattleReturnReconcile = false
      self._battleReturnFlushedOnce = false
    end
  end
  return ok, info
end

function AmbientPokemon:onTownPokemonToggled(on, game)
  local ow, liveGame = liveOw(self)
  game = game or liveGame
  if not on then
    self:clearAll(ow)
    return
  end
  if ow and ow.map then
    self.activeMapId = nil -- force respawn
    self:spawnForMap(game, ow)
  end
end

function AmbientPokemon:refreshSprites(game)
  self._spriteCache = {}
  local world = self.mod.world
  game = game or (world and world.game)
  local n = 0
  for npc in pairs(self.active) do
    if npc and npc.ambientSpecies then
      if self:_bindSprite(npc, npc.ambientSpecies, game) then
        n = n + 1
      end
    end
  end
  return n
end

function AmbientPokemon:talkTo(ow, npc, done)
  local game = (ow and ow.game)
    or (self.mod.world and self.mod.world.game)
  if not (npc and npc.wildsAmbientPokemon) then
    if done then done() end
    return
  end
  -- Finish mid-step so interact's not-moving gate stays happy next frame.
  if npc.moving then
    npc.cellX = npc.targetX or npc.cellX
    npc.cellY = npc.targetY or npc.cellY
    npc.targetX, npc.targetY = nil, nil
    npc.px = (npc.cellX or 0) * 16
    npc.py = (npc.cellY or 0) * 16
    npc.moving, npc.marching = false, false
    npc.progress = 0
  end
  npc.frozen = true
  local unfreeze = function()
    npc.frozen = false
    if done then done() end
  end
  if npc.facePlayer and ow and ow.player then
    pcall(npc.facePlayer, npc, ow.player)
  end
  if ow and ow.player and npc.facing then
    local OPP = { up = "down", down = "up", left = "right", right = "left" }
    ow.player.facing = OPP[npc.facing] or ow.player.facing
  end

  local species = npc.ambientSpecies
  local Sound = tryRequire("src.core.Sound")
  if Sound and Sound.playCry and game and game.data and species then
    pcall(Sound.playCry, game.data, species)
  end

  local text = AmbientCries.textFor(species)
  local GameCompat = V.require("game_compat")
  GameCompat.presentText(self.mod, game, ow, text, unfreeze)
end

function AmbientPokemon:_installTalkWrap()
  -- Gen1: wrap OverworldController.talkTo (unchanged).
  -- Gold: the same wrap is the World:interactBody talkToWrapper seam;
  -- a true return suppresses vanilla trainer/script dispatch.
  local OverworldState = tryRequire("src.world.OverworldController")
  if not (OverworldState and OverworldState.talkTo) then return false end
  if OverworldState._wildsAmbientTalkWrap == OverworldState.talkTo then
    return true
  end
  local manager = self
  local orig = OverworldState.talkTo
  local function wrap(selfOw, npc, ...)
    if npc and npc.wildsAmbientPokemon then
      manager:talkTo(selfOw, npc)
      return true
    end
    -- Never start battles from ambient even if flags were stripped.
    if npc and npc.def and npc.def._wildsAmbientGuard then
      manager:talkTo(selfOw, npc)
      return true
    end
    return orig(selfOw, npc, ...)
  end
  OverworldState.talkTo = wrap
  OverworldState._wildsAmbientTalkWrap = wrap
  self._talkOrig = orig
  self._talkWrapped = true
  return true
end

function AmbientPokemon:install()
  if self._installed then return true end
  self:_installTalkWrap()
  self._installed = true
  return true
end

function AmbientPokemon:onOptionsChanged(payload)
  if not payload then return end
  local key = payload.key
  if key == "town_pokemon" then
    self:onTownPokemonToggled(Config.townPokemonEnabled(self.mod))
  elseif key == "sprite_style"
      or key == "use_animated_overworld_sprites"
      or key == "pokemon_size" then
    local game = self.mod.world and self.mod.world.game
    self:refreshSprites(game)
  end
end

function AmbientPokemon:countActive()
  local n = 0
  for _ in pairs(self.active) do n = n + 1 end
  return n
end

--- Dev overlay label helper.
function AmbientPokemon.devLabel(entity)
  if not entity or not entity.wildsAmbientPokemon then return nil end
  local beh = upper(entity.ambientBehavior or "IDLE")
  if beh == "WANDER" then return "AMBIENT", "WANDER" end
  return "AMBIENT", "IDLE"
end

return AmbientPokemon
