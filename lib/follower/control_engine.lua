-- Control / pack / trailer engine for Wilds of Kanto standalone use.
--
-- Credits: masterwebx / Followers EX ControlEngine concepts adapted for Wilds;
-- assets via Wilds sprite service (no PokePCFollowers_VoxelMerge dependency).
--
-- Ownership:
--   * Trailer movement: ControlEngine:update via OverworldController.update
--     (fallback: PikachuFollower.update wrap when OW wrap unavailable).
--   * Stock PikachuFollower: shouldSpawn / onMapEntered / talk only.
-- Lifecycle must NOT also wrap update/onMapEntered/shouldSpawn when the
-- control engine is installed.
local V = ...
local Constants = V.require("follower/constants")

local DebugLog
do
  local ok, mod = pcall(function() return V.require("debug_log") end)
  if ok then DebugLog = mod end
end

local ControlEngine = {}
ControlEngine.__index = ControlEngine

local TRAILER_BASE = 240

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function logInfo(mod, fmt, ...)
  if DebugLog and DebugLog.info then
    DebugLog.info(mod, fmt, ...)
  end
end

local function logWarn(mod, fmt, ...)
  if DebugLog and DebugLog.warn then
    DebugLog.warn(mod, fmt, ...)
  end
end

local function captureUpvalue(fn, upvalueName)
  if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then
    return nil, nil
  end
  local i = 1
  while true do
    local name, val = debug.getupvalue(fn, i)
    if not name then break end
    if name == upvalueName then return i, val end
    i = i + 1
  end
  return nil, nil
end

local function patchUpvalue(fn, upvalueName, newVal)
  local idx = select(1, captureUpvalue(fn, upvalueName))
  if idx and debug.setupvalue then
    debug.setupvalue(fn, idx, newVal)
    return true
  end
  return false
end

local function isShinyMon(mon)
  if not mon then return false end
  if mon.shiny == true or mon.isShiny == true then return true end
  local Stats = tryRequire("src.pokemon.Stats")
  if Stats and Stats.isShiny and mon.dvs then
    local ok, shiny = pcall(Stats.isShiny, mon.dvs)
    return ok and shiny and true or false
  end
  return false
end

local function copySpriteDef(def)
  if type(def) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(def) do out[k] = v end
  return out
end

--- Construct a control engine instance.
-- @param mod Wilds mod handle
-- @param deps table optional: spriteService, settings, selection, render, game
function ControlEngine.new(mod, deps)
  deps = deps or {}
  local self = setmetatable({}, ControlEngine)
  self.mod = mod
  self.deps = deps
  self.spriteService = deps.spriteService
  self.settings = deps.settings
  self.selection = deps.selection
  self.render = deps.render
  self._gameRef = deps.game -- optional injected Game (tests)
  self._installed = false
  self._restoreState = nil
  self._pendingMapTrailerSync = false
  self._mapExitSnapshot = nil
  self._pendingConnectionHandoff = nil
  self._optCache = {}
  self._eventOff = {}
  self._talkWrapped = false
  self._owUpdateWrapped = false
  self._inControlUpdate = false
  -- "overworld" = OverworldController.update owns trailer ticks;
  -- "pikachu_follower" = fallback when OW wrap is unavailable.
  self._trailerUpdateOwner = nil
  self.diag = {
    wrappedUpdateCalls = 0,
    syncTrailersCalls = 0,
    advanceTrailerStepCalls = 0,
    controlUpdateCalls = 0,
    overworldUpdateCalls = 0,
    lastSource = nil,
    lastSurfing = false,
  }
  return self
end

function ControlEngine:_game()
  if self._gameRef then return self._gameRef end
  local Game = tryRequire("src.core.Game")
  return Game
end

function ControlEngine:_isYellow()
  local GV = tryRequire("src.core.GameVersion")
  if not GV then return false end
  if type(GV.isYellow) == "function" then
    local ok, yellow = pcall(GV.isYellow)
    if ok then return yellow == true end
  end
  if type(GV.get) == "function" then
    local ok, version = pcall(GV.get)
    return ok and version == "yellow"
  end
  return false
end

function ControlEngine:_opt(key, default)
  local cache = self._optCache
  if cache[key] ~= nil then return cache[key] end
  local mod = self.mod
  if mod and mod.options and mod.options.get then
    local ok, got = pcall(mod.options.get, mod.options, key)
    if ok and got ~= nil and type(got) ~= "boolean" then
      cache[key] = got
      return got
    end
  end
  cache[key] = default
  return default
end

function ControlEngine:onOptionsChanged(payload)
  -- Cache is a consumer only — wipe on any options change.
  self._optCache = {}
  local settings = self.settings
  if settings and type(settings.onOptionsChanged) == "function" then
    pcall(settings.onOptionsChanged, settings, payload)
  end

  local game = (payload and payload.game) or self:_game()
  if game then
    -- Mirror mod.options → game.save, then rebuild active trailers.
    pcall(function() self:alignSaveFromOptions(game) end)
    pcall(function() self:syncAll(game, game.overworld) end)
  end
end

function ControlEngine:controlMode(game)
  game = game or self:_game()
  local settings = self.settings
  if settings and type(settings.engineMode) == "function" then
    local ok, mode = pcall(settings.engineMode, settings, game)
    if ok and type(mode) == "string" and mode ~= "" then
      if mode == "lead" then mode = "lead_trainer" end
      return mode
    end
  end
  local saved = game and game.save and game.save.pokepcControlMode
  if saved == "lead" then saved = "lead_trainer" end
  if type(saved) == "string" and saved ~= "" then return saved end
  return tostring(self:_opt("control_mode", "follow"))
end

function ControlEngine:followerCount(game)
  game = game or self:_game()
  local settings = self.settings
  if settings and type(settings.followerCount) == "function" then
    local ok, n = pcall(settings.followerCount, settings, game)
    if ok and type(n) == "number" then
      return math.max(0, math.min(6, n))
    end
  end
  -- Prefer live options over a possibly stale save mirror / cache.
  local fromOpt = self:_opt("follower_count", nil)
  if type(fromOpt) == "number" then
    return math.max(0, math.min(6, fromOpt))
  end
  local saved = game and game.save and game.save.pokepcFollowerCount
  if type(saved) == "number" then return math.max(0, math.min(6, saved)) end

  return 1
end

--- Programmatic API: write through Settings (options + save mirror).
-- Does not own persistence; invalidates local cache instead of storing a
-- parallel truth. Callers that need runtime refresh should go through
-- Follower:onOptionsChanged / ControlEngine:onOptionsChanged.
function ControlEngine:setFollowerCount(game, n)
  n = math.max(0, math.min(6, math.floor(tonumber(n) or 0)))
  local settings = self.settings
  if settings and type(settings.setFollowerCount) == "function" then
    local ok, got = pcall(settings.setFollowerCount, settings, game, n)
    if ok and type(got) == "number" then n = got end
  elseif self.mod and self.mod.options and type(self.mod.options.set) == "function" then
    pcall(self.mod.options.set, self.mod.options, "follower_count", n)
    if game and game.save then game.save.pokepcFollowerCount = n end
  elseif game and game.save then
    game.save.pokepcFollowerCount = n
  end
  self._optCache.follower_count = nil
  return n
end

function ControlEngine:setControlMode(game, mode)
  mode = mode or "follow"
  if mode == "lead" then mode = "lead_trainer" end
  local settings = self.settings
  if settings and type(settings.setEngineMode) == "function" then
    pcall(settings.setEngineMode, settings, game, mode)
  end
  if game and game.save then game.save.pokepcControlMode = mode end
  -- Invalidate; do not cache a second source of truth.
  self._optCache.control_mode = nil
  self._optCache.follow_control = nil
  self._optCache.trainer_trail = nil
end

function ControlEngine:isPokemonFront(game)
  local m = self:controlMode(game)
  return m == "pokemon" or m == "lead_trainer" or m == "pack"
end

function ControlEngine:clearLeader(game)
  if game and game.save then
    game.save.pokepcLeader = nil
    game.save.followerPartyIndex = nil
  end
end

function ControlEngine:bustLeaderVisual(game)
  local player = game and game.overworld and game.overworld.player
  if player then
    player._pokepcControlSpecies = nil
  end
end

function ControlEngine.monIdentityKey(mon)
  if not mon then return nil end
  local dvs = mon.dvs
  local dvKey = ""
  if type(dvs) == "table" then
    dvKey = table.concat({
      tostring(dvs.attack), tostring(dvs.defense),
      tostring(dvs.speed), tostring(dvs.special),
    }, ",")
  elseif dvs ~= nil then
    dvKey = tostring(dvs)
  end
  return table.concat({
    tostring(mon.species or ""),
    tostring(mon.level or ""),
    tostring(mon.nickname or ""),
    tostring(mon.otId or ""),
    dvKey,
  }, "|")
end

function ControlEngine:toggleStopFollowing(mon, game)
  if not mon then return end
  mon.stopFollowing = not mon.stopFollowing
  game = game or self:_game()
  local ow = game and game.overworld
  self:syncAll(game, ow)
  return mon.stopFollowing
end

