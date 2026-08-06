-- Control / pack / trailer engine for Wilds of Kanto standalone use.
--
-- Credits: masterwebx / Followers EX ControlEngine concepts adapted for Wilds;
-- assets via Wilds sprite service (no PokePCFollowers_VoxelMerge dependency).
--
-- Ownership: install() is the sole PikachuFollower hook owner for
-- shouldSpawn / update / onMapEntered when the control engine is installed.
-- Lifecycle must NOT also wrap update/onMapEntered/shouldSpawn in that case;
-- talk wrapping may remain on lifecycle.
local V = ...
local Constants = V.require("follower/constants")

local DebugLog
do
  local ok, mod = pcall(function() return V.require("debug_log") end)
  if ok then DebugLog = mod end
end

local ControlEngine = {}
ControlEngine.__index = ControlEngine

local TRAILER_BASE = 240

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function logInfo(mod, fmt, ...)
  if DebugLog and DebugLog.info then
    DebugLog.info(mod, fmt, ...)
  end
end

local function logWarn(mod, fmt, ...)
  if DebugLog and DebugLog.warn then
    DebugLog.warn(mod, fmt, ...)
  end
end

local function captureUpvalue(fn, upvalueName)
  if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then
    return nil, nil
  end
  local i = 1
  while true do
    local name, val = debug.getupvalue(fn, i)
    if not name then break end
    if name == upvalueName then return i, val end
    i = i + 1
  end
  return nil, nil
end

local function patchUpvalue(fn, upvalueName, newVal)
  local idx = select(1, captureUpvalue(fn, upvalueName))
  if idx and debug.setupvalue then
    debug.setupvalue(fn, idx, newVal)
    return true
  end
  return false
end

local function isShinyMon(mon)
  if not mon then return false end
  if mon.shiny == true or mon.isShiny == true then return true end
  local Stats = tryRequire("src.pokemon.Stats")
  if Stats and Stats.isShiny and mon.dvs then
    local ok, shiny = pcall(Stats.isShiny, mon.dvs)
    return ok and shiny and true or false
  end
  return false
end

local function copySpriteDef(def)
  if type(def) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(def) do out[k] = v end
  return out
end

--- Construct a control engine instance.
-- @param mod Wilds mod handle
-- @param deps table optional: spriteService, settings, selection, render, game
function ControlEngine.new(mod, deps)
  deps = deps or {}
  local self = setmetatable({}, ControlEngine)
  self.mod = mod
  self.deps = deps
  self.spriteService = deps.spriteService
  self.settings = deps.settings
  self.selection = deps.selection
  self.render = deps.render
  self._gameRef = deps.game -- optional injected Game (tests)
  self._installed = false
  self._restoreState = nil
  self._pendingMapTrailerSync = false
  self._optCache = {}
  self._eventOff = {}
  self._talkWrapped = false
  return self
end

function ControlEngine:_game()
  if self._gameRef then return self._gameRef end
  local Game = tryRequire("src.core.Game")
  return Game
end

function ControlEngine:_isYellow()
  local GV = tryRequire("src.core.GameVersion")
  if not (GV and GV.isYellow) then return false end
  local ok, yellow = pcall(GV.isYellow)
  return ok and yellow and true or false
end

function ControlEngine:_opt(key, default)
  local cache = self._optCache
  if cache[key] ~= nil then return cache[key] end
  local mod = self.mod
  if mod and mod.options and mod.options.get then
    local ok, got = pcall(mod.options.get, mod.options, key)
    if ok and got ~= nil and type(got) ~= "boolean" then
      cache[key] = got
      return got
    end
  end
  cache[key] = default
  return default
end

function ControlEngine:onOptionsChanged(payload)
  self._optCache = {}
  local settings = self.settings
  if settings and type(settings.onOptionsChanged) == "function" then
    pcall(settings.onOptionsChanged, settings, payload)
  end
  local game = self:_game()
  local ow = game and game.overworld
  if game then
    pcall(function() self:alignSaveFromOptions(game) end)
    pcall(function() self:syncAll(game, ow) end)
  end
end

function ControlEngine:controlMode(game)
  game = game or self:_game()
  local settings = self.settings
  if settings and type(settings.engineMode) == "function" then
    local ok, mode = pcall(settings.engineMode, settings, game)
    if ok and type(mode) == "string" and mode ~= "" then
      if mode == "lead" then mode = "lead_trainer" end
      return mode
    end
  end
  local saved = game and game.save and game.save.pokepcControlMode
  if saved == "lead" then saved = "lead_trainer" end
  if type(saved) == "string" and saved ~= "" then return saved end
  return tostring(self:_opt("control_mode", "follow"))
end

function ControlEngine:followerCount(game)
  game = game or self:_game()
  local settings = self.settings
  if settings and type(settings.followerCount) == "function" then
    local ok, n = pcall(settings.followerCount, settings, game)
    if ok and type(n) == "number" then
      return math.max(0, math.min(6, n))
    end
  end
  local saved = game and game.save and game.save.pokepcFollowerCount
  if type(saved) == "number" then return math.max(0, math.min(6, saved)) end
  return tonumber(self:_opt("follower_count", 1)) or 1
end

function ControlEngine:setFollowerCount(game, n)
  n = math.max(0, math.min(6, math.floor(tonumber(n) or 0)))
  self._optCache.follower_count = n
  local settings = self.settings
  if settings and type(settings.setFollowerCount) == "function" then
    pcall(settings.setFollowerCount, settings, game, n)
  end
  if game and game.save then game.save.pokepcFollowerCount = n end
end

function ControlEngine:setControlMode(game, mode)
  mode = mode or "follow"
  if mode == "lead" then mode = "lead_trainer" end
  self._optCache.control_mode = mode
  local settings = self.settings
  if settings and type(settings.setEngineMode) == "function" then
    pcall(settings.setEngineMode, settings, game, mode)
  end
  if game and game.save then game.save.pokepcControlMode = mode end
end

function ControlEngine:isPokemonFront(game)
  local m = self:controlMode(game)
  return m == "pokemon" or m == "lead_trainer" or m == "pack"
end

function ControlEngine:clearLeader(game)
  if game and game.save then
    game.save.pokepcLeader = nil
    game.save.followerPartyIndex = nil
  end
end

function ControlEngine:bustLeaderVisual(game)
  local player = game and game.overworld and game.overworld.player
  if player then
    player._pokepcControlSpecies = nil
  end
end

