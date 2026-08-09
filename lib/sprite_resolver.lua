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
  local WaterDisplay = V.require("water_display")
  local WaterShadowRenderer = V.require("water_shadow_renderer")
  local wantSilhouette = context.nativeSilhouette == true
    or (context.voxelActive == true and WaterDisplay.isSilhouettes(self.mod))
  local wantHiddenShadow = context.nativeHiddenShadow == true
    or (context.voxelActive == true and WaterDisplay.isHiddenSilhouettes(self.mod))

  -- Voxel Hidden Silhouettes: generic flat underwater shadow marker.
  -- Flat 2D Hidden keeps the procedural circle (Entity:draw) and never asks
  -- for this sheet.
  if wantHiddenShadow then
    fallbackStep = fallbackStep + 1
    local def = WaterShadowRenderer.hiddenDef(self.mod)
    local meta = {
      providerId = "water_hidden_shadow",
      requestedStyle = style,
      fallbackStep = fallbackStep,
      usedVariant = variant,
      loadPath = def.image,
      relativePath = WaterShadowRenderer.HIDDEN_RELATIVE,
      bodyRenderer = "NATIVE_SPRITE_RENDERER",
      waterSource = "hidden_shadow",
      frames = 6,
      walker = true,
      waterDisplayMode = (type(Config.waterDisplayMode) == "function"
        and Config.waterDisplayMode(self.mod)) or "hidden_silhouettes",
      voxelActive = true,
      shadowRendererMode = WaterShadowRenderer.MODE.FLAT_WORLD,
      waterFlatShadow = true,
      waterShadowKind = "hidden",
    }
    local result = {
      def = def,
      meta = meta,
      providerId = "water_hidden_shadow",
      fallbackStep = fallbackStep,
      steps = steps,
      spriteState = "water",
      spriteKind = "hidden_shadow",
      waterOverride = true,
      waterHiddenShadow = true,
      waterFlatShadow = true,
      shadowRendererMode = WaterShadowRenderer.MODE.FLAT_WORLD,
    }
    steps[#steps + 1] = { providerId = "water_hidden_shadow", ok = true }
    return result
  end

  -- 1) Direct poke_followers submerged check (fsExists, no mod:read).
  -- Only applies when the GSC/Followers sprite style is selected; otherwise
  -- falls through to the provider chain + swimming/levitates registry so
  -- the user's chosen style (e.g. HGSS) is respected.
  local useGscSubmerged = false
  if Config and type(Config.normalizeSpriteStyle) == "function" then
    useGscSubmerged = Config.normalizeSpriteStyle(style) == "followers"
  else
    useGscSubmerged = style == "followers"
  end
  if useGscSubmerged and not wantSilhouette and not wantHiddenShadow then
    local dex = speciesId
    if type(dex) ~= "number" then
      local AS
      pcall(function() AS = V.require("animated_sprites") end)
      if AS and AS.resolveSpeciesId then
        dex = AS.resolveSpeciesId(tostring(dex), game, self.mod)
      end
    end
    if dex and type(dex) == "number" then
      local redpp = Config and type(Config.paletteFxRedpp) == "function"
        and Config.paletteFxRedpp()
      local tryVariants
      if redpp then
        if variant == "shiny" then
          tryVariants = { "shiny_submerged", "normal_submerged" }
        else
          tryVariants = { "normal_submerged" }
        end
      else
        tryVariants = { "grayscale_submerged" }
      end
      for _, v in ipairs(tryVariants) do
        local rel = string.format(
          "assets/enhanced_overworld/poke_followers/follower_%03d_%s.png",
          dex, v)
        local loadPath = rel
        if self.mod and self.mod.assets and self.mod.assets.path then
          local ok, p = pcall(function() return self.mod.assets:path(rel) end)
          if ok and type(p) == "string" then loadPath = p end
        end
        if (love and love.filesystem and love.filesystem.getInfo
            and love.filesystem.getInfo(loadPath))
           or (love and love.filesystem and love.filesystem.getInfo
               and love.filesystem.getInfo(rel)) then
          local def = {
            image = loadPath,
            frames = 6,
            walker = true,
            trueColor = true,
            id = "SPRITE_OW_WILD_SUBMERGED_" .. tostring(dex),
          }
          local meta = {
            providerId = "poke_followers_submerged",
            requestedStyle = style,
            fallbackStep = 1,
            usedVariant = v,
            loadPath = loadPath,
            relativePath = rel,
            bodyRenderer = "NATIVE_SPRITE_RENDERER",
            waterSource = "poke_followers_submerged",
            kind = "submerged",
            frames = 6,
            walker = true,
          }
          steps[#steps + 1] = { providerId = "poke_followers_submerged", ok = true }
          return { def = def, meta = meta, providerId = "poke_followers_submerged",
            fallbackStep = 1, steps = steps, spriteState = "water",
            spriteKind = "submerged" }
        end
      end
    end
  end

  -- 2) Provider water (skip when Voxel silhouettes need Wilds silhouette sheets).
  if not wantSilhouette and self.spriteProviders then
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
  elseif wantSilhouette then
    steps[#steps + 1] = {
      providerId = "provider_water", ok = false,
      reason = "skipped for native silhouette sheets",
    }
  end

  -- 2–3) Wilds swimming / levitates registry.
  -- Voxel silhouettes: native pre-rendered silhouette sheets (same kind order).
  -- Flat silhouettes keep colour sheets + runtime tint (handled at draw).
  if self.waterRegistry and self.waterRegistry.ready then
    fallbackStep = fallbackStep + 1
    local preferred = self.waterRegistry:preferredKindFor(speciesId)
    local waterDef, waterErr = self.waterRegistry:resolve(
      speciesId, variant, preferred, form, { silhouette = wantSilhouette })
    if waterDef then
      local providerTag = "water_" .. waterDef.kind
      if waterDef.silhouette then
        providerTag = providerTag .. "_silhouette"
      end
      local shadowMode = WaterShadowRenderer.MODE.NONE
      if waterDef.silhouette and context.voxelActive == true then
        shadowMode = WaterShadowRenderer.MODE.FLAT_WORLD
      end
      local meta = {
        providerId = providerTag,
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
        silhouette = waterDef.silhouette == true,
        silhouetteFallback = waterDef.silhouetteFallback == true,
        waterDisplayMode = (type(Config.waterDisplayMode) == "function"
          and Config.waterDisplayMode(self.mod)) or "swimming_sprites",
        voxelActive = context.voxelActive == true,
        shadowRendererMode = shadowMode,
        waterFlatShadow = waterDef.silhouette == true and context.voxelActive == true,
        waterShadowKind = waterDef.silhouette and "silhouette" or nil,
      }
      local def = {
        image = waterDef.image,
        frames = waterDef.frames,
        walker = true,
        trueColor = true,
        id = waterDef.id,
      }
      if meta.waterFlatShadow then
        WaterShadowRenderer.tagDef(def, "silhouette")
      end
      local result = {
        def = def,
        meta = meta,
        providerId = providerTag,
        fallbackStep = fallbackStep,
        steps = steps,
        spriteState = "water",
        spriteKind = waterDef.kind,
        waterOverride = true,
        waterSilhouetteSheet = waterDef.silhouette == true,
        waterFlatShadow = meta.waterFlatShadow == true,
        shadowRendererMode = shadowMode,
      }
      steps[#steps + 1] = {
        providerId = result.providerId, ok = true, kind = waterDef.kind,
        silhouette = waterDef.silhouette == true,
      }
      return result
    end
    steps[#steps + 1] = {
      providerId = "water_registry", ok = false, reason = waterErr or "unavailable",
    }
  end

  -- 4–6) Built-in PokeMMO → Pokedex → black (ignore gold/followers land art).
  -- Never used as a Voxel silhouette primary path when Wilds water exists.
  if self.spriteProviders then
    local landFallback = self.spriteProviders:resolve("pokemmo", speciesId or (entity and entity.species), variant, game)
    if landFallback then
      landFallback.spriteState = "water"
      landFallback.spriteKind = landFallback.providerId == "pokemmo"
        and "pokemmo" or landFallback.providerId
      landFallback.waterOverride = true
      landFallback.fallbackReason = wantSilhouette
        and "no swimming/levitates silhouette asset"
        or "no swimming or levitates asset"
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