-- Yellow: party[1] = talkable Pikachu; chosen leader → party[2]
-- (unless leader IS that Pikachu → stays slot 1).
function ControlEngine:ensureYellowLeaderLayout(game, leaderMon)
  if not self:_isYellow() then return nil end
  local save = game and game.save
  local party = save and save.party
  if not (party and leaderMon) then return nil end

  local pikaIdx = nil
  for i, mon in ipairs(party) do
    if mon and mon.species == "PIKACHU" then
      pikaIdx = i
      break
    end
  end
  if not pikaIdx then return nil end
  local pika = party[pikaIdx]

  local leadIdx = nil
  for i, mon in ipairs(party) do
    if mon == leaderMon then leadIdx = i; break end
  end
  if not leadIdx then
    local want = ControlEngine.monIdentityKey(leaderMon)
    for i, mon in ipairs(party) do
      if want and ControlEngine.monIdentityKey(mon) == want then
        leadIdx = i
        break
      end
    end
  end
  if not leadIdx then return nil end
  local lead = party[leadIdx]

  if lead == pika then
    if pikaIdx ~= 1 then
      table.remove(party, pikaIdx)
      table.insert(party, 1, pika)
    end
    return 1
  end

  local rest = {}
  for _, mon in ipairs(party) do
    if mon ~= pika and mon ~= lead then
      rest[#rest + 1] = mon
    end
  end
  local newParty = { pika, lead }
  for i = 1, #rest do
    newParty[#newParty + 1] = rest[i]
  end
  save.party = newParty
  return 2
end

function ControlEngine:setLeaderParty(game, partyIndex)
  if not game or not game.save then return end
  local mon = game.save.party and game.save.party[partyIndex]
  if self:_isYellow() and mon then
    local idx = self:ensureYellowLeaderLayout(game, mon)
    if type(idx) == "number" then partyIndex = idx end
  end
  game.save.pokepcLeader = { source = "party", index = partyIndex }
  game.save.followerPartyIndex = partyIndex
  if self.selection and type(self.selection.selectFollower) == "function" then
    local m = game.save.party and game.save.party[partyIndex]
    if m then pcall(self.selection.selectFollower, self.selection, m, game, {}) end
  end
  self:bustLeaderVisual(game)
end

function ControlEngine:setLeaderBox(game, boxNum, slotIndex)
  if not game or not game.save then return end
  game.save.pokepcLeader = {
    source = "box", box = boxNum, index = slotIndex,
  }
  self:bustLeaderVisual(game)
end

function ControlEngine:getLeaderMon(game)
  game = game or self:_game()
  if not game or not game.save then return nil end
  local save = game.save
  local lead = save.pokepcLeader

  -- Box leader always wins when explicitly set (selection is party-only).
  if lead and lead.source == "box" then
    local Boxes = tryRequire("src.pokemon.Boxes")
    if Boxes and Boxes.ensure then pcall(Boxes.ensure, save) end
    local boxes = save.boxes or {}
    local box = boxes[lead.box or save.currentBox or 1]
    local mon = box and box[lead.index]
    if mon then return mon, "box" end
  end

  -- Prefer Wilds selection when available.
  if self.selection and type(self.selection.getActiveFollowerMon) == "function" then
    local ok, mon, slot = pcall(self.selection.getActiveFollowerMon, self.selection, game, false)
    if ok and mon then return mon, "party", slot end
  end

  if lead and lead.source == "party" then
    local mon = save.party and save.party[lead.index]
    if mon and (mon.hp or 0) >= 0 then return mon, "party" end
  end

  local idx = save.followerPartyIndex
  if idx and save.party and save.party[idx] then
    local mon = save.party[idx]
    if not mon.stopFollowing then return mon, "party" end
  end

  if self:_isYellow() and save.party and save.party[1]
     and save.party[1].species == "PIKACHU" and save.party[2]
     and (save.party[2].hp or 0) > 0 then
    return save.party[2], "party"
  end
  for _, mon in ipairs(save.party or {}) do
    if (mon.hp or 0) > 0 then return mon, "party" end
  end
  return nil, "party"
end

function ControlEngine:getActiveFollowerMon(game)
  game = game or self:_game()
  if self.selection and type(self.selection.getActiveFollowerMon) == "function" then
    local ok, mon = pcall(self.selection.getActiveFollowerMon, self.selection, game, true)
    if ok and mon then return mon end
  end
  return (self:getLeaderMon(game))
end

function ControlEngine:_leaderPartyIndex(game, leader, leadSrc)
  local save = game and game.save
  if not save then return nil end
  local lead = save.pokepcLeader
  if lead and lead.source == "party" and type(lead.index) == "number" then
    return lead.index
  end
  if leadSrc == "party" and leader then
    for i, mon in ipairs(save.party or {}) do
      if mon == leader then return i end
    end
  end
  if type(save.followerPartyIndex) == "number" then
    return save.followerPartyIndex
  end
  return nil
end

function ControlEngine:_partyPikachuIndex(save)
  for i, mon in ipairs(save and save.party or {}) do
    if mon and mon.species == "PIKACHU" and (mon.hp or 0) > 0 then
      return i
    end
  end
  return nil
end

function ControlEngine:yellowStockFollowActive(game)
  if not self:_isYellow() then return false end
  if self:controlMode(game) ~= "follow" then return false end
  if self:followerCount(game) <= 0 then return false end
  local save = game and game.save
  return self:_partyPikachuIndex(save) ~= nil
end

function ControlEngine:_findStockPikachu(ow)
  for _, npc in ipairs((ow and ow.npcs) or {}) do
    if npc and npc.pikachuFollower and not npc.pokepcTrailer then
      return npc
    end
  end
  return nil
end

function ControlEngine:isYellowPikachuTrailer(npc)
  return npc and npc.pokepcTrailer and npc.pokepcMon
    and npc.pokepcMon.species == "PIKACHU"
    and self:_isYellow()
end

--- Resolve a follower sprite def via injected spriteService, or render fallback.
-- Never errors on missing PokéPC.
function ControlEngine:resolveFollowerSprite(opts)
  opts = opts or {}
  local svc = self.spriteService
  if svc and type(svc.resolveFollowerSprite) == "function" then
    local ok, def = pcall(svc.resolveFollowerSprite, svc, opts)
    if ok and def and def.image then return def end
  end

  local render = self.render
  local species = opts.species or "CHARMANDER"
  local shiny = opts.shiny == true
  local variant = shiny and "shiny" or "normal"
  local role = opts.role or "primary"
  local sheets = render and render.runtimeSheets
  if sheets then
    if not sheets.ready and sheets.load then pcall(function() sheets:load() end) end
    local dex = 4
    if svc and type(svc.dexOf) == "function" then
      local ok, d = pcall(svc.dexOf, svc, species)
      if ok and d then dex = d end
    else
      local AS
      pcall(function() AS = V.require("animated_sprites") end)
      if AS and AS.resolveSpeciesId then
        local ok, d = pcall(AS.resolveSpeciesId, species, nil, self.mod)
        if ok and d then dex = d end
      end
    end
    local id = (role == "player_controlled") and "SPRITE_PLAYER_POKEMON"
      or "SPRITE_WILDS_FOLLOWER_MON"
    if sheets.spriteDef then
      local ok, def = pcall(sheets.spriteDef, sheets, dex, variant, id)
      if ok and def and def.image then
        return {
          image = def.image,
          frames = def.frames or 6,
          walker = def.walker ~= false,
          trueColor = def.trueColor ~= false,
          id = def.id or id,
        }
      end
    end
  end

  local image = "assets/fallback/pokemon_missing.png"
  if render and type(render._modAssetPath) == "function" then
    local ok, path = pcall(render._modAssetPath, render, "assets/fallback/pokemon_missing.png")
    if ok and path then image = path end
  elseif self.mod and self.mod.path then
    image = self.mod.path .. "/assets/fallback/pokemon_missing.png"
  end
  return {
    image = image,
    frames = 1,
    walker = false,
    trueColor = true,
    id = Constants.SPRITE_ID,
  }
end

function ControlEngine:forceYellowStockPikachuArt(ow, game)
  if not self:_isYellow() then return end
  local npc = self:_findStockPikachu(ow)
  if not npc then return end
  game = game or self:_game()
  local mon = self:getActiveFollowerMon(game)
  local species = (mon and mon.species) or "PIKACHU"
  local resolved = self:resolveFollowerSprite({
    species = species,
    shiny = isShinyMon(mon),
    surface = "land",
    role = "primary",
    game = game,
  })
  if not (resolved and resolved.image) then return end
  local def = npc.sprite and npc.sprite.def
  local resolvedFrames = resolved.frames or 6
  local resolvedWalker = resolved.walker ~= false
  local resolvedTrueColor = resolved.trueColor ~= false
  if def and def.image == resolved.image
     and (def.id or Constants.SPRITE_ID) == Constants.SPRITE_ID
     and (def.frames or 1) == resolvedFrames
     and (def.walker == true) == resolvedWalker
     and (def.trueColor == nil or def.trueColor == resolvedTrueColor) then
    npc._pokepcFollowerSpecies = species
    npc._wildsFollowerSpecies = species
    return
  end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new) then return end

  local preserved = {
    facing = npc.facing,
    moving = npc.moving,
    cellX = npc.cellX,
    cellY = npc.cellY,
    px = npc.px,
    py = npc.py,
    targetX = npc.targetX,
    targetY = npc.targetY,
    progress = npc.progress,
    marching = npc.marching,
    hopStep = npc.hopStep,
    idle = npc.idle,
    goalX = npc.goalX,
    goalY = npc.goalY,
  }
  local ok, sprite = pcall(SpriteRenderer.new, {
    id = Constants.SPRITE_ID,
    image = resolved.image,
    frames = resolvedFrames,
    walker = resolvedWalker,
    trueColor = resolvedTrueColor,
  }, npc.id or Constants.ENTITY_ID)
  if ok and sprite then
    npc.sprite = sprite
    npc.spriteId = Constants.SPRITE_ID
    npc.facing = preserved.facing
    npc.moving = preserved.moving
    npc.cellX, npc.cellY = preserved.cellX, preserved.cellY
    npc.px, npc.py = preserved.px, preserved.py
    npc.targetX, npc.targetY = preserved.targetX, preserved.targetY
    npc.progress = preserved.progress
    npc.marching = preserved.marching
    npc.hopStep = preserved.hopStep
    npc.idle = preserved.idle
    npc.goalX, npc.goalY = preserved.goalX, preserved.goalY
    npc._pokepcFollowerSpecies = species
    npc._wildsFollowerSpecies = species
  end
end

function ControlEngine:_trailAnchor(game, ow, player)
  -- Surf: always follow the moving player. Stock Yellow Pikachu is suppressed
  -- while surfing and must never be a frozen trail anchor.
  if self:_playerSurfing(ow, game) then
    return player
  end
  if self:yellowStockFollowActive(game) then
    local stock = self:_findStockPikachu(ow)
    if stock and not stock.frozen and (stock.cellX ~= nil) then
      return stock
    end
  end
  return player
end

--- Stock PikachuFollower spawn gate (may be false while surfing).
-- Must NOT gate Wilds trailer updates.
function ControlEngine:shouldSpawnStockFollower(game, ow)
  return self:_shouldSpawnStockFollower(game, ow)
end

--- Wilds trailers / control visuals must keep ticking even when stock is off.
function ControlEngine:shouldUpdateWildsTrailers(game, ow)
  if not (ow and ow.map and ow.player) then return false end
  local mode = self:controlMode(game)
  if mode == "pokemon" or mode == "lead_trainer" or mode == "pack"
      or mode == "follow" then
    return true
  end
  return type(ow.pokepcTrailers) == "table" and #ow.pokepcTrailers > 0
end

function ControlEngine:partyTrailMons(game)
  local n = self:followerCount(game)
  if n <= 0 then return {} end

  local save = game and game.save
  if not save then return {} end

  local leader, leadSrc = self:getLeaderMon(game)
  local leadIdx = self:_leaderPartyIndex(game, leader, leadSrc)
  local leadKey = ControlEngine.monIdentityKey(leader)
  local front = self:isPokemonFront(game)

  -- Identify if stock Pikachu is active to prevent duplicate rendering
  local isStockPikaActive = self:yellowStockFollowActive(game)
  local skipPikaIdx = isStockPikaActive and self:_partyPikachuIndex(save) or nil

  local out = {}
  local function push(mon, i)
    out[#out + 1] = { mon = mon, partyIndex = i }
  end

  local function isControlledLeader(mon, i)
    if not mon then return false end
    if leadIdx and i == leadIdx then return true end
    if leader and mon == leader then return true end
    if leadKey and ControlEngine.monIdentityKey(mon) == leadKey then return true end
    return false
  end

  local function skipMon(i, mon)
    if skipPikaIdx and i == skipPikaIdx then return true end
    if mon and mon.stopFollowing == true then return true end
    return false
  end

  if not front and leader then
    if leadIdx and save.party and save.party[leadIdx]
       and (save.party[leadIdx].hp or 0) > 0
       and not skipMon(leadIdx, save.party[leadIdx]) then
      push(save.party[leadIdx], leadIdx)
    else
      for i, mon in ipairs(save.party or {}) do
        if isControlledLeader(mon, i) and (mon.hp or 0) > 0
           and not skipMon(i, mon) then
          push(mon, i)
          break
        end
      end
    end
  end

  for i, mon in ipairs(save.party or {}) do
    if (mon.hp or 0) > 0 and not isControlledLeader(mon, i)
       and not skipMon(i, mon) then
      push(mon, i)
    end
  end

  -- If stock Pikachu is active, it fills slot 1.
  -- Subtract 1 from extra trailers so total visible followers equals `n`.
  local maxTrailers = isStockPikaActive and math.max(0, n - 1) or n
  while #out > maxTrailers do out[#out] = nil end

  return out
end

function ControlEngine:_trainerWalkDef(game)
  local FieldDefaults = tryRequire("src.world.FieldDefaults")
  local data = game and game.data
  if not (data and FieldDefaults and FieldDefaults.fieldValue) then return nil end
  local walkId = FieldDefaults.fieldValue(data, "playerSprites", "walk")
  return walkId and data.sprites and data.sprites[walkId]
end

function ControlEngine:restorePlayerTrainerSprite(game, ow)
  local player = ow and ow.player
  if not player or not game or not game.data then return end
  local monSprite = player._pokepcAsPokemon
    or (player.sprite and player.sprite.def
        and player.sprite.def.id == "SPRITE_PLAYER_POKEMON")
  if not monSprite then return end
  local def = self:_trainerWalkDef(game)
  if not def then return end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new) then return end
  local ok, sprite = pcall(SpriteRenderer.new, def, "player")
  if ok and sprite then
    player.sprite = sprite
    player._pokepcAsPokemon = nil
    player._pokepcControlSpecies = nil
    player._pokepcShiny = nil
  end
end

function ControlEngine:applyPlayerAsPokemon(game, ow, force)
  local player = ow and ow.player
  if not player then return end
  if player.surfing or player.onBike or player.fishing then
    self:restorePlayerTrainerSprite(game, ow)
    return
  end
  local mon = self:getLeaderMon(game)
  local species = mon and mon.species or "CHARMANDER"
  local shiny = isShinyMon(mon)
  local resolved = self:resolveFollowerSprite({
    species = species,
    shiny = shiny,
    surface = "land",
    role = "player_controlled",
    game = game,
  })
  local path = resolved and resolved.image
  if not force and player._pokepcAsPokemon and player._pokepcControlSpecies == species
     and player._pokepcShiny == (shiny and true or false)
     and player.sprite and player.sprite.def
     and player.sprite.def.image == path then
    return
  end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new and path) then return end
  local ok, sprite = pcall(SpriteRenderer.new, {
    id = "SPRITE_PLAYER_POKEMON",
    image = path,
    frames = (resolved and resolved.frames) or 6,
    walker = not resolved or resolved.walker ~= false,
    trueColor = not resolved or resolved.trueColor ~= false,
    pokepcShiny = shiny and true or false,
  }, "player")
  if ok and sprite then
    player.sprite = sprite
    player._pokepcAsPokemon = true
    player._pokepcControlSpecies = species
    player._pokepcShiny = shiny and true or false
  end
