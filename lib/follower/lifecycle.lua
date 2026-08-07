-- Follower entity lifecycle (spawn/despawn/map/update/bike/surf).
-- Adapted from PokéPC Followers + Followers EX stability ideas.
-- No direct asset paths; sprite refresh goes through a injectable handler.
local V = ...
local Constants = V.require("follower/constants")
local DebugLog = V.require("debug_log")

local Lifecycle = {}
Lifecycle.__index = Lifecycle

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function replaceUpvalue(fn, wanted, replacement)
  if type(fn) ~= "function" or not (debug and debug.getupvalue and debug.setupvalue) then
    return false
  end
  local i = 1
  while true do
    local name, old = debug.getupvalue(fn, i)
    if not name then return false end
    if name == wanted then
      debug.setupvalue(fn, i, replacement)
      return true, old
    end
    i = i + 1
  end
end

local function copySpriteDef(def)
  if type(def) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(def) do
    out[k] = v
  end
  return out
end

local function defAlreadyBound(entity, def)
  if not (entity and entity.sprite and entity.sprite.def and def) then
    return false
  end
  local cur = entity.sprite.def
  return cur.image == def.image
     and cur.frames == def.frames
     and cur.walker == def.walker
end

function Lifecycle.new(mod, state, selection)
  local self = setmetatable({}, Lifecycle)
  self.mod = mod
  self.state = state
  self.selection = selection
  self._spriteRefreshHandler = nil
  self._installed = false
  self._originals = {}
  self._wrappers = {}
  self._vanillaShouldSpawn = nil
  self._lastSurface = Constants.SURFACE.land
  self._partyMenuWrapped = false
  self._submenuWrapped = false
  return self
end

function Lifecycle:setSpriteRefreshHandler(handler)
  if type(handler) == "function" then
    self._spriteRefreshHandler = handler
  end
end

function Lifecycle:requestFollowerSpriteRefresh(reason, ctx)
  self.state.lastRefreshReason = reason
  local handler = self._spriteRefreshHandler
  if type(handler) ~= "function" then
    return false, "no_handler"
  end
  local ok, err = pcall(handler, reason, ctx or {})
  if not ok then
    DebugLog.warn(self.mod, "follower sprite refresh failed (%s): %s",
                  tostring(reason), tostring(err))
    return false, err
  end
  return true
end

function Lifecycle:markEntity(npc, mon)
  if not npc then return end
  npc.wildsFollower = true
  npc.isFollower = true
  npc.follower = true
  if npc.wildsFollowerRole == nil and npc.pokepcTrailer ~= true then
    npc.wildsFollowerRole = "primary"
  end
  if mon then
    npc._wildsFollowerSpecies = mon.species
    npc._wildsFollowerFingerprint = self.selection.monFingerprint(mon)
  end
end

function Lifecycle:applyLocalSpriteDef(npc, def)
  if not (npc and def) then return false, "missing" end
  if defAlreadyBound(npc, def) then
    return false, "unchanged"
  end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new) then
    return false, "no_renderer"
  end
  local localDef = copySpriteDef(def)
  -- Preserve pose / movement fields owned by stock follower.
  local facing = npc.facing
  local moving = npc.moving
  local cellX, cellY = npc.cellX, npc.cellY
  local px, py = npc.px, npc.py
  local targetX, targetY = npc.targetX, npc.targetY
  local progress = npc.progress
  local march = npc.marching
  local hop = npc.hopStep

  npc.sprite = SpriteRenderer.new(localDef, npc.id)
  self.state.spriteRendererNews = (self.state.spriteRendererNews or 0) + 1

  npc.facing = facing
  npc.moving = moving
  npc.cellX, npc.cellY = cellX, cellY
  npc.px, npc.py = px, py
  npc.targetX, npc.targetY = targetX, targetY
  npc.progress = progress
  npc.marching = march
  npc.hopStep = hop
  npc.usingFollowerSprite = true
  npc.usingEnhancedSprite = false
  return true, "rebinding"
end

function Lifecycle:purgeFollowerEntities(ow)
  if not (ow and ow.entities) then return 0 end
  local removed = 0
  local j = 1
  for i = 1, #ow.entities do
    local ent = ow.entities[i]
    local isFollower = ent and (
      ent.wildsFollower == true
      or ent.id == Constants.ENTITY_ID
      or (ent.sprite and ent.sprite.def and ent.sprite.def.id == Constants.SPRITE_ID
          and ent.pikachuFollower == true)
    )
    -- Never purge Followers EX trailers (external ownership).
    if ent and ent.pokepcTrailer == true then
      isFollower = false
    end
    if not isFollower then
      ow.entities[j] = ent
      j = j + 1
    else
      removed = removed + 1
    end
  end
  for i = j, #ow.entities do ow.entities[i] = nil end
  return removed
end

