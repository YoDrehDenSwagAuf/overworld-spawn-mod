-- Bounded conversation memory in Wilds private user data (not Pokémon saves).
local V = ...
local AiConfig = V.require("ai/config")
local AiLog = V.require("ai/log")

local Memory = {}
Memory.MAX_TURNS_PER_NPC = 6
Memory.MAX_NPCS = 32
Memory.STORAGE_KEY = "ai_dialogue_memory_v1"

local _ram = { npcs = {} } -- fallback when mod.storage unavailable

local function storageWrite(mod, game, key, value)
  if mod and mod.storage and type(mod.storage.write) == "function" and game then
    local ok = pcall(mod.storage.write, mod.storage, game, key, value)
    if ok then return true end
  end
  _ram[key] = value
  return true
end

local function storageRead(mod, game, key)
  if mod and mod.storage and type(mod.storage.read) == "function" and game then
    local ok, value = pcall(mod.storage.read, mod.storage, game, key)
    if ok and type(value) == "table" then return value end
  end
  return _ram[key]
end

local function bucket(mod, game)
  local data = storageRead(mod, game, Memory.STORAGE_KEY)
  if type(data) ~= "table" or type(data.npcs) ~= "table" then
    data = { npcs = {} }
  end
  return data
end

local function persist(mod, game, data)
  -- Cap NPC entries
  local ids = {}
  for id in pairs(data.npcs) do ids[#ids + 1] = id end
  if #ids > Memory.MAX_NPCS then
    table.sort(ids, function(a, b)
      local ta = (data.npcs[a] and data.npcs[a].updated) or 0
      local tb = (data.npcs[b] and data.npcs[b].updated) or 0
      return ta < tb
    end)
    for i = 1, #ids - Memory.MAX_NPCS do
      data.npcs[ids[i]] = nil
    end
  end
  storageWrite(mod, game, Memory.STORAGE_KEY, data)
end

function Memory.getTurns(mod, game, npcId)
  if not AiConfig.memoryEnabled(mod) then return {} end
  if type(npcId) ~= "string" or npcId == "" then return {} end
  local data = bucket(mod, game)
  local entry = data.npcs[npcId]
  if not entry or type(entry.turns) ~= "table" then return {} end
  local out = {}
  for i, t in ipairs(entry.turns) do
    out[i] = { role = t.role, text = t.text }
  end
  return out
end

function Memory.append(mod, game, npcId, role, text)
  if not AiConfig.memoryEnabled(mod) then return false end
  if type(npcId) ~= "string" or npcId == "" then return false end
  text = tostring(text or "")
  if text == "" then return false end
  if #text > 160 then text = text:sub(1, 160) end
  local data = bucket(mod, game)
  local entry = data.npcs[npcId]
  if not entry then
    entry = { turns = {} }
    data.npcs[npcId] = entry
  end
  entry.turns = entry.turns or {}
  entry.turns[#entry.turns + 1] = { role = role, text = text }
  while #entry.turns > Memory.MAX_TURNS_PER_NPC do
    table.remove(entry.turns, 1)
  end
  entry.updated = os.time()
  persist(mod, game, data)
  return true
end

function Memory.clearNpc(mod, game, npcId)
  local data = bucket(mod, game)
  if npcId then data.npcs[npcId] = nil else data.npcs = {} end
  persist(mod, game, data)
  AiLog.info(mod, "memory cleared")
  return true
end

function Memory.clearAll(mod, game)
  return Memory.clearNpc(mod, game, nil)
end

function Memory.resetRam()
  _ram = { npcs = {} }
end

return Memory
