-- Gen 2 / Pokémon Gold adapter for Wilds game compatibility.
--
-- Gold adapter: species, party, surf, map, water, wild encounters, followers,
-- and overworld catching. Encounter tables live in lib/gen2/encounters.lua.
-- Catching supported. Safari / special-session compatibility remains separate.
-- Town Pokémon: curated Johto catalog.
--
-- Engine pointers (verified against current Gen1Recomp Gold):
--   party:        game.save.party (src/core/gen2/Save.lua)
--   inventory:    save.inventory id→count (Bag.remove; PackMenu pockets)
--   mon:          src.battle.gen2.Mon.new + stampOT
--   boxes:        src.core.gen2.Boxes.box; SendMonIntoBox inserts at head
--   dex:          save.pokedex.caught / .seen keyed by species id
--   catch:        src.battle.gen2.Catching.attempt
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
  followers = true,
  catching = true,
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

-- STANDING_DOWN (src/world/gen2/Npc.lua MOVE table). STILL=1 carries
-- FIXED_FACING and cannot turn. Same constant Follower.lua uses.
local GOLD_STANDING_DOWN = 6

--- Native Gold NPC module.
-- Prefer `src.world.gen2.Npc` (the path `src/world/gen2/Follower.lua` uses)
-- so construction does not depend on Loader's Gen2Compat alias.
--
-- `pcall(require, "src.world.NPC")` can miss that alias: Loader's shim
-- uses callerIsMod(3), a C `pcall` frame makes the call look like engine
-- code, and Gold then loads Gen1 `src/world/NPC.lua` (no MOVE, draw is
-- `draw(camX, camY)` — invisible under Gold `draw(ox, oy, scale)`).
-- An extra Lua frame makes callerIsMod(3) see this mod chunk.
local function loadGoldNpc(name)
  local ok, Npc = pcall(function()
    return require(name)
  end)
  if ok and type(Npc) == "table" and type(Npc.new) == "function" then
    return Npc, name
  end
  return nil, nil
end

function Gen2.npcModule()
  local Npc, name = loadGoldNpc("src.world.gen2.Npc")
  if Npc then return Npc, name end
  return loadGoldNpc("src.world.NPC")
end

--- Gold trailer NPC: native Npc.new(mapId, objDef, spriteDef).
-- Same contract as src/world/gen2/Follower.lua makeFollower.
-- Never sniffs NPC.MOVE to choose Gen1 arity. Never calls
-- NPC.new(data, mapId, objDef) — that is Gen1.makeGuestNpc only.
function Gen2.makeGuestNpc(game, ow, spec)
  spec = spec or {}
  local NPC, npcSource = Gen2.npcModule()
  if not (NPC and NPC.new) then
    return nil, "no Gold NPC (src.world.gen2.Npc)"
  end
  if not (ow and ow.map and ow.map.id) then return nil, "no map" end
  local spriteDef = spec.spriteDef
  if type(spriteDef) ~= "table" or not spriteDef.image then
    return nil, "Gold trailer requires spriteDef.image"
  end
  local mapId = ow.map.id
  local MOVE = type(NPC.MOVE) == "table" and NPC.MOVE or {}
  local movement = MOVE.STANDING_DOWN or GOLD_STANDING_DOWN
  local objDef = {
    index = spec.index,
    name = spec.name,
    sprite = spec.spriteId,
    movement = movement,
    x = spec.x, y = spec.y,
  }
  local ok, npc = pcall(NPC.new, mapId, objDef, spriteDef)
  if not ok then
    return nil, tostring(npc)
  end
  if not npc then
    return nil, "NPC.new returned nil (" .. tostring(npcSource) .. ")"
  end
  npc.spriteDef = npc.spriteDef or spriteDef
  npc.mapId = npc.mapId or mapId
  npc.passable = true
  npc._wildsGoldGuest = true
  if spec.facing then npc.facing = spec.facing end
  npc._wildsGoldNpcSource = npcSource
  npc._wildsGoldMovement = movement
  return npc
end

local function resolveCatchBallSpriteDef(game, spec)
  spec = spec or {}
  if type(spec.spriteDef) == "table" and spec.spriteDef.image then
    return spec.spriteDef
  end
  local spriteId = spec.spriteId
  local data = game and game.data
  if spriteId and data and type(data.sprites) == "table" then
    local def = data.sprites[spriteId]
    if type(def) == "table" and def.image then return def end
  end
  local mod = V.mod
  local sprites = mod and mod.content and mod.content.sprites
  if spriteId and sprites and type(sprites.get) == "function" then
    local def = sprites:get(spriteId)
    if type(def) == "table" and def.image then return def end
  end
  if spec.image then
    return {
      id = spriteId,
      image = spec.image,
      frames = 1,
      walker = false,
      trueColor = true,
    }
  end
  return nil