end

function ControlEngine:syncPlayerControlVisual(game, ow, force)
  if self:isPokemonFront(game) then
    self:applyPlayerAsPokemon(game, ow, force)
  else
    self:restorePlayerTrainerSprite(game, ow)
  end
end

function ControlEngine:removeTrailers(ow)
  if not ow then return end
  local keepNpcs, keepEnt = {}, {}
  for _, npc in ipairs(ow.npcs or {}) do
    if not npc.pokepcTrailer then keepNpcs[#keepNpcs + 1] = npc end
  end
  for _, e in ipairs(ow.entities or {}) do
    if not e.pokepcTrailer then keepEnt[#keepEnt + 1] = e end
  end
  ow.npcs, ow.entities = keepNpcs, keepEnt
  ow.pokepcTrailers = {}
  ow.pokepcTrailCells = {}
end

function ControlEngine:ledgeStep(game, ow, cx, cy, dir)
  local Collision = tryRequire("src.world.Collision")
  if not (game and ow and ow.map and dir and Collision and Collision.DELTA
          and Collision.DELTA[dir]) then
    return false
  end
  local map = ow.map
  local d = Collision.DELTA[dir]
  local fx, fy = cx + d[1], cy + d[2]
  local lx, ly = cx + d[1] * 2, cy + d[2] * 2
  if not (map:inBounds(fx, fy) and map:inBounds(lx, ly)) then return false end
  local tileset = map.def and map.def.tileset
  local standing = map:cellTile(cx, cy)
  local front = map:cellTile(fx, fy)
  local landing = map:cellTile(lx, ly)
  local opposite = { up = "down", down = "up", left = "right", right = "left" }
  local ledges = game.data and game.data.field and game.data.field.ledges
  for _, ledge in ipairs(ledges or {}) do
    if (ledge.tileset or "OVERWORLD") == tileset and ledge.ledgeTile == front then
      if ledge.facing == dir and ledge.input == dir
         and ledge.standingTile == standing then
        return true
      end
      -- Reverse-jump mods traverse the same physical ledge against the stock
      -- one-way declaration. From that side, the declared standing tile is
      -- the follower's landing tile and the blocked middle tile is unchanged.
      local reverse = opposite[dir]
      if ledge.facing == reverse and ledge.input == reverse
         and ledge.standingTile == landing then
        return true
      end
    end
  end
  return false
end

function ControlEngine:makeTrailer(game, ow, x, y, facing, kind, mon, slot)
  local NPC = tryRequire("src.world.NPC")
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (NPC and NPC.new) then return nil end

  local npc = NPC.new(game.data, ow.map.id, {
    index = TRAILER_BASE + slot,
    name = "WILDS_TRAILER_" .. tostring(slot),
    sprite = Constants.SPRITE_ID,
    movement = "STAY", range = "NONE", x = x, y = y,
  })
  -- Legacy occupancy/water compat + Wilds role markers.
  npc.pokepcTrailer = true
  npc.wildsFollower = true
  npc.wildsFollowerRole = (kind == "trainer") and "trainer_trailer" or "party_trailer"
  npc.pokepcTrailerKind = kind
  npc.pokepcTrailerId = kind .. ":" .. tostring(slot)
  npc.pokepcMon = mon
  npc.passable = true
  npc.facing = facing or "down"
  -- NEVER set pikachuFollower on trailers (stock findFollower would remove them).
  npc.pikachuFollower = false
  npc.pokepcTalkablePikachu = (kind ~= "trainer"
    and self:_isYellow()
    and mon and mon.species == "PIKACHU") and true or false

  if kind == "trainer" then
    -- Walk sheets are DMG greyscale; trueColor would draw raw greys.
    local def = self:_trainerWalkDef(game)
    if def and SpriteRenderer and SpriteRenderer.new then
      local ok, sprite = pcall(SpriteRenderer.new, {
        id = def.id or "SPRITE_RED",
        image = def.image,
        frames = def.frames or 6,
        walker = def.walker ~= false,
        source = def.source,
        paletteSource = def.paletteSource,
      }, npc.id)
      if ok and sprite then npc.sprite = sprite end
    end
  else
    local species = mon and mon.species or "CHARMANDER"
    local shiny = isShinyMon(mon)
    npc.pokepcShiny = shiny and true or false
    local resolved = self:resolveFollowerSprite({
      species = species,
      shiny = shiny,
      form = mon and mon.form,
      surface = "land",
      role = "party_trailer",
      game = game,
    })
    if resolved and resolved.image and SpriteRenderer and SpriteRenderer.new then
      local ok, sprite = pcall(SpriteRenderer.new, {
        id = resolved.id or "SPRITE_WILDS_FOLLOWER_MON",
        image = resolved.image,
        frames = resolved.frames or 6,
        walker = resolved.walker ~= false,
        trueColor = resolved.trueColor ~= false,
        pokepcShiny = npc.pokepcShiny,
      }, npc.id)
      if ok and sprite then npc.sprite = sprite end
    end
    npc._wildsFollowerSpecies = species
  end

  if NPC.walkPhase then
    npc.walkPhase = function(ent)
      if ent.moving then
        return NPC.walkPhase(ent)
      end
      return 0
    end
  end

  -- ControlEngine owns trailer interpolation exclusively. Exclude trailers
  -- from the stock NPC auto-step so OverworldController's npc loop cannot
  -- double-advance (or reject) water steps.
  npc.update = function() end
  local basePose = npc.pose
  if type(basePose) == "function" then
    npc.pose = function(ent)
      local sprite, px, py, face, phase, flip = basePose(ent)
      local hopping = ent.hopStep == true and ent.moving == true
      if hopping then
        local total = math.max(1, tonumber(ent.stepFrames) or 16)
        local t = math.min(1, math.max(0,
          (tonumber(ent.progress) or 0) / total))
        py = py - math.floor(10 * math.sin(t * math.pi) + 0.5)
      end
      return sprite, px, py, face, phase, flip, hopping
    end
  end
  npc._wildsFollowerStep = true
  npc._wildsFollowerStepOwned = true
  return npc
end

local function behindOffset(facing, steps)
  local dx = facing == "left" and 1 or facing == "right" and -1 or 0
  local dy = facing == "up" and 1 or facing == "down" and -1 or 0
  return dx * steps, dy * steps
end

function ControlEngine:_playerSurfing(ow, game)
  local player = ow and ow.player
  if not player then return false end
  if player.surfing == true or player.isSurfing == true then return true end
  if player.surface == "water" or player.surface == "WATER" then return true end
  if game and game.player and game.player.surfing == true then return true end
  return false
end

function ControlEngine:_trailSurface(ow, game)
  if self:_playerSurfing(ow, game) then return "water" end
  return "land"
end

local function isWaterMapCell(map, x, y)
  if not (map and map.isWaterCell) then return false end
  local ok, water = pcall(map.isWaterCell, map, x, y)
  return ok and water == true
end

local function isLandWalkable(map, x, y)
  if not (map and map.isWalkableCell) then return false end
  local ok, walk = pcall(map.isWalkableCell, map, x, y)
  return ok and walk == true
end

local function mapContainsCell(map, x, y)
  if not (map and type(map.inBounds) == "function") then return false end
  local ok, inside = pcall(map.inBounds, map, x, y)
  return ok and inside == true
end

--- Resolve a trailer cell in the current map's coordinate frame.
-- During a seamless connection, trailers may still be standing on the map
-- behind the player.  Neighbor offsets are pixels relative to the current
-- map, so translate the cell back to that neighbor's local coordinates.
-- Outside an active handoff, follower checks remain current-map-only.
function ControlEngine:_followerMapCell(ow, x, y)
  local map = ow and ow.map
  if mapContainsCell(map, x, y) then return map, x, y end
  if not (ow and ow._wildsFollowerSeamActive) then return nil end
  for _, nb in ipairs(ow.neighbors or {}) do
    local nmap = nb and nb.map
    local ox = tonumber(nb and nb.ox)
    local oy = tonumber(nb and nb.oy)
    if nmap and ox and oy then
      local nx = x - ox / 16
      local ny = y - oy / 16
      if nx == math.floor(nx) and ny == math.floor(ny)
         and mapContainsCell(nmap, nx, ny) then
        return nmap, nx, ny
      end
    end
  end
  return nil
end

--- Surface-aware cell check for Wilds Pokémon trailers only.
-- Never used for trainers/wilds/global NPC collision.
-- context.surface: "land" | "water" | "land_to_water" | "water_to_land"
-- context.role: wildsFollowerRole override when entity is not yet created
function ControlEngine:isFollowerCellAllowed(game, ow, entity, x, y, context)
  context = context or {}
  if not (ow and ow.map) then return false end
  local map, mapX, mapY = self:_followerMapCell(ow, x, y)
  if not map then return false end

  local role = context.role
    or (entity and entity.wildsFollowerRole)
    or (entity and entity.pokepcTrailerKind == "trainer" and "trainer_trailer")
    or (entity and (entity.pikachuFollower == true or entity.wildsFollower == true)
        and "primary")
    or "party_trailer"

  -- Water exception only for Pokémon follower roles.
  local pokemonRole = (role == "primary" or role == "party_trailer")
  if not pokemonRole then
    return isLandWalkable(map, mapX, mapY)
  end

  local surface = context.surface or self:_trailSurface(ow, game)
  if surface == "water" or surface == "land_to_water" then
    -- Surf path: water cells the player can occupy, plus shore land for entry.
    if isWaterMapCell(map, mapX, mapY) then return true end
    if isLandWalkable(map, mapX, mapY) then return true end
    return false
  end

  if surface == "water_to_land" then
    if isLandWalkable(map, mapX, mapY) then return true end
    if isWaterMapCell(map, mapX, mapY) then return true end
    return false
  end

  -- Land: normal walkability. Allow current water cell so a surfing trailer
  -- can step onto shore without freezing when the player exits water.
  if isLandWalkable(map, mapX, mapY) then return true end
  if entity and (entity.wildsFollowerWater == true or entity.spriteState == "water")
      and isWaterMapCell(map, mapX, mapY) then
    return true
  end
  return false
end

local function copyTrailCells(cells)
  local out = {}
  for i, cell in ipairs(cells or {}) do
    out[i] = { x = cell.x, y = cell.y }
  end
  return out
end

local function copyTrailHead(head)
  if not head then return nil end
  return {
    x = head.x, y = head.y,
    ledgeHop = head.ledgeHop,
    ledgeLandingPending = head.ledgeLandingPending,
  }
end

local function addIdentity(list, value)
  if not value then return end
  for _, existing in ipairs(list) do
    if existing == value then return end
  end
  list[#list + 1] = value
end

local function translateTrailer(npc, dx, dy)
  npc.cellX, npc.cellY = (npc.cellX or 0) + dx, (npc.cellY or 0) + dy
  npc.px, npc.py = (npc.px or (npc.cellX - dx) * 16) + dx * 16,
                   (npc.py or (npc.cellY - dy) * 16) + dy * 16
  if npc.targetX ~= nil then npc.targetX = npc.targetX + dx end
  if npc.targetY ~= nil then npc.targetY = npc.targetY + dy end
  if npc.goalX ~= nil then npc.goalX = npc.goalX + dx end
  if npc.goalY ~= nil then npc.goalY = npc.goalY + dy end
end

function ControlEngine:_isOutsideMap(game, map)
  if not (map and map.def) then return false end
  local Map = tryRequire("src.world.Map")
  local FieldDefaults = tryRequire("src.world.FieldDefaults")
  if Map and type(Map.isOutside) == "function" then
    local tilesets
    if FieldDefaults and type(FieldDefaults.field) == "function"
       and game and game.data then
      local ok, value = pcall(FieldDefaults.field, game.data, "outsideTilesets")
      if ok then tilesets = value end
    end
    local ok, outside = pcall(Map.isOutside, map.def, tilesets)
    if ok then return outside == true end
  end
  if map.def.outdoor ~= nil then return map.def.outdoor == true end
  return map.def.tileset == "OVERWORLD" or map.def.tileset == "PLATEAU"
end

--- Capture live trailers before setMap replaces the entity lists.
function ControlEngine:_captureMapExit(game, ow, ev)
  local trailers = ow and ow.pokepcTrailers
  local player = ow and ow.player
  if not (player and trailers and #trailers > 0) then
    self._mapExitSnapshot = nil
    return false
  end
  local refs = {}
  for i, trailer in ipairs(trailers) do refs[i] = trailer end
  self._mapExitSnapshot = {
    fromMapId = ev and ev.mapId or (ow.map and ow.map.id),
    toMapId = ev and ev.toMapId,
    map = ow.map,
    playerX = player.cellX,
    playerY = player.cellY,
    trailers = refs,
    trailCells = copyTrailCells(ow.pokepcTrailCells),
    trailHead = copyTrailHead(ow.pokepcTrailHead),
  }
  return true
end

--- Select seamless outside-to-outside entries for a soft handoff.
function ControlEngine:_queueMapEntry(game, ow, ev)
  local snapshot = self._mapExitSnapshot
  self._mapExitSnapshot = nil
  self._pendingConnectionHandoff = nil
  if ow then ow._wildsFollowerSeamActive = nil end
  if not (snapshot and ev and ev.via == "connection") then return false end
  if snapshot.toMapId and ev.mapId and snapshot.toMapId ~= ev.mapId then
    return false
  end
  if not (self:_isOutsideMap(game, snapshot.map)
          and self:_isOutsideMap(game, (ev and ev.map) or (ow and ow.map))) then
    return false
  end
  self._pendingConnectionHandoff = snapshot
  return true
end

--- Reattach and translate the preserved train after crossConnection has put
-- the player at the pre-seam cell and rebuilt the destination's neighbors.
function ControlEngine:_applyConnectionHandoff(ow)
  local snapshot = self._pendingConnectionHandoff
  self._pendingConnectionHandoff = nil
  local player = ow and ow.player
  if not (snapshot and player and snapshot.trailers and #snapshot.trailers > 0) then
    return false
  end
  local dx = (player.cellX or 0) - (snapshot.playerX or 0)
  local dy = (player.cellY or 0) - (snapshot.playerY or 0)
  ow.npcs = ow.npcs or {}
  ow.entities = ow.entities or {}
  for _, trailer in ipairs(snapshot.trailers) do
    translateTrailer(trailer, dx, dy)
    addIdentity(ow.npcs, trailer)
    addIdentity(ow.entities, trailer)
  end
  for _, cell in ipairs(snapshot.trailCells or {}) do
    cell.x, cell.y = cell.x + dx, cell.y + dy
  end
  local head = snapshot.trailHead
  if head then head.x, head.y = head.x + dx, head.y + dy end
  ow.pokepcTrailers = snapshot.trailers
  ow.pokepcTrailCells = snapshot.trailCells
  ow.pokepcTrailHead = head or { x = player.cellX, y = player.cellY }
  ow._wildsFollowerSeamActive = true
  self._pendingMapTrailerSync = false
  return true
end

function ControlEngine:_finishConnectionHandoffIfComplete(ow)
  if not (ow and ow._wildsFollowerSeamActive and ow.map) then return false end
  local trailers = ow.pokepcTrailers or {}
  local goals = ow.pokepcTrailCells or {}
  local occupied = {}
  if #trailers == 0 or #goals < #trailers then return false end
  for i, trailer in ipairs(trailers) do
    if not mapContainsCell(ow.map, trailer.cellX, trailer.cellY) then return false end
    if trailer.moving then return false end
    if trailer.targetX ~= nil
       and not mapContainsCell(ow.map, trailer.targetX, trailer.targetY) then
      return false
    end
    local key = tostring(trailer.cellX) .. "," .. tostring(trailer.cellY)
    if occupied[key] then return false end
    occupied[key] = true
    local goal = goals[i]
    if not (goal and mapContainsCell(ow.map, goal.x, goal.y)) then return false end
    if trailer.cellX ~= goal.x or trailer.cellY ~= goal.y then return false end
  end
  ow._wildsFollowerSeamActive = nil
  return true
end

function ControlEngine:_walkableBehind(ow, px, py, facing, steps, entity, game, role, occupied)
  local surface = self:_trailSurface(ow, game)
  local ctx = { surface = surface, role = role }
  local ox, oy = behindOffset(facing, steps)
  local bx, by = px + ox, py + oy
  local function free(x, y)
    if occupied and occupied[x .. "," .. y] then return false end
    return self:isFollowerCellAllowed(game, ow, entity, x, y, ctx)
  end
  if free(bx, by) then
    return bx, by
  end
  bx, by = px, py
  for s = math.max(steps, 1), 1, -1 do
    local sx, sy = behindOffset(facing, s)
    local tx, ty = px + sx, py + sy
    if free(tx, ty) then
      return tx, ty
    end
  end
  -- Prefer any free cell further back along the trail axis.
  for s = steps + 1, steps + 6 do
    local sx, sy = behindOffset(facing, s)
    local tx, ty = px + sx, py + sy
    if free(tx, ty) then
      return tx, ty
    end
  end
  return bx, by
end

local function placeTrailerAt(npc, x, y, facing)
  npc.cellX, npc.cellY = x, y
  npc.px, npc.py = x * 16, y * 16
  npc.targetX, npc.targetY = nil, nil
  npc.moving = false
  npc.progress = 0
  npc.hopStep = nil
  if facing then npc.facing = facing end
end

--- Advance a trailer step without stock NPC land-walkability rejection.
-- Uses the same fields as NPC movement (target/moving/progress/px/py).
-- Timing: one progress tick per ControlEngine:update (logic frame), matching
-- stock NPC:update — not present/render FPS.
function ControlEngine.advanceTrailerStep(npc, _map, _entities, diag)
  if not npc or not npc.moving then return false end
  local toX, toY = npc.targetX, npc.targetY
  if toX == nil or toY == nil then
    npc.moving = false
    npc.progress = 0
    return false
  end
  if diag then
    diag.advanceTrailerStepCalls = (diag.advanceTrailerStepCalls or 0) + 1
  end
  local frames = tonumber(npc.stepFrames) or 16
  if frames < 1 then frames = 1 end
  npc.progress = (tonumber(npc.progress) or 0) + 1
  local fromX = tonumber(npc.cellX) or 0
  local fromY = tonumber(npc.cellY) or 0
  local t = npc.progress / frames
  if t > 1 then t = 1 end
  npc.px = (fromX + (toX - fromX) * t) * 16
  npc.py = (fromY + (toY - fromY) * t) * 16
  if npc.progress >= frames then
    npc.cellX, npc.cellY = toX, toY
    npc.px, npc.py = toX * 16, toY * 16
    npc.targetX, npc.targetY = nil, nil
    npc.moving = false
    npc.progress = 0
    npc.hopStep = nil
    if npc.stepFlip ~= nil then
      npc.stepFlip = not npc.stepFlip
    end
    npc.walkFlip = npc.stepFlip == true
    npc.flip = npc.stepFlip == true
  end
  return true
end

function ControlEngine:_seedTrailBehind(ow, anchor, facing, n, game, role)
  local goals = {}
  local occupied = {}
  local px = anchor.cellX or 0
  local py = anchor.cellY or 0
  facing = facing or anchor.facing or "down"
  role = role or "party_trailer"
  -- Anchor cell is occupied by the player / stock leader.
  occupied[px .. "," .. py] = true
  for i = 1, n do
    local bx, by = self:_walkableBehind(ow, px, py, facing, i, nil, game, role, occupied)
    goals[i] = { x = bx, y = by }
    occupied[bx .. "," .. by] = true
  end
  return goals
end

local function trailersAliveInWorld(ow, trailers)
  if not trailers or #trailers == 0 then return true end
  local ents = ow.entities or {}
  for _, t in ipairs(trailers) do
    local found = false
    for _, e in ipairs(ents) do
      if e == t then found = true; break end
    end
    if not found then return false end
  end
  return true
end

local function compositionDirty(trailers, want)
  if #trailers ~= #want then return true end
  for i, spec in ipairs(want) do
    local t = trailers[i]
    if not t or t.pokepcTrailerKind ~= spec.kind then return true end
    if spec.kind == "mon" then
      local sp = spec.mon and spec.mon.species
      local cur = t.pokepcMon and t.pokepcMon.species
      if sp ~= cur then return true end
    end
  end
  return false
end

function ControlEngine:syncTrailers(game, ow, opts)
  opts = opts or {}
  if not ow or not ow.player or not ow.map then return end
  self.diag.syncTrailersCalls = (self.diag.syncTrailersCalls or 0) + 1
  local mode = self:controlMode(game)
  local want = {}
  local surfing = self:_playerSurfing(ow, game)
  local surface = surfing and "water" or "land"

  -- Solo "pokemon" with a pack size still trails party mons (no trainer NPC).
  if mode == "pokemon" and self:followerCount(game) > 0 then
    mode = "pack"
  end

  if mode == "lead_trainer" then
    for _, entry in ipairs(self:partyTrailMons(game)) do
      want[#want + 1] = { kind = "mon", mon = entry.mon }
    end
    -- Trainer trailers must not swim: hide while surfing, restore on land.
    if not surfing then
      want[#want + 1] = { kind = "trainer", mon = nil }
    end
  elseif mode == "follow" or mode == "pack" then
    for _, entry in ipairs(self:partyTrailMons(game)) do
      want[#want + 1] = { kind = "mon", mon = entry.mon }
    end
  end

  local trailers = ow.pokepcTrailers or {}
  -- Reassert movement ownership on hot-reloaded / legacy trailer instances.
  for _, npc in ipairs(trailers) do
    if npc and npc.pokepcTrailer then
      npc.update = function() end
      npc._wildsFollowerStepOwned = true
      npc._wildsFollowerStep = true
    end
  end
  local dirty = compositionDirty(trailers, want)
    or not trailersAliveInWorld(ow, trailers)

  local p = ow.player
  local anchor = self:_trailAnchor(game, ow, p)
  local facing = (anchor and anchor.facing) or p.facing or "down"
  local mapEnter = opts.mapEnter == true
  local stepClock = p.stepFramesCur or p.stepFrames
    or (anchor and (anchor.stepFramesCur or anchor.stepFrames)) or 16

  -- Surface transition: reseed once so trail goals leave the frozen shore cell.
  local prevSurface = ow._wildsFollowerTrailSurface
  if prevSurface ~= surface then
    mapEnter = true
    ow._wildsFollowerTrailSurface = surface
  end

  if not dirty and self:yellowStockFollowActive(game) and anchor ~= p
     and #trailers > 0 then
    local t1 = trailers[1]
    if t1 and not t1.moving
       and t1.cellX == anchor.cellX and t1.cellY == anchor.cellY then
      mapEnter = true
    end
  end

  if dirty then
    self:removeTrailers(ow)
    trailers = {}
    local goals = self:_seedTrailBehind(ow, anchor, facing, #want, game, "party_trailer")
    for i, spec in ipairs(want) do
      local role = (spec.kind == "trainer") and "trainer_trailer" or "party_trailer"
      local cell = goals[i]
      if not cell or not self:isFollowerCellAllowed(game, ow, nil, cell.x, cell.y, {
        surface = surface, role = role,
      }) then
        local bx, by = self:_walkableBehind(ow, anchor.cellX or 0, anchor.cellY or 0,
                                           facing, i, nil, game, role)
        cell = { x = bx, y = by }
      end
      local bx, by = cell.x, cell.y
      local okNpc, npc = pcall(function()
        return self:makeTrailer(game, ow, bx, by, facing, spec.kind, spec.mon, i)
      end)
      if not okNpc or not npc then
        logWarn(self.mod, "trailer spawn failed slot %s: %s", tostring(i), tostring(npc))
      else
        placeTrailerAt(npc, bx, by, facing)
        table.insert(ow.npcs, npc)
        table.insert(ow.entities, npc)
        local slot = #trailers + 1
        trailers[slot] = npc
        goals[slot] = { x = bx, y = by }
      end
    end
    ow.pokepcTrailers = trailers
    ow.pokepcTrailCells = goals
    ow.pokepcTrailHead = { x = anchor.cellX, y = anchor.cellY }
  elseif mapEnter and #trailers > 0 then
    local goals = self:_seedTrailBehind(ow, anchor, facing, #trailers, game, "party_trailer")
    for i, npc in ipairs(trailers) do
      local role = npc.wildsFollowerRole or "party_trailer"
      local g = goals[i]
      if not g or not self:isFollowerCellAllowed(game, ow, npc, g.x, g.y, {
        surface = surface, role = role,
      }) then
        local bx, by = self:_walkableBehind(ow, anchor.cellX or 0, anchor.cellY or 0,
                                           facing, i, npc, game, role)
        g = { x = bx, y = by }
        goals[i] = g
      end
      placeTrailerAt(npc, g.x, g.y, facing)
      if want[i] and want[i].kind == "mon" then
        npc.pokepcMon = want[i].mon
      end
    end
    ow.pokepcTrailCells = goals
    ow.pokepcTrailHead = { x = anchor.cellX, y = anchor.cellY }
  end

  local destX = anchor.targetX or anchor.cellX
  local destY = anchor.targetY or anchor.cellY
  ow.pokepcTrailHead = ow.pokepcTrailHead
    or { x = anchor.cellX, y = anchor.cellY, ledgeHop = nil }
  local head = ow.pokepcTrailHead
  local committed = (destX ~= head.x or destY ~= head.y)
  if committed then
    local stepDir = destY > head.y and "down" or destY < head.y and "up"
                    or destX > head.x and "right" or "left"
    if head.ledgeHop == stepDir then
      head.ledgeHop = nil
      -- The engine executes a ledge jump as two scripted one-cell moves. The
      -- first phase releases only the takeoff cell. Keep the trainer's landing
      -- reserved on the second phase; publishing it now makes follower one
      -- jump concurrently and land on top of the trainer.
      head.ledgeLandingPending = true
      head.x, head.y = destX, destY
    else
      -- The first step away from a ledge landing releases that cell into the
      -- ordinary trail shift. Follower one can then hop into it while the
      -- trainer vacates it, and each later follower repeats that cadence.
      local leavingLedgeLanding = head.ledgeLandingPending == true
      head.ledgeLandingPending = nil
      -- Ledge hops are land-only; skip on water and do not reclassify the
      -- trainer's first ordinary post-hop step.
      if surface ~= "water" and not leavingLedgeLanding then
        head.ledgeHop = self:ledgeStep(game, ow, head.x, head.y, stepDir)
                        and stepDir or nil
      else
        head.ledgeHop = nil
      end
      local goals = ow.pokepcTrailCells or {}
      for i = #trailers, 2, -1 do
        local prev = goals[i - 1]
        goals[i] = prev and { x = prev.x, y = prev.y }
          or { x = head.x, y = head.y }
      end
      if #trailers >= 1 then
        goals[1] = { x = head.x, y = head.y }
      end
      ow.pokepcTrailCells = goals
      head.x, head.y = destX, destY
    end
  elseif not mapEnter and not dirty and not ow._wildsFollowerSeamActive then
    return
  end

  local Collision = tryRequire("src.world.Collision")
  local goals = ow.pokepcTrailCells or {}
  -- A translated train can momentarily become geometrically out of order
  -- while its members catch up at different speeds. During seam settlement,
  -- reserve both occupied cells and in-flight targets so no trailer can enter
  -- a cell until its current occupant has actually vacated it.
  local seamReservations
  if ow._wildsFollowerSeamActive then
    seamReservations = {}
    if p.moving and p.targetX ~= nil and p.targetY ~= nil then
      -- The convoy may enter the trainer's origin on the same cadence while
      -- the trainer vacates it; reserve only the trainer's destination.
      seamReservations[tostring(p.targetX) .. "," .. tostring(p.targetY)] = p
    elseif p.cellX ~= nil and p.cellY ~= nil then
      seamReservations[tostring(p.cellX) .. "," .. tostring(p.cellY)] = p
    end
    for _, trailer in ipairs(trailers) do
      if not trailer.moving and trailer.cellX ~= nil and trailer.cellY ~= nil then
        seamReservations[tostring(trailer.cellX) .. "," .. tostring(trailer.cellY)] = trailer
      end
      if trailer.moving and trailer.targetX ~= nil and trailer.targetY ~= nil then
        seamReservations[tostring(trailer.targetX) .. "," .. tostring(trailer.targetY)] = trailer
      end
    end
  end
  local function seamCellFree(x, y, npc)
    if not seamReservations then return true end
    local owner = seamReservations[tostring(x) .. "," .. tostring(y)]
    return owner == nil or owner == npc
  end
  local function reserveSeamCell(x, y, npc)
    if seamReservations then
      seamReservations[tostring(x) .. "," .. tostring(y)] = npc
    end
  end
  local function releaseSeamCell(x, y, npc)
    if seamReservations then
      local key = tostring(x) .. "," .. tostring(y)
      if seamReservations[key] == npc then seamReservations[key] = nil end
    end
  end
  for i, npc in ipairs(trailers) do
    if npc.moving then
      -- Trailer update owns px/py mid-step; do not overwrite.
    else
      local cell = goals[i] or { x = anchor.cellX, y = anchor.cellY }
      local gx, gy = cell.x, cell.y
      local role = npc.wildsFollowerRole or "party_trailer"
      if not self:isFollowerCellAllowed(game, ow, npc, gx, gy, {
        surface = surface, role = role,
      }) then
        -- Goal invalid for this surface: re-pick a valid cell behind the player.
        gx, gy = self:_walkableBehind(ow, anchor.cellX or 0, anchor.cellY or 0,
                                      facing, i, npc, game, role)
        goals[i] = { x = gx, y = gy }
      end
      if npc.cellX ~= gx or npc.cellY ~= gy then
        local far = math.abs((npc.cellX or 0) - gx) + math.abs((npc.cellY or 0) - gy)
        if far > 6 and not seamReservations and seamCellFree(gx, gy, npc) then
          releaseSeamCell(npc.cellX, npc.cellY, npc)
          placeTrailerAt(npc, gx, gy, npc.facing or facing)
          reserveSeamCell(gx, gy, npc)
        else
          local dir
          if npc.cellX < gx then dir = "right"
          elseif npc.cellX > gx then dir = "left"
          elseif npc.cellY < gy then dir = "down"
          else dir = "up" end
          local stepX = npc.cellX + (dir == "right" and 1 or dir == "left" and -1 or 0)
          local stepY = npc.cellY + (dir == "down" and 1 or dir == "up" and -1 or 0)
          local moveX, moveY = stepX, stepY
          local hopping = false
          if surface ~= "water"
             and self:ledgeStep(game, ow, npc.cellX, npc.cellY, dir)
             and Collision and Collision.DELTA and Collision.DELTA[dir] then
            local d = Collision.DELTA[dir]
            local hx, hy = npc.cellX + d[1] * 2, npc.cellY + d[2] * 2
            if self:isFollowerCellAllowed(game, ow, npc, hx, hy, {
              surface = surface, role = role,
            }) then
              moveX, moveY = hx, hy
              hopping = true
            end
          end
          if not seamCellFree(moveX, moveY, npc) then
            -- The occupant must complete its own move before this trailer can
            -- claim the cell. A later update will retry the same goal.
          elseif not hopping and not self:isFollowerCellAllowed(game, ow, npc,
              stepX, stepY, {
            surface = surface, role = role,
          }) then
            -- Adjacent step blocked: warp-distance catch-up only when far.
            if far > 2 and not seamReservations and seamCellFree(gx, gy, npc) then
              releaseSeamCell(npc.cellX, npc.cellY, npc)
              placeTrailerAt(npc, gx, gy, dir)
              reserveSeamCell(gx, gy, npc)
            end
          else
            npc.facing = dir
            npc.hopStep = hopping and true or nil
            npc.targetX = moveX
            npc.targetY = moveY
            if hopping then goals[i] = { x = moveX, y = moveY } end
            local stepLen = stepClock
            if far > 1 and not npc.hopStep and not seamReservations then
              stepLen = math.max(1, math.floor(stepLen / 2))
            end
            npc.stepFrames = stepLen
            npc.moving = true
            npc.progress = 0
            releaseSeamCell(npc.cellX, npc.cellY, npc)
            reserveSeamCell(moveX, moveY, npc)
            -- First-frame burn happens in ControlEngine:update via
            -- advanceTrailerStep (npc.update is intentionally a no-op).
          end
        end
      end
    end
  end
end

--- Advance every Wilds trailer exactly once (logic-frame semantics).
function ControlEngine:advanceAllTrailers(ow)
  if not ow then return 0 end
  local n = 0
  for _, trailer in ipairs(ow.pokepcTrailers or {}) do
    if ControlEngine.advanceTrailerStep(trailer, ow.map, ow.entities, self.diag) then
      n = n + 1
    end
  end
  return n
end

function ControlEngine:_traceSurf(game, ow)
  local surfing = self:_playerSurfing(ow, game)
  self.diag.lastSurfing = surfing
  if not surfing then
    self.diag._surfFrames = 0
    return
  end
  self.diag._surfFrames = (self.diag._surfFrames or 0) + 1
  -- Rate-limited diagnostic snapshot (every ~30 logic frames while surfing).
  if self.diag._surfFrames % 30 ~= 1 then return end
  local p = ow.player
  local t = (ow.pokepcTrailers or {})[1]
  local head = ow.pokepcTrailHead
  local goal = (ow.pokepcTrailCells or {})[1]
  logInfo(self.mod,
    "surf-trace owner=%s ctrl=%s sync=%s adv=%s wrap=%s p=%s,%s tgt=%s,%s "
      .. "t=%s,%s tt=%s,%s mov=%s prog=%s head=%s,%s goal=%s,%s",
    tostring(self._trailerUpdateOwner),
    tostring(self.diag.controlUpdateCalls),
    tostring(self.diag.syncTrailersCalls),
    tostring(self.diag.advanceTrailerStepCalls),
    tostring(self.diag.wrappedUpdateCalls),
    tostring(p and p.cellX), tostring(p and p.cellY),
    tostring(p and p.targetX), tostring(p and p.targetY),
    tostring(t and t.cellX), tostring(t and t.cellY),
    tostring(t and t.targetX), tostring(t and t.targetY),
    tostring(t and t.moving), tostring(t and t.progress),
    tostring(head and head.x), tostring(head and head.y),
    tostring(goal and goal.x), tostring(goal and goal.y))
end

--- Sole per-frame owner for Wilds trailer sync + step advance.
-- Prefer calling from OverworldController.update (after vanilla) so player
-- targetX/Y for this logic frame are already committed.
function ControlEngine:update(game, ow, opts)
  opts = opts or {}
  if self._inControlUpdate then return false, "reentrant" end
  game = game or self:_game()
  ow = ow or (game and game.overworld)
  if not self:shouldUpdateWildsTrailers(game, ow) and not opts.force then
    return false, "skip"
  end

  self._inControlUpdate = true
  self.diag.controlUpdateCalls = (self.diag.controlUpdateCalls or 0) + 1
  self.diag.lastSource = opts.source or "direct"

  local ok, err = pcall(function()
    self:_applyConnectionHandoff(ow)
    if self:isPokemonFront(game) or self:followerCount(game) <= 0 then
      self:_removeStockPikachu(ow)
    end
    self:forceYellowStockPikachuArt(ow, game)
    self:syncPlayerControlVisual(game, ow)
    if self._pendingMapTrailerSync or opts.mapEnter then
      self._pendingMapTrailerSync = false
      self:syncTrailers(game, ow, { mapEnter = true })
    else
      self:syncTrailers(game, ow, {})
    end
    self:advanceAllTrailers(ow)
    self:_finishConnectionHandoffIfComplete(ow)
    self:_traceSurf(game, ow)
  end)

  self._inControlUpdate = false
  if not ok then
    logWarn(self.mod, "ControlEngine:update failed: %s", tostring(err))
    return false, err
  end
  return true
end

function ControlEngine:_removeStockPikachu(ow)
  if not ow then return end
  for i = #(ow.npcs or {}), 1, -1 do
    local npc = ow.npcs[i]
    if npc and npc.pikachuFollower and not npc.pokepcTrailer then
      table.remove(ow.npcs, i)
      for j, e in ipairs(ow.entities or {}) do
        if e == npc then table.remove(ow.entities, j); break end
      end
    end
  end
end

function ControlEngine:alignSaveFromOptions(game)
  game = game or self:_game()
  if not (game and game.save) then return end
  local settings = self.settings
  -- Settings adapter owns option → save mirroring (count + derived engine mode).
  -- Do not call setFollowerCount here — that would re-write mod.options.
  if settings and type(settings.alignSave) == "function" then
    pcall(settings.alignSave, settings, game)
    self._optCache.follower_count = nil
    self._optCache.control_mode = nil
    self._optCache.follow_control = nil
    self._optCache.trainer_trail = nil
    return
  end
  local n = tonumber(self:_opt("follower_count", 1)) or 1
  n = math.max(0, math.min(6, math.floor(n)))
  game.save.pokepcFollowerCount = n
  local mode = tostring(self:_opt("control_mode", "follow"))
  if mode == "lead" then mode = "lead_trainer" end
  game.save.pokepcControlMode = mode
end

function ControlEngine:syncAll(game, ow)
  game = game or self:_game()
  ow = ow or (game and game.overworld)
  if ow then pcall(function() self:removeTrailers(ow) end) end
  if self:_isYellow() and game and game.save
     and game.save.pokepcLeader and game.save.pokepcLeader.source == "party" then
    local mon = game.save.party
      and game.save.party[game.save.pokepcLeader.index]
    if mon then
      local idx = self:ensureYellowLeaderLayout(game, mon)
      if type(idx) == "number" then
        game.save.pokepcLeader.index = idx
        game.save.followerPartyIndex = idx
      end
    end
  end
  if (self:isPokemonFront(game) or self:followerCount(game) <= 0) and ow and ow.player then
    ow.player._pokepcControlSpecies = nil
  end
  pcall(function() self:syncPlayerControlVisual(game, ow, true) end)
  pcall(function() self:forceYellowStockPikachuArt(ow, game) end)
  pcall(function() self:syncTrailers(game, ow, { mapEnter = true, catchUp = true }) end)
end

function ControlEngine:_installTalkWrap()
  local OverworldState = tryRequire("src.world.OverworldController")
  if not (OverworldState and OverworldState.interact) then return false end
  if OverworldState._wildsControlEngineTalkWrap == OverworldState.interact then
    return true
  end
  if not self._interaction then
    local Interaction = V.require("follower/interaction")
    self._interaction = Interaction.new(self.mod, self.selection)
  end
  local engine = self
  local origInteract = OverworldState.interact
  local function talkWrap(owSelf, ...)
    local p = owSelf.player
    if p and type(p.facingCell) == "function"
        and type(owSelf.npcAtCell) == "function" then
      local Collision = tryRequire("src.world.Collision")
      local PF = tryRequire("src.world.PikachuFollower")
      local fx, fy = p:facingCell()
      local npc = owSelf:npcAtCell(fx, fy)
      if not npc and owSelf.map and owSelf.map.isCounterCell
         and owSelf.map:isCounterCell(fx, fy) and Collision and Collision.target then
        local fx2, fy2 = Collision.target(fx, fy, p.facing)
        npc = owSelf:npcAtCell(fx2, fy2)
      end
      -- Wilds-owned Pokémon follower trailers are talkable in every version;
      -- no Pikachu in the party is required.
      if npc and npc.wildsFollower == true and npc.pokepcTrailer == true
         and npc.pokepcTrailerKind ~= "trainer" and npc.pokepcMon then
        local mon = npc.pokepcMon
        -- Yellow Pikachu keeps vanilla talk (Pikachu-specific options).
        if engine:_isYellow() and mon.species == "PIKACHU" then
          if PF and PF.talk then
            PF.talk(engine:_game(), owSelf, npc)
          end
          return
        end
        -- Any other follower: "X is following you!".
        if engine._interaction and engine._interaction.showFollowMessage then
          engine._interaction:showFollowMessage(engine:_game(), owSelf, npc, mon)
        end
        return
      end
    end
    return origInteract(owSelf, ...)
  end
  OverworldState.interact = talkWrap
  OverworldState._wildsControlEngineTalkWrap = talkWrap
  self._talkOrigInteract = origInteract
  self._talkWrapped = true
  return true
end

function ControlEngine:_restoreTalkWrap()
  local OverworldState = tryRequire("src.world.OverworldController")
  if not OverworldState then return end
  if self._talkWrapped and OverworldState._wildsControlEngineTalkWrap
     and OverworldState.interact == OverworldState._wildsControlEngineTalkWrap
     and self._talkOrigInteract then
    OverworldState.interact = self._talkOrigInteract
    OverworldState._wildsControlEngineTalkWrap = nil
  end
  self._talkWrapped = false
  self._talkOrigInteract = nil
end

--- Wrap OverworldController.update so trailer ticks are independent of
-- PikachuFollower.shouldSpawn / stock follower presence.
function ControlEngine:_installOverworldUpdateWrap()
  local OverworldState = tryRequire("src.world.OverworldController")
  if not (OverworldState and type(OverworldState.update) == "function") then
    return false
  end
  if OverworldState._wildsControlEngineUpdateWrap == OverworldState.update then
    self._owUpdateWrapped = true
    return true
  end
  local engine = self
  local origUpdate = OverworldState.update
  local function owUpdateWrap(owSelf, dt, ...)
    local a, b, c, d, e = origUpdate(owSelf, dt, ...)
    engine.diag.overworldUpdateCalls = (engine.diag.overworldUpdateCalls or 0) + 1
    -- After vanilla: player.targetX/Y for this logic frame are committed,
    -- and stock npc:update has already run (trailer.update is a no-op).
    pcall(function()
      engine:update(engine:_game(), owSelf, {
        dt = dt,
        source = "overworld",
      })
    end)
    return a, b, c, d, e
  end
  OverworldState.update = owUpdateWrap
  OverworldState._wildsControlEngineUpdateWrap = owUpdateWrap
  self._owOrigUpdate = origUpdate
  self._owUpdateWrapped = true
  return true
end

function ControlEngine:_restoreOverworldUpdateWrap()
  local OverworldState = tryRequire("src.world.OverworldController")
  if not OverworldState then return end
  if self._owUpdateWrapped and OverworldState._wildsControlEngineUpdateWrap
     and OverworldState.update == OverworldState._wildsControlEngineUpdateWrap
     and self._owOrigUpdate then
    OverworldState.update = self._owOrigUpdate
    OverworldState._wildsControlEngineUpdateWrap = nil
  end
  self._owUpdateWrapped = false
  self._owOrigUpdate = nil
end

--- Install PikachuFollower hooks. Idempotent; restores previous on reinstall.
-- Returns false, "no_engine" when NPC/PikachuFollower are unavailable (tests).
function ControlEngine:install()
  if self._installed then
    self:restore()
  end

  local PF = tryRequire("src.world.PikachuFollower")
  local NPC = tryRequire("src.world.NPC")
  if not PF or not NPC then
    return false, "no_engine"
  end

  -- Hot-reload: restore any previous control-engine install first.
  local previous = rawget(PF, Constants.CONTROL_ENGINE_STATE_KEY)
  if previous and type(previous.restore) == "function" then
    pcall(previous.restore)
  end

  local engine = self
  local _, prevShouldSpawn = captureUpvalue(PF.onMapEntered, "shouldSpawn")
  if not prevShouldSpawn then
    _, prevShouldSpawn = captureUpvalue(PF.update, "shouldSpawn")
  end
  engine._prevShouldSpawn = prevShouldSpawn

  local function newShouldSpawn(game, ow)
    return engine:_shouldSpawnStockFollower(game, ow)
  end

  patchUpvalue(PF.update, "shouldSpawn", newShouldSpawn)
  patchUpvalue(PF.onMapEntered, "shouldSpawn", newShouldSpawn)

  local origFollowerUpdate = PF.update
  local origOnMap = PF.onMapEntered
  local origStarterInParty = PF.starterInParty

  -- Prefer OverworldController.update as the sole trailer tick owner.
  local owWrapOk = self:_installOverworldUpdateWrap()
  self._trailerUpdateOwner = owWrapOk and "overworld" or "pikachu_follower"

  local function wrappedUpdate(game, ow, ...)
    engine.diag.wrappedUpdateCalls = (engine.diag.wrappedUpdateCalls or 0) + 1
    local result = origFollowerUpdate and origFollowerUpdate(game, ow, ...)
    -- Stock-only duties while overworld owns trailer movement.
    if engine:isPokemonFront(game) or engine:followerCount(game) <= 0 then
      pcall(function() engine:_removeStockPikachu(ow) end)
    end
    pcall(function() engine:forceYellowStockPikachuArt(ow, game) end)
    -- Fallback only: when OverworldController.update wrap is unavailable,
    -- keep trailers alive via this path (including while surfing).
    if engine._trailerUpdateOwner ~= "overworld" then
      pcall(function()
        engine:update(game, ow, { source = "pikachu_follower" })
      end)
    end
    return result
  end

  local function wrappedOnMapEntered(game, ow, opts)
    if origOnMap then origOnMap(game, ow, opts) end
    local mode = engine:controlMode(game)
    if mode == "pokemon" or mode == "lead_trainer" or mode == "pack" or engine:followerCount(game) <= 0 then
      pcall(function() engine:_removeStockPikachu(ow) end)
    else
      pcall(function() engine:forceYellowStockPikachuArt(ow, game) end)
    end
    engine._pendingMapTrailerSync = true
    pcall(function() engine:syncPlayerControlVisual(game, ow) end)
  end

  local function wrappedStarterInParty(save, needHealthy)
    for _, mon in ipairs(save and save.party or {}) do
      if not needHealthy or (mon.hp or 0) > 0 then return mon end
    end
    return nil
  end

  if origFollowerUpdate then PF.update = wrappedUpdate end
  if origOnMap then PF.onMapEntered = wrappedOnMapEntered end
  PF.starterInParty = wrappedStarterInParty

  pcall(function() self:_installTalkWrap() end)
  -- Re-assert OW wrap after talk wrap / late loads.
  pcall(function() self:_installOverworldUpdateWrap() end)
  if self._owUpdateWrapped then
    self._trailerUpdateOwner = "overworld"
  end

  local mod = self.mod
  if mod and mod.events and mod.events.on then
    local function subscribe(name, callback)
      local ok, off = pcall(mod.events.on, mod.events, name, callback)
      if ok and type(off) == "function" then
        engine._eventOff[#engine._eventOff + 1] = off
      elseif not ok then
        logWarn(mod, "event subscription failed (%s): %s", tostring(name), tostring(off))
      end
    end
    subscribe("mod.options_changed", function(payload)
        if payload and (payload.mod == mod.id) then
          engine._optCache = {}
        end
      end)
    subscribe("map.exited", function(payload)
        local game = engine:_game()
        local ow = game and game.overworld
        engine:_captureMapExit(game, ow, payload)
      end)
    subscribe("map.entered", function(payload)
        local game = engine:_game()
        local ow = game and game.overworld
        pcall(function() engine:syncPlayerControlVisual(game, ow) end)
        engine:_queueMapEntry(game, ow, payload)
        engine._pendingMapTrailerSync = true
      end)
    subscribe("game.ready", function()
        local game = engine:_game()
        engine._mapExitSnapshot = nil
        engine._pendingConnectionHandoff = nil
        engine:alignSaveFromOptions(game)
        pcall(function()
          engine:syncPlayerControlVisual(game, game and game.overworld)
        end)
        engine._pendingMapTrailerSync = true
        pcall(function() engine:_installTalkWrap() end)
      end)
  end

  local restoreState = {
    originalUpdate = origFollowerUpdate,
    originalOnMapEntered = origOnMap,
    originalStarterInParty = origStarterInParty,
    originalShouldSpawn = prevShouldSpawn,
    wrapperUpdate = wrappedUpdate,
    wrapperOnMapEntered = wrappedOnMapEntered,
    wrapperStarterInParty = wrappedStarterInParty,
    engine = engine,
  }

  restoreState.restore = function()
    for i = #engine._eventOff, 1, -1 do
      pcall(engine._eventOff[i])
    end
    engine._eventOff = {}
    if origFollowerUpdate and prevShouldSpawn then
      patchUpvalue(origFollowerUpdate, "shouldSpawn", prevShouldSpawn)
    end
    if origOnMap and prevShouldSpawn then
      patchUpvalue(origOnMap, "shouldSpawn", prevShouldSpawn)
    end
    if PF.update == wrappedUpdate then PF.update = origFollowerUpdate end
    if PF.onMapEntered == wrappedOnMapEntered then PF.onMapEntered = origOnMap end
    if PF.starterInParty == wrappedStarterInParty then
      PF.starterInParty = origStarterInParty
    end
    engine:_restoreTalkWrap()
    engine:_restoreOverworldUpdateWrap()
    engine._mapExitSnapshot = nil
    engine._pendingConnectionHandoff = nil
    engine._trailerUpdateOwner = nil
    if rawget(PF, Constants.CONTROL_ENGINE_STATE_KEY) == restoreState then
      rawset(PF, Constants.CONTROL_ENGINE_STATE_KEY, nil)
    end
    engine._installed = false
    engine._restoreState = nil
  end

  rawset(PF, Constants.CONTROL_ENGINE_STATE_KEY, restoreState)
  self._restoreState = restoreState
  self._installed = true

  pcall(function() self:alignSaveFromOptions(self:_game()) end)
  logInfo(self.mod,
    "control engine installed (trailer owner=%s)",
    tostring(self._trailerUpdateOwner))
  return true, "installed"
end

--- Stock PikachuFollower spawn decision. False while surfing / bike / pack
-- modes — this must never stop ControlEngine:update for Wilds trailers.
function ControlEngine:_shouldSpawnStockFollower(game, ow)
  -- Suppress stock follower if count is 0
  if self:followerCount(game) <= 0 then
    return false
  end

  local mode = self:controlMode(game)
  if mode == "pokemon" or mode == "lead_trainer" or mode == "pack" then
    return false
  end
  -- Pack trailers own the field (except Yellow stock talkable Pikachu).
  if mode == "follow" and self:followerCount(game) > 0
     and not self:yellowStockFollowActive(game) then
    return false
  end

  -- Standalone Red/Blue/Yellow follow (count 0, or Yellow stock): spawn when
  -- SPRITE_PIKACHU is registered and a healthy selection exists. Do not rely
  -- solely on vanilla shouldSpawn (Yellow-Pikachu-only).
  local save = game and game.save
  if not (save and ow) then return false end
  if not save.party or #save.party == 0 then return false end
  if save.onBike then return false end
  if ow.player and ow.player.surfing then return false end

  local hasSprite = false
  if self.spriteService and self.spriteService.hasSpritePikachu then
    hasSprite = self.spriteService:hasSpritePikachu(game) == true
  end
  if not hasSprite then
    local sprites = game.data and game.data.sprites
    hasSprite = sprites ~= nil and sprites[Constants.SPRITE_ID] ~= nil
  end
  if not hasSprite then return false end

  local mon = self:getActiveFollowerMon(game)
  if mon and (tonumber(mon.hp) or 0) > 0 then return true end
  return false
end

function ControlEngine:restore()
  if self._restoreState and type(self._restoreState.restore) == "function" then
    pcall(self._restoreState.restore)
  end
  self:_restoreOverworldUpdateWrap()
  self._installed = false
  self._restoreState = nil
  self._trailerUpdateOwner = nil
end

return ControlEngine
