-- Central land/water sprite resolution for Wilds of Kanto.
--
-- Land: existing SpriteProviders style chains (unchanged).
-- Water: optional provider water API → Wilds swimming/levitates → PokeMMO →
--        Pokedex → black. Never rebuilds rendering; only selects SpriteRenderer defs.
local V = ...
local Config = V.require("config")
local Surface = V.require("surface")
local AnimatedSprites = V.require("animated_sprites")
local Behavior = V.require("behavior")

local SpriteResolver = {}
SpriteResolver.__index = SpriteResolver

------------------------------------------------------------------------
-- Surface state
------------------------------------------------------------------------

local SurfaceState = {}
SpriteResolver.SurfaceState = SurfaceState

function SurfaceState.isWaterEntity(entity, map)
  if not entity then return false end
  if entity.surface == Surface.WATER or entity.surface == "water" then
    return true
  end
  if entity.behaviour == "WATER_IDLE" or entity.behavior == "WATER_IDLE"
     or entity.behaviour == "WATER_WANDER" or entity.behavior == "WATER_WANDER"
     or entity.behaviour == "WATER_AGGRESSIVE" or entity.behavior == "WATER_AGGRESSIVE" then
    return true
  end
  if Behavior and Behavior.isWater and Behavior.isWater(entity.behavior or entity.behaviour) then
    return true
  end
  if map and map.isWaterCell and entity.cellX ~= nil and entity.cellY ~= nil then
    local ok, water = pcall(map.isWaterCell, map, entity.cellX, entity.cellY)
    if ok and water then return true end
  end
  return false
end

function SurfaceState.forEntity(entity, map)
  if SurfaceState.isWaterEntity(entity, map) then
    return "water"
  end
  return "land"
end

------------------------------------------------------------------------
-- Resolver
------------------------------------------------------------------------

function SpriteResolver.new(mod, spriteProviders, waterRegistry)
  local self = setmetatable({}, SpriteResolver)
  self.mod = mod
  self.spriteProviders = spriteProviders
  self.waterRegistry = waterRegistry
  self.cache = {}
  return self
end

local function resolveDex(entity, game, mod)
  if not entity then return nil end
  local dex = entity.enhancedDexId or tonumber(entity.dex)
  if dex and dex >= 1 then return math.floor(dex) end
  return AnimatedSprites.resolveSpeciesId(entity.species, game, mod)
end

local function resolveVariant(entity)
  return AnimatedSprites.resolveRuntimeVariant(entity)
end

local function resolveForm(entity)
  if not entity then return nil end
  local form = entity.spriteForm or entity.formSuffix or entity.form
    or entity.genderForm or entity.gender
  if form == true or form == "female" or form == "f" or form == "F" then
    return "female"
  end
  if form == false or form == "male" or form == "m" or form == "M" then
    return nil
  end
  if type(form) == "number" then
    return tostring(math.floor(form))
  end
  if type(form) == "string" and form ~= "" then
    local s = form:gsub("^_", "")
    if s == "default" or s == "none" or s == "null" then return nil end
    return s
  end
  return nil
end

local function copyResult(result)
  if not result then return nil end
  return {
    def = result.def,
    meta = result.meta,
    providerId = result.providerId,
    fallbackStep = result.fallbackStep,
    steps = result.steps,
    spriteState = result.spriteState,
    spriteKind = result.spriteKind,
    waterOverride = result.waterOverride,
    fallbackReason = result.fallbackReason,
    error = result.error,
  }
end

function SpriteResolver:_tryProviderWater(provider, speciesId, variant, game)
  if not provider then return nil end
  if type(provider.resolveWater) == "function" then
    local ok, def, meta, err = pcall(provider.resolveWater, provider, speciesId, variant, game)
    if ok and def and type(def) == "table" and type(def.image) == "string" then
      return def, meta or {}, nil
    end
    if ok and def == nil then return nil end
  end
  if type(provider.resolveForState) == "function" then
    local ok, def, meta, err = pcall(
      provider.resolveForState, provider, speciesId, variant, "water", game)
    if ok and def and type(def) == "table" and type(def.image) == "string" then
      return def, meta or {}, nil
    end
  end
  return nil
end

function SpriteResolver:resolveLandSprite(entity, context)
  context = context or {}
  local style = context.style or Config.spriteStyle(self.mod)
  local game = context.game
  local species = (entity and (entity.species or entity.enhancedDexId)) or context.speciesId
  local variant = context.variant or resolveVariant(entity)
  if not self.spriteProviders then
    return nil
  end
  local result = self.spriteProviders:resolve(style, species, variant, game)
  if result then
    result.spriteState = "land"
    result.spriteKind = result.providerId
    result.waterOverride = false
  end
  return result
end

