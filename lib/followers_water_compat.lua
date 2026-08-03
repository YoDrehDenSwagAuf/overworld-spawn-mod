-- Optional Followers EX / PokePC water-sprite compatibility.
--
-- Ownership stays with Followers EX (spawn, queue, pathing, battle).
-- Wilds only swaps the native SpriteDef on the existing follower entity when
-- the player transitions land ↔ water, using the public resolveWaterSprite API.
--
-- Never reads private Followers tables. Detection uses:
--   * mod.find("FOLLOWERS_EX"|"PokePCFollowers_VoxelMerge").exports
--   * public markers on ow.entities (pokepcTrailer, pikachuFollower, sprite ids)
--   * optional ow.pokepcTrailers list published on the shared overworld
local V = ...
local DebugLog = V.require("debug_log")
local CellOccupancy = V.require("cell_occupancy")
local Surface = V.require("surface")

local FollowersWaterCompat = {}
FollowersWaterCompat.__index = FollowersWaterCompat

local FOLLOWERS_MOD_ID = "FOLLOWERS_EX"
local POKEPC_MOD_ID = "PokePCFollowers_VoxelMerge"

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function findExports(mod)
  if not (mod and mod.find) then return nil, nil end
  for _, id in ipairs({ FOLLOWERS_MOD_ID, POKEPC_MOD_ID }) do
    local hit = mod:find(id)
    if hit and hit.exports then
      return hit.exports, id
    end
  end
  return nil, nil
end

local function playerInWater(player, game)
  if not player then return false end
  if player.surfing == true or player.isSurfing == true then return true end
  if player.surface == Surface.WATER or player.surface == "water" then
    return true
  end
  -- Engine surf state when exposed.
  if game and game.player and game.player.surfing == true then
    return true
  end
  if player.surfing == false then return false end
  return false
end

local function monShiny(mon)
  if not mon then return false end
  if mon.shiny == true or mon.isShiny == true then return true end
  local Stats = tryRequire("src.pokemon.Stats")
  if Stats and Stats.isShiny and mon.dvs then
    local ok, shiny = pcall(Stats.isShiny, mon.dvs)
    if ok and shiny then return true end
  end
  return false
end

local function speciesKeyOf(entity, mon)
  if entity then
    if entity.pokepcMon and entity.pokepcMon.species then
      return tostring(entity.pokepcMon.species)
    end
    if entity.species then return tostring(entity.species) end
    local def = entity.sprite and entity.sprite.def
    if def and def.id == "SPRITE_PIKACHU" then return "PIKACHU" end
  end
  if mon and mon.species then return tostring(mon.species) end
  return nil
end

function FollowersWaterCompat.new(mod, opts)
  opts = opts or {}
  local self = setmetatable({}, FollowersWaterCompat)
  self.mod = mod
  self.resolveWaterSprite = opts.resolveWaterSprite
  self._cache = {
    entityId = nil,
    speciesId = nil,
    variant = nil,
    form = nil,
    surfaceState = nil,
  }
  self.status = {
    detected = false,
    surface = "land",
    waterSprite = "n/a",
    spriteKind = "n/a",
    lastAction = "idle",
  }
  self._landBackup = nil -- per entity id
  return self
end

function FollowersWaterCompat:isInstalled()
  local ex = select(1, findExports(self.mod))
  return ex ~= nil
end

function FollowersWaterCompat:publicApi()
  return select(1, findExports(self.mod))
end

