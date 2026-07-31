# Changelog

## 0.4.2

### Fixed

- **Dramatic Shape Voxel Mod corruption during aggressive chase**: hidden
  wild markers (nil sprite) no longer join `ow.entities`. A nil `sprite.def`
  in VoxelScene's `posesOf` / `shadowSignature` / `drawEntity` path was
  retiring the entire DRAMATIC_SHAPE render pipeline for the session.
- **Aggressive alert/chase state machine**: detection fires once; movement
  stops during ALERT; chase starts only from the engine emote `onDone`
  (no parallel timer); tile steps use NPC-compatible previous/current
  pixel interpolation so Voxel billboards stay coherent when leaving grass.
- **2D sprites larger than one map tile**: final scale is now
  `min(desiredReadableScale, oneTileMaxScale)` from non-transparent visible
  bounds, capped to Gen1Recomp's 16×16 cell. Aspect ratio preserved
  (nearest-neighbor).

### Added

- `lib/tile.lua` — Gen1Recomp tile size (16) as the single source of truth.
- `lib/movement.lua` — central tile-step movement (IDLE/ALERT/MOVING/CHASING).
- `lib/voxel_adapter.lua` — read-only Voxel safety checks + per-entity 2D
  fallback when a wild entity would break the Voxel pose contract.
- Stable entity ids: `wilds_of_kanto_entity_<n>` for the full lifetime.
- Dev HUD lines for scale bounds, stable id, Voxel fallback, alert/battle.
- `tests/voxel_aggressive_compat_test.lua` — simulated VoxelScene pose path
  through alert → chase → battle.

### Changed

- "Minimum Pokemon sprite size" option: preferred readable size only; never
  bypasses the one-tile footprint cap.
- Grass occlusion height is relative to rendered visible height
  (`min(default, renderedH * 0.35)`).
- Voxel billboard scale stays `1` (16×16 card); 2D `final2DScale` is never
  reused as a Voxel world scale.

## 0.4.1

### Changed

- Renamed the public mod title to **Wilds of Kanto** (technical id
  `overworld_wild_spawns` unchanged for save/options compatibility).
- Reworked the README with installation, features, compatibility notes and
  project background.
- Added clearer links to Gen1Recomp and Dramatic Shape Voxel Mod.
- Updated visible HUD / preview titles and debug log prefix to match the
  public name.
- Release ZIP primary filename is now `wilds-of-kanto-v<version>.zip`
  (technical-id aliases still written).

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