end

--- Thrown Ball: native Gold NPC only. Never src.world.NPC Gen1 arity.
-- Reuses Gen2.makeGuestNpc (src.world.gen2.Npc + STANDING_DOWN).
function Gen2.makeCatchProjectile(game, ow, spec)
  spec = spec or {}
  local spriteDef = resolveCatchBallSpriteDef(game, spec)
  if type(spriteDef) ~= "table" or not spriteDef.image then
    return nil, "Gold ball requires spriteDef.image"
  end
  local ballType = spec.ballType or "POKE_BALL"
  local npc, err = Gen2.makeGuestNpc(game, ow, {
    index = spec.index or (480 + math.random(1, 40)),
    name = spec.name or ("WILDS_BALL_" .. tostring(ballType)),
    spriteId = spec.spriteId or ("SPRITE_WILDS_BALL_" .. ballType),
    spriteDef = spriteDef,
    x = spec.x or spec.cellX or 0,
    y = spec.y or spec.cellY or 0,
    facing = spec.facing,
  })
  if not npc then
    return nil, err or "Gold makeGuestNpc failed"
  end
  -- STANDING_DOWN already kind=stand; frozen blocks wander if kind is wrong.
  npc.frozen = true
  npc.moving = false
  npc.passable = true
  npc.blocking = false
  npc._wildsCatchProjectile = true
  return npc
end

--- Gold CONTROL=POKEMON: Player:setSprite(spriteDef). Keeps the same
-- player object (cell, input, collision, scripts, warps, surf).
function Gen2.applyControlledPokemonSprite(player, def, _game)
  if not (player and def) then return false, "missing player or def" end
  if type(player.setSprite) == "function" then
    local ok, err = pcall(player.setSprite, player, def)
    if not ok then return false, err end
    player._pokepcAsPokemon = true
    return true, "setSprite"
  end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new) then
    return false, "no SpriteRenderer"
  end
  local ok, sprite = pcall(SpriteRenderer.new, def, "player")
  if not ok or not sprite then return false, tostring(sprite) end
  player.sprite = sprite
  player.spriteDef = def
  player._pokepcAsPokemon = true
  return true, "player.sprite"
end

--- Catching-only world: Gold's live object is game.world, not a stack state.
-- WorldAPI:overworld() returns the same World once world.map exists; catching
-- must not depend on that, because Wilds already attach to game.world.
function Gen2.catchWorld(mod, game)
  game = game or (mod and (mod.game or (mod.world and mod.world.game)))
  if game and game.world and (game.world.player or game.world.map) then
    return game.world
  end
  local api = mod and mod.world
  if api and type(api.overworld) == "function" then
    local ok, ow = pcall(api.overworld, api)
    if ok and ow and (ow.player or ow.map) then return ow end
  end
  return nil
end

--- Native Gold Player (src/world/gen2/Player.lua). Same object World owns.
function Gen2.catchPlayer(game, ow)
  if ow and ow.player then return ow.player end
  ow = goldWorld(game, ow)
  return ow and ow.player
end

function Gen2.playerCell(game, ow)
  local player = Gen2.catchPlayer(game, ow)
  if not player then return nil, nil end
  return player.cellX, player.cellY
end

--- Gold free-roam control. Uses real World fields only (no invented ones).
-- Empty stack IS free roam (game.world is never a stack state).
-- textbox is a latch (true / object / nil), not Gen1 TextBox:active().
function Gen2.catchPlayerHasControl(game, ow, logic)
  if not game then return false end
  ow = goldWorld(game, ow)
  if not ow then return false end
  if not Gen2.catchPlayer(game, ow) then return false end
  if logic and logic.pendingBattle then return false end
  if ow.battleActive then return false end
  if type(ow.busy) == "function" then
    local ok, busy = pcall(ow.busy, ow)
    if ok and busy then return false end
  end
  if type(ow.scriptRunning) == "function" then
    local ok, running = pcall(ow.scriptRunning, ow)
    if ok and running then return false end
  elseif ow.runner and type(ow.runner.isRunning) == "function" then
    local ok, running = pcall(ow.runner.isRunning, ow.runner)
    if ok and running then return false end
  end
  if ow.textbox or ow.choicebox then return false end
  if ow.engaging then return false end
  local stack = game.stack
  if stack and type(stack.top) == "function" then
    local top = stack:top()
    if top then return false end
  end
  return true
end

