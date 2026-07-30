-- Pokemon preview browser (developer mode only).
--
-- Opening path (public Gen1Recomp APIs, no invented UI):
--   1. mod.content.screens:register("OverworldSpawnPreview", ...)
--   2. mod.hooks:wrap("ui.options.rows", ...) with an activate row
--      (same pattern as mods/examples/example_jukebox)
--
-- The Mod Manager option schema has no button type
-- (ManagerState.OPTION_TYPES = toggle|choice|number|text), so the browser
-- is reached from OPTIONS → "POKEMON PREVIEW" → OPEN when Developer mode
-- is enabled. Filter/search use real option rows (preview_filter, etc.).
--
-- Never filters by Pokédex seen/caught/owned.
local V = ...
local Config = V.require("config")
local EncounterIndex = V.require("encounter_index")
local DebugLog = V.require("debug_log")

local PreviewBrowser = {}
PreviewBrowser.__index = PreviewBrowser

PreviewBrowser.SCREEN = "OverworldSpawnPreview"
PreviewBrowser.DETAIL = "OverworldSpawnPreviewDetail"

local function pokedexDiag(game)
  local save = game and game.save
  local dex = save and save.pokedex
  if not dex then return false, false end
  local seen = dex.seen and next(dex.seen) ~= nil
  local owned = dex.owned and next(dex.owned) ~= nil
  return seen, owned
end

local function allSpecies(mod, game)
  -- Prefer the merged runtime table (game.data.pokemon) and union with the
  -- content registry so headless tests / late registrations still appear.
  -- Never consult the Pokédex for inclusion.
  local rows = {}
  local seen = {}
  local function add(id, mon)
    if type(id) ~= "string" or seen[id] then return end
    if type(mon) ~= "table" then mon = { name = id } end
    seen[id] = true
    rows[#rows + 1] = {
      id = id,
      name = mon.name or id,
      dex = mon.dex or 9999,
    }
  end
  if game and game.data and type(game.data.pokemon) == "table" then
    for id, mon in pairs(game.data.pokemon) do
      add(id, mon)
    end
  end
  if mod.content and mod.content.pokemon and mod.content.pokemon.each then
    for id, mon in mod.content.pokemon:each() do
      add(id, mon)
    end
  end
  table.sort(rows, function(a, b)
    if a.dex ~= b.dex then return a.dex < b.dex end
    return a.id < b.id
  end)
  return rows
end

local function matchesSearch(row, search)
  if not search or search == "" then return true end
  local q = tostring(search):lower()
  if tostring(row.id):lower():find(q, 1, true) then return true end
  if tostring(row.name):lower():find(q, 1, true) then return true end
  if tostring(row.dex) == q then return true end
  return false
end

function PreviewBrowser.new(mod, logic)
  local self = setmetatable({}, PreviewBrowser)
  self.mod = mod
  self.logic = logic
  self._index = nil
  self._registered = false
  return self
end

function PreviewBrowser:invalidateIndex()
  self._index = nil
end

function PreviewBrowser:indexFor(game)
  if not self._index then
    self._index = EncounterIndex.build(game)
    DebugLog.info(self.mod, "preview index built for %d species",
                  (function()
                    local n = 0
                    for _ in pairs(self._index) do n = n + 1 end
                    return n
                  end)())
  end
  return self._index
end

