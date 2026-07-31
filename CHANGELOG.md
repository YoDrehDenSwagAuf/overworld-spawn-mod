# Changelog

## 0.4.0

### Added

- **Map-aware spawn density** from eligible encounter tiles + connected regions
  (`spawn_density`, min/max visible, tiles-per-additional, refill interval).
- **Four behaviours**: Idle Look, Grass Wander, Aggressive, Hidden Grass/Cave.
- **Aggressive** spotting with engine `ow.emote` exclamation, chase (may leave
  grass), single unavoidable battle; sight blocked by non-walkable tiles.
- **Hidden** markers: grass shake or cave dust — no Pokemon sprite / no fallback.
- **Surface abstraction**: GRASS, CAVE, WATER (Surf), with fishing kept rod-only.
- **Cave spawns** on walkable indoor tiles without requiring grass graphics.
- **Water spawns** from Surf encounter tables on water cells (optional).
- **Sprite scaling** (nearest-neighbor, bounds/species aware) so small mons stay
  readable in tall grass; engine `drawCellBottom` feet overdraw unchanged.
- Behaviour tick present-pipeline (`owwild_behavior_tick`).
- Developer HUD fields: Target / Active / Regions / Surface + entity detail.
- Behaviour overlay option; expanded options categories.
- Docs: `docs/USER_GUIDE.md`, `docs/DEVELOPER_GUIDE.md`, `docs/ARCHITECTURE.md`.

### Changed

- Default max visible raised to 12 (density-capped); min player distance 3;
  spawn band expanded for long routes.
- Sprite opacity default Solid (1.0); grass tuck default 0 (engine overlay).
- Version **0.4.0**.

### Notes

- Pokédex remains unused as a gate. Player is never teleported.
- Vanilla grass rolls suppressed only when the spawn system is READY.
- Vanilla water/fishing rolls are not suppressed.
- DramaticShapeVoxelMod remains optional.

## 0.3.2

### Fixed

- **`cache/<species>.png: Does not exist` entity errors.** Runtime 16×16 bake
  no longer returns `love.filesystem.getSaveDirectory() .. "/" .. rel` (an OS
  absolute path). `love.graphics.newImage` / `Assets.image` only accept LÖVE
  virtual paths, so the absolute path made every baked sprite fail to load and
  surfaced as `…cache/pidgey.png: Does not exist.`
- Bake now returns the relative save-dir path `overworld_wild_spawns-cache/<id>.png`.
- Placeholder / fallback paths use `assets/…` under the mod root via
  `mod.assets:path`.
- Missing optional cache files no longer abort spawn or test spawn.

### Added

- Species-id-first asset resolution with ordered candidates (explicit map →
  dex-padded → species id → display-name token → battle front/back → optional
  cache → black fallback).
- Static fallback sprite `assets/fallback/pokemon_missing.png` registered at
  load (`SPRITE_OW_WILD_FALLBACK`). Used when no real image is available.
- Preview browser shows real-asset path / exists / fallback / runtime image
  status and a short tried list (full details in the log).
- Dev-mode asset audit on map enter / `game.ready`.
- Concrete entity phase errors (`ASSET LOAD ERROR`, `WORLD REGISTER ERROR`, …).

### Notes

- Temporary overworld presentation uses Gen1 battle-front sprites scaled to
  16×16 when no dedicated overworld PNG is shipped.
- Pokédex remains unused as a gate. DramaticShapeVoxelMod remains optional.
- Does **not** change the player spawn point, warp, or teleport the player.

## 0.3.1

### Fixed

- **Content registry freeze crash on Test spawn.** `spriteIdFor()` no longer
  calls `mod.content.sprites:register` at runtime. Gen1Recomp freezes content
  registries after mod load; registering from the preview browser / test spawn
  path caused `sprites: content is frozen after load`.
- All overworld sprite definitions are registered once during mod
  initialization (`SpawnRender:registerContent()`), then looked up via an
  immutable `speciesSpriteIds` table.
- Missing pre-registered sprites return a controlled error (preview shows
  UNAVAILABLE / Test spawn DISABLED) instead of crashing.
- Runtime 16×16 sheet baking is cache-only and never mutates content registries.

### Notes

- Pokédex remains unused as a gate. DramaticShapeVoxelMod remains optional.
- Does **not** change the player spawn point, warp, or teleport the player.

## 0.3.0

### Added

- **Developer mode** (`dev_mode`) with live Mod Manager toggle.
- Compact spawn debug HUD (top-right) via public `render_pipelines` `present`
  pass (`owwild_debug_hud`). Shows unique species, encounter slots, eligible
  tiles, loaded assets, active Pokemon, spawn/renderer status, visibility
  counters, and last error.
- **Keep spawn debug HUD visible** (`debug_hud_always_visible`).
- Pokemon preview browser (OPTIONS → POKEMON PREVIEW / Start Menu → OW PREVIEW)
  listing every species available to the mod with asset status, renderer status,
  global encounter locations, and **Test spawn**.
- Test spawn phase diagnostics (7 steps) with exact failure reporting.
- **Allow test spawn outside encounter areas** (dev-only debug).
- **Show valid spawn tiles** overlay via passable marker entities.
- Structured `[OverworldSpawn][LEVEL]` debug logging with change/throttle gating.
- Global encounter location index with per-route level-range collapse.

### Notes

- Pokédex status is never a gate for spawns, preview, assets, or test spawns.
- DramaticShapeVoxelMod remains optional.
- Does **not** change the player spawn point, warp, or teleport the player.
- Options are live-toggleable (`mod.options_changed`); no restart required.
