-- Structured NPC / player context for AI dialogues (GameCompat only).
local V = ...
local GameCompat = V.require("game_compat")
local Memory = V.require("ai/memory")

local ContextBuilder = {}

-- Conservative local blurbs (safe, non-spoiler).
local LOCAL_KNOWLEDGE = {
  PEWTER_CITY = "Pewter City is known for its museum and Brocks Gym.",
  PEWTER = "Pewter City is known for its museum and Brocks Gym.",
  VIRIDIAN_CITY = "Viridian City sits near the Indigo Plateau road.",
  PALLET_TOWN = "A quiet town. Professor Oak researchs Pokémon here.",
  CERULEAN_CITY = "Cerulean is famous for its Gym and nearby cave.",
  NEW_BARK = "New Bark Town is where many Johto journeys begin.",
  NEW_BARK_TOWN = "New Bark Town is where many Johto journeys begin.",
  VIOLET_CITY = "Violet City has a Sprout Tower and a Gym.",
  GOLDENROD = "Goldenrod is a busy Johto city with a large Department Store.",
}

-- Story-critical / cutscene-heavy ids — AI offer skipped (M6).
ContextBuilder.DENY_NPC_NAMES = {
  oak = true,
  profoak = true,
  professoroak = true,
  rival = true,
  blue = true,
  gary = true,
  elm = true,
  mom = true,
}

local function lower(s)
  return tostring(s or ""):lower()
end

