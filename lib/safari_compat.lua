-- Safari Zone compatibility: session detection, native encounter routing,
-- behaviour selection helpers, and safe Vanilla fallback.
--
-- Visible Safari Pokémon never start normal wild battles. Contact uses the
-- engine's BattleState:makeSafari path (BALL / BAIT / ROCK / RUN) when a real
-- Safari session is active. Outside an active session this module is inert.
local V = ...

local SafariCompat = {}

SafariCompat.STATUS = {
  INACTIVE = "INACTIVE",
  ACTIVE = "ACTIVE",
  FALLBACK_VANILLA = "FALLBACK_VANILLA",
}

-- Land Safari behaviour distribution (percentages → weights).
SafariCompat.LAND_WEIGHTS = {
  SAFARI_IDLE = 35,
  SAFARI_WANDER = 40,
  SAFARI_FLEE = 25,
}

-- Water Safari: no flee (no new water pathfinding). Idle / wander only.
SafariCompat.WATER_WEIGHTS = {
  WATER_IDLE = 45,
  WATER_WANDER = 55,
}

-- Species temperament for SAFARI_FLEE selection (multipliers on base weight).
-- Only applied during an active Safari session.
SafariCompat.SAFARI_FLEE_AFFINITY = {
  CHANSEY = 1.6,
  TAUROS = 1.3,
  SCYTHER = 1.4,
  PINSIR = 1.3,
  EXEGGCUTE = 0.7,
  RHYHORN = 0.6,
  KANGASKHAN = 1.2,
  DODUO = 1.4,
  DODRIO = 1.5,
  VENONAT = 0.8,
  PARASECT = 0.7,
  NIDOQUEEN = 0.8,
  NIDOKING = 0.8,
}

SafariCompat.SIGHT_RANGE = 4          -- tiles (within recommended 3–5)
SafariCompat.ALERT_FRAMES = 24        -- ~0.40s at 60 fps (0.25–0.50 window)
SafariCompat.FLEE_STEPS_MIN = 2
SafariCompat.FLEE_STEPS_MAX = 5
SafariCompat.FLEE_COOLDOWN_MIN = 3.0  -- seconds
SafariCompat.FLEE_COOLDOWN_MAX = 6.0
SafariCompat.ALERT_TIMEOUT = 1.2      -- fail-safe if emote onDone never fires

-- Verified Safari Zone map id prefixes / known interior ids.
local SAFARI_MAP_PREFIX = "SAFARI_ZONE"
local KNOWN_SAFARI_MAPS = {
  SAFARI_ZONE_CENTER = true,
  SAFARI_ZONE_EAST = true,
  SAFARI_ZONE_NORTH = true,
  SAFARI_ZONE_WEST = true,
  SAFARI_ZONE_CENTER_REST_HOUSE = true,
  SAFARI_ZONE_EAST_REST_HOUSE = true,
  SAFARI_ZONE_NORTH_REST_HOUSE = true,
  SAFARI_ZONE_WEST_REST_HOUSE = true,
  SAFARI_ZONE_SECRET_HOUSE = true,
  SAFARI_ZONE_GATE = true,
}

local _nativeProbe = nil -- cached { ok = bool, reason = string }

local function mapDefOf(game, overworld, mapId)
  if overworld and overworld.map then
    if overworld.map.def then return overworld.map.def end
    if overworld.map.id and (mapId == nil or overworld.map.id == mapId) then
      return {
        id = overworld.map.id,
        region = overworld.map.region or (overworld.map.def and overworld.map.def.region),
        label = overworld.map.label,
        name = overworld.map.name,
      }
    end
  end
  local maps = game and game.data and game.data.maps
  local def = maps and mapId and maps[mapId]
  if def then
    if not def.id then
      -- shallow copy so we never mutate content registries
      local copy = {}
      for k, v in pairs(def) do copy[k] = v end
      copy.id = mapId
      return copy
    end
    return def
  end
  if mapId then
    return { id = tostring(mapId) }
  end
  return nil
end

local function tryMapInRegion(def)
  if not def then return false end
  local ok, Map = pcall(require, "src.world.Map")
  if ok and Map and type(Map.inRegion) == "function" then
    local fine, hit = pcall(Map.inRegion, def, "SAFARI", "SAFARI_ZONE")
    if fine then return hit == true end
  end
  return nil -- unknown; caller falls back
