-- Hidden Idle grass encounters: cell reservations, density targets, reveal timing.
-- Independent of the visible spawn mix and of legacy HIDDEN_GRASS behaviour.
-- Only applies on grass surfaces; caves and water are untouched.
local V = ...
local Config = V.require("config")
local Behavior = V.require("behavior")
local Grass = V.require("grass")

local HiddenIdle = {}

-- Midpoints of the recommended density bands (no public fine-tune).
HiddenIdle.RATIO_HIDDEN = 0.30 -- ~30 %
HiddenIdle.RATIO_BOTH = 0.15   -- ~15 %
HiddenIdle.MIN_SEPARATION = 4  -- Chebyshev tiles between reserved cells
HiddenIdle.RUSTLE_MIN = 1.5
HiddenIdle.RUSTLE_MAX = 4.0

-- Reveal timeline (seconds from trigger).
HiddenIdle.REVEAL = {
  RUSTLE_END = 0.15,
  VISIBLE_AT = 0.15,
  HOP_START = 0.30,
  HOP_END = 0.45,
  BATTLE_AT = 0.45,
}

local function now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

local function rngOf(rng)
  if type(rng) == "function" then return rng end
  if love and love.math and love.math.random then return love.math.random end
  return math.random
end

local function cellKey(x, y)
  return tostring(x) .. "," .. tostring(y)
end

function HiddenIdle.ratioForMode(mode)
  mode = tostring(mode or "hidden")
  if mode == "classic" then return 0 end
  if mode == "both" then return HiddenIdle.RATIO_BOTH end
  return HiddenIdle.RATIO_HIDDEN
end

function HiddenIdle.targetCount(normalTarget, mode)
  local ratio = HiddenIdle.ratioForMode(mode)
  if ratio <= 0 then return 0 end
  local n = tonumber(normalTarget) or 0
  if n <= 0 then return 0 end
  local want = math.floor(n * ratio + 0.5)
  if want < 1 and n >= 1 and mode ~= "classic" then
    want = 1
  end
  return want
end

function HiddenIdle.randomRustleDelay(rng)
  rng = rngOf(rng)
  local span = HiddenIdle.RUSTLE_MAX - HiddenIdle.RUSTLE_MIN
  local roll = rng()
  if type(roll) ~= "number" then
    roll = ((rng(1000) - 1) / 1000)
  end
  return HiddenIdle.RUSTLE_MIN + roll * span
end

function HiddenIdle.newState(rng)
  return {
    active = true,
    revealed = false,
    revealStarted = false,
    revealElapsed = 0,
    rustleTimer = 0,
    nextRustle = HiddenIdle.randomRustleDelay(rng),
    battleStarted = false,
    strongRustle = false,
    hopActive = false,
  }
end

function HiddenIdle.isEntity(entity)
  if not entity then return false end
  if entity.behavior == Behavior.HIDDEN_IDLE then return true end
  if entity.hiddenIdle and entity.hiddenIdle.active then return true end
  return false
end

function HiddenIdle.isUnrevealed(entity)
  if not HiddenIdle.isEntity(entity) then return false end
  local hi = entity.hiddenIdle
  if not hi or not hi.active then return false end
  return hi.revealed ~= true
end

function HiddenIdle.bodyHidden(entity)
  return HiddenIdle.isUnrevealed(entity)
end

-- ------- reservation table helpers (owned by SpawnLogic) -------

function HiddenIdle.initReservations(logic)
  logic.hiddenReserved = logic.hiddenReserved or {}
  logic.targetHiddenCount = logic.targetHiddenCount or 0
end

function HiddenIdle.reserve(logic, x, y, id)
  HiddenIdle.initReservations(logic)
  if x == nil or y == nil or not id then return false end
  local key = cellKey(x, y)
  local existing = logic.hiddenReserved[key]
  if existing and existing ~= id then return false end
  logic.hiddenReserved[key] = id
  return true
end

function HiddenIdle.release(logic, x, y, id)
  if not logic or not logic.hiddenReserved then return end
  if x == nil or y == nil then return end
  local key = cellKey(x, y)
  if id == nil or logic.hiddenReserved[key] == id then
    logic.hiddenReserved[key] = nil
  end
end

function HiddenIdle.releaseAllForId(logic, id)
  if not logic or not logic.hiddenReserved or not id then return end
  for key, reservedId in pairs(logic.hiddenReserved) do
    if reservedId == id then
      logic.hiddenReserved[key] = nil
    end
  end
end

function HiddenIdle.clearAll(logic)
  if not logic then return end
  logic.hiddenReserved = {}
  logic.targetHiddenCount = 0
end

