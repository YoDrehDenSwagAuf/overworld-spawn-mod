-- Followers EX / PokePC / Wilds unified follower sprite-style + water compatibility.
--
-- Entity ownership:
--   * Followers EX control engine (when active) owns trailers / pack pathing.
--   * Otherwise Wilds `lib/follower/` owns the single PikachuFollower entity.
-- This module only swaps the native SpriteDef on the existing follower entity when:
--   * the selected Sprite Style changes
--   * the follower species / shiny / form changes
--   * the player transitions land ↔ water
--
-- Never reads private Followers tables. Detection uses:
--   * mod.find("FOLLOWERS_EX"|"PokePCFollowers_VoxelMerge").exports
--   * mod.exports.getActiveFollowerMon (Wilds unified selection)
--   * public markers on ow.entities (pokepcTrailer, pikachuFollower, wildsFollower)
--   * optional ow.pokepcTrailers list published on the shared overworld
local V = ...
local Config = V.require("config")
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
  if game and game.player and game.player.surfing == true then
    return true
  end
  -- Last resort: the player's own cell is water (surf field flags vary across
  -- engine builds). Keeps the follower water sprites in sync with movement.
  local ow = player.ow or (game and game.overworld)
  if ow and ow.map and player.cellX ~= nil and player.cellY ~= nil
     and type(ow.map.isWaterCell) == "function" then
    local ok, water = pcall(ow.map.isWaterCell, ow.map, player.cellX, player.cellY)
    if ok and water == true then return true end
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
    -- Stock Yellow Pikachu entity: its art follows the selected follower
    -- species (ControlEngine:forceYellowStockPikachuArt), not the entity id
    -- or any stale engine species field.
    if entity._wildsFollowerSpecies then
      return tostring(entity._wildsFollowerSpecies)
    end
    if entity.species then return tostring(entity.species) end
    local def = entity.sprite and entity.sprite.def
    if def and def.id == "SPRITE_PIKACHU" then return "PIKACHU" end
  end
  if mon and mon.species then return tostring(mon.species) end
  return nil
end

local function entityIdentity(entity)
  if not entity then return "" end
  return tostring(entity.pokepcTrailerId or entity.id or entity.spawnId or entity)
end

function FollowersWaterCompat.new(mod, opts)
  opts = opts or {}
  local self = setmetatable({}, FollowersWaterCompat)
  self.mod = mod
  self.resolveWaterSprite = opts.resolveWaterSprite
  self.resolveLandSprite = opts.resolveLandSprite
  -- Per-entity cache keyed by entityIdentity. Pack trailers must not share
  -- a single global water/land sprite cache.
  self._entityCaches = {}
  -- Legacy single-slot mirror of the first updated trailer (HUD / tests).
  self._cache = {
    entityId = nil,
    speciesId = nil,
    variant = nil,
    form = nil,
    surfaceState = nil,
    requestedStyle = nil,
    image = nil,
    frames = nil,
    walker = nil,
  }
  self.status = {
    detected = false,
    surface = "land",
    waterSprite = "n/a",
    spriteKind = "n/a",
    requestedStyle = "auto",
    activeProvider = "n/a",
    lastAction = "idle",
  }
  self._landBackup = nil
  self._styleGeneration = 0
  self._activeEntity = nil
  self._activeEntityId = nil
  self._spriteRendererNews = 0
  return self
end

function FollowersWaterCompat:isInstalled()
  local ex = select(1, findExports(self.mod))
  if ex ~= nil then return true end
  -- Wilds unified follower core (no external mod required).
  local exports = self.mod and self.mod.exports
  return exports ~= nil and type(exports.getActiveFollowerMon) == "function"
end

function FollowersWaterCompat:publicApi()
  return select(1, findExports(self.mod))
end

local function wildsFollowerApi(mod)
  local exports = mod and mod.exports
  if exports and type(exports.getActiveFollowerMon) == "function" then
    return exports
  end
  return nil
end

function FollowersWaterCompat:invalidateStyle()
  self._styleGeneration = (self._styleGeneration or 0) + 1
  self._entityCaches = {}
  self._cache.requestedStyle = nil -- force refresh on next tick
  self._cache.image = nil
  self.status.lastAction = "style_invalidated"
