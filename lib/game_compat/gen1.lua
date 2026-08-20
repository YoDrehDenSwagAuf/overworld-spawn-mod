-- Gen 1 adapter for Wilds game compatibility.
--
-- Thin wrappers around the current Red / Blue / Yellow logic. Do not change
-- semantics here — future generations get their own adapter.
local V = ...

local Gen1 = {}
Gen1.supported = true
Gen1.generation = 1
-- National Dex cap for Gen1-only consumers (True Size, etc.). Shared
-- GameCompat.speciesId does not apply this cap.
Gen1.MAX_SPECIES = 151

Gen1.capabilities = {
  core = true,
  species = true,
  party = true,
  surf = true,
  encounters = true,
  followers = true,
  catching = true,
  ambient = true,
  townPokemon = true,
  safari = true,
}

-- Existing Gen1 name → dex fallback (moved from follower/sprite_service.lua).
-- Used only when the engine species resolver cannot resolve a key.
Gen1.SPECIES_TO_DEX = {
  BULBASAUR=1, IVYSAUR=2, VENUSAUR=3, CHARMANDER=4, CHARMELEON=5, CHARIZARD=6,
  SQUIRTLE=7, WARTORTLE=8, BLASTOISE=9, CATERPIE=10, METAPOD=11, BUTTERFREE=12,
  WEEDLE=13, KAKUNA=14, BEEDRILL=15, PIDGEY=16, PIDGEOTTO=17, PIDGEOT=18,
  RATTATA=19, RATICATE=20, SPEAROW=21, FEAROW=22, EKANS=23, ARBOK=24,
  PIKACHU=25, RAICHU=26, SANDSHREW=27, SANDSLASH=28, NIDORAN_F=29, NIDORINA=30,
  NIDOQUEEN=31, NIDORAN_M=32, NIDORINO=33, NIDOKING=34, CLEFAIRY=35, CLEFABLE=36,
  VULPIX=37, NINETALES=38, JIGGLYPUFF=39, WIGGLYTUFF=40, ZUBAT=41, GOLBAT=42,
  ODDISH=43, GLOOM=44, VILEPLUME=45, PARAS=46, PARASECT=47, VENONAT=48,
  VENOMOTH=49, DIGLETT=50, DUGTRIO=51, MEOWTH=52, PERSIAN=53, PSYDUCK=54,
  GOLDUCK=55, MANKEY=56, PRIMEAPE=57, GROWLITHE=58, ARCANINE=59, POLIWAG=60,
  POLIWHIRL=61, POLIWRATH=62, ABRA=63, KADABRA=64, ALAKAZAM=65, MACHOP=66,
  MACHOKE=67, MACHAMP=68, BELLSPROUT=69, WEEPINBELL=70, VICTREEBEL=71, TENTACOOL=72,
  TENTACRUEL=73, GEODUDE=74, GRAVELER=75, GOLEM=76, PONYTA=77, RAPIDASH=78,
  SLOWPOKE=79, SLOWBRO=80, MAGNEMITE=81, MAGNETON=82, FARFETCHD=83, DODUO=84,
  DODRIO=85, SEEL=86, DEWGONG=87, GRIMER=88, MUK=89, SHELLDER=90,
  CLOYSTER=91, GASTLY=92, HAUNTER=93, GENGAR=94, ONIX=95, DROWZEE=96,
  HYPNO=97, KRABBY=98, KINGLER=99, VOLTORB=100, ELECTRODE=101, EXEGGCUTE=102,
  EXEGGUTOR=103, CUBONE=104, MAROWAK=105, HITMONLEE=106, HITMONCHAN=107, LICKITUNG=108,
  KOFFING=109, WEEZING=110, RHYHORN=111, RHYDON=112, CHANSEY=113, TANGELA=114,
  KANGASKHAN=115, HORSEA=116, SEADRA=117, GOLDEEN=118, SEAKING=119, STARYU=120,
  STARMIE=121, MR_MIME=122, SCYTHER=123, JYNX=124, ELECTABUZZ=125, MAGMAR=126,
  PINSIR=127, TAUROS=128, MAGIKARP=129, GYARADOS=130, LAPRAS=131, DITTO=132,
  EEVEE=133, VAPOREON=134, JOLTEON=135, FLAREON=136, PORYGON=137, OMANYTE=138,
  OMASTAR=139, KABUTO=140, KABUTOPS=141, AERODACTYL=142, SNORLAX=143, ARTICUNO=144,
  ZAPDOS=145, MOLTRES=146, DRATINI=147, DRAGONAIR=148, DRAGONITE=149, MEWTWO=150, MEW=151,
}