function ControlEngine.monIdentityKey(mon)
  if not mon then return nil end
  local dvs = mon.dvs
  local dvKey = ""
  if type(dvs) == "table" then
    dvKey = table.concat({
      tostring(dvs.attack), tostring(dvs.defense),
      tostring(dvs.speed), tostring(dvs.special),
    }, ",")
  elseif dvs ~= nil then
    dvKey = tostring(dvs)
  end
  return table.concat({
    tostring(mon.species or ""),
    tostring(mon.level or ""),
    tostring(mon.nickname or ""),
    tostring(mon.otId or ""),
    dvKey,
  }, "|")
end

-- Yellow: party[1] = talkable Pikachu; chosen leader → party[2]
-- (unless leader IS that Pikachu → stays slot 1).
function ControlEngine:ensureYellowLeaderLayout(game, leaderMon)
  if not self:_isYellow() then return nil end
  local save = game and game.save
  local party = save and save.party
  if not (party and leaderMon) then return nil end

  local pikaIdx = nil
  for i, mon in ipairs(party) do
    if mon and mon.species == "PIKACHU" then
      pikaIdx = i
      break
    end
  end
  if not pikaIdx then return nil end
  local pika = party[pikaIdx]

  local leadIdx = nil
  for i, mon in ipairs(party) do
    if mon == leaderMon then leadIdx = i; break end
  end
  if not leadIdx then
    local want = ControlEngine.monIdentityKey(leaderMon)
    for i, mon in ipairs(party) do
      if want and ControlEngine.monIdentityKey(mon) == want then
        leadIdx = i
        break
      end
    end
  end
  if not leadIdx then return nil end
  local lead = party[leadIdx]

  if lead == pika then
    if pikaIdx ~= 1 then
      table.remove(party, pikaIdx)
      table.insert(party, 1, pika)
    end
    return 1
  end

  local rest = {}
  for _, mon in ipairs(party) do
    if mon ~= pika and mon ~= lead then
      rest[#rest + 1] = mon
    end
  end
  local newParty = { pika, lead }
  for i = 1, #rest do
    newParty[#newParty + 1] = rest[i]
  end
  save.party = newParty
  return 2
end

function ControlEngine:setLeaderParty(game, partyIndex)
  if not game or not game.save then return end
  local mon = game.save.party and game.save.party[partyIndex]
  if self:_isYellow() and mon then
    local idx = self:ensureYellowLeaderLayout(game, mon)
    if type(idx) == "number" then partyIndex = idx end
  end
  game.save.pokepcLeader = { source = "party", index = partyIndex }
  game.save.followerPartyIndex = partyIndex
  if self.selection and type(self.selection.selectFollower) == "function" then
    local m = game.save.party and game.save.party[partyIndex]
    if m then pcall(self.selection.selectFollower, self.selection, m, game, {}) end
  end
  self:bustLeaderVisual(game)
end

function ControlEngine:setLeaderBox(game, boxNum, slotIndex)
  if not game or not game.save then return end
  game.save.pokepcLeader = {
    source = "box", box = boxNum, index = slotIndex,
  }
  self:bustLeaderVisual(game)
end

function ControlEngine:getLeaderMon(game)
  game = game or self:_game()
  if not game or not game.save then return nil end
  local save = game.save
  local lead = save.pokepcLeader

  -- Box leader always wins when explicitly set (selection is party-only).
  if lead and lead.source == "box" then
    local Boxes = tryRequire("src.pokemon.Boxes")
    if Boxes and Boxes.ensure then pcall(Boxes.ensure, save) end
    local boxes = save.boxes or {}
    local box = boxes[lead.box or save.currentBox or 1]
    local mon = box and box[lead.index]
    if mon then return mon, "box" end
  end

  -- Prefer Wilds selection when available.
  if self.selection and type(self.selection.getActiveFollowerMon) == "function" then
    local ok, mon, slot = pcall(self.selection.getActiveFollowerMon, self.selection, game, false)
    if ok and mon then return mon, "party", slot end
  end

  if lead and lead.source == "party" then
    local mon = save.party and save.party[lead.index]
    if mon and (mon.hp or 0) >= 0 then return mon, "party" end
  end

  local idx = save.followerPartyIndex
  if idx and save.party and save.party[idx] then
    return save.party[idx], "party"
  end

  if self:_isYellow() and save.party and save.party[1]
     and save.party[1].species == "PIKACHU" and save.party[2]
     and (save.party[2].hp or 0) > 0 then
    return save.party[2], "party"
  end
  for _, mon in ipairs(save.party or {}) do
    if (mon.hp or 0) > 0 then return mon, "party" end
  end
  return save.party and save.party[1], "party"
end

function ControlEngine:getActiveFollowerMon(game)
  game = game or self:_game()
  if self.selection and type(self.selection.getActiveFollowerMon) == "function" then
    local ok, mon = pcall(self.selection.getActiveFollowerMon, self.selection, game, true)
    if ok and mon then return mon end
  end
  return (self:getLeaderMon(game))
end

function ControlEngine:_leaderPartyIndex(game, leader, leadSrc)
  local save = game and game.save
  if not save then return nil end
  local lead = save.pokepcLeader
  if lead and lead.source == "party" and type(lead.index) == "number" then
    return lead.index
  end
  if leadSrc == "party" and leader then
    for i, mon in ipairs(save.party or {}) do
      if mon == leader then return i end
    end
  end
  if type(save.followerPartyIndex) == "number" then
    return save.followerPartyIndex
  end
  return nil
end

function ControlEngine:_partyPikachuIndex(save)
  for i, mon in ipairs(save and save.party or {}) do
    if mon and mon.species == "PIKACHU" and (mon.hp or 0) > 0 then
      return i
    end
  end
  return nil
end

function ControlEngine:yellowStockFollowActive(game)
  if not self:_isYellow() then return false end
  if self:controlMode(game) ~= "follow" then return false end
  local save = game and game.save
  return self:_partyPikachuIndex(save) ~= nil
end

function ControlEngine:_findStockPikachu(ow)
  for _, npc in ipairs((ow and ow.npcs) or {}) do
    if npc and npc.pikachuFollower and not npc.pokepcTrailer then
      return npc
    end
  end
  return nil
end

function ControlEngine:isYellowPikachuTrailer(npc)
  return npc and npc.pokepcTrailer and npc.pokepcMon
    and npc.pokepcMon.species == "PIKACHU"
    and self:_isYellow()
end

--- Resolve a follower sprite def via injected spriteService, or render fallback.
-- Never errors on missing PokéPC.
function ControlEngine:resolveFollowerSprite(opts)
  opts = opts or {}
  local svc = self.spriteService
  if svc and type(svc.resolveFollowerSprite) == "function" then
    local ok, def = pcall(svc.resolveFollowerSprite, svc, opts)
    if ok and def and def.image then return def end
  end

  local render = self.render
  local species = opts.species or "CHARMANDER"
  local shiny = opts.shiny == true
  local variant = shiny and "shiny" or "normal"
  local role = opts.role or "primary"
  local sheets = render and render.runtimeSheets
  if sheets then
    if not sheets.ready and sheets.load then pcall(function() sheets:load() end) end
    local dex = 4
    if svc and type(svc.dexOf) == "function" then
      local ok, d = pcall(svc.dexOf, svc, species)
      if ok and d then dex = d end
    else
      local AS
      pcall(function() AS = V.require("animated_sprites") end)
      if AS and AS.resolveSpeciesId then
        local ok, d = pcall(AS.resolveSpeciesId, species, nil, self.mod)
        if ok and d then dex = d end
      end
    end
    local id = (role == "player_controlled") and "SPRITE_PLAYER_POKEMON"
      or "SPRITE_WILDS_FOLLOWER_MON"
    if sheets.spriteDef then
      local ok, def = pcall(sheets.spriteDef, sheets, dex, variant, id)
      if ok and def and def.image then
        return {
          image = def.image,
          frames = def.frames or 6,
          walker = def.walker ~= false,
          trueColor = def.trueColor ~= false,
          id = def.id or id,
        }
      end
    end
  end

  local image = "assets/fallback/pokemon_missing.png"
  if render and type(render._modAssetPath) == "function" then
    local ok, path = pcall(render._modAssetPath, render, "assets/fallback/pokemon_missing.png")
    if ok and path then image = path end
  elseif self.mod and self.mod.path then
    image = self.mod.path .. "/assets/fallback/pokemon_missing.png"
  end
  return {
    image = image,
    frames = 1,
    walker = false,
    trueColor = true,
    id = Constants.SPRITE_ID,
  }
end

function ControlEngine:forceYellowStockPikachuArt(ow, game)
  if not self:_isYellow() then return end
  local npc = self:_findStockPikachu(ow)
  if not npc then return end
  game = game or self:_game()
  local resolved = self:resolveFollowerSprite({
    species = "PIKACHU",
    shiny = false,
    surface = "land",
    role = "primary",
    game = game,
  })
  if not (resolved and resolved.image) then return end
  local def = npc.sprite and npc.sprite.def
  if def and def.image == resolved.image and def.id == Constants.SPRITE_ID then
    npc._pokepcFollowerSpecies = "PIKACHU"
    npc._wildsFollowerSpecies = "PIKACHU"
    return
  end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new) then return end
  local ok, sprite = pcall(SpriteRenderer.new, {
    id = Constants.SPRITE_ID,
    image = resolved.image,
    frames = resolved.frames or 6,
    walker = resolved.walker ~= false,
    trueColor = resolved.trueColor ~= false,
  }, npc.id or Constants.ENTITY_ID)
  if ok and sprite then
    npc.sprite = sprite
    npc.spriteId = Constants.SPRITE_ID
    npc._pokepcFollowerSpecies = "PIKACHU"
    npc._wildsFollowerSpecies = "PIKACHU"
  end
end

function ControlEngine:_trailAnchor(game, ow, player)
  if self:yellowStockFollowActive(game) then
    local stock = self:_findStockPikachu(ow)
    if stock then return stock end
  end
  return player
end

function ControlEngine:partyTrailMons(game)
  local save = game and game.save
  if not save then return {} end
  local leader, leadSrc = self:getLeaderMon(game)
  local leadIdx = self:_leaderPartyIndex(game, leader, leadSrc)
  local leadKey = ControlEngine.monIdentityKey(leader)
  local front = self:isPokemonFront(game)
  local skipPikaIdx = self:yellowStockFollowActive(game) and self:_partyPikachuIndex(save) or nil
  local out = {}
  local function push(mon, i)
    out[#out + 1] = { mon = mon, partyIndex = i }
  end
  local function isControlledLeader(mon, i)
    if not mon then return false end
    if leadIdx and i == leadIdx then return true end
    if leader and mon == leader then return true end
    if leadKey and ControlEngine.monIdentityKey(mon) == leadKey then return true end
    return false
  end
  local function skipAsStockPika(i)
    return skipPikaIdx and i == skipPikaIdx
  end

  if not front and leader then
    if leadIdx and save.party and save.party[leadIdx]
       and (save.party[leadIdx].hp or 0) > 0
       and not skipAsStockPika(leadIdx) then
      push(save.party[leadIdx], leadIdx)
    else
      for i, mon in ipairs(save.party or {}) do
        if isControlledLeader(mon, i) and (mon.hp or 0) > 0
           and not skipAsStockPika(i) then
          push(mon, i)
          break
        end
      end
    end
  end
  for i, mon in ipairs(save.party or {}) do
    if (mon.hp or 0) > 0 and not isControlledLeader(mon, i)
       and not skipAsStockPika(i) then
      push(mon, i)
    end
  end
  local n = self:followerCount(game)
  while #out > n do out[#out] = nil end
  return out
end

function ControlEngine:_trainerWalkDef(game)
  local FieldDefaults = tryRequire("src.world.FieldDefaults")
  local data = game and game.data
  if not (data and FieldDefaults and FieldDefaults.fieldValue) then return nil end
  local walkId = FieldDefaults.fieldValue(data, "playerSprites", "walk")
  return walkId and data.sprites and data.sprites[walkId]
end

function ControlEngine:restorePlayerTrainerSprite(game, ow)
  local player = ow and ow.player
  if not player or not game or not game.data then return end
  local monSprite = player._pokepcAsPokemon
    or (player.sprite and player.sprite.def
        and player.sprite.def.id == "SPRITE_PLAYER_POKEMON")
  if not monSprite then return end
  local def = self:_trainerWalkDef(game)
  if not def then return end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new) then return end
  local ok, sprite = pcall(SpriteRenderer.new, def, "player")
  if ok and sprite then
    player.sprite = sprite
    player._pokepcAsPokemon = nil
    player._pokepcControlSpecies = nil
    player._pokepcShiny = nil
  end
end

function ControlEngine:applyPlayerAsPokemon(game, ow, force)
  local player = ow and ow.player
  if not player then return end
  if player.surfing or player.onBike or player.fishing then
    self:restorePlayerTrainerSprite(game, ow)
    return
  end
  local mon = self:getLeaderMon(game)
  local species = mon and mon.species or "CHARMANDER"
  local shiny = isShinyMon(mon)
  local resolved = self:resolveFollowerSprite({
    species = species,
    shiny = shiny,
    surface = "land",
    role = "player_controlled",
    game = game,
  })
  local path = resolved and resolved.image
  if not force and player._pokepcAsPokemon and player._pokepcControlSpecies == species
     and player._pokepcShiny == (shiny and true or false)
     and player.sprite and player.sprite.def
     and player.sprite.def.image == path then
    return
  end
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (SpriteRenderer and SpriteRenderer.new and path) then return end
  local ok, sprite = pcall(SpriteRenderer.new, {
    id = "SPRITE_PLAYER_POKEMON",
    image = path,
    frames = (resolved and resolved.frames) or 6,
    walker = not resolved or resolved.walker ~= false,
    trueColor = not resolved or resolved.trueColor ~= false,
    pokepcShiny = shiny and true or false,
  }, "player")
  if ok and sprite then
    player.sprite = sprite
    player._pokepcAsPokemon = true
    player._pokepcControlSpecies = species
    player._pokepcShiny = shiny and true or false
  end
end

function ControlEngine:syncPlayerControlVisual(game, ow, force)
  if self:isPokemonFront(game) then
    self:applyPlayerAsPokemon(game, ow, force)
  else
    self:restorePlayerTrainerSprite(game, ow)
  end
end

function ControlEngine:removeTrailers(ow)
  if not ow then return end
  local keepNpcs, keepEnt = {}, {}
  for _, npc in ipairs(ow.npcs or {}) do
    if not npc.pokepcTrailer then keepNpcs[#keepNpcs + 1] = npc end
  end
  for _, e in ipairs(ow.entities or {}) do
    if not e.pokepcTrailer then keepEnt[#keepEnt + 1] = e end
  end
  ow.npcs, ow.entities = keepNpcs, keepEnt
  ow.pokepcTrailers = {}
  ow.pokepcTrailCells = {}
end

function ControlEngine:ledgeStep(game, ow, cx, cy, dir)
  local Collision = tryRequire("src.world.Collision")
  if not (game and ow and ow.map and dir and Collision and Collision.DELTA
          and Collision.DELTA[dir]) then
    return false
  end
  local map = ow.map
  local d = Collision.DELTA[dir]
  local fx, fy = cx + d[1], cy + d[2]
  local lx, ly = cx + d[1] * 2, cy + d[2] * 2
  if not (map:inBounds(fx, fy) and map:inBounds(lx, ly)) then return false end
  local tileset = map.def and map.def.tileset
  local standing = map:cellTile(cx, cy)
  local front = map:cellTile(fx, fy)
  local ledges = game.data and game.data.field and game.data.field.ledges
  for _, ledge in ipairs(ledges or {}) do
    if (ledge.tileset or "OVERWORLD") == tileset
       and ledge.facing == dir and ledge.input == dir
       and ledge.standingTile == standing and ledge.ledgeTile == front then
      return true
    end
  end
  return false
end

function ControlEngine:makeTrailer(game, ow, x, y, facing, kind, mon, slot)
  local NPC = tryRequire("src.world.NPC")
  local SpriteRenderer = tryRequire("src.render.SpriteRenderer")
  if not (NPC and NPC.new) then return nil end

  local npc = NPC.new(game.data, ow.map.id, {
    index = TRAILER_BASE + slot,
    name = "WILDS_TRAILER_" .. tostring(slot),
    sprite = Constants.SPRITE_ID,
    movement = "STAY", range = "NONE", x = x, y = y,
  })
  -- Legacy occupancy/water compat + Wilds role markers.
  npc.pokepcTrailer = true
  npc.wildsFollower = true
  npc.wildsFollowerRole = (kind == "trainer") and "trainer_trailer" or "party_trailer"
  npc.pokepcTrailerKind = kind
  npc.pokepcTrailerId = kind .. ":" .. tostring(slot)
  npc.pokepcMon = mon
  npc.passable = true
  npc.facing = facing or "down"
  -- NEVER set pikachuFollower on trailers (stock findFollower would remove them).
  npc.pikachuFollower = false
  npc.pokepcTalkablePikachu = (kind ~= "trainer"
    and self:_isYellow()
    and mon and mon.species == "PIKACHU") and true or false

  if kind == "trainer" then
    -- Walk sheets are DMG greyscale; trueColor would draw raw greys.
    local def = self:_trainerWalkDef(game)
    if def and SpriteRenderer and SpriteRenderer.new then
      local ok, sprite = pcall(SpriteRenderer.new, {
        id = def.id or "SPRITE_RED",
        image = def.image,
        frames = def.frames or 6,
        walker = def.walker ~= false,
        source = def.source,
        paletteSource = def.paletteSource,
      }, npc.id)
      if ok and sprite then npc.sprite = sprite end
    end
  else
    local species = mon and mon.species or "CHARMANDER"
    local shiny = isShinyMon(mon)
    npc.pokepcShiny = shiny and true or false
    local resolved = self:resolveFollowerSprite({
      species = species,
      shiny = shiny,
      form = mon and mon.form,
      surface = "land",
      role = "party_trailer",
      game = game,
    })
    if resolved and resolved.image and SpriteRenderer and SpriteRenderer.new then
      local ok, sprite = pcall(SpriteRenderer.new, {
        id = resolved.id or "SPRITE_WILDS_FOLLOWER_MON",
        image = resolved.image,
        frames = resolved.frames or 6,
        walker = resolved.walker ~= false,
        trueColor = resolved.trueColor ~= false,
        pokepcShiny = npc.pokepcShiny,
      }, npc.id)
      if ok and sprite then npc.sprite = sprite end
    end
    npc._wildsFollowerSpecies = species
  end

  if NPC.walkPhase then
    npc.walkPhase = function(ent)
      if ent.moving then
        return NPC.walkPhase(ent)
      end
      return 0
    end
  end

  -- Surface-aware step: stock NPC:update rejects water targets via land
  -- walkability. Trailers always advance through our interpolator instead.
  npc.update = function(self, map, entities)
    ControlEngine.advanceTrailerStep(self, map, entities)
  end
  npc._wildsFollowerStep = true
  return npc
end

local function behindOffset(facing, steps)
  local dx = facing == "left" and 1 or facing == "right" and -1 or 0
  local dy = facing == "up" and 1 or facing == "down" and -1 or 0
  return dx * steps, dy * steps
end

function ControlEngine:_playerSurfing(ow, game)
  local player = ow and ow.player
  if not player then return false end
  if player.surfing == true or player.isSurfing == true then return true end
  if player.surface == "water" or player.surface == "WATER" then return true end
  if game and game.player and game.player.surfing == true then return true end
  return false
end

function ControlEngine:_trailSurface(ow, game)
  if self:_playerSurfing(ow, game) then return "water" end
  return "land"
end

local function isWaterMapCell(map, x, y)
  if not (map and map.isWaterCell) then return false end
  local ok, water = pcall(map.isWaterCell, map, x, y)
  return ok and water == true
end

local function isLandWalkable(map, x, y)
  if not (map and map.isWalkableCell) then return false end
  local ok, walk = pcall(map.isWalkableCell, map, x, y)
  return ok and walk == true
end

--- Surface-aware cell check for Wilds Pokémon trailers only.
-- Never used for trainers/wilds/global NPC collision.
-- context.surface: "land" | "water" | "land_to_water" | "water_to_land"
-- context.role: wildsFollowerRole override when entity is not yet created
function ControlEngine:isFollowerCellAllowed(game, ow, entity, x, y, context)
  context = context or {}
  if not (ow and ow.map) then return false end
  local map = ow.map
  if type(map.inBounds) == "function" then
    local ok, inside = pcall(map.inBounds, map, x, y)
    if not (ok and inside) then return false end
  end

  local role = context.role
    or (entity and entity.wildsFollowerRole)
    or (entity and entity.pokepcTrailerKind == "trainer" and "trainer_trailer")
    or (entity and (entity.pikachuFollower == true or entity.wildsFollower == true)
        and "primary")
    or "party_trailer"

  -- Water exception only for Pokémon follower roles.
  local pokemonRole = (role == "primary" or role == "party_trailer")
  if not pokemonRole then
    return isLandWalkable(map, x, y)
  end

  local surface = context.surface or self:_trailSurface(ow, game)
  if surface == "water" or surface == "land_to_water" then
    -- Surf path: water cells the player can occupy, plus shore land for entry.
    if isWaterMapCell(map, x, y) then return true end
    if isLandWalkable(map, x, y) then return true end
    return false
  end

  if surface == "water_to_land" then
    if isLandWalkable(map, x, y) then return true end
    if isWaterMapCell(map, x, y) then return true end
    return false
  end

  -- Land: normal walkability. Allow current water cell so a surfing trailer
  -- can step onto shore without freezing when the player exits water.
  if isLandWalkable(map, x, y) then return true end
  if entity and (entity.wildsFollowerWater == true or entity.spriteState == "water")
      and isWaterMapCell(map, x, y) then
    return true
  end
  return false
end

function ControlEngine:_walkableBehind(ow, px, py, facing, steps, entity, game, role, occupied)
  local surface = self:_trailSurface(ow, game)
  local ctx = { surface = surface, role = role }
  local ox, oy = behindOffset(facing, steps)
  local bx, by = px + ox, py + oy
  local function free(x, y)
    if occupied and occupied[x .. "," .. y] then return false end
    return self:isFollowerCellAllowed(game, ow, entity, x, y, ctx)
  end
  if free(bx, by) then
    return bx, by
  end
  bx, by = px, py
  for s = math.max(steps, 1), 1, -1 do
    local sx, sy = behindOffset(facing, s)
    local tx, ty = px + sx, py + sy
    if free(tx, ty) then
      return tx, ty
    end
  end
  -- Prefer any free cell further back along the trail axis.
  for s = steps + 1, steps + 6 do
    local sx, sy = behindOffset(facing, s)
    local tx, ty = px + sx, py + sy
    if free(tx, ty) then
      return tx, ty
    end
  end
  return bx, by
end

local function placeTrailerAt(npc, x, y, facing)
  npc.cellX, npc.cellY = x, y
  npc.px, npc.py = x * 16, y * 16
  npc.targetX, npc.targetY = nil, nil
  npc.moving = false
  npc.progress = 0
  npc.hopStep = nil
  if facing then npc.facing = facing end
end

--- Advance a trailer step without stock NPC land-walkability rejection.
-- Uses the same fields as NPC movement (target/moving/progress/px/py).
function ControlEngine.advanceTrailerStep(npc, _map, _entities)
  if not npc or not npc.moving then return end
  local toX, toY = npc.targetX, npc.targetY
  if toX == nil or toY == nil then
    npc.moving = false
    npc.progress = 0
    return
  end
  local frames = tonumber(npc.stepFrames) or 16
  if frames < 1 then frames = 1 end
  npc.progress = (tonumber(npc.progress) or 0) + 1
  local fromX = tonumber(npc.cellX) or 0
  local fromY = tonumber(npc.cellY) or 0
  local t = npc.progress / frames
  if t > 1 then t = 1 end
  npc.px = (fromX + (toX - fromX) * t) * 16
  npc.py = (fromY + (toY - fromY) * t) * 16
  if npc.progress >= frames then
    npc.cellX, npc.cellY = toX, toY
    npc.px, npc.py = toX * 16, toY * 16
    npc.targetX, npc.targetY = nil, nil
    npc.moving = false
    npc.progress = 0
    npc.hopStep = nil
    if npc.stepFlip ~= nil then
      npc.stepFlip = not npc.stepFlip
    end
    npc.walkFlip = npc.stepFlip == true
    npc.flip = npc.stepFlip == true
  end
end

function ControlEngine:_seedTrailBehind(ow, anchor, facing, n, game, role)
  local goals = {}
  local occupied = {}
  local px = anchor.cellX or 0
  local py = anchor.cellY or 0
  facing = facing or anchor.facing or "down"
  role = role or "party_trailer"
  -- Anchor cell is occupied by the player / stock leader.
  occupied[px .. "," .. py] = true
  for i = 1, n do
    local bx, by = self:_walkableBehind(ow, px, py, facing, i, nil, game, role, occupied)
    goals[i] = { x = bx, y = by }
    occupied[bx .. "," .. by] = true
  end
  return goals
end

local function trailersAliveInWorld(ow, trailers)
  if not trailers or #trailers == 0 then return true end
  local ents = ow.entities or {}
  for _, t in ipairs(trailers) do
    local found = false
    for _, e in ipairs(ents) do
      if e == t then found = true; break end
    end
    if not found then return false end
  end
  return true
end

local function compositionDirty(trailers, want)
  if #trailers ~= #want then return true end
  for i, spec in ipairs(want) do
    local t = trailers[i]
    if not t or t.pokepcTrailerKind ~= spec.kind then return true end
    if spec.kind == "mon" then
      local sp = spec.mon and spec.mon.species
      local cur = t.pokepcMon and t.pokepcMon.species
      if sp ~= cur then return true end
    end
  end
  return false
end

function ControlEngine:syncTrailers(game, ow, opts)
  opts = opts or {}
  if not ow or not ow.player or not ow.map then return end
  local mode = self:controlMode(game)
  local want = {}
  local surfing = self:_playerSurfing(ow, game)
  local surface = surfing and "water" or "land"

  -- Solo "pokemon" with a pack size still trails party mons (no trainer NPC).
  if mode == "pokemon" and self:followerCount(game) > 0 then
    mode = "pack"
  end

  if mode == "lead_trainer" then
    for _, entry in ipairs(self:partyTrailMons(game)) do
      want[#want + 1] = { kind = "mon", mon = entry.mon }
    end
    -- Trainer trailers must not swim: hide while surfing, restore on land.
    if not surfing then
      want[#want + 1] = { kind = "trainer", mon = nil }
    end
  elseif mode == "follow" or mode == "pack" then
    for _, entry in ipairs(self:partyTrailMons(game)) do
      want[#want + 1] = { kind = "mon", mon = entry.mon }
    end
  end

  local trailers = ow.pokepcTrailers or {}
  local dirty = compositionDirty(trailers, want)
    or not trailersAliveInWorld(ow, trailers)

  local p = ow.player
  local anchor = self:_trailAnchor(game, ow, p)
  local facing = (anchor and anchor.facing) or p.facing or "down"
  local mapEnter = opts.mapEnter == true
  local stepClock = p.stepFramesCur or p.stepFrames
    or (anchor and (anchor.stepFramesCur or anchor.stepFrames)) or 16

  -- Surface transition: reseed once so trail goals leave the frozen shore cell.
  local prevSurface = ow._wildsFollowerTrailSurface
  if prevSurface ~= surface then
    mapEnter = true
    ow._wildsFollowerTrailSurface = surface
  end

  if not dirty and self:yellowStockFollowActive(game) and anchor ~= p
     and #trailers > 0 then
    local t1 = trailers[1]
    if t1 and not t1.moving
       and t1.cellX == anchor.cellX and t1.cellY == anchor.cellY then
      mapEnter = true
    end
  end

  if dirty then
    self:removeTrailers(ow)
    trailers = {}
    local goals = self:_seedTrailBehind(ow, anchor, facing, #want, game, "party_trailer")
    for i, spec in ipairs(want) do
      local role = (spec.kind == "trainer") and "trainer_trailer" or "party_trailer"
      local cell = goals[i]
      if not cell or not self:isFollowerCellAllowed(game, ow, nil, cell.x, cell.y, {
        surface = surface, role = role,
      }) then
        local bx, by = self:_walkableBehind(ow, anchor.cellX or 0, anchor.cellY or 0,
                                           facing, i, nil, game, role)
        cell = { x = bx, y = by }
      end
      local bx, by = cell.x, cell.y
      local okNpc, npc = pcall(function()
        return self:makeTrailer(game, ow, bx, by, facing, spec.kind, spec.mon, i)
      end)
      if not okNpc or not npc then
        logWarn(self.mod, "trailer spawn failed slot %s: %s", tostring(i), tostring(npc))
      else
        placeTrailerAt(npc, bx, by, facing)
        table.insert(ow.npcs, npc)
        table.insert(ow.entities, npc)
        local slot = #trailers + 1
        trailers[slot] = npc
        goals[slot] = { x = bx, y = by }
      end
    end
    ow.pokepcTrailers = trailers
    ow.pokepcTrailCells = goals
    ow.pokepcTrailHead = { x = anchor.cellX, y = anchor.cellY }
  elseif mapEnter and #trailers > 0 then
    local goals = self:_seedTrailBehind(ow, anchor, facing, #trailers, game, "party_trailer")
    for i, npc in ipairs(trailers) do
      local role = npc.wildsFollowerRole or "party_trailer"
      local g = goals[i]
      if not g or not self:isFollowerCellAllowed(game, ow, npc, g.x, g.y, {
        surface = surface, role = role,
      }) then
        local bx, by = self:_walkableBehind(ow, anchor.cellX or 0, anchor.cellY or 0,
                                           facing, i, npc, game, role)
        g = { x = bx, y = by }
        goals[i] = g
      end
      placeTrailerAt(npc, g.x, g.y, facing)
      if want[i] and want[i].kind == "mon" then
        npc.pokepcMon = want[i].mon
      end
    end
    ow.pokepcTrailCells = goals
    ow.pokepcTrailHead = { x = anchor.cellX, y = anchor.cellY }
  end

  local destX = anchor.targetX or anchor.cellX
  local destY = anchor.targetY or anchor.cellY
  ow.pokepcTrailHead = ow.pokepcTrailHead
    or { x = anchor.cellX, y = anchor.cellY, ledgeHop = nil }
  local head = ow.pokepcTrailHead
  local committed = (destX ~= head.x or destY ~= head.y)
  if committed then
    local stepDir = destY > head.y and "down" or destY < head.y and "up"
                    or destX > head.x and "right" or "left"
    if head.ledgeHop == stepDir then
      head.ledgeHop = nil
      head.x, head.y = destX, destY
    else
      -- Ledge hops are land-only; skip on water.
      if surface ~= "water" then
        head.ledgeHop = self:ledgeStep(game, ow, head.x, head.y, stepDir)
                        and stepDir or nil
      else
        head.ledgeHop = nil
      end
      local goals = ow.pokepcTrailCells or {}
      for i = #trailers, 2, -1 do
        local prev = goals[i - 1]
        goals[i] = prev and { x = prev.x, y = prev.y }
          or { x = head.x, y = head.y }
      end
      if #trailers >= 1 then
        goals[1] = { x = head.x, y = head.y }
      end
      ow.pokepcTrailCells = goals
      head.x, head.y = destX, destY
    end
  elseif not mapEnter and not dirty then
    return
  end

  local Collision = tryRequire("src.world.Collision")
  local goals = ow.pokepcTrailCells or {}
  for i, npc in ipairs(trailers) do
    if npc.moving then
      -- Trailer update owns px/py mid-step; do not overwrite.
    else
      local cell = goals[i] or { x = anchor.cellX, y = anchor.cellY }
      local gx, gy = cell.x, cell.y
      local role = npc.wildsFollowerRole or "party_trailer"
      if not self:isFollowerCellAllowed(game, ow, npc, gx, gy, {
        surface = surface, role = role,
      }) then
        -- Goal invalid for this surface: re-pick a valid cell behind the player.
        gx, gy = self:_walkableBehind(ow, anchor.cellX or 0, anchor.cellY or 0,
                                      facing, i, npc, game, role)
        goals[i] = { x = gx, y = gy }
      end
      if npc.cellX ~= gx or npc.cellY ~= gy then
        local far = math.abs((npc.cellX or 0) - gx) + math.abs((npc.cellY or 0) - gy)
        if far > 6 then
          placeTrailerAt(npc, gx, gy, npc.facing or facing)
        else
          local dir
          if npc.cellX < gx then dir = "right"
          elseif npc.cellX > gx then dir = "left"
          elseif npc.cellY < gy then dir = "down"
          else dir = "up" end
          local stepX = npc.cellX + (dir == "right" and 1 or dir == "left" and -1 or 0)
          local stepY = npc.cellY + (dir == "down" and 1 or dir == "up" and -1 or 0)
          if not self:isFollowerCellAllowed(game, ow, npc, stepX, stepY, {
            surface = surface, role = role,
          }) then
            -- Adjacent step blocked: warp-distance catch-up only when far.
            if far > 2 then
              placeTrailerAt(npc, gx, gy, dir)
            end
          else
            npc.facing = dir
            npc.hopStep = nil
            npc.targetX = stepX
            npc.targetY = stepY
            if surface ~= "water"
               and self:ledgeStep(game, ow, npc.cellX, npc.cellY, dir)
               and Collision and Collision.DELTA and Collision.DELTA[dir] then
              local d = Collision.DELTA[dir]
              local hx, hy = npc.cellX + d[1] * 2, npc.cellY + d[2] * 2
              if self:isFollowerCellAllowed(game, ow, npc, hx, hy, {
                surface = surface, role = role,
              }) then
                npc.targetX = hx
                npc.targetY = hy
                goals[i] = { x = hx, y = hy }
                npc.hopStep = true
              end
            end
            local stepLen = stepClock
            if far > 1 and not npc.hopStep then
              stepLen = math.max(1, math.floor(stepLen / 2))
            end
            npc.stepFrames = stepLen
            npc.moving = true
            npc.progress = 0
            if opts.catchUp and npc.update then
              npc:update(ow.map, ow.entities)
            end
          end
        end
      end
    end
  end
end

function ControlEngine:_removeStockPikachu(ow)
  if not ow then return end
  for i = #(ow.npcs or {}), 1, -1 do
    local npc = ow.npcs[i]
    if npc and npc.pikachuFollower and not npc.pokepcTrailer then
      table.remove(ow.npcs, i)
      for j, e in ipairs(ow.entities or {}) do
        if e == npc then table.remove(ow.entities, j); break end
      end
    end
  end
end

function ControlEngine:alignSaveFromOptions(game)
  game = game or self:_game()
  if not (game and game.save) then return end
  local settings = self.settings
  if settings and type(settings.followerCount) == "function" then
    local ok, n = pcall(settings.followerCount, settings, game)
    if ok and type(n) == "number" then
      self:setFollowerCount(game, n)
    end
  else
    local n = tonumber(self:_opt("follower_count", 1))
    if type(n) == "number" then
      self:setFollowerCount(game, n)
    end
  end
  local savedMode = game.save.pokepcControlMode
  if type(savedMode) ~= "string" or savedMode == "" then
    local mode
    if settings and type(settings.engineMode) == "function" then
      local ok, m = pcall(settings.engineMode, settings, game)
      if ok then mode = m end
    end
    self:setControlMode(game, tostring(mode or self:_opt("control_mode", "follow")))
  end
end

function ControlEngine:syncAll(game, ow)
  game = game or self:_game()
  ow = ow or (game and game.overworld)
  if ow then pcall(function() self:removeTrailers(ow) end) end
  if self:_isYellow() and game and game.save
     and game.save.pokepcLeader and game.save.pokepcLeader.source == "party" then
    local mon = game.save.party
      and game.save.party[game.save.pokepcLeader.index]
    if mon then
      local idx = self:ensureYellowLeaderLayout(game, mon)
      if type(idx) == "number" then
        game.save.pokepcLeader.index = idx
        game.save.followerPartyIndex = idx
      end
    end
  end
  if self:isPokemonFront(game) and ow and ow.player then
    ow.player._pokepcControlSpecies = nil
  end
  pcall(function() self:syncPlayerControlVisual(game, ow, true) end)
  pcall(function() self:forceYellowStockPikachuArt(ow, game) end)
  pcall(function() self:syncTrailers(game, ow, { mapEnter = true, catchUp = true }) end)
end

function ControlEngine:_installTalkWrap()
  local OverworldState = tryRequire("src.world.OverworldController")
  if not (OverworldState and OverworldState.interact) then return false end
  if OverworldState._wildsControlEngineTalkWrap == OverworldState.interact then
    return true
  end
  local engine = self
  local origInteract = OverworldState.interact
  local function talkWrap(owSelf, ...)
    local p = owSelf.player
    if p and engine:_isYellow() then
      local Collision = tryRequire("src.world.Collision")
      local PF = tryRequire("src.world.PikachuFollower")
      local fx, fy = p:facingCell()
      local npc = owSelf:npcAtCell(fx, fy)
      if not npc and owSelf.map and owSelf.map.isCounterCell
         and owSelf.map:isCounterCell(fx, fy) and Collision and Collision.target then
        local fx2, fy2 = Collision.target(fx, fy, p.facing)
        npc = owSelf:npcAtCell(fx2, fy2)
      end
      if npc and npc.pokepcTrailer and (npc.pokepcTalkablePikachu
          or engine:isYellowPikachuTrailer(npc)) then
        if PF and PF.talk then
          PF.talk(engine:_game(), owSelf, npc)
        end
        return
      end
    end
    return origInteract(owSelf, ...)
  end
  OverworldState.interact = talkWrap
  OverworldState._wildsControlEngineTalkWrap = talkWrap
  self._talkOrigInteract = origInteract
  self._talkWrapped = true
  return true
end

function ControlEngine:_restoreTalkWrap()
  local OverworldState = tryRequire("src.world.OverworldController")
  if not OverworldState then return end
  if self._talkWrapped and OverworldState._wildsControlEngineTalkWrap
     and OverworldState.interact == OverworldState._wildsControlEngineTalkWrap
     and self._talkOrigInteract then
    OverworldState.interact = self._talkOrigInteract
    OverworldState._wildsControlEngineTalkWrap = nil
  end
  self._talkWrapped = false
  self._talkOrigInteract = nil
end

--- Install PikachuFollower hooks. Idempotent; restores previous on reinstall.
-- Returns false, "no_engine" when NPC/PikachuFollower are unavailable (tests).
function ControlEngine:install()
  if self._installed then
    self:restore()
  end

  local PF = tryRequire("src.world.PikachuFollower")
  local NPC = tryRequire("src.world.NPC")
  if not PF or not NPC then
    return false, "no_engine"
  end

  -- Hot-reload: restore any previous control-engine install first.
  local previous = rawget(PF, Constants.CONTROL_ENGINE_STATE_KEY)
  if previous and type(previous.restore) == "function" then
    pcall(previous.restore)
  end

  local engine = self
  local _, prevShouldSpawn = captureUpvalue(PF.onMapEntered, "shouldSpawn")
  if not prevShouldSpawn then
    _, prevShouldSpawn = captureUpvalue(PF.update, "shouldSpawn")
  end

  local function newShouldSpawn(game, ow)
    local mode = engine:controlMode(game)
    if mode == "pokemon" or mode == "lead_trainer" or mode == "pack" then
      return false
    end
    -- Pack trailers own the field (except Yellow stock talkable Pikachu).
    if mode == "follow" and engine:followerCount(game) > 0
       and not engine:yellowStockFollowActive(game) then
      return false
    end

    -- Standalone Red/Blue/Yellow follow (count 0, or Yellow stock): spawn when
    -- SPRITE_PIKACHU is registered and a healthy selection exists. Do not rely
    -- solely on vanilla shouldSpawn (Yellow-Pikachu-only).
    local save = game and game.save
    if not (save and ow) then return false end
    if not save.party or #save.party == 0 then return false end
    if save.onBike then return false end
    if ow.player and ow.player.surfing then return false end

    local hasSprite = false
    if engine.spriteService and engine.spriteService.hasSpritePikachu then
      hasSprite = engine.spriteService:hasSpritePikachu(game) == true
    end
    if not hasSprite then
      local sprites = game.data and game.data.sprites
      hasSprite = sprites ~= nil and sprites[Constants.SPRITE_ID] ~= nil
    end
    if not hasSprite then return false end

    local mon = engine:getActiveFollowerMon(game)
    if mon and (tonumber(mon.hp) or 0) > 0 then return true end
    return false
  end

  patchUpvalue(PF.update, "shouldSpawn", newShouldSpawn)
  patchUpvalue(PF.onMapEntered, "shouldSpawn", newShouldSpawn)

  local origFollowerUpdate = PF.update
  local origOnMap = PF.onMapEntered
  local origStarterInParty = PF.starterInParty

  local function wrappedUpdate(game, ow, ...)
    local result = origFollowerUpdate and origFollowerUpdate(game, ow, ...)
    if engine:isPokemonFront(game) then
      pcall(function() engine:_removeStockPikachu(ow) end)
    end
    pcall(function() engine:forceYellowStockPikachuArt(ow, game) end)
    pcall(function() engine:syncPlayerControlVisual(game, ow) end)
    if engine._pendingMapTrailerSync then
      engine._pendingMapTrailerSync = false
      pcall(function()
        engine:syncTrailers(game, ow, { mapEnter = true, catchUp = true })
      end)
    else
      pcall(function()
        engine:syncTrailers(game, ow, { catchUp = true })
      end)
    end
    return result
  end

  local function wrappedOnMapEntered(game, ow, opts)
    if origOnMap then origOnMap(game, ow, opts) end
    local mode = engine:controlMode(game)
    if mode == "pokemon" or mode == "lead_trainer" or mode == "pack" then
      pcall(function() engine:_removeStockPikachu(ow) end)
    else
      pcall(function() engine:forceYellowStockPikachuArt(ow, game) end)
    end
    engine._pendingMapTrailerSync = true
    pcall(function() engine:syncPlayerControlVisual(game, ow) end)
  end

  local function wrappedStarterInParty(save, needHealthy)
    for _, mon in ipairs(save and save.party or {}) do
      if not needHealthy or (mon.hp or 0) > 0 then return mon end
    end
    return nil
  end

  if origFollowerUpdate then PF.update = wrappedUpdate end
  if origOnMap then PF.onMapEntered = wrappedOnMapEntered end
  PF.starterInParty = wrappedStarterInParty

  pcall(function() self:_installTalkWrap() end)

  local mod = self.mod
  if mod and mod.events and mod.events.on then
    pcall(function()
      mod.events:on("mod.options_changed", function(payload)
        if payload and (payload.mod == mod.id) then
          engine._optCache = {}
        end
      end)
    end)
    pcall(function()
      mod.events:on("map.entered", function()
        local game = engine:_game()
        local ow = game and game.overworld
        pcall(function() engine:syncPlayerControlVisual(game, ow) end)
        engine._pendingMapTrailerSync = true
      end)
    end)
    pcall(function()
      mod.events:on("game.ready", function()
        local game = engine:_game()
        engine:alignSaveFromOptions(game)
        pcall(function()
          engine:syncPlayerControlVisual(game, game and game.overworld)
        end)
        engine._pendingMapTrailerSync = true
        pcall(function() engine:_installTalkWrap() end)
      end)
    end)
  end

  local restoreState = {
    originalUpdate = origFollowerUpdate,
    originalOnMapEntered = origOnMap,
    originalStarterInParty = origStarterInParty,
    originalShouldSpawn = prevShouldSpawn,
    wrapperUpdate = wrappedUpdate,
    wrapperOnMapEntered = wrappedOnMapEntered,
    wrapperStarterInParty = wrappedStarterInParty,
    engine = engine,
  }

  restoreState.restore = function()
    if origFollowerUpdate and prevShouldSpawn then
      patchUpvalue(origFollowerUpdate, "shouldSpawn", prevShouldSpawn)
    end
    if origOnMap and prevShouldSpawn then
      patchUpvalue(origOnMap, "shouldSpawn", prevShouldSpawn)
    end
    if PF.update == wrappedUpdate then PF.update = origFollowerUpdate end
    if PF.onMapEntered == wrappedOnMapEntered then PF.onMapEntered = origOnMap end
    if PF.starterInParty == wrappedStarterInParty then
      PF.starterInParty = origStarterInParty
    end
    engine:_restoreTalkWrap()
    if rawget(PF, Constants.CONTROL_ENGINE_STATE_KEY) == restoreState then
      rawset(PF, Constants.CONTROL_ENGINE_STATE_KEY, nil)
    end
    engine._installed = false
    engine._restoreState = nil
  end

  rawset(PF, Constants.CONTROL_ENGINE_STATE_KEY, restoreState)
  self._restoreState = restoreState
  self._installed = true

  pcall(function() self:alignSaveFromOptions(self:_game()) end)
  logInfo(self.mod, "control engine installed (hooks owned by ControlEngine)")
  return true, "installed"
end

function ControlEngine:restore()
  if self._restoreState and type(self._restoreState.restore) == "function" then
    pcall(self._restoreState.restore)
  end
  self._installed = false
  self._restoreState = nil
end

return ControlEngine
