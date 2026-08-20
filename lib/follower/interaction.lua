-- Follower talk interaction (PokéPC behaviour; no sprite resolution).
local V = ...

local Interaction = {}
Interaction.__index = Interaction

local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }

-- Last Ball/Ok talk phases (diagnostic). Not per-frame.
local talkPhases = {}

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function gameVersion(game)
  local GameCompat = V.require("game_compat")
  return GameCompat.gameVersion(game)
end

function Interaction.talkPhases()
  return talkPhases
end

function Interaction.resetTalkPhases()
  talkPhases = {}
end

local function talkPhase(mod, phase, extra)
  talkPhases[#talkPhases + 1] = phase
  extra = extra or {}
  local parts = { "phase=" .. tostring(phase) }
  for _, key in ipairs({
    "generation", "npc", "stackTop", "overworldTop", "entities", "npcs",
    "trailers", "busy", "deferred", "fingerprint",
  }) do
    if extra[key] ~= nil then
      parts[#parts + 1] = key .. "=" .. tostring(extra[key])
    end
  end
  local line = "[Wilds][FollowerTalk] " .. table.concat(parts, " ")
  -- Always emit these sparse talk phases so a real Gen1 crash log names
  -- the last phase reached. They fire a handful of times per Ok/Ball, never
  -- per frame.
  if mod and mod.log and type(mod.log.info) == "function" then
    pcall(mod.log.info, mod.log, "%s", line)
  end
end

function Interaction.new(mod, selection, control)
  local self = setmetatable({}, Interaction)
  self.mod = mod
  self.selection = selection
  self.control = control
  self._originalTalk = nil
  self._wrapper = nil
  self._installed = false
  return self
end

function Interaction:setControl(control)
  self.control = control
end

local function finishMovement(npc)
  if not npc then return end
  if npc.moving then
    npc.cellX = npc.targetX or npc.cellX
    npc.cellY = npc.targetY or npc.cellY
    npc.targetX, npc.targetY = nil, nil
    local cell = 16
    if npc.px and npc.cellX then npc.px = npc.cellX * cell end
    if npc.py and npc.cellY then npc.py = npc.cellY * cell end
    npc.moving, npc.marching = false, false
    npc.progress, npc.hopStep = 0, nil
  end
  npc.idle, npc.goalX, npc.goalY = nil, nil, nil
end

local function monDisplayName(game, mon)
  if not mon then return "It" end
  if type(mon.nickname) == "string" and mon.nickname ~= "" then
    return mon.nickname
  end
  local def = game and game.data and game.data.pokemon and game.data.pokemon[mon.species]
  if def and def.name then return def.name end
  local AmbientCries = V.require("ambient_cries")
  if AmbientCries and AmbientCries.displayName then
    return AmbientCries.displayName(mon.species)
  end
  return tostring(mon.species or "It")
end

local function setChoiceCallbackFlag(interaction, on)
  interaction._inChoiceCallback = on == true
  local control = interaction.control
  if control then
    control._inChoiceCallback = on == true
  end
end

local function stackTop(game)
  local stack = game and game.stack
  if not (stack and type(stack.top) == "function") then return nil end
  local ok, top = pcall(stack.top, stack)
  if ok then return top end
  return nil
end

--- Shared follower dialog + Ok / Ball choice.
-- Ok → close, no change.
-- Ball → manual recall of THAT mon (stopFollowing + count - 1 + recall FX).
-- Gen1 only marks a pending recall request here. World mutation runs on the
-- next Overworld-owned ControlEngine:update (same owner as Poké Center heal).
-- Gold keeps the immediate recall path that already works.
--
-- Gen1 PikachuFollower.talk is (game, ow, npc, done). Interact never passes
-- done. TextBox.choice already completes the UI, so Gen1 must not invent or
-- invoke a `done` callback from this dialog.
function Interaction:showFollowMessage(game, ow, npc, mon, done)
  if not mon then return false end

  finishMovement(npc)
  if npc and npc.facePlayer and ow and ow.player then
    pcall(npc.facePlayer, npc, ow.player)
  end
  if ow and ow.player and npc and npc.facing then
    ow.player.facing = OPPOSITE[npc.facing] or ow.player.facing
  end

  local Sound = tryRequire("src.core.Sound")
  if Sound and Sound.playCry and game and game.data then
    pcall(Sound.playCry, game.data, mon.species)
  end

  local Strings = tryRequire("src.core.Strings")
  local name = monDisplayName(game, mon)
  local text
  if Strings then
    local ok, formatted = pcall(Strings, "%s is following\nyou!", name)
    text = ok and formatted or (tostring(name) .. " is following\nyou!")
  else
    text = tostring(name) .. " is following\nyou!"
  end

  local GameCompat = V.require("game_compat")
  local interaction = self
  local allowBall = self.control ~= nil
    and type(self.control.manualRecallFollower) == "function"
  -- Yellow stock Pikachu entity is engine-owned: never offer manual recall.
  if npc and npc.pikachuFollower == true and npc.pokepcTrailer ~= true then
    allowBall = false
  end

  local gen = GameCompat.generation(self.mod, game)
  local gen1 = GameCompat.isGen1(self.mod, game) == true

  if not allowBall then
    GameCompat.presentText(self.mod, game, ow, text, done)
    return true
  end

  talkPhase(self.mod, "choice_open", { generation = gen })

  GameCompat.presentTextChoice(self.mod, game, ow, text, function(okay)
    setChoiceCallbackFlag(interaction, true)
    talkPhase(interaction.mod, "CHOICE_CALLBACK_ENTER", {
      generation = gen,
      stackTop = stackTop(game) == ow and "overworld" or tostring(stackTop(game)),
      overworldTop = GameCompat.overworldOwnsStack(game, ow),
    })
    if okay then
      -- Ok: TextBox.choice already popped ChoiceBox+TextBox. Gen1 talk has
      -- no external completion callback on the interact path.
      if not gen1 and done then
        talkPhase(interaction.mod, "BEFORE_DONE", { generation = gen })
        talkPhase(interaction.mod, "DONE_ENTER", { generation = gen })
        done()
        talkPhase(interaction.mod, "DONE_EXIT", { generation = gen })
      end
      talkPhase(interaction.mod, "CHOICE_CALLBACK_EXIT", { generation = gen })
      setChoiceCallbackFlag(interaction, false)
      return
    end

    local control = interaction.control
    local defer = GameCompat.shouldDeferFollowerRecall(game, ow, npc) == true
    if control then
      if defer and type(control.queueManualRecallFollower) == "function" then
        talkPhase(interaction.mod, "QUEUE_RECALL", { generation = gen })
        -- Queue by mon identity only. Do not capture ow/npc pointers:
        -- Gen1 may rebuild trailers between this callback and the next
        -- Overworld tick.
        control:queueManualRecallFollower(game, nil, mon, {
          source = "talk_pokeball",
        })
      elseif type(control.manualRecallFollower) == "function" then
        -- Gold: keep the working immediate path, including the talked-to npc.
        control:manualRecallFollower(game, ow, mon, {
          source = "talk_pokeball",
          npc = npc,
        })
      end
    end
    -- Gen1: do not call done(). TextBox.choice already finished the UI, and
    -- vanilla PikachuFollower.talk is never given a done from interact().
    if not gen1 and done then
      talkPhase(interaction.mod, "BEFORE_DONE", { generation = gen })
      talkPhase(interaction.mod, "DONE_ENTER", { generation = gen })
      done()
      talkPhase(interaction.mod, "DONE_EXIT", { generation = gen })
    end
    talkPhase(interaction.mod, "CHOICE_CALLBACK_EXIT", { generation = gen })
    setChoiceCallbackFlag(interaction, false)
  end, {
    labels = { "Ok", "Ball" },
  })
  return true
end

--- Exact Gen1 contract: PikachuFollower.talk(game, ow, npc, done).
-- Interact calls this with three arguments; `done` is Pewter-sleep only.
function Interaction:makeGen1TalkWrapper(originalTalk)
  local selection = self.selection
  local interaction = self
  return function(game, ow, npc, done)
    local GameCompat = V.require("game_compat")
    game = game or tryRequire("src.core.Game")
    ow = ow or GameCompat.liveOverworld(interaction.mod, game)
    -- Use the talked-to NPC from the engine call. Do not substitute
    -- PikachuFollower.current (stock Yellow companion).
    local mon = npc and npc.pokepcMon
    if not mon and selection and selection.getActiveFollowerMon then
      mon = selection:getActiveFollowerMon(game, true)
    end
    if not mon then
      if originalTalk then return originalTalk(game, ow, npc, done) end
      return
    end
    local ver = gameVersion(game)
    if ver == "yellow" and mon.species == "PIKACHU" and originalTalk then
      return originalTalk(game, ow, npc, done)
    end
    -- TextBox.choice owns UI completion. Do not forward vanilla `done`.
    return interaction:showFollowMessage(game, ow, npc, mon, nil)
  end
end

--- Gold Follower.talk(game, world, npc, done). Production talk uses talkTo wrap
-- → showFollowMessage directly; this wrapper is lifecycle fallback only.
function Interaction:makeGoldTalkWrapper(originalTalk)
  local selection = self.selection
  local interaction = self
  return function(game, world, npc, done)
    local GameCompat = V.require("game_compat")
    game = game or tryRequire("src.core.Game")
    world = world or GameCompat.liveOverworld(interaction.mod, game)
    local mon = npc and npc.pokepcMon
    if not mon and selection and selection.getActiveFollowerMon then
      mon = selection:getActiveFollowerMon(game, true)
    end
    if not mon then
      if originalTalk then return originalTalk(game, world, npc, done) end
      if done then done() end
      return
    end
    return interaction:showFollowMessage(game, world, npc, mon, done)
  end
end

function Interaction:makeTalkWrapper(originalTalk)
  local gen1 = self:makeGen1TalkWrapper(originalTalk)
  local gold = self:makeGoldTalkWrapper(originalTalk)
  local interaction = self
  return function(game, ow, npc, done)
    local GameCompat = V.require("game_compat")
    if GameCompat.isGen2(interaction.mod, game) then
      return gold(game, ow, npc, done)
    end
    return gen1(game, ow, npc, done)
  end
end

return Interaction