local function tryVRequire(name)
  local ok, mod = pcall(function() return V.require(name) end)
  if ok then return mod end
  return nil
end

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

--- Resolve a species key to a numeric id using current Gen1 paths.
-- 1. numeric id → return as-is if a positive integer
-- 2. engine species resolver (AnimatedSprites / game.data / content)
-- 3. existing Gen1 name mapping fallback
function Gen1.speciesId(species, game, mod)
  if species == nil then return nil end
  local n = tonumber(species)
  if n and n >= 1 and math.floor(n) == n then
    return math.floor(n)
  end
  if type(species) ~= "string" and type(species) ~= "number" then
    return nil
  end

  local AnimatedSprites = tryVRequire("animated_sprites")
  if AnimatedSprites and AnimatedSprites.resolveSpeciesId then
    local ok, dex = pcall(AnimatedSprites.resolveSpeciesId, species, game, mod)
    if ok and type(dex) == "number" and dex >= 1 then
      return math.floor(dex)
    end
  end

  if type(species) == "string" and species ~= "" then
    local mapped = Gen1.SPECIES_TO_DEX[species:upper()]
    if mapped then return mapped end
  end
  return nil
end

--- Current Red/Blue/Yellow surf detection (ControlEngine / water-compat).
function Gen1.isSurfing(game, ow)
  ow = ow or (game and game.overworld)
  local player = ow and ow.player
  if not player then return false end
  if player.surfing == true or player.isSurfing == true then return true end
  if player.surface == "water" or player.surface == "WATER" then return true end
  if game and game.player and game.player.surfing == true then return true end
  if ow and ow.map and player.cellX ~= nil and player.cellY ~= nil then
    return Gen1.isWaterCell(ow.map, player.cellX, player.cellY)
  end
  return false
end

function Gen1.isWaterCell(map, x, y)
  if not (map and type(map.isWaterCell) == "function") then return false end
  local ok, water = pcall(map.isWaterCell, map, x, y)
  return ok and water == true
end

function Gen1.party(game)
  if not (game and game.save and type(game.save.party) == "table") then
    return nil
  end
  return game.save.party
end

function Gen1.currentMapId(game, ow)
  ow = ow or (game and game.overworld)
  if ow and ow.map and ow.map.id ~= nil then
    return ow.map.id
  end
  return nil
end

--- Per-map encounter table. Same object as game.data.encounters[mapId].
function Gen1.encountersForMap(game, mapId)
  if not game or not game.data or type(game.data.encounters) ~= "table" then
    return nil
  end
  return game.data.encounters[mapId]
end

--- Exact current Gen1 wild battle entry: queue start_battle wild species level.
function Gen1.startWildBattle(world, species, level)
  if not (world and type(world.queueScript) == "function") then
    return nil, "no world"
  end
  return world:queueScript({
    { "start_battle", "wild", species, tonumber(level) or 5 },
  })
end

--- Gen1 trailer NPC: exact ControlEngine makeTrailer constructor.
function Gen1.makeGuestNpc(game, ow, spec)
  spec = spec or {}
  local NPC = tryRequire("src.world.NPC")
  if not (NPC and NPC.new) then return nil, "no NPC" end
  if not (game and game.data and ow and ow.map and ow.map.id) then
    return nil, "no data/map"
  end
  return NPC.new(game.data, ow.map.id, {
    index = spec.index,
    name = spec.name,
    sprite = spec.spriteId or "SPRITE_PIKACHU",
    movement = spec.movement or "STAY",
    range = spec.range or "NONE",
    x = spec.x, y = spec.y,
  })
end