function HiddenIdle.isReserved(logic, x, y)
  if not logic or not logic.hiddenReserved then return false end
  return logic.hiddenReserved[cellKey(x, y)] ~= nil
end

function HiddenIdle.reservedId(logic, x, y)
  if not logic or not logic.hiddenReserved then return nil end
  return logic.hiddenReserved[cellKey(x, y)]
end

function HiddenIdle.reservedCount(logic)
  local n = 0
  if not logic or not logic.hiddenReserved then return 0 end
  for _ in pairs(logic.hiddenReserved) do n = n + 1 end
  return n
end

function HiddenIdle.countEntities(logic, mapId)
  local n = 0
  local revealed = 0
  local list = mapId and logic.byMap[mapId] or nil
  if list then
    for _, id in ipairs(list) do
      local record = logic.spawns[id]
      local entity = logic.entities[id]
      if record and record.state == Config.STATE.AVAILABLE
         and record.behavior == Behavior.HIDDEN_IDLE then
        n = n + 1
        if entity and entity.hiddenIdle and entity.hiddenIdle.revealed then
          revealed = revealed + 1
        end
      end
    end
  else
    for id, record in pairs(logic.spawns or {}) do
      if record and record.state == Config.STATE.AVAILABLE
         and record.behavior == Behavior.HIDDEN_IDLE then
        n = n + 1
        local entity = logic.entities[id]
        if entity and entity.hiddenIdle and entity.hiddenIdle.revealed then
          revealed = revealed + 1
        end
      end
    end
  end
  return n, revealed
end

local function tooCloseToReserved(logic, x, y, minSep)
  if not logic or not logic.hiddenReserved then return false end
  for key in pairs(logic.hiddenReserved) do
    local sx, sy = key:match("^(%-?%d+),(%-?%d+)$")
    sx, sy = tonumber(sx), tonumber(sy)
    if sx and sy and Grass.chebyshev(x, y, sx, sy) < minSep then
      return true
    end
  end
  return false
end

-- Validate a grass cell for a new Hidden Idle reservation.
function HiddenIdle.validateCell(map, entities, player, logic, x, y, ignore)
  local ok, reason = Grass.validateSpawnTile(
    map, entities, player, x, y, 1, nil, ignore)
  if not ok then return false, reason end
  if HiddenIdle.isReserved(logic, x, y) then
    return false, "rejected: already reserved"
  end
  if tooCloseToReserved(logic, x, y, HiddenIdle.MIN_SEPARATION) then
    return false, "rejected: too close to reserved"
  end
  return true, nil
end

