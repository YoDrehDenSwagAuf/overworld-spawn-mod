-- Control / pack / trailer engine for Wilds of Kanto standalone use.
--
-- Credits: masterwebx / Followers EX ControlEngine concepts adapted for Wilds;
-- assets via Wilds sprite service (no PokePCFollowers_VoxelMerge dependency).
--
-- Ownership (exactly one driver; never both):
--   * Gen1 trailer movement: ControlEngine:update via OverworldController.update
--     (owner = "overworld"). Fallback: PikachuFollower.update wrap
--     (owner = "pikachu_follower") when the OW wrap is unavailable.
--   * Gen2 trailer movement: ControlEngine:update via Gold World:step wrap
--     (owner = "gen2_world_event"). world.stepped is per-tile-land, not a
--     logic frame, so it is not the Gold driver. Do not wrap World.update.
--   * Stock PikachuFollower: shouldSpawn / onMapEntered / talk only.
-- Lifecycle must NOT also wrap update/onMapEntered/shouldSpawn when the
-- control engine is installed.
local V = ...
local Constants = V.require("follower/constants")
local WildsFs = V.require("wilds_fs")

local DebugLog
do
  local ok, mod = pcall(function() return V.require("debug_log") end)
  if ok then DebugLog = mod end
end

local ControlEngine = {}
ControlEngine.__index = ControlEngine

local TRAILER_BASE = 240

-- Jam-recovery tuning (see the recovery block in syncTrailers).  A scrambled
-- pack (slot order inverted after a reversal) is re-seeded quickly; non-inverted
-- stalls wait a fraction of a second; a quiet cooldown stops a re-form from
-- oscillating into repeated pops.  All in logic frames.
--
-- The inverted (scrambled) fast path is deliberately NOT instantaneous: during
-- an ordinary reversal the tightly packed 1-cell train briefly folds and its
-- slot-order probe can read as inverted for a frame or two before the swap
-- allowance resolves the crossing.  An 8x/2-frame fast fire turned that
-- momentary fold into a visible teleport-pop (the "slingshot" read on tall
-- True Size sprites).  Since the fold fixes (live-goal swap, feasibility
-- guard, in-flight abort) those momentary folds resolve by walking and never
-- accumulate, the fast path only fires on genuine deadlocks — so it can run
-- quicker: FAST_STEP = 4 re-seeds a scrambled pack after ~4 stalled frames
-- (~0.07s) before the player has walked far enough for the re-seed to read as
-- a big teleport.  Non-inverted stalls (wall-blocked pack) still wait
-- THRESHOLD frames; COOLDOWN keeps a re-form from popping repeatedly.
local TRAIL_JAM_THRESHOLD = 12
local TRAIL_JAM_FAST_STEP = 4
local TRAIL_JAM_COOLDOWN = 40

local DIR_DELTA = {
  right = { 1, 0 }, left = { -1, 0 }, down = { 0, 1 }, up = { 0, -1 },
}

-- Shared no-op for Wilds-owned trailer NPCs. ControlEngine owns stepping;
-- stock NPC.update must not run. Reuse one function so syncTrailers does not
-- allocate a fresh closure per trailer on the hot path.
local NO_UPDATE = function() end

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

local function logGen2(mod, fmt, ...)
  if DebugLog and DebugLog.followerGen2Always then
    DebugLog.followerGen2Always(mod, fmt, ...)
  elseif DebugLog and DebugLog.followerGen2 then
    DebugLog.followerGen2(mod, fmt, ...)
  end
end

local function logGen2Once(self, key, fmt, ...)
  if not self then return end
  self._gen2Once = self._gen2Once or {}
  if self._gen2Once[key] then return end
  self._gen2Once[key] = true
  logGen2(self.mod, fmt, ...)
end

local function isMissingFallbackImage(image)
  return type(image) == "string"
    and image:find("pokemon_missing.png", 1, true) ~= nil
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

--- Build a SpriteRenderer def carrying True Size geometry (frameWidth /
-- frameHeight / anchorX / anchorY) so follower sprites render at the
-- effective species size (HGSS style → True Size).  Geometry travels from
-- the resolver; extras are merged on top.
local function spriteDefWithGeometry(resolved, extras)
  local def = {
    id = resolved.id or "SPRITE_WILDS_FOLLOWER_MON",
    image = resolved.image,
    frames = resolved.frames or 6,
    walker = resolved.walker ~= false,
    trueColor = resolved.trueColor ~= false,
    frameWidth = resolved.frameWidth,
    frameHeight = resolved.frameHeight,
    anchorX = resolved.anchorX,
    anchorY = resolved.anchorY,
  }
  if type(extras) == "table" then
    for k, v in pairs(extras) do def[k] = v end
  end
  return def
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
  self._pendingSpawnAtPlayer = false
  self._pendingBattleReturnSync = false
  self._battleReturnFlushedOnce = false
  self._battleReturnPhase = nil
  self._battleReturnChecks = 0
  self._battleReturnOw = nil
  self._battleReturnTrailers = nil
  self._battleReturnTrailCells = nil
  self._battleReturnTrailHead = nil
  self._mapExitSnapshot = nil
  self._pendingConnectionHandoff = nil
  self._optCache = {}
  self._eventOff = {}
  self._talkWrapped = false
  self._talkToWrapped = false
  self._owUpdateWrapped = false
  self._gen2WorldStepWrapped = false
  self._inControlUpdate = false
  -- "overworld" = OverworldController.update owns trailer ticks (Gen1);
  -- "gen2_world_event" = Gold World:step owns trailer ticks;
  -- "pikachu_follower" = Gen1 fallback when OW wrap is unavailable.
  self._trailerUpdateOwner = nil
  self.diag = {
    wrappedUpdateCalls = 0,
    syncTrailersCalls = 0,
    advanceTrailerStepCalls = 0,
    controlUpdateCalls = 0,
    overworldUpdateCalls = 0,
    gen2WorldStepCalls = 0,
    lastSource = nil,
    lastSurfing = false,
    -- Which re-seed branch parked/placed the pack last, for the WILDS HUD:
    -- "parked_at_player" | "trail_reform" | "behind_water" | "kept" | nil
    lastSeed = nil,
    entryParks = 0,
    trailReforms = 0,
    behindWaterSeeds = 0,
  }
  return self
end

function ControlEngine:_game()
  if self._gameRef then return self._gameRef end
  local mod = self.mod
  if mod then
    if type(mod.game) == "table" then return mod.game end
    if mod.world and type(mod.world.game) == "table" then return mod.world.game end
  end
  local Game = tryRequire("src.core.Game")
  return Game
end

--- Live world: Gen1 OverworldState or Gold game.world. Never assigns
-- game.overworld = game.world.
function ControlEngine:_liveOw(game, ow)
  if ow and (ow.player or ow.map) then return ow end
  local GameCompat = V.require("game_compat")
  return GameCompat.liveOverworld(self.mod, game)
end

function ControlEngine:_freshOw(game)
  local GameCompat = V.require("game_compat")
  return GameCompat.liveOverworld(self.mod, game or self:_game())
end

function ControlEngine:_identityInList(list, npc)
  if type(list) ~= "table" or not npc then return false end
  for _, e in ipairs(list) do
    if e == npc then return true end
  end
  return false
end

-- Authoritative visibility: the SAME object is in the current live
-- draw/entity/NPC containers. Id / pokepcTrailers / registeredInWorld
-- are not enough — a late people rebuild can drop the object while
-- those caches still look healthy.
function ControlEngine:_isTrailerAttached(ow, npc)
  if not ow or not npc then return false end
  return self:_identityInList(ow.entities, npc)
    or self:_identityInList(ow.npcs, npc)
end

