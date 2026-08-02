# Architecture — Wilds of Kanto 0.6.0

Public name: **Wilds of Kanto**. Technical id: `overworld_wild_spawns`.

## Components

| Module | Role |
|---|---|
| `main.lua` | Load-phase wiring, hooks, exports |
| `options.lua` | Mod Manager schema |
| `lib/config.lua` | Defaults + option helpers |
| `lib/json_decode.lua` | Minimal JSON decoder for mappings |
| `lib/animated_sprites.lua` | Follow-sprite mapping, lazy images/quads, animation, card cache |
| `lib/enhanced_world_sprite.lua` | Stable DS SpriteRenderer-compatible adapter |
| `lib/tile.lua` | Gen1Recomp tile size (16x16) |
| `lib/movement.lua` | Central tile-step movement |
| `lib/grass_occlusion.lua` | Flat feet-overdraw + above-lift helpers |
| `lib/voxel_adapter.lua` | DS hooks; emergency overlay filter |
| `lib/surface.lua` | GRASS / CAVE / WATER surface resolve |
| `lib/spawn_regions.lua` | Connected regions + density target |
| `lib/behavior.lua` | Behaviour pick + state machines |
| `lib/behavior_tick.lua` | Present-pipeline AI tick + hidden FX |
| `lib/sprite_scale.lua` | Legacy visible-bounds → one-tile 2D scale |
| `lib/grass.lua` | Tile eligibility / pickers |
| `lib/encounter_pick.lua` | Weighted table picks |
| `lib/encounter_index.lua` | Preview location index |
| `lib/spawn_logic.lua` | Lifecycle, spawn, battle |
| `lib/spawn_render.lua` | Sprite register + entities + pose/draw |
| `lib/spawn_state.lua` | Fail-safe readiness flags |
| `lib/diagnostics.lua` | HUD snapshot / renderer source lines |
| `lib/debug_hud.lua` | Present-only debug HUD |
| `lib/debug_overlay.lua` | Spawn-tile markers |
| `lib/preview_browser.lua` | Dev species browser + anim preview |

## Verified Dramatic Shape pose contract

```text
pose() → sprite, visualX, visualY, facing, phase, flip [, hop]
posesOf uses: sprite, visualX, e.py, facing, phase, flip
lift = e.py - visualY
ground = groundAt(map, e.cellX, e.cellY)
sprite must provide: def + resolveImage() → love Image
```

Entity billboards are **fixed 16x16** meshes. Sheet+Quad is not accepted by DS.
Wilds supplies cached 16x16 card Images; DS owns depth, grass mesh, occlusion.

## Flat vs Voxel presentation

```text
FLAT (no Dramatic Shape / voxel off)
  Entity:draw → follow-sprite quad (native tile size) or legacy PNG

VOXEL (Dramatic Shape drawWorld active)
  Wild entities stay in ow.entities
  pose() → EnhancedWorldSprite (stable)
  resolveImage() → cached 16x16 follow-sprite card
  VoxelScene SpriteBillboards → depth + object occlusion + native grass
  ctx.drawFx → alert emotes; Pokemon BODY only if SPATIAL_OVERLAY_EMERGENCY
```

Primary Pokemon renderer: `WORLD_BILLBOARD_ENHANCED`.

## Grass rendering (`pokemon_grass_render_mode`)

| Mode | Flat 2D | Voxel (world billboard) |
|------|---------|-------------------------|
| `above` | Lift clears engine `drawCellBottom` | `visualY` lift (`grass_above_lift_px`); object occlusion stays |
| `immersed` (default) | Engine `drawCellBottom` after entity | DS tall-grass mesh after cast (`DRAMATIC_SHAPE_NATIVE`) |

No custom grass color/mask on the success world-billboard path.

## Follow-sprites

- PNGs: `assets/enhanced_overworld/followsprites/{id}-{form}-{n|s}.png`
- Mapping: `assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json`
- Identity: numeric speciesId / dex only
- Layout: rows = directions, columns = frames (verified)
- Shared animation state: `BehaviorTick` → `syncEntityAnimation`
- `animation.renderRevision` increments only on visible changes
- Image cache: `speciesId:variant`; quad/card: `speciesId:variant:anim:dir:frame:...`
- UV carrier asset: `assets/runtime/dynamic_billboard_base.png`
- Runtime shiny: NOT AVAILABLE (preview may force shiny)

## Non-negotiables

- No Pokedex gate for spawns
- No player teleport
- Battle starts exactly once per encounter
- No content-registry mutation after load
- Hidden encounters never show Pokemon follow-sprites
- Valid follow-sprites are never replaced by Legacy because Voxel is on
- Legacy SpriteRenderer is never mutated for the enhanced voxel path
- Commercial Anima atlas PNG must not be packaged
