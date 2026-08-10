-- Forward-facing wild target resolution + throw-path collision scan.
-- Normal catching still only resolves battleable Wilds; Town/NPC hits are
-- secondary easter-egg collisions along the physical travel line.
local V = ...
local Config = V.require("config")
local CatchMath = V.require("catching/catch_math")

local Target = {}

Target.HitKind = {
  NONE = "NONE",
  WILD = "WILD",
  TOWN_MON = "TOWN_MON",
  NPC = "NPC",
}

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

local function forEachAtCell(logic, ow, x, y, fn)
  if logic and logic.entities then
    for _, entity in pairs(logic.entities) do
      if entity and entity.cellX == x and entity.cellY == y then
        fn(entity)
      end
    end
  end
  if ow then
    for _, listName in ipairs({ "entities", "npcs" }) do
      local list = ow[listName]
      if list then
        for _, entity in ipairs(list) do
          if entity and entity.cellX == x and entity.cellY == y then
            fn(entity)
          end
        end
      end
    end
  end
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

--- Town / Ambient Pokémon (peaceful, never catchable).
function Target.isTownPokemon(entity)
  if not entity then return false end
  if entity.wildsAmbientPokemon ~= true then return false end
  if entity.isPokeBallEntity or entity.wildsProjectile then return false end
  if entity.wildsFollower or entity.pokepcTrailer or entity.pikachuFollower then
    return false
  end
  if entity.isFollower or entity.follower then return false end
  if entity.fxOnly or entity.overworldWildOverlay then return false end
  if entity.hiddenEncounter == true then return false end
  if entity.visibleSprite == false then return false end
  if entity.overworldWildSpawn == true then return false end
  return true
end

local function looksLikeExcludedNonHuman(entity)
  if entity.overworldWildSpawn then return true end
  if entity.wildsAmbientPokemon then return true end
  if entity.species or entity.wildSpecies or entity.ambientSpecies then return true end
  if entity.wildsFollower or entity.pokepcTrailer or entity.pikachuFollower then
    return true
  end
  if entity.isFollower or entity.follower then return true end
  if entity.isPokeBallEntity or entity.wildsProjectile or entity.wildsCatchProjectile then
    return true
  end
  if entity.fxOnly or entity.overworldWildOverlay or entity.alertIcon then return true end
  if entity.hiddenEncounter or entity.caveScenery then return true end
  if entity.name and tostring(entity.name):find("WILDS_BALL", 1, true) then
    return true
  end
  return false
end

-- Gen1Recomp NPC.new stores the map object_event on entity.def (index,
-- trainerClass, item, pokemon, sprite, text, …). Top-level entity.index is
-- NOT set on native instances — that was the human easter-egg miss.
local function mapObjectDef(entity)
  local def = entity and entity.def
  return type(def) == "table" and def or nil
end

local function mapObjectIndex(entity, def)
  if type(entity.index) == "number" then return entity.index end
  if def and type(def.index) == "number" then return def.index end
  return nil
end

-- Non-character map objects still use the NPC class / ow.npcs list.
local function isNonCharacterMapObject(def)
  if not def then return false end
  -- Item balls (ITEM_NONE "0" is a plain text prop, not a person either).
  if def.item ~= nil then return true end
  -- Static map Pokémon (birds, Mewtwo, Vermilion Machop, …).
  if def.pokemon ~= nil then return true end
  if def.pushable == true then return true end
  local spriteId = def.sprite
  if spriteId == "SPRITE_BOULDER" or spriteId == "SPRITE_BALL" then
    return true
  end
  return false
end

local function hasTrainerSignal(entity, def)
  if entity.trainer == true or entity.isTrainer == true then return true end
  if entity.trainerClass or entity.trainerId or entity.trainerData then return true end
  if type(entity.trainer) == "table" then return true end
  if not def then return false end
  if def.trainer == true or type(def.trainer) == "table" then return true end
  if def.trainerClass or def.trainerId or def.trainerData then return true end
  return false
