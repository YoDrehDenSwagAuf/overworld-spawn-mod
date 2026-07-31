# Architecture — Wilds of Kanto 0.4.1

Public name: **Wilds of Kanto**. Technical id: `overworld_wild_spawns`.

## Components

| Module | Role |
|---|---|
| `main.lua` | Load-phase wiring, hooks, exports |
| `options.lua` | Mod Manager schema |
| `lib/config.lua` | Defaults + option helpers |
| `lib/surface.lua` | GRASS / CAVE / WATER surface resolve |
| `lib/spawn_regions.lua` | Connected regions + density target |
| `lib/behavior.lua` | Behaviour pick + state machines |
| `lib/behavior_tick.lua` | Present-pipeline AI tick |
| `lib/sprite_scale.lua` | Visible-bounds scale |
| `lib/grass.lua` | Tile eligibility / pickers |
| `lib/encounter_pick.lua` | Weighted table picks |
| `lib/encounter_index.lua` | Preview location index |
| `lib/spawn_logic.lua` | Lifecycle, spawn, battle |
| `lib/spawn_render.lua` | Sprite register + entities |
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
  aggressive alert → ow.emote "!"
  chase contact → battle

battle.ended / map.exited / enabled=false
  cleanup
```

## Spawn data flow

```text
Map entered
→ resolve environment (surface)
→ load encounter table
→ collect eligible tiles
→ build connected spawn regions
→ calculate target count (density)
→ choose species + behaviour
→ resolve sprite (or skip for hidden)
→ create entity
→ register ow.entities
→ render (+ engine grass overdraw)
→ contact or detection
→ start_battle wild
→ cleanup
```

## Render process

1. Entity on `OverworldState.entities` with `pose()` / `draw()`
2. Base path: custom nearest-neighbor scaled blit (or SpriteRenderer)
3. Engine `drawCellBottom` after each entity on grass cells (feet overdraw)
4. Hidden: draw shake/dust only — no Pokemon sprite / no fallback
5. Optional Voxel: same `pose()` billboard contract

## Battle process

```text
AVAILABLE → ENCOUNTER_STARTING → queueScript start_battle → despawn → IN_BATTLE
pendingBattle prevents double start
species/level taken from the entity record (never re-rolled)
```

## Behaviour state machines

- **IDLE_LOOK**: timer 5–10s → change facing
- **GRASS_WANDER**: pause / step inside `homeRegion` only
- **AGGRESSIVE**: idle → sight → ALERT (`ow.emote`) → CHASE (may leave home) → contact
- **HIDDEN_***: periodic shake/dust; step/collision starts battle

## Surface system

| Surface | Tiles | Table | Hidden effect |
|---|---|---|---|
| GRASS | `isGrassCell` | grass | grass shake |
| CAVE | walkable indoor | grass | dust/shadow |
| WATER | `isWaterCell` | water (Surf) | none |
| Fishing | — | never free-spawn | — |

## Fail-safe / fallback

Vanilla grass `encounter.roll` suppressed only when `SpawnState:canSuppressVanilla()`.
Water/fishing rolls always pass through. Missing art → black fallback sprite (visible behaviours only).
