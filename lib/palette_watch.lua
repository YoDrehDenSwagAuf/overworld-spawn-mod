-- PaletteFX COLORS mode watcher.
--
-- The colored sprite art is the default; the -grayscale sheets serve every
-- PaletteFX mode except redpp (ADVANCED), which bakes real per-tile color
-- and wants the colored art. The engine exposes no mode-change event
-- (COLORS menu / hotkey 2 assign src.render.PaletteFX.mode directly), so
-- this module watches the resolved gate each frame and, on a redpp <->
-- non-redpp flip, re-resolves sprite art so the switch lands without a game
-- restart:
--   1. AnimatedSprites caches are cleared (mapping choices and the
--      species:variant image/quad caches are mode-dependent).
--   2. Every live wild entity is re-applied through the provider so its
--      SpriteRenderer sheet swaps immediately.
--   3. The follower sprite is refreshed through its lifecycle handler.
--
-- Only the *boundary* flip matters: toggling between non-redpp modes keeps
-- grayscale, and toggling within redpp keeps colored.
local V = ...
local Config = V.require("config")

local PaletteWatch = {}
PaletteWatch.__index = PaletteWatch

function PaletteWatch.new(mod, logic)
  local self = setmetatable({}, PaletteWatch)
  self.mod = mod
  self.logic = logic
  self._lastRedpp = nil -- nil = unknown; never fire on the first tick
  return self
end

function PaletteWatch:tick(game, ow)
  local redpp = Config.paletteFxRedpp()
  if self._lastRedpp ~= nil and redpp ~= self._lastRedpp then
    self:_onModeFlip(game, ow)
  end
  self._lastRedpp = redpp
end

function PaletteWatch:_onModeFlip(game, ow)
  local logic = self.logic
  local render = logic and logic.render
  local follower = logic and logic.follower

  -- 1. Drop mode-dependent caches so mappings / images / quads rebuild.
  local animated = render and render.animated
  if animated then
    if animated.mappingsBySpeciesId then animated.mappingsBySpeciesId = {} end
    if animated.imageCache then animated.imageCache = {} end
    if animated.quadCache then animated.quadCache = {} end
    if animated.voxelCardCache then animated.voxelCardCache = {} end
    if animated.billboardCache then animated.billboardCache = {} end
  end

  -- 2. Re-resolve every live wild so already-drawn sprites swap art now.
  -- applyProviderSprite's fast path compares entity.paletteRedpp, so the flip
  -- forces a real rebuild instead of the no-op early return.
  if render and logic and logic.entities then
    for _, entity in pairs(logic.entities) do
      if entity and render.applyProviderSprite then
        pcall(render.applyProviderSprite, render, entity, game)
      end
    end
  end

  -- 3. Refresh the follower sprite (primary via the lifecycle handler, which
  -- also re-applies water-compat presentation).
  if follower and follower.lifecycle
     and follower.lifecycle.requestFollowerSpriteRefresh then
    pcall(follower.lifecycle.requestFollowerSpriteRefresh,
          follower.lifecycle, "palette_mode", { game = game, ow = ow })
  end

  -- 4. Re-sync trailers (extra followers) so their sheets swap too.
  if follower and follower.syncTrailers then
    pcall(follower.syncTrailers, follower, game, ow, {})
  end
end

return PaletteWatch