function HiddenIdle.pickCell(map, entities, player, logic, grassList, rng, onReject)
  grassList = grassList or Grass.cells(map)
  rng = rngOf(rng)
  if #grassList == 0 then
    if onReject then onReject("rejected: not encounter tile") end
    return nil, nil, "rejected: not encounter tile"
  end

  local candidates = {}
  for _, cell in ipairs(grassList) do
    local ok, reason = HiddenIdle.validateCell(
      map, entities, player, logic, cell.x, cell.y, nil)
    if ok then
      candidates[#candidates + 1] = cell
    elseif onReject and reason then
      onReject(reason)
    end
  end

  -- Relax separation if nothing available.
  if #candidates == 0 then
    for _, cell in ipairs(grassList) do
      local ok = Grass.validateSpawnTile(
        map, entities, player, cell.x, cell.y, 1, nil, nil)
      if ok and not HiddenIdle.isReserved(logic, cell.x, cell.y) then
        candidates[#candidates + 1] = cell
      end
    end
  end

  if #candidates == 0 then
    return nil, nil, "rejected: no eligible tiles"
  end

  local pick = candidates[rng(#candidates)]
  return pick.x, pick.y, nil
end

-- Advance rustle / reveal state. Returns event string or nil.
-- Events: "rustle", "reveal_visible", "reveal_hop", "reveal_battle"
function HiddenIdle.tick(entity, dt, rng)
  if not entity or not entity.hiddenIdle then return nil end
  local hi = entity.hiddenIdle
  if not hi.active then return nil end
  rng = rngOf(rng)
  dt = tonumber(dt) or 0.016
  if dt < 0 then dt = 0 end
  if dt > 0.1 then dt = 0.1 end

  if hi.revealStarted then
    hi.revealElapsed = (hi.revealElapsed or 0) + dt
    local t = hi.revealElapsed
    local R = HiddenIdle.REVEAL

    hi.strongRustle = t < R.RUSTLE_END
    entity.grassEffectActive = t < R.VISIBLE_AT + 0.05
    entity.canTriggerBattle = false

    if t >= R.VISIBLE_AT and not hi.revealed then
      hi.revealed = true
      entity.visibleSprite = true
      entity.hiddenEncounter = false
      return "reveal_visible"
    end

    if t >= R.HOP_START and t < R.HOP_END then
      hi.hopActive = true
      entity.hopping = true
      local progress = (t - R.HOP_START) / (R.HOP_END - R.HOP_START)
      entity._revealHopPx = math.sin(progress * math.pi) * 4
      if not hi._hopEventSent then
        hi._hopEventSent = true
        return "reveal_hop"
      end
      return nil
    else
      hi.hopActive = false
      entity.hopping = false
      entity._revealHopPx = 0
    end

    if t >= R.BATTLE_AT then
      if not hi.battleStarted then
        return "reveal_battle"
      end
    end
    return nil
  end

  -- Idle lurk: periodic native rustle only.
  entity.canTriggerBattle = false
  hi.rustleTimer = (hi.rustleTimer or 0) + dt
  if entity.grassEffectUntil and now() > entity.grassEffectUntil then
    entity.grassEffectActive = false
    hi.strongRustle = false
  end
  if hi.rustleTimer >= (hi.nextRustle or HiddenIdle.RUSTLE_MIN) then
    hi.rustleTimer = 0
    hi.nextRustle = HiddenIdle.randomRustleDelay(rng)
    hi.strongRustle = false
    entity.grassEffectActive = true
    entity.grassEffectUntil = now() + 0.35
    local bx = entity.behaviorState
    if bx then
      bx.shakePhase = (bx.shakePhase or 0) + 1
      bx.shakeNextAt = now() + hi.nextRustle
    end
    return "rustle"
  end
  return nil
end

function HiddenIdle.beginReveal(entity)
  if not entity or not entity.hiddenIdle then return false end
  local hi = entity.hiddenIdle
  if hi.revealStarted or hi.battleStarted then return false end
  hi.revealStarted = true
  hi.revealElapsed = 0
  hi.strongRustle = true
  entity.canTriggerBattle = false
  entity.grassEffectActive = true
  entity.grassEffectUntil = now() + HiddenIdle.REVEAL.RUSTLE_END
  return true
end

function HiddenIdle.markBattleStarted(entity)
  if not entity or not entity.hiddenIdle then return end
  entity.hiddenIdle.battleStarted = true
  entity.canTriggerBattle = false
end

function HiddenIdle.statusLines(entity)
  local lines = {}
  if not HiddenIdle.isEntity(entity) then return lines end
  local hi = entity.hiddenIdle or {}
  local SpawnFx = V.require("spawn_fx")
  lines[#lines + 1] = ("Behaviour: %s"):format(Behavior.HIDDEN_IDLE)
  lines[#lines + 1] = ("Surface: GRASS")
  lines[#lines + 1] = ("Hidden: %s"):format(hi.active and "YES" or "NO")
  lines[#lines + 1] = ("Revealed: %s"):format(hi.revealed and "YES" or "NO")
  lines[#lines + 1] = ("Reveal started: %s"):format(
    hi.revealStarted and "YES" or "NO")
  lines[#lines + 1] = ("Battle started: %s"):format(
    hi.battleStarted and "YES" or "NO")
  lines[#lines + 1] = ("Body Visible: %s"):format(
    SpawnFx.bodyVisible(entity) and "YES" or "NO")
  lines[#lines + 1] = ("Can Act: %s"):format(SpawnFx.canAct(entity) and "YES" or "NO")
  lines[#lines + 1] = ("Can Battle: %s"):format(SpawnFx.canBattle(entity) and "YES" or "NO")
  local fx = entity.spawnFx
  lines[#lines + 1] = ("Spawn FX: %s"):format(
    fx and tostring(fx.kind or "?"):upper() or "NONE")
  if not hi.revealStarted then
    local remaining = (hi.nextRustle or 0) - (hi.rustleElapsed or hi.rustleTimer or 0)
    if remaining < 0 then remaining = 0 end
    lines[#lines + 1] = ("Next rustle: %.1fs"):format(remaining)
  else
    lines[#lines + 1] = ("Reveal t: %.2fs"):format(hi.revealElapsed or 0)
  end
  lines[#lines + 1] = ("Cell: %s,%s"):format(
    tostring(entity.cellX), tostring(entity.cellY))
  return lines
end

function HiddenIdle.hudSummary(logic)
  local mode = Config.grassEncounters(logic.mod)
  local classicOn = (mode == "classic" or mode == "both")
  local loaded, revealed = HiddenIdle.countEntities(logic, logic.activeMapId)
  return {
    mode = mode,
    classicOn = classicOn,
    target = logic.targetHiddenCount or 0,
    loaded = loaded,
    revealed = revealed,
    reserved = HiddenIdle.reservedCount(logic),
  }
end

return HiddenIdle
