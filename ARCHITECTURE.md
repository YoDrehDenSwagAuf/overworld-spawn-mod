# Architecture: Overworld Wild Pokémon on Gen1Recomp

## Goal

Spawn **visible wild Pokémon** in eligible overworld encounter areas.
The mod does **not** change the player spawn point, warp, or teleport the player.

## Gen1Recomp mod surface (survey of current public API)

This repository follows the DramaticShapeVoxelMod layout: `manifest.json` +
`main.lua` live at the **repository root**. For local play, `scripts/bootstrap.sh`
clones the engine under `.deps/gen1recomp/` and symlinks the repo into
`.deps/gen1recomp/mods/overworld_wild_spawns/`. Release packages are produced
with `modkit pack` so the ZIP root is the mod root.

The loader exposes a sandboxed `mod` API (`src/mods/Loader.lua`, API version 2):

| Surface | Use in this mod |
|---|---|
| `mod.events:on` | `map.entered`, `map.exited`, `world.stepped`, `battle.ended`, `save.loaded`, `save.created`, `mod.options_changed` |
| `mod.hooks:wrap` | `encounter.roll` (optional grass suppress), `movement.collision` (bump safety) |
| `mod.world` | `overworld()`, `queueScript({ {"start_battle","wild",species,level} })` |
| `mod.content.sprites` | Placeholder + optional baked 16×16 species sheets |
| `mod.options` | `enabled`, caps, rate, opacity, suppress, `dev_mode`, HUD/overlay toggles (`options.lua`) |
| `mod.content.screens` | `OverworldSpawnPreview` / detail (dev browser) |
| `mod.content.render_pipelines` | present-only `owwild_debug_hud` |
| `mod.hooks` | `ui.options.rows` activate row, `ui.start_menu.items` (dev browser entry) |
| `mod.ui` | `ListMenu`, `PicBox`, `TextBox`, `Font`, `insertBefore`, `push` |
| `mod.exports` | `logic` / `render` / `hud` / `browser` / `testSpawn` for companions & tests |
| `mod.save` | unused — wild entities are runtime-only |

There is no public `StartWildBattle` helper. Wild battles are started via the
script verb `start_battle` (which calls `BattleState.newWild`) or by letting
the grass encounter pipeline roll. This mod uses the script verb so the
spawned species/level are exact.

Encounter tables live at `game.data.encounters[mapId].grass` with
`rate`, `slots[{species,level}]`, and optional `buckets`. Grass cells are
`Map:isGrassCell(cx, cy)` on the live runtime map (`widthCells` × `heightCells`).

Player-position APIs that this mod deliberately never calls:

- `WorldAPI:warpTo`
- script `warp`
- `SaveData.newGame` boot `startMap` / `startX` / `startY` / `startFacing`

## Dramatic Shape Voxel Mod (survey)

Manifest id: **`DRAMATIC_SHAPE`** (from DramaticShapeVoxelMod `manifest.json`).

`DRAMATIC_SHAPE` is presentational only. It registers `render_pipelines`
`voxel` / `tiltshift` and draws whatever is already on `OverworldState.entities`
through `VoxelScene` → `SpriteBillboards`, using each entity's `pose()`:

```text
e:pose() → sprite, vx, vy, facing, phase, flip [, hopping]
e.px, e.py, e.cellX, e.cellY
```

There is **no** inject-billboard API. The supported dual-mode path is to put
entities on `state.entities`. Companion access: `mod.find("DRAMATIC_SHAPE").exports.lib`.

This mod does not wrap Map/camera/BattleState methods and does not register
render pipelines. Optional dependency only documents coexistence.

Coordinate cheat-sheet:

| Space | Mapping |
|---|---|
| Cell → world px | `px = cellX * 16`, `py = cellY * 16` |
| 2D blit | `(px - camX, py - camY - 4)` |
| Voxel billboard feet | `(px + 8, groundAt + lift, py + 8)` |

## This mod's split

```
map.entered ──► SpawnLogic clears + initial wave (if enabled)
                 └── Diagnostics + DebugHud markMapEnter (dev_mode)
world.stepped ──► touch? start_battle : despawn-far / wander / trySpawn
trySpawn ──► EncounterPick + Grass.pickFree ──► SpawnRender.makeEntity
makeEntity ──► insert into ow.entities  (2D draw + Voxel billboard)
OPTIONS activate / Start Menu ──► PreviewBrowser (dev_mode)
testSpawn ──► 7-phase diagnosis (species→asset→tile→create→register→renderer→visible)
enabled=false / map.exited / save.loaded ──► clearAll
```

Developer HUD uses a present-only `render_pipelines` record (does not replace
the world pass). Tile overlay uses passable marker entities on `ow.entities`.

Logic never calls `love.graphics`. Rendering never queues battles.
Voxel coexistence uses the shared entity `pose()` contract only — no
`optional_dependencies` or invented permissions beyond `engine_internals`
(required for `SpriteRenderer`).

## Vanilla grass rolls (fail-safe)

`encounter.roll` returns `nil` for `ctx.terrain == "grass"` only when
`SpawnLogic:canSuppressVanilla()` is true:

```text
initialized
AND mapSupported
AND encounterDataAvailable
AND eligibleTilesAvailable
AND rendererAvailable
AND updateCallbackRegistered
AND pipelineVerified
AND lastError == nil
AND enabled
AND suppress_random_grass
```

Init order on `map.entered`: map → encounter data → grass tiles
(`Map:isGrassCell`) → renderer probe → controlled spawn → then allow suppress.
On any failure, vanilla grass rolls stay active. The Pokédex is never consulted.

Water, fishing, and other terrains always pass through.

## ROM / generated data

`scripts/setup.sh` runs `tools/build_data.py --rom <ROM> --clean` →
`data/generated/` (Lua modules) and `assets/generated/` (PNG sheets, battle
fronts/backs, tilesets). `scripts/run.sh` requires `data/generated/maps.lua`
and launches `love <project-root>`.
