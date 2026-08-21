-- AI dialogue configuration + private secret storage.
-- Public options never hold API keys. Secrets live in private user data.
local V = ...
local Config = V.require("config")

local AiConfig = {}

AiConfig.DEFAULT_ENDPOINT = "http://127.0.0.1:1234/v1"
AiConfig.DEFAULT_MODEL = "local"
AiConfig.SECRETS_REL = "wilds_ai/provider_secrets.json"
AiConfig.SECRETS_NOTE = "plaintext local storage (not Pokémon save data)"

local function opt(mod, key, default)
  if Config and type(Config.get) == "function" then
    local v = Config.get(mod, key)
    if v ~= nil then return v end
  end
  if mod and mod.options and type(mod.options.get) == "function" then
    local v = mod.options:get(key)
    if v ~= nil then return v end
  end
  return default
end

function AiConfig.enabled(mod)
  return opt(mod, "ai_dialogues", false) == true
end

function AiConfig.providerId(mod)
  local p = tostring(opt(mod, "ai_provider", "local") or "local")
  if p ~= "local" and p ~= "openai" and p ~= "custom" then
    return "local"
  end
  return p
end

function AiConfig.model(mod)
  local m = opt(mod, "ai_model", AiConfig.DEFAULT_MODEL)
  if type(m) ~= "string" or m == "" then return AiConfig.DEFAULT_MODEL end
  return m
end

function AiConfig.endpoint(mod)
  local e = opt(mod, "ai_endpoint", AiConfig.DEFAULT_ENDPOINT)
  if type(e) ~= "string" or e == "" then return AiConfig.DEFAULT_ENDPOINT end
  -- Strip trailing slash for joining /chat/completions
  return (e:gsub("/+$", ""))
end

function AiConfig.memoryEnabled(mod)
  return opt(mod, "ai_memory", true) ~= false
end

function AiConfig.chatUrl(mod)
  local base = AiConfig.endpoint(mod)
  if base:find("/chat/completions", 1, true) then return base end
  return base .. "/chat/completions"
end

-- ------- Secrets (never logged)

local _secretsCache = nil
local _secretsPathOverride = nil -- tests

function AiConfig.setSecretsPathForTests(path)
  _secretsPathOverride = path
  _secretsCache = nil
end

local function saveRoot()
  if love and love.filesystem and type(love.filesystem.getSaveDirectory) == "function" then
    local ok, dir = pcall(love.filesystem.getSaveDirectory)
    if ok and type(dir) == "string" and dir ~= "" then return dir end
  end
  return nil
end

local function secretsAbsPath()
  if type(_secretsPathOverride) == "string" and _secretsPathOverride ~= "" then
    return _secretsPathOverride
  end
  local root = saveRoot()
  if root then
    return root .. "/" .. AiConfig.SECRETS_REL
  end
  -- Headless / sandbox fallback: never write into the mod install tree.
  return nil
end

local function readFile(path)
  if type(path) ~= "string" then return nil end
  if love and love.filesystem and type(love.filesystem.read) == "function" then
    local ok, data = pcall(love.filesystem.read, AiConfig.SECRETS_REL)
    if ok and type(data) == "string" and data ~= "" then return data end
  end
  if io and io.open then
    local ok, f = pcall(io.open, path, "rb")
    if ok and f then
      local data = f:read("*a")
      f:close()
      if type(data) == "string" then return data end
    end
  end
  return nil
end

local function writeFile(path, body)
  if type(path) ~= "string" or type(body) ~= "string" then return false end
  if love and love.filesystem and type(love.filesystem.write) == "function" then
    pcall(function()
      if love.filesystem.createDirectory then
        love.filesystem.createDirectory("wilds_ai")
      end
    end)
    local ok = pcall(love.filesystem.write, AiConfig.SECRETS_REL, body)
    if ok then return true end
  end
  if io and io.open then
    -- Ensure parent dir when possible.
    local dir = path:match("^(.*)/[^/]+$")
    if dir and os and os.execute then
      pcall(os.execute, 'mkdir -p "' .. dir:gsub('"', "") .. '" 2>/dev/null')
    end
    local ok, f = pcall(io.open, path, "wb")
    if ok and f then
      f:write(body)
      f:close()
      return true
    end
  end
  return false
end

local function decodeSecrets(raw)
  if type(raw) ~= "string" or raw == "" then return {} end
  local JsonDecode = V.require("json_decode")
  local obj = JsonDecode.decode(raw)
  if type(obj) ~= "table" then return {} end
  return {
    openai_api_key = type(obj.openai_api_key) == "string" and obj.openai_api_key or "",
    custom_api_key = type(obj.custom_api_key) == "string" and obj.custom_api_key or "",
  }
end

function AiConfig.loadSecrets()
  if _secretsCache then return _secretsCache end
  local path = secretsAbsPath()
  local raw = path and readFile(path) or nil
  if not raw and love and love.filesystem then
    raw = readFile(AiConfig.SECRETS_REL)
  end
  _secretsCache = decodeSecrets(raw)
  return _secretsCache
end

function AiConfig.saveSecrets(secrets)
  secrets = secrets or {}
  local payload = {
    openai_api_key = tostring(secrets.openai_api_key or ""),
    custom_api_key = tostring(secrets.custom_api_key or ""),
    _note = AiConfig.SECRETS_NOTE,
  }
  local JsonEncode = V.require("ai/json_encode")
  local body = JsonEncode.encode(payload)
  local path = secretsAbsPath()
  local ok = false
  if path then ok = writeFile(path, body) end
  if not ok then
    ok = writeFile(AiConfig.SECRETS_REL, body)
  end
  if ok then
    _secretsCache = {
      openai_api_key = payload.openai_api_key,
      custom_api_key = payload.custom_api_key,
    }
  end
  return ok == true
end

function AiConfig.apiKeyForProvider(mod, providerId)
  providerId = providerId or AiConfig.providerId(mod)
  local s = AiConfig.loadSecrets()
  if providerId == "openai" then
    return s.openai_api_key or ""
  end
  if providerId == "custom" then
    return s.custom_api_key or ""
  end
  -- Local: optional key (some local proxies want one)
  return s.custom_api_key or ""
end

function AiConfig.redact(value)
  if type(value) ~= "string" then return value end
  if #value < 8 then return "***" end
  return value:sub(1, 2) .. string.rep("*", math.min(12, #value - 4)) .. value:sub(-2)
end

--- Safe snapshot for diagnostics (no secrets).
function AiConfig.diagnostics(mod)
  return {
    enabled = AiConfig.enabled(mod),
    provider = AiConfig.providerId(mod),
    model = AiConfig.model(mod),
    endpoint = AiConfig.endpoint(mod),
    memory = AiConfig.memoryEnabled(mod),
    hasOpenAiKey = (AiConfig.loadSecrets().openai_api_key or "") ~= "",
    hasCustomKey = (AiConfig.loadSecrets().custom_api_key or "") ~= "",
    secretsStorage = AiConfig.SECRETS_NOTE,
  }
end

function AiConfig.resetCache()
  _secretsCache = nil
end

return AiConfig
