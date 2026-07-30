# Architecture: Overworld Spawns on Gen1Recomp

## Gen1Recomp mod surface (survey)

Mods live one level under `mods/<id>/` with `manifest.json` + `main.lua`.
The loader exposes a sandboxed `mod` API:

| Surface | Use in this mod |
|---|---|
| `mod.events:on` | `map.entered`, `map.exited`, `world.stepped`, `battle.ended` |
| `mod.hooks:wrap` | `encounter.roll` (optional grass suppress), `movement.collision` (bump safety) |
| `mod.world` | `overworld()`, `queueScript({ {"start_battle","wild",species,level} })` |
| `mod.content.sprites` | Placeholder + baked 16×16 species sheets |
| `mod.options` | Cap, rate, opacity, suppress toggle |
| `mod.exports` | `logic` / `render` / `lib` for companions & tests |

There is no public `StartWildBattle` helper. Wild battles are started via the
script verb `start_battle` (which calls `BattleState.newWild`) or by letting
the grass encounter pipeline roll. This mod uses the script verb so the
spawned species/level are exact.

Encounter tables live at `game.data.encounters[mapId].grass` with
`rate`, `slots[{species,level}]`, and optional `buckets`. Grass cells are
`Map:isGrassCell(cx, cy)` on the live runtime map (`widthCells` × `heightCells`).

## Dramatic Shape Voxel Mod (survey)

`DRAMATIC_SHAPE` is presentational only. It registers `render_pipelines`
`voxel` / `tiltshift` and draws whatever is already on `OverworldState.entities`
through `VoxelScene` → `SpriteBillboards`, using each entity's `pose()`:

```text
e:pose() → sprite, vx, vy, facing, phase, flip [, hopping]
e.px, e.py, e.cellX, e.cellY
```

There is **no** inject-billboard API. The supported dual-mode path is to put
entities on `state.entities`. Companion access: `mod.find("DRAMATIC_SHAPE").exports.lib`.

Coordinate cheat-sheet:

| Space | Mapping |
|---|---|
| Cell → world px | `px = cellX * 16`, `py = cellY * 16` |
| 2D blit | `(px - camX, py - camY - 4)` |
| Voxel billboard feet | `(px + 8, groundAt + lift, py + 8)` |

## This mod's split

```
map.entered ──► SpawnLogic clears + initial wave
world.stepped ──► touch? start_battle : maybe trySpawn
trySpawn ──► EncounterPick + Grass.pickFree ──► SpawnRender.makeEntity
makeEntity ──► insert into ow.entities  (2D draw + Voxel billboard)
```

Logic never calls `love.graphics`. Rendering never queues battles.
`optional_dependencies: ["DRAMATIC_SHAPE"]` documents Voxel compatibility
without requiring it.

## ROM / generated data

`scripts/setup.sh` runs `tools/build_data.py --rom <ROM> --clean` →
`data/generated/` (Lua modules) and `assets/generated/` (PNG sheets, battle
fronts/backs, tilesets). `scripts/run.sh` requires `data/generated/maps.lua`
and launches `love <project-root>`.