end

function FollowersWaterCompat:_cacheFor(entity)
  local id = entityIdentity(entity)
  if id == "" then return nil, id end
  local caches = self._entityCaches
  if not caches[id] then
    caches[id] = {
      entityId = id,
      speciesId = nil,
      variant = nil,
      form = nil,
      surfaceState = nil,
      requestedStyle = nil,
      image = nil,
      frames = nil,
      walker = nil,
    }
  end
  return caches[id], id
end

--- Resolve the mon table for one trailer. Pack trailers use entity.pokepcMon;
-- only the primary/stock follower may fall back to the global active selection.
function FollowersWaterCompat:monForEntity(entity, game)
  if not entity then return nil end
  if entity.pokepcMon and entity.pokepcMon.species then
    return entity.pokepcMon
  end
  local role = entity.wildsFollowerRole
  local isPrimary = role == "primary"
    or (entity.pikachuFollower == true and entity.pokepcTrailer ~= true)
  if not isPrimary then
    return nil
  end
  local wildsExports = self.mod and self.mod.exports
  if wildsExports and type(wildsExports.getActiveFollowerMon) == "function" then
    local ok, got = pcall(wildsExports.getActiveFollowerMon, game, true)
    if ok and got then return got end
  end
  local api = self:publicApi()
  if api and type(api.getActiveFollowerMon) == "function" then
    local ok, got = pcall(api.getActiveFollowerMon, game)
    if ok and got then return got end
  end
  return nil
end

-- Verified Followers EX / PokePC public export used by Wilds:
--   getActiveFollowerMon(game) → party mon table (species, dvs, form, …)
-- No verified public sprite-swap / refresh export exists. Do NOT probe
-- guessed method names — that can re-bind Followers art and cause flicker.

local function entityStillPresent(ow, entity)
  if not ow or not entity then return false end
  local lists = { ow.pokepcTrailers, ow.entities, ow.npcs }
  for _, list in ipairs(lists) do
    if type(list) == "table" then
      for _, e in ipairs(list) do
        if e == entity then return true end
      end
    end
  end
  return false
end

local function isPokemonTrailer(entity)
  if not entity then return false end
  if entity.pokepcTrailerKind == "trainer" then return false end
  if entity.pokepcTrailerKind == "mon" or entity.pokepcTrailerKind == "pokemon" then
    return true
  end
  if entity.pokepcTrailer == true or entity.pikachuFollower == true then
    return true
  end
  if entity.wildsFollower == true then return true end
  return CellOccupancy.isFollowerEntity(entity)
end

-- Exact def copy for SpriteRenderer. Never invent walker sheets from static art.
local function copySpriteDef(def)
  local renderDef = {}
  if type(def) == "table" then
    for k, v in pairs(def) do
      renderDef[k] = v
    end
  end
  renderDef.image = def.image
  renderDef.frames = def.frames or 1
  renderDef.walker = def.walker == true
  if def.trueColor == nil then
    renderDef.trueColor = true
  else
    renderDef.trueColor = def.trueColor ~= false
  end
  renderDef.id = def.id or "SPRITE_POKEPC_MON"
  if def.pokepcShiny then
    renderDef.pokepcShiny = true
  end
  return renderDef
end

local function defAlreadyBound(entity, renderDef)
  local cur = entity and entity.sprite and entity.sprite.def
  if not cur or not renderDef then return false end
  return cur.image == renderDef.image
     and (cur.frames or 1) == (renderDef.frames or 1)
     and (cur.walker == true) == (renderDef.walker == true)
end

