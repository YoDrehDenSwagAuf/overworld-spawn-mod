-- Wilds unified follower system (standalone).
--
-- Owns: selection, persistence, control modes, trailers, talk, sprite refresh.
-- No Followers EX / PokéPC runtime dependency.
--
-- Concepts adapted from:
--   * PokéPC Followers (gamecorner-033) — selection, fingerprint, talk
--   * Followers EX (masterwebx) — ControlEngine pack / modes / trailers
-- Assets: Wilds HGSS/PokeMMO runtime sheets (no external sprite pack required).
local V = ...
local Constants = V.require("follower/constants")
local State = V.require("follower/state")
local Selection = V.require("follower/selection")
local Compatibility = V.require("follower/compatibility")
local Lifecycle = V.require("follower/lifecycle")
local SpriteService = V.require("follower/sprite_service")
local Settings = V.require("follower/settings")
local ControlEngine = V.require("follower/control_engine")
local FollowerDiagnostics = V.require("follower/diagnostics")
local DebugLog = V.require("debug_log")
local Config = V.require("config")

local Follower = {}
Follower.__index = Follower

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function supportedVersion()
  local GV = tryRequire("src.core.GameVersion")
  if not (GV and GV.get) then return true end
  local ok, v = pcall(GV.get)
  if not ok or v == nil then return true end
  return v == "red" or v == "blue" or v == "yellow"
end

function Follower.new(mod, opts)
  opts = opts or {}
  local self = setmetatable({}, Follower)
  self.mod = mod
  self.state = State.new(mod)
  self.selection = Selection.new(mod, self.state)
  self.compat = Compatibility.new(mod, self.state)
  self.settings = Settings.new(mod)
  self.logic = opts.logic
  self.render = opts.render
  self.spriteService = SpriteService.new(mod, {
    render = opts.render,
    logic = opts.logic,
  })
  self.lifecycle = Lifecycle.new(mod, self.state, self.selection)
  self.control = ControlEngine.new(mod, {
    spriteService = self.spriteService,
    settings = self.settings,
    selection = self.selection,
    render = opts.render,
  })
  self._installed = false
  self._supported = supportedVersion()
  -- Wilds is always the runtime owner after this follow-up.
  self.state.ownerMode = Constants.OWNER.wilds
  return self
end

function Follower:installDefaultSpriteRefreshHandler()
  local follower = self
  self.lifecycle:setSpriteRefreshHandler(function(reason, ctx)
    ctx = ctx or {}
    local game = ctx.game
    local ow = ctx.ow or (game and game.overworld)
    local mon = ctx.mon or follower.selection:getActiveFollowerMon(game, false)
    local entity = ctx.entity
    local surface = ctx.surface or follower.state.surface or "land"

    if mon and follower.spriteService then
      local resolved = follower.spriteService:resolveFollowerSprite({
        species = mon.species,
        shiny = mon.shiny == true or mon.isShiny == true,
        form = mon.form,
        surface = surface,
        style = Config.spriteStyle(follower.mod),
        role = "primary",
        game = game,
      })
      if resolved and entity then
        follower.lifecycle:applyLocalSpriteDef(entity, resolved)
        follower.lifecycle:markEntity(entity, mon)
      end
    end

    -- Water compat still ticks for surfing presentation.
    local logic = follower.logic
    if logic and logic.followersWater and logic.followersWater.tick
        and logic.resolveWaterSprite then
      pcall(function()
        if reason and tostring(reason):find("style", 1, true) then
          logic.followersWater:invalidateStyle()
        end
        logic.followersWater:tick(game, ow, function(speciesId, shiny, form, o)
          return logic:resolveWaterSprite(speciesId, shiny, form, o)
        end)
      end)
    end
  end)
end

--- LOAD PHASE: register SPRITE_PIKACHU before content freeze.
function Follower:registerContent()
  return self.spriteService:registerLoadPhaseSprites()
end

