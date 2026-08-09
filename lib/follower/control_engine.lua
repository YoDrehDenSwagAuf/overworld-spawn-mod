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

local DIR_DELTA = {
  right = { 1, 0 }, left = { -1, 0 }, down = { 0, 1 }, up = { 0, -1 },
}

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
  -- The stepper menu writes directly to game.save (mod.options can be
  -- stale/locked while a ListMenu is on the stack).  Check save first.
  local saved = game and game.save and game.save.pokepcFollowerCount
  if type(saved) == "number" then
    return math.max(0, math.min(6, saved))
  end
  local settings = self.settings
  if settings and type(settings.followerCount) == "function" then
    local ok, n = pcall(settings.followerCount, settings, game)
    if ok and type(n) == "number" then
      return math.max(0, math.min(6, n))
    end
  end
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
    pcall(settings.setEngineMode, settings, mode)
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
  -- Wilds owns the trailer pack independently of party order, so the
  -- Yellow Pikachu-slot-1 layout is unnecessary and causes visible party
  -- reordering when selecting a follower.
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
  -- No followers configured: return nil so the party menu shows FOLLOWER
  -- instead of ACTIVE for every healthy mon.
  if self:followerCount(game) <= 0 then return nil end
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
  -- No followers configured: no mon is active, regardless of selection
  -- state or party contents.
  if self:followerCount(game) <= 0 then return nil end
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

  -- Identify if stock Pikachu is active to prevent duplicate rendering.
  -- In Yellow follow mode the stock Pikachu NPC is rebound to the ACTIVE
  -- leader's art (forceYellowStockPikachuArt), so the leader must not also
  -- trail: that would render the spot-1 mon twice.
  local isStockPikaActive = self:yellowStockFollowActive(game)
  local skipPikaIdx = isStockPikaActive and self:_partyPikachuIndex(save) or nil

  local out = {}
  local pushed = {}  -- party indexes already in the trail (dedupe guard)
  local function push(mon, i)
    out[#out + 1] = { mon = mon, partyIndex = i }
    pushed[i] = true
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
    -- Stock NPC already renders the leader; skip it from the trail.
    if isStockPikaActive and leadIdx and i == leadIdx then return true end
    if mon and mon.stopFollowing == true then return true end
    return false
  end

  if not front and leader then
    -- When the stock Pikachu NPC is active (Yellow follow mode) it already
    -- renders the leader's art via forceYellowStockPikachuArt.  The leader
    -- must not also trail, or it renders twice ("duplicate of the first
    -- slot").  The skipMon guard handles this, but when leadIdx is stale
    -- (switched leaders, identity mismatch, selection-API drift), relying on
    -- index alone misses it.  So: when stock Pika is active, skip the
    -- leader push unconditionally; the stock NPC takes care of slot 1.
    if not (isStockPikaActive and (leadIdx or save.followerPartyIndex)) then
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
  end

  for i, mon in ipairs(save.party or {}) do
    -- pushed[i] guards against a slot already added by the leader push above
    -- (e.g. a box leader whose followerPartyIndex aliases a normal party slot,
    -- or a leader whose party identity collides): one mon per party slot.
    if (mon.hp or 0) > 0 and not pushed[i]
       and not isControlledLeader(mon, i)
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

  -- Walk-cycle animation: mirror the player (continuous animClock, so leg
  -- cadence survives step-length changes like surf/bike) instead of the
  -- stock NPC's per-step progress reset. stepFlip alternates the up/down
  -- walk-frame mirror every completed step; without it the sprite is stuck
  -- on one pose and looks dragged along.
  npc.stepFlip = false
  npc.animClock = 0
  npc.stepLanded = false
  if NPC.walkPhase then
    npc.walkPhase = function(ent)
      if not ent.moving and not ent.stepLanded then
        -- Keep the walk cycle running while the pack is in motion, so a
        -- trailer waiting between steps (or catching up after a blocked
        -- corner) still shows a moving gait instead of freezing on the
        -- stand frame. Idle packs settle back to stand after the tail.
        if ent._wildsPackWalking ~= true then
          return 0
        end
      end
      local p = (ent.animClock or ent.progress or 0) % 16
      return (p >= 4 and p < 12) and 1 or 0
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
  -- Last resort: the player's own cell is water (surf field flags vary across
  -- engine builds). Trailers must get water surface semantics or they can
  -- never step onto water cells and get dragged along via teleports.
  if ow and ow.map and player.cellX ~= nil and player.cellY ~= nil
     and type(ow.map.isWaterCell) == "function" then
    local ok, water = pcall(ow.map.isWaterCell, ow.map, player.cellX, player.cellY)
    if ok and water == true then return true end
  end
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

--- Pick the next adjacent cell for a trailer moving toward (gx, gy).
-- Tries the goal axis first, then the other axis, then the current facing,
-- so trailers navigate corners and shorelines instead of freezing (or
-- teleporting) when the direct step is blocked. Returns { dir, x, y } or nil
-- when no adjacent follower-allowed cell exists.
function ControlEngine:_pickTrailerStep(game, ow, npc, gx, gy, surface, role)
  local cx, cy = npc.cellX or 0, npc.cellY or 0
  local dx, dy = gx - cx, gy - cy
  local function allowed(sx, sy)
    return self:isFollowerCellAllowed(game, ow, npc, sx, sy, {
      surface = surface, role = role,
    })
  end
  local cands = {}
  local function consider(dir, sx, sy, hop)
    cands[#cands + 1] = {
      dir = dir, x = sx, y = sy,
      dist = math.abs(gx - sx) + math.abs(gy - sy),
      hop = hop or nil,
    }
  end
  if math.abs(dx) >= math.abs(dy) then
    if dx > 0 then consider("right", cx + 1, cy) end
    if dx < 0 then consider("left", cx - 1, cy) end
    if dy > 0 then consider("down", cx, cy + 1) end
    if dy < 0 then consider("up", cx, cy - 1) end
  else
    if dy > 0 then consider("down", cx, cy + 1) end
    if dy < 0 then consider("up", cx, cy - 1) end
    if dx > 0 then consider("right", cx + 1, cy) end
    if dx < 0 then consider("left", cx - 1, cy) end
  end
  local d = npc.facing and DIR_DELTA[npc.facing]
  if d then consider(npc.facing, cx + d[1], cy + d[2]) end

  -- Ledge-hop candidates: when the follower stands on a ledge edge, the
  -- landing two cells ahead can be the goal even though the one-cell-adjacent
  -- step (the ledge tile itself) is often rejected by isFollowerCellAllowed.
  -- This gives followers the same ledge-jump behaviour that the stock Yellow
  -- Pikachu follower has.
  if surface ~= "water" then
    local Collision = tryRequire("src.world.Collision")
    for _, dir in ipairs({ "up", "down", "left", "right" }) do
      if self:ledgeStep(game, ow, cx, cy, dir)
         and Collision and Collision.DELTA and Collision.DELTA[dir] then
        local delta = Collision.DELTA[dir]
        local hx, hy = cx + delta[1] * 2, cy + delta[2] * 2
        if self:isFollowerCellAllowed(game, ow, npc, hx, hy, {
          surface = surface, role = role,
        }) then
          consider(dir, hx, hy, true)
        end
      end
    end
  end

  -- Separate walkable 1-cell steps from ledge-hop candidates.  Ledge hops
  -- win when they are the shorter path to the goal — otherwise a trailer on
  -- a ledge edge walks *around* the ledge (toward a walkable side cell)
  -- instead of jumping down, which is what "freaks out" when the player
  -- changes direction after a ledge hop.
  local walkable = {}
  local hops = {}
  for _, c in ipairs(cands) do
    if c.hop then
      hops[#hops + 1] = c
    elseif allowed(c.x, c.y) then
      walkable[#walkable + 1] = c
    end
  end

  local function bestDist(list)
    local d = math.huge
    for _, c in ipairs(list) do
      if c.dist < d then d = c.dist end
    end
    return d
  end
  local bestWalkable = bestDist(walkable)
  local bestHop = bestDist(hops)

  -- If a ledge hop gets us closer to the goal than any walkable 1-cell
  -- step, prefer the hop.  The adjacent cell past the ledge is often the
  -- ledge tile itself (non-walkable), so the "walkable" list only contains
  -- side/back steps that move AWAY from the goal; the hop is the correct
  -- path forward.
  local pool = (bestHop < bestWalkable) and hops or walkable
  if #pool == 0 then
    pool = (pool == hops) and walkable or hops
  end
  if #pool == 0 then return nil end

  table.sort(pool, function(a, b)
    if a.dist ~= b.dist then return a.dist < b.dist end
    if (a.dir == npc.facing) ~= (b.dir == npc.facing) then
      return a.dir == npc.facing
    end
    return false
  end)
  return pool[1]
end

--- Advance a trailer step without stock NPC land-walkability rejection.
-- Uses the same fields as NPC movement (target/moving/progress/px/py).
-- Timing: one progress tick per ControlEngine:update (logic frame), matching
-- stock NPC:update — not present/render FPS.
function ControlEngine.advanceTrailerStep(npc, _map, _entities, diag)
  if not npc then return false end
  -- Mirror Player:update — the completion-frame pose is kept for this draw,
  -- then cleared so an idle trailer snaps back to the stand frame.
  npc.stepLanded = false
  -- Keep the walk clock running every frame (moving or not) so the
  -- pack-motion gate in walkPhase always has a continuous cycle to sample.
  npc.animClock = (tonumber(npc.animClock) or 0) + 1
  if not npc.moving then return false end
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
    npc.stepLanded = true
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
  -- Force re-composition when the desired count changes (stepper menu).
  -- Only triggers after the first sync has established a baseline, so the
  -- initial sync (from nil) doesn't inadvertently mark itself dirty.
  local wantN = #want
  local countChanged = self._lastSyncedCount ~= nil
    and wantN ~= self._lastSyncedCount
  local dirty = compositionDirty(trailers, want)
    or not trailersAliveInWorld(ow, trailers)
    or countChanged

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
    self._lastSyncedCount = wantN
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

  -- Pack-motion gate for the trailer walk cycle. The pack is walking while the
  -- player is mid-step or the trail head just committed a step; the gate then
  -- stays on for a short settle tail (long enough to bridge the one-frame
  -- gap between steps and to finish in-flight trailer steps) and drops to
  -- stand afterwards, so an idle pack never bobs in place. Reading the
  -- player's own motion in addition to the head commit makes this robust to
  -- anchor quirks (Yellow's stock Pikachu steps on its own offset cadence, so
  -- commits land at irregular intervals and a commit-only gate can sit off
  -- for long stretches between them).
  local packMoving = (p and p.moving == true) or committed
  local settle = math.max(4, math.floor((stepClock or 16) / 2))
  if packMoving then
    ow._wildsPackMotionFrames = 0
    ow._wildsPackWalking = true
  else
    ow._wildsPackMotionFrames = (ow._wildsPackMotionFrames or 0) + 1
    if ow._wildsPackMotionFrames > settle then
      ow._wildsPackWalking = false
    end
  end

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
  end

  -- Step assignment runs every frame: a trailer starts a step as soon as its
  -- goal differs, even on frames where the head did not commit (a trailer that
  -- landed mid-walk must re-step immediately instead of freezing until the
  -- next goal shift). Mid-step trailers are left to advanceAllTrailers.
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
        local ok = self:_assignTrailerStep(
          game, ow, npc, gx, gy, surface, role, stepClock, facing)
        if ok then
          -- Keep the trail cell aligned with the trailer's actual aim
          -- (including ledge-hop extension) for the catch-up chain pass.
          goals[i] = { x = npc._wildsGoalX, y = npc._wildsGoalY }
        end
      else
        npc._wildsGoalX, npc._wildsGoalY = nil, nil
      end
    end
  end
end

--- Assign one step for a trailer toward (gx, gy). Corner-navigates, handles
-- ledges, and picks the cadence: normal at 1-cell spacing, double-speed for
-- catch-up. Stores the goal on the trailer so the catch-up pass can chain
-- consecutive steps without waiting for the next goal shift. Returns true
-- when a step started; false when blocked (no adjacent follower cell).
function ControlEngine:_assignTrailerStep(game, ow, npc, gx, gy, surface, role,
                                           stepClock, facing)
  local Collision = tryRequire("src.world.Collision")
  local far = math.abs((npc.cellX or 0) - gx) + math.abs((npc.cellY or 0) - gy)
  local step = self:_pickTrailerStep(game, ow, npc, gx, gy, surface, role)
  if not step then
    -- No valid adjacent cell (wall pocket). Only hard-warp when the trailer
    -- is so far that waiting would strand it forever; mid-range blocked
    -- trailers wait for the goal to shift instead of teleporting (teleports
    -- read as "dragged along" jumps on followers 2+).
    if far > 8 then
      placeTrailerAt(npc, gx, gy, npc.facing or facing)
      npc._wildsGoalX, npc._wildsGoalY = nil, nil
    end
    return false
  end
  local dir = step.dir
  npc.facing = dir
  npc.hopStep = step.hop or nil
  npc.targetX = step.x
  npc.targetY = step.y
  npc._wildsGoalX, npc._wildsGoalY = gx, gy
  -- When _pickTrailerStep already identified this as a ledge hop the
  -- target coordinates, hop flag, and goal chain are already set for the
  -- two-cell landing; skip the secondary ledge re-detection.
  if not step.hop
     and surface ~= "water"
     and self:ledgeStep(game, ow, npc.cellX, npc.cellY, dir)
     and Collision and Collision.DELTA and Collision.DELTA[dir] then
    local d = Collision.DELTA[dir]
    local hx, hy = npc.cellX + d[1] * 2, npc.cellY + d[2] * 2
    if self:isFollowerCellAllowed(game, ow, npc, hx, hy, {
      surface = surface, role = role,
    }) then
      npc.targetX = hx
      npc.targetY = hy
      npc.hopStep = true
      -- Ledge hop lands two cells out: aim the chain at the far cell.
      npc._wildsGoalX, npc._wildsGoalY = hx, hy
    end
  end
  -- Normal cadence at 1-cell spacing. Trailers that fell behind (blocked
  -- corner, spawn, surface change) walk at double cadence until they close
  -- the gap; the catch-up pass chains the next step the moment one lands so
  -- the straggler moves continuously instead of bursting 8 frames then
  -- freezing 8 frames waiting for the next goal shift (the tick-tock drag).
  -- Ledge hops always use full-length frames for the arc animation.
  if not npc.hopStep and far > 1 then
    npc.stepFrames = math.max(1, math.floor(stepClock / 2))
  else
    npc.stepFrames = stepClock
  end
  npc.moving = true
  npc.progress = 0
  -- First-frame burn happens in ControlEngine:update via
  -- advanceTrailerStep (npc.update is intentionally a no-op).
  return true
end

--- Chain catch-up steps: a trailer that just landed but is still short of
-- its goal starts the next step immediately (double cadence), so it closes
-- the gap continuously instead of freezing until the next goal shift.
function ControlEngine:_chainCatchUpSteps(game, ow, stepClock)
  -- Only chase goals while the pack is actually walking: once the player
  -- stops, stragglers hold position (they resume catching up on the next
  -- walk) instead of pacing toward stale goals — that pacing is what made
  -- idle followers 2+ bob up and down in place.
  if ow._wildsPackWalking ~= true then return 0 end
  local trailers = ow.pokepcTrailers or {}
  local goals = ow.pokepcTrailCells or {}
  local p = ow.player
  local anchor = self:_trailAnchor(game, ow, p)
  local facing = (anchor and anchor.facing) or (p and p.facing) or "down"
  stepClock = stepClock or (p and (p.stepFramesCur or p.stepFrames)) or 16
  local surface = self:_trailSurface(ow, game)
  local assigned = 0
  for i, npc in ipairs(trailers) do
    if npc and not npc.moving then
      local gx, gy = npc._wildsGoalX, npc._wildsGoalY
      if gx == nil then
        local cell = goals[i]
        if cell then gx, gy = cell.x, cell.y end
      end
      if gx ~= nil then
        local far = math.abs((npc.cellX or 0) - gx) + math.abs((npc.cellY or 0) - gy)
        if far > 0 and self:isFollowerCellAllowed(game, ow, npc, gx, gy, {
          surface = surface, role = npc.wildsFollowerRole or "party_trailer",
        }) then
          local ok = self:_assignTrailerStep(game, ow, npc, gx, gy, surface,
            npc.wildsFollowerRole or "party_trailer", stepClock, facing)
          if ok then
            -- Chain at catch-up cadence for normal steps; ledge hops keep
            -- full-length frames so the arc animation plays out properly.
            if not npc.hopStep then
              npc.stepFrames = math.max(1, math.floor(stepClock / 2))
            end
            assigned = assigned + 1
          end
        end
      end
    end
  end
  return assigned
end

--- Advance every Wilds trailer exactly once (logic-frame semantics).
function ControlEngine:advanceAllTrailers(ow)
  if not ow then return 0 end
  local packWalking = ow._wildsPackWalking == true
  local n = 0
  for _, trailer in ipairs(ow.pokepcTrailers or {}) do
    -- Propagate the pack-motion gate so walkPhase can sample it at draw time.
    trailer._wildsPackWalking = packWalking
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
  -- Always run when a pending sync is queued (stepper menu changed the count
  -- while the world was paused).  Otherwise skip if trailers aren't needed.
  if not self._pendingMapTrailerSync
     and not self:shouldUpdateWildsTrailers(game, ow)
     and not opts.force then
    return false, "skip"
  end

  self._inControlUpdate = true
  self._lastOw = ow  -- cached for menu-context access (stepper, etc.)
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

    -- Detect land↔water transitions and re-resolve trailer sprites so
    -- submerged poke_followers art appears the moment the player surfs.
    -- Also refresh when trailer entities are recreated (battle ended / party
    -- change while on water) — syncTrailers gives them fresh land sprites.
    local surface = self:_trailSurface(ow, game)
    local t1 = (ow.pokepcTrailers or {})[1]
    local trailersChanged = (t1 ~= self._lastTrailerRef)
    if surface ~= self._lastTrailSurface or (surface == "water" and trailersChanged) then
      self._lastTrailSurface = surface
      self._lastTrailerRef = t1
      pcall(function() self:_refreshTrailerWaterSprites(game, ow, surface) end)
    end

    self:advanceAllTrailers(ow)
    -- Stragglers re-step the moment they land so the pack closes gaps
    -- continuously instead of freezing between goal shifts.
    self:_chainCatchUpSteps(game, ow)
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

--- Re-resolve every party-mon trailer sprite for the new surface (land/water)
-- so submerged sheets take effect the moment the player enters water and
-- land sheets restore when they step out.
--
-- Water path: loads poke_followers/follower_NNN_submerged.png directly via
-- fsExists instead of going through the resolution chain (whose mod:read
-- existence check can fail for binary assets).  Falls back to the standard
-- resolveFollowerSprite chain when no submerged sheet exists.
function ControlEngine:_refreshTrailerWaterSprites(game, ow, surface)
  if not (ow and ow.pokepcTrailers) then return end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new) then return end

  local AnimatedSprites = nil
  pcall(function() AnimatedSprites = V.require("animated_sprites") end)

  for _, npc in ipairs(ow.pokepcTrailers) do
    if npc and npc.pokepcTrailerKind == "mon" and npc.pokepcMon then
      local mon = npc.pokepcMon
      local species = mon.species or npc._wildsFollowerSpecies
      local shiny = isShinyMon(mon) or (npc.pokepcShiny == true)
      local resolved = nil

      if surface == "water" then
        -- Load the submerged poke_followers sheet directly.  Naming is
        -- follower_NNN_{variant}_submerged.png; pick based on COLORS mode.
        local dex = AnimatedSprites and AnimatedSprites.resolveSpeciesId
          and AnimatedSprites.resolveSpeciesId(species, game, self.mod)
        if dex then
          local Config = nil
          pcall(function() Config = V.require("config") end)
          local redpp = Config and type(Config.paletteFxRedpp) == "function"
            and Config.paletteFxRedpp()
          -- Build a list of variant suffixes to try, best match first.
          local tryVariants = {}
          if redpp then
            if shiny then
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
              local ok, p = pcall(function()
                return self.mod.assets:path(rel)
              end)
              if ok and type(p) == "string" then loadPath = p end
            end
            if (love and love.filesystem and love.filesystem.getInfo
                and love.filesystem.getInfo(loadPath))
               or (love and love.filesystem and love.filesystem.getInfo
                   and love.filesystem.getInfo(rel)) then
              resolved = {
                image = loadPath,
                frames = 6,
                walker = true,
                trueColor = true,
                id = "SPRITE_WILDS_FOLLOWER_SUBMERGED_" .. tostring(dex),
              }
              break
            end
          end
        end
      end

      if not resolved then
        -- No submerged sheet (land surface, or species outside the set).
        -- Fall back to the standard sprite resolution chain.
        resolved = self:resolveFollowerSprite({
          species = species,
          shiny = shiny,
          form = mon.form,
          surface = surface,
          role = "party_trailer",
          game = game,
        })
      end

      if resolved and resolved.image then
        local ok, sprite = pcall(SpriteRenderer.new, {
          id = resolved.id or "SPRITE_WILDS_FOLLOWER_MON",
          image = resolved.image,
          frames = resolved.frames or 6,
          walker = resolved.walker ~= false,
          trueColor = resolved.trueColor ~= false,
          pokepcShiny = shiny and true or false,
        }, npc.id)
        if ok and sprite then
          npc.sprite = sprite
          npc._wildsFollowerSpecies = species
        end
      end
      npc.wildsFollowerWater = (surface == "water")
      npc.spriteState = surface
    end
  end
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
  -- Unconditionally restore to the vanilla original captured at first install.
  -- External mods (e.g. Followers EX) may have wrapped on top, so equality
  -- guards against _wildsControlEngineUpdateWrap would fail.
  if self._owOrigUpdate then
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

  -- Preserve vanilla originals so restore() can strip any external-mod
  -- wrappers (e.g. Followers EX) that were installed on top of ours.
  engine._vanillaOrigUpdate = origFollowerUpdate
  engine._vanillaOrigOnMapEntered = origOnMap
  engine._vanillaOrigStarterInParty = origStarterInParty
  engine._vanillaShouldSpawn = prevShouldSpawn

  restoreState.restore = function()
    for i = #engine._eventOff, 1, -1 do
      pcall(engine._eventOff[i])
    end
    engine._eventOff = {}
    engine._mapExitSnapshot = nil
    engine._pendingConnectionHandoff = nil
    -- Unconditionally restore the engine functions to the vanilla originals
    -- captured at first install time, regardless of whether an external mod
    -- (e.g. Followers EX) has wrapped on top. Without this the equality
    -- guards would see EX's wrapper instead of ours and skip the restore,
    -- so reinstall() wraps on top of EX → broken walk cycles.
    if engine._vanillaOrigUpdate and engine._vanillaShouldSpawn then
      patchUpvalue(engine._vanillaOrigUpdate, "shouldSpawn", engine._vanillaShouldSpawn)
    end
    if engine._vanillaOrigOnMapEntered and engine._vanillaShouldSpawn then
      patchUpvalue(engine._vanillaOrigOnMapEntered, "shouldSpawn", engine._vanillaShouldSpawn)
    end
    if engine._vanillaOrigUpdate then PF.update = engine._vanillaOrigUpdate end
    if engine._vanillaOrigOnMapEntered then PF.onMapEntered = engine._vanillaOrigOnMapEntered end
    if engine._vanillaOrigStarterInParty then PF.starterInParty = engine._vanillaOrigStarterInParty end
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
