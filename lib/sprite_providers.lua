-- Sprite source providers for Wilds of Kanto overworld Pokemon.
--
-- Architecture: swap SpriteRenderer definitions only. Rendering stays native
-- (frames/walker/pose → Gen1Recomp / Dramatic Shape). No overlay bodies.
--
-- Built-in IDs: followers_ex, pokemmo, pokedex (+ internal black fallback).
-- External mods may register via mod.exports.registerSpriteProvider after
-- Wilds loads (Followers EX priority 160 loads after Wilds priority 80).
local V = ...
local Config = V.require("config")
local RuntimeSheets = V.require("runtime_sheets")
local AnimatedSprites = V.require("animated_sprites")
local DebugLog = V.require("debug_log")

local SpriteProviders = {}
SpriteProviders.__index = SpriteProviders

SpriteProviders.ID = {
  FOLLOWERS_EX = "followers_ex",
  POKEMMO = "pokemmo",
  POKEDEX = "pokedex",
  BLACK = "black",
}

SpriteProviders.STYLE = {
  AUTO = "auto",
  FOLLOWERS_EX = "followers_ex",
  POKEMMO = "pokemmo",
  POKEDEX = "pokedex",
}

-- Explicit style → try order (before black). Auto matches followers→pokemmo→pokedex.
local STYLE_CHAINS = {
  auto = { "followers_ex", "pokemmo", "pokedex" },
  followers_ex = { "followers_ex", "pokemmo", "pokedex" },
  pokemmo = { "pokemmo", "pokedex" },
  pokedex = { "pokedex" },
}

local VALID_STYLES = {
  auto = true,
  followers_ex = true,
  pokemmo = true,
  pokedex = true,
}

local FOLLOWERS_MOD_ID = "FOLLOWERS_EX"
local POKEPC_MOD_ID = "PokePCFollowers_VoxelMerge"
local PROBE_SPECIES = "CHARMANDER"
local PROBE_REL = "assets/sprites/follower_" .. PROBE_SPECIES .. ".png"

local function fsExists(path)
  if type(path) ~= "string" or path == "" then return false end
  local fs = love and love.filesystem
  if fs and fs.getInfo then
    local ok, info = pcall(fs.getInfo, path)
    if ok and info then return true end
  end
  return false
end

local function normalizeVariant(variant)
  return AnimatedSprites.normalizeVariant(variant)
end

local function copyDef(def, spriteId)
  if type(def) ~= "table" or type(def.image) ~= "string" or def.image == "" then
    return nil
  end
  local out = {
    image = def.image,
    frames = tonumber(def.frames) or 1,
    trueColor = def.trueColor ~= false,
    id = spriteId or def.id,
  }
  if def.walker then out.walker = true end
  if def.pokepcShiny then out.pokepcShiny = true end
  return out
end

local function speciesKeyFromId(speciesId, game, mod)
  if type(speciesId) == "string" and speciesId ~= "" and not tonumber(speciesId) then
    return speciesId
  end
  local dex = tonumber(speciesId)
  if not dex then
    dex = AnimatedSprites.resolveSpeciesId(speciesId, game, mod)
  end
  if not dex then return nil end
  dex = math.floor(dex)
  local pokemon = game and game.data and game.data.pokemon
  if type(pokemon) == "table" then
    for key, def in pairs(pokemon) do
      if type(key) == "string" and def and tonumber(def.dex) == dex then
        return key
      end
    end
  end
  if mod and mod.content and mod.content.pokemon and mod.content.pokemon.each then
    for key, def in mod.content.pokemon:each() do
      if type(key) == "string" and def and tonumber(def.dex) == dex then
        return key
      end
    end
  end
  return nil
end

local function resolveDexId(speciesId, game, mod)
  local n = tonumber(speciesId)
  if n and n >= 1 and math.floor(n) == n then
    return math.floor(n)
  end
  return AnimatedSprites.resolveSpeciesId(speciesId, game, mod)
end

------------------------------------------------------------------------
-- Registry
------------------------------------------------------------------------

function SpriteProviders.new(mod, render)
  local self = setmetatable({}, SpriteProviders)
  self.mod = mod
  self.render = render
  self.providers = {}
  self.finalized = false
  self.lastResolve = nil
  self:_registerBuiltins()
  return self