function Follower:install(opts)
  opts = opts or {}
  if self._installed then return true, "already" end
  if not self._supported then
    DebugLog.info(self.mod, "follower core skipped (unsupported game version)")
    return false, "unsupported"
  end

  local game = opts.game
  self.state.ownerMode = Constants.OWNER.wilds

  -- Detect legacy mods for migration only — never defer runtime ownership.
  self.compat:detectExternalMods()
  if #(self.state.externalMods or {}) > 0 then
    local msg = "[Wilds] Legacy follower mod detected. Settings and selection were imported; Wilds now owns follower runtime."
    if self.mod and self.mod.log and self.mod.log.info then
      pcall(function() self.mod.log:info("%s", msg) end)
    end
    DebugLog.info(self.mod, "%s", msg)
    -- Best-effort: restore PokéPC / EX hooks so they do not double-run.
    self.compat:restorePokePcIfPresent()
    self.compat:restoreFollowersExIfPresent()
  end

  self.settings:migrateFromLegacy(game)
  self.compat:migrateSelection(game, self.selection)
  self.settings:alignSave(game)

  -- Ensure sprite id exists (also called from registerContent during load).
  pcall(function() self.spriteService:registerLoadPhaseSprites() end)

  self:installDefaultSpriteRefreshHandler()

  -- Control engine owns shouldSpawn / update / onMapEntered / trailers.
  local okEngine, engineReason = self.control:install()
  if not okEngine then
    -- Engine modules unavailable (unit tests / early load): fall back to
    -- lifecycle-only hooks so selection UI still works when possible.
    DebugLog.info(self.mod, "control engine deferred (%s); lifecycle fallback",
                  tostring(engineReason))
    self.lifecycle:installHooks()
  end

  -- Party FOLLOWER submenu (selection). Handled solely by _installPartyLeaderItems.
  self:_installPartyLeaderItems()

  self._installed = true
  DebugLog.info(self.mod, "follower standalone core installed (engine=%s)",
                tostring(okEngine))
  return true, okEngine and "control_engine" or engineReason
end

-- Helper: match mon to its party slot index reliably
local function findPartyIndex(mon, party, selection)
  if not mon or not party then return nil end

  local targetKey = selection and selection.monFingerprint and selection.monFingerprint(mon)
  for idx, pMon in ipairs(party) do
    if pMon == mon then
      return idx
    end
    if targetKey and selection and selection.monFingerprint then
      if selection.monFingerprint(pMon) == targetKey then
        return idx
      end
    end
    if pMon.species == mon.species and pMon.hp == mon.hp and pMon.level == mon.level then
      return idx
    end
  end
  return nil
end

