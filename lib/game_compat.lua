-- Wilds game / generation compatibility facade.
--
-- Shared Wilds systems should ask this module instead of assuming Gen 1.
-- This PR only implements a real Gen1 adapter. Gen2 is an unsupported stub.
--
-- Detection uses Gen1Recomp `src.core.GameVersion` (not ROM filenames).
-- Red / Blue / Yellow → generation 1. Any other explicit version is unsupported.
-- Missing GameVersion (unit tests / early load) keeps the historical Gen1 path
-- so current Red/Blue/Yellow loading is unchanged.
local V = ...

local Gen1 = V.require("game_compat/gen1")
local Gen2 = V.require("game_compat/gen2")

local GameCompat = {}
GameCompat.Gen1 = Gen1
GameCompat.Gen2 = Gen2

local GEN1_VERSIONS = {
  red = true,
  blue = true,
  yellow = true,
}

local function tryRequire(path)
  local ok, mod = pcall(require, path)
  if ok then return mod end
  return nil
end

local function looksLikeGame(t)
  if type(t) ~= "table" then return false end
  if t.save or t.data or t.overworld or t.player then return true end
  if t.generation ~= nil or t.version ~= nil or t.gameVersion ~= nil then
    return true
  end
  return false
end

-- Accept both GameCompat.generation(mod, game) and GameCompat.generation(game).
local function splitModGame(modOrGame, game)
  if game ~= nil then
    return modOrGame, game
  end
  if looksLikeGame(modOrGame) then
    return nil, modOrGame
  end
  return modOrGame, nil
end

local function engineVersion(game)
  local GV = tryRequire("src.core.GameVersion")
  if GV then
    if type(GV.isYellow) == "function" then
      local ok, yellow = pcall(GV.isYellow)
      if ok and yellow == true then return "yellow" end
    end
    if type(GV.get) == "function" then
      local ok, v = pcall(GV.get)
      if ok and type(v) == "string" and v ~= "" then
        return string.lower(v)
      end
    end
  end
  if type(game) == "table" then
    local v = game.version or game.gameVersion
    if type(v) == "string" and v ~= "" then
      return string.lower(v)
    end
  end
  return nil
end

--- Engine version string: "red" | "blue" | "yellow" | other | nil.
function GameCompat.gameVersion(game)
  return engineVersion(game)
end

--- National-dex generation currently running, or nil if unsupported.
-- Red / Blue / Yellow → 1. Explicit unknown versions → nil (never guessed as 1).
function GameCompat.generation(mod, game)
  local _, g = splitModGame(mod, game)
  local ver = engineVersion(g)
  if ver then
    if GEN1_VERSIONS[ver] then return 1 end
    return nil
  end
  if type(g) == "table" then
    local declared = tonumber(g.generation)
    if declared then
      if declared == 1 then return 1 end
      return nil
    end
  end
  -- No GameVersion API and no explicit game.generation: preserve Gen1 loading
  -- (unit tests and historical missing-API path). Future titles must expose
  -- GameVersion or game.generation so they are not classified as Gen 1.
  return 1
end

function GameCompat.isSupported(mod, game)
  return GameCompat.generation(mod, game) == 1
end

--- Active adapter (Gen1 table) or nil when unsupported.
function GameCompat.current(mod, game)
  if not GameCompat.isSupported(mod, game) then
    return nil
  end
  return Gen1
end

function GameCompat.speciesId(species, game, mod)
  local adapter = GameCompat.current(mod, game)
  if not (adapter and adapter.speciesId) then return nil end
  return adapter.speciesId(species, game, mod or V.mod)
end

function GameCompat.isSurfing(game, ow)
  local adapter = GameCompat.current(nil, game)
  if not (adapter and adapter.isSurfing) then return false end
  return adapter.isSurfing(game, ow) == true
end

function GameCompat.isWaterCell(map, x, y)
  -- Map water probe is engine-level, not generation-specific.
  if not (map and type(map.isWaterCell) == "function") then return false end
  local ok, water = pcall(map.isWaterCell, map, x, y)
  return ok and water == true
end

function GameCompat.party(game)
  local adapter = GameCompat.current(nil, game)
  if not (adapter and adapter.party) then return nil end
  return adapter.party(game)
end

function GameCompat.currentMapId(game, ow)
  local adapter = GameCompat.current(nil, game)
  if not (adapter and adapter.currentMapId) then return nil end
  return adapter.currentMapId(game, ow)
end

return GameCompat