--- Thrown Ball: EXACT previous Projectile.makeBallEntity Gen1 path.
-- NPC.new(data, mapId, objDef). Headless stub when NPC/data is missing.
function Gen1.makeCatchProjectile(game, ow, spec)
  spec = spec or {}
  local ballType = spec.ballType or "POKE_BALL"
  local spriteId = spec.spriteId or ("SPRITE_WILDS_BALL_" .. ballType)
  local cellX = spec.x or spec.cellX or 0
  local cellY = spec.y or spec.cellY or 0
  local data = game and game.data
  local NPC = tryRequire("src.world.NPC")
  local entity
  if NPC and NPC.new and data then
    local ok, created = pcall(NPC.new, data, ow and ow.map and ow.map.id or 1, {
      index = 480 + math.random(1, 40),
      name = "WILDS_BALL_" .. tostring(ballType),
      sprite = spriteId,
      movement = "NONE",
      x = cellX,
      y = cellY,
    })
    if ok then entity = created end
  end
  if not entity then
    entity = {
      cellX = cellX,
      cellY = cellY,
      px = cellX * 16,
      py = cellY * 16,
      facing = "down",
      sprite = spriteId,
      movement = "NONE",
      passable = true,
      pose = function(self)
        return self.sprite, self.px, self.py, self.facing or "down", 0, false
      end,
    }
  end
  return entity
end

--- Gen1 CONTROL=POKEMON: assign SpriteRenderer onto player.sprite.
function Gen1.applyControlledPokemonSprite(player, renderer, _game)
  if not (player and renderer) then return false, "missing player or renderer" end
  player.sprite = renderer
  player._pokepcAsPokemon = true
  return true, "player.sprite"
end

--- Catching-only world object. EXACT previous OverworldCatching:overworld().
-- Returns WorldAPI:overworld() → OverworldState. Do not add Gold fallbacks.
function Gen1.catchWorld(mod, _game)
  local world = mod and mod.world
  if not world or not world.overworld then return nil end
  return world:overworld()
end

--- Catching-only player. EXACT previous `ow.player` read.
function Gen1.catchPlayer(_game, ow)
  return ow and ow.player
end

function Gen1.playerCell(game, ow)
  local player = Gen1.catchPlayer(game, ow)
  if not player then return nil, nil end
  return player.cellX, player.cellY
end

--- EXACT previous OverworldCatching:playerHasControl.
function Gen1.catchPlayerHasControl(game, ow, logic)
  if not game or not ow or not ow.player then return false end
  if ow.runner and ow.runner.isRunning and ow.runner:isRunning() then
    return false
  end
  if ow.textbox and ow.textbox.active and ow.textbox:active() then
    return false
  end
  if ow.engaging then return false end
  if logic and logic.pendingBattle then return false end

  local stack = game.stack
  if stack and stack.top then
    local top = stack:top()
    if top and top ~= ow then
      local opaque = top.isOpaque == true
        or (type(top.isOpaque) == "function" and top:isOpaque())
      if opaque or top.battle or top.isBattle then
        return false
      end
      if top ~= ow then return false end
    end
  end
  return true
end

--- EXACT previous OverworldCatching:isBlockedByUi.
function Gen1.catchUiBlocked(game, ow, logic)
  if not game then return true end
  if logic and logic.pendingBattle then return true end
  if ow and ow.runner and ow.runner.isRunning and ow.runner:isRunning() then
    return true
  end
  if ow and ow.textbox and ow.textbox.active and ow.textbox:active() then
    return true
  end
  local stack = game.stack
  if stack and stack.top then
    local top = stack:top()
    if top and ow and top ~= ow then
      local opaque = top.isOpaque == true
        or (type(top.isOpaque) == "function" and top:isOpaque())
      if opaque or top.battle or top.isBattle then
        return true
      end
      return true
    end
  end
  return false
end

--- Current OW catch inventory read: `game.save.inventory[ballType]`.
function Gen1.ballCount(game, ballType)
  local inv = game and game.save and game.save.inventory
  if not inv or ballType == nil then return 0 end
  return tonumber(inv[ballType]) or 0
end

--- Current OW catch consume: Bag.remove(save, ballType, 1), else raw decrement.
function Gen1.consumeBall(game, ballType)
  local Bag = tryRequire("src.inventory.Bag")
  local save = game and game.save
  if not save or not save.inventory then return false end
  if Gen1.ballCount(game, ballType) <= 0 then return false end
  if Bag and Bag.remove then
    Bag.remove(save, ballType, 1)
  else
    local n = (save.inventory[ballType] or 0) - 1
    if n <= 0 then save.inventory[ballType] = nil
    else save.inventory[ballType] = n end
  end
  return true
end