function PreviewBrowser:speciesRows(game)
  local render = self.logic.render
  local index = self:indexFor(game)
  local filter = Config.get(self.mod, "preview_filter") or "all"
  local search = Config.get(self.mod, "preview_search") or ""
  local mapFilter = Config.get(self.mod, "preview_map_filter") or ""
  local kindFilter = Config.get(self.mod, "preview_encounter_kind") or "any"
  local rows = {}

  for _, row in ipairs(allSpecies(self.mod, game)) do
    if matchesSearch(row, search) then
      local info = render:assetStatusFor(row.id, game)
      local locs = index[row.id] or {}
      local locLines = EncounterIndex.formatLocations(locs, mapFilter, kindFilter)
      local include = true
      if mapFilter ~= "" and #locLines == 0 then
        include = false
      end
      if include and filter == "asset_loaded" then
        include = info.status == "LOADED"
      elseif include and filter == "asset_missing" then
        include = info.status ~= "LOADED"
      elseif include and filter == "entity_ready" then
        local probe = render:probeEntity(game, row.id)
        include = probe.entityReady == true
      elseif include and filter == "entity_failed" then
        local probe = render:probeEntity(game, row.id)
        include = probe.entityReady ~= true
      end
      if include then
        local right = info.status
        if #locLines > 0 then
          right = right .. " " .. tostring(#locLines)
        end
        rows[#rows + 1] = {
          label = row.name,
          right = right,
          value = row.id,
          meta = {
            name = row.name,
            dex = row.dex,
            info = info,
            locations = locLines,
          },
        }
      end
    end
  end
  return rows
end

function PreviewBrowser:_openDetail(game, speciesId)
  local mod = self.mod
  local logic = self.logic
  local render = logic.render
  local index = self:indexFor(game)
  local mon = (game.data.pokemon and game.data.pokemon[speciesId]) or {}
  local info, _ = render:probeEntity(game, speciesId)
  local locs = EncounterIndex.formatLocations(
    index[speciesId] or {},
    Config.get(mod, "preview_map_filter") or "",
    Config.get(mod, "preview_encounter_kind") or "any")
  local imgPath, imgKind = render:previewImagePath(speciesId, game)
  local seen, owned = pokedexDiag(game)

  local items = {
    { label = "SPECIES ID", right = tostring(speciesId) },
    { label = "DEX NO", right = tostring(mon.dex or "?") },
    { label = "ASSET", right = tostring(info.status) },
    { label = "ASSET KIND", right = tostring(imgKind) },
    { label = "RENDERER", right = tostring(info.renderer) },
    { label = "OW ENTITY", right = tostring(info.entityStatus or "?") },
    { label = "POKEDEX SEEN", right = tostring(seen) .. " (diag)" },
    { label = "POKEDEX OWN", right = tostring(owned) .. " (diag)" },
  }
  if info.lastError then
    items[#items + 1] = { label = "LAST ERR", right = tostring(info.lastError):sub(1, 18) }
  end
  for i, line in ipairs(locs) do
    if i <= 8 then
      items[#items + 1] = { label = line }
    end
  end
  if #locs == 0 then
    items[#items + 1] = { label = "(no encounter locations)" }
  end
  items[#items + 1] = {
    label = "SHOW PREVIEW",
    onSelect = function()
      if mod.ui and mod.ui.PicBox then
        game.stack:push(mod.ui.PicBox.new(game, imgPath,
          ("Overworld path: %s\nKind: %s"):format(tostring(imgKind), tostring(info.status))))
      end
    end,
  }
  items[#items + 1] = {
    label = "TEST SPAWN",
    onSelect = function()
      local result = logic:testSpawn(speciesId, { fromBrowser = true })
      local msg
      if result.ok then
        msg = ("Test spawn OK\n%s Lv%d at (%d,%d)\nAll 7 steps passed.")
          :format(tostring(speciesId), result.level or 1,
                  result.x or 0, result.y or 0)
      else
        msg = ("Test spawn failed at step %d:\n%s\n%s")
          :format(result.failedAt or 0,
                  tostring(result.stepName or "?"),
                  tostring(result.error or "unknown"))
      end
      if mod.ui and mod.ui.TextBox then
        game.stack:push(mod.ui.TextBox.new(game, msg))
      else
        DebugLog.info(mod, "%s", msg)
      end
    end,
  }

  return mod.ui.ListMenu.new(game, mon.name or speciesId, items, {
    pageJump = true,
    onChoose = function(item, menu)
      if item and item.onSelect then
        item.onSelect()
      end
    end,
  })
end

function PreviewBrowser:register()
  if self._registered then return end
  local mod = self.mod
  local browser = self

  mod.content.screens:register(PreviewBrowser.SCREEN, {
    new = function(game)
      if not Config.devMode(mod) then
        return mod.ui.ListMenu.new(game, "PREVIEW", {
          { label = "Enable Developer mode" },
        }, {
          onChoose = function(_, menu) menu:close() end,
        })
      end
      local items = browser:speciesRows(game)
      if #items == 0 then
        items = { { label = "Nothing matched filters" } }
      end
      local seen, owned = pokedexDiag(game)
      DebugLog.info(mod, "preview browser open rows=%d pokedex_seen=%s owned=%s (diag-only)",
                    #items, tostring(seen), tostring(owned))
      return mod.ui.ListMenu.new(game,
        ("OW PREVIEW %d"):format(#items), items, {
          pageJump = true,
          footer = "A: detail  B: close",
          onChoose = function(item)
            if item and item.value then
              mod.ui.push(game, PreviewBrowser.DETAIL, item.value)
            end
          end,
        })
    end,
  })

  mod.content.screens:register(PreviewBrowser.DETAIL, {
    new = function(game, speciesId)
      return browser:_openDetail(game, speciesId)
    end,
  })

  -- OPTIONS → activate row (public OptionRows activate API).
  mod.hooks:wrap("ui.options.rows", function(next, game, rows)
    local out = next(game, rows)
    if type(out) ~= "table" then return out end
    if Config.devMode(mod) then
      out[#out + 1] = {
        id = "overworld_wild_spawns_preview",
        label = "POKEMON PREVIEW",
        value = function() return "OPEN" end,
        activate = function(g)
          mod.ui.push(g, PreviewBrowser.SCREEN)
        end,
      }
    end
    return out
  end)

  -- Also reachable from Start Menu while Developer mode is on.
  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then return out end
    if not Config.devMode(mod) then return out end
    return mod.ui.insertBefore(out, "SAVE", {
      label = "OW PREVIEW",
      onSelect = function()
        mod.ui.push(game, PreviewBrowser.SCREEN)
      end,
    })
  end)

  self._registered = true
end

return PreviewBrowser