function Gen2.catchUiBlocked(game, ow, logic)
  if not game then return true end
  if logic and logic.pendingBattle then return true end
  ow = goldWorld(game, ow)
  if not ow then return true end
  if ow.battleActive then return true end
  if type(ow.busy) == "function" then
    local ok, busy = pcall(ow.busy, ow)
    if ok and busy then return true end
  end
  if type(ow.scriptRunning) == "function" then
    local ok, running = pcall(ow.scriptRunning, ow)
    if ok and running then return true end
  elseif ow.runner and type(ow.runner.isRunning) == "function" then
    local ok, running = pcall(ow.runner.isRunning, ow.runner)
    if ok and running then return true end
  end
  if ow.textbox or ow.choicebox then return true end
  local stack = game.stack
  if stack and type(stack.top) == "function" then
    local top = stack:top()
    if top then return true end
  end
  return false
end

--- Gold bag is still a flat id→count map (src/core/gen2/Save.lua).
-- PackMenu buckets by item pocket; counts are save.inventory[id].
function Gen2.ballCount(game, ballType)
  local inv = game and game.save and game.save.inventory
  if not inv or ballType == nil then return 0 end
  return tonumber(inv[ballType]) or 0
end

--- Consume exactly one ball via Gold Bag.remove (same inventory map).
function Gen2.consumeBall(game, ballType)
  local save = game and game.save
  if not save then return false end
  save.inventory = save.inventory or {}
  if Gen2.ballCount(game, ballType) <= 0 then return false end
  local Bag = tryRequire("src.inventory.Bag")
  if Bag and Bag.remove then
    Bag.remove(save, ballType, 1)
  else
    local n = (save.inventory[ballType] or 0) - 1
    if n <= 0 then save.inventory[ballType] = nil
    else save.inventory[ballType] = n end
  end
  return true
end

function Gen2.catchRate(game, species)
  local def = pokemonDef(species, game)
  if type(def) == "table" and def.catchRate ~= nil then
    return tonumber(def.catchRate) or 255, def
  end
  return 255, def
end

-- Gold Catching.attempt expects a 0-based random(n) → 0..n-1.
local function goldCatchRandom(rng, n)
  n = tonumber(n) or 256
  if type(rng) == "function" then
    local ok, a = pcall(rng, 0, n - 1)
    if ok and type(a) == "number" then return a end
    local ok2, b = pcall(rng, n)
    if ok2 and type(b) == "number" then
      if b >= 1 and b <= n then return b - 1 end
      return b
    end
  end
  if love and love.math and love.math.random then
    return love.math.random(n) - 1
  end
  return math.random(0, n - 1)
end

--- Gold catch roll: src.battle.gen2.Catching.attempt.
-- Wilds throw-quality stays in rateOverride (species rate). Ball + HP stay native.
-- Gen2 returns (caught, rate); shakes are presentation-only so the shared wobble runs.
function Gen2.attemptCatch(game, opts)
  opts = opts or {}
  local ballType = opts.ballType or "POKE_BALL"
  local mon = opts.mon or {}
  local def = opts.def
  local rng = opts.rng or (love and love.math and love.math.random) or math.random
  local rateOverride = opts.rateOverride
  local Catching = tryRequire("src.battle.gen2.Catching")
  if Catching and Catching.attempt then
    local maxHp = (mon.stats and mon.stats.hp) or mon.maxHp or mon.hp or 1
    local hp = mon.hp or maxHp
    local caught, rate = Catching.attempt({
      ball = ballType,
      mon = mon,
      def = def,
      catchRate = rateOverride or (def and def.catchRate) or 255,
      hp = hp,
      maxHp = maxHp,
      status = mon.status,
      species = mon.species or opts.species,
      data = game and game.data,
      random = function(n) return goldCatchRandom(rng, n) end,
    })
    if caught then return true, 3 end
    local shakes = 1
    if type(rate) == "number" and rate >= 85 then shakes = 2 end
    return false, shakes
  end
  if ballType == "MASTER_BALL" then
    return true, 3
  end
  local roll = rng(0, 255)
  local rate = rateOverride or (def and def.catchRate) or 255
  local caught = roll <= rate
  return caught, caught and 3 or 1
end