end

function SpriteProviders:_registerBuiltins()
  self:register(self:_makePokemmoProvider())
  self:register(self:_makePokedexProvider())
  self:register(self:_makeBlackProvider())
  -- Followers adapter is registered now and re-probed at finalize / resolve.
  self:register(self:_makeFollowersExProvider())
end

function SpriteProviders:register(provider)
  if type(provider) ~= "table" or type(provider.id) ~= "string" or provider.id == "" then
    return false, "invalid provider"
  end
  if type(provider.isAvailable) ~= "function" or type(provider.resolve) ~= "function" then
    return false, "provider must implement isAvailable and resolve"
  end
  -- Do not mutate content registries; runtime resolvers only.
  self.providers[provider.id] = provider
  return true
end

function SpriteProviders:unregister(id)
  if type(id) ~= "string" or id == "" then return false end
  if id == SpriteProviders.ID.POKEMMO
     or id == SpriteProviders.ID.POKEDEX
     or id == SpriteProviders.ID.BLACK then
    return false, "cannot unregister built-in provider"
  end
  if self.providers[id] == nil then return false end
  self.providers[id] = nil
  return true
end

function SpriteProviders:get(id)
  if type(id) ~= "string" then return nil end
  return self.providers[id]
end

function SpriteProviders:list()
  local out = {}
  for id, provider in pairs(self.providers) do
    out[#out + 1] = {
      id = id,
      available = select(1, provider:isAvailable(nil)) == true,
      reason = select(2, provider:isAvailable(nil)),
      builtin = provider.builtin == true,
      modId = provider.modId,
    }
  end
  table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return out
end

function SpriteProviders:finalize(game)
  self.finalized = true
  local followers = self.providers[SpriteProviders.ID.FOLLOWERS_EX]
  if followers and type(followers.refreshAvailability) == "function" then
    pcall(followers.refreshAvailability, followers, game)
  end
  if Config.debug(self.mod) then
    local ok, reason = false, "missing"
    if followers then
      ok, reason = followers:isAvailable(game)
    end
    DebugLog.info(self.mod,
      "sprite providers finalized; followers_ex available=%s (%s)",
      tostring(ok), tostring(reason))
  end
end

------------------------------------------------------------------------
-- Built-in: PokeMMO (Wilds runtime 16×96 sheets)
------------------------------------------------------------------------

function SpriteProviders:_makePokemmoProvider()
  local render = self.render
  local mod = self.mod
  return {
    id = SpriteProviders.ID.POKEMMO,
    builtin = true,
    modId = mod and mod.id or "overworld_wild_spawns",
    isAvailable = function(_self, _game)
      local sheets = render and render.runtimeSheets
      if sheets and not sheets.ready and sheets.load then
        pcall(function() sheets:load() end)
      end
      if sheets and sheets:isReady() then
        return true, "runtime sheets ready"
      end
      return false, sheets and sheets.loadError or "runtime sheets unavailable"
    end,
    resolve = function(_self, speciesId, variant, game)
      local sheets = render and render.runtimeSheets
      if not sheets then
        return nil, nil, "no runtime sheets"
      end
      if not sheets.ready and sheets.load then
        pcall(function() sheets:load() end)
      end
      local dex = resolveDexId(speciesId, game, mod)
      if not dex then
        return nil, nil, "dex unresolved"
      end
      local want = normalizeVariant(variant)
      local def, usedVariant, loadPath, rel = sheets:spriteDef(dex, want)
      if not def then
        return nil, nil, "no pokemmo sheet for dex " .. tostring(dex)
      end
      -- Prefer mod.assets:path when render helper exists.
      if rel and render and render._modAssetPath then
        local via = render:_modAssetPath(rel)
        if via then
          def.image = via
          loadPath = via
        end
      end
      local meta = {
        providerId = SpriteProviders.ID.POKEMMO,
        usedVariant = usedVariant or want,
        relativePath = rel,
        loadPath = loadPath or def.image,
        frames = def.frames,
        walker = def.walker == true,
        bodyRenderer = "NATIVE_SPRITE_RENDERER",
      }
      return def, meta, nil
    end,
  }
