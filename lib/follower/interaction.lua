-- Follower talk interaction (PokéPC behaviour; no sprite resolution).
local V = ...

local Interaction = {}
Interaction.__index = Interaction

local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function gameVersion(game)
  local GameCompat = V.require("game_compat")
  return GameCompat.gameVersion(game)
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

--- Shared follower dialog + OKAY / POKEBALL choice.
-- OKAY → close, no change.
-- POKEBALL → manual recall of THAT mon (stopFollowing + count - 1 + recall FX).
-- @param game src.core.Game (module or instance)
-- @param ow overworld state
-- @param npc follower/trailer entity being talked to (may be nil)
-- @param mon the party mon to present (trailer's own mon preferred)
-- @param done optional callback (vanilla talk signature compatibility)
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

  if not allowBall then
    GameCompat.presentText(self.mod, game, ow, text, done)
    return true
  end

  GameCompat.presentTextChoice(self.mod, game, ow, text, function(okay)
    if okay then
      if done then done() end
      return
    end
    -- POKEBALL: remove this specific follower from active selection.
    local control = interaction.control
    if control and type(control.manualRecallFollower) == "function" then
      pcall(control.manualRecallFollower, control, game, ow, mon, {
        source = "talk_pokeball",
      })
    end
    if done then done() end
  end, {
    labels = { "OKAY", "POKEBALL" },
  })
  return true
end

function Interaction:makeTalkWrapper(originalTalk)
  local selection = self.selection
  local interaction = self
  local function wrappedTalk(a, b, c, d)
    local Game = tryRequire("src.core.Game")
    local game = type(a) == "table" and a.save and a or Game
    local GameCompat = V.require("game_compat")
    local ow = type(b) == "table" and (b.entities or b.npcs or b.player) and b
      or GameCompat.liveOverworld(interaction.mod, game)
    local done = type(c) == "function" and c or d

    local PikachuFollower = tryRequire("src.world.PikachuFollower")
    local npc = PikachuFollower and PikachuFollower.current and PikachuFollower.current(ow)
    local mon = selection:getActiveFollowerMon(game, true)
    -- Talking to a specific trailer: present THAT mon, not the active leader.
    if npc and npc.pokepcMon then
      mon = npc.pokepcMon
    end

    if not mon then
      if originalTalk then return originalTalk(a, b, c, d) end
      if done then done() end
      return
    end

    -- Yellow Pikachu keeps vanilla talk (PokéPC behaviour).
    local ver = gameVersion(game)
    if ver == "yellow" and mon.species == "PIKACHU" and originalTalk then
      return originalTalk(a, b, c, d)
    end

    return interaction:showFollowMessage(game, ow, npc, mon, done)
  end
  return wrappedTalk
end

return Interaction