function Lifecycle:shouldSpawn(game, ow)
  local save = game and game.save
  if not (save and ow) then return false end
  if not save.party or #save.party == 0 then return false end
  if save.onBike then return false end
  local player = ow.player
  if player and player.surfing then return false end
  -- Crash guard: never spawn without a registered SPRITE_PIKACHU.
  local sprites = game.data and game.data.sprites
  if not (sprites and sprites[Constants.SPRITE_ID]) then
    return false
  end
  return self.selection:getActiveFollowerMon(game, true) ~= nil
end

function Lifecycle:_updateSurface(game, ow)
  local player = ow and ow.player
  local surfing = player and player.surfing == true
  local nextSurface
  if surfing then
    nextSurface = Constants.SURFACE.surfing
  elseif self._lastSurface == Constants.SURFACE.surfing then
    nextSurface = Constants.SURFACE.return_to_land
  else
    nextSurface = Constants.SURFACE.land
  end
  if nextSurface ~= self._lastSurface then
    self.state:setSurface(nextSurface)
    self:requestFollowerSpriteRefresh("surface:" .. nextSurface, {
      game = game,
      ow = ow,
      surface = nextSurface,
    })
    if nextSurface == Constants.SURFACE.return_to_land then
      self._lastSurface = Constants.SURFACE.land
      self.state:setSurface(Constants.SURFACE.land)
    else
      self._lastSurface = nextSurface
    end
  end
end

function Lifecycle:_currentNpc(ow)
  local PF = tryRequire("src.world.PikachuFollower")
  if PF and PF.current then
    local ok, npc = pcall(PF.current, ow)
    if ok then return npc end
  end
  return nil
end

function Lifecycle:_afterSync(game, ow)
  self.selection:reconcile(game)
  local mon = self.selection:getActiveFollowerMon(game, true)
  local npc = self:_currentNpc(ow)
  if npc and mon then
    self:markEntity(npc, mon)
  end
  self:_updateSurface(game, ow)
  self:requestFollowerSpriteRefresh("sync", {
    game = game,
    ow = ow,
    entity = npc,
    mon = mon,
    surface = self.state.surface,
  })
end

function Lifecycle:installHooks()
  if self._installed then return true, "already" end
  -- When control engine owns PikachuFollower hooks, lifecycle must not wrap them.
  -- Callers (Follower:install) skip this when control engine succeeds.

  local PF = tryRequire("src.world.PikachuFollower")
  if not PF then return false, "no_pikachu_follower" end

  -- Hot-reload: restore previous Wilds install first.
  local previous = rawget(PF, Constants.STATE_KEY)
  if previous and type(previous.restore) == "function" then
    pcall(previous.restore)
  end

  local originalUpdate = PF.update
  local originalOnMapEntered = PF.onMapEntered
  local originalTalk = PF.talk
  local originalStarterInParty = PF.starterInParty

  local lifecycle = self
  local function shouldSpawn(game, ow)
    return lifecycle:shouldSpawn(game, ow)
  end

  local vanillaShouldSpawn
  if originalUpdate then
    local _, oldSpawn = replaceUpvalue(originalUpdate, "shouldSpawn", shouldSpawn)
    vanillaShouldSpawn = oldSpawn
  end
  pcall(function()
    replaceUpvalue(PF.onMapEntered, "shouldSpawn", shouldSpawn)
  end)

  local function wrappedStarterInParty(save, needHealthy)
    local Game = tryRequire("src.core.Game")
    local active = lifecycle.selection:getActiveFollowerMon(Game, needHealthy)
    if active then return active end
    for _, mon in ipairs(save and save.party or {}) do
      if not needHealthy or lifecycle.selection.healthy(mon) then
        return mon
      end
    end
    return nil
  end

  local function wrappedOnMapEntered(game, ow, opts)
    -- Do not mutate global sprite defs here (safe-location bug mitigation).
    local result = originalOnMapEntered and originalOnMapEntered(game, ow, opts)
    if ow and ow.entities and not shouldSpawn(game, ow) then
      lifecycle:purgeFollowerEntities(ow)
    else
      lifecycle:_afterSync(game, ow)
    end
    -- Map transitions must not wipe selection state.
    return result
  end

  local function wrappedUpdate(game, ow, ...)
    if ow and not shouldSpawn(game, ow) then
      lifecycle:purgeFollowerEntities(ow)
      lifecycle:_updateSurface(game, ow)
      return
    end
    local result = originalUpdate and originalUpdate(game, ow, ...)
    pcall(function() lifecycle:_afterSync(game, ow) end)
    return result
  end

  local Interaction = V.require("follower/interaction")
  local interaction = Interaction.new(self.mod, self.selection)
  local wrappedTalk = interaction:makeTalkWrapper(originalTalk)

  PF.starterInParty = wrappedStarterInParty
  if originalOnMapEntered then PF.onMapEntered = wrappedOnMapEntered end
  if originalUpdate then PF.update = wrappedUpdate end
  if originalTalk then PF.talk = wrappedTalk end

  local restoreState = {
    originalUpdate = originalUpdate,
    originalOnMapEntered = originalOnMapEntered,
    originalTalk = originalTalk,
    originalStarterInParty = originalStarterInParty,
    wrapperUpdate = wrappedUpdate,
    wrapperOnMapEntered = wrappedOnMapEntered,
    wrapperTalk = wrappedTalk,
    wrapperStarterInParty = wrappedStarterInParty,
    originalShouldSpawn = vanillaShouldSpawn,
  }

  restoreState.restore = function()
    if originalUpdate and vanillaShouldSpawn then
      replaceUpvalue(originalUpdate, "shouldSpawn", vanillaShouldSpawn)
    end
    if PF.update == wrappedUpdate then PF.update = originalUpdate end
    if PF.onMapEntered == wrappedOnMapEntered then
      PF.onMapEntered = originalOnMapEntered
    end
    if PF.talk == wrappedTalk then PF.talk = originalTalk end
    if PF.starterInParty == wrappedStarterInParty then
      PF.starterInParty = originalStarterInParty
    end
    if rawget(PF, Constants.STATE_KEY) == restoreState then
      rawset(PF, Constants.STATE_KEY, nil)
    end
  end

  rawset(PF, Constants.STATE_KEY, restoreState)
  self._restoreState = restoreState
  self._installed = true
  self._originals = restoreState
  self._wrappers = {
    update = wrappedUpdate,
    onMapEntered = wrappedOnMapEntered,
    talk = wrappedTalk,
    starterInParty = wrappedStarterInParty,
    shouldSpawn = shouldSpawn,
  }
  self._vanillaShouldSpawn = vanillaShouldSpawn
  return true, "installed"