end

------------------------------------------------------------------------
-- Built-in: Pokedex / battle-front (1-frame SpriteRenderer)
------------------------------------------------------------------------

function SpriteProviders:_makePokedexProvider()
  local render = self.render
  local mod = self.mod
  return {
    id = SpriteProviders.ID.POKEDEX,
    builtin = true,
    modId = mod and mod.id or "overworld_wild_spawns",
    isAvailable = function()
      return true, "pokedex / battle-front resolver"
    end,
    resolve = function(_self, speciesId, variant, game)
      local speciesKey = speciesKeyFromId(speciesId, game, mod)
        or (type(speciesId) == "string" and speciesId)
      if not speciesKey then
        return nil, nil, "species key unresolved"
      end

      local imagePath = nil
      local kind = nil

      -- Prefer already-registered content sprite when it is a 1-frame / battle front.
      local reg = render and render.registrationInfo and render.registrationInfo[speciesKey]
      if reg and type(reg.image) == "string" and reg.image ~= ""
         and reg.kind ~= "native_runtime_sheet" then
        imagePath = reg.image
        kind = reg.kind or "registered"
      end

      if not imagePath and render and render.resolveAsset then
        local resolved = render:resolveAsset(speciesKey, game)
        if resolved and type(resolved.path) == "string" and resolved.path ~= "" then
          imagePath = resolved.path
          kind = resolved.source or "resolved"
        end
      end

      if not imagePath then
        local mon = game and game.data and game.data.pokemon and game.data.pokemon[speciesKey]
        if not mon and mod and mod.content and mod.content.pokemon then
          mon = mod.content.pokemon:get(speciesKey)
        end
        local front = mon and mon.spriteFront
        if type(front) == "string" and front ~= "" then
          imagePath = front
          kind = "battle_front"
        end
      end

      if not imagePath then
        return nil, nil, "no pokedex image for " .. tostring(speciesKey)
      end

      local def = {
        image = imagePath,
        frames = 1,
        trueColor = true,
        id = "SPRITE_OW_WILD_" .. tostring(speciesKey),
      }
      local meta = {
        providerId = SpriteProviders.ID.POKEDEX,
        usedVariant = "normal",
        loadPath = imagePath,
        frames = 1,
        walker = false,
        kind = kind,
        bodyRenderer = "NATIVE_SPRITE_RENDERER",
        requestedVariant = normalizeVariant(variant),
      }
      return def, meta, nil
    end,
  }
end

------------------------------------------------------------------------
-- Built-in: black fallback
------------------------------------------------------------------------

function SpriteProviders:_makeBlackProvider()
  local render = self.render
  local mod = self.mod
  return {
    id = SpriteProviders.ID.BLACK,
    builtin = true,
    modId = mod and mod.id or "overworld_wild_spawns",
    isAvailable = function()
      return true, "black fallback"
    end,
    resolve = function(_self, speciesId, _variant, _game)
      local path = render and (render.fallbackPath or (render._fallbackPath and render:_fallbackPath()))
      if type(path) ~= "string" or path == "" then
        path = (mod and mod.assets and mod.assets.path
                and mod.assets:path("assets/fallback/pokemon_missing.png"))
            or "assets/fallback/pokemon_missing.png"
      end
      local def = {
        image = path,
        frames = 1,
        trueColor = true,
        id = render and render.fallbackId or "SPRITE_OW_WILD_FALLBACK",
      }
      local meta = {
        providerId = SpriteProviders.ID.BLACK,
        usedVariant = "normal",
        loadPath = path,
        frames = 1,
        walker = false,
        bodyRenderer = "NATIVE_SPRITE_RENDERER",
        fallback = true,
      }
      return def, meta, nil
    end,
  }
end