function FollowersWaterCompat:collectFollowerEntities(ow)
  local out = {}
  if not ow then return out end
  local seen = {}
  local function add(e)
    if not e or seen[e] then return end
    if CellOccupancy.isFollowerEntity(e) then
      seen[e] = true
      out[#out + 1] = e
    end
  end
  if type(ow.pokepcTrailers) == "table" then
    for _, e in ipairs(ow.pokepcTrailers) do add(e) end
  end
  for _, e in ipairs(ow.entities or {}) do add(e) end
  for _, e in ipairs(ow.npcs or {}) do add(e) end
  return out
end

function FollowersWaterCompat:activeFollower(ow, game)
  local followers = self:collectFollowerEntities(ow)
  if #followers == 0 then
    self.status.detected = false
    return nil, nil
  end
  local api = self:publicApi()
  local mon = nil
  if api and type(api.getActiveFollowerMon) == "function" then
    local ok, got = pcall(api.getActiveFollowerMon, game)
    if ok then mon = got end
  end
  -- Prefer mon trailer matching active mon species; else first mon trailer.
  local best = nil
  local want = mon and mon.species and tostring(mon.species) or nil
  for _, e in ipairs(followers) do
    if e.pokepcTrailerKind == "trainer" then
      -- skip trainer trailers for water sprites
    else
      local key = speciesKeyOf(e, mon)
      if want and key == want then
        best = e
        break
      end
      if not best then best = e end
    end
  end
  self.status.detected = best ~= nil
  return best, mon
end

local function applySpriteDef(entity, def)
  if not entity or not def or type(def.image) ~= "string" then
    return false
  end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not SpriteRenderer then return false end
  local renderDef = {
    image = def.image,
    frames = def.frames or 6,
    walker = def.walker ~= false,
    trueColor = def.trueColor ~= false,
    id = def.id or "SPRITE_POKEPC_MON",
  }
  if def.pokepcShiny then renderDef.pokepcShiny = true end
  local ok, sprite = pcall(SpriteRenderer.new, renderDef, entity.spawnId or entity.id)
  if not (ok and sprite) then return false end
  entity.sprite = sprite
  entity.legacySprite = sprite
  entity.spriteId = renderDef.id
  entity.usingFollowerSprite = true
  return true
end

local function backupLand(self, entity)
  local def = entity.sprite and entity.sprite.def
  if not def or type(def.image) ~= "string" then return end
  local id = tostring(entity.id or entity.spawnId or entity)
  self._landBackup = self._landBackup or {}
  self._landBackup[id] = {
    image = def.image,
    frames = def.frames or 6,
    walker = def.walker ~= false,
    trueColor = def.trueColor ~= false,
    id = def.id,
    pokepcShiny = def.pokepcShiny,
    species = speciesKeyOf(entity),
    shiny = entity.pokepcShiny == true,
  }
end

local function restoreLand(self, entity, mon)
  local id = tostring(entity.id or entity.spawnId or entity)
  local bak = self._landBackup and self._landBackup[id]
  local species = speciesKeyOf(entity, mon)
  local shiny = mon and monShiny(mon) or (entity.pokepcShiny == true)
  -- If species/shiny changed, do not blind-restore stale backup.
  if bak and bak.species and species and bak.species ~= species then
    bak = nil
  end
  if bak and bak.shiny ~= nil and bak.shiny ~= shiny then
    bak = nil
  end
  if bak then
    if applySpriteDef(entity, bak) then
      entity.spriteState = "land"
      return true, "backup"
    end
  end
  -- Leave existing Followers land art alone if we cannot restore.
  entity.spriteState = "land"
  return false, "keep_current"
end

function FollowersWaterCompat:cacheKey(entity, speciesId, variant, form, surfaceState)
  return table.concat({
    tostring(entity and (entity.id or entity.spawnId) or ""),
    tostring(speciesId or ""),
    tostring(variant or "normal"),
    tostring(form or "default"),
    tostring(surfaceState or "land"),
  }, "|")
end

function FollowersWaterCompat:tick(game, ow, resolveWaterSprite)
  resolveWaterSprite = resolveWaterSprite or self.resolveWaterSprite
  local ex, exId = findExports(self.mod)
  if not ex then
    self.status.detected = false
    self.status.surface = "n/a"
    self.status.waterSprite = "n/a"
    self.status.spriteKind = "n/a"
    return false
  end

  local player = ow and ow.player
  local inWater = playerInWater(player, game)
  local surfaceState = inWater and "water" or "land"
  self.status.surface = surfaceState

  local entity, mon = self:activeFollower(ow, game)
  if not entity then
    self.status.waterSprite = "n/a"
    self.status.spriteKind = "n/a"
    self.status.lastAction = "no_follower"
    self._cache.surfaceState = surfaceState
    return false
  end

  local species = speciesKeyOf(entity, mon)
  local shiny = mon and monShiny(mon) or (entity.pokepcShiny == true)
  local variant = shiny and "shiny" or "normal"
  local form = entity.form or (mon and mon.form) or "default"
  local entityId = tostring(entity.id or entity.spawnId or entity)
  local key = self:cacheKey(entity, species, variant, form, surfaceState)
  local prev = self._cache
  local prevKey = self:cacheKey(
    { id = prev.entityId }, prev.speciesId, prev.variant, prev.form, prev.surfaceState)

  if key == prevKey and prev.entityId == entityId then
    self.status.lastAction = "cached"
    return false
  end

  local changedSurface = prev.surfaceState ~= surfaceState
  local changedFollower = prev.entityId ~= entityId
    or prev.speciesId ~= tostring(species or "")
    or prev.variant ~= variant
    or tostring(prev.form or "default") ~= tostring(form)

  if not (changedSurface or changedFollower or prev.entityId == nil) then
    self.status.lastAction = "noop"
    return false
  end

  if surfaceState == "water" then
    if type(resolveWaterSprite) ~= "function" then
      self.status.waterSprite = "unavailable"
      self.status.spriteKind = "n/a"
      self.status.lastAction = "no_resolver"
      DebugLog.info(self.mod, "Follower water sprite: unavailable")
      DebugLog.info(self.mod, "Follower fallback: existing land sprite")
      self._cache = {
        entityId = entityId, speciesId = tostring(species or ""),
        variant = variant, form = form, surfaceState = surfaceState,
      }
      return false
    end
    backupLand(self, entity)
    local def, meta = resolveWaterSprite(species, shiny, form, {
      game = game,
      follower = true,
      allowLandFallback = false,
    })
    if not def then
      self.status.waterSprite = "unavailable"
      self.status.spriteKind = "n/a"
      self.status.lastAction = "no_water_sprite"
      DebugLog.info(self.mod, "Follower water sprite: unavailable")
      DebugLog.info(self.mod, "Follower fallback: existing land sprite")
      -- Prefer Followers EX own surf handling; keep land art.
      self._cache = {
        entityId = entityId, speciesId = tostring(species or ""),
        variant = variant, form = form, surfaceState = surfaceState,
      }
      return false
    end
    if applySpriteDef(entity, {
      image = def.image,
      frames = def.frames or (meta and meta.frames) or 6,
      walker = def.walker ~= false,
      trueColor = true,
      id = def.id or "SPRITE_POKEPC_MON",
      pokepcShiny = shiny or nil,
    }) then
      entity.spriteState = "water"
      entity.wildsFollowerWater = true
      self.status.waterSprite = "YES"
      self.status.spriteKind = tostring((meta and meta.kind) or def.kind or "?")
      self.status.lastAction = "to_water"
      DebugLog.info(self.mod,
        "Follower water sprite: %s (%s) via %s",
        tostring(species), self.status.spriteKind, tostring(exId))
    else
      self.status.waterSprite = "unavailable"
      self.status.lastAction = "apply_failed"
      DebugLog.info(self.mod, "Follower water sprite: unavailable")
      DebugLog.info(self.mod, "Follower fallback: existing land sprite")
    end
  else
    local ok = restoreLand(self, entity, mon)
    entity.wildsFollowerWater = false
    self.status.waterSprite = "n/a"
    self.status.spriteKind = "land"
    self.status.lastAction = ok and "to_land" or "to_land_keep"
  end

  self._cache = {
    entityId = entityId,
    speciesId = tostring(species or ""),
    variant = variant,
    form = form,
    surfaceState = surfaceState,
  }
  return true
end

function FollowersWaterCompat:hudLines()
  return {
    ("Follower detected: %s"):format(self.status.detected and "YES" or "NO"),
    ("Follower surface: %s"):format(tostring(self.status.surface or "?")),
    ("Follower water sprite: %s"):format(tostring(self.status.waterSprite or "?")),
    ("Follower sprite kind: %s"):format(tostring(self.status.spriteKind or "?")),
  }
end

return FollowersWaterCompat
