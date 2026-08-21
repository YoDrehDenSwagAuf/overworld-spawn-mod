-- NPC AI dialogue flow: vanilla first, then optional Talk / free-text / reply.
local V = ...
local GameCompat = V.require("game_compat")
local AiConfig = V.require("ai/config")
local Providers = V.require("ai/providers/init")
local ContextBuilder = V.require("ai/context_builder")
local Memory = V.require("ai/memory")
local Prompt = V.require("ai/prompt")
local Input = V.require("ai/input")
local AiLog = V.require("ai/log")
local Transport = V.require("ai/transport")

local Dialogue = {}
Dialogue.__index = Dialogue

function Dialogue.new(mod, opts)
  local self = setmetatable({}, Dialogue)
  self.mod = mod
  self.follower = opts and opts.follower
  self._active = nil -- { provider, handle, npc, ctx, game, ow }
  self._talkWrapped = false
  self._origTalkTo = nil
  self._forceProvider = nil -- tests: "mock"
  return self
end

function Dialogue:setForceProvider(id)
  self._forceProvider = id
end

function Dialogue:hasActiveRequest()
  return self._active ~= nil
end

local function tryRequire(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil
end

function Dialogue:eligible(game, ow, npc)
  if not AiConfig.enabled(self.mod) then return false, "disabled" end
  if not npc or npc.wildsAmbientPokemon then return false, "ambient" end
  if npc._wildsFollower or npc.isFollower then return false, "follower" end
  if ContextBuilder.isDenied(npc) then return false, "denylist" end
  if GameCompat.followerInteractionBusy(game, ow, npc) then
    return false, "busy"
  end
  if npc.moving then return false, "moving" end
  local provider = Providers.resolve(self.mod, self._forceProvider)
  if provider.id == "mock" or self._forceProvider == "mock" then
    return true, "ok"
  end
  local ok, ready = pcall(function() return provider.isConfigured(self.mod) end)
  if not (ok and ready) then return false, "provider" end
  if not Transport.available(self.mod) and not Transport._mock then
    return false, "transport"
  end
  return true, "ok"
end

function Dialogue:_provider()
  return Providers.resolve(self.mod, self._forceProvider)
end

function Dialogue:_present(game, ow, text, onDone)
  GameCompat.presentText(self.mod, game, ow, text, onDone)
end

function Dialogue:_presentChoice(game, ow, text, onChoose, labels)
  GameCompat.presentTextChoice(self.mod, game, ow, text, onChoose, {
    labels = labels or { "Talk", "Leave" },
  })
end

function Dialogue:_beginAiChat(game, ow, npc)
  local mod = self.mod
  local ctx = ContextBuilder.build(mod, game, ow, npc)
  local thinking = (ctx.npcName or "Someone") .. " is thinking..."

  Input.prompt(mod, game, {
    title = "ASK WHAT?",
    maxLen = Prompt.MAX_USER_CHARS,
  }, function(message)
    if type(message) ~= "string" or message == "" then
      return
    end
    message = Prompt.clampUserText(message)
    local provider = self:_provider()
    -- Show thinking line without blocking; start request immediately.
    self:_present(game, ow, thinking, function() end)

    local handle, err = provider.startRequest(mod, ctx, message)
    if not handle then
      AiLog.warn(mod, "startRequest failed: %s", tostring(err))
      self:_present(game, ow, "Hmm... I have nothing to say right now.", function() end)
      return
    end
    self._active = {
      provider = provider,
      handle = handle,
      npc = npc,
      ctx = ctx,
      game = game,
      ow = ow,
      userMessage = message,
      started = os.clock(),
      timeout = 28,
    }
    AiLog.info(mod, "request started provider=%s npc=%s",
      tostring(provider.id), tostring(ctx.npcName))
  end)
end

function Dialogue:afterVanilla(game, ow, npc)
  local ok, reason = self:eligible(game, ow, npc)
  if not ok then return false end
  local name = ContextBuilder.npcDisplayName(npc)
  self:_presentChoice(game, ow,
    name .. ": Want to talk more?",
    function(yes)
      if yes then
        self:_beginAiChat(game, ow, npc)
      end
    end,
    { "Talk", "Leave" })
  return true
end

function Dialogue:tick()
  local active = self._active
  if not active then return end
  local mod = self.mod
  local provider = active.provider
  local ok, st = pcall(function()
    return provider.poll(mod, active.handle)
  end)
  if not ok then
    AiLog.warn(mod, "poll crashed: %s", tostring(st))
    self._active = nil
    return
  end
  st = st or { status = "error", err = "nil" }
  if st.status == "pending" then
    local elapsed = os.clock() - (active.started or os.clock())
    if elapsed > (active.timeout or 28) then
      pcall(function() provider.cancel(mod, active.handle) end)
      self._active = nil
      AiLog.warn(mod, "request timeout")
      self:_present(active.game, active.ow, "......", function() end)
    end
    return
  end
  self._active = nil
  if st.status == "success" and type(st.text) == "string" then
    Memory.append(mod, active.game, active.ctx.npcId, "user", active.userMessage)
    Memory.append(mod, active.game, active.ctx.npcId, "assistant", st.text)
    local pages = Prompt.toTextBoxPages(st.text)
    local text = table.concat(pages, "\n")
    self:_present(active.game, active.ow, text, function() end)
    AiLog.info(mod, "reply ok chars=%d", #st.text)
  else
    AiLog.warn(mod, "request error: %s", tostring(st.err))
    self:_present(active.game, active.ow, "Hmm... Never mind.", function() end)
  end
end

--- Wrap OverworldController.talkTo so AI offer runs after vanilla (and ambient).
function Dialogue:installTalkWrap()
  if self._talkWrapped then return true end
  local OverworldState = tryRequire("src.world.OverworldController")
  if not (OverworldState and type(OverworldState.talkTo) == "function") then
    return false
  end
  if OverworldState._wildsAiTalkWrap == OverworldState.talkTo then
    self._talkWrapped = true
    return true
  end
  local manager = self
  local orig = OverworldState.talkTo
  local function wrap(selfOw, npc, done, ...)
    if npc and npc.wildsAmbientPokemon then
      return orig(selfOw, npc, done, ...)
    end
    if npc and (npc._wildsFollower or npc.isFollower) then
      return orig(selfOw, npc, done, ...)
    end
    local game = (selfOw and selfOw.game)
      or (manager.mod.world and manager.mod.world.game)
      or manager.mod.game
    local function queueOffer()
      if AiConfig.enabled(manager.mod) then
        manager._pendingOffer = { game = game, ow = selfOw, npc = npc }
      end
    end
    if type(done) == "function" then
      return orig(selfOw, npc, function(...)
        done(...)
        queueOffer()
      end, ...)
    end
    local r = orig(selfOw, npc, done, ...)
    queueOffer()
    return r
  end

  OverworldState.talkTo = wrap
  OverworldState._wildsAiTalkWrap = wrap
  self._origTalkTo = orig
  self._talkWrapped = true
  AiLog.info(self.mod, "talkTo wrap installed")
  return true
end

function Dialogue:processPendingOffer()
  local pending = self._pendingOffer
  if not pending then return end
  -- Wait until overworld owns the stack again (vanilla TextBox finished).
  local game, ow, npc = pending.game, pending.ow, pending.npc
  if GameCompat.followerInteractionBusy(game, ow, npc) then
    return
  end
  self._pendingOffer = nil
  pcall(function()
    self:afterVanilla(game, ow, npc)
  end)
end

function Dialogue:uninstall()
  local OverworldState = tryRequire("src.world.OverworldController")
  if OverworldState and self._origTalkTo
     and OverworldState.talkTo == OverworldState._wildsAiTalkWrap then
    OverworldState.talkTo = self._origTalkTo
    OverworldState._wildsAiTalkWrap = nil
  end
  self._talkWrapped = false
  if self._active and self._active.provider then
    pcall(function()
      self._active.provider.cancel(self.mod, self._active.handle)
    end)
  end
  self._active = nil
  self._pendingOffer = nil
end

return Dialogue
