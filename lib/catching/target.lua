-- Forward-facing wild target resolution (1–6 tiles, no auto-aim cone).
local V = ...
local Config = V.require("config")
local CatchMath = V.require("catching/catch_math")

local Target = {}

local DIR = {
  up = { 0, -1 },
  down = { 0, 1 },
  left = { -1, 0 },
  right = { 1, 0 },
}

local function facingOf(player)
  local f = player and (player.facing or player.dir or player.direction)
  if type(f) == "string" then
    f = f:lower()
    if DIR[f] then return f end
  end
  return "down"
end

--- True only for real battleable overworld Wilds entities (visible).
function Target.isCatchableWild(entity)
  if not entity then return false end
  if entity.wildsCatchLocked == true then return false end
  if entity.wildsCatchPending == true then return false end
  if entity.wildsCatchState == "capturing" or entity.wildsCatchState == "pending" then
    return false
  end
  if entity.isPokeBallEntity or entity.wildsProjectile then return false end
  if entity.wildsAmbientPokemon == true then return false end
  if entity.caveScenery == true then return false end
  if entity.wildsFollower == true or entity.pokepcTrailer == true then return false end
  if entity.isFollower == true or entity.follower == true then return false end
  -- Pure FX overlays are never catchable. A real wild with a temporary !
  -- emote (alertIcon) MUST stay catchable — including AGGRESSIVE retries.
  if entity.fxOnly or entity.overworldWildOverlay then return false end
  if entity.alertIcon == true and entity.overworldWildSpawn ~= true then
    return false
  end
  -- Visible only: hidden grass/cave markers are battleable on contact but not throw targets.
  if entity.hiddenEncounter == true then return false end
  if entity.visibleSprite == false then return false end
  if entity.canTriggerBattle == false and entity.overworldWildSpawn == true then
    -- Spawn FX not ready yet, or scenery-like lock.
    if entity.caveScenery then return false end
  end
  if Config.isBattleableWild and not Config.isBattleableWild(entity) then
    return false
  end
  if entity.overworldWildSpawn ~= true then return false end
  local st = entity.state
  if st == "REMOVED" or st == Config.STATE.REMOVED then return false end
  -- Block only once a real battle transition has begun — not mere AGGRESSIVE.
  if st == Config.STATE.ENCOUNTER_STARTING or st == Config.STATE.IN_BATTLE then
    return false
  end
  local bx = entity.behaviorState
  if bx and (bx.battleStarted == true or bx.battlePending == true
             or bx.state == "BATTLE_PENDING") then
    return false
  end
  return true
end

local function entityAtCell(logic, ow, x, y)
  if logic and logic.entities then
    for _, entity in pairs(logic.entities) do
      if entity and entity.cellX == x and entity.cellY == y
         and Target.isCatchableWild(entity) then
        return entity
      end
    end
  end
  -- Fallback scan of ow lists (should rarely be needed).
  if ow then
    for _, listName in ipairs({ "entities", "npcs" }) do
      local list = ow[listName]
      if list then
        for _, entity in ipairs(list) do
          if entity and entity.cellX == x and entity.cellY == y
             and Target.isCatchableWild(entity) then
            return entity
          end
        end
      end
    end
  end
  return nil
end

--- Search cells 1..maxRange directly ahead. First valid wild wins.
-- Returns entity, distance, tileX, tileY or nil.
function Target.findAhead(logic, ow, player, maxRange)
  maxRange = maxRange or CatchMath.MAX_RANGE
  if not player then return nil end
  local px, py = player.cellX, player.cellY
  if px == nil or py == nil then return nil end
  local facing = facingOf(player)
  local d = DIR[facing]
  if not d then return nil end

  for step = 1, maxRange do
    local tx = px + d[1] * step
    local ty = py + d[2] * step
    local entity = entityAtCell(logic, ow, tx, ty)
    if entity then
      return entity, step, tx, ty, facing
    end
  end
  return nil
end

Target.facingOf = facingOf
Target.DIR = DIR

return Target
