-- Wilds unified follower system (PR 1).
--
-- Owns: selection, persistence, lifecycle, talk (when not deferred).
-- Does not own: wild spawn, water renderer, sprite style menu, shared resolver (PR 2).
--
-- Concepts adapted from:
--   * PokéPC Followers (gamecorner-033) — selection, fingerprint, talk, party UI
--   * Followers EX (masterwebx) — map-enter stability, single-owner discipline
local V = ...
local Constants = V.require("follower/constants")
local State = V.require("follower/state")
local Selection = V.require("follower/selection")
local Compatibility = V.require("follower/compatibility")
local Lifecycle = V.require("follower/lifecycle")
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
  if not (GV and GV.get) then return true end -- unit tests / no engine
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
  self.lifecycle = Lifecycle.new(mod, self.state, self.selection)
  self.logic = opts.logic
  self.render = opts.render
  self._installed = false
  self._supported = supportedVersion()
  return self
end

--- Default sprite refresh: reuse existing Wilds land/water integration.
--- No map-specific decisions; no new asset paths in lifecycle.
function Follower:installDefaultSpriteRefreshHandler()
  local follower = self
  self.lifecycle:setSpriteRefreshHandler(function(reason, ctx)
    ctx = ctx or {}
    local game = ctx.game
    local ow = ctx.ow or (game and game.overworld)
    local mon = ctx.mon or follower.selection:getActiveFollowerMon(game, false)
    local entity = ctx.entity
    if not entity and ow then
      local PF = tryRequire("src.world.PikachuFollower")
      if PF and PF.current then
        local ok, npc = pcall(PF.current, ow)
        if ok then entity = npc end
      end
    end

    -- Prefer FollowersWaterCompat when available (existing Wilds path).
    local logic = follower.logic
    if logic and logic.followersWater and logic.followersWater.tick
        and logic.resolveWaterSprite then
      pcall(function()
        if reason and tostring(reason):find("style", 1, true) then
          logic.followersWater:invalidateStyle()
        end
        logic.followersWater:tick(game, ow, function(speciesId, shiny, form, opts)
          return logic:resolveWaterSprite(speciesId, shiny, form, opts)
        end)
      end)
      return
    end

    -- Standalone fallback: resolve land sheet via Wilds providers and apply locally.
    if not (mon and entity and logic and logic.render and logic.render.spriteProviders) then
      return
    end
    local style = Config.spriteStyle(follower.mod)
    local shiny = mon.shiny == true or mon.isShiny == true
    local variant = shiny and "shiny" or "normal"
    local result = logic.render.spriteProviders:resolve(style, mon.species, variant, game)
    if not (result and result.image) then return end
    local def = {
      id = Constants.SPRITE_ID,
      image = result.image,
      frames = result.frames or 6,
      walker = result.walker ~= false,
      trueColor = result.trueColor,
    }
    follower.lifecycle:applyLocalSpriteDef(entity, def)
    follower.lifecycle:markEntity(entity, mon)
  end)
end

function Follower:install(opts)
  opts = opts or {}
  if self._installed then return true, "already" end
  if not self._supported then
    DebugLog.info(self.mod, "follower core skipped (unsupported game version)")
    return false, "unsupported"
  end

  local ownerMode, detected = self.compat:resolveOwnerMode()
  local game = opts.game

  -- Migrate legacy selection once (never deletes old keys).
  self.compat:migrateSelection(game, self.selection)

  if ownerMode == Constants.OWNER.external then
    self.compat:logExternalOwnerWarning(detected)
    -- Selection + party UI still available; no second entity / hooks.
    self.lifecycle:installPartySubmenu()
    self:installDefaultSpriteRefreshHandler()
    self._installed = true
    DebugLog.info(self.mod,
      "follower core deferred entity ownership to external mod (%s)",
      tostring(detected))
    return true, "deferred_external"
  end

  -- Absorb PokéPC lifecycle if present so Wilds is the sole wrapper.
  self.compat:restorePokePcIfPresent()

  self:installDefaultSpriteRefreshHandler()
  local ok, reason = self.lifecycle:installHooks()
  self.lifecycle:installPartySubmenu()
  self._installed = true
  DebugLog.info(self.mod, "follower core installed (owner=wilds reason=%s)",
                tostring(reason))
  return ok, reason
end

function Follower:reassertAfterModsLoaded(game)
  local ownerMode, detected = self.compat:resolveOwnerMode()
  self.compat:migrateSelection(game, self.selection)
  if ownerMode == Constants.OWNER.external then
    -- External loaded after us: tear down our hooks if we installed them.
    if self.lifecycle._installed then
      self.lifecycle:restoreHooks()
    end
    self.compat:logExternalOwnerWarning(detected)
    self.state.ownerMode = Constants.OWNER.external
    return "deferred_external"
  end
  -- External gone / PokéPC only: ensure Wilds hooks are outermost.
  self.compat:restorePokePcIfPresent()
  if not self.lifecycle._installed then
    self.lifecycle:installHooks()
  else
    -- Re-install so our wrappers stay outermost after late companion wraps.
    self.lifecycle:restoreHooks()
    self.lifecycle:installHooks()
  end
  self.lifecycle:installPartySubmenu()
  self.state.ownerMode = Constants.OWNER.wilds
  self._installed = true
  return "wilds"
end

function Follower:onMapEntered(ev)
  local game = ev and (ev.game or (ev.world and ev.world.game))
  if not game and self.mod and self.mod.world then
    game = self.mod.world.game
  end
  local ow = game and game.overworld
  self.lifecycle:onMapEntered(game, ow)
end

function Follower:onSaveLoaded()
  local game = self.mod and self.mod.world and self.mod.world.game
  self.lifecycle:onSaveLoaded(game)
end

function Follower:onOptionsChanged(payload)
  if payload and payload.key == "sprite_style" then
    self.lifecycle:requestFollowerSpriteRefresh("style_changed", {
      game = self.mod and self.mod.world and self.mod.world.game,
    })
  end
end

function Follower:getActiveFollowerMon(game, needHealthy)
  return self.selection:getActiveFollowerMon(game, needHealthy)
end

function Follower:selectFollower(mon, game, quiet)
  return self.selection:selectFollower(mon, game, {
    onSelected = function(selected, slot, g)
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

function Follower:snapshot()
  local snap = self.state:snapshot()
  snap.installed = self._installed
  snap.hooksInstalled = self.lifecycle._installed == true
  snap.supported = self._supported
  return snap
end

function Follower:hudLines()
  return FollowerDiagnostics.lines(self)
end

function Follower:restore()
  self.lifecycle:restoreHooks()
  self._installed = false
end

Follower.Constants = Constants
Follower.State = State
Follower.Selection = Selection
Follower.Compatibility = Compatibility
Follower.Lifecycle = Lifecycle

return Follower
