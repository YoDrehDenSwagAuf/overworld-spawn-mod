-- Gen 2 / Pokémon Gold adapter for Wilds game compatibility.
--
-- Gold adapter: species, party, surf, map, water, plus wild encounters.
-- Encounter tables live in lib/gen2/encounters.lua (not this file).
-- Followers / catching / safari stay off. Town Pokémon: curated Johto catalog.
--
-- Engine pointers (verified against current Gen1Recomp Gold):
--   party:        game.save.party (src/core/gen2/Save.lua)
--   world:        game.world (src/world/gen2/World.lua), not Gen1 overworld
--   map id:       world.map.id (e.g. ROUTE_29)
--   isSurfing:    src.world.gen2.FieldMoves.isSurfing(playerState)
--                 PLAYER_SURF = "surf", PLAYER_SURF_PIKA = "surf_pika"
--   isWaterCell:  src.world.gen2.Map:isWaterCell → Permissions.isWater
--   speciesId:    data.pokemon[id].dex or .index (World.monIndex uses index)
--
-- Wild encounters: lib/gen2/encounters.lua over data.gen2Encounters.
-- Town Pokémon: lib/gen2/town_pokemon.lua (curated Johto towns).
local V = ...

local Gen2 = {}
Gen2.supported = true
Gen2.generation = 2
-- National Dex span Gold actually uses. Shared generated geometry may
-- include 1..251; Gen1 consumers stay capped at Gen1.MAX_SPECIES.
Gen2.MAX_SPECIES = 251

Gen2.capabilities = {
  core = true,
  species = true,
  party = true,
  surf = true,
  encounters = true,
  followers = false,
  catching = false,
  ambient = true,
  townPokemon = true,
  safari = false,
}

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function goldWorld(game, ow)
  if game and game.world and (game.world.map or game.world.playerState ~= nil) then
    return game.world
  end
  if ow and (ow.playerState ~= nil or ow.map) then
    return ow
  end
  if game and game.overworld then
    return game.overworld
  end
  return ow
end

local function pokemonDef(species, game, mod)
  if type(species) ~= "string" or species == "" then return nil end
  if game and game.data and type(game.data.pokemon) == "table" then
    local def = game.data.pokemon[species]
    if def then return def end
  end
  if mod and mod.content and mod.content.pokemon and mod.content.pokemon.get then
    local ok, def = pcall(mod.content.pokemon.get, mod.content.pokemon, species)
    if ok and def then return def end
  end
  return nil
end

--- Resolve a species key to a numeric National Dex / Gold index.
-- 1. numeric id → return as-is if a positive integer
-- 2. engine pokemon record dex (schema requires dex) or index (World.monIndex)
-- 3. AnimatedSprites.resolveSpeciesId (reads dex on the record)
-- No hand-maintained 251-name table.
function Gen2.speciesId(species, game, mod)
  if species == nil then return nil end
  local n = tonumber(species)
  if n and n >= 1 and math.floor(n) == n then
    return math.floor(n)
  end
  if type(species) ~= "string" and type(species) ~= "number" then
    return nil
  end

  local def = pokemonDef(species, game, mod or V.mod)
  if def then
    local dex = tonumber(def.dex) or tonumber(def.index)
    if dex and dex >= 1 then return math.floor(dex) end
  end

  local okAS, AnimatedSprites = pcall(function() return V.require("animated_sprites") end)
  if okAS and AnimatedSprites and AnimatedSprites.resolveSpeciesId then
    local ok, dex = pcall(AnimatedSprites.resolveSpeciesId, species, game, mod or V.mod)
    if ok and type(dex) == "number" and dex >= 1 then
      return math.floor(dex)
    end
  end
  return nil
end

--- Gold surf: FieldMoves.isSurfing(world.playerState / save.playerState).
-- Does not use Gen1 player.surfing.
function Gen2.isSurfing(game, ow)
  local world = goldWorld(game, ow)
  local state = (world and world.playerState)
    or (game and game.save and game.save.playerState)

  local FieldMoves = tryRequire("src.world.gen2.FieldMoves")
  if FieldMoves and type(FieldMoves.isSurfing) == "function" then
    local ok, surfing = pcall(FieldMoves.isSurfing, state)
    if ok then return surfing == true end
  end
  -- Engine string values when FieldMoves is not on package.path (unit tests).
  return state == "surf" or state == "surf_pika"
end

function Gen2.isWaterCell(map, x, y)
  if map and type(map.isWaterCell) == "function" then
    local ok, water = pcall(map.isWaterCell, map, x, y)
    if ok then return water == true end
  end
  if map and type(map.cellCollision) == "function" then
    local Permissions = tryRequire("src.world.gen2.Permissions")
    if Permissions and type(Permissions.isWater) == "function" then
      local ok, coll = pcall(map.cellCollision, map, x, y)
      if ok then
        local okWater, water = pcall(Permissions.isWater, coll)
        if okWater then return water == true end
      end
    end
  end
  return false
end

function Gen2.party(game)
  if not (game and game.save and type(game.save.party) == "table") then
    return nil
  end
  return game.save.party
end

function Gen2.currentMapId(game, ow)
  local world = goldWorld(game, ow)
  if world and world.map and world.map.id ~= nil then
    return world.map.id
  end
  if ow and ow.map and ow.map.id ~= nil then
    return ow.map.id
  end
  return nil
end

function Gen2.encountersForMap(game, mapId, ctx)
  local Enc = V.require("gen2/encounters")
  return Enc.forMap(game, mapId, ctx)
end

function Gen2.pickEncounter(game, mapId, kind, ctx)
  local Enc = V.require("gen2/encounters")
  return Enc.pick(game, mapId, kind, ctx)
end

--- Gold wild battle: WorldAPI.queueScript start_battle wild species level.
-- WorldAPI builds src.battle.gen2.Mon and World:startBattle({ wild = mon }).
function Gen2.startWildBattle(world, species, level)
  if not (world and type(world.queueScript) == "function") then
    return nil, "no world"
  end
  return world:queueScript({
    { "start_battle", "wild", species, tonumber(level) or 5 },
  })
end

return Gen2