function Follower:_installPartyLeaderItems()
  -- Extend party submenu: FOLLOW sets active follower mon, DISMISS clears it.
  local mod = self.mod
  local selection = self.selection
  local control = self.control
  if not (mod and mod.hooks and mod.hooks.wrap) then return end
  if self._leaderMenuWrapped then return end

  pcall(function()
    mod.hooks:wrap("ui.party.submenu", function(next, game, items, mon, ctx)
      local out = next(game, items, mon, ctx)
      if type(out) ~= "table" or (ctx and ctx.battle)
          or not selection.healthy(mon) then
        return out
      end

      -- Strip existing follower rows to prevent duplicate/overflowing options.
      local clean = {}
      for _, row in ipairs(out) do
        if row and row.label ~= "FOLLOW" and row.label ~= "DISMISS" then
          clean[#clean + 1] = row
        end
      end
      out = clean

      local party = (game and game.save and game.save.party) or {}
      local monIndex = findPartyIndex(mon, party, selection)
      if not monIndex then return out end

      -- Determine if this mon is currently the active leader/follower
      local active = control:getActiveFollowerMon(game)
      local activeKey = selection.state and selection.state.selectedMonKey
      local monKey = selection.monFingerprint and selection.monFingerprint(mon)

      local isActive = active and mon and (
        active == mon or (activeKey and monKey and activeKey == monKey)
      )

      if isActive then
        out[#out + 1] = {
          label = "DISMISS",
          onSelect = function(selected, selectedGame)
            if selection and selection.state then
              selection.state:clearSelection()
            end
            control:clearLeader(selectedGame)
            control:setFollowerCount(selectedGame, 0)
            if selectedGame and selectedGame.save then
              selectedGame.save.followerPartyIndex = nil
              selectedGame.save.pokepcFollowerCount = 0
              selectedGame.save.followerPartyIndices = nil
              selectedGame.save.followerOrder = nil
            end
            control._optCache.follower_count = 0
            control._pendingMapTrailerSync = true

            if mod and mod.options and mod.options.set then
              pcall(function() mod.options:set("follower_count", 0) end)
            end

            pcall(function() control:syncAll(selectedGame, selectedGame and selectedGame.overworld) end)

            local name = selected.nickname or selected.species or "It"
            local msg = name .. " is no longer following."
            if selectedGame and selectedGame.stack and mod and mod.ui and mod.ui.TextBox then
              pcall(function()
                selectedGame.stack:push(mod.ui.TextBox.new(selectedGame, msg))
              end)
            end
          end,
        }
      else
        out[#out + 1] = {
          label = "FOLLOW",
          onSelect = function(selected, selectedGame)
            -- Ensure at least 1 follower is set if currently at 0
            if control:followerCount(selectedGame) <= 0 then
              control:setFollowerCount(selectedGame, 1)
              control._optCache.follower_count = 1
              if selectedGame and selectedGame.save then
                selectedGame.save.pokepcFollowerCount = 1
              end
              if mod and mod.options and mod.options.set then
                pcall(function() mod.options:set("follower_count", 1) end)
              end
            end

            if selectedGame and selectedGame.save then
              selectedGame.save.followerPartyIndex = monIndex
            end

            control:setLeaderParty(selectedGame, monIndex)
            selection:selectFollower(selected, selectedGame, {})
            control._pendingMapTrailerSync = true

            pcall(function() control:syncAll(selectedGame, selectedGame and selectedGame.overworld) end)

            local name = selected.nickname or selected.species or "It"
            local msg = name .. " is now following you!"
            if selectedGame and selectedGame.stack and mod and mod.ui and mod.ui.TextBox then
              pcall(function()
                selectedGame.stack:push(mod.ui.TextBox.new(selectedGame, msg))
              end)
            end
          end,
        }
      end
      return out
    end)
  end)
  self._leaderMenuWrapped = true
end

--- Called from main.lua when an external mod (e.g. Followers EX) hooks into
-- Wilds via setOptionsChangedHandler.
function Follower:disableExternalFollowersIfHooked()
  self._pendingExternalModCleanup = true
  self.compat:restoreFollowersExIfPresent()
  self.compat:restorePokePcIfPresent()
end

function Follower:processPendingExternalModCleanup()
  if not self._pendingExternalModCleanup then return end
  self._pendingExternalModCleanup = false
  pcall(function()
    self.control:restore()
    self.control:install()
  end)
end

function Follower:reassertAfterModsLoaded(game)
  self.state.ownerMode = Constants.OWNER.wilds
  self.compat:detectExternalMods()
  self.compat:restorePokePcIfPresent()
  self.compat:restoreFollowersExIfPresent()
  self.settings:migrateFromLegacy(game)
  self.compat:migrateSelection(game, self.selection)
  self.settings:alignSave(game)

  if not self.control._installed then
    local ok = self.control:install()
    if not ok and not self.lifecycle._installed then
      self.lifecycle:installHooks()
    end
  else
    -- Re-install outermost after late companion wraps.
    self.control:restore()
    self.control:install()
  end
  self:_installPartyLeaderItems()
  if game then
    pcall(function() self.spriteService:installPartyMenuHook() end)
    pcall(function() self.spriteService:patchPartyIconTrueColor(game) end)
  end
  self._installed = true
  return "wilds"
end

function Follower:onMapEntered(ev)
  local game = ev and (ev.game or (ev.world and ev.world.game))
  if not game and self.mod and self.mod.world then
    game = self.mod.world.game
  end
  local ow = game and game.overworld
  -- Control engine map.entered event also runs; keep selection reconciled.
  self.selection:reconcile(game)
  if not self.control._installed then
    self.lifecycle:onMapEntered(game, ow)
  end
end

function Follower:onSaveLoaded()
  local game = self.mod and self.mod.world and self.mod.world.game
  self.settings:alignSave(game)
  self.lifecycle:onSaveLoaded(game)
  if game then
    pcall(function() self.spriteService:installPartyMenuHook() end)
    pcall(function() self.spriteService:patchPartyIconTrueColor(game) end)
  end
  if self.control._installed then
    pcall(function()
      self.control:alignSaveFromOptions(game)
      self.control:syncAll(game, game and game.overworld)
    end)
  end
end

function Follower:onOptionsChanged(payload)
  if not payload then return end
  local key = payload.key
  self.settings:onOptionsChanged(payload)
  if key == "follow_control" or key == "trainer_trail" or key == "follower_count"
      or key == "sprite_style" then
    local game = self.mod and self.mod.world and self.mod.world.game
    self.settings:alignSave(game)
    if self.control then
      self.control:onOptionsChanged(payload)
    end
    self.lifecycle:requestFollowerSpriteRefresh("options:" .. tostring(key), {
      game = game,
    })
  end
end

function Follower:getActiveFollowerMon(game, needHealthy)
  if self.control and self.control.getActiveFollowerMon then
    local mon = self.control:getActiveFollowerMon(game)
    if mon then
      if needHealthy == false or (tonumber(mon.hp) or 0) > 0 then
        return mon
      end
    end
  end
  return self.selection:getActiveFollowerMon(game, needHealthy)
end

function Follower:selectFollower(mon, game, quiet)
  return self.selection:selectFollower(mon, game, {
    onSelected = function(selected, slot, g)
      if self.control and self.control.setLeaderParty then
        self.control:setLeaderParty(g, slot)
        pcall(function()
          self.control:syncAll(g, g and g.overworld)
        end)
      end
      self.lifecycle:requestFollowerSpriteRefresh("party_select", {
        game = g,
        ow = g and g.overworld,
        mon = selected,
        slot = slot,
      })
      if quiet then return end
    end,
  })
end

function Follower:setControlMode(game, mode)
  return self.control:setControlMode(game, mode)
end

function Follower:controlMode(game)
  return self.control:controlMode(game)
end

function Follower:setFollowerCount(game, n)
  return self.control:setFollowerCount(game, n)
end

function Follower:followerCount(game)
  return self.control:followerCount(game)
end

function Follower:syncAll(game, ow)
  return self.control:syncAll(game, ow)
end

function Follower:syncTrailers(game, ow, opts)
  return self.control:syncTrailers(game, ow, opts)
end

function Follower:update(game, ow, opts)
  return self.control:update(game, ow, opts)
end

function Follower:snapshot()
  local snap = self.state:snapshot()
  snap.installed = self._installed
  snap.hooksInstalled = self.lifecycle._installed == true
  snap.controlEngine = self.control._installed == true
  snap.trailerUpdateOwner = self.control._trailerUpdateOwner
  snap.supported = self._supported
  snap.followControl = self.settings:followControl()
  snap.trainerTrail = self.settings:trainerTrail()
  snap.followerCount = self.settings:followerCount()
  snap.engineMode = self.settings:engineMode()
  snap.spriteRegistered = self.spriteService._registered == true
  return snap
end

function Follower:hudLines()
  return FollowerDiagnostics.lines(self)
end

function Follower:restore()
  if self.control then self.control:restore() end
  self.lifecycle:restoreHooks()
  self._installed = false
end

Follower.Constants = Constants
Follower.State = State
Follower.Selection = Selection
Follower.Compatibility = Compatibility
Follower.Lifecycle = Lifecycle
Follower.SpriteService = SpriteService
Follower.Settings = Settings
Follower.ControlEngine = ControlEngine

return Follower