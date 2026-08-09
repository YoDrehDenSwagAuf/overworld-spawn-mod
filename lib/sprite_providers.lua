-- Sprite source providers for Wilds of Kanto overworld Pokemon.
--
-- Architecture: swap SpriteRenderer definitions only. Rendering stays native
-- (frames/walker/pose → Gen1Recomp / Dramatic Shape). No overlay bodies.
--
-- Built-in IDs: gold, followers_ex, pokemmo, pokedex (+ internal black fallback).
-- External mods may register via mod.exports.registerSpriteProvider after
-- Wilds loads (Followers EX priority 160 loads after Wilds priority 80).
--
-- Optional water extension (backward compatible):
--   provider:resolveWater(speciesId, variant, game)
--   provider:resolveForState(speciesId, variant, "water"|"land", game)
-- Missing methods simply mean "no water support" — Wilds then uses built-in
-- swimming/levitates sheets via SpriteResolver.
--
-- Gold Sprites (Gold_Silver_Sprites 1.0.1) ships battle front/back PNGs only
-- (56×56 fronts). Wilds adapts them as 1-frame SpriteRenderer defs — no asset
-- copy, no hard dependency, no content-registry mutation after freeze.
local V = ...
local Config = V.require("config")
local RuntimeSheets = V.require("runtime_sheets")
local AnimatedSprites = V.require("animated_sprites")
local DebugLog = V.require("debug_log")

local SpriteProviders = {}
SpriteProviders.__index = SpriteProviders

SpriteProviders.ID = {
  GOLD = "gold",
  FOLLOWERS_EX = "followers_ex",
  POKEMMO = "pokemmo",
  POKEDEX = "pokedex",
  BLACK = "black",
}

-- Public styles (Mod Settings). "followers" is the visible value; the
-- provider id remains "followers_ex".
SpriteProviders.STYLE = {
  POKEMMO = "pokemmo",
  FOLLOWERS = "followers",
  POKEDEX = "pokedex",
  -- Compat aliases (normalized away by Config.normalizeSpriteStyle).
  AUTO = "auto",
  GOLD = "gold",
  FOLLOWERS_EX = "followers_ex",
}

-- Explicit style → provider try order (before black).
-- Public "followers" maps to the followers_ex provider, then HGSS/PokeMMO.
local STYLE_CHAINS = {
  pokemmo = { "pokemmo", "pokedex" },
  followers = { "followers_ex", "pokemmo", "pokedex" },
  pokedex = { "pokedex" },
  -- Legacy aliases kept for direct resolve / old call sites.
  auto = { "pokemmo", "pokedex" },
  gold = { "pokemmo", "pokedex" },
  followers_ex = { "followers_ex", "pokemmo", "pokedex" },
}

local VALID_STYLES = {
  pokemmo = true,
  followers = true,
  pokedex = true,
  auto = true,
  gold = true,
  followers_ex = true,
}

-- Back-compat export (no longer used as a public Auto preference order).
local AUTO_PROVIDER_ORDER = STYLE_CHAINS.auto

local FOLLOWERS_MOD_ID = "FOLLOWERS_EX"
local POKEPC_MOD_ID = "PokePCFollowers_VoxelMerge"
local GOLD_MOD_ID = "Gold_Silver_Sprites"
local PROBE_SPECIES = "CHARMANDER"
local PROBE_REL = "assets/sprites/follower_" .. PROBE_SPECIES .. ".png"
-- Availability probes: Dex 1 / 25 / 151 (release truecolor fronts).
local GOLD_PROBE_SPECIES = { "BULBASAUR", "PIKACHU", "MEW" }
local GOLD_ROOT_CANDIDATES = {
  "mods/Gold_Silver_Sprites",
  "mods/Pokemon Gold Silver Sprites",
}

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