--- Species catch-rate byte from game.data.pokemon[species].
function Gen1.catchRate(game, species)
  local def = game and game.data and game.data.pokemon and game.data.pokemon[species]
  if type(def) == "table" and def.catchRate ~= nil then
    return tonumber(def.catchRate) or 255, def
  end
  return 255, def
end

--- Current OW catch roll: src.battle.Catching.attempt(ball, mon, def, rng, rateOverride).
-- Returns caught, shakes. Master Ball / missing API fallbacks stay identical.
function Gen1.attemptCatch(game, opts)
  opts = opts or {}
  local ballType = opts.ballType or "POKE_BALL"
  local mon = opts.mon
  local def = opts.def or { catchRate = 255, name = opts.species }
  local rng = opts.rng or (love and love.math and love.math.random) or math.random
  local rateOverride = opts.rateOverride
  local Catching = tryRequire("src.battle.Catching")
  if Catching and Catching.attempt then
    return Catching.attempt(ballType, mon, def, rng, rateOverride)
  end
  if ballType == "MASTER_BALL" then
    return true, 3
  end
  local roll = rng(0, 255)
  local rate = rateOverride or (def and def.catchRate) or 255
  local caught = roll <= rate
  return caught, caught and 3 or 1
end

--- Current OW catch constructor: src.pokemon.Pokemon.new(data, species, level).
function Gen1.createCaughtPokemon(game, species, level, context)
  context = context or {}
  local Pokemon = tryRequire("src.pokemon.Pokemon")
  local newMon
  if Pokemon and Pokemon.new and game and game.data then
    local ok, mon = pcall(Pokemon.new, game.data, species, level)
    if ok then newMon = mon end
  end
  if not newMon then
    newMon = { species = species, level = level, hp = 1, stats = { hp = 1 } }
  end
  if context.shiny then newMon.shiny = true end
  if context.variant then newMon.variant = context.variant end
  return newMon
end

--- Current OW catch store: Party.add, else Boxes.deposit, else party insert.
-- Returns { destination = "party"|"box"|nil, boxNum = n?, boxFull = bool? }.
function Gen1.giveCaughtPokemon(game, mon)
  if not (game and mon) then return { destination = nil } end
  local Party = tryRequire("src.pokemon.Party")
  local Boxes = tryRequire("src.pokemon.Boxes")
  local added = false
  if Party and Party.add and game.save and game.save.party then
    added = Party.add(game.save.party, mon) == true
  end
  if added then
    return { destination = "party" }
  end
  if Boxes and Boxes.deposit and game.save then
    local boxNum = Boxes.deposit(game.save, mon)
    if boxNum then
      return { destination = "box", boxNum = boxNum }
    end
    return { destination = "box", boxFull = true }
  end
  if game.save and game.save.party and #(game.save.party) < 6 then
    table.insert(game.save.party, mon)
    return { destination = "party" }
  end
  return { destination = nil }
end

--- Native Gen1 owned/seen stamp (BattleState.markOwned). No-op without a dex.
function Gen1.markSpeciesCaught(game, species, _mon)
  local dex = game and game.save and game.save.pokedex
  if not (dex and species) then return false end
  dex.seen = dex.seen or {}
  dex.seen[species] = true
  if dex.owned ~= nil or dex.caught == nil then
    dex.owned = dex.owned or {}
    dex.owned[species] = true
  else
    dex.caught[species] = true
  end
  return true
end

--- Gen1 Pokédex seen table is keyed by internal species id.
function Gen1.hasSeenSpecies(game, species)
  local dex = game and game.save and game.save.pokedex
  if not (dex and species) then return false end
  local seen = dex.seen
  if type(seen) ~= "table" then return false end
  return seen[species] == true
end

--- Gen1 capture registration: owned (BattleState.markOwned) or caught.
function Gen1.hasCaughtSpecies(game, species)
  local dex = game and game.save and game.save.pokedex
  if not (dex and species) then return false end
  if type(dex.owned) == "table" and dex.owned[species] == true then
    return true
  end
  if type(dex.caught) == "table" and dex.caught[species] == true then
    return true
  end
  return false
end

function Gen1.playerHasPartySpace(game)
  local party = Gen1.party(game)
  if type(party) ~= "table" then return false end
  return #party < 6
end

--- Safari is handled by SafariCompat. No extra Gen1 special session.
function Gen1.specialCatchSessionBlocks(_game, _ow)
  return false
end

return Gen1
