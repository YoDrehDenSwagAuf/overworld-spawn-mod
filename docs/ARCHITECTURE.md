# Architecture — Wilds of Kanto 0.5.6

Public name: **Wilds of Kanto**. Technical id: `overworld_wild_spawns`.

## Components

| Module | Role |
|---|---|
| `main.lua` | Load-phase wiring, hooks, exports |
| `options.lua` | Mod Manager schema |
| `lib/config.lua` | Defaults + option helpers |
| `lib/json_decode.lua` | Minimal JSON decoder for mappings |
| `lib/animated_sprites.lua` | Atlas + 151 JSON load, quads, animation, card cache |
| `lib/enhanced_world_sprite.lua` | Stable DS SpriteRenderer-compatible adapter |
| `lib/tile.lua` | Gen1Recomp tile size (16×16) |
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

Entity billboards are **fixed 16×16** meshes. Atlas+Quad is not accepted.
Wilds supplies cached 16×16 card Images; DS owns depth, grass mesh, occlusion.

## Flat vs Voxel presentation

```text
FLAT (no Dramatic Shape / voxel off)
  Entity:draw → atlas quad (native size) or legacy PNG

VOXEL (Dramatic Shape drawWorld active)
  Wild entities stay in ow.entities
  pose() → EnhancedWorldSprite (stable)
  resolveImage() → cached 16×16 atlas card
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

## Animated sprites

- Atlas: `assets/enhanced_overworld/Pokemon_Sprites/POKEMON 1.png`
- Mappings: `assets/enhanced_overworld/pokedex_mapping/pokemon_%03d_project.json`
- Identity: numeric speciesId / dex only
- Shared animation state: `BehaviorTick` → `syncEntityAnimation`
- `animation.renderRevision` increments only on visible changes
- Card cache key: `speciesId:anim:direction:frameIndex:w:h`
- UV carrier asset: `assets/runtime/dynamic_billboard_base.png`

## Non-negotiables

- No Pokédex gate for spawns
- No player teleport
- Battle starts exactly once per encounter
- No content-registry mutation after load
- Hidden encounters never show Pokemon atlas sprites
- Valid atlas frames are never replaced by Legacy because Voxel is on
- Legacy SpriteRenderer is never mutated for the enhanced voxel path