end

--- Human map NPC / trainer. Prefer canonical Gen1Recomp NPC.def identity.
-- If uncertain → false (never invent humans from arbitrary entities).
function Target.isHumanNpc(entity)
  if not entity then return false end
  if looksLikeExcludedNonHuman(entity) then return false end

  local def = mapObjectDef(entity)
  if isNonCharacterMapObject(def) then return false end

  -- Explicit trainer markers (entity-level or object_event def).
  if hasTrainerSignal(entity, def) then return true end

  local index = mapObjectIndex(entity, def)
  -- Native map person: NPC instance with object_event def + cells + sprite.
  -- facing is set by NPC.new but must not be required (STAY/NONE ranges).
  if def ~= nil
     and type(index) == "number"
     and entity.sprite ~= nil
     and entity.cellX ~= nil
     and entity.cellY ~= nil
     and entity.species == nil
     and entity.wildSpecies == nil
     and entity.ambientSpecies == nil then
    return true
  end

  -- Legacy / test fixtures that put index on the entity (no .def).
  if def == nil
     and type(entity.index) == "number"
     and entity.sprite ~= nil
     and entity.facing ~= nil
     and entity.cellX ~= nil
     and entity.cellY ~= nil
     and entity.species == nil
     and entity.wildSpecies == nil
     and entity.ambientSpecies == nil then
    return true
  end

  return false
end

local function entityAtCell(logic, ow, x, y)
  local found = nil
  forEachAtCell(logic, ow, x, y, function(entity)
    if not found and Target.isCatchableWild(entity) then
      found = entity
    end
  end)
  return found
end

local function townAtCell(logic, ow, x, y)
  local found = nil
  forEachAtCell(logic, ow, x, y, function(entity)
    if not found and Target.isTownPokemon(entity) then
      found = entity
    end
  end)
  return found
end

local function humanAtCell(logic, ow, x, y)
  local found = nil
  forEachAtCell(logic, ow, x, y, function(entity)
    if not found and Target.isHumanNpc(entity) then
      found = entity
    end
  end)
  return found
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

--- Physical travel collision along facing for `power` tiles (order matters).
-- Priority per cell: WILD → TOWN_MON → NPC → continue.
-- Returns { kind, entity?, distance, x, y, facing }.
function Target.scanThrowPath(logic, ow, player, power)
  local Hit = Target.HitKind
  if not player then
    return { kind = Hit.NONE, distance = 1, x = 0, y = 0, facing = "down" }
  end
  local px, py = player.cellX, player.cellY
  local facing = facingOf(player)
  local d = DIR[facing]
  local tiles = CatchMath.roundedPower(power)
  if px == nil or py == nil or not d then
    return { kind = Hit.NONE, distance = tiles, x = px or 0, y = py or 0, facing = facing }
  end

  for step = 1, tiles do
    local tx = px + d[1] * step
    local ty = py + d[2] * step
    local wild = entityAtCell(logic, ow, tx, ty)
    if wild then
      return {
        kind = Hit.WILD, entity = wild, distance = step,
        x = tx, y = ty, facing = facing,
      }
    end
    local town = townAtCell(logic, ow, tx, ty)
    if town then
      return {
        kind = Hit.TOWN_MON, entity = town, distance = step,
        x = tx, y = ty, facing = facing,
      }
    end
    local human = humanAtCell(logic, ow, tx, ty)
    if human then
      return {
        kind = Hit.NPC, entity = human, distance = step,
        x = tx, y = ty, facing = facing,
      }
    end
  end

  local landX = px + d[1] * tiles
  local landY = py + d[2] * tiles
  return {
    kind = Hit.NONE, distance = tiles, x = landX, y = landY, facing = facing,
  }
end

Target.facingOf = facingOf
Target.DIR = DIR

return Target