------------------------------------------------------------------------
-- Followers EX / PokePC read-only adapter
--
-- Real API (Followers EX 1.0.19 / ControlEngine):
--   * Assets live in PokePCFollowers_VoxelMerge: assets/sprites/follower_<SPECIES>.png
--   * FOLLOWERS_EX depends on PokePC + overworld_wild_spawns (no public resolveSprite)
--   * ControlEngine discovers root via SPRITE_PIKACHU.image or mods/<id>/...
--   * SpriteRenderer def: { image, frames=6, walker=true, trueColor=true }
--   * Optional SHINY_POKEMON.exports.bakeFollowerOwSheet(path, species)
--
-- We never scan private tables; we only use documented paths + content defs.
------------------------------------------------------------------------

function SpriteProviders:_discoverPokepcRoot(game)
  local mod = self.mod

  -- A) Content registry: Followers EX patches SPRITE_PIKACHU.image to a pack path.
  local function rootFromImage(img)
    if type(img) ~= "string" then return nil end
    local root = img:match("^(.-)/assets/sprites/")
    if root and fsExists(root .. "/" .. PROBE_REL) then
      return root
    end
    return nil
  end

  local function spriteImage(id)
    if game and game.data and game.data.sprites and game.data.sprites[id] then
      return game.data.sprites[id].image
    end
    if mod and mod.content and mod.content.sprites and mod.content.sprites.get then
      local def = mod.content.sprites:get(id)
      return def and def.image
    end
    return nil
  end

  local fromPikachu = rootFromImage(spriteImage("SPRITE_PIKACHU"))
  if fromPikachu then return fromPikachu, "SPRITE_PIKACHU" end

  -- B) Public mod:find — path may be absent (find returns {id,version,exports}).
  local function tryMod(id)
    if not (mod and mod.find) then return nil end
    local hit = mod:find(id)
    if not hit then return nil end
    if type(hit.path) == "string" and fsExists(hit.path .. "/" .. PROBE_REL) then
      return hit.path
    end
    -- Documented love.filesystem install locations (same as Followers EX).
    return nil
  end

  local fromPokepc = tryMod(POKEPC_MOD_ID)
  if fromPokepc then return fromPokepc, POKEPC_MOD_ID end

  for _, root in ipairs({
    "mods/PokePCFollowers_VoxelMerge",
    "mods/PokePCFollowers-main",
    "mods/PokePCFollowers",
  }) do
    if fsExists(root .. "/" .. PROBE_REL) then
      return root, root
    end
  end

  -- C) Optional export from Followers EX / PokePC if a future provider API appears.
  local function tryExportResolve()
    if not (mod and mod.find) then return nil end
    for _, id in ipairs({ FOLLOWERS_MOD_ID, POKEPC_MOD_ID }) do
      local hit = mod:find(id)
      local ex = hit and hit.exports
      if ex then
        if type(ex.resolveFollowerSprite) == "function" then
          return "export:" .. id, id, ex
        end
        if type(ex.getFollowerSpritePath) == "function" then
          return "export:" .. id, id, ex
        end
        if type(ex.registerSpriteProvider) == "function" then
          -- External already uses our API; root discovery not needed.
          return nil
        end
      end
    end
    return nil
  end

  local exportRoot, exportId, exportApi = tryExportResolve()
  if exportApi then
    return exportRoot, exportId, exportApi
  end

  return nil, nil, nil
end