end

-- Verified Safari map: native Map.inRegion, known id table, or SAFARI_ZONE* id.
-- Does NOT treat arbitrary "Safari" substrings in labels as sufficient alone.
function SafariCompat.isSafariMap(game, mapId, overworld)
  local def = mapDefOf(game, overworld, mapId)
  local id = tostring((def and def.id) or mapId or "")
  if id == "" then return false end

  local regionHit = tryMapInRegion(def)
  if regionHit == true then return true end
  if regionHit == false and def and def.region ~= nil then
    -- Explicit non-SAFARI region wins over id prefix.
    return false
  end

  if KNOWN_SAFARI_MAPS[id] then return true end
  if id:find(SAFARI_MAP_PREFIX, 1, true) == 1 then return true end
  return false
end

function SafariCompat.sessionState(game)
  if not game or not game.save then return nil end
  local st = game.save.safari
  if type(st) ~= "table" then return nil end
  -- Prefer native session fields (balls / steps). Presence of the table is
  -- the engine's Safari-session flag (see data/scripts/safari.lua).
  if st.balls == nil and st.steps == nil and st.Balls == nil then
    -- Unknown shape: still treat non-empty table as a session candidate.
    local n = 0
    for _ in pairs(st) do n = n + 1 end
    if n == 0 then return nil end
  end
  return st
end

-- Central Safari-session gate used by behaviour, battle, and encounter rules.
function SafariCompat.isActive(game, overworld, mapId)
  if not SafariCompat.sessionState(game) then return false end
  local id = mapId
  if (not id or id == "") and overworld and overworld.map then
    id = overworld.map.id
  end
  return SafariCompat.isSafariMap(game, id, overworld)
end

-- Probe whether BattleState.newWild + makeSafari + pushBattle are available.
-- Result is cached for the process lifetime (engine APIs do not change mid-run).
function SafariCompat.probeNativePath(opts)
  opts = opts or {}
  if _nativeProbe and not opts.force then
    return _nativeProbe.ok, _nativeProbe.reason
  end
  local okReq, BattleState = pcall(require, "src.battle.BattleState")
  if not okReq or type(BattleState) ~= "table" then
    _nativeProbe = { ok = false, reason = "BattleState unavailable" }
    return false, _nativeProbe.reason
  end
  if type(BattleState.newWild) ~= "function" then
    _nativeProbe = { ok = false, reason = "BattleState.newWild missing" }
    return false, _nativeProbe.reason
  end
  -- makeSafari lives on the instance prototype / metatable.
  local proto = BattleState
  local mt = getmetatable(BattleState)
  if mt and type(mt.__index) == "table" then proto = mt.__index end
  if type(BattleState.makeSafari) ~= "function"
     and type(proto.makeSafari) ~= "function" then
    -- Also accept instances created later having the method via __index.
    local sample = BattleState
    if type(sample.makeSafari) ~= "function" then
      _nativeProbe = { ok = false, reason = "BattleState:makeSafari missing" }
      return false, _nativeProbe.reason
    end
  end
  _nativeProbe = { ok = true, reason = "ok" }
  return true, "ok"
end

-- Allow tests to inject / reset the native-path probe.
function SafariCompat.setNativePathProbe(ok, reason)
  if ok == nil then
    _nativeProbe = nil
    return
  end
  _nativeProbe = { ok = ok == true, reason = reason or (ok and "ok" or "forced") }
end

function SafariCompat.hasNativeSafariEncounter()
  local ok = SafariCompat.probeNativePath()
  return ok == true
end

-- Evaluate Safari compatibility status for the current map/session.
function SafariCompat.status(game, overworld, mapId)
  if not SafariCompat.isSafariMap(game, mapId, overworld) then
    return SafariCompat.STATUS.INACTIVE
  end
  if not SafariCompat.sessionState(game) then
    return SafariCompat.STATUS.INACTIVE
  end
  if not SafariCompat.hasNativeSafariEncounter() then
    return SafariCompat.STATUS.FALLBACK_VANILLA
  end
  return SafariCompat.STATUS.ACTIVE
end