-- Entity-local SpriteRenderer swap only. Never touches content registries,
-- game.data.pokemon, or battle spriteFront / spriteBack.
local function applySpriteDef(entity, def)
  if not entity or not def or type(def.image) ~= "string" then
    return false, "bad_def"
  end

  local renderDef = copySpriteDef(def)
  if defAlreadyBound(entity, renderDef) then
    entity.usingFollowerSprite = true
    entity.usingEnhancedSprite = false
    if renderDef.walker == true and (renderDef.frames or 1) >= 6 then
      entity.nativeSpriteRenderer = true
    end
    return true, "unchanged"
  end

  -- Snapshot Followers-owned pose / movement fields before any swap.
  -- Sprite rebind must never reset trailer motion (water freeze regression).
  local preserved = {
    facing = entity.facing,
    phase = entity.phase,
    flip = entity.flip,
    stepFlip = entity.stepFlip,
    walkFlip = entity.walkFlip,
    walkPhase = entity.walkPhase,
    movement = entity.movement,
    position = entity.position,
    cellX = entity.cellX,
    cellY = entity.cellY,
    px = entity.px,
    py = entity.py,
    targetX = entity.targetX,
    targetY = entity.targetY,
    moving = entity.moving,
    progress = entity.progress,
    stepFrames = entity.stepFrames,
    hopStep = entity.hopStep,
    passable = entity.passable,
    pokepcShiny = entity.pokepcShiny,
    pokepcTrailer = entity.pokepcTrailer,
    pokepcTrailerKind = entity.pokepcTrailerKind,
    pokepcMon = entity.pokepcMon,
    wildsFollowerRole = entity.wildsFollowerRole,
    form = entity.form,
  }

  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not SpriteRenderer then return false, "no_renderer" end
  local ok, sprite = pcall(SpriteRenderer.new, renderDef, entity.spawnId or entity.id)
  if not (ok and sprite) then return false, "new_failed" end

  entity.sprite = sprite
  entity.legacySprite = sprite
  entity.spriteId = renderDef.id
  entity.usingFollowerSprite = true
  entity.usingEnhancedSprite = false
  if renderDef.walker == true and (renderDef.frames or 1) >= 6 then
    entity.nativeSpriteRenderer = true
  elseif renderDef.walker ~= true then
    if entity.nativeSpriteRenderer == true and (renderDef.frames or 1) < 6 then
      entity.nativeSpriteRenderer = false
    end
  end

  entity.facing = preserved.facing
  entity.phase = preserved.phase
  entity.flip = preserved.flip
  entity.stepFlip = preserved.stepFlip
  entity.walkFlip = preserved.walkFlip
  entity.walkPhase = preserved.walkPhase
  entity.movement = preserved.movement
  entity.position = preserved.position
  entity.cellX = preserved.cellX
  entity.cellY = preserved.cellY
  entity.px = preserved.px
  entity.py = preserved.py
  entity.targetX = preserved.targetX
  entity.targetY = preserved.targetY
  entity.moving = preserved.moving
  entity.progress = preserved.progress
  entity.stepFrames = preserved.stepFrames
  entity.hopStep = preserved.hopStep
  entity.passable = preserved.passable
  if preserved.pokepcShiny ~= nil then entity.pokepcShiny = preserved.pokepcShiny end
  if preserved.pokepcTrailer ~= nil then entity.pokepcTrailer = preserved.pokepcTrailer end
  if preserved.pokepcTrailerKind ~= nil then
    entity.pokepcTrailerKind = preserved.pokepcTrailerKind
  end
  if preserved.pokepcMon ~= nil then entity.pokepcMon = preserved.pokepcMon end
  if preserved.wildsFollowerRole ~= nil then
    entity.wildsFollowerRole = preserved.wildsFollowerRole
  end
  if preserved.form ~= nil then entity.form = preserved.form end
  if renderDef.pokepcShiny and entity.pokepcShiny == nil then
    entity.pokepcShiny = true
  end
  return true, "replaced"
end

function FollowersWaterCompat:cacheKey(entity, speciesId, variant, form, surfaceState, style, image, frames, walker)
  return table.concat({
    tostring(entity and (entity.id or entity.spawnId) or ""),
    tostring(speciesId or ""),
    tostring(variant or "normal"),
    tostring(form or "default"),
    tostring(surfaceState or "land"),
    tostring(style or "auto"),
    tostring(image or ""),
    tostring(frames or ""),
    tostring(walker == true),
  }, "|")
end

