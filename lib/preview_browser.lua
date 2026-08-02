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
PreviewBrowser.ANIM = "OverworldSpawnPreviewAnim"

local PREVIEW_DIRS = { "down", "up", "left", "right" }
local PREVIEW_ANIMS = { "idle", "walk" }

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
  self._preview = {
    speciesId = nil,
    anim = "idle",
    direction = "down",
    frameIndex = 1,
    elapsed = 0,
  }
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
      -- Lookup / status only — never registers content.
      local info = render:assetStatusFor(row.id, game)
      local locs = index[row.id] or {}
      local locLines = EncounterIndex.formatLocations(locs, mapFilter, kindFilter)
      local include = true
      if mapFilter ~= "" and #locLines == 0 then
        include = false
      end
      if include and filter == "asset_loaded" then
        include = info.status == "LOADED" or info.status == "FALLBACK_LOADED"
      elseif include and filter == "asset_missing" then
        include = info.status ~= "LOADED" and info.status ~= "FALLBACK_LOADED"
      elseif include and filter == "entity_ready" then
        local probe = render:probeEntity(game, row.id)
        include = probe.entityReady == true
      elseif include and filter == "entity_failed" then
        local probe = render:probeEntity(game, row.id)
        include = probe.entityReady ~= true
      end
      if include then
        local right = info.status
        if info.fallbackUsed then
          right = "FALLBACK"
        elseif not info.spriteRegistered and not info.fallbackAvailable then
          right = "UNAVAILABLE"
        elseif info.status == "FALLBACK_LOADED" then
          right = "FALLBACK"
        end
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
  render:invalidateAssetCache(speciesId)
  local info, _ = render:probeEntity(game, speciesId)
  local locs = EncounterIndex.formatLocations(
    index[speciesId] or {},
    Config.get(mod, "preview_map_filter") or "",
    Config.get(mod, "preview_encounter_kind") or "any")
  local imgPath, imgKind = render:previewImagePath(speciesId, game)
  local seen, owned = pokedexDiag(game)
  local AnimatedSprites = V.require("animated_sprites")
  local enh = render:enhancedStatusFor(speciesId, game)
  local dexId = enh.dexId or mon.dex
  local mapping = enh.mapping

  local runtimeLabel
  if enh.available then
    runtimeLabel = "ENHANCED ATLAS"
  elseif info.fallbackUsed then
    runtimeLabel = "FALLBACK LOADED"
  elseif info.realAssetLoaded then
    runtimeLabel = "REAL ASSET LOADED"
  else
    runtimeLabel = tostring(info.runtimeStatus or info.status)
  end

  local spawnSupported = info.entityReady == true
                      or info.status == "LOADED"
                      or info.status == "FALLBACK_LOADED"
  local items = {
    { label = "SPECIES ID", right = tostring(speciesId) },
    { label = "DEX / SPECIESID", right = tostring(dexId or "?") },
    { label = "LOCALIZED NAME", right = tostring(mon.name or speciesId) },
    { label = "MAPPING NAME", right = tostring((mapping and mapping.speciesName) or "(n/a)") },
    { label = "MAPPING FILE", right = tostring(enh.fileName or AnimatedSprites.mappingFileName(dexId or 0)) },
    { label = "MAPPING STATUS", right = tostring(enh.status or "?") },
    { label = "ATLAS LOADED", right = (render.animated and render.animated:isReady()) and "YES" or "NO" },
    { label = "LEGACY PNG", right = info.realAssetLoaded and "YES" or "NO" },
    { label = "BLACK FALLBACK", right = info.fallbackAvailable and "YES" or "NO" },
    { label = "CURRENT SOURCE", right = tostring(info.spriteSource or runtimeLabel) },
    { label = "SPRITE REG", right = info.spriteRegistered and "YES" or "NO" },
    { label = "2D RENDERER", right = tostring(info.renderer) },
    { label = "VOXEL ADAPTER", right = "EnhancedWorldSprite" },
    { label = "WORLD BILLBOARD", right = tostring(
      (render.worldBillboardReady and "READY")
        or (enh.available and "ENHANCED") or "LEGACY") },
    { label = "CARD SIZE", right = "16x16 (DS mesh)" },
    { label = "OW ENTITY", right = tostring(info.entityStatus or info.phase or "?") },
    { label = "TEST SPAWN", right = spawnSupported and "READY" or "DISABLED" },
    { label = "ENCOUNTERS", right = tostring(#locs) },
    { label = "POKEDEX SEEN", right = tostring(seen) .. " (diag)" },
    { label = "POKEDEX OWN", right = tostring(owned) .. " (diag)" },
  }

  if mapping and mapping.valid then
    for _, anim in ipairs(PREVIEW_ANIMS) do
      for _, dir in ipairs(PREVIEW_DIRS) do
        local frames = mapping[anim] and mapping[anim][dir] or {}
        items[#items + 1] = {
          label = (anim .. " " .. dir):upper(),
          right = tostring(#frames) .. " fr",
        }
      end
    end
    if mapping.partial and mapping.missingDirs and #mapping.missingDirs > 0 then
      items[#items + 1] = {
        label = "MISSING DIRS",
        right = table.concat(mapping.missingDirs, ","):sub(1, 22),
      }
    end
  elseif Config.useAnimatedOverworldSprites(mod) then
    items[#items + 1] = { label = "Enhanced sprite unavailable" }
    if info.fallbackUsed then
      items[#items + 1] = { label = "Using black fallback sprite" }
    else
      items[#items + 1] = { label = "Using legacy PNG fallback" }
    end
  end

  -- Short tried list on screen; full details go to the log.
  local tried = info.tried or {}
  if #tried > 0 then
    items[#items + 1] = { label = "TRIED:" }
    for i, t in ipairs(tried) do
      if i > 4 then break end
      local mark = t.loaded and "OK" or (t.exists and "FAIL" or "MISS")
      items[#items + 1] = {
        label = ("  %s %s"):format(mark, tostring(t.source)),
      }
    end
    DebugLog.info(mod, "asset resolve %s tried=%d result=%s path=%s",
                  tostring(speciesId), #tried, tostring(info.status),
                  tostring(info.resolvedPath or info.overworldSprite))
    for _, t in ipairs(tried) do
      DebugLog.info(mod, "  tried %s path=%s exists=%s loaded=%s err=%s",
                    tostring(t.source), tostring(t.path),
                    tostring(t.exists), tostring(t.loaded),
                    tostring(t.error))
    end
  end

  if info.fallbackUsed then
    items[#items + 1] = { label = "RESULT", right = "Fallback loaded" }
  elseif enh.available then
    items[#items + 1] = { label = "RESULT", right = "Enhanced atlas" }
  elseif info.realAssetLoaded then
    items[#items + 1] = { label = "RESULT", right = "Real asset loaded" }
  elseif info.lastError then
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

  if enh.available then
    items[#items + 1] = {
      label = "VOXEL PATH",
      right = "WORLD BILLBOARD",
    }
    items[#items + 1] = {
      label = "DS BILLBOARD",
      right = "ENHANCED CARD",
    }
    items[#items + 1] = {
      label = "ANIMATED PREVIEW",
      onSelect = function()
        self._preview.speciesId = speciesId
        self._preview.dexId = dexId
        self._preview.anim = "idle"
        self._preview.direction = "down"
        self._preview.frameIndex = 1
        self._preview.elapsed = 0
        mod.ui.push(game, PreviewBrowser.ANIM, speciesId)
      end,
    }
  end

  items[#items + 1] = {
    label = "SHOW PREVIEW",
    onSelect = function()
      if mod.ui and mod.ui.PicBox then
        game.stack:push(mod.ui.PicBox.new(game, imgPath,
          ("Overworld path: %s\nKind: %s\nRuntime: %s\nFallback: %s\nEnhanced: %s")
            :format(tostring(imgPath), tostring(imgKind),
                    tostring(runtimeLabel),
                    tostring(info.fallbackUsed),
                    tostring(enh.status))))
      end
    end,
  }
  if spawnSupported then
    items[#items + 1] = {
      label = "TEST SPAWN",
      onSelect = function()
        -- testSpawn must never register content; it only looks up IDs.
        local result = logic:testSpawn(speciesId, { fromBrowser = true })
        local msg
        if result.ok then
          msg = (result.summary or "TEST SPAWN SUCCESS")
            .. ("\n%s Lv%d at (%d,%d)\nRuntime: %s")
              :format(tostring(speciesId), result.level or 1,
                      result.x or 0, result.y or 0,
                      tostring(result.runtimeImage or runtimeLabel))
          if result.entity and result.entity.usingEnhancedSprite then
            msg = msg .. "\nSprite source: ENHANCED_ATLAS"
          elseif result.fallbackUsed then
            msg = msg .. "\nRendering with fallback sprite"
          else
            msg = msg .. "\nSprite source: LEGACY_PNG"
          end
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
  else
    items[#items + 1] = {
      label = "TEST SPAWN (DISABLED)",
      onSelect = function()
        local msg = ("Test spawn DISABLED\n%s\nReason: %s")
          :format(tostring(speciesId),
                  tostring(info.lastError or "No drawable sprite"))
        if mod.ui and mod.ui.TextBox then
          game.stack:push(mod.ui.TextBox.new(game, msg))
        else
          DebugLog.warn(mod, "%s", msg)
        end
      end,
    }
  end

  return mod.ui.ListMenu.new(game, mon.name or speciesId, items, {
    pageJump = true,
    onChoose = function(item, menu)
      if item and item.onSelect then
        item.onSelect()
      end
    end,
  })
end

function PreviewBrowser:_openAnimPreview(game, speciesId)
  local mod = self.mod
  local render = self.logic.render
  local animated = render.animated
  local AnimatedSprites = V.require("animated_sprites")
  local mon = (game.data.pokemon and game.data.pokemon[speciesId]) or {}
  local enh = render:enhancedStatusFor(speciesId, game)
  local dexId = enh.dexId
  local browser = self

  local function frameInfo()
    if not animated or not dexId then
      return { count = 0, w = 0, h = 0, idx = 1, cells = "?" }
    end
    local frame, count, idx = animated:getFrame(
      dexId, browser._preview.anim, browser._preview.direction,
      browser._preview.frameIndex)
    return {
      count = count or 0,
      w = frame and frame.width or 0,
      h = frame and frame.height or 0,
      idx = idx or 1,
      frame = frame,
      cells = frame and string.format("%dx%d", frame.widthCells, frame.heightCells) or "?",
    }
  end

  local fi = frameInfo()
  local mapping = enh.mapping
  local items = {
    { label = "SPECIES ID", right = tostring(dexId or "?") },
    { label = "LOCALIZED", right = tostring(mon.name or speciesId) },
    { label = "MAPPING NAME", right = tostring((mapping and mapping.speciesName) or "") },
    { label = "ANIMATION", right = browser._preview.anim:upper() },
    { label = "DIRECTION", right = browser._preview.direction:upper() },
    { label = "FRAME", right = string.format("%d / %d", fi.idx, math.max(1, fi.count)) },
    { label = "FRAME SIZE", right = string.format("%dx%d", fi.w, fi.h) },
    { label = "CELL SIZE", right = mapping and string.format("%dx%d", mapping.cellWidth, mapping.cellHeight) or "?" },
    { label = "CELLS WxH", right = fi.cells },
    { label = "RENDERED", right = string.format("%dx%d", fi.w, fi.h) },
    { label = "FALLBACK", right = tostring(enh.status) },
    {
      label = "PREVIEW GRASS",
      right = (browser._preview.grassOcclusion and "IMMERSED") or "ABOVE",
      onSelect = function()
        browser._preview.grassOcclusion = not browser._preview.grassOcclusion
        mod.ui.push(game, PreviewBrowser.ANIM, speciesId)
      end,
    },
    {
      label = "TOGGLE IDLE/WALK",
      onSelect = function()
        browser._preview.anim = (browser._preview.anim == "idle") and "walk" or "idle"
        browser._preview.frameIndex = 1
        browser._preview.elapsed = 0
        mod.ui.push(game, PreviewBrowser.ANIM, speciesId)
      end,
    },
  }
  for _, dir in ipairs(PREVIEW_DIRS) do
    items[#items + 1] = {
      label = "FACE " .. dir:upper(),
      onSelect = function()
        browser._preview.direction = dir
        browser._preview.frameIndex = 1
        browser._preview.elapsed = 0
        mod.ui.push(game, PreviewBrowser.ANIM, speciesId)
      end,
    }
  end
  items[#items + 1] = {
    label = "SHOW CURRENT FRAME",
    onSelect = function()
      local cur = frameInfo()
      local msg = ("Anim %s %s\nFrame %d/%d\nSize %dx%d\nStatus %s")
        :format(browser._preview.anim, browser._preview.direction,
                cur.idx, math.max(1, cur.count), cur.w, cur.h, tostring(enh.status))
      if mod.ui and mod.ui.TextBox then
        game.stack:push(mod.ui.TextBox.new(game, msg))
      end
    end,
  }

  return mod.ui.ListMenu.new(game,
    ("ANIM %s"):format(tostring(mon.name or speciesId)), items, {
      pageJump = true,
      footer = "A: action  B: back",
      onChoose = function(item)
        if item and item.onSelect then item.onSelect() end
      end,
      present = function(canvas, ctx)
        if not (love and love.graphics and animated and animated.atlasImage and dexId) then
          return canvas
        end
        local dt = (ctx and ctx.dt) or (1 / 60)
        local moving = browser._preview.anim == "walk"
        local state = {
          name = browser._preview.anim,
          direction = browser._preview.direction,
          frameIndex = browser._preview.frameIndex,
          elapsed = browser._preview.elapsed or 0,
          frameDuration = moving and AnimatedSprites.WALK_FRAME_DURATION
                          or AnimatedSprites.IDLE_FRAME_DURATION,
          usingEnhancedSprite = true,
        }
        animated:updateAnimation(state, dexId, dt, moving, browser._preview.direction)
        browser._preview.frameIndex = state.frameIndex
        browser._preview.elapsed = state.elapsed

        local frame = animated:getFrame(
          dexId, browser._preview.anim, browser._preview.direction,
          browser._preview.frameIndex)
        local quad = animated:getQuad(
          dexId, browser._preview.anim, browser._preview.direction,
          browser._preview.frameIndex)
        if not frame or not quad or quad._owwildStub then return canvas end

        love.graphics.push("all")
        love.graphics.setCanvas(canvas)
        local scale = 2
        local dw = frame.width * scale
        local dh = frame.height * scale
        local x = 16
        local y = ((ctx and ctx.height) or 144) - dh - 16
        love.graphics.setColor(0, 0, 0, 0.55)
        love.graphics.rectangle("fill", x - 4, y - 4, dw + 8, dh + 8)
        love.graphics.setColor(1, 1, 1, 1)
        if animated.atlasImage.setFilter then
          animated.atlasImage:setFilter("nearest", "nearest")
        end
        love.graphics.draw(animated.atlasImage, quad, x, y, 0, scale, scale)
        if browser._preview.grassOcclusion then
          local GrassOcclusion = V.require("grass_occlusion")
          local cover = GrassOcclusion.computeOcclusionHeight(frame.height) * scale
          love.graphics.setColor(0.2, 0.55, 0.25, 0.85)
          love.graphics.rectangle("fill", x - 4, y + dh - cover, dw + 8, cover + 4)
          love.graphics.setColor(1, 1, 1, 1)
        end
        love.graphics.pop()
        return canvas
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
        ("WILDS PREVIEW %d"):format(#items), items, {
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

  mod.content.screens:register(PreviewBrowser.ANIM, {
    new = function(game, speciesId)
      return browser:_openAnimPreview(game, speciesId)
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
      label = "WILDS PREVIEW",
      onSelect = function()
        mod.ui.push(game, PreviewBrowser.SCREEN)
      end,
    })
  end)

  self._registered = true
end

return PreviewBrowser