local function partySummary(game)
  local party = GameCompat.party(game)
  if type(party) ~= "table" then return nil end
  local parts = {}
  for i = 1, math.min(6, #party) do
    local mon = party[i]
    if type(mon) == "table" then
      local sp = mon.species or mon.name or "?"
      local lv = mon.level or mon.lvl
      if lv then
        parts[#parts + 1] = tostring(sp) .. " Lv" .. tostring(lv)
      else
        parts[#parts + 1] = tostring(sp)
      end
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, ", ")
end

local function teamSummary(npc)
  local team = npc and (npc.team or (npc.def and npc.def.team) or (npc.def and npc.def.party))
  if type(team) ~= "table" then return nil end
  local parts = {}
  for i = 1, math.min(6, #team) do
    local mon = team[i]
    if type(mon) == "table" then
      local sp = mon.species or mon[1] or "?"
      local lv = mon.level or mon[2]
      parts[#parts + 1] = lv and (tostring(sp) .. " Lv" .. tostring(lv)) or tostring(sp)
    elseif type(mon) == "string" then
      parts[#parts + 1] = mon
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, ", ")
end

local function badgesSummary(game)
  local save = game and game.save
  if not save then return nil end
  if type(save.badges) == "table" then
    local n = 0
    for _, v in pairs(save.badges) do if v then n = n + 1 end end
    return tostring(n) .. " badge(s)"
  end
  if type(save.badgeCount) == "number" then
    return tostring(save.badgeCount) .. " badge(s)"
  end
  return nil
end

local function followerSummary(mod, game)
  local follower = mod and mod._wildsAiFollower
  if not follower and _G and _G._wildsAiFollowerRef then
    follower = _G._wildsAiFollowerRef
  end
  -- Prefer selection snapshot when installed.
  if follower and follower.selection and type(follower.selection.snapshot) == "function" then
    local ok, snap = pcall(follower.selection.snapshot, follower.selection)
    if ok and type(snap) == "table" and snap.species then
      return tostring(snap.species)
    end
  end
  if follower and follower.state and follower.state.selectedMonKey then
    return tostring(follower.state.selectedMonKey)
  end
  -- Party lead fallback
  local party = GameCompat.party(game)
  if type(party) == "table" and party[1] and party[1].species then
    return tostring(party[1].species) .. " (party lead)"
  end
  return nil
end

local function mapIdOf(mod, game, ow)
  ow = ow or GameCompat.liveOverworld(mod, game)
  local id = GameCompat.currentMapId(game, ow)
  if id then return tostring(id) end
  if ow and ow.map and ow.map.id then return tostring(ow.map.id) end
  return "UNKNOWN"
end

local function regionFor(generation, mapId)
  if generation == 2 then
    local m = lower(mapId)
    if m:find("kanto", 1, true) then return "Kanto" end
    return "Johto"
  end
  return "Kanto"
end

local function localKnowledge(mapId)
  if not mapId then return nil end
  local key = tostring(mapId)
  if LOCAL_KNOWLEDGE[key] then return LOCAL_KNOWLEDGE[key] end
  local upper = key:upper()
  if LOCAL_KNOWLEDGE[upper] then return LOCAL_KNOWLEDGE[upper] end
  for k, v in pairs(LOCAL_KNOWLEDGE) do
    if upper:find(k, 1, true) then return v end
  end
  return nil
end

function ContextBuilder.npcIdentity(npc, mapId)
  if not npc then return "unknown" end
  local def = npc.def or {}
  local parts = {
    tostring(mapId or "?"),
    tostring(def.index or def.id or def.name or npc.name or npc.id or "npc"),
  }
  if def.trainerId or npc.trainerId then
    parts[#parts + 1] = "t" .. tostring(def.trainerId or npc.trainerId)
  end
  return table.concat(parts, ":")
end

function ContextBuilder.npcDisplayName(npc)
  if not npc then return "Someone" end
  local def = npc.def or {}
  local name = def.name or npc.name or def.trainerName or npc.trainerName
  if type(name) == "string" and name ~= "" then return name end
  local class = def.trainerClass or def.class or npc.trainerClass or npc.class
  if type(class) == "string" and class ~= "" then
    return class
  end
  if def.objectName then return tostring(def.objectName) end
  return "Someone"
end

function ContextBuilder.isDenied(npc)
  local name = lower(ContextBuilder.npcDisplayName(npc))
  name = name:gsub("%s+", "")
  if ContextBuilder.DENY_NPC_NAMES[name] then return true end
  local def = npc and npc.def
  if def then
    local id = lower(def.id or def.script or def.event or "")
    for deny in pairs(ContextBuilder.DENY_NPC_NAMES) do
      if id:find(deny, 1, true) then return true end
    end
  end
  return false
end

--- Pewter vertical-slice helper: prefer safe non-story Pewter NPCs.
function ContextBuilder.isPewterSliceNpc(npc, mapId)
  local m = lower(mapId)
  if not (m:find("pewter", 1, true)) then return false end
  if ContextBuilder.isDenied(npc) then return false end
  if npc and npc.wildsAmbientPokemon then return false end
  return true
end

function ContextBuilder.build(mod, game, ow, npc, opts)
  opts = opts or {}
  ow = ow or GameCompat.liveOverworld(mod, game)
  local generation = GameCompat.generation(mod, game) or 1
  local mapId = mapIdOf(mod, game, ow)
  local npcName = ContextBuilder.npcDisplayName(npc)
  local def = npc and npc.def or {}
  local trainerClass = def.trainerClass or def.class or npc and npc.trainerClass
  local battled = npc and (npc.battled or npc.fought)
  if battled == nil and def then battled = def.battled end
  local defeated = npc and (npc.defeated or npc.beaten)
  if defeated == nil and def then defeated = def.defeated end

  local ctx = {
    generation = generation,
    gameVersion = GameCompat.gameVersion(game),
    region = regionFor(generation, mapId),
    mapId = mapId,
    locationName = (ow and ow.map and (ow.map.name or ow.map.id)) or mapId,
    npcId = ContextBuilder.npcIdentity(npc, mapId),
    npcName = npcName,
    trainerClass = trainerClass,
    role = trainerClass or (def.role) or "townsperson",
    teamSummary = teamSummary(npc),
    battled = battled,
    defeated = defeated,
    localKnowledge = localKnowledge(mapId),
    storyHints = nil,
    playerPartySummary = partySummary(game),
    followerSummary = followerSummary(mod, game),
    badgesSummary = badgesSummary(game),
    priorTurns = {},
  }

  if not opts.skipMemory then
    ctx.priorTurns = Memory.getTurns(mod, game, ctx.npcId)
  end

  return ctx
end

return ContextBuilder