function SpriteProviders:_makeFollowersExProvider()
  local mod = self.mod
  local state = {
    root = nil,
    source = nil,
    exportApi = nil,
    probed = false,
  }

  local owners = self
  local provider = {
    id = SpriteProviders.ID.FOLLOWERS_EX,
    builtin = true, -- built-in adapter; external may override via register
    modId = POKEPC_MOD_ID,
    _state = state,
  }

  function provider:refreshAvailability(game)
    state.probed = true
    local root, source, exportApi = owners:_discoverPokepcRoot(game)
    state.root, state.source, state.exportApi = root, source, exportApi
    return state.root ~= nil or state.exportApi ~= nil
  end

  function provider:isAvailable(game)
    if not state.probed or (state.root == nil and state.exportApi == nil) then
      self:refreshAvailability(game)
    end
    if state.exportApi then
      return true, "followers export API (" .. tostring(state.source) .. ")"
    end
    if state.root and fsExists(state.root .. "/" .. PROBE_REL) then
      return true, "PokePC walker sheets at " .. tostring(state.root)
    end
    -- Installed Followers EX without resolvable sheets is NOT available.
    if mod and mod.find and mod:find(FOLLOWERS_MOD_ID) and not state.root then
      return false, "FOLLOWERS_EX installed but sprite pack unresolved"
    end
    return false, "Followers EX / PokePC sprite provider not available"
  end

  function provider:resolve(speciesId, variant, game)
    local okAvail, why = self:isAvailable(game)
    if not okAvail then
      return nil, nil, why
    end

    local speciesKey = speciesKeyFromId(speciesId, game, mod)
    if not speciesKey and type(speciesId) == "string" and not tonumber(speciesId) then
      speciesKey = speciesId
    end
    if not speciesKey then
      return nil, nil, "species key unresolved for followers path"
    end

    local wantShiny = normalizeVariant(variant) == "shiny"

    -- Future / optional public export API.
    if state.exportApi then
      local api = state.exportApi
      if type(api.resolveFollowerSprite) == "function" then
        local ok, defOrPath, meta = pcall(api.resolveFollowerSprite, speciesKey, variant, game)
        if ok and type(defOrPath) == "table" and defOrPath.image then
          local def = copyDef(defOrPath, "SPRITE_OW_WILD_" .. tostring(speciesKey))
          def.frames = def.frames or 6
          def.walker = def.walker ~= false
          def.trueColor = true
          return def, {
            providerId = SpriteProviders.ID.FOLLOWERS_EX,
            usedVariant = (meta and meta.usedVariant) or (wantShiny and "shiny" or "normal"),
            loadPath = def.image,
            frames = def.frames,
            walker = true,
            bodyRenderer = "NATIVE_SPRITE_RENDERER",
            providerMod = state.source or POKEPC_MOD_ID,
          }, nil
        elseif ok and type(defOrPath) == "string" and defOrPath ~= "" then
          if fsExists(defOrPath) then
            local def = {
              image = defOrPath, frames = 6, walker = true, trueColor = true,
              id = "SPRITE_OW_WILD_" .. tostring(speciesKey),
            }
            return def, {
              providerId = SpriteProviders.ID.FOLLOWERS_EX,
              usedVariant = wantShiny and "shiny" or "normal",
              loadPath = defOrPath,
              frames = 6, walker = true,
              bodyRenderer = "NATIVE_SPRITE_RENDERER",
              providerMod = state.source or POKEPC_MOD_ID,
            }, nil
          end
        end
      end
      if type(api.getFollowerSpritePath) == "function" then
        local ok, path = pcall(api.getFollowerSpritePath, speciesKey, variant)
        if ok and type(path) == "string" and fsExists(path) then
          local def = {
            image = path, frames = 6, walker = true, trueColor = true,
            id = "SPRITE_OW_WILD_" .. tostring(speciesKey),
          }
          return def, {
            providerId = SpriteProviders.ID.FOLLOWERS_EX,
            usedVariant = wantShiny and "shiny" or "normal",
            loadPath = path, frames = 6, walker = true,
            bodyRenderer = "NATIVE_SPRITE_RENDERER",
            providerMod = state.source or POKEPC_MOD_ID,
          }, nil
        end
      end
    end

    if not state.root then
      return nil, nil, "no PokePC asset root"
    end

    local path = state.root .. "/assets/sprites/follower_" .. tostring(speciesKey) .. ".png"
    if not fsExists(path) then
      return nil, nil, "missing follower sheet: " .. path
    end

    local usedVariant = "normal"
    local imagePath = path
    if wantShiny and mod and mod.find then
      local shinyMod = mod:find("SHINY_POKEMON")
      local bake = shinyMod and shinyMod.exports and shinyMod.exports.bakeFollowerOwSheet
      if type(bake) == "function" then
        local ok, baked = pcall(bake, path, speciesKey)
        -- bakeFollowerOwSheet returns an Image, not a path — cannot feed SpriteRenderer.
        -- Only accept string paths from future APIs; otherwise fall through to normal.
        if ok and type(baked) == "string" and baked ~= "" and fsExists(baked) then
          imagePath = baked
          usedVariant = "shiny"
        else
          -- Requested shiny unavailable as a sheet path → signal caller to try normal.
          return nil, nil, "followers shiny sheet path unavailable"
        end
      else
        return nil, nil, "followers shiny unavailable"
      end
    end

    local def = {
      image = imagePath,
      frames = 6,
      walker = true,
      trueColor = true,
      id = "SPRITE_OW_WILD_" .. tostring(speciesKey),
    }
    if usedVariant == "shiny" then
      def.pokepcShiny = true
    end
    local meta = {
      providerId = SpriteProviders.ID.FOLLOWERS_EX,
      usedVariant = usedVariant,
      loadPath = imagePath,
      frames = 6,
      walker = true,
      bodyRenderer = "NATIVE_SPRITE_RENDERER",
      providerMod = state.source or POKEPC_MOD_ID,
    }
    return def, meta, nil
  end

  return provider