function SafariCompat.shouldSpawnVisible(game, overworld, mapId)
  return SafariCompat.status(game, overworld, mapId) == SafariCompat.STATUS.ACTIVE
end

-- During ACTIVE Safari: always suppress classic step encounters so the player
-- can pursue visible Pokémon. FALLBACK_VANILLA / inactive leave Random Enc alone.
function SafariCompat.shouldSuppressClassicEncounters(game, overworld, mapId)
  return SafariCompat.status(game, overworld, mapId) == SafariCompat.STATUS.ACTIVE
end

-- Start a native Safari encounter (BALL/BAIT/ROCK/RUN). Never queues a normal
-- wild battle and never mutates catch/flee rates beyond makeSafari defaults.
function SafariCompat.startNativeSafariEncounter(game, overworld, species, level, opts)
  opts = opts or {}
  local session = opts.safari or SafariCompat.sessionState(game)
  if not session then
    return false, "no safari session"
  end
  local okPath, why = SafariCompat.probeNativePath()
  if not okPath then
    return false, why or "native safari path unavailable"
  end
  local okReq, BattleState = pcall(require, "src.battle.BattleState")
  if not okReq or not BattleState or type(BattleState.newWild) ~= "function" then
    return false, "BattleState.newWild unavailable"
  end

  local okNew, battle = pcall(BattleState.newWild, game, species, level)
  if not okNew or not battle then
    return false, "newWild failed: " .. tostring(battle)
  end
  if type(battle.makeSafari) ~= "function" then
    return false, "battle:makeSafari unavailable"
  end
  local okMake, makeErr = pcall(function()
    battle:makeSafari(session)
  end)
  if not okMake then
    return false, "makeSafari failed: " .. tostring(makeErr)
  end
  if not battle.safari then
    return false, "makeSafari did not attach safari state"
  end

  battle.onFinish = function(result)
    if overworld and type(overworld.afterBattle) == "function" then
      pcall(overworld.afterBattle, overworld, result, battle)
    end
    if type(opts.onFinish) == "function" then
      pcall(opts.onFinish, result, battle)
    end
  end

  if overworld and type(overworld.pushBattle) == "function" then
    local okPush, pushErr = pcall(overworld.pushBattle, overworld, battle)
    if not okPush then
      return false, "pushBattle failed: " .. tostring(pushErr)
    end
    return true, battle
  end
  if game and game.stack and type(game.stack.push) == "function" then
    local okPush, pushErr = pcall(game.stack.push, game.stack, battle)
    if not okPush then
      return false, "stack.push failed: " .. tostring(pushErr)
    end
    return true, battle
  end
  return false, "no battle push path"
end

function SafariCompat.fleeAffinity(species)
  if not species then return 1 end
  return SafariCompat.SAFARI_FLEE_AFFINITY[species] or 1
end

function SafariCompat.randomRangeInt(rng, lo, hi)
  rng = rng or math.random
  lo = math.floor(lo)
  hi = math.floor(hi)
  if hi < lo then lo, hi = hi, lo end
  if type(rng) == "function" then
    -- Prefer integer form rng(n) / rng(lo, hi) when available.
    local ok, a = pcall(rng, lo, hi)
    if ok and type(a) == "number" and a >= lo and a <= hi then
      return math.floor(a)
    end
    local ok2, b = pcall(rng, hi - lo + 1)
    if ok2 and type(b) == "number" then
      return lo + (math.floor(b) - 1) % (hi - lo + 1)
    end
    local ok3, u = pcall(rng)
    if ok3 and type(u) == "number" then
      if u >= 0 and u < 1 then
        return lo + math.floor(u * (hi - lo + 1))
      end
      return lo + (math.floor(u) - 1) % (hi - lo + 1)
    end
  end
  return lo + math.floor(math.random() * (hi - lo + 1))
end

function SafariCompat.randomRangeFloat(rng, lo, hi)
  rng = rng or math.random
  local u
  if type(rng) == "function" then
    local ok, v = pcall(rng)
    if ok and type(v) == "number" then
      if v >= 0 and v < 1 then u = v
      else u = (math.floor(v) % 10000) / 10000 end
    end
  end
  if not u then u = math.random() end
  return lo + (hi - lo) * u
end

return SafariCompat
