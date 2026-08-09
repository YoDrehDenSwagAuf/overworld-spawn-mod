-- Central registry for Wilds built-in water sprites (swimming + levitates).
--
-- Resolves by Pokédex / species ID only (never localized names).
-- Returns SpriteRenderer-ready definitions pointing at pre-built 16×96 sheets.
local V = ...
local JsonDecode = V.require("json_decode")
local Config = V.require("config")
local RuntimeSheets = V.require("runtime_sheets")

local WaterSpriteRegistry = {}
WaterSpriteRegistry.__index = WaterSpriteRegistry

WaterSpriteRegistry.WATER_SPRITE_ORDER = { "swimming", "levitates" }
WaterSpriteRegistry.FRAMES = RuntimeSheets.FRAMES or 6
WaterSpriteRegistry.WALKER = true
WaterSpriteRegistry.SHEET_W = RuntimeSheets.SHEET_W or 16
WaterSpriteRegistry.SHEET_H = RuntimeSheets.SHEET_H or 96

WaterSpriteRegistry.ROOT_REL = "assets/enhanced_overworld/water_sprites"
WaterSpriteRegistry.RUNTIME_REL = "assets/generated/water_runtime"
WaterSpriteRegistry.MANIFEST_REL = WaterSpriteRegistry.RUNTIME_REL .. "/manifest.json"
-- Native Voxel silhouette sheets (pre-rendered; filenames match water_runtime).
WaterSpriteRegistry.SILHOUETTE_RUNTIME = {
  swimming = "assets/generated/swimming_silhouette_runtime",
  levitates = "assets/generated/levitates_silhouette_runtime",
}

local KIND_META = {
  swimming = {
    kind = "swimming",
    mappingRel = WaterSpriteRegistry.ROOT_REL .. "/swimming/swimming_sprite_mapping.json",
    sourceDir = WaterSpriteRegistry.ROOT_REL .. "/swimming",
  },
  levitates = {
    kind = "levitates",
    mappingRel = WaterSpriteRegistry.ROOT_REL .. "/levitates/levitates_sprite_mapping.json",
    sourceDir = WaterSpriteRegistry.ROOT_REL .. "/levitates",
  },
}

local function normalizeVariant(variant)
  if variant == true or variant == "shiny" or variant == "s" or variant == "SHINY" then
    return "shiny"
  end
  return "normal"
end

local function normalizeForm(form)
  if form == nil then return nil end
  local s = tostring(form):gsub("^_", "")
  if s == "" or s == "null" or s == "none" or s == "default" then
    return nil
  end
  return s
end

local function formKey(form)
  return normalizeForm(form) or "default"
end

function WaterSpriteRegistry.new(mod)
  local self = setmetatable({}, WaterSpriteRegistry)
  self.mod = mod
  self.ready = false
  self.loadError = nil
  self.mappings = {}      -- kind → mapping table
  self.index = {}         -- kind → speciesId → variant → formKey → entry
  self.preferredKind = {} -- speciesId → kind override
  self.manifest = nil
  self.manifestSheets = {}
  self.cache = {}
  self.stats = {
    swimmingMapped = 0,
    levitatesMapped = 0,
    normal = 0,
    shiny = 0,
    uniqueSpecies = 0,
  }
  return self
end

function WaterSpriteRegistry:_modPath(rel)
  if type(rel) ~= "string" or rel == "" then return nil end
  if self.mod and self.mod.assets and type(self.mod.assets.path) == "function" then
    local ok, path = pcall(self.mod.assets.path, self.mod.assets, rel)
    if ok and type(path) == "string" and path ~= "" then
      return path
    end
  end
  return rel
end

function WaterSpriteRegistry:_readBytes(rel)
  if type(rel) ~= "string" or rel == "" then return nil end
  if self.mod and type(self.mod.read) == "function" then
    local ok, data = pcall(self.mod.read, self.mod, rel)
    if ok and type(data) == "string" and data ~= "" then return data end
    if ok and data ~= nil and data ~= false then return data end
  end
  local loadPath = self:_modPath(rel)
  if love and love.filesystem and love.filesystem.read and loadPath then
    local ok, data = pcall(love.filesystem.read, loadPath)
    if ok and type(data) == "string" and data ~= "" then return data end
  end
  local f = io.open(rel, "rb")
  if not f and V.path then
    f = io.open((V.path or ".") .. "/" .. rel, "rb")
  end
  if f then
    local data = f:read("*a")
    f:close()
    if type(data) == "string" and data ~= "" then return data end
  end
  return nil
end

function WaterSpriteRegistry:_assetPresent(rel)
  return self:_readBytes(rel) ~= nil
end

local function ensureNested(root, ...)
  local node = root
  for i = 1, select("#", ...) do
    local key = select(i, ...)
    local nextNode = node[key]
    if type(nextNode) ~= "table" then
      nextNode = {}
      node[key] = nextNode
    end
    node = nextNode
  end
  return node
end

function WaterSpriteRegistry:_indexEntry(kind, entry, sourceDir)
  local sid = tonumber(entry.speciesId)
  if not sid or sid < 1 then return false, "non-numeric speciesId" end
  sid = math.floor(sid)
  local variant = normalizeVariant(entry.variant)
  local form = normalizeForm(entry.suffix)
  -- Colored targets are the default "normal" art (entry.target); the
  -- -grayscale targets serve every PaletteFX mode except redpp (ADVANCED),
  -- which bakes real per-tile color. Headless / unknown mode defaults to
  -- colored. Entries without a grayscaleTarget (colored-only variants such
  -- as female forms) fall back to the colored target everywhere.
  local useGray = not Config.paletteFxRedpp()
    and type(entry.grayscaleTarget) == "string" and entry.grayscaleTarget ~= ""
  local target = useGray and entry.grayscaleTarget or entry.target
  if type(target) ~= "string" or target == "" then
    return false, "missing target"
  end

  local sourceRel = sourceDir .. "/" .. target
  local runtimeName
  if form then
    runtimeName = string.format("%03d-%s-%s.png", sid, variant, form)
  else
    runtimeName = string.format("%03d-%s.png", sid, variant)
  end
  local runtimeRel = WaterSpriteRegistry.RUNTIME_REL .. "/" .. kind .. "/" .. runtimeName

  local record = {
    kind = kind,
    speciesId = sid,
    variant = variant,
    form = form,
    target = target,
    sourceRel = sourceRel,
    runtimeRel = runtimeRel,
    preferredWaterKind = entry.preferredWaterKind,
    speciesName = entry.speciesName,
  }

  local bucket = ensureNested(self.index, kind, sid, variant)
  bucket[formKey(form)] = record
  -- Stable ordered list for deterministic "first available form".
  bucket._order = bucket._order or {}
  local seen = false
  for _, fk in ipairs(bucket._order) do
    if fk == formKey(form) then seen = true break end
  end
  if not seen then
    bucket._order[#bucket._order + 1] = formKey(form)
  end

  if type(entry.preferredWaterKind) == "string" and entry.preferredWaterKind ~= "" then
    self.preferredKind[sid] = entry.preferredWaterKind
  end
  return true
end

function WaterSpriteRegistry:_loadMapping(kind)
  local meta = KIND_META[kind]
  if not meta then return false, "unknown kind" end
  local raw = self:_readBytes(meta.mappingRel)
  if type(raw) ~= "string" or raw == "" then
    return false, "mapping missing: " .. meta.mappingRel
  end
  local ok, data = pcall(JsonDecode.decode, raw)
  if not ok or type(data) ~= "table" then
    return false, "mapping invalid JSON: " .. meta.mappingRel
  end
  self.mappings[kind] = data
  self.index[kind] = self.index[kind] or {}

  if type(data.preferredWaterKind) == "string" then
    -- Top-level preferred kind applies only when per-species is absent;
    -- stored under key 0 as a sentinel is avoided — skip global apply.
  end
  if type(data.speciesPreferred) == "table" then
    for k, v in pairs(data.speciesPreferred) do
      local sid = tonumber(k)
      if sid and type(v) == "string" then
        self.preferredKind[math.floor(sid)] = v
      end
    end
  end

  local files = data.files or {}
  local count = 0
  for _, entry in ipairs(files) do
    if type(entry) == "table" then
      local okEntry = self:_indexEntry(kind, entry, meta.sourceDir)
      if okEntry then count = count + 1 end
    end
  end
  return true, count
end

function WaterSpriteRegistry:_loadManifest()
  local raw = self:_readBytes(WaterSpriteRegistry.MANIFEST_REL)
  if type(raw) ~= "string" or raw == "" then
    return false, "water runtime manifest missing"
  end
  local ok, data = pcall(JsonDecode.decode, raw)
  if not ok or type(data) ~= "table" then
    return false, "water runtime manifest invalid JSON"
  end
  self.manifest = data
  self.manifestSheets = data.sheets or {}
  -- Prefer preferredWaterKind from generated manifest when present.
  for _, entry in pairs(self.manifestSheets) do
    if type(entry) == "table" and entry.speciesId and entry.preferredWaterKind then
      local sid = tonumber(entry.speciesId)
      if sid and not self.preferredKind[sid] then
        self.preferredKind[math.floor(sid)] = entry.preferredWaterKind
      end
    end
  end
  return true
end

function WaterSpriteRegistry:load()
  self.ready = false
  self.loadError = nil
  self.mappings = {}
  self.index = {}
  self.preferredKind = {}
  self.cache = {}
  self.stats = {
    swimmingMapped = 0,
    levitatesMapped = 0,
    normal = 0,
    shiny = 0,
    uniqueSpecies = 0,
  }

  local swimOk, swimCount = self:_loadMapping("swimming")
  if not swimOk then
    self.loadError = tostring(swimCount)
    return false, self.loadError
  end
  local levOk, levCount = self:_loadMapping("levitates")
  if not levOk then
    self.loadError = tostring(levCount)
    return false, self.loadError
  end
  self.stats.swimmingMapped = swimCount or 0
  self.stats.levitatesMapped = levCount or 0

  local manOk, manErr = self:_loadManifest()
  if not manOk then
    -- Registry can still resolve via constructed paths if sheets exist.
    self.loadError = manErr
  end

  local speciesSet = {}
  for kind, bySpecies in pairs(self.index) do
    for sid, byVariant in pairs(bySpecies) do
      speciesSet[sid] = true
      for variant, byForm in pairs(byVariant) do
        if variant == "normal" or variant == "shiny" then
          for fk, record in pairs(byForm) do
            if fk ~= "_order" and type(record) == "table" then
              if record.variant == "normal" then
                self.stats.normal = self.stats.normal + 1
              elseif record.variant == "shiny" then
                self.stats.shiny = self.stats.shiny + 1
              end
            end
          end
        end
      end
    end
  end
  local unique = 0
  for _ in pairs(speciesSet) do unique = unique + 1 end
  self.stats.uniqueSpecies = unique

  self.ready = true
  return true
end

function WaterSpriteRegistry:isReady()
  return self.ready == true
end

function WaterSpriteRegistry:preferredKindFor(speciesId)
  local sid = tonumber(speciesId)
  if not sid then return nil end
  return self.preferredKind[math.floor(sid)]
end

function WaterSpriteRegistry:kindOrder(preferredKind)
  local order = {}
  local pref = preferredKind and tostring(preferredKind):lower() or nil
  if pref == "swimming" or pref == "levitates" then
    order[#order + 1] = pref
  end
  for _, kind in ipairs(WaterSpriteRegistry.WATER_SPRITE_ORDER) do
    if kind ~= pref then
      order[#order + 1] = kind
    end
  end
  return order
end

function WaterSpriteRegistry:_pickFormRecord(byForm, form)
  if type(byForm) ~= "table" then return nil end
  local want = formKey(form)
  local exact = byForm[want]
  if type(exact) == "table" and exact.runtimeRel then
    return exact, want
  end
  -- Prefer default (no suffix).
  local default = byForm["default"]
  if type(default) == "table" and default.runtimeRel then
    return default, "default"
  end
  -- Deterministic first available form (sorted order list).
  local order = byForm._order
  if type(order) == "table" then
    for _, fk in ipairs(order) do
      local rec = byForm[fk]
      if type(rec) == "table" and rec.runtimeRel then
        return rec, fk
      end
    end
  end
  return nil
end

function WaterSpriteRegistry:_fileName(record)
  if not record then return nil end
  if record.form then
    return string.format("%03d-%s-%s.png", record.speciesId, record.variant, record.form)
  end
  return string.format("%03d-%s.png", record.speciesId, record.variant)
end

function WaterSpriteRegistry:_silhouetteRel(kind, record)
  local root = WaterSpriteRegistry.SILHOUETTE_RUNTIME[kind]
  if not root or not record then return nil end
  local name = self:_fileName(record)
  if not name then return nil end
  return root .. "/" .. name
end

function WaterSpriteRegistry:_resolvePath(record, opts)
  opts = opts or {}
  if not record then return nil end
  -- Prefer runtime sheet; fall back to checking manifest path.
  local rel = record.runtimeRel
  local key = string.format("%d:%s:%s", record.speciesId, record.variant, record.kind)
  if record.form then
    key = key .. ":" .. record.form
  end
  local man = self.manifestSheets[key]
  if man and type(man.path) == "string" and man.path ~= "" then
    rel = man.path
  end

  local silhouette = opts.silhouette == true
  if silhouette then
    local silRel = self:_silhouetteRel(record.kind, record)
    if silRel and self:_assetPresent(silRel) then
      return silRel, nil, key, true
    end
    -- Fallback: keep colour water sheet only as last resort (diagnosed).
    if not self:_assetPresent(rel) then
      return nil, "silhouette + water sheet missing: " .. tostring(silRel or rel)
    end
    return rel, nil, key, false
  end

  -- Colored runtime sheets are the default (rel); the -grayscale sheets
  -- serve every PaletteFX mode except redpp (ADVANCED), which bakes real
  -- per-tile color. Every other mode serves the grayscale sheet.
  if not Config.paletteFxRedpp() then
    local grayPath = man and man.grayscalePath or nil
    if type(grayPath) ~= "string" or grayPath == "" then
      grayPath = rel:gsub("%.png$", "-grayscale.png")
    end
    if grayPath ~= "" and self:_assetPresent(grayPath) then
      rel = grayPath
    end
  end

  if not self:_assetPresent(rel) then
    return nil, "runtime sheet missing: " .. tostring(rel)
  end
  return rel, nil, key, false
end

-- Resolve one kind+variant attempt. Returns def table or nil, err.
function WaterSpriteRegistry:_resolveKindVariant(speciesId, kind, variant, form, opts)
  opts = opts or {}
  local bySpecies = self.index[kind]
  if not bySpecies then return nil, "kind not indexed" end
  local byVariant = bySpecies[speciesId]
  if not byVariant then return nil, "species missing for kind" end
  local byForm = byVariant[variant]
  if not byForm then return nil, "variant missing for kind" end
  local record = self:_pickFormRecord(byForm, form)
  if not record then return nil, "form unavailable" end
  local rel, err, _key, usedSilhouette = self:_resolvePath(record, opts)
  if not rel then return nil, err end
  local loadPath = self:_modPath(rel)
  if type(loadPath) ~= "string" or loadPath == "" then
    return nil, "asset path unresolved"
  end
  local idKind = kind
  if opts.silhouette and usedSilhouette then
    idKind = kind .. "_silhouette"
  end
  return {
    kind = kind,
    speciesId = speciesId,
    variant = variant,
    form = record.form,
    formKey = formKey(record.form),
    image = loadPath,
    relativePath = rel,
    frames = WaterSpriteRegistry.FRAMES,
    walker = true,
    trueColor = true,
    source = "mapping",
    silhouette = usedSilhouette == true,
    silhouetteRequested = opts.silhouette == true,
    silhouetteFallback = opts.silhouette == true and usedSilhouette ~= true,
    id = string.format("SPRITE_OW_WATER_%s_%d_%s",
      string.upper(idKind), speciesId, variant),
  }
end

-- Public resolve: speciesId, variant, preferredKind, form [, opts]
-- opts.silhouette = true → prefer pre-rendered silhouette runtime sheets.
-- Shiny tries shiny then normal within each kind before next kind.
function WaterSpriteRegistry:resolve(speciesId, variant, preferredKind, form, opts)
  opts = opts or {}
  local sid = tonumber(speciesId)
  if not sid or sid < 1 then
    return nil, "water sprite unavailable"
  end
  sid = math.floor(sid)
  local want = normalizeVariant(variant)
  form = normalizeForm(form)
  preferredKind = preferredKind or self:preferredKindFor(sid)
  local silKey = opts.silhouette and "sil" or "color"

  local cacheKey = string.format("%d:%s:water:%s:%s:%s",
    sid, want, tostring(preferredKind or "auto"), formKey(form), silKey)
  local cached = self.cache[cacheKey]
  if cached ~= nil then
    if cached.ok then return cached.def end
    return nil, cached.err or "water sprite unavailable"
  end

  local order = self:kindOrder(preferredKind)
  local variantOrder = (want == "shiny") and { "shiny", "normal" } or { "normal" }

  for _, kind in ipairs(order) do
    for _, v in ipairs(variantOrder) do
      local def, err = self:_resolveKindVariant(sid, kind, v, form, opts)
      if def then
        self.cache[cacheKey] = { ok = true, def = def }
        return def
      end
    end
  end

  local err = "water sprite unavailable"
  self.cache[cacheKey] = { ok = false, err = err }
  return nil, err
end

function WaterSpriteRegistry:invalidateCache()
  self.cache = {}
end

function WaterSpriteRegistry:hasKind(speciesId, kind, variant)
  local sid = tonumber(speciesId)
  if not sid then return false end
  sid = math.floor(sid)
  local bySpecies = self.index[kind]
  local byVariant = bySpecies and bySpecies[sid]
  local want = normalizeVariant(variant)
  local byForm = byVariant and byVariant[want]
  if not byForm then return false end
  return self:_pickFormRecord(byForm, nil) ~= nil
end

function WaterSpriteRegistry:summary()
  return {
    ready = self.ready,
    loadError = self.loadError,
    order = WaterSpriteRegistry.WATER_SPRITE_ORDER,
    stats = self.stats,
    manifestRel = WaterSpriteRegistry.MANIFEST_REL,
    frames = WaterSpriteRegistry.FRAMES,
    sheetW = WaterSpriteRegistry.SHEET_W,
    sheetH = WaterSpriteRegistry.SHEET_H,
  }
end

function WaterSpriteRegistry:diagnosticsFor(speciesId, variant, form)
  local def, err = self:resolve(speciesId, variant, nil, form)
  if not def then
    return {
      ready = self.ready,
      available = false,
      reason = err or "water sprite unavailable",
      kind = nil,
    }
  end
  return {
    ready = self.ready,
    available = true,
    kind = def.kind,
    variant = def.variant,
    form = def.formKey or "default",
    image = def.image,
    relativePath = def.relativePath,
    frames = def.frames,
    walker = def.walker == true,
  }
end

WaterSpriteRegistry.normalizeVariant = normalizeVariant
WaterSpriteRegistry.normalizeForm = normalizeForm
WaterSpriteRegistry.KIND_META = KIND_META

return WaterSpriteRegistry