end

------------------------------------------------------------------------
-- Resolution with style chains + shiny fallback
------------------------------------------------------------------------

function SpriteProviders:chainForStyle(style)
  style = tostring(style or "auto")
  if not VALID_STYLES[style] then style = "auto" end
  return STYLE_CHAINS[style] or STYLE_CHAINS.auto
end

function SpriteProviders:providerAvailable(id, game)
  local p = self.providers[id]
  if not p then return false, "provider missing" end
  local ok, reason = p:isAvailable(game)
  return ok == true, reason
end

-- Resolve one provider attempting shiny then normal when requested shiny.
local function resolveProviderVariant(provider, speciesId, variant, game)
  local want = normalizeVariant(variant)
  if want == "shiny" then
    local def, meta, err = provider:resolve(speciesId, "shiny", game)
    if def then
      meta = meta or {}
      meta.usedVariant = meta.usedVariant or "shiny"
      return def, meta, nil
    end
    def, meta, err = provider:resolve(speciesId, "normal", game)
    if def then
      meta = meta or {}
      meta.usedVariant = meta.usedVariant or "normal"
      meta.shinyFallback = true
      meta.shinyError = err
      return def, meta, nil
    end
    return nil, nil, err or "shiny and normal unresolved"
  end
  return provider:resolve(speciesId, "normal", game)
end