function SpriteResolver:resolveWaterSprite(entity, context)
  context = context or {}
  local style = context.style or Config.spriteStyle(self.mod)
  local game = context.game
  local speciesId = context.speciesId or resolveDex(entity, game, self.mod)
  local variant = context.variant or resolveVariant(entity)
  local form = context.form or resolveForm(entity)
  local steps = {}
  local fallbackStep = 0

  -- 1) Optional water support on the selected style's provider chain.
  if self.spriteProviders then
    local chain = self.spriteProviders:chainForStyle(style)
    for _, providerId in ipairs(chain) do
      fallbackStep = fallbackStep + 1
      local provider = self.spriteProviders.providers[providerId]
      if provider then
        local avail = true
        if provider.isAvailable then
          avail = select(1, provider:isAvailable(game))
        end
        if avail then
          local def, meta = self:_tryProviderWater(provider, speciesId or entity and entity.species, variant, game)
          if def then
            meta = meta or {}
            meta.providerId = providerId
            meta.requestedStyle = style
            meta.fallbackStep = fallbackStep
            meta.usedVariant = meta.usedVariant or variant
            meta.bodyRenderer = "NATIVE_SPRITE_RENDERER"
            meta.waterSource = "provider"
            meta.loadPath = def.image
            local result = {
              def = def,
              meta = meta,
              providerId = providerId,
              fallbackStep = fallbackStep,
              steps = steps,
              spriteState = "water",
              spriteKind = providerId,
              waterOverride = false,
            }
            steps[#steps + 1] = { providerId = providerId, ok = true, water = true }
            return result
          end
          steps[#steps + 1] = {
            providerId = providerId, ok = false, reason = "no water sprite",
          }
        end
      end
    end
  end

  -- 2–3) Wilds swimming / levitates registry.
  if self.waterRegistry and self.waterRegistry.ready then
    fallbackStep = fallbackStep + 1
    local preferred = self.waterRegistry:preferredKindFor(speciesId)
    local waterDef, waterErr = self.waterRegistry:resolve(
      speciesId, variant, preferred, form)
    if waterDef then
      local meta = {
        providerId = "water_" .. waterDef.kind,
        requestedStyle = style,
        fallbackStep = fallbackStep,
        usedVariant = waterDef.variant,
        loadPath = waterDef.image,
        relativePath = waterDef.relativePath,
        bodyRenderer = "NATIVE_SPRITE_RENDERER",
        waterSource = "wilds",
        waterKind = waterDef.kind,
        form = waterDef.formKey,
        frames = waterDef.frames,
        walker = true,
      }
      local result = {
        def = {
          image = waterDef.image,
          frames = waterDef.frames,
          walker = true,
          trueColor = true,
          id = waterDef.id,
        },
        meta = meta,
        providerId = "water_" .. waterDef.kind,
        fallbackStep = fallbackStep,
        steps = steps,
        spriteState = "water",
        spriteKind = waterDef.kind,
        waterOverride = true,
      }
      steps[#steps + 1] = { providerId = result.providerId, ok = true, kind = waterDef.kind }
      return result
    end
    steps[#steps + 1] = {
      providerId = "water_registry", ok = false, reason = waterErr or "unavailable",
    }
  end

  -- 4–6) Built-in PokeMMO → Pokedex → black (ignore gold/followers land art).
  if self.spriteProviders then
    local landFallback = self.spriteProviders:resolve("pokemmo", speciesId or (entity and entity.species), variant, game)
    if landFallback then
      landFallback.spriteState = "water"
      landFallback.spriteKind = landFallback.providerId == "pokemmo"
        and "pokemmo" or landFallback.providerId
      landFallback.waterOverride = true
      landFallback.fallbackReason = "no swimming or levitates asset"
      if landFallback.providerId == "pokemmo" then
        landFallback.spriteKind = "pokemmo"
      end
      return landFallback
    end
  end

  return {
    def = nil,
    meta = {},
    providerId = "black",
    fallbackStep = fallbackStep + 1,
    steps = steps,
    spriteState = "water",
    spriteKind = "black",
    waterOverride = true,
    fallbackReason = "no swimming or levitates asset",
    error = "all water resolvers failed",
  }
end

function SpriteResolver:resolveForEntity(entity, context)
  context = context or {}
  local map = context.map
  local state = context.surface
  if state == Surface.WATER or state == "WATER" then
    state = "water"
  elseif state == "LAND" or state == "land" then
    state = "land"
  elseif state == nil or state == true then
    state = SurfaceState.forEntity(entity, map)
  else
    -- Treat other Surface.* values (GRASS/CAVE/…) as land for sprite purposes.
    if state == Surface.GRASS or state == Surface.CAVE
       or state == Surface.INTERIOR or state == Surface.OTHER then
      state = "land"
    elseif SurfaceState.isWaterEntity(
      { surface = state, behavior = entity and entity.behavior, cellX = entity and entity.cellX, cellY = entity and entity.cellY },
      map
    ) then
      state = "water"
    else
      state = "land"
    end
  end

  if state == "water" then
    return self:resolveWaterSprite(entity, context)
  end
  return self:resolveLandSprite(entity, context)
end

function SpriteResolver:applyEntityMeta(entity, result)
  if not entity or not result then return end
  entity.spriteState = result.spriteState or entity.spriteState
  entity.spriteKind = result.spriteKind or entity.spriteKind
  if result.meta and result.meta.usedVariant then
    entity.spriteVariant = result.meta.usedVariant
  end
  if result.meta and result.meta.relativePath then
    entity.spriteSourcePath = result.meta.relativePath
  elseif result.def and result.def.image then
    entity.spriteSourcePath = result.def.image
  end
  entity.waterOverride = result.waterOverride == true
  entity.waterFallbackReason = result.fallbackReason
  if result.meta and result.meta.form then
    entity.spriteFormKey = result.meta.form
  end
end

return SpriteResolver