function SpriteResolver:cacheKey(entity, context, state)
  context = context or {}
  local style = tostring(context.style or Config.spriteStyle(self.mod) or "pokemmo")
  local speciesId = context.speciesId or resolveDex(entity, context.game, self.mod)
    or (entity and (entity.species or entity.enhancedDexId)) or "?"
  local variant = tostring(context.variant or resolveVariant(entity) or "normal")
  local form = tostring(context.form or resolveForm(entity) or "default")
  state = state or "land"
  local waterMode = "na"
  local voxel = "flat"
  local shadowMode = "none"
  local imagePath = "na"
  if state == "water" then
    if type(Config.waterDisplayMode) == "function" then
      waterMode = tostring(Config.waterDisplayMode(self.mod) or "swimming_sprites")
    else
      waterMode = "swimming_sprites"
    end
    if context.voxelActive == true then
      voxel = "voxel"
      local WaterShadowRenderer = V.require("water_shadow_renderer")
      if waterMode == "hidden_silhouettes" then
        shadowMode = WaterShadowRenderer.MODE.FLAT_WORLD
        imagePath = WaterShadowRenderer.HIDDEN_RELATIVE
      elseif waterMode == "silhouettes" then
        shadowMode = WaterShadowRenderer.MODE.FLAT_WORLD
        imagePath = "silhouette"
      end
    end
  end
  return string.format("%s:%s:%s:%s:%s:%s:%s:%s:%s",
    tostring(speciesId), variant, form, state, style, waterMode, voxel,
    shadowMode, imagePath)
end

function SpriteResolver:invalidateCache()
  self.cache = {}
  if self.waterRegistry and self.waterRegistry.invalidateCache then
    pcall(self.waterRegistry.invalidateCache, self.waterRegistry)
  end
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

  local style = context.style or Config.spriteStyle(self.mod)
  context.style = style
  if entity then
    entity.requestedSpriteStyle = style
  end

  local key = self:cacheKey(entity, context, state)
  local cached = self.cache[key]
  if cached ~= nil then
    local result = copyResult(cached)
    if entity and result then
      self:applyEntityMeta(entity, result)
    end
    return result
  end

  local result
  if state == "water" then
    result = self:resolveWaterSprite(entity, context)
  else
    result = self:resolveLandSprite(entity, context)
  end

  -- Hard rule: explicit PokeMMO on land never resolves Followers EX.
  if result and style == "pokemmo" and state == "land"
     and result.providerId == "followers_ex" then
    result = self.spriteProviders and self.spriteProviders:resolve(
      "pokemmo",
      context.speciesId or (entity and (entity.species or entity.enhancedDexId)),
      context.variant or resolveVariant(entity),
      context.game)
    if result then
      result.spriteState = "land"
      result.spriteKind = result.providerId
      result.waterOverride = false
      result.fallbackReason = "rejected followers_ex for explicit pokemmo"
    end
  end

  if result then
    self.cache[key] = copyResult(result)
  end
  return result
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
