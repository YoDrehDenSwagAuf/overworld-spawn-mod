-- Async HTTP transport for optional AI dialogues.
-- Prefer public mod.fetch.request when present; otherwise src.net.Fetch.request
-- (requires engine_internals). Never blocks the render thread.
local V = ...

local Transport = {}
Transport.__index = Transport

local DEFAULT_MAX_SECONDS = 25

local function tryRequire(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil
end

--- Injected mock for unit tests: { start = fn, poll = fn, cancel = fn? }
Transport._mock = nil

function Transport.setMock(mock)
  Transport._mock = mock
end

function Transport.clearMock()
  Transport._mock = nil
end

local function resolveEngineFetch()
  -- Future-proof: public mod.fetch may gain request/post.
  return nil
end

local function resolveInternalFetch()
  local Fetch = tryRequire("src.net.Fetch")
  if Fetch and type(Fetch.request) == "function" and type(Fetch.poll) == "function" then
    return Fetch
  end
  return nil
end

function Transport.available(mod)
  if Transport._mock then return true end
  if mod and mod.fetch and type(mod.fetch.request) == "function" then
    if type(mod.fetch.available) == "function" then
      local ok, avail = pcall(mod.fetch.available, mod.fetch)
      if ok and avail then return true end
    else
      return true
    end
  end
  return resolveInternalFetch() ~= nil
end

function Transport.describe(mod)
  if Transport._mock then return "mock" end
  if mod and mod.fetch and type(mod.fetch.request) == "function" then
    return "mod.fetch.request"
  end
  if resolveInternalFetch() then return "src.net.Fetch.request" end
  return "unavailable"
end

--- Start an HTTP request.
-- opts: { method, url, headers = {Name=value}|{ "Name: value", ... }, body, maxSeconds }
-- Returns handle or nil, err
function Transport.start(mod, opts)
  opts = opts or {}
  if Transport._mock and type(Transport._mock.start) == "function" then
    local ok, handle, err = pcall(Transport._mock.start, opts)
    if not ok then return nil, tostring(handle) end
    return handle, err
  end

  local method = tostring(opts.method or "POST"):upper()
  local url = opts.url
  if type(url) ~= "string" or url == "" then
    return nil, "url required"
  end
  local maxSeconds = tonumber(opts.maxSeconds) or DEFAULT_MAX_SECONDS
  if maxSeconds > 30 then maxSeconds = 30 end
  if maxSeconds < 1 then maxSeconds = 1 end

  -- Public facade (if engine adds it later).
  if mod and mod.fetch and type(mod.fetch.request) == "function" then
    local ok, handle, err = pcall(mod.fetch.request, mod.fetch, url, {
      method = method,
      body = opts.body,
      headers = opts.headers,
      maxSeconds = maxSeconds,
    })
    if ok and handle ~= nil then
      return { kind = "mod_fetch", handle = handle, mod = mod }, nil
    end
    if ok then return nil, err or "mod.fetch.request failed" end
    return nil, tostring(handle)
  end

  local Fetch = resolveInternalFetch()
  if not Fetch then
    return nil, "no async HTTP transport (need network + Fetch.request)"
  end

  local ok, id = pcall(Fetch.request, url, {
    method = method,
    body = opts.body,
    headers = opts.headers,
    userAgent = "gen1recomp-mod/overworld_wild_spawns",
    maxSeconds = maxSeconds,
  })
  if not ok then return nil, tostring(id) end
  if id == nil then return nil, "Fetch.request returned nil" end
  return { kind = "engine_fetch", id = id, Fetch = Fetch }, nil
end

--- Non-blocking poll. status: pending | ok | error | cancelled
function Transport.poll(handle)
  if handle == nil then
    return { status = "error", err = "unknown request" }
  end
  if Transport._mock and type(Transport._mock.poll) == "function" then
    local ok, st = pcall(Transport._mock.poll, handle)
    if not ok then return { status = "error", err = tostring(st) } end
    return st or { status = "error", err = "mock poll nil" }
  end

  if handle.kind == "mod_fetch" then
    local mod = handle.mod
    if not (mod and mod.fetch and type(mod.fetch.poll) == "function") then
      return { status = "error", err = "mod.fetch unavailable" }
    end
    local ok, st = pcall(mod.fetch.poll, mod.fetch, handle.handle)
    if not ok then return { status = "error", err = tostring(st) } end
    st = st or {}
    return {
      status = st.status or "error",
      body = st.body,
      err = st.err,
      code = st.code,
      progress = st.progress,
    }
  end

  if handle.kind == "engine_fetch" and handle.Fetch then
    local ok, st = pcall(handle.Fetch.poll, handle.id)
    if not ok then return { status = "error", err = tostring(st) } end
    st = st or {}
    return {
      status = st.status or "error",
      body = st.body,
      err = st.err,
      code = st.code,
      progress = st.progress,
    }
  end

  return { status = "error", err = "unknown handle" }
end

function Transport.release(handle)
  if handle == nil then return false end
  if Transport._mock and type(Transport._mock.release) == "function" then
    pcall(Transport._mock.release, handle)
    return true
  end
  if handle.kind == "mod_fetch" then
    local mod = handle.mod
    if mod and mod.fetch and type(mod.fetch.release) == "function" then
      pcall(mod.fetch.release, mod.fetch, handle.handle)
      return true
    end
  elseif handle.kind == "engine_fetch" and handle.Fetch then
    pcall(handle.Fetch.release, handle.id)
    return true
  end
  return false
end

function Transport.cancel(handle)
  if handle == nil then return false end
  if Transport._mock and type(Transport._mock.cancel) == "function" then
    pcall(Transport._mock.cancel, handle)
    return true
  end
  if handle.kind == "mod_fetch" then
    local mod = handle.mod
    if mod and mod.fetch and type(mod.fetch.cancel) == "function" then
      pcall(mod.fetch.cancel, mod.fetch, handle.handle)
      return true
    end
  elseif handle.kind == "engine_fetch" and handle.Fetch then
    pcall(handle.Fetch.cancel, handle.id)
    return true
  end
  return false
end

return Transport
