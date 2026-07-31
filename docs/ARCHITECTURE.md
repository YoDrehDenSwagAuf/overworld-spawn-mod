# Architecture — Wilds of Kanto 0.4.2

Public name: **Wilds of Kanto**. Technical id: `overworld_wild_spawns`.

## Components

| Module | Role |
|---|---|
| `main.lua` | Load-phase wiring, hooks, exports |
| `options.lua` | Mod Manager schema |
| `lib/config.lua` | Defaults + option helpers |
| `lib/tile.lua` | Gen1Recomp tile size (16×16) |
| `lib/movement.lua` | Central tile-step movement |
| `lib/voxel_adapter.lua` | Optional Voxel pose safety / fallback |
| `lib/surface.lua` | GRASS / CAVE / WATER surface resolve |
| `lib/spawn_regions.lua` | Connected regions + density target |
| `lib/behavior.lua` | Behaviour pick + state machines |
| `lib/behavior_tick.lua` | Present-pipeline AI tick + hidden FX |
| `lib/sprite_scale.lua` | Visible-bounds → one-tile 2D scale |
| `lib/grass.lua` | Tile eligibility / pickers |
| `lib/encounter_pick.lua` | Weighted table picks |
| `lib/encounter_index.lua` | Preview location index |
| `lib/spawn_logic.lua` | Lifecycle, spawn, battle |
| `lib/spawn_render.lua` | Sprite register + 2D entities |
| `lib/spawn_state.lua` | Fail-safe readiness flags |
| `lib/diagnostics.lua` | HUD snapshot / lines |
| `lib/debug_hud.lua` | Present-only debug HUD |
| `lib/debug_overlay.lua` | Spawn-tile markers |
| `lib/preview_browser.lua` | Dev species browser |

## Lifecycle

```text
LOAD
  define options
  SpawnRender:registerContent()   -- only registry writes
  register HUD / preview / behaviour tick pipelines
  install hooks if enabled

map.entered
  clear old entities
  Surface.resolve
  load encounter table (grass or water)
  collect eligible tiles → regions
  compute targetSpawnCount
  spawn initial wave
  mark pipelineVerified → may suppress vanilla grass

world.stepped
  contact tile? → battle
  despawn far
  refill toward target

behaviour tick (render_pipeline present)
  Idle look / wander / aggressive / hidden shake
  aggressive alert → ow.emote "!" (engine bubble, not a wild entity)
  chase contact → battle

battle.ended / map.exited / enabled=false
  cleanup
```

## Render separation

```text
World simulation (behavior + movement)
        │ read-only
        ├─► 2D renderer (Entity:draw / final2DScale)
        └─► Voxel adapter (pose() fields only; voxelScale = 1)
```

- Simulation owns position, facing, behaviour, species, collision, battle.
- Renderers never mutate simulation state.
- Dramatic Shape Voxel Mod billboards `ow.entities` via `pose()` — see
  `DramaticShapeVoxelMod/lib/VoxelScene.lua` (`posesOf`, `drawEntity`).
- Hidden markers are **logical-only** (not in `ow.entities`) so a nil sprite
  cannot retire the Voxel pipeline.

## Aggressive state machine

```text
IDLE → PLAYER_DETECTED → ALERT → CHASE_START → CHASING
    → BATTLE_PENDING → IN_BATTLE → CLEANUP
```

- Detection once; sight disabled afterward.
- ALERT: one `ow.emote` bubble; no movement; chase only via emote `onDone`.
- CHASING: central `Movement.beginStep` / `update` (cell finalizes after lerp).
- Battle queued exactly once (`pendingBattle`).

## Movement

NPC-compatible: `cellX/cellY` stay at the origin during a step; `px/py`
interpolate from previous → target; tile committed on completion.

Stable id: `wilds_of_kanto_entity_<n>` for the full lifetime.

## Sprite scale (2D)

```text
visibleBounds (ignore transparent margins)
desiredScale  = readability / species preference
maximumScale  = min(usableW/visW, usableH/visH)   -- usable ≈ 0.9×0.95 tile
final2DScale  = min(desiredScale, maximumScale)
```

Tile size is Gen1Recomp **16×16**. Logical footprint stays one tile.
Voxel cards stay 16×16 (`voxelScale = 1`); never reuse `final2DScale`.

Grass occlusion: `min(defaultGrassOcclusion, renderedVisibleHeight * 0.35)`.

## Fail-safe / fallback

- Vanilla grass `encounter.roll` suppressed only when `SpawnState:canSuppressVanilla()`.
- Per-entity Voxel failure → 2D fallback for that entity; world AI continues.
- Missing art → black fallback sprite (visible behaviours only).