function ControlEngine:_rememberBattleTrailers(ow)
  local trailers = ow and ow.pokepcTrailers
  if not (trailers and #trailers > 0) then return end
  local refs = {}
  for i, t in ipairs(trailers) do refs[i] = t end
  self._battleReturnTrailers = refs
  self._battleReturnTrailCells = ow.pokepcTrailCells
  self._battleReturnTrailHead = ow.pokepcTrailHead
end

-- If the engine replaced the overworld object, pokepcTrailers on the
-- new instance is empty even though we still hold the live NPCs.
function ControlEngine:_adoptRememberedTrailers(ow)
  if not ow then return false end
  local remembered = self._battleReturnTrailers
  if not remembered or #remembered == 0 then return false end
  if ow.pokepcTrailers and #ow.pokepcTrailers > 0 then
    self:_rememberBattleTrailers(ow)
    return false
  end
  ow.pokepcTrailers = remembered
  if self._battleReturnTrailCells then
    ow.pokepcTrailCells = self._battleReturnTrailCells
  end
  if self._battleReturnTrailHead then
    ow.pokepcTrailHead = self._battleReturnTrailHead
  end
  return true
end

function ControlEngine:_allTrailersIdentityAttached(ow)
  local trailers = ow and ow.pokepcTrailers
  if not trailers or #trailers == 0 then return false end
  for _, npc in ipairs(trailers) do
    if not self:_isTrailerAttached(ow, npc) then return false end
  end
  return true
end

-- Reinsert existing trailers into the CURRENT live containers. Does not
-- recreate sprites, reroll selection, or rebuild pokepcTrailers.
function ControlEngine:_ensureTrailersAttached(game, ow)
  game = game or self:_game()
  local fresh = self:_freshOw(game)
  if fresh then
    if ow and fresh ~= ow then
      self:_traceBattleReturn("ensure.owReplaced", game, fresh)
    end
    ow = fresh
  end
  if not ow then return false, "no_overworld" end
  local adopted = self:_adoptRememberedTrailers(ow)
  local trailers = ow.pokepcTrailers or {}
  local attached = 0
  for _, npc in ipairs(trailers) do
    if npc then
      if not self:_isTrailerAttached(ow, npc) then
        self:_attachTrailer(game, ow, npc)
      end
      if self:_isTrailerAttached(ow, npc) then
        attached = attached + 1
      end
    end
  end
  self:_rememberBattleTrailers(ow)
  self:_traceBattleReturn("ensureTrailersAttached", game, ow, {
    attached = attached,
    desired = #trailers,
    adopted = adopted,
  })
  return attached > 0 and attached == #trailers, attached
end

function ControlEngine:_battleReturnActive()
  local phase = self._battleReturnPhase
  return phase == "pending" or phase == "first_live" or phase == "verify"
end

function ControlEngine:_clearBattleReturn()
  self._pendingBattleReturnSync = false
  self._battleReturnFlushedOnce = false
  self._battleReturnPhase = nil
  self._battleReturnChecks = 0
  self._battleReturnOw = nil
  self._battleReturnTrailers = nil
  self._battleReturnTrailCells = nil
  self._battleReturnTrailHead = nil
end

function ControlEngine:_traceBattleReturn(tag, game, ow, extra)
  extra = extra or {}
  local enabled = DebugLog and DebugLog.enabled and DebugLog.enabled(self.mod)
  if not enabled and not extra.force then return end
  local live = self:_freshOw(game)
  local liveSame = (ow ~= nil and live == ow)
  local desired = 0
  pcall(function() desired = self:followerCount(game) or 0 end)
  local trailers = (ow and ow.pokepcTrailers) or {}
  logInfo(self.mod,
    "[BattleReturn][%s] map=%s ow=%s liveOw=%s liveSame=%s battleActive=%s phase=%s pendingSync=%s flushedOnce=%s pendingMap=%s spawnAtPlayer=%s desired=%s trailers=%s entities=%s npcs=%s",
    tostring(tag),
    tostring(ow and ow.map and ow.map.id),
    tostring(ow),
    tostring(live),
    tostring(liveSame),
    tostring(ow and ow.battleActive),
    tostring(self._battleReturnPhase),
    tostring(self._pendingBattleReturnSync),
    tostring(self._battleReturnFlushedOnce),
    tostring(self._pendingMapTrailerSync),
    tostring(self._pendingSpawnAtPlayer),
    tostring(desired),
    tostring(#trailers),
    tostring(ow and ow.entities and #ow.entities or 0),
    tostring(ow and ow.npcs and #ow.npcs or 0))
  for i, npc in ipairs(trailers) do
    local inTrailers = self:_identityInList(trailers, npc)
    logInfo(self.mod,
      "[BattleReturn][%s] trailer[%d] id=%s obj=%s inTrailers=%s inEntities=%s inNpcs=%s pokepcTrailer=%s kind=%s wildsFollower=%s attached=%s",
      tostring(tag), i,
      tostring(npc and npc.id),
      tostring(npc),
      tostring(inTrailers),
      tostring(self:_identityInList(ow and ow.entities, npc)),
      tostring(self:_identityInList(ow and ow.npcs, npc)),
      tostring(npc and npc.pokepcTrailer),
      tostring(npc and npc.pokepcTrailerKind),
      tostring(npc and npc.wildsFollower),
      tostring(self:_isTrailerAttached(ow, npc)))
  end
end

function ControlEngine:_attachTrailer(game, ow, npc)
  if not (ow and npc) then return end
  local GameCompat = V.require("game_compat")
  local attached = GameCompat.attachGuestEntity(ow, npc, game)
  npc.worldContainer = attached or npc.worldContainer
  local inNpcs, inEntities = false, false
  for _, n in ipairs(ow.npcs or {}) do
    if n == npc then inNpcs = true break end
  end
  for _, e in ipairs(ow.entities or {}) do
    if e == npc then inEntities = true break end
  end
  if self:_battleReturnActive() then
    self:_traceBattleReturn("attachTrailer", game, ow, {
      id = npc.id, inNpcs = inNpcs, inEntities = inEntities,
    })
  end
  logGen2(self.mod,
    "attached=%s inNpcs=%s inEntities=%s npcs=%s entities=%s id=%s",
    tostring(attached or npc.worldContainer or "?"),
    tostring(inNpcs), tostring(inEntities),
    tostring(#(ow.npcs or {})), tostring(#(ow.entities or {})),
    tostring(npc.id))
end

function ControlEngine:_isYellow()
  local GameCompat = V.require("game_compat")
  local game = self.mod and self.mod.world and self.mod.world.game
  return GameCompat.gameVersion(game) == "yellow"
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
    pcall(function() self:syncAll(game, self:_liveOw(game)) end)
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
  local ow = self:_liveOw(game)
  local player = ow and ow.player
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
  local ow = self:_liveOw(game)
  self:syncAll(game, ow)
  return mon.stopFollowing
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

  -- Prefer Wilds selection when available. needHealthy=true so a fainted
  -- leader is skipped — reconcile permanently fails over selection first.
  if self.selection and type(self.selection.getActiveFollowerMon) == "function" then
    local ok, mon, slot = pcall(self.selection.getActiveFollowerMon, self.selection, game, true)
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
    local SpeciesAssets = V.require("species_assets")
    local assetId = SpeciesAssets.idFor(species)
    if not assetId then
      -- Unknown / Fakemon: do not guess via runtime dex or Charmander default.
      return nil
    end
    local GameCompat = V.require("game_compat")
    local id = (role == "player_controlled")
      and (GameCompat.isGen2(self.mod, opts.game) and "SPRITE_WILDS_PLAYER_MON"
        or "SPRITE_PLAYER_POKEMON")
      or "SPRITE_WILDS_FOLLOWER_MON"
    if sheets.spriteDef then
      local ok, def = pcall(sheets.spriteDef, sheets, assetId, variant, id)
      if ok and def and def.image then
        return {
          image = def.image,
          frames = def.frames or 6,
          walker = def.walker ~= false,
          trueColor = def.trueColor ~= false,
          id = def.id or id,
          dex = assetId,
          assetId = assetId,
          fallback = isMissingFallbackImage(def.image),
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
  local GameCompat = V.require("game_compat")
  local fallbackId = (role == "player_controlled")
    and (GameCompat.isGen2(self.mod, opts.game) and "SPRITE_WILDS_PLAYER_MON"
      or "SPRITE_PLAYER_POKEMON")
    or Constants.SPRITE_ID
  return {
    image = image,
    frames = 1,
    walker = false,
    trueColor = true,
    id = fallbackId,
    fallback = true,
  }
end

function ControlEngine:forceYellowStockPikachuArt(ow, game)
  if not self:_isYellow() then return end
  local npc = self:_findStockPikachu(ow)
  if not npc then return end
  game = game or self:_game()
  -- The stock NPC renders the SELECTED leader's art (it is slot 1 of the
  -- pack); the party Pikachu trails behind like any other party mon unless
  -- it IS the leader. Rebinding it to the party Pikachu's art instead is
  -- what made Pikachu take priority over the chosen follower.
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
  local ok, sprite = pcall(SpriteRenderer.new, spriteDefWithGeometry(resolved, {
    id = Constants.SPRITE_ID,
    frames = resolvedFrames,
    walker = resolvedWalker,
    trueColor = resolvedTrueColor,
  }), npc.id or Constants.ENTITY_ID)
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

--- True Size: check whether visual trail spacing (followGap) is active.
-- Controlled by the same option toggle as wild sizing.
function ControlEngine:_visualTrailSpacingActive()
  local ok, VariableSize = pcall(function() return V.require("variable_size") end)
  if not ok or not VariableSize or not VariableSize.canApplyTrueSize then
    return false
  end
  return VariableSize.canApplyTrueSize(self.mod) == true
end

--- Return a numeric species id for a trail source (mon table, spec, or npc).
function ControlEngine:_speciesIdForTrailSource(source)
  if not source then return nil end
  if type(source) == "number" then return source end
  if type(source) == "table" then
    if source.kind == "trainer" then return nil end
    local mon = source.mon or source.pokepcMon
    local species = source._wildsFollowerSpecies
      or source._pokepcFollowerSpecies
      or (mon and mon.species)
      or source.species
    local SpeciesAssets = V.require("species_assets")
    if type(species) == "string" then
      local assetId = SpeciesAssets.idFor(species)
      if type(assetId) == "number" then return assetId end
      return species
    end
    -- Prefer already-canonical enhancedDexId; never mon.dex (runtime).
    local assetId = SpeciesAssets.idFor(source._wildsFollowerDex or source.enhancedDexId)
    return assetId or species
  end
  return nil
end

--- Size-aware follower gap for a single mon in the trail convoy.
-- @return integer gap (1 for Classic, >= 1 for True Size)
function ControlEngine:_followGapForSource(source)
  if not self:_visualTrailSpacingActive() then return 1 end
  local ok, SpeciesGeometry = pcall(function() return V.require("species_geometry") end)
  if not ok or not SpeciesGeometry or not SpeciesGeometry.followGap then
    return 1
  end
  return SpeciesGeometry.followGap(self:_speciesIdForTrailSource(source), self.mod)
end

--- Record a trail-head position into the per-overworld history ring buffer.
function ControlEngine:_pushTrailHistory(ow, x, y)
  if not ow then return end
  local history = ow.pokepcTrailHistory
  if type(history) ~= "table" then
    history = {}
    ow.pokepcTrailHistory = history
  end
  table.insert(history, 1, { x = x, y = y })
  -- Max convoy ~6 × max gap 3, plus slack for ledge double-steps.
  while #history > 24 do
    table.remove(history)
  end
end

--- Clear trail history (map change, re-seed, etc.).
function ControlEngine:_clearTrailHistory(ow)
  if ow then ow.pokepcTrailHistory = {} end
end

--- Assign trailer goals from vacated-cell history using size-aware lag.
-- gap_i = max(gap(previous), gap(current)); lag accumulates through the convoy.
--
-- The cell the trail head currently occupies (the player's cell) is never a
-- valid goal: when the player doubles back over walked ground, that cell
-- sits inside the history buffer and a lag index can land on it — the
-- follower then walks INTO the player, the True Size reversal
-- "slingshot".  Lag skips past any head-cell entries (and the fallback is
-- filtered too), so followers always aim behind the head.
function ControlEngine:_goalsFromTrailHistory(ow, trailers, fallbackX, fallbackY)
  local history = (ow and ow.pokepcTrailHistory) or {}
  local goals = {}
  local head = ow and ow.pokepcTrailHead
  local hx, hy = head and head.x, head and head.y
  local function offHead(c)
    return c and (hx == nil or c.x ~= hx or c.y ~= hy)
  end
  -- One-cell lag: follower i aims at the cell vacated i steps ago — the
  -- exact classic snake.  Size-based whole-cell gaps made big (True Size)
  -- sprites spread far behind the player AND let lag goals cross on a
  -- doubled-back trail: the pack turned around at the trail's end one
  -- follower at a time, physically swapped order, and then deadlocked —
  -- the reversal "chain break".  Keeping every follower exactly one cell
  -- behind the one ahead is order-preserving by construction (the Classic
  -- snake that never breaks) and keeps the pack tight against the player.
  for i, npc in ipairs(trailers or {}) do
    local cell
    if hx ~= nil then
      -- Walk forward from the exact lag until an off-head cell is found
      -- (the lag slot itself can be the head cell on a doubled-back path).
      for scan = i, #history do
        if offHead(history[scan]) then
          cell = history[scan]
          break
        end
      end
    else
      cell = history[i]
    end
    if not cell then
      local last = history[#history]
      if last and offHead(last) then cell = last end
    end
    goals[i] = cell and { x = cell.x, y = cell.y }
      or { x = fallbackX, y = fallbackY }
  end
  return goals
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
  -- After permanent faint failover, selectedMonKey always matches the
  -- healthy leader. leadIsSubstitute remains for rare mid-frame races
  -- before reconcile runs (should be false once reconcile has settled).
  --
  -- NOTE: selKey is Selection's monFingerprint (colon-separated
  -- species:otId:dv:...), NOT ControlEngine.monIdentityKey (pipe-separated
  -- species|level|nickname|otId|...). Compare the leader's own fingerprint
  -- in the selection format instead of mixing key formats.
  local selKey = self.selection and self.selection.state
    and self.selection.state.selectedMonKey
  local leadIsSubstitute = false
  if selKey and leader and self.selection
     and type(self.selection.monFingerprint) == "function" then
    local leadFp = self.selection.monFingerprint(leader)
    leadIsSubstitute = leadFp ~= nil and leadFp ~= selKey
  end
  local front = self:isPokemonFront(game)

  -- Identify if stock Pikachu is active. In Yellow follow mode the stock
  -- NPC renders the ACTIVE leader's art (forceYellowStockPikachuArt), so the
  -- leader must not also trail (that would render the spot-1 mon twice) —
  -- and when the leader IS Pikachu, the party Pikachu is reserved for the
  -- stock NPC. Any other party Pikachu trails like a normal party mon.
  local isStockPikaActive = self:yellowStockFollowActive(game)
  local pikaIdx = self:_partyPikachuIndex(save)
  local pikaIsLeader = pikaIdx ~= nil and leadKey ~= nil
    and ControlEngine.monIdentityKey(save.party[pikaIdx]) == leadKey
  local skipPikaIdx = (isStockPikaActive and pikaIsLeader) and pikaIdx or nil

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

  if not front and leader and not leadIsSubstitute then
    -- The stock NPC (when active) renders the leader and reserves slot 1, so
    -- the leader push is skipped here (skipMon blocks it below); the other
    -- party mons — including Pikachu — trail behind in party order.
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
  if not player or not game then return end
  local GameCompat = V.require("game_compat")
  if GameCompat.isGen2(self.mod, game) then
    local ok, err = GameCompat.restoreTrainerSprite(player, game, ow)
    if not ok then
      logWarn(self.mod, "[Wilds][Follower][Gen2] restore trainer sprite failed: %s",
        tostring(err))
      logGen2(self.mod, "restore trainer sprite failed: %s", tostring(err))
    end
    return
  end
  if not game.data then return end
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
    player._pokepcControlStyle = nil
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
  if not mon and self.selection
     and type(self.selection.getActiveFollowerMon) == "function" then
    -- CONTROL=POKEMON with FOLLOWERS=0 still needs the selected party mon.
    -- getLeaderMon returns nil when count is 0 (party menu FOLLOW vs ACTIVE).
    local ok, sel = pcall(self.selection.getActiveFollowerMon, self.selection, game, true)
    if ok then mon = sel end
  end
  if not mon then
    local save = game and game.save
    local idx = save and save.followerPartyIndex
    if idx and save.party then mon = save.party[idx] end
    if not mon then
      for _, pmon in ipairs((save and save.party) or {}) do
        if (pmon.hp or 0) > 0 then mon = pmon break end
      end
    end
  end
  local species = mon and mon.species or "CHARMANDER"
  local shiny = isShinyMon(mon)
  local Config
  pcall(function() Config = V.require("config") end)
  local style = Config and Config.spriteStyle and Config.spriteStyle(self.mod)
  -- Skip expensive sprite resolution when presentation is unchanged.
  if not force and player._pokepcAsPokemon and player._pokepcControlSpecies == species
     and player._pokepcShiny == (shiny and true or false)
     and player._pokepcControlStyle == style
     and ((player.sprite and player.sprite.def and player.sprite.def.image)
          or (player.spriteDef and player.spriteDef.image)) then
    return
  end
  local resolved = self:resolveFollowerSprite({
    species = species,
    shiny = shiny,
    surface = "land",
    role = "player_controlled",
    game = game,
  })
  local path = resolved and resolved.image
  local GameCompat = V.require("game_compat")
  local dex = (resolved and (resolved.assetId or resolved.dex))
    or (V.require("species_assets")).idFor(species)
  local fallback = (resolved and resolved.fallback == true)
    or isMissingFallbackImage(path)
  logGen2(self.mod,
    "[PlayerSprite] species=%s dex=%s style=%s role=player_controlled resolved=%s fallback=%s",
    tostring(species),
    tostring(dex or "?"),
    tostring(style or "?"),
    tostring(path or "nil"),
    tostring(fallback == true))
  if fallback then
    logWarn(self.mod,
      "[Wilds][Follower][Gen2][PlayerSprite] missing sprite species=%s dex=%s resolved=%s",
      tostring(species), tostring(dex or "?"), tostring(path or "nil"))
  end
  local already = player.sprite and player.sprite.def and player.sprite.def.image == path
  if not already and player.spriteDef and player.spriteDef.image == path then
    already = true
  end
  if not force and player._pokepcAsPokemon and player._pokepcControlSpecies == species
     and player._pokepcShiny == (shiny and true or false)
     and player._pokepcControlStyle == style
     and already then
    return
  end
  if not path then
    logWarn(self.mod, "[Wilds][Follower][Gen2] player sprite skipped: no image")
    logGen2(self.mod, "player sprite skipped: no image species=%s", tostring(species))
    return
  end
  local def = spriteDefWithGeometry(resolved, {
    id = (resolved and resolved.id)
      or (GameCompat.isGen2(self.mod, game) and "SPRITE_WILDS_PLAYER_MON"
        or "SPRITE_PLAYER_POKEMON"),
    pokepcShiny = shiny and true or false,
  })
  -- Gold: Player:setSprite(def). Do not require a Gen1 SpriteRenderer
  -- assignment and do not register SPRITE_PLAYER_POKEMON.
  if GameCompat.isGen2(self.mod, game) then
    local ok, how = GameCompat.applyControlledPokemonSprite(player, def, game)
    if not ok then
      logWarn(self.mod, "[Wilds][Follower][Gen2] Gold player sprite apply failed: %s",
        tostring(how))
      logGen2(self.mod, "player sprite apply failed: %s", tostring(how))
      return
    end
    logGen2(self.mod, "player sprite applied via %s", tostring(how))
    player._pokepcAsPokemon = true
    player._pokepcControlSpecies = species
    player._pokepcShiny = shiny and true or false
    player._pokepcControlStyle = style
    return
  end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new) then
    logWarn(self.mod, "SpriteRenderer.new unavailable for player pokemon")
    return
  end
  local ok, sprite = pcall(SpriteRenderer.new, {
    id = "SPRITE_PLAYER_POKEMON",
    image = path,
    frames = (resolved and resolved.frames) or 6,
    walker = not resolved or resolved.walker ~= false,
    trueColor = not resolved or resolved.trueColor ~= false,
    pokepcShiny = shiny and true or false,
  }, "player")
  if not ok then
    logWarn(self.mod, "SpriteRenderer.new failed (player pokemon): %s", tostring(sprite))
    return
  end
  if ok and sprite then
    player.sprite = sprite
    player._pokepcAsPokemon = true
    player._pokepcControlSpecies = species
    player._pokepcShiny = shiny and true or false
    player._pokepcControlStyle = style
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
  if self:_battleReturnActive() then
    self:_traceBattleReturn("removeTrailers", self:_game(), ow)
  end
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

function ControlEngine:makeTrailer(game, ow, x, y, facing, kind, mon, slot, opts)
  opts = opts or {}
  local GameCompat = V.require("game_compat")
  local gen2 = GameCompat.isGen2(self.mod, game)
  -- Gen2 must not pcall-require src.world.NPC: Loader.callerIsMod(3) treats
  -- the C pcall frame as engine code, skips the Gen2Compat alias, and can
  -- cache Gen1 NPC.lua (invisible under Gold drawPeople). Construction
  -- goes through Gen2.npcModule → src.world.gen2.Npc.
  local NPC = nil
  if not gen2 then
    NPC = tryRequire("src.world.NPC")
    if not (NPC and NPC.new) then return nil end
  end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")

  local species = (kind ~= "trainer") and (mon and mon.species or "CHARMANDER") or "trainer"
  local surfaceHint = opts.surface or self:_trailSurface(ow, game) or "land"
  if gen2 then
    logGen2(self.mod, "makeTrailer BEGIN slot=%s species=%s surface=%s",
      tostring(slot), tostring(species), tostring(surfaceHint))
  else
    logGen2(self.mod, "makeTrailer species=%s", tostring(species))
  end

  local resolved, trainerDef, surface
  if kind == "trainer" then
    trainerDef = self:_trainerWalkDef(game)
    if not trainerDef and gen2 and ow and ow.player then
      trainerDef = ow.player.spriteDef
    end
  else
    surface = opts.surface or self:_trailSurface(ow, game) or "land"
    resolved = self:resolveFollowerSprite({
      species = species,
      shiny = isShinyMon(mon),
      form = mon and mon.form,
      surface = surface,
      role = "party_trailer",
      game = game,
    })
  end
  local spriteDef = trainerDef
  if kind ~= "trainer" and resolved and resolved.image then
    spriteDef = spriteDefWithGeometry(resolved, {
      pokepcShiny = isShinyMon(mon) and true or false,
    })
  end

  if gen2 then
    logGen2(self.mod,
      "sprite image=%s SpriteDef id=%s frameWidth=%s frameHeight=%s trueColor=%s",
      tostring(spriteDef and spriteDef.image),
      tostring(spriteDef and spriteDef.id),
      tostring(spriteDef and spriteDef.frameWidth),
      tostring(spriteDef and spriteDef.frameHeight),
      tostring(spriteDef and spriteDef.trueColor))
  end

  local npc
  if gen2 then
    if not (spriteDef and spriteDef.image) then
      logGen2(self.mod, "makeGuestNpc success=false error=spriteDef.image missing species=%s",
        tostring(species))
      error("makeTrailer Gold spriteDef missing species=" .. tostring(species))
    end
    local err
    npc, err = GameCompat.makeGuestNpc(game, ow, {
      index = TRAILER_BASE + slot,
      name = "WILDS_TRAILER_" .. tostring(slot),
      spriteId = Constants.SPRITE_ID,
      spriteDef = spriteDef,
      x = x, y = y,
      facing = facing,
    })
    logGen2(self.mod,
      "makeGuestNpc success=%s error=%s type=%s id=%s cell=%s,%s spriteDef=%s sprite=%s source=%s movement=%s",
      tostring(npc ~= nil),
      tostring(err),
      type(npc),
      tostring(npc and npc.id),
      tostring(npc and npc.cellX), tostring(npc and npc.cellY),
      tostring(npc and npc.spriteDef ~= nil),
      tostring(npc and npc.sprite ~= nil),
      tostring(npc and npc._wildsGoldNpcSource or "?"),
      tostring(npc and npc._wildsGoldMovement))
    if not npc then
      error("makeTrailer Gold NPC.new failed: " .. tostring(err))
    end
  else
    npc = NPC.new(game.data, ow.map.id, {
      index = TRAILER_BASE + slot,
      name = "WILDS_TRAILER_" .. tostring(slot),
      sprite = Constants.SPRITE_ID,
      movement = "STAY", range = "NONE", x = x, y = y,
    })
  end
  -- Legacy occupancy/water compat + Wilds role markers.
  npc.pokepcTrailer = true
  npc.wildsFollower = true
  npc.wildsFollowerRole = (kind == "trainer") and "trainer_trailer" or "party_trailer"
  npc.pokepcTrailerKind = kind
  npc.pokepcTrailerId = kind .. ":" .. tostring(slot)
  npc.wildsFollowerSlot = slot
  npc.pokepcMon = mon
  npc.passable = true
  npc.facing = facing or "down"
  npc.overworldWildSpawn = false
  npc.wildsBattleable = false
  npc.wildsAggressive = false
  npc.wildsEncounterEnabled = false
  -- Draw-order tiebreak: the engine y-sorts entities by py with a
  -- tie-break that only special-cases pikachuFollower (which trailers
  -- must NOT set — stock findFollower would remove them), so two
  -- overlapping trailers (same cell: entry parking, folds, re-seeds)
  -- get an arbitrary, frame-varying draw order — the flicker on tall
  -- True Size sprites.  Bias each trailer's py by a sub-pixel slot
  -- offset: the leader (slot 1) draws on top of the pack, and every
  -- trailer stays just UNDER the player's own exact py.  py is purely
  -- presentation for trailers (movement/collision use cellX/cellY), so
  -- the bias is invisible and only makes the engine's sort deterministic.
  npc._wildsDrawBias = -slot * 0.001
  -- NPC.new parked this trailer at (x, y) without the offset — carry the
  -- bias onto the spawn pose so a fresh stack sorts consistently with its
  -- biased siblings on the first draw.
  npc.py = (npc.py or y * 16) + (npc._wildsDrawBias or 0)
  -- NEVER set pikachuFollower on trailers (stock findFollower would remove them).
  npc.pikachuFollower = false
  npc.pokepcTalkablePikachu = (kind ~= "trainer"
    and self:_isYellow()
    and mon and mon.species == "PIKACHU") and true or false

  if kind == "trainer" then
    -- Walk sheets are DMG greyscale; trueColor would draw raw greys.
    local def = trainerDef or self:_trainerWalkDef(game)
    if def and SpriteRenderer and SpriteRenderer.new then
      local ok, sprite = pcall(SpriteRenderer.new, {
        id = def.id or "SPRITE_RED",
        image = def.image,
        frames = def.frames or 6,
        walker = def.walker ~= false,
        source = def.source,
        paletteSource = def.paletteSource,
      }, npc.id)
      if not ok then
        logWarn(self.mod, "SpriteRenderer.new failed (trainer trailer): %s", tostring(sprite))
      elseif sprite then
        npc.sprite = sprite
        if gen2 then npc.spriteDef = def end
      end
    end
  else
    local shiny = isShinyMon(mon)
    npc.pokepcShiny = shiny and true or false
    surface = surface or opts.surface or self:_trailSurface(ow, game) or "land"
    if resolved and resolved.image and SpriteRenderer and SpriteRenderer.new then
      -- Native Gold NPC.new already built SpriteRenderer from spriteDef
      -- (Follower.lua does not rebuild it). Keep that sprite unless missing.
      if gen2 and npc.sprite then
        npc.spriteDef = npc.spriteDef or spriteDef
      else
        local ok, sprite = pcall(SpriteRenderer.new, spriteDefWithGeometry(resolved, {
          pokepcShiny = npc.pokepcShiny,
        }), npc.id)
        if not ok then
          logWarn(self.mod, "SpriteRenderer.new failed (party trailer %s): %s",
            tostring(species), tostring(sprite))
          logGen2(self.mod, "SpriteRenderer.new failed species=%s err=%s",
            tostring(species), tostring(sprite))
        elseif sprite then
          npc.sprite = sprite
          if gen2 then npc.spriteDef = sprite.def or spriteDef end
        end
      end
    end
    npc._wildsFollowerSpecies = species
    npc.wildsFollowerWater = (surface == "water" or surface == "surfing")
    npc.spriteState = (surface == "water" or surface == "surfing") and "water" or "land"
  end

  -- Walk-cycle animation: mirror the player (continuous animClock, so leg
  -- cadence survives step-length changes like surf/bike) instead of the
  -- stock NPC's per-step progress reset. stepFlip alternates the up/down
  -- walk-frame mirror every completed step; without it the sprite is stuck
  -- on one pose and looks dragged along.
  npc.stepFlip = false
  npc.animClock = 0
  npc.stepLanded = false
  if (NPC and NPC.walkPhase) or gen2 then
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
  npc.update = NO_UPDATE
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
  local GameCompat = V.require("game_compat")
  return GameCompat.isSurfing(game, ow) == true
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
    if ok and outside ~= nil then return outside == true end
  end
  if map.def.outdoor ~= nil then return map.def.outdoor == true end
  local tileset = tostring(map.def.tileset or ""):upper()
  local id = tostring(map.id or map.def.id or ""):upper()
  -- Buildings / interiors: never a walking seam (Yellow door parking).
  if tileset == "HOUSE" or tileset == "POKECENTER" or tileset == "POKEMON_CENTER"
     or tileset == "MART" or tileset == "POKEMART" or tileset == "GYM"
     or tileset == "GATE" or tileset == "INTERIOR" or tileset == "LAB"
     or tileset == "SCHOOL" or tileset == "MUSEUM" or tileset == "SHIP"
     or tileset == "FACILITY" or tileset == "MANSION" or tileset == "CAVERN"
     or tileset == "UNDERGROUND" or tileset == "TOWER" or tileset == "RUINS"
     or tileset:find("HOUSE", 1, true) or tileset:find("CENTER", 1, true)
     or tileset:find("INTERIOR", 1, true) or tileset:find("GYM", 1, true)
     or tileset:find("GATE", 1, true) or tileset:find("MART", 1, true) then
    return false
  end
  if id:find("_HOUSE", 1, true) or id:find("POKECENTER", 1, true)
     or id:find("POKEMON_CENTER", 1, true) or id:find("_GYM", 1, true)
     or id:find("_MART", 1, true) or id:find("_GATE", 1, true) then
    return false
  end
  if tileset == "OVERWORLD" or tileset == "PLATEAU" or tileset == "TOWN"
     or tileset == "FOREST" or tileset == "JOHTO" or tileset == "KANTO" then
    return true
  end
  if id:find("ROUTE", 1, true) or id:find("_TOWN", 1, true)
     or id:find("_CITY", 1, true) or id:find("LAKE", 1, true)
     or id:find("PARK", 1, true) then
    return true
  end
  return false
end

function ControlEngine:_playerNearMapEdge(map, x, y)
  if not map or x == nil or y == nil then return false end
  local w = tonumber(map.widthCells) or tonumber(map.def and map.def.width) or 0
  local h = tonumber(map.heightCells) or tonumber(map.def and map.def.height) or 0
  if w > 0 and h > 0 then
    return x <= 1 or y <= 1 or x >= (w - 2) or y >= (h - 2)
  end
  if type(map.inBounds) == "function" then
    local function inside(cx, cy)
      local ok, value = pcall(map.inBounds, map, cx, cy)
      return ok and value == true
    end
    if not inside(x, y) then return true end
    return not inside(x - 1, y) or not inside(x + 1, y)
        or not inside(x, y - 1) or not inside(x, y + 1)
  end
  return false
end

-- Walking map seam vs door / warp / script teleport.
function ControlEngine:_isWalkingSeam(game, ow, ev, snapshot)
  if not snapshot then return false end
  local via = ev and ev.via
  if via == "warp" or via == "script" or via == "teleport" or via == "fly"
     or via == "dig" or via == "healing" or via == "door" then
    return false
  end
  local fromMap = snapshot.map
  local toMap = (ev and ev.map) or (ow and ow.map)
  if not (self:_isOutsideMap(game, fromMap) and self:_isOutsideMap(game, toMap)) then
    return false
  end
  if via == "connection" then return true end
  local dest = ow and ow.player
  return self:_playerNearMapEdge(fromMap, snapshot.playerX, snapshot.playerY)
      or self:_playerNearMapEdge(toMap, dest and dest.cellX, dest and dest.cellY)
      or (ow and type(ow.neighbors) == "table" and ow.neighbors[1] ~= nil)
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
    trailHistory = copyTrailCells(ow.pokepcTrailHistory),
  }
  return true
end

--- Select seamless outside-to-outside entries for a soft handoff.
function ControlEngine:_queueMapEntry(game, ow, ev)
  local snapshot = self._mapExitSnapshot
  self._mapExitSnapshot = nil
  self._pendingConnectionHandoff = nil
  if ow then ow._wildsFollowerSeamActive = nil end
  if not snapshot then return false end
  if snapshot.toMapId and ev and ev.mapId and snapshot.toMapId ~= ev.mapId then
    return false
  end
  if not self:_isWalkingSeam(game, ow, ev, snapshot) then
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
  local game = self:_game()
  for _, trailer in ipairs(snapshot.trailers) do
    translateTrailer(trailer, dx, dy)
    self:_attachTrailer(game, ow, trailer)
  end
  for _, cell in ipairs(snapshot.trailCells or {}) do
    cell.x, cell.y = cell.x + dx, cell.y + dy
  end
  local head = snapshot.trailHead
  if head then head.x, head.y = head.x + dx, head.y + dy end
  ow.pokepcTrailers = snapshot.trailers
  ow.pokepcTrailCells = snapshot.trailCells
  ow.pokepcTrailHead = head or { x = player.cellX, y = player.cellY }
  for _, cell in ipairs(snapshot.trailHistory or {}) do
    if cell then
      cell.x, cell.y = (cell.x or 0) + dx, (cell.y or 0) + dy
    end
  end
  ow.pokepcTrailHistory = snapshot.trailHistory or ow.pokepcTrailHistory
  ow._wildsFollowerSeamActive = true
  self._pendingMapTrailerSync = false
  self._pendingSpawnAtPlayer = false
  -- Followers are already at lag cells. Do not wait extra frames.
  ow._wildsEntryCooldown = nil
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
  npc.px, npc.py = x * 16, y * 16 + (npc._wildsDrawBias or 0)
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
function ControlEngine:_pickTrailerStep(game, ow, npc, gx, gy, surface, role,
                                        cellFree)
  local cx, cy = npc.cellX or 0, npc.cellY or 0
  local dx, dy = gx - cx, gy - cy
  local function allowed(sx, sy)
    return (not cellFree or cellFree(sx, sy, npc))
      and self:isFollowerCellAllowed(game, ow, npc, sx, sy, {
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
        if (not cellFree or cellFree(hx, hy, npc))
           and self:isFollowerCellAllowed(game, ow, npc, hx, hy, {
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
  -- Draw-order tiebreak rides on py every frame — mid-step fold swaps
  -- cross at equal pixel y, and without the bias that transient tie
  -- flickers exactly like a standing stack.
  npc.py = (fromY + (toY - fromY) * t) * 16 + (npc._wildsDrawBias or 0)
  if npc.progress >= frames then
    npc.cellX, npc.cellY = toX, toY
    npc.px, npc.py = toX * 16, toY * 16 + (npc._wildsDrawBias or 0)
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

--- True when the pack has a REAL walked trail (at least one goal cell off
-- the anchor) to re-form along, vs a degenerate fresh-entry parking trail.
function ControlEngine:_seedTrailIsDistinct(ow, anchor, n)
  local trail = ow.pokepcTrailCells or {}
  local px = anchor and anchor.cellX or 0
  local py = anchor and anchor.cellY or 0
  for i = 1, math.min(n, #trail) do
    local t = trail[i]
    if t and (t.x ~= px or t.y ~= py) then return true end
  end
  return false
end

--- Re-seed trailers preferring the EXISTING trail goals (the player's
-- actual walked path — every cell walkable and connected by construction),
-- so a re-form after a collapse re-forms ALONG the trail instead of behind
-- the anchor's geometric facing.  At a door the anchor's facing points INTO
-- the building, and the behind cells can be an enclosed walkable pocket
-- (e.g. the cells north of the Pewter Poke Center) from which the pack can
-- never path out — the Yellow "stuck behind the Poke Center" bug.  Trail
-- cells are never a building interior; a trailer with no trail cell parks
-- on the anchor's own cell and walks out as the trail re-opens.
function ControlEngine:_seedTrailBehind(ow, anchor, facing, n, game, role)
  local goals = {}
  local px = anchor.cellX or 0
  local py = anchor.cellY or 0
  facing = facing or anchor.facing or "down"
  role = role or "party_trailer"
  local trail = ow.pokepcTrailCells or {}
  local surface = self:_trailSurface(ow, game)
  -- A DEGENERATE trail (no cells, or every cell the anchor's own — fresh
  -- entry parking / nothing following yet) means there is no walked path to
  -- re-form along; the geometric behind-facing seed is the right call there
  -- (surf entry seeds water cells behind the player; mid-play rebuilds).
  -- A REAL trail (distinct cells) means the pack was following the player's
  -- path — re-form ALONG it, never behind the anchor's facing (which at a
  -- door points INTO the building, and whose behind cells can be an
  -- enclosed walkable pocket the pack can never path out of — the Yellow
  -- "stuck behind the Poke Center" bug).
  local distinct = self:_seedTrailIsDistinct(ow, anchor, n)
  if not distinct then
    -- Water (surf) entry with no trail: the pack must seed onto water cells
    -- behind the player (geometric), or it would freeze on the shore.
    if surface == "water" then
      local occupied = {}
      occupied[px .. "," .. py] = true
      for i = 1, n do
        local bx, by = self:_walkableBehind(ow, px, py, facing, i, nil, game, role, occupied)
        goals[i] = { x = bx, y = by }
        occupied[bx .. "," .. by] = true
      end
      return goals
    end
    -- Land with no real trail (fresh entry where the spawnAtPlayer parking
    -- was skipped / raced, or a mid-play rebuild): park the pack on the
    -- PLAYER's cell so it walks out as the trail opens — exactly the
    -- Red/Blue door-exit look.  NEVER spread it behind the anchor's facing:
    -- at a door that facing points INTO the building, and the behind cells
    -- can be an enclosed walkable pocket the pack can never path out of
    -- (the Yellow "loads in as the full trail, stuck behind the building"
    -- bug).
    local p = ow and ow.player
    local parkX = p and p.cellX or px
    local parkY = p and p.cellY or py
    for i = 1, n do
      goals[i] = { x = parkX, y = parkY }
    end
    return goals
  end
  -- Dedupe the trail into distinct, in-order cells.  On a doubled-back path
  -- (reversal / zigzag) the same physical cell can appear at several lags,
  -- so the trail table can alias two followers onto one cell; re-seeding
  -- them stacked re-creates the jam instantly (reform #2) instead of
  -- fixing it.  Claim each cell once so the pack lands spread out in trail
  -- order; stragglers fall back to walkable cells behind the anchor.
  local distinct = {}
  local claimed = {}
  for _, t in ipairs(trail) do
    if t and not claimed[t.x .. "," .. t.y]
       and self:isFollowerCellAllowed(game, ow, nil, t.x, t.y, {
         surface = surface, role = role,
       }) then
      claimed[t.x .. "," .. t.y] = true
      distinct[#distinct + 1] = t
    end
  end
  local occupied = {}
  for i = 1, n do
    local t = distinct[i]
    if t then
      goals[i] = { x = t.x, y = t.y }
      occupied[t.x .. "," .. t.y] = true
    else
      -- Off the trail (short trail / collapsed tail / all distinct cells
      -- exhausted): park the trailer at a walkable cell BEHIND the anchor
      -- (distinct from every other re-seeded trailer), falling back to the
      -- anchor's own cell only when nothing behind is available.  It walks
      -- out as the trail re-opens.
      local bx, by = self:_walkableBehind(ow, px, py, facing, i, nil, game, role, occupied)
      occupied[bx .. "," .. by] = true
      goals[i] = { x = bx, y = by }
    end
  end
  return goals
end

--- Park the stock Yellow Pikachu NPC on the player's cell after a fresh map
-- entry. The engine's own PikachuFollower.onMapEntered does this when handed
-- viaMapLoad, but Wilds wraps that call and cannot rely on every engine
-- version passing the flag, so the pack seed does it explicitly: the whole
-- train (stock NPC + trailers) walks out from under the player instead of
-- materializing behind his facing (stuck behind buildings on door exits).
function ControlEngine:_parkStockPikachuAtPlayer(ow)
  local p = ow and ow.player
  if not p then return end
  local npc = self:_findStockPikachu(ow)
  if not npc and self:yellowStockFollowActive(self:_game()) then
    -- The engine's entry spawn may have been skipped (shouldSpawn
    -- transiently false during the warp) or the transitional frame raced
    -- it.  Ask the engine to spawn the stock Pikachu now, parked on the
    -- player's cell (viaMapLoad = fresh-entry parking), so the pack walks
    -- out from under him instead of trailing in behind.
    local PF = tryRequire("src.world.PikachuFollower")
    if PF and PF.onMapEntered then
      pcall(function() PF.onMapEntered(self:_game(), ow, nil, true) end)
      npc = self:_findStockPikachu(ow)
    end
  end
  if not npc then return end
  npc.cellX, npc.cellY = p.cellX, p.cellY
  npc.px, npc.py = (p.cellX or 0) * 16, (p.cellY or 0) * 16
  npc.targetX, npc.targetY = nil, nil
  npc.goalX, npc.goalY = nil, nil
  npc.moving = false
  npc.progress = 0
  npc.marching = nil
  npc.hopStep = nil
  npc.idle = nil
  local trail = ow.pikachuTrail
  if trail then trail.x, trail.y = p.cellX, p.cellY end
end

--- Seed every trailer ON the player's cell, mirroring the engine's stock
-- Yellow Pikachu on a fresh map entry: the pack parks hidden under the
-- player (draw-sort) and walks out behind him as the trail opens up, instead
-- of materializing in the cells behind his facing (which on a building exit
-- can land inside walls or behind the building). Anchored to the PLAYER, not
-- the trail anchor: on Yellow the anchor is the stock Pikachu NPC, which may
-- itself still be settling after a map entry.
function ControlEngine:_seedTrailAtPlayer(ow, anchor, n)
  local goals = {}
  local p = ow and ow.player
  local px = p and p.cellX or 0
  local py = p and p.cellY or 0
  for i = 1, n do
    goals[i] = { x = px, y = py }
  end
  return goals
end

local function trailersAliveInWorld(ow, trailers)
  if not trailers or #trailers == 0 then return true end
  local ents = ow.entities or {}
  local npcs = ow.npcs or {}
  for _, t in ipairs(trailers) do
    local found = false
    for _, e in ipairs(ents) do
      if e == t then found = true; break end
    end
    if not found then
      for _, n in ipairs(npcs) do
        if n == t then found = true; break end
      end
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

--- True when `owner` (a stationary trailer occupying the cell `npc` wants to
-- step into) is itself trying to move to `npc`'s current cell — a mutual
-- cell exchange.  A doubled-back path (reversal) re-spaces the pack at the
-- fold: adjacent followers' goals can point at each other's cells, and with
-- strict reservations NEITHER may move first (each is blocked by the other's
-- occupied cell) — the pack deadlocks scrambled instead of re-forming
-- behind the player.  Allowing the mutual exchange breaks the circular wait:
-- the two followers shuffle past each other and the pack un-jams.
local function trailerSwapIntended(npc, owner, trailers, goals, ow)
  if owner == nil or owner == npc then return false end
  if not (owner.pokepcTrailer == true) then return false end
  if owner.moving then return false end
  local ox, oy = owner.cellX, owner.cellY
  local nx, ny = npc.cellX, npc.cellY
  if ox == nil or oy == nil or nx == nil or ny == nil then return false end
  if ox == nx and oy == ny then return false end
  -- Live goal FIRST: _wildsGoalX/Y goes stale the moment a follower lands
  -- (it holds the goal the follower STARTED a step toward, which after
  -- landing equals the follower's own cell).  A fold-time swap must read
  -- the CURRENT goal from the goals table, or adjacent followers crossing
  -- at a reversal never register as an exchange, the pack deadlocks, and
  -- the jam-recovery resolves it by teleporting (the True Size
  -- "slingshot" pop).
  local ogx, ogy = nil, nil
  for idx, tr in ipairs(trailers or {}) do
    if tr == owner then
      local g = goals and goals[idx]
      if g then ogx, ogy = g.x, g.y end
      break
    end
  end
  if ogx == nil then
    ogx, ogy = owner._wildsGoalX, owner._wildsGoalY
  end
  -- Feasibility: the exchange only works if the occupant can actually step
  -- to the stepper's cell THIS frame.  A goal on the head cell or the
  -- player's current cell is unreachable (the player still stands there),
  -- so treating it as an intended swap lets the stepper walk into an
  -- occupant that cannot move — overlap (the True Size "slingshot").
  if ogx ~= nil then
    local head = ow and ow.pokepcTrailHead
    if head and ogx == head.x and ogy == head.y then return false end
    local p = ow and ow.player
    if p and ogx == p.cellX and ogy == p.cellY then return false end
  end
  return ogx == nx and ogy == ny
end

function ControlEngine:syncTrailers(game, ow, opts)
  opts = opts or {}
  -- "no_context" tells update() the world wasn't ready (a transitional
  -- frame before the new map is fully live), so it keeps the pending
  -- map-entry seed and retries on the next update instead of letting the
  -- pack materialize behind the player.
  if self:_battleReturnActive() then
    self:_traceBattleReturn("syncTrailers", game, ow)
  end
  if not ow or not ow.player or not ow.map then
    local reason = (not ow and "no_world")
      or (not ow.player and "missing player")
      or "missing map"
    logGen2Once(self, "sync_no_context:" .. reason,
      "syncTrailers exit=%s wantN=? (Gold world must be game.world, not game.overworld)",
      reason)
    return false, "no_context"
  end
  self.diag.syncTrailersCalls = (self.diag.syncTrailersCalls or 0) + 1
  local mode = self:controlMode(game)
  local want = {}
  local surfing = self:_playerSurfing(ow, game)
  local surface = surfing and "water" or "land"

  -- Solo "pokemon" with a pack size still trails party mons (no trainer NPC).
  if mode == "pokemon" and self:followerCount(game) > 0 then
    mode = "pack"
  end

  local trailMons = {}
  if mode == "lead_trainer" then
    trailMons = self:partyTrailMons(game)
    for _, entry in ipairs(trailMons) do
      want[#want + 1] = { kind = "mon", mon = entry.mon }
    end
    -- Trainer trailers must not swim: hide while surfing, restore on land.
    if not surfing then
      want[#want + 1] = { kind = "trainer", mon = nil }
    end
  elseif mode == "follow" or mode == "pack" then
    trailMons = self:partyTrailMons(game)
    for _, entry in ipairs(trailMons) do
      want[#want + 1] = { kind = "mon", mon = entry.mon }
    end
  end

  local GameCompat = V.require("game_compat")
  if GameCompat.isGen2(self.mod, game) then
    local save = game and game.save
    local party = (save and save.party) or {}
    local leader = self:getLeaderMon(game)
    local configured = self:followerCount(game)
    logGen2Once(self,
      string.format("partyTrail:%s:%s:%s:%s", tostring(mode), tostring(configured),
        tostring(#trailMons), tostring(ow.map and ow.map.id)),
      "mode=%s configuredCount=%s partySize=%s leader=%s desiredTrailers=%s",
      tostring(mode), tostring(configured), tostring(#party),
      tostring(leader and leader.species or "nil"), tostring(#trailMons))
  end

  local trailers = ow.pokepcTrailers or {}
  -- Reassert movement ownership on hot-reloaded / legacy trailer instances.
  for _, npc in ipairs(trailers) do
    if npc and npc.pokepcTrailer then
      if npc.update ~= NO_UPDATE then
        npc.update = NO_UPDATE
      end
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
  -- Late people-list rebuilds drop guests from ow.entities/npcs while
  -- pokepcTrailers still holds the same objects. Reinsert those objects
  -- instead of treating the miss as a species-swap (which never attaches).
  if #trailers > 0 and not trailersAliveInWorld(ow, trailers) then
    if self:_battleReturnActive() then
      self:_traceBattleReturn("syncTrailers.missingFromWorld", game, ow)
    end
    self:_ensureTrailersAttached(game, ow)
    dirty = compositionDirty(trailers, want)
      or not trailersAliveInWorld(ow, trailers)
      or countChanged
  end
  if not dirty and not mapEnter and #trailers > 0 then
    self.diag.lastSeed = "kept"
  end

  local p = ow.player
  local anchor = self:_trailAnchor(game, ow, p)
  local facing = (anchor and anchor.facing) or p.facing or "down"
  local mapEnter = opts.mapEnter == true
  local stepClock = p.stepFramesCur or p.stepFrames
    or (anchor and (anchor.stepFramesCur or anchor.stepFrames)) or 16

  -- Surface transition: reseed once so trail goals leave the frozen shore cell.
  -- Sprite presentation is rebound after composition (existing NPCs keep
  -- identity; newly spawned trailers resolve the correct surface in makeTrailer).
  local prevSurface = ow._wildsFollowerTrailSurface
  local surfaceChanged = prevSurface ~= surface
  if surfaceChanged then
    mapEnter = true
    ow._wildsFollowerTrailSurface = surface
  end
  if dirty or mapEnter or opts.spawnAtPlayer or countChanged then
    local GameCompat = V.require("game_compat")
    if GameCompat.isGen2(self.mod, game) then
      logGen2(self.mod,
        "sync wantN=%s existing=%s dirty=%s mapEnter=%s surface=%s player=%s,%s map=%s",
        tostring(wantN), tostring(#trailers), tostring(dirty),
        tostring(mapEnter or opts.mapEnter == true), tostring(surface),
        tostring(p and p.cellX), tostring(p and p.cellY),
        tostring(ow.map and ow.map.id))
    else
      logGen2(self.mod, "wanted=%s", tostring(wantN))
    end
  end

  -- Yellow only: re-form the train behind the stock Pikachu when the pack
  -- has collapsed onto its cell mid-play.  This must NOT fire right after a
  -- fresh entry, where the pack was deliberately parked on the player's
  -- cell (spawnAtPlayer) — re-seeding behind then would undo the walk-out.
  -- The marker is set by update() on entry parking and cleared only once
  -- the pack has genuinely separated from the anchor (see the committed
  -- block below).  It must also only fire when the train can actually
  -- re-form: if the cell behind the anchor is not follower-walkable, the
  -- re-seed falls back to the anchor's own cell, stacks the pack there, and
  -- fires again next frame — an infinite re-seed loop that freezes the pack
  -- against a wall/building (the Yellow door-exit "stuck up top" bug).
  if not dirty and not ow._wildsEntryParked
     and self:yellowStockFollowActive(game) and anchor ~= p
     and #trailers > 0 then
    local t1 = trailers[1]
    if t1 and not t1.moving
       and t1.cellX == anchor.cellX and t1.cellY == anchor.cellY then
      -- Only re-form when the trail has a REAL cell for the head trailer
      -- behind the anchor.  The anchor may be idle (pack stacked on a
      -- standing stock Pikachu) — re-seeding onto the anchor's own cell
      -- would loop forever.  The trail cell is the player's actual path,
      -- never a building interior (the anchor's facing at a door points
      -- INTO the building — the Yellow "stuck behind the Poke Center" bug).
      local t = (ow.pokepcTrailCells or {})[1]
      if t and (t.x ~= anchor.cellX or t.y ~= anchor.cellY)
         and self:isFollowerCellAllowed(game, ow, t1, t.x, t.y, {
           surface = surface, role = "party_trailer",
         }) then
        mapEnter = true
      end
    end
  end

  if dirty then
    -- When count is unchanged and trailers already exist (only species
    -- shifted, e.g. revive or party menu reorder), swap mon references
    -- in-place so positions are preserved.
    if #trailers > 0 and #trailers == #want then
      for i, spec in ipairs(want) do
        local npc = trailers[i]
        if npc and spec.kind == "mon" and npc.pokepcMon ~= spec.mon then
          npc.pokepcMon = spec.mon
          -- Species art re-resolves on the next render pass via the
          -- existing sprite def (same image path, different species).
          -- Do NOT set npc.sprite = nil — that can crash renderers
          -- that dereference sprite without nil-checking.
        end
      end
      -- Refresh sprites so each trailer shows its new mon's art.
      self:_refreshTrailerMonSprites(game, ow, surface)
      -- Force water sprite refresh if applicable.
      if surface == "water" then
        self._lastTrailSurface = nil
      end
      self._lastSyncedCount = wantN
      self.diag.lastSeed = "species_swap"
    -- Count changed mid-play (not a map entry): preserve existing trailer
    -- positions.  When count decreased (faint), trim excess from tail and
    -- update mon refs.  When count increased (heal, party change), add new
    -- trailers at the anchor.  On map entry (spawnAtPlayer or fresh map),
    -- do a full destroy+re-seed via the normal path.
    elseif mapEnter or opts.spawnAtPlayer then
    -- Full re-seed for map entries: the old positions are from a different map.
    self:removeTrailers(ow)
    trailers = {}
    if opts.spawnAtPlayer then
      self.diag.lastSeed = "parked_at_player"
      self.diag.entryParks = (self.diag.entryParks or 0) + 1
      self:_clearTrailHistory(ow)
    elseif self:_seedTrailIsDistinct(ow, anchor, #want) then
      self.diag.lastSeed = "trail_reform"
      self.diag.trailReforms = (self.diag.trailReforms or 0) + 1
    elseif self:_trailSurface(ow, game) == "water" then
      self.diag.lastSeed = "behind_water"
      self.diag.behindWaterSeeds = (self.diag.behindWaterSeeds or 0) + 1
    else
      self.diag.lastSeed = "parked_at_player"
      self.diag.entryParks = (self.diag.entryParks or 0) + 1
    end
    local goals = opts.spawnAtPlayer
      and self:_seedTrailAtPlayer(ow, anchor, #want)
      or self:_seedTrailBehind(ow, anchor, facing, #want, game, surface)
    for i, spec in ipairs(want) do
      local role = (spec.kind == "trainer") and "trainer_trailer" or "party_trailer"
      local cell = goals[i]
      if not cell or not self:isFollowerCellAllowed(game, ow, nil, cell.x, cell.y, {
        surface = surface, role = role,
      }) then
        cell = { x = anchor.cellX or 0, y = anchor.cellY or 0 }
      end
      local bx, by = cell.x, cell.y
      local okNpc, npc = pcall(function()
        return self:makeTrailer(game, ow, bx, by, facing, spec.kind, spec.mon, i, {
          surface = surface,
        })
      end)
      if not okNpc or not npc then
        logWarn(self.mod, "trailer spawn failed slot %s: %s", tostring(i), tostring(npc))
        logGen2(self.mod, "makeTrailer FAILED slot=%s err=%s", tostring(i), tostring(npc))
      else
        placeTrailerAt(npc, bx, by, facing)
        self:_attachTrailer(game, ow, npc)
        local slot = #trailers + 1
        trailers[slot] = npc
        goals[slot] = { x = bx, y = by }
      end
    end
    ow.pokepcTrailers = trailers
    ow.pokepcTrailCells = goals
    ow.pokepcTrailHead = {
      x = anchor.targetX or anchor.cellX,
      y = anchor.targetY or anchor.cellY,
    }
    self._lastSyncedCount = wantN
    if opts.spawnAtPlayer then
      -- One settle frame so stacked door-exit parking does not slingshot.
      -- The first legitimate player step then starts follower 1 immediately.
      ow._wildsEntryCooldown = 1
    end
    else
    -- Mid-play count change (faint, heal, party menu) or initial sync
    -- without mapEnter (Red/Blue boot).
    local oldN = 0
    for _ in ipairs(trailers) do oldN = oldN + 1 end
    if oldN > 0 then
      -- Build a clean list of kept trailers (trim tail if count decreased).
      local keepN = math.min(oldN, #want)
      local kept = {}
      local keptGoals = {}
      for i = 1, keepN do
        local npc = trailers[i]
        local spec = want[i]
        if npc and spec then
          npc.pokepcMon = spec.mon
          npc.pokepcTrailerKind = spec.kind
          npc.wildsFollowerRole = (spec.kind == "trainer") and "trainer_trailer" or "party_trailer"
          kept[i] = npc
          local cell = ow.pokepcTrailCells and ow.pokepcTrailCells[i]
          keptGoals[i] = cell or { x = npc.cellX or anchor.cellX or 0, y = npc.cellY or anchor.cellY or 0 }
        end
      end
      -- Remove excess trailers from world lists (trimmed tail).
      for i = keepN + 1, oldN do
        local old = trailers[i]
        if old then
          local keepEnt, keepNpc = {}, {}
          for _, e in ipairs(ow.entities or {}) do
            if e ~= old then keepEnt[#keepEnt + 1] = e end
          end
          for _, n in ipairs(ow.npcs or {}) do
            if n ~= old then keepNpc[#keepNpc + 1] = n end
          end
          ow.entities, ow.npcs = keepEnt, keepNpc
        end
      end
      -- Add new trailers at anchor (count increased).
      for i = oldN + 1, #want do
        local spec = want[i]
        local role = (spec.kind == "trainer") and "trainer_trailer" or "party_trailer"
        local bx = anchor.cellX or 0
        local by = anchor.cellY or 0
        local okNpc, npc = pcall(function()
          return self:makeTrailer(game, ow, bx, by, facing, spec.kind, spec.mon, i, {
            surface = surface,
          })
        end)
        if okNpc and npc then
          placeTrailerAt(npc, bx, by, facing)
          self:_attachTrailer(game, ow, npc)
          kept[i] = npc
          keptGoals[i] = { x = bx, y = by }
        else
          logWarn(self.mod, "trailer spawn failed slot %s: %s", tostring(i), tostring(npc))
          logGen2(self.mod, "makeTrailer FAILED slot=%s err=%s", tostring(i), tostring(npc))
        end
      end
      ow.pokepcTrailers = kept
      ow.pokepcTrailCells = keptGoals
      -- Refresh sprites so each trailer shows its new mon's art.
      self:_refreshTrailerMonSprites(game, ow, surface)
      -- Force water sprite refresh if applicable.
      if surface == "water" then
        self._lastTrailSurface = nil
      end
      self.diag.lastSeed = "count_changed"
    else
      -- No existing trailers (e.g. Red/Blue boot): seed new pack
      -- parked at the player so they walk out under him.
      self:removeTrailers(ow)
      trailers = {}
      self.diag.lastSeed = "parked_at_player"
      self.diag.entryParks = (self.diag.entryParks or 0) + 1
      self:_clearTrailHistory(ow)
      local goals = self:_seedTrailAtPlayer(ow, anchor, #want)
      for i, spec in ipairs(want) do
        local role = (spec.kind == "trainer") and "trainer_trailer" or "party_trailer"
        local cell = goals[i]
        if not cell or not self:isFollowerCellAllowed(game, ow, nil, cell.x, cell.y, {
          surface = surface, role = role,
        }) then
          cell = { x = anchor.cellX or 0, y = anchor.cellY or 0 }
        end
        local bx, by = cell.x, cell.y
        local okNpc, npc = pcall(function()
          return self:makeTrailer(game, ow, bx, by, facing, spec.kind, spec.mon, i, {
            surface = surface,
          })
        end)
        if not okNpc or not npc then
          logWarn(self.mod, "trailer spawn failed slot %s: %s", tostring(i), tostring(npc))
          logGen2(self.mod, "makeTrailer FAILED slot=%s err=%s", tostring(i), tostring(npc))
        else
          placeTrailerAt(npc, bx, by, facing)
          self:_attachTrailer(game, ow, npc)
          local slot = #trailers + 1
          trailers[slot] = npc
          goals[slot] = { x = bx, y = by }
        end
      end
      ow.pokepcTrailers = trailers
      ow.pokepcTrailCells = goals
      ow._wildsEntryCooldown = 1
    end
    ow.pokepcTrailHead = {
      x = anchor.targetX or anchor.cellX,
      y = anchor.targetY or anchor.cellY,
    }
    self._lastSyncedCount = wantN
    end  -- inner else (count changed or initial sync)
  end

  -- Land ↔ water: rebind Pokémon trailer sprites on the surviving NPCs
  -- (or on newly spawned ones after a required rebuild). Movement fields
  -- stay on the entity; only SpriteRenderer / sprite def change.
  if surfaceChanged then
    local rebound = self:_refreshTrailerMonSprites(game, ow, surface) or 0
    if prevSurface == "land" or prevSurface == "water" then
      logInfo(self.mod, "follower surface %s -> %s, rebound %d mon sprites",
              tostring(prevSurface), tostring(surface), rebound)
    end
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
    -- The pack is walking out of the entry parking: the collapse heuristic
    -- is allowed to re-form the train again — but only once the pack has
    -- genuinely separated from the anchor (first trailer off its cell or
    -- mid-step away).  Clearing on the FIRST committed step fired the
    -- heuristic while the pack was still deliberately stacked at the entry
    -- cell, re-seeding it behind into walls/buildings and freezing it
    -- (the Yellow door-exit "stuck up top" bug).
    local t1 = trailers[1]
    if not t1 or t1.moving
       or t1.cellX ~= anchor.cellX or t1.cellY ~= anchor.cellY then
      ow._wildsEntryParked = nil
    end
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
      local vacatedX, vacatedY = head.x, head.y
      -- Publish the new head position BEFORE trail-goal selection so
      -- _goalsFromTrailHistory can exclude the cell the player is entering
      -- (on a doubled-back path that cell can sit inside the history
      -- buffer — a lag goal on it makes followers walk into the player,
      -- the True Size "slingshot").
      head.x, head.y = destX, destY
      if self:_visualTrailSpacingActive() then
        -- Visual-only: consume older trail-history points for large sprites.
        -- Logical footprint / collision remain one cell per trailer.
        self:_pushTrailHistory(ow, vacatedX, vacatedY)
        ow.pokepcTrailCells = self:_goalsFromTrailHistory(
          ow, trailers, vacatedX, vacatedY)
      else
        -- Classic / Voxel-effective-Classic: exact historic 1-cell snake.
        if ow.pokepcTrailHistory and #ow.pokepcTrailHistory > 0 then
          self:_clearTrailHistory(ow)
        end
        local goals = ow.pokepcTrailCells or {}
        for i = #trailers, 2, -1 do
          local prev = goals[i - 1]
          goals[i] = prev and { x = prev.x, y = prev.y }
            or { x = vacatedX, y = vacatedY }
        end
        if #trailers >= 1 then
          goals[1] = { x = vacatedX, y = vacatedY }
        end
        ow.pokepcTrailCells = goals
      end
    end
  end

  -- The player just committed a step into a cell; any trailer mid-step into
  -- that SAME cell must abort — they would land on the player (the zigzag
  -- "steps onto head cell" read on True Size sprites, where the follower
  -- walks through the player on the doubled-back).  The follower holds at
  -- its origin cell and re-assigns next frame; the pause is one step.
  if committed and p and p.moving and p.targetX ~= nil and p.targetY ~= nil then
    for i, t in ipairs(trailers) do
      if t.moving and t.targetX ~= nil and t.targetY ~= nil
         and t.targetX == p.targetX and t.targetY == p.targetY then
        t.moving = false
        t.targetX, t.targetY = nil, nil
        t.progress = 0
      end
    end
  end

  -- Step assignment runs every frame: a trailer starts a step as soon as its
  -- goal differs, even on frames where the head did not commit (a trailer that
  -- landed mid-walk must re-step immediately instead of freezing until the
  -- next goal shift). Mid-step trailers are left to advanceAllTrailers.
  local Collision = tryRequire("src.world.Collision")
  local goals = ow.pokepcTrailCells or {}
  -- Reserve both occupied cells and in-flight targets so no trailer can
  -- enter a cell until its current occupant has actually vacated it.  This
  -- is the main step-assignment loop's equivalent of the chain pass's
  -- occupied tracking: on a doubled-back path the lag-indexed goals can
  -- alias to one physical cell, and two followers stepping into it overlap
  -- and then shoot ahead (the True Size "slingshot").  During seam
  -- settlement the trainer's cell is reserved as well, since a translated
  -- train can momentarily sit geometrically out of order while its members
  -- catch up at different speeds.
  local seamReservations = {}
  if ow._wildsFollowerSeamActive then
    if p.moving and p.targetX ~= nil and p.targetY ~= nil then
      -- The convoy may enter the trainer's origin on the same cadence while
      -- the trainer vacates it; reserve only the trainer's destination.
      seamReservations[tostring(p.targetX) .. "," .. tostring(p.targetY)] = p
    elseif p.cellX ~= nil and p.cellY ~= nil then
      seamReservations[tostring(p.cellX) .. "," .. tostring(p.cellY)] = p
    end
  end
  for _, trailer in ipairs(trailers) do
    if not trailer.moving and trailer.cellX ~= nil and trailer.cellY ~= nil then
      seamReservations[tostring(trailer.cellX) .. "," .. tostring(trailer.cellY)] = trailer
    end
    if trailer.moving and trailer.targetX ~= nil and trailer.targetY ~= nil then
      seamReservations[tostring(trailer.targetX) .. "," .. tostring(trailer.targetY)] = trailer
    end
  end
  local function seamCellFree(x, y, npc)
    if not seamReservations then return true end
    local owner = seamReservations[tostring(x) .. "," .. tostring(y)]
    if owner == nil or owner == npc then return true end
    -- Mutual cell exchange (reversal re-spacing): the stationary occupant
    -- wants the stepper's own cell — let them shuffle past each other.
    return trailerSwapIntended(npc, owner, trailers, goals, ow)
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
  local anyStepStarted = false
  local anyOffGoal = false
  local anyOnHead = false
  local inverted = false
  local prevDist = math.huge
  for i, npc in ipairs(trailers) do
    if npc.moving then
      -- Trailer update owns px/py mid-step; do not overwrite.
      anyStepStarted = true
    else
      -- Scramble probe (stationary pack only): a packed train's slot order
      -- is monotonic in head-distance (1,2,3...).  A later follower CLOSER
      -- to the head than an earlier one means the pack swapped order (the
      -- reversal fold) and is deadlocked — that arms the fast re-seed.
      -- The entry drain is excluded separately via anyOnHead.
      local d = math.abs((npc.cellX or 0) - head.x) + math.abs((npc.cellY or 0) - head.y)
      if d < prevDist and prevDist ~= math.huge then inverted = true end
      prevDist = d
      if d == 0 then anyOnHead = true end
      local cell = goals[i] or { x = anchor.cellX, y = anchor.cellY }
      local gx, gy = cell.x, cell.y
      local role = npc.wildsFollowerRole or "party_trailer"
      if not self:isFollowerCellAllowed(game, ow, npc, gx, gy, {
        surface = surface, role = role,
      }) then
        -- Goal invalid for this surface: park on the anchor's cell instead of
        -- re-picking behind its facing (a door-facing points into the
        -- building; the behind cells may be an enclosed pocket the pack can
        -- never path out of).  It walks out as the trail re-opens.
        gx, gy = anchor.cellX or 0, anchor.cellY or 0
        goals[i] = { x = gx, y = gy }
      end
      if npc.cellX ~= gx or npc.cellY ~= gy then
        anyOffGoal = true
        local originX, originY = npc.cellX, npc.cellY
        local ok = self:_assignTrailerStep(
          game, ow, npc, gx, gy, surface, role, stepClock, facing, seamCellFree, i)
        if ok then
          anyStepStarted = true
          releaseSeamCell(originX, originY, npc)
          reserveSeamCell(npc.targetX, npc.targetY, npc)
          -- Keep the trail cell aligned with the trailer's actual aim
          -- (including ledge-hop extension) for the catch-up chain pass.
          goals[i] = { x = npc._wildsGoalX, y = npc._wildsGoalY }
        end
      else
        npc._wildsGoalX, npc._wildsGoalY = nil, nil
      end
    end
  end

  -- Jam recovery: when the pack should be walking but NO trailer could start
  -- a step while some trailer is off its goal, the trail goals have scrambled
  -- (a reversal walked the pack back over its own trail — the fold) and
  -- single-file stepping can never re-order the pack: the follower that
  -- reached its goal first parks on the path and the rest deadlock behind
  -- it.  Re-seed the pack along the player's actual walked trail instead:
  -- the trail cells are ordered by construction (one cell per follower), so
  -- a re-seed restores slot order and the pack follows cleanly.
  --
  -- Latency: a SCRAMBLED pack (slot order inverted) is re-seeded almost
  -- immediately — the counter jumps by TRAIL_JAM_FAST_STEP per stalled
  -- frame, so the freeze is imperceptible (~2 frames).  Non-inverted stalls
  -- (e.g. a pack blocked against walls) wait TRAIL_JAM_THRESHOLD frames.
  -- The entry drain is excluded by anyOnHead (parked followers sit on the
  -- head cell and drain naturally when the player walks — never a jam) and
  -- the entry cooldown; TRAIL_JAM_COOLDOWN frames of quiet must pass before
  -- a re-seed can fire again, so a re-form can't oscillate into repeated
  -- pops.
  if ow._wildsJamCooldown and ow._wildsJamCooldown > 0 then
    ow._wildsJamCooldown = ow._wildsJamCooldown - 1
  end
  if not anyStepStarted and anyOffGoal and not anyOnHead
     and (ow._wildsEntryCooldown == nil or ow._wildsEntryCooldown <= 0)
     and (ow._wildsJamCooldown == nil or ow._wildsJamCooldown <= 0) then
    ow._wildsJamFrames = (ow._wildsJamFrames or 0)
      + (inverted and TRAIL_JAM_FAST_STEP or 1)
    if ow._wildsJamFrames >= TRAIL_JAM_THRESHOLD then
      ow._wildsJamFrames = 0
      ow._wildsJamCooldown = TRAIL_JAM_COOLDOWN
      local seedGoals = self:_seedTrailBehind(ow, anchor, facing, #trailers, game, surface)
      local reformed = 0
      for i, npc in ipairs(trailers) do
        local c = seedGoals and seedGoals[i]
        if c and self:isFollowerCellAllowed(game, ow, npc, c.x, c.y, {
          surface = surface, role = npc.wildsFollowerRole or "party_trailer",
        }) then
          placeTrailerAt(npc, c.x, c.y, npc.facing or facing)
          npc.targetX, npc.targetY = nil, nil
          npc.moving = false
          npc.progress = 0
          goals[i] = { x = c.x, y = c.y }
          reformed = reformed + 1
        end
      end
      if reformed > 0 then
        ow.pokepcTrailCells = goals
        self.diag.lastSeed = "jam_reform"
        self.diag.jamReforms = (self.diag.jamReforms or 0) + 1
      end
    end
  else
    ow._wildsJamFrames = 0
  end
  if dirty or mapEnter or opts.spawnAtPlayer or countChanged then
    logGen2(self.mod, "activeTrailers=%s", tostring(#(ow.pokepcTrailers or {})))
  end
  return true
end

--- Assign one step for a trailer toward (gx, gy). Corner-navigates, handles
-- ledges, and picks the cadence: normal at 1-cell spacing, double-speed for
-- catch-up. Stores the goal on the trailer so the catch-up pass can chain
-- consecutive steps without waiting for the next goal shift. Returns true
-- when a step started; false when blocked (no adjacent follower cell).
function ControlEngine:_assignTrailerStep(game, ow, npc, gx, gy, surface, role,
                                           stepClock, facing, cellFree, slot)
  local Collision = tryRequire("src.world.Collision")
  -- A follower must never walk onto the cell the trail head currently
  -- occupies (the player's cell).  Path doubling (a reversal over walked
  -- ground) can leave a stale goal or step aim on that cell; stepping in
  -- reads as the True Size "slingshot".  The follower holds position until
  -- the goal shifts away.  Parked pack members already on the head cell
  -- are exempt — they step OFF it normally during the entry drain.
  local head = ow and ow.pokepcTrailHead
  local hx, hy = head and head.x, head and head.y
  local onHead = (npc.cellX or 0) == hx and (npc.cellY or 0) == hy
  if hx ~= nil and hy ~= nil and gx == hx and gy == hy and not onHead then
    return false
  end
  local far = math.abs((npc.cellX or 0) - gx) + math.abs((npc.cellY or 0) - gy)
  local step = self:_pickTrailerStep(game, ow, npc, gx, gy, surface, role,
                                     cellFree)
  -- The picked step can still land on the head cell even when the goal is
  -- behind it (the goal lies on the far side of the player, e.g. after a
  -- second reversal).  The follower holds position instead of walking
  -- through the player; it resumes once the head moves away.
  if step and hx ~= nil and hy ~= nil and not onHead
     and step.x == hx and step.y == hy then
    return false
  end
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
    if (not cellFree or cellFree(hx, hy, npc))
       and self:isFollowerCellAllowed(game, ow, npc, hx, hy, {
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
  --
  -- Double cadence is reserved for GENUINE stragglers — a trailer more than
  -- one cell behind its convoy slot (head-distance > slot + 1).  On a
  -- reversal the tightly packed train's trail-history goals can jump 2+ cells
  -- (doubled-back lag indexing) while every member is still right behind the
  -- head; treating that as "falling behind" makes the whole pack DASH through
  -- the fold at double speed — the visible True Size "slingshot".  Folds
  -- resolve by walking at normal cadence (the swap allowance lets the
  -- crossing members shuffle past), which reads as a smooth turnaround.
  local headDist = (hx ~= nil and hy ~= nil)
    and (math.abs((npc.cellX or 0) - hx) + math.abs((npc.cellY or 0) - hy)) or 0
  local lagging = headDist > (slot or 1) + 1
  if not npc.hopStep and far > 1 and lagging then
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
  -- Track cells occupied by other trailers (including mid-step targets)
  -- so followers can't step on top of each other — the root cause of
  -- the "slingshot" effect where overlapping followers shoot ahead.
  local occupied = {}
  for _, npc in ipairs(trailers) do
    if npc then
      occupied[(npc.cellX or 0) .. "," .. (npc.cellY or 0)] = true
      if npc.moving and npc.targetX ~= nil and npc.targetY ~= nil then
        occupied[npc.targetX .. "," .. npc.targetY] = true
      end
    end
  end
  local function cellFree(x, y, selfNpc)
    -- A cell is free if no OTHER trailer occupies it (current cell or
    -- mid-step target).  A trailer's own current cell is always free
    -- (it's stepping away from it).  A moving trailer's current cell is
    -- also free for others — the occupant is vacating it.
    local key = x .. "," .. y
    local owner = occupied[key]
    if not owner then return true end
    -- selfNpc is the npc passed by _pickTrailerStep; if a table is stored
    -- as value we can compare identity.  Our occupied set uses `true` as
    -- values, so we check by key only and allow self-vacancy: if the
    -- occupying trailer is moving, its current cell will be vacated.
    for _, npc in ipairs(trailers) do
      local cx, cy = npc.cellX or 0, npc.cellY or 0
      if cx == x and cy == y then
        if npc == selfNpc then return true end  -- self
        if npc.moving then return true end     -- vacating
        -- Mutual cell exchange (reversal re-spacing): the stationary
        -- occupant wants this stepper's own cell — let them shuffle past.
        return trailerSwapIntended(selfNpc, npc, trailers, goals, ow)
      end
      if npc.moving and npc.targetX == x and npc.targetY == y then
        if npc == selfNpc then return true end  -- self
        return false  -- another trailer heading here
      end
    end
    return false
  end
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
            npc.wildsFollowerRole or "party_trailer", stepClock, facing, cellFree, i)
          if ok then
            -- Mark the step target as occupied so later trailers don't
            -- step into it.
            if npc.targetX ~= nil and npc.targetY ~= nil then
              occupied[npc.targetX .. "," .. npc.targetY] = true
            end
            -- Chain at catch-up cadence for normal steps; ledge hops keep
            -- full-length frames so the arc animation plays out properly.
            -- Same straggler gate as the main assignment: mid-reversal-fold
            -- trailers re-step immediately (no freeze) but at NORMAL cadence
            -- so the pack turns smoothly instead of dashing through the fold.
            if not npc.hopStep then
              local head = ow and ow.pokepcTrailHead
              local chx, chy = head and head.x, head and head.y
              local headDist = (chx ~= nil and chy ~= nil)
                and (math.abs((npc.cellX or 0) - chx)
                     + math.abs((npc.cellY or 0) - chy)) or 0
              if headDist > i + 1 then
                npc.stepFrames = math.max(1, math.floor(stepClock / 2))
              else
                npc.stepFrames = stepClock
              end
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
  ow = self:_liveOw(game, ow)
  if self:_battleReturnActive() then
    local fresh = self:_freshOw(game)
    if fresh and fresh ~= ow then
      self:_traceBattleReturn("update.owReplaced", game, fresh)
      ow = fresh
    end
    self:_traceBattleReturn("update", game, ow)
  end

  -- Out-of-battle HP loss (poison, etc.) does not fire battle.ended.
  -- Reconcile on the existing trailer update cadence so a fainted selected
  -- follower permanently fails over before trailer sync / party menu reads.
  local selState = self.selection and self.selection.state
  local beforeKey = selState and selState.selectedMonKey
  local beforeSlot = selState and selState.selectedSlot
  if self.selection and game and type(self.selection.reconcile) == "function" then
    pcall(function() self.selection:reconcile(game) end)
  end
  local afterKey = selState and selState.selectedMonKey
  local afterSlot = selState and selState.selectedSlot
  local selectionChanged = beforeKey ~= afterKey or beforeSlot ~= afterSlot

  -- Always run when a pending sync is queued (stepper menu changed the count
  -- while the world was paused), or selection just failed over. Otherwise
  -- skip if trailers aren't needed.
  if not self._pendingMapTrailerSync
     and not self:shouldUpdateWildsTrailers(game, ow)
     and not opts.force
     and not selectionChanged then
    return false, "skip"
  end

  local perf = nil
  local perfStart = nil
  do
    local bt = self.mod and self.mod.exports and self.mod.exports.behaviorTick
    perf = bt and bt.perf
    if perf and perf.enabled then
      perfStart = (love and love.timer and love.timer.getTime and love.timer.getTime())
        or os.clock()
    end
  end

  self._inControlUpdate = true
  self._lastOw = ow  -- cached for menu-context access (stepper, etc.)
  self.diag.controlUpdateCalls = (self.diag.controlUpdateCalls or 0) + 1
  self.diag.lastSource = opts.source or "direct"

  -- Gold OPTIONS can wipe WILDS AI to OFF. Re-assert on the per-logic-frame
  -- World:step owner so wilds recover without waiting for a map reload.
  do
    local GameCompat = V.require("game_compat")
    if GameCompat.isGen2(self.mod, game) then
      local bt = self.mod and self.mod.exports and self.mod.exports.behaviorTick
      if bt and bt.ensurePipeline then
        pcall(bt.ensurePipeline, bt)
      end
    end
  end

  local ok, err = pcall(function()
    self:_applyConnectionHandoff(ow)
    if self:isPokemonFront(game) or self:followerCount(game) <= 0 then
      self:_removeStockPikachu(ow)
    end
    self:forceYellowStockPikachuArt(ow, game)
    self:syncPlayerControlVisual(game, ow)
    if self._pendingMapTrailerSync or opts.mapEnter then
      -- A fresh (non-connection) map entry parks the pack on the player's
      -- cell so it walks out from under him instead of materializing behind
      -- his facing (stuck behind buildings / walls on door exits).
      local spawnAtPlayer = self._pendingSpawnAtPlayer == true
      if spawnAtPlayer then
        -- Park the stock Yellow Pikachu explicitly (engine version
        -- independent) before the trailers anchor to it.  Mark the entry
        -- parking so the Yellow collapse heuristic doesn't re-seed the pack
        -- behind the stock on the very next frame.
        pcall(function() self:_parkStockPikachuAtPlayer(ow) end)
        ow._wildsEntryParked = true
      end
      local _, syncRes = self:syncTrailers(game, ow,
                                           { mapEnter = true, spawnAtPlayer = spawnAtPlayer })
      if syncRes == "no_context" then
        -- World not live yet (transitional frame): keep the pending entry
        -- so the next update still parks the pack at the player instead of
        -- seeding it behind his facing.
        self._pendingMapTrailerSync = true
        self._pendingSpawnAtPlayer = spawnAtPlayer
      elseif self:_battleReturnActive()
          and not self:_allTrailersIdentityAttached(ow) then
        -- Battle-return: a late people rebuild may still wipe guests.
        -- Keep the pending seed until identity is verified.
        self._pendingMapTrailerSync = true
        self._pendingSpawnAtPlayer = spawnAtPlayer
      else
        self._pendingMapTrailerSync = false
        self._pendingSpawnAtPlayer = false
      end
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
    -- After parking the pack on the player during a map entry, suppress
    -- catch-up steps for a brief cooldown so the trail expands naturally
    -- one follower per step.  Without this, followers stepping from a
    -- shared cell can overlap and slingshot ahead.
    if ow._wildsEntryCooldown and ow._wildsEntryCooldown > 0 then
      ow._wildsEntryCooldown = ow._wildsEntryCooldown - 1
    else
      self:_chainCatchUpSteps(game, ow)
    end
    self:_finishConnectionHandoffIfComplete(ow)
    self:_traceSurf(game, ow)
  end)

  self._inControlUpdate = false
  if perfStart and perf and perf.addMs then
    perf:addMs("msFollowers", perfStart)
  end
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
-- The poke_followers submerged art is the **GSC / Poke Followers** water
-- presentation (Classic 16×16, half-submerged behind a waterline).  It is
-- only derived when that sprite style is active; HGSS / PokeMMO (True
-- Size) and Pokédex trailers fall straight through to the standard
-- resolveFollowerSprite chain, which serves the style's own water art
-- (true_size swimming/levitate sheets / water registry) — never the GSC
-- classic sheets, so True Size surf never drops back to GSC.
--
-- GSC water path: derives the submerged poke_followers art at load from the
-- coloured LAND sheet (follower_NNN_{variant}.png) via
-- LuminanceSheet.submergedFor — waterline mask + foam/blue water line,
-- cached in the save dir, no separate _submerged.png files.  Falls back to
-- the standard resolveFollowerSprite chain when no submerged sheet exists.
function ControlEngine:_refreshTrailerWaterSprites(game, ow, surface)
  if not (ow and ow.pokepcTrailers) then return end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new) then return end

  local AnimatedSprites = nil
  pcall(function() AnimatedSprites = V.require("animated_sprites") end)

  -- Only the GSC / Poke Followers style uses the derived submerged art.
  local gscSubmerged = false
  if surface == "water" then
    local style = "followers"
    local okCfg, Config = pcall(function() return V.require("config") end)
    if okCfg and Config and type(Config.spriteStyle) == "function" then
      style = Config.spriteStyle(self.mod)
      if type(Config.normalizeSpriteStyle) == "function" then
        style = Config.normalizeSpriteStyle(style)
      end
    end
    gscSubmerged = style == "followers"
  end

  for _, npc in ipairs(ow.pokepcTrailers) do
    if npc and npc.pokepcTrailerKind == "mon" and npc.pokepcMon then
      local mon = npc.pokepcMon
      local species = mon.species or npc._wildsFollowerSpecies
      local shiny = isShinyMon(mon) or (npc.pokepcShiny == true)
      local resolved = nil

      if surface == "water" and gscSubmerged then
        -- Derive the submerged poke_followers art at load from the coloured
        -- LAND sheet (follower_NNN_{variant}.png) via LuminanceSheet.submergedFor
        -- — waterline mask + foam/blue water line, cached in the save dir, no
        -- separate _submerged.png files.  Pick the sheet by COLORS mode.
        local SpeciesAssets = V.require("species_assets")
        local dex = SpeciesAssets.idFor(species)
        if dex then
          local Config = nil
          pcall(function() Config = V.require("config") end)
          local LuminanceSheet = nil
          pcall(function() LuminanceSheet = V.require("luminance_sheet") end)
          -- Luminance-based shading: Gen1 non-ADVANCED derives a 3-shade
          -- luminance sheet (trueColor=false). Gold keeps colored submerged
          -- art with trueColor=true.
          local useLuma = Config and Config.waterArtUsesLuminance
            and Config.waterArtUsesLuminance(self.mod)
          if useLuma == nil then
            useLuma = not (Config and Config.paletteFxRedpp and Config.paletteFxRedpp())
          end
          local tryVariants = {}
          if useLuma then
            tryVariants = { "normal" }
          elseif shiny then
            tryVariants = { "shiny", "normal" }
          else
            tryVariants = { "normal" }
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
            if WildsFs.assetExists(self.mod, rel) then
              local subPath = LuminanceSheet and LuminanceSheet.submergedFor(loadPath)
              if subPath then
                local luma = useLuma and LuminanceSheet
                  and LuminanceSheet.pathFor(subPath) or nil
                local image = luma or subPath
                resolved = {
                  image = image,
                  frames = 6,
                  walker = true,
                  -- trueColor travels with the art: luminance sheets are false
                  -- so the zone pass colors them; colored (ADVANCED / headless
                  -- fallback) is true so it draws raw.
                  trueColor = luma == nil,
                  id = "SPRITE_WILDS_FOLLOWER_SUBMERGED_" .. tostring(dex),
                }
                break
              end
            end
          end
        end
      end

      if not resolved then
        -- No submerged sheet (land surface, non-GSC style, or species outside
        -- the set).  Fall back to the standard sprite resolution chain.
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
        local ok, sprite = pcall(SpriteRenderer.new, spriteDefWithGeometry(resolved, {
          pokepcShiny = shiny and true or false,
        }), npc.id)
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

--- Resolve sprite art for every mon trailer from its current pokepcMon.
-- Call after species-swap, count-changed inline updates, or a land↔water
-- surface transition. Rebinds SpriteRenderer only — movement / trail slot /
-- pokepcMon stay on the same NPC. Swimming geometry (frameWidth/Height,
-- anchorX/Y) travels through spriteDefWithGeometry.
-- Returns the number of mon trailers whose sprite was rebound.
function ControlEngine:_refreshTrailerMonSprites(game, ow, surface)
  if not (ow and ow.pokepcTrailers) then return 0 end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new) then return 0 end
  surface = surface or self:_trailSurface(ow, game) or "land"
  local water = (surface == "water" or surface == "surfing")
  local rebound = 0

  for _, npc in ipairs(ow.pokepcTrailers) do
    if npc and npc.pokepcTrailerKind == "mon" and npc.pokepcMon then
      local mon = npc.pokepcMon
      local species = mon.species or npc._wildsFollowerSpecies
      if species then
        local shiny = isShinyMon(mon) or (npc.pokepcShiny == true)
        local resolved = self:resolveFollowerSprite({
          species = species,
          shiny = shiny,
          form = mon.form,
          surface = surface,
          role = "party_trailer",
          game = game,
        })
        if resolved and resolved.image then
          local ok, sprite = pcall(SpriteRenderer.new, spriteDefWithGeometry(resolved, {
            pokepcShiny = shiny and true or false,
          }), npc.id)
          if ok and sprite then
            npc.sprite = sprite
            npc._wildsFollowerSpecies = species
            rebound = rebound + 1
          end
        end
      end
      npc.wildsFollowerWater = water
      npc.spriteState = water and "water" or "land"
    end
  end
  return rebound
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

function ControlEngine:onBattleEnded(game, ow, ev)
  game = game or self:_game()
  local source = ev and ev.source or "battle.ended"
  -- Always re-resolve the live overworld. A passed-in ow can be the
  -- pre-rebuild instance the engine is about to replace.
  local prevOw = self._battleReturnOw
  ow = self:_freshOw(game) or ow
  if prevOw and ow and prevOw ~= ow then
    self:_adoptRememberedTrailers(ow)
    self:_traceBattleReturn("owReplaced", game, ow, { force = true })
    local logic = self.mod and self.mod.exports and self.mod.exports.logic
    if logic and logic.markOccupancyDirty then
      logic:markOccupancyDirty()
    end
  end
  self._battleReturnOw = ow
  self:_rememberBattleTrailers(ow)

  if source == "battle.ended" then
    -- Mirror map.entered: mark pending and wait for a STABLE overworld.
    -- Immediate update() races the engine's post-battle people rebuild.
    self._battleReturnPhase = "pending"
    self._battleReturnChecks = 0
    self._pendingBattleReturnSync = true
    self._pendingMapTrailerSync = true
    self._pendingSpawnAtPlayer = true
    self._battleReturnFlushedOnce = false
    self:_traceBattleReturn("onBattleEnded", game, ow)
    if ow and ow.battleActive then
      return false, "battle_active"
    end
    return true, "pending"
  end

  self._pendingBattleReturnSync = true
  self._pendingMapTrailerSync = true
  self._pendingSpawnAtPlayer = true
  if ow and ow.battleActive then
    self:_traceBattleReturn(source, game, ow)
    return false, "battle_active"
  end
  if not (ow and ow.map and ow.player) then
    self:_traceBattleReturn(source, game, ow)
    return false, "no_overworld"
  end

  local logic = self.mod and self.mod.exports and self.mod.exports.logic
  if logic and logic.activeMapId and ow.map.id
     and logic.activeMapId ~= ow.map.id then
    self:_traceBattleReturn("map_mismatch", game, ow)
    self:_clearBattleReturn()
    return false, "map_mismatch"
  end

  -- Reattach existing trailer objects to the CURRENT lists first.
  -- Do not recreate sprites when the same NPCs are still in pokepcTrailers.
  local ensured = self:_ensureTrailersAttached(game, ow)
  local want = self:followerCount(game) or 0
  if (not ow.pokepcTrailers or #ow.pokepcTrailers == 0) and want > 0 then
    local ok, err = pcall(function()
      self:update(game, ow, {
        mapEnter = true,
        force = true,
        source = "battle_return",
      })
    end)
    if not ok then
      logWarn(self.mod, "battle-return follower sync failed: %s", tostring(err))
    end
    ensured = self:_allTrailersIdentityAttached(ow)
  end

  self._battleReturnChecks = (self._battleReturnChecks or 0) + 1
  local identityOk = self:_allTrailersIdentityAttached(ow)
    or (want <= 0)
  if ensured or identityOk then
    local logic = self.mod and self.mod.exports and self.mod.exports.logic
    if logic and logic.markOccupancyDirty then
      logic:markOccupancyDirty()
    end
  end
  self:_traceBattleReturn(source, game, ow, {
    ensured = ensured, identityOk = identityOk,
  })

  -- Bounded: pending → first_live (tick) → verify (world.stepped) → complete.
  -- Ticks must not complete: a late people rebuild can still happen after
  -- the first successful attach.
  if identityOk then
    if source == "world.stepped" then
      if self._battleReturnPhase == "verify" then
        self:_clearBattleReturn()
      else
        self._battleReturnPhase = "verify"
      end
    elseif self._battleReturnPhase == "pending" then
      self._battleReturnPhase = "first_live"
    end
  elseif self._battleReturnChecks >= 3 then
    self:_clearBattleReturn()
  else
    self._battleReturnPhase = self._battleReturnPhase or "pending"
  end

  local attached = (ow.pokepcTrailers and #ow.pokepcTrailers) or 0
  logGen2(self.mod,
    "battleReturn source=%s phase=%s followersDesired=%s followersAttached=%s identity=%s",
    tostring(source), tostring(self._battleReturnPhase),
    tostring(want), tostring(attached), tostring(identityOk))
  return true, {
    desired = want,
    attached = attached,
    identity = identityOk,
    phase = self._battleReturnPhase,
  }
end

function ControlEngine:syncAll(game, ow)
  game = game or self:_game()
  ow = self:_liveOw(game, ow)
  if ow then pcall(function() self:removeTrailers(ow) end) end
  -- Never reorder the party here. Wilds designates the follower via save data
  -- (pokepcLeader / followerPartyIndex), not party order, so the Yellow
  -- Pikachu-slot-1 layout (ensureYellowLeaderLayout) is unnecessary and
  -- caused visible party reordering when selecting a follower.
  if (self:isPokemonFront(game) or self:followerCount(game) <= 0) and ow and ow.player then
    ow.player._pokepcControlSpecies = nil
  end
  local okVis, errVis = pcall(function() self:syncPlayerControlVisual(game, ow, true) end)
  if not okVis then
    logWarn(self.mod, "syncPlayerControlVisual failed: %s", tostring(errVis))
    logGen2(self.mod, "syncPlayerControlVisual failed: %s", tostring(errVis))
  end
  pcall(function() self:forceYellowStockPikachuArt(ow, game) end)
  local okSync, errSync = pcall(function()
    self:syncTrailers(game, ow, { mapEnter = true, catchUp = true })
  end)
  if not okSync then
    logWarn(self.mod, "syncAll/syncTrailers failed: %s", tostring(errSync))
    logGen2(self.mod, "syncAll failed: %s", tostring(errSync))
  end
end

function ControlEngine:_installTalkWrap()
  local OverworldState = tryRequire("src.world.OverworldController")
  if not OverworldState then return false end
  if not self._interaction then
    local Interaction = V.require("follower/interaction")
    self._interaction = Interaction.new(self.mod, self.selection)
  end
  local engine = self
  local function handleFollowerTalk(owSelf, npc)
    if not (npc and npc.wildsFollower == true and npc.pokepcTrailer == true
            and npc.pokepcTrailerKind ~= "trainer" and npc.pokepcMon) then
      return false
    end
    local mon = npc.pokepcMon
    -- Yellow Pikachu keeps vanilla talk (Pikachu-specific options).
    if engine:_isYellow() and mon.species == "PIKACHU" then
      local PF = tryRequire("src.world.PikachuFollower")
      if PF and PF.talk then
        PF.talk(engine:_game(), owSelf, npc)
      end
      return true
    end
    if engine._interaction and engine._interaction.showFollowMessage then
      engine._interaction:showFollowMessage(engine:_game(), owSelf, npc, mon)
    end
    return true
  end

  -- Gen1 OverworldController.interact uses facingCell / npcAtCell.
  -- Gold interactWrapper falls through to interactBody when facingCell is
  -- absent (Gold player has cellX/cellY/facing, not facingCell).
  if type(OverworldState.interact) == "function"
     and OverworldState._wildsControlEngineTalkWrap ~= OverworldState.interact then
    local origInteract = OverworldState.interact
    local function talkWrap(owSelf, ...)
      local p = owSelf and owSelf.player
      if p and type(p.facingCell) == "function"
          and type(owSelf.npcAtCell) == "function" then
        local Collision = tryRequire("src.world.Collision")
        local fx, fy = p:facingCell()
        local npc = owSelf:npcAtCell(fx, fy)
        if not npc and owSelf.map and owSelf.map.isCounterCell
           and owSelf.map:isCounterCell(fx, fy) and Collision and Collision.target then
          local fx2, fy2 = Collision.target(fx, fy, p.facing)
          npc = owSelf:npcAtCell(fx2, fy2)
        end
        if handleFollowerTalk(owSelf, npc) then return true end
      end
      return origInteract(owSelf, ...)
    end
    OverworldState.interact = talkWrap
    OverworldState._wildsControlEngineTalkWrap = talkWrap
    self._talkOrigInteract = origInteract
    self._talkWrapped = true
  end

  -- Gold World:interactBody already resolved the facing NPC, then calls
  -- talkTo(world, npc). A true return suppresses trainer/script dispatch.
  if type(OverworldState.talkTo) == "function"
     and OverworldState._wildsControlEngineTalkToWrap ~= OverworldState.talkTo then
    local origTalkTo = OverworldState.talkTo
    local function talkToWrap(owSelf, npc, ...)
      if handleFollowerTalk(owSelf, npc) then return true end
      return origTalkTo(owSelf, npc, ...)
    end
    OverworldState.talkTo = talkToWrap
    OverworldState._wildsControlEngineTalkToWrap = talkToWrap
    self._talkOrigTalkTo = origTalkTo
    self._talkToWrapped = true
  end
  return self._talkWrapped == true or self._talkToWrapped == true
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
  if self._talkToWrapped and OverworldState._wildsControlEngineTalkToWrap
     and OverworldState.talkTo == OverworldState._wildsControlEngineTalkToWrap
     and self._talkOrigTalkTo then
    OverworldState.talkTo = self._talkOrigTalkTo
    OverworldState._wildsControlEngineTalkToWrap = nil
  end
  self._talkWrapped = false
  self._talkToWrapped = false
  self._talkOrigInteract = nil
  self._talkOrigTalkTo = nil
end

--- Wrap OverworldController.update so trailer ticks are independent of
-- PikachuFollower.shouldSpawn / stock follower presence.
function ControlEngine:_installOverworldUpdateWrap()
  -- Gold World:step is the Gen2 driver (owner = gen2_world_event).
  -- OverworldController.update on Gold is a Gen2 facade whose defaultUpdate
  -- is a no-op unless worldTick sees a replacement on THAT table. Wrapping
  -- the real Gen1 OverworldController is a silent no-op on Gold.
  local GameCompat = V.require("game_compat")
  if GameCompat.isGen2(self.mod, self:_game()) then
    return false
  end
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
    --
    -- Cutscene gate: during dialogs / healing animations the vanilla
    -- PikachuFollower.shouldSpawn returns false.  When it does and the
    -- player isn't surfing (surfing also trips vanilla shouldSpawn but
    -- trailers still need to follow on water), purge trailers and skip
    -- the engine update so they stay hidden for the cutscene duration.
    --
    -- During map transitions (pending handoff or sync is queued) the
    -- player state may be indeterminate — never treat as cutscene.
    local game = engine:_game()
    local vanillaSpawn = engine._vanillaShouldSpawn
    local transitioning = engine._pendingConnectionHandoff ~= nil
      or engine._pendingMapTrailerSync == true
    -- The cutscene gate is Yellow stock-Pikachu only. Vanilla shouldSpawn
    -- is also false when Pikachu is simply not in the party — treating every
    -- Yellow frame as a cutscene froze Wilds trailers at spawn. Red/Blue
    -- never use this gate (they hide trailers via map.exited).
    local yellow = engine:_isYellow()
    local stockPikachuActive =
      yellow and engine:yellowStockFollowActive(game)
    local inCutscene =
      stockPikachuActive
      and not transitioning
      and vanillaSpawn
      and not vanillaSpawn(game, owSelf)
      and not (owSelf.player and owSelf.player.surfing)
    if inCutscene then
      -- Skip the engine update so trailers aren't re-added to entities
      -- during the cutscene.  The engine's own rendering system hides
      -- NPCs during dialogs / healing — our job is to not fight it.
    else
      pcall(function()
        engine:update(game, owSelf, {
          dt = dt,
          source = "overworld",
        })
      end)
    end
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

--- Gold driver: wrap src.world.gen2.World.step (one tick per logic frame).
-- world.stepped is public and generation-neutral but fires only when a tile
-- step lands — not every World:step — so it cannot own trailer interpolation.
-- Do not wrap World.update. Gen1 OverworldController.update is untouched.
function ControlEngine:_installGen2WorldStepWrap()
  local GameCompat = V.require("game_compat")
  if not GameCompat.isGen2(self.mod, self:_game()) then
    return false
  end
  local World = tryRequire("src.world.gen2.World")
  if not (World and type(World.step) == "function") then
    return false
  end
  if World._wildsControlEngineStepWrap == World.step then
    self._gen2WorldStepWrapped = true
    return true
  end
  local engine = self
  local origStep = World.step
  local function gen2StepWrap(worldSelf, ...)
    local a, b, c, d, e = origStep(worldSelf, ...)
    if engine._trailerUpdateOwner == "gen2_world_event" then
      engine.diag.gen2WorldStepCalls = (engine.diag.gen2WorldStepCalls or 0) + 1
      local game = (worldSelf and worldSelf.game) or engine:_game()
      local ok, err = pcall(function()
        engine:update(game, worldSelf, { source = "gen2_world_event" })
      end)
      if not ok then
        logWarn(engine.mod, "[Wilds][Follower][Gen2] update failed: %s", tostring(err))
        logGen2(engine.mod, "update failed: %s", tostring(err))
      else
        logGen2Once(engine, "world_step_owner",
          "updateOwner=%s controlUpdateCalls=%s syncTrailersCalls=%s",
          tostring(engine._trailerUpdateOwner),
          tostring(engine.diag.controlUpdateCalls),
          tostring(engine.diag.syncTrailersCalls))
        local trailers = worldSelf and worldSelf.pokepcTrailers or {}
        local t = trailers[1]
        if t then
          local inNpcs, inEntities = false, false
          for _, n in ipairs((worldSelf and worldSelf.npcs) or {}) do
            if n == t then inNpcs = true break end
          end
          for _, e in ipairs((worldSelf and worldSelf.entities) or {}) do
            if e == t then inEntities = true break end
          end
          logGen2Once(engine, "world_step_alive",
            "stillAlive=true inNpcs=%s inEntities=%s activeTrailers=%s",
            tostring(inNpcs), tostring(inEntities), tostring(#trailers))
        end
      end
    end
    return a, b, c, d, e
  end
  World.step = gen2StepWrap
  World._wildsControlEngineStepWrap = gen2StepWrap
  self._gen2OrigStep = origStep
  self._gen2WorldStepWrapped = true
  logGen2(self.mod, "World.step wrapped as update-owner=gen2_world_event")
  return true
end

--- Retry Gold World:step wrap after late World.lua load (map.entered / game.ready).
function ControlEngine:_ensureGen2WorldStepWrap(game)
  local GameCompat = V.require("game_compat")
  if not GameCompat.isGen2(self.mod, game or self:_game()) then
    return false
  end
  local was = self._gen2WorldStepWrapped == true
  local ok = self:_installGen2WorldStepWrap()
  if ok then
    self._trailerUpdateOwner = "gen2_world_event"
    if not was then
      logGen2(self.mod, "update-owner=gen2_world_event")
    end
    return true
  end
  if not was then
    logGen2(self.mod, "World.step wrap not installed yet (World may still be loading)")
  end
  return false
end

function ControlEngine:_restoreGen2WorldStepWrap()
  local World = tryRequire("src.world.gen2.World")
  if World and self._gen2OrigStep then
    World.step = self._gen2OrigStep
    World._wildsControlEngineStepWrap = nil
  end
  self._gen2WorldStepWrapped = false
  self._gen2OrigStep = nil
end

--- Install mod event subscriptions (map.entered, game.ready, etc.).
-- Called from install() before the PF check, so Red/Blue also gets events.
function ControlEngine:_installEventSubscriptions()
  local engine = self
  local mod = self.mod
  if not (mod and mod.events and mod.events.on) then return end

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
      local ow = engine:_liveOw(game)
      engine:_captureMapExit(game, ow, payload)
      -- Remove trailers from the overworld so they disappear during
      -- transitions (healing, warps, doors).  Connection handoffs
      -- reattach them in _applyConnectionHandoff; other entries
      -- re-create them fresh via spawnAtPlayer.
      pcall(function() engine:removeTrailers(ow) end)
    end)
  subscribe("map.entered", function(payload)
      local game = engine:_game()
      local ow = engine:_liveOw(game)
      -- World.lua is often first required on overworld entry, after mod load
      -- and sometimes after game.ready. Retry the Gold World:step wrap here.
      pcall(function() engine:_ensureGen2WorldStepWrap(game) end)
      pcall(function() engine:syncPlayerControlVisual(game, ow) end)
      engine:_queueMapEntry(game, ow, payload)
      engine._pendingMapTrailerSync = true
      -- Seamless outdoor walking seams keep the existing train
      -- (translated by _applyConnectionHandoff); any other entry (warp /
      -- door / boot / healing) parks the pack on the player's cell.
      if not engine._pendingConnectionHandoff then
        engine._pendingSpawnAtPlayer = true
        -- Remove any leftover trailers from the previous map immediately
        -- so they don't remain visible during transitions (healing, etc.)
        -- before the next update() processes the spawn-at-player sync.
        if ow then pcall(function() engine:removeTrailers(ow) end) end
      end
    end)
  subscribe("game.ready", function()
      local game = engine:_game()
      engine._mapExitSnapshot = nil
      engine._pendingConnectionHandoff = nil
      engine:alignSaveFromOptions(game)
      pcall(function()
        engine:syncPlayerControlVisual(game, engine:_liveOw(game))
      end)
      engine._pendingMapTrailerSync = true
      engine._pendingSpawnAtPlayer = true
      pcall(function() engine:_installTalkWrap() end)
      -- World.lua may load after the first install attempt; re-assert Gold
      -- World:step wrap now that the overworld exists.
      pcall(function() engine:_ensureGen2WorldStepWrap(game) end)
    end)
end

--- Install PikachuFollower hooks. Idempotent; restores previous on reinstall.
-- Returns false, "no_engine" when NPC/PikachuFollower are unavailable (tests).
function ControlEngine:install()
  if self._installed then
    self:restore()
  end

  -- Gen1: wrap OverworldController.update so trailers tick every frame
  -- (Red / Blue / Yellow), even when PikachuFollower is absent.
  -- Gen2: that wrap is skipped. Gold World:step is the per-logic-frame
  -- analog (owner = gen2_world_event). world.stepped is per-tile-land.
  local owWrapOk = self:_installOverworldUpdateWrap()
  local gen2WrapOk = self:_installGen2WorldStepWrap()

  -- Always install event subscriptions (map.entered, game.ready, etc.)
  -- regardless of PF availability.  Red/Blue needs these for the OW
  -- update wrap to work (it relies on _pendingMapTrailerSync).
  self:_installEventSubscriptions()

  local GameCompat = V.require("game_compat")
  local gen2 = GameCompat.isGen2(self.mod, self:_game())
  local PF = tryRequire("src.world.PikachuFollower")
  local NPC
  if gen2 then
    -- Same Loader.callerIsMod pitfall as makeTrailer: never pcall-require
    -- src.world.NPC on Gold. Prefer the Follower.lua module path.
    NPC = GameCompat.Gen2 and select(1, GameCompat.Gen2.npcModule())
    local okF, goldF = pcall(function()
      return require("src.world.gen2.Follower")
    end)
    if okF and type(goldF) == "table" then PF = goldF end
  else
    NPC = tryRequire("src.world.NPC")
  end
  if not PF or not NPC then
    -- Red / Blue: no PikachuFollower, but OverworldController.update
    -- is now wrapped and events are subscribed.  Return partial so
    -- lifecycle does NOT install its own hooks (which also need PF) —
    -- trailers are handled by the OW update wrap alone.
    if owWrapOk then
      self._trailerUpdateOwner = "overworld"
      self._installed = true
      return true, "ow_only"
    end
    if gen2WrapOk then
      self._trailerUpdateOwner = "gen2_world_event"
      logGen2(self.mod, "update-owner=gen2_world_event")
      self._installed = true
      return true, "gen2_world_only"
    end
    return false, "no_engine"
  end

  -- Hot-reload: restore any previous control-engine install first.
  local previous = rawget(PF, Constants.CONTROL_ENGINE_STATE_KEY)
  if previous and type(previous.restore) == "function" then
    pcall(previous.restore)
    owWrapOk = self:_installOverworldUpdateWrap()
    gen2WrapOk = self:_installGen2WorldStepWrap()
  end

  -- Owner is exclusive: Gen1 overworld, else Gold World:step, else PF fallback.
  if owWrapOk then
    self._trailerUpdateOwner = "overworld"
  elseif gen2WrapOk or GameCompat.isGen2(self.mod, self:_game()) then
    self._trailerUpdateOwner = "gen2_world_event"
    logGen2(self.mod, "update-owner=gen2_world_event")
    if not gen2WrapOk then
      logGen2(self.mod, "World.step wrap not installed yet (World may still be loading)")
    end
  else
    self._trailerUpdateOwner = "pikachu_follower"
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
    -- Gold World:step wrap is the exclusive Gen2 owner — do not also tick
    -- here or trailers double-update.
    if engine._trailerUpdateOwner == "pikachu_follower" then
      pcall(function()
        engine:update(game, ow, { source = "pikachu_follower" })
      end)
    elseif engine._trailerUpdateOwner == "gen2_world_event"
        and not engine._gen2WorldStepWrapped then
      pcall(function()
        engine:update(game, ow, { source = "gen2_world_event" })
      end)
    end
    return result
  end

  local function wrappedOnMapEntered(game, ow, opts, ...)
    -- Preserve the engine's trailing args: OverworldController calls
    -- onMapEntered(Game, self, opts, true) where the 4th arg is viaMapLoad
    -- (fresh map entry parks the stock Pikachu UNDER the player instead of
    -- behind his facing).  Dropping it made the Yellow follower respawn
    -- behind the player on door/warp exits and get stuck behind buildings.
    --
    -- Vanilla PikachuFollower.update also calls onMapEntered(game, ow)
    -- (no viaMapLoad) whenever it finds no follower mid-frame — that spawns
    -- the stock Pikachu BEHIND the player's facing.  While the entry parking
    -- is still pending (the engine's entry spawn may have been skipped or
    -- raced by a transitional frame), treat that re-spawn as a fresh entry
    -- too, so it parks under the player instead of materializing behind him.
    local viaMapLoad = ...
    if viaMapLoad == nil and engine._pendingSpawnAtPlayer == true then
      viaMapLoad = true
    end
    if origOnMap then origOnMap(game, ow, opts, viaMapLoad) end
    local mode = engine:controlMode(game)
    if mode == "pokemon" or mode == "lead_trainer" or mode == "pack" or engine:followerCount(game) <= 0 then
      pcall(function() engine:_removeStockPikachu(ow) end)
    else
      pcall(function() engine:forceYellowStockPikachuArt(ow, game) end)
    end
    engine._pendingMapTrailerSync = true
    -- Connection / walking-seam crossings are re-seeded by
    -- _applyConnectionHandoff. Do not force player-cell parking over a
    -- pending seam snapshot. Every other entry (warp / door / boot) parks
    -- the pack on the player's cell.
    if not engine._pendingConnectionHandoff then
      engine._pendingSpawnAtPlayer = true
    end
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
  pcall(function() self:_installGen2WorldStepWrap() end)
  if self._owUpdateWrapped then
    self._trailerUpdateOwner = "overworld"
  elseif self._gen2WorldStepWrapped then
    self._trailerUpdateOwner = "gen2_world_event"
    logGen2(self.mod, "update-owner=gen2_world_event")
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
    engine:_restoreGen2WorldStepWrap()
    engine._mapExitSnapshot = nil
    engine._pendingConnectionHandoff = nil
    engine._pendingSpawnAtPlayer = false
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
  self:_restoreGen2WorldStepWrap()
  self._installed = false
  self._restoreState = nil
  self._trailerUpdateOwner = nil
end

return ControlEngine
