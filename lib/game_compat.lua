-- Wilds game / generation compatibility facade.
--
-- Shared Wilds systems should ask this module instead of assuming Gen 1.
-- This PR only implements a real Gen1 adapter. Gen2 is an unsupported stub.
--
-- Canonical engine source of truth (Gen1Recomp src/core/GameVersion.lua):
--   GameVersion.get()            → "red"|"blue"|"yellow"|"gold"|…
--   GameVersion.generation(id)   → 1 or 2  (absent row field reads as 1)
--   GameVersion.info(id)
--
-- GameVersion is a zero-require module, loaded during love.conf, and
-- GameVersion.set() runs in bootGame() BEFORE Loader:load / mod entry.
-- A real engine boot therefore never hits the "module missing" path.
-- That path exists only for standalone Wilds unit tests.
--
-- Future Mod Manager claim (NOT active in this PR):
--   manifest "games": ["gen1", "gen2"]  → ModTargets.label = "Gen 1+2"
-- Do not set that until Gen2.supported is true and boot is safe.
local V = ...

local Gen1 = V.require("game_compat/gen1")
local Gen2 = V.require("game_compat/gen2")

local GameCompat = {}
GameCompat.Gen1 = Gen1
GameCompat.Gen2 = Gen2

-- Documented next-PR manifest tokens. Production manifest.json must not
-- include these until the Gen2 adapter is boot-safe.
GameCompat.FUTURE_GAMES = { "gen1", "gen2" }

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

local function readEngineVersion(GV, game)
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

-- Engine generation number, or nil when the running title is unknown.
-- Returns: gen, versionId, source
--   source = "engine" | "declared" | "missing-module"
local function detectGeneration(game)
  local GV = tryRequire("src.core.GameVersion")
  local ver = readEngineVersion(GV, game)

  if GV then
    -- Module present: never assume Gen1. Gold boots with GameVersion already
    -- set; treating a missing get() as Gen1 would install Gen1 hooks on Gen2.
    if type(GV.generation) == "function" then
      local ok, gen = pcall(function()
        if ver then return GV.generation(ver) end
        return GV.generation()
      end)
      if ok and type(gen) == "number" then
        return gen, ver, "engine"
      end
    end
    if ver and GEN1_VERSIONS[ver] then
      return 1, ver, "engine"
    end
    if type(game) == "table" then
      local declared = tonumber(game.generation)
      if declared then
        return declared, ver, "declared"
      end
    end
    -- Explicit unknown version, or GameVersion present but unreadable.
    return nil, ver, "engine"
  end

  -- Module absent: standalone unit tests / no engine on package.path.
  -- Cannot happen on a real Gen1Recomp boot (GameVersion loads at love.conf).
  if type(game) == "table" then
    local declared = tonumber(game.generation)
    if declared then
      if declared == 1 then return 1, ver, "declared" end
      return nil, ver, "declared"
    end
  end
  if ver and GEN1_VERSIONS[ver] then return 1, ver, "missing-module" end
  if ver then return nil, ver, "missing-module" end
  return 1, nil, "missing-module"
end

--- Engine version string: "red" | "blue" | "yellow" | "gold" | other | nil.
function GameCompat.gameVersion(game)
  return readEngineVersion(tryRequire("src.core.GameVersion"), game)
end

--- National-dex generation currently running, or nil if unknown/unsupported.
-- Red / Blue / Yellow → 1. Gold (engine GameVersion.generation) → 2.
-- Explicit unknown versions → nil (never guessed as 1).
function GameCompat.generation(mod, game)
  local _, g = splitModGame(mod, game)
  local gen = detectGeneration(g)
  return gen
end

function GameCompat.isGen1(mod, game)
  return GameCompat.generation(mod, game) == 1
end

function GameCompat.isGen2(mod, game)
  return GameCompat.generation(mod, game) == 2
end

--- Active adapter, or nil when this generation has no supported adapter.
function GameCompat.current(mod, game)
  local gen = GameCompat.generation(mod, game)
  if gen == 1 and Gen1.supported then return Gen1 end
  if gen == 2 and Gen2.supported then return Gen2 end
  return nil
end

--- True only when a supported adapter is active. Production: Gen1 only.
function GameCompat.isSupported(mod, game)
  local adapter = GameCompat.current(mod, game)
  return adapter ~= nil and adapter.supported == true
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