end

function Lifecycle:restoreHooks()
  if self._restoreState and type(self._restoreState.restore) == "function" then
    pcall(self._restoreState.restore)
  end
  self._installed = false
end

function Lifecycle:installPartySubmenu()
  if self._submenuWrapped then return true, "already" end
  local mod = self.mod
  local selection = self.selection
  local lifecycle = self

  local function onSelected(mon, game)
    local ok = selection:selectFollower(mon, game, {
      onSelected = function(selected, slot, g)
        lifecycle:requestFollowerSpriteRefresh("party_select", {
          game = g,
          ow = g and g.overworld,
          mon = selected,
          slot = slot,
        })
        local Sound = tryRequire("src.core.Sound")
        local Strings = tryRequire("src.core.Strings")
        local TextBox = tryRequire("src.render.TextBox")
        if Sound and Sound.play and g and g.data then
          pcall(Sound.play, g.data, "Swap")
        end
        local def = g and g.data and g.data.pokemon and g.data.pokemon[selected.species]
        local name = selected.nickname or (def and def.name) or selected.species
        local text
        if Strings then
          local sok, formatted = pcall(Strings, "%s is now\nyour follower!", name)
          text = sok and formatted or (tostring(name) .. " is now\nyour follower!")
        else
          text = tostring(name) .. " is now\nyour follower!"
        end
        if g and g.stack and TextBox and TextBox.new then
          g.stack:push(TextBox.new(g, text))
        end
      end,
    })
    return ok
  end

  if mod.hooks and mod.hooks.wrap then
    local ok = pcall(function()
      mod.hooks:wrap("ui.party.submenu", function(next, game, items, mon, ctx)
        local out = next(game, items, mon, ctx)
        if type(out) ~= "table" or (ctx and ctx.battle)
            or not selection.healthy(mon) then
          return out
        end
        local Strings = tryRequire("src.core.Strings")
        local active = selection:getActiveFollowerMon(game, true)
        local label = (active == mon) and "FOLLOWING" or "FOLLOWER"
        if Strings then
          local sok, formatted = pcall(Strings, label)
          if sok and formatted then label = formatted end
        end
        out[#out + 1] = {
          label = label,
          onSelect = function(selected, selectedGame)
            onSelected(selected, selectedGame)
          end,
        }
        return out
      end)
    end)
    if ok then self._submenuWrapped = true end
  end

  if mod.events and mod.events.on and not self._submenuWrapped then
    pcall(function()
      mod.events:on("ui.party.submenu", function(e)
        if not e or not e.items or not e.mon or not e.game then return end
        if e.ctx and e.ctx.battle then return end
        if not selection.healthy(e.mon) then return end
        local active = selection:getActiveFollowerMon(e.game, true)
        local label = (active == e.mon) and "FOLLOWING" or "FOLLOWER"
        e.items[#e.items + 1] = {
          label = label,
          onSelect = function(selectedMon, game)
            onSelected(selectedMon, game)
          end,
        }
      end)
    end)
    self._submenuWrapped = true
  end

  return self._submenuWrapped, "party_submenu"
end

function Lifecycle:onMapEntered(game, ow)
  if self.state.ownerMode == Constants.OWNER.external then
    -- Still reconcile selection + surface signals without touching entities.
    self.selection:reconcile(game)
    self:_updateSurface(game, ow)
    return
  end
  if not self:shouldSpawn(game, ow) then
    self:purgeFollowerEntities(ow)
  else
    self:_afterSync(game, ow)
  end
end

function Lifecycle:onSaveLoaded(game)
  self.selection:reconcile(game)
end

return Lifecycle