--- Native Gold mon: src.battle.gen2.Mon.new(data, species, level, opts) + stampOT.
-- species is the entity/runtime id, never a Wilds asset id.
-- Mon.new returns nil when data.pokemon[species] is missing. Do NOT invent a
-- fake party member — that corrupts Gold party/save data.
function Gen2.createCaughtPokemon(game, species, level, context)
  context = context or {}
  local Mon = tryRequire("src.battle.gen2.Mon")
  if not (Mon and Mon.new) then
    return nil, "no src.battle.gen2.Mon.new"
  end
  if not (game and game.data) then
    return nil, "no game.data"
  end
  if not (game.data.pokemon and game.data.pokemon[species]) then
    return nil, "missing_species_def"
  end
  local ok, mon = pcall(Mon.new, game.data, species, level, {
    shiny = context.shiny or nil,
  })
  if not ok then
    return nil, tostring(mon)
  end
  if not mon then
    return nil, "mon_new_returned_nil"
  end
  if Mon.stampOT and game.save then
    pcall(Mon.stampOT, game.save, mon)
  end
  if context.shiny then mon.shiny = true end
  if context.variant then mon.variant = context.variant end
  return mon
end

--- Native Gold store: party append, else SendMonIntoBox (insert at head of box).
function Gen2.giveCaughtPokemon(game, mon)
  if not (game and game.save and mon) then return { destination = nil } end
  local save = game.save
  save.party = save.party or {}
  if #save.party < 6 then
    save.party[#save.party + 1] = mon
    return { destination = "party" }
  end
  local Boxes = tryRequire("src.core.gen2.Boxes")
  if Boxes and Boxes.box then
    local start = tonumber(save.currentBox) or 1
    local num = Boxes.NUM_BOXES or 14
    for off = 0, num - 1 do
      local i = ((start - 1 + off) % num) + 1
      if not (Boxes.isFull and Boxes.isFull(save, i)) then
        local box = Boxes.box(save, i)
        -- SendMonIntoBox inserts at the head of the current box.
        table.insert(box, 1, mon)
        return { destination = "box", boxNum = i }
      end
    end
    return { destination = "box", boxFull = true }
  end
  save.boxes = save.boxes or {}
  local idx = tonumber(save.currentBox) or 1
  save.boxes[idx] = save.boxes[idx] or {}
  if #save.boxes[idx] < 20 then
    table.insert(save.boxes[idx], 1, mon)
    return { destination = "box", boxNum = idx }
  end
  return { destination = "box", boxFull = true }
end

--- Native Gold SetSeenAndCaughtMon: pokedex.caught + seen, keyed by species id.
function Gen2.markSpeciesCaught(game, species, mon)
  local save = game and game.save
  if not (save and species) then return false end
  save.pokedex = save.pokedex or { seen = {}, caught = {} }
  save.pokedex.seen = save.pokedex.seen or {}
  save.pokedex.caught = save.pokedex.caught or {}
  save.pokedex.seen[species] = true
  save.pokedex.caught[species] = true
  if mon then
    local Unown = tryRequire("src.core.gen2.Unown")
    if Unown and Unown.registerCatch then
      pcall(Unown.registerCatch, save, mon)
    end
  end
  return true
end

--- Gold Pokédex seen table is keyed by internal species id.
function Gen2.hasSeenSpecies(game, species)
  local dex = game and game.save and game.save.pokedex
  if not (dex and species) then return false end
  local seen = dex.seen
  if type(seen) ~= "table" then return false end
  return seen[species] == true
end

--- Gold capture registration: pokedex.caught (SetSeenAndCaughtMon).
function Gen2.hasCaughtSpecies(game, species)
  local dex = game and game.save and game.save.pokedex
  if not (dex and species) then return false end
  local caught = dex.caught
  if type(caught) ~= "table" then return false end
  return caught[species] == true
end

function Gen2.playerHasPartySpace(game)
  local party = Gen2.party(game)
  if type(party) ~= "table" then return false end
  return #party < 6
end

--- Bug-Catching Contest (and similar engine-owned catch modes) block OW throws.
-- Safari stays a separate capability and is not treated as this session.
function Gen2.specialCatchSessionBlocks(game, _ow)
  local save = game and game.save
  if not save then return false end
  local BugContest = tryRequire("src.core.gen2.BugContest")
  if BugContest and type(BugContest.isActive) == "function" then
    local ok, active = pcall(BugContest.isActive, save)
    if ok and active == true then return true end
  end
  local contest = save.bugContest
  if type(contest) == "table" and contest.active == true then
    return true
  end
  return false
end

--- Gold restore: World:applyPlayerState picks SPRITE_CHRIS / bike / surf.
function Gen2.restoreTrainerSprite(player, game, ow)
  ow = goldWorld(game, ow)
  if ow and type(ow.applyPlayerState) == "function" then
    local ok, err = pcall(ow.applyPlayerState, ow, ow.playerState)
    if not ok then return false, err end
    if player then
      player._pokepcAsPokemon = nil
      player._pokepcControlSpecies = nil
      player._pokepcShiny = nil
      player._pokepcControlStyle = nil
    end
    return true, "applyPlayerState"
  end
  return false, "no applyPlayerState"
end

return Gen2