local function resolveLandDef(self, species, shiny, form, style, game)
  if type(self.resolveLandSprite) == "function" then
    local def, meta = self.resolveLandSprite(species, shiny, form, {
      game = game,
      style = style,
      follower = true,
    })
    if def and type(def.image) == "string" then
      return def, meta
    end
  end
  -- Fallback: ask Wilds sprite providers through mod.exports when available.
  local exports = self.mod and self.mod.exports
  local providers = exports and exports.spriteProviders
  if providers and type(providers.resolve) == "function" then
    local variant = shiny and "shiny" or "normal"
    local result = providers:resolve(style, species, variant, game)
    if result and result.def and type(result.def.image) == "string" then
      return result.def, {
        providerId = result.providerId,
        kind = result.providerId,
      }
    end
  end
  return nil, nil
end

function FollowersWaterCompat:collectFollowerEntities(ow)
  local out = {}
  if not ow then return out end
  local seen = {}
  local function add(e)
    if not e or seen[e] then return end
    if isPokemonTrailer(e) then
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
    self._activeEntity = nil
    self._activeEntityId = nil
    return nil, nil
  end

  local api = self:publicApi()
  local mon = nil
  -- Prefer Wilds unified follower selection when installed.
  local wildsExports = self.mod and self.mod.exports
  if wildsExports and type(wildsExports.getActiveFollowerMon) == "function" then
    local ok, got = pcall(wildsExports.getActiveFollowerMon, game, true)
    if ok and got then mon = got end
  end
  -- Verified Followers EX / PokePC public export.
  if not mon and api and type(api.getActiveFollowerMon) == "function" then
    local ok, got = pcall(api.getActiveFollowerMon, game)
    if ok then mon = got end
  end
  local want = mon and mon.species and tostring(mon.species) or nil

  -- Sticky: keep the same entity reference across frames while it exists.
  local sticky = self._activeEntity
  if sticky and entityStillPresent(ow, sticky) and isPokemonTrailer(sticky) then
    local stickySpecies = speciesKeyOf(sticky, mon)
    if not want or stickySpecies == want or stickySpecies == nil then
      self.status.detected = true
      return sticky, mon
    end
  end

  local best = nil
  local pokemonOnly = {}
  for _, e in ipairs(followers) do
    if e.pokepcTrailerKind == "mon" or e.pokepcTrailerKind == "pokemon" then
      pokemonOnly[#pokemonOnly + 1] = e
    end
  end
  local pool = (#pokemonOnly > 0) and pokemonOnly or followers

  if want then
    for _, e in ipairs(pool) do
      if speciesKeyOf(e, mon) == want then
        best = e
        break
      end
    end
  end
  if not best and #pool == 1 then
    best = pool[1]
  elseif not best then
    -- Conservative: prefer previous sticky match inside pool, else first.
    for _, e in ipairs(pool) do
      if e == sticky then best = e break end
    end
    if not best then best = pool[1] end
  end

  self._activeEntity = best
  self._activeEntityId = best and tostring(best.id or best.spawnId or "") or nil
  self.status.detected = best ~= nil
  return best, mon
end

--- Update one Pokémon follower entity for the current surface.
-- Returns true when SpriteRenderer.new ran for this entity.
function FollowersWaterCompat:tickEntity(game, ow, entity, surfaceState, style, resolveWaterSprite, exId)
  if not entity or entity.pokepcTrailerKind == "trainer" then
    return false
  end
  if entity.wildsFollowerRole == "trainer_trailer" then
    return false
  end

  local mon = self:monForEntity(entity, game)
  local species = speciesKeyOf(entity, mon)
  local shiny = (mon and monShiny(mon)) or (entity.pokepcShiny == true)
  local variant = shiny and "shiny" or "normal"
  local form = entity.form or (mon and mon.form) or "default"
  local prev, entityId = self:_cacheFor(entity)
  if not prev then return false end

  local function remember(extra)
    prev.entityId = entityId
    prev.speciesId = tostring(species or "")
    prev.variant = variant
    prev.form = form
    prev.surfaceState = surfaceState
    prev.requestedStyle = style
    prev.image = extra and extra.image or nil
    prev.frames = extra and extra.frames or nil
    prev.walker = extra and extra.walker or nil
    -- Mirror first trailer into legacy _cache for HUD/tests.
    if self._activeEntity == nil or self._activeEntity == entity then
      self._cache = {
        entityId = prev.entityId,
        speciesId = prev.speciesId,
        variant = prev.variant,
        form = prev.form,
        surfaceState = prev.surfaceState,
        requestedStyle = prev.requestedStyle,
        image = prev.image,
        frames = prev.frames,
        walker = prev.walker,
      }
    end
  end

  -- Stable identity cache: no resolve / no SpriteRenderer while nothing changed.
  if prev.entityId == entityId
     and prev.speciesId == tostring(species or "")
     and prev.variant == variant
     and tostring(prev.form or "default") == tostring(form)
     and prev.surfaceState == surfaceState
     and prev.requestedStyle == style
     and prev.image ~= nil then
    self.status.lastAction = "cached"
    if surfaceState == "water" then
      entity.spriteState = "water"
      entity.wildsFollowerWater = true
      if self.status.spriteKind == "n/a" then
        self.status.spriteKind = "water"
      end
      self.status.waterSprite = "YES"
    else
      entity.spriteState = "land"
      entity.wildsFollowerWater = false
      self.status.waterSprite = "n/a"
      self.status.spriteKind = "land"
    end
    return false
  end

  local def, meta
  if surfaceState == "water" then
    if type(resolveWaterSprite) ~= "function" then
      self.status.waterSprite = "unavailable"
      self.status.spriteKind = "n/a"
      self.status.lastAction = "no_resolver"
      remember(nil)
      return false
    end
    def, meta = resolveWaterSprite(species, shiny, form, {
      game = game,
      follower = true,
      allowLandFallback = false,
    })
    if not def then
      -- No swimming sheet: stay visible with the player's selected land style
      -- (not a hard-coded HGSS fallback).
      local landDef = resolveLandDef(self, species, shiny, form, style, game)
      if landDef then
        def = landDef
        meta = { kind = "land_style_fallback" }
      end
    end
    if not def then
      self.status.waterSprite = "unavailable"
      self.status.spriteKind = "n/a"
      self.status.lastAction = "no_water_sprite"
      remember(nil)
      return false
    end
  else
    def, meta = resolveLandDef(self, species, shiny, form, style, game)
    if not def then
      entity.spriteState = "land"
      entity.wildsFollowerWater = false
      self.status.waterSprite = "n/a"
      self.status.spriteKind = "land"
      self.status.activeProvider = "keep_current"
      self.status.lastAction = "to_land_keep"
      local cur = entity.sprite and entity.sprite.def
      remember({
        image = (cur and cur.image) or "__keep_current__",
        frames = cur and cur.frames or 1,
        walker = cur and cur.walker == true,
      })
      return false
    end
  end

  local applyDef = {
    image = def.image,
    frames = def.frames or (meta and meta.frames) or 1,
    walker = def.walker == true,
    trueColor = def.trueColor ~= false,
    id = def.id or "SPRITE_POKEPC_MON",
    pokepcShiny = shiny or nil,
  }
  for k, v in pairs(def) do
    if applyDef[k] == nil then applyDef[k] = v end
  end

  local nextKey = self:cacheKey(
    entity, species, variant, form, surfaceState, style,
    applyDef.image, applyDef.frames, applyDef.walker)
  local prevKey = self:cacheKey(
    { id = prev.entityId }, prev.speciesId, prev.variant, prev.form,
    prev.surfaceState, prev.requestedStyle,
    prev.image, prev.frames, prev.walker == true)

  if nextKey == prevKey then
    self.status.lastAction = "cached"
    remember({
      image = applyDef.image,
      frames = applyDef.frames,
      walker = applyDef.walker == true,
    })
    return false
  end

  local ok, how = applySpriteDef(entity, applyDef)
  if ok then
    if how == "replaced" then
      self._spriteRendererNews = (self._spriteRendererNews or 0) + 1
    end
    if surfaceState == "water" then
      entity.spriteState = "water"
      entity.wildsFollowerWater = true
      self.status.waterSprite = "YES"
      self.status.spriteKind = tostring((meta and meta.kind) or def.kind or "?")
      self.status.activeProvider = self.status.spriteKind
      self.status.lastAction = (how == "unchanged") and "cached" or "to_water"
      if how == "replaced" then
        DebugLog.info(self.mod,
          "Follower water sprite: %s (%s) via %s",
          tostring(species), self.status.spriteKind, tostring(exId))
      end
    else
      entity.spriteState = "land"
      entity.wildsFollowerWater = false
      self.status.waterSprite = "n/a"
      self.status.spriteKind = "land"
      self.status.activeProvider = tostring((meta and (meta.providerId or meta.kind)) or style)
      if how == "unchanged" then
        self.status.lastAction = "cached"
      else
        self.status.lastAction = (prev.requestedStyle ~= style) and "style_land" or "to_land"
        DebugLog.info(self.mod,
          "Follower land sprite: %s style=%s provider=%s",
          tostring(species), tostring(style), self.status.activeProvider)
      end
    end
    remember({
      image = applyDef.image,
      frames = applyDef.frames,
      walker = applyDef.walker == true,
    })
    return how == "replaced"
  end

  if surfaceState == "water" then
    self.status.waterSprite = "unavailable"
    self.status.lastAction = "apply_failed"
  else
    entity.spriteState = "land"
    entity.wildsFollowerWater = false
    self.status.waterSprite = "n/a"
    self.status.spriteKind = "land"
    self.status.activeProvider = "keep_current"
    self.status.lastAction = "to_land_keep"
  end
  -- Remember the desired def so the next tick hits the cache even when
  -- SpriteRenderer is unavailable — never thrash SpriteRenderer.new.
  remember({
    image = applyDef.image,
    frames = applyDef.frames,
    walker = applyDef.walker == true,
  })
  return false
end

function FollowersWaterCompat:tick(game, ow, resolveWaterSprite)
  resolveWaterSprite = resolveWaterSprite or self.resolveWaterSprite
  local ex, exId = findExports(self.mod)
  local wildsApi = wildsFollowerApi(self.mod)
  if not ex and not wildsApi then
    self.status.detected = false
    self.status.surface = "n/a"
    self.status.waterSprite = "n/a"
    self.status.spriteKind = "n/a"
    self.status.activeProvider = "n/a"
    self._activeEntity = nil
    return false
  end

  local player = ow and ow.player
  local inWater = playerInWater(player, game)
  local surfaceState = inWater and "water" or "land"
  local style = Config.spriteStyle(self.mod)
  self.status.surface = surfaceState
  self.status.requestedStyle = style

  local followers = self:collectFollowerEntities(ow)
  if #followers == 0 then
    self.status.detected = false
    self.status.waterSprite = "n/a"
    self.status.spriteKind = "n/a"
    self.status.lastAction = "no_follower"
    self._activeEntity = nil
    self._cache.surfaceState = surfaceState
    self._cache.requestedStyle = style
    return false
  end

  self.status.detected = true
  self._activeEntity = followers[1]
  self._activeEntityId = entityIdentity(followers[1])

  local anyReplaced = false
  local waterYes = 0
  for _, entity in ipairs(followers) do
    local replaced = self:tickEntity(
      game, ow, entity, surfaceState, style, resolveWaterSprite, exId)
    if replaced then anyReplaced = true end
    if entity.wildsFollowerWater == true then waterYes = waterYes + 1 end
  end

  if surfaceState == "water" then
    self.status.waterSprite = (waterYes > 0) and "YES" or self.status.waterSprite
  end
  return anyReplaced
end

function FollowersWaterCompat:hudLines()
  return {
    ("Follower detected: %s"):format(self.status.detected and "YES" or "NO"),
    ("Follower requested style: %s"):format(tostring(self.status.requestedStyle or "?")),
    ("Follower active provider: %s"):format(tostring(self.status.activeProvider or "?")),
    ("Follower surface: %s"):format(tostring(self.status.surface or "?")),
    ("Follower water sprite: %s"):format(tostring(self.status.waterSprite or "?")),
    ("Follower sprite kind: %s"):format(tostring(self.status.spriteKind or "?")),
  }
end

return FollowersWaterCompat