local function copyDef(def, spriteId, mod)
  if type(def) ~= "table" or type(def.image) ~= "string" or def.image == "" then
    return nil
  end
  local trueColor = def.trueColor ~= false
  -- PokéPC color_mode semantics: Classic forces trueColor=false.
  if mod and Config and Config.spriteTrueColor then
    trueColor = Config.spriteTrueColor(mod)
  end
  local out = {
    image = def.image,
    frames = tonumber(def.frames) or 1,
    trueColor = trueColor,
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
  -- External adapters are registered now and re-probed at finalize / resolve.
  self:register(self:_makeGoldProvider())
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
  for _, id in ipairs({ SpriteProviders.ID.GOLD, SpriteProviders.ID.FOLLOWERS_EX }) do
    local provider = self.providers[id]
    if provider and type(provider.refreshAvailability) == "function" then
      pcall(provider.refreshAvailability, provider, game)
    end
  end
  if Config.debug(self.mod) then
    local gold = self.providers[SpriteProviders.ID.GOLD]
    local followers = self.providers[SpriteProviders.ID.FOLLOWERS_EX]
    local gOk, gWhy = false, "missing"
    local fOk, fWhy = false, "missing"
    if gold then gOk, gWhy = gold:isAvailable(game) end
    if followers then fOk, fWhy = followers:isAvailable(game) end
    DebugLog.info(self.mod,
      "sprite providers finalized; gold=%s (%s) followers_ex=%s (%s)",
      tostring(gOk), tostring(gWhy), tostring(fOk), tostring(fWhy))
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
-- Gold Sprites read-only adapter (OtaconRevengeance / Gold_Silver_Sprites)
--
-- Release 1.0.1 facts (verified from Pokemon.Gold.Silver.Sprites.1.0.1.zip):
--   * Mod ID: Gold_Silver_Sprites  version: 1.0.1  entry: main.lua
--   * No public exports; hooks pokemon.sprite for battle art only
--   * Truecolor fronts: <pack>/battle/front/<species_lower>.png (56×56)
--   * No shiny variants, no walker sheets (frames=1, walker=false)
--   * Pack choice gold|silver via Gold's spritePack option (default gold)
--
-- We never copy assets, never mutate Gold's tables, never hard-depend.
------------------------------------------------------------------------

function SpriteProviders:_goldFrontRel(speciesKey, pack)
  pack = (pack == "silver") and "silver" or "gold"
  if type(speciesKey) ~= "string" or speciesKey == "" then return nil end
  return pack .. "/battle/front/" .. string.lower(speciesKey) .. ".png"
end

function SpriteProviders:_goldPackChoice(game)
  local buckets = {}
  if game and game.save and game.save.options and game.save.options.modOptions then
    buckets[#buckets + 1] = game.save.options.modOptions[GOLD_MOD_ID]
  end
  if game and game.mods and game.mods.modOptions then
    buckets[#buckets + 1] = game.mods.modOptions[GOLD_MOD_ID]
  end
  if game and game.mods and game.mods.loader and game.mods.loader.modOptions then
    buckets[#buckets + 1] = game.mods.loader.modOptions[GOLD_MOD_ID]
  end
  for i = 1, #buckets do
    local b = buckets[i]
    if type(b) == "table" and (b.spritePack == "gold" or b.spritePack == "silver") then
      return b.spritePack
    end
  end
  return "gold"
end

function SpriteProviders:_discoverGoldRoot(game)
  local mod = self.mod

  local function probeOk(root, pack)
    if type(root) ~= "string" or root == "" then return false end
    for _, species in ipairs(GOLD_PROBE_SPECIES) do
      local rel = self:_goldFrontRel(species, pack)
      if rel and fsExists(root .. "/" .. rel) then
        return true
      end
    end
    return false
  end

  -- A) Optional future public export.
  if mod and mod.find then
    local hit = mod:find(GOLD_MOD_ID)
    local ex = hit and hit.exports
    if ex then
      if type(ex.resolveGoldSprite) == "function"
         or type(ex.getGoldSpritePath) == "function"
         or type(ex.resolveSprite) == "function" then
        return "export:" .. GOLD_MOD_ID, GOLD_MOD_ID, ex, hit
      end
    end
    if hit and type(hit.path) == "string" then
      local pack = self:_goldPackChoice(game)
      if probeOk(hit.path, pack) or probeOk(hit.path, "gold") or probeOk(hit.path, "silver") then
        return hit.path, GOLD_MOD_ID, nil, hit
      end
    end
  end

  -- B) Documented install locations matching the release ZIP folder name.
  local pack = self:_goldPackChoice(game)
  for _, root in ipairs(GOLD_ROOT_CANDIDATES) do
    if probeOk(root, pack) or probeOk(root, "gold") or probeOk(root, "silver") then
      return root, root, nil, nil
    end
  end

  return nil, nil, nil, nil
end

function SpriteProviders:_makeGoldProvider()
  local mod = self.mod
  local owners = self
  local state = {
    root = nil,
    source = nil,
    exportApi = nil,
    hit = nil,
    probed = false,
  }

  local provider = {
    id = SpriteProviders.ID.GOLD,
    builtin = true,
    modId = GOLD_MOD_ID,
    _state = state,
  }

  function provider:refreshAvailability(game)
    state.probed = true
    local root, source, exportApi, hit = owners:_discoverGoldRoot(game)
    state.root, state.source, state.exportApi, state.hit = root, source, exportApi, hit
    return state.root ~= nil or state.exportApi ~= nil
  end

  function provider:isAvailable(game)
    if not state.probed or (state.root == nil and state.exportApi == nil) then
      self:refreshAvailability(game)
    end
    if state.exportApi then
      return true, "gold export API (" .. tostring(state.source) .. ")"
    end
    if state.root then
      local pack = owners:_goldPackChoice(game)
      for _, species in ipairs(GOLD_PROBE_SPECIES) do
        local rel = owners:_goldFrontRel(species, pack)
        if rel and fsExists(state.root .. "/" .. rel) then
          return true, "Gold Sprites fronts at " .. tostring(state.root)
        end
      end
      -- Root found for other pack; still usable.
      for _, species in ipairs(GOLD_PROBE_SPECIES) do
        local rel = owners:_goldFrontRel(species, "gold")
        if rel and fsExists(state.root .. "/" .. rel) then
          return true, "Gold Sprites fronts at " .. tostring(state.root)
        end
      end
    end
    if mod and mod.find and mod:find(GOLD_MOD_ID) and not state.root then
      return false, "Gold_Silver_Sprites installed but sprite fronts unresolved"
    end
    return false, "Gold Sprites provider not available"
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
      return nil, nil, "species key unresolved for gold path"
    end

    local wantShiny = normalizeVariant(variant) == "shiny"
    -- Gold_Silver_Sprites has no shiny art. Signal shiny miss so the chain
    -- tries gold normal next (resolveProviderVariant), then later providers.
    if wantShiny then
      return nil, nil, "gold shiny unavailable"
    end

    -- Future / optional public export API.
    if state.exportApi then
      local api = state.exportApi
      local tryFns = { "resolveGoldSprite", "resolveSprite", "getGoldSpritePath" }
      for _, fname in ipairs(tryFns) do
        local fn = api[fname]
        if type(fn) == "function" then
          local ok, defOrPath, meta = pcall(fn, speciesKey, variant, game)
          if ok and type(defOrPath) == "table" and defOrPath.image then
            local def = copyDef(defOrPath, "SPRITE_OW_WILD_" .. tostring(speciesKey))
            def.frames = tonumber(def.frames) or 1
            def.trueColor = def.trueColor ~= false
            if def.walker == nil then def.walker = false end
            return def, {
              providerId = SpriteProviders.ID.GOLD,
              usedVariant = "normal",
              loadPath = def.image,
              frames = def.frames,
              walker = def.walker == true,
              bodyRenderer = "NATIVE_SPRITE_RENDERER",
              providerMod = GOLD_MOD_ID,
              providerVersion = state.hit and state.hit.version,
            }, nil
          elseif ok and type(defOrPath) == "string" and defOrPath ~= "" and fsExists(defOrPath) then
            local def = {
              image = defOrPath, frames = 1, trueColor = true,
              id = "SPRITE_OW_WILD_" .. tostring(speciesKey),
            }
            return def, {
              providerId = SpriteProviders.ID.GOLD,
              usedVariant = "normal",
              loadPath = defOrPath, frames = 1, walker = false,
              bodyRenderer = "NATIVE_SPRITE_RENDERER",
              providerMod = GOLD_MOD_ID,
              providerVersion = state.hit and state.hit.version,
            }, nil
          end
        end
      end
    end

    if not state.root or tostring(state.root):sub(1, 7) == "export:" then
      return nil, nil, "no Gold Sprites asset root"
    end

    local pack = owners:_goldPackChoice(game)
    local rel = owners:_goldFrontRel(speciesKey, pack)
    local path = state.root .. "/" .. rel
    if not fsExists(path) and pack ~= "gold" then
      rel = owners:_goldFrontRel(speciesKey, "gold")
      path = state.root .. "/" .. rel
    end
    if not fsExists(path) then
      return nil, nil, "missing gold front: " .. tostring(rel)
    end

    local def = {
      image = path,
      frames = 1,
      trueColor = true,
      id = "SPRITE_OW_WILD_" .. tostring(speciesKey),
    }
    local meta = {
      providerId = SpriteProviders.ID.GOLD,
      usedVariant = "normal",
      loadPath = path,
      relativePath = rel,
      frames = 1,
      walker = false,
      bodyRenderer = "NATIVE_SPRITE_RENDERER",
      providerMod = GOLD_MOD_ID,
      providerVersion = state.hit and state.hit.version,
      pack = pack,
      sheetFormat = "battle_front_56x56",
    }
    return def, meta, nil
  end

  return provider
end

------------------------------------------------------------------------
-- Built-in Poke Followers / GSC (provider id remains followers_ex for
-- save / chain compatibility). Assets ship split into subdirs:
--   assets/enhanced_overworld/poke_followers/normal/follower_%03d.png  (colored)
--   assets/enhanced_overworld/poke_followers/shiny/follower_%03d.png   (colored shiny)
--   assets/enhanced_overworld/poke_followers/grayscale/follower_%03d.png (grayscale)
-- Dex id maps 1:1. External PokePC packs remain an optional override.
------------------------------------------------------------------------

local POKE_FOLLOWERS_REL = "assets/enhanced_overworld/poke_followers"
local POKE_FOLLOWERS_PROBE = POKE_FOLLOWERS_REL .. "/follower_001_normal.png"

-- Flat file naming (all variants in one directory):
--   follower_%03d_normal.png    (colored)
--   follower_%03d_shiny.png     (shiny)
--   follower_%03d_grayscale.png (grayscale)
--   follower_%03d_submerged.png (submerged)

function SpriteProviders:_pokeFollowersPath(dex, render)
  if type(dex) ~= "number" or dex < 1 then return nil, nil end
  local rel = string.format("%s/follower_%03d_normal.png", POKE_FOLLOWERS_REL, dex)
  return self:_modRelPath(rel, render)
end

function SpriteProviders:_pokeFollowersShinyPath(dex, render)
  if type(dex) ~= "number" or dex < 1 then return nil, nil end
  local rel = string.format("%s/follower_%03d_shiny.png", POKE_FOLLOWERS_REL, dex)
  return self:_modRelPath(rel, render)
end

-- Grayscale sibling sheets serve every PaletteFX mode except redpp (ADVANCED),
-- which bakes real per-tile color and keeps the original colored art.
function SpriteProviders:_pokeFollowersGrayscalePath(dex, render)
  if type(dex) ~= "number" or dex < 1 then return nil, nil end
  local rel = string.format("%s/follower_%03d_grayscale.png", POKE_FOLLOWERS_REL, dex)
  return self:_modRelPath(rel, render)
end

-- Submerged (water) sheet: variant-aware naming.
-- follower_NNN_normal_submerged.png  (colored)
-- follower_NNN_shiny_submerged.png   (colored shiny)
-- follower_NNN_grayscale_submerged.png (grayscale)
function SpriteProviders:_pokeFollowersSubmergedPath(dex, render, variant)
  if type(dex) ~= "number" or dex < 1 then return nil, nil end
  variant = variant or "normal"
  local suffix = variant .. "_submerged"
  local rel = string.format("%s/follower_%03d_%s.png", POKE_FOLLOWERS_REL, dex, suffix)
  return self:_modRelPath(rel, render)
end

-- Backward-compatible aliases.
function SpriteProviders:_pokeFollowersSubmergedGrayscalePath(dex, render)
  return self:_pokeFollowersSubmergedPath(dex, render, "grayscale")
end

function SpriteProviders:_pokeFollowersSubmergedColoredPath(dex, render)
  return self:_pokeFollowersSubmergedPath(dex, render, "normal")
end

-- Resolve a mod-relative asset to a load path (render._modAssetPath first,
-- then mod.assets:path; headless falls back to the relative path).
function SpriteProviders:_modRelPath(rel, render)
  local via = nil
  if render and render._modAssetPath then
    local ok, path = pcall(render._modAssetPath, render, rel)
    if ok and type(path) == "string" and path ~= "" then
      via = path
    end
  end
  if not via and self.mod and self.mod.assets and self.mod.assets.path then
    local ok, path = pcall(function() return self.mod.assets:path(rel) end)
    if ok and type(path) == "string" then via = path end
  end
  -- Headless / unit-test fallback: relative path from mod root.
  if not via then via = rel end
  return via, rel
end

function SpriteProviders:_builtinPokeFollowersReady()
  local mod = self.mod
  if mod and mod.read then
    local ok, data = pcall(function() return mod:read(POKE_FOLLOWERS_PROBE) end)
    if ok and data then return true end
  end
  return fsExists(POKE_FOLLOWERS_PROBE)
end

function SpriteProviders:_makeFollowersExProvider()
  local mod = self.mod
  local render = self.render
  local owners = self
  local state = {
    root = nil,
    source = nil,
    exportApi = nil,
    probed = false,
  }

  local provider = {
    id = SpriteProviders.ID.FOLLOWERS_EX,
    builtin = true,
    modId = mod and mod.id or "overworld_wild_spawns",
    _state = state,
  }

  function provider:refreshAvailability(game)
    state.probed = true
    if owners:_builtinPokeFollowersReady() then
      state.root, state.source, state.exportApi = POKE_FOLLOWERS_REL, "builtin", nil
      return true
    end
    local root, source, exportApi = owners:_discoverPokepcRoot(game)
    state.root, state.source, state.exportApi = root, source, exportApi
    return state.root ~= nil or state.exportApi ~= nil
  end

  function provider:isAvailable(game)
    if owners:_builtinPokeFollowersReady() then
      return true, "built-in poke_followers (GSC)"
    end
    if not state.probed then
      self:refreshAvailability(game)
    end
    if state.exportApi then
      return true, "followers export API (" .. tostring(state.source) .. ")"
    end
    if state.root and state.root ~= POKE_FOLLOWERS_REL
       and fsExists(tostring(state.root) .. "/" .. PROBE_REL) then
      return true, "external PokePC walker sheets at " .. tostring(state.root)
    end
    return false, "Poke Followers assets unavailable"
  end

  function provider:resolve(speciesId, variant, game)
    local okAvail, why = self:isAvailable(game)
    if not okAvail then
      return nil, nil, why
    end

    local dex = resolveDexId(speciesId, game, mod)
    local wantShiny = normalizeVariant(variant) == "shiny"

    -- Built-in pack: dex → follower_%03d.png split into normal/ (colored),
    -- shiny/ (colored shiny) and grayscale/ subdirs. Grayscale siblings
    -- serve every PaletteFX mode except redpp (ADVANCED), which bakes real
    -- per-tile color and keeps the colored art.
    if owners:_builtinPokeFollowersReady() and dex then
      local imagePath, rel = nil, nil
      local usedVariant = "normal"
      if not Config.paletteFxRedpp() then
        local gPath, gRel = owners:_pokeFollowersGrayscalePath(dex, render)
        if gPath and gRel then
          local gExists = true
          if mod and mod.read then
            local ok, data = pcall(function() return mod:read(gRel) end)
            gExists = ok and data ~= nil
          elseif not fsExists(gRel) then
            gExists = false
          end
          if gExists then
            imagePath, rel = gPath, gRel
          end
        end
      elseif wantShiny then
        -- redpp + shiny: prefer the shiny/ sheet, fall back to normal/.
        local sPath, sRel = owners:_pokeFollowersShinyPath(dex, render)
        if sPath and sRel then
          local sExists = true
          if mod and mod.read then
            local ok, data = pcall(function() return mod:read(sRel) end)
            sExists = ok and data ~= nil
          elseif not fsExists(sRel) then
            sExists = false
          end
          if sExists then
            imagePath, rel = sPath, sRel
            usedVariant = "shiny"
          end
        end
      end
      if not imagePath then
        imagePath, rel = owners:_pokeFollowersPath(dex, render)
      end
      if not imagePath then
        return nil, nil, "poke_followers path unresolved for dex " .. tostring(dex)
      end
      -- Existence: prefer mod.read / fs when available.
      local exists = true
      if mod and mod.read then
        local ok, data = pcall(function()
          return mod:read(rel or string.format("%s/follower_%03d.png",
            POKE_FOLLOWERS_REL, dex))
        end)
        exists = ok and data ~= nil
      elseif not fsExists(rel or imagePath) and not fsExists(imagePath) then
        exists = false
      end
      if not exists then
        return nil, nil, "missing poke_followers sheet for dex " .. tostring(dex)
      end
      local def = {
        image = imagePath,
        frames = 6,
        walker = true,
        trueColor = true,
        id = "SPRITE_OW_WILD_" .. tostring(dex),
      }
      return def, {
        providerId = SpriteProviders.ID.FOLLOWERS_EX,
        usedVariant = usedVariant,
        loadPath = imagePath,
        relativePath = rel,
        frames = 6,
        walker = true,
        bodyRenderer = "NATIVE_SPRITE_RENDERER",
        providerMod = "overworld_wild_spawns",
        pack = "poke_followers",
      }, nil
    end

    -- Optional external PokePC / export API (legacy companion mods).
    local speciesKey = speciesKeyFromId(speciesId, game, mod)
    if not speciesKey and type(speciesId) == "string" and not tonumber(speciesId) then
      speciesKey = speciesId
    end
    if not speciesKey then
      return nil, nil, "species key unresolved for followers path"
    end

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
        elseif ok and type(defOrPath) == "string" and defOrPath ~= "" and fsExists(defOrPath) then
          local def = {
            image = defOrPath, frames = 6, walker = true, trueColor = true,
            id = "SPRITE_OW_WILD_" .. tostring(speciesKey),
          }
          return def, {
            providerId = SpriteProviders.ID.FOLLOWERS_EX,
            usedVariant = wantShiny and "shiny" or "normal",
            loadPath = defOrPath, frames = 6, walker = true,
            bodyRenderer = "NATIVE_SPRITE_RENDERER",
            providerMod = state.source or POKEPC_MOD_ID,
          }, nil
        end
      end
    end

    if not state.root then
      return nil, nil, "no Poke Followers asset root"
    end

    local path = tostring(state.root) .. "/assets/sprites/follower_"
      .. tostring(speciesKey) .. ".png"
    if not fsExists(path) then
      return nil, nil, "missing follower sheet: " .. path
    end
    if wantShiny then
      return nil, nil, "followers shiny sheet path unavailable"
    end
    local def = {
      image = path, frames = 6, walker = true, trueColor = true,
      id = "SPRITE_OW_WILD_" .. tostring(speciesKey),
    }
    return def, {
      providerId = SpriteProviders.ID.FOLLOWERS_EX,
      usedVariant = "normal",
      loadPath = path, frames = 6, walker = true,
      bodyRenderer = "NATIVE_SPRITE_RENDERER",
      providerMod = state.source or POKEPC_MOD_ID,
    }, nil
  end

  -- Water extension (submerged sheets).  Naming is
  -- follower_NNN_{variant}_submerged.png.  Picks based on COLORS mode:
  -- redpp uses normal_submerged (or shiny_submerged), grayscale/GBC
  -- uses grayscale_submerged.
  function provider:resolveWater(speciesId, variant, game)
    local okAvail, why = self:isAvailable(game)
    if not okAvail then
      return nil, nil, why
    end
    local dex = resolveDexId(speciesId, game, mod)
    if not dex then return nil, nil, "dex unresolved" end

    local redpp = Config.paletteFxRedpp and Config.paletteFxRedpp()
    local tryVariants
    if redpp then
      if variant == "shiny" then
        tryVariants = { "shiny", "normal" }
      else
        tryVariants = { "normal" }
      end
    else
      tryVariants = { "grayscale" }
    end
    local imagePath, rel, usedVariant = nil, nil, "normal"
    for _, v in ipairs(tryVariants) do
      imagePath, rel = owners:_pokeFollowersSubmergedPath(dex, render, v)
      if imagePath and rel then
        local exists = true
        if mod and mod.read then
          local ok, data = pcall(function() return mod:read(rel) end)
          if not ok or data == nil then
            exists = fsExists(rel) or fsExists(imagePath)
          end
        elseif not fsExists(rel) then
          exists = false
        end
        if exists then usedVariant = v; break end
        imagePath, rel = nil, nil
      end
    end
    if not imagePath then
      return nil, nil, "no submerged poke_followers sheet for dex " .. tostring(dex)
    end
    local def = {
      image = imagePath,
      frames = 6,
      walker = true,
      trueColor = true,
      id = "SPRITE_OW_WILD_SUBMERGED_" .. tostring(dex),
    }
    return def, {
      providerId = SpriteProviders.ID.FOLLOWERS_EX,
      usedVariant = usedVariant,
      loadPath = imagePath,
      relativePath = rel,
      frames = 6,
      walker = true,
      bodyRenderer = "NATIVE_SPRITE_RENDERER",
      providerMod = "overworld_wild_spawns",
      pack = "poke_followers_submerged",
    }, nil
  end

  return provider
end

--- Resolve a water sprite through the style chain's providers (submerged
-- poke_followers art etc). Returns { def, meta } or nil when no provider in
-- the chain supports water resolution.
function SpriteProviders:resolveWater(style, speciesId, variant, game)
  style = self:normalizeStyle(style or Config.spriteStyle(self.mod) or "followers")
  local chain = self:chainForStyle(style)

  -- Poke Followers submerged sheets are independent of the land sprite-style
  -- preference.  Always try the followers_ex provider first so its submerged
  -- art takes precedence over the swimming/levitates registry; then fall
  -- through the selected style chain for providers that also support water.
  local ordered = { SpriteProviders.ID.FOLLOWERS_EX }
  for _, pid in ipairs(chain) do
    if pid ~= SpriteProviders.ID.FOLLOWERS_EX then
      ordered[#ordered + 1] = pid
    end
  end

  for _, providerId in ipairs(ordered) do
    local provider = self.providers[providerId]
    if provider and type(provider.resolveWater) == "function" then
      local def, meta, err = provider:resolveWater(speciesId, variant, game)
      if def then
        meta = meta or {}
        meta.providerId = providerId
        meta.kind = meta.kind or "submerged"
        meta.water = true
        if Config.spriteTrueColor then
          def.trueColor = Config.spriteTrueColor(self.mod)
        end
        return def, meta
      end
      if err then
        DebugLog.debug(self.mod, "%s resolveWater %s: %s",
          providerId, tostring(speciesId), tostring(err))
      end
    end
  end
  return nil, nil
end

------------------------------------------------------------------------
-- Followers EX / PokePC root discovery (optional companion override)
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


------------------------------------------------------------------------
-- Resolution with style chains + shiny fallback
------------------------------------------------------------------------

function SpriteProviders:normalizeStyle(style)
  if type(Config.normalizeSpriteStyle) == "function" then
    return Config.normalizeSpriteStyle(style)
  end
  style = tostring(style or "followers")
  if style == "followers_ex" or style == "poke_followers" then return "followers" end
  if style == "auto" or style == "gold" or style == "crystal" then
    return "pokemmo"
  end
  if VALID_STYLES[style] and (style == "pokemmo" or style == "followers"
      or style == "pokedex") then
    return style
  end
  return "followers"
end

function SpriteProviders:chainForStyle(style)
  style = self:normalizeStyle(style)
  return STYLE_CHAINS[style] or STYLE_CHAINS.pokemmo
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
  style = self:normalizeStyle(style or Config.spriteStyle(self.mod) or "followers")

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
          -- Apply shared Sprite Color (PokéPC color_mode semantics).
          if Config.spriteTrueColor then
            def.trueColor = Config.spriteTrueColor(self.mod)
          end
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
  style = self:normalizeStyle(style or "followers")
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

  local function installedStatus(modId, providerId, label)
    local installed = false
    if self.mod and self.mod.find then
      installed = self.mod:find(modId) ~= nil
    end
    local provider = self.providers[providerId]
    local ok, reason = false, "NOT INSTALLED"
    if provider then
      ok, reason = provider:isAvailable(game)
    end
    local lines = {}
    if not installed and not ok then
      lines[#lines + 1] = label .. ": NOT INSTALLED"
    elseif not ok then
      lines[#lines + 1] = ("%s: UNAVAILABLE (%s)"):format(label, tostring(reason))
    else
      lines[#lines + 1] = label .. ": AVAILABLE"
      local ver = provider and provider._state and provider._state.hit
        and provider._state.hit.version
      if ver then
        lines[#lines + 1] = ("Provider version: %s"):format(tostring(ver))
      end
    end
    return lines, installed, ok, reason
  end

  style = self:normalizeStyle(style)
  local followersLines, followersInstalled, followersOk =
    installedStatus(FOLLOWERS_MOD_ID, SpriteProviders.ID.FOLLOWERS_EX, "Poke Followers")
  local pokepcInstalled = false
  if self.mod and self.mod.find then
    pokepcInstalled = self.mod:find(POKEPC_MOD_ID) ~= nil
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
  for _, line in ipairs(followersLines) do lines[#lines + 1] = line end
  lines[#lines + 1] = ("PokePC provider: %s"):format(
    pokepcInstalled and "INSTALLED" or "NOT INSTALLED")

  if style == "followers" and not followersOk then
    lines[#lines + 1] = "Provider unavailable: YES"
  end

  lines[#lines + 1] = ("Active provider: %s"):format(tostring(activeId or "?"):upper())
  local modId = (last and last.meta and last.meta.providerMod)
    or (active and active.modId) or "?"
  lines[#lines + 1] = ("Provider mod: %s"):format(tostring(modId))
  local ver = last and last.meta and last.meta.providerVersion
  if ver then
    lines[#lines + 1] = ("Provider version: %s"):format(tostring(ver))
  end
  if style == "followers" then
    lines[#lines + 1] = ("Provider installed: %s"):format(
      (followersInstalled or followersOk) and "YES" or "NO")
  end

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

  if style == "followers" and not followersOk then
    lines[#lines + 1] = "Fallback reason: provider missing"
  elseif last and last.meta and last.meta.shinyFallback then
    lines[#lines + 1] = "Fallback reason: shiny unavailable"
  end

  lines[#lines + 1] = "Quick menu: READY"
  lines[#lines + 1] = "Body renderer: NATIVE_SPRITE_RENDERER"
  return lines
end

SpriteProviders.VALID_STYLES = VALID_STYLES
SpriteProviders.STYLE_CHAINS = STYLE_CHAINS
SpriteProviders.AUTO_PROVIDER_ORDER = AUTO_PROVIDER_ORDER
SpriteProviders.FOLLOWERS_MOD_ID = FOLLOWERS_MOD_ID
SpriteProviders.POKEPC_MOD_ID = POKEPC_MOD_ID
SpriteProviders.GOLD_MOD_ID = GOLD_MOD_ID

return SpriteProviders