-- Preferred auto shiny order is encoded by walking the chain with per-provider
-- shiny→normal attempts (followers shiny, followers normal, pokemmo shiny, ...).
function SpriteProviders:resolve(style, speciesId, variant, game)
  style = tostring(style or Config.spriteStyle(self.mod) or "auto")
  if not VALID_STYLES[style] then style = "auto" end

  local chain = self:chainForStyle(style)
  local steps = {}
  local fallbackStep = 0

  for _, providerId in ipairs(chain) do
    fallbackStep = fallbackStep + 1
    local provider = self.providers[providerId]
    if not provider then
      steps[#steps + 1] = { providerId = providerId, ok = false, reason = "not registered" }
    else
      local avail, availReason = provider:isAvailable(game)
      if not avail then
        steps[#steps + 1] = {
          providerId = providerId, ok = false, reason = availReason or "unavailable",
        }
      else
        local def, meta, err = resolveProviderVariant(provider, speciesId, variant, game)
        if def then
          meta = meta or {}
          meta.providerId = providerId
          meta.requestedStyle = style
          meta.fallbackStep = fallbackStep
          meta.providerMod = meta.providerMod or provider.modId
          meta.bodyRenderer = meta.bodyRenderer or "NATIVE_SPRITE_RENDERER"
          local result = {
            def = def,
            meta = meta,
            providerId = providerId,
            fallbackStep = fallbackStep,
            steps = steps,
          }
          steps[#steps + 1] = { providerId = providerId, ok = true, variant = meta.usedVariant }
          self.lastResolve = result
          return result
        end
        steps[#steps + 1] = {
          providerId = providerId, ok = false, reason = err or "resolve failed",
        }
      end
    end
  end

  -- Black fallback
  fallbackStep = fallbackStep + 1
  local black = self.providers[SpriteProviders.ID.BLACK]
  local def, meta = nil, nil
  if black then
    def, meta = black:resolve(speciesId, "normal", game)
  end
  meta = meta or {}
  meta.providerId = SpriteProviders.ID.BLACK
  meta.requestedStyle = style
  meta.fallbackStep = fallbackStep
  meta.bodyRenderer = "NATIVE_SPRITE_RENDERER"
  local result = {
    def = def,
    meta = meta,
    providerId = SpriteProviders.ID.BLACK,
    fallbackStep = fallbackStep,
    steps = steps,
    error = "all providers failed",
  }
  self.lastResolve = result
  return result
end

function SpriteProviders:activeProviderForStyle(style, game)
  style = tostring(style or "auto")
  local chain = self:chainForStyle(style)
  for _, id in ipairs(chain) do
    if self:providerAvailable(id, game) then
      return id, self.providers[id]
    end
  end
  return SpriteProviders.ID.BLACK, self.providers[SpriteProviders.ID.BLACK]
end

function SpriteProviders:diagnostics(style, game, entity)
  style = style or Config.spriteStyle(self.mod)
  local followers = self.providers[SpriteProviders.ID.FOLLOWERS_EX]
  local followersOk, followersReason = false, "NOT INSTALLED"
  if followers then
    followersOk, followersReason = followers:isAvailable(game)
  end
  local installed = false
  if self.mod and self.mod.find then
    installed = self.mod:find(FOLLOWERS_MOD_ID) ~= nil
  end

  local activeId = entity and entity.spriteProviderId
  if not activeId then
    activeId = select(1, self:activeProviderForStyle(style, game))
  end
  local active = activeId and self.providers[activeId]
  local last = self.lastResolve or (entity and entity.spriteProviderMeta and {
    meta = entity.spriteProviderMeta,
    providerId = entity.spriteProviderId,
    fallbackStep = entity.spriteFallbackStep,
  })

  local lines = {
    ("Requested style: %s"):format(tostring(style):upper()),
  }
  if not installed then
    lines[#lines + 1] = "Followers EX: NOT INSTALLED"
  elseif not followersOk then
    lines[#lines + 1] = ("Followers EX: UNAVAILABLE (%s)"):format(tostring(followersReason))
  else
    lines[#lines + 1] = "Followers EX: AVAILABLE"
  end

  if style == "followers_ex" and not followersOk then
    lines[#lines + 1] = "Provider unavailable: YES"
  end

  lines[#lines + 1] = ("Active provider: %s"):format(tostring(activeId or "?"):upper())
  local modId = (last and last.meta and last.meta.providerMod)
    or (active and active.modId) or "?"
  lines[#lines + 1] = ("Provider mod: %s"):format(tostring(modId))

  if entity then
    local dex = entity.enhancedDexId
      or resolveDexId(entity.species, game, self.mod)
    lines[#lines + 1] = ("Species ID: %s"):format(tostring(dex or entity.species or "?"))
    lines[#lines + 1] = ("Variant: %s"):format(
      tostring(entity.spriteVariant or "normal"):upper())
    local img = entity.sprite and entity.sprite.def and entity.sprite.def.image
    lines[#lines + 1] = ("Sprite image: %s"):format(tostring(img or "?"))
    lines[#lines + 1] = ("Frames: %s"):format(
      tostring(entity.sprite and entity.sprite.def and entity.sprite.def.frames or "?"))
    lines[#lines + 1] = ("Walker: %s"):format(
      (entity.sprite and entity.sprite.def and entity.sprite.def.walker) and "true" or "false")
    lines[#lines + 1] = ("Fallback step: %s"):format(
      tostring(entity.spriteFallbackStep or (last and last.fallbackStep) or "?"))
  end

  if style == "followers_ex" and not followersOk then
    lines[#lines + 1] = "Fallback reason: provider missing"
  elseif last and last.meta and last.meta.shinyFallback then
    lines[#lines + 1] = "Fallback reason: shiny unavailable"
  end

  lines[#lines + 1] = "Body renderer: NATIVE_SPRITE_RENDERER"
  return lines
end

SpriteProviders.VALID_STYLES = VALID_STYLES
SpriteProviders.STYLE_CHAINS = STYLE_CHAINS
SpriteProviders.FOLLOWERS_MOD_ID = FOLLOWERS_MOD_ID
SpriteProviders.POKEPC_MOD_ID = POKEPC_MOD_ID

return SpriteProviders
