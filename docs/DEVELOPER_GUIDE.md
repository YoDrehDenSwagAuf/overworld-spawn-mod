# Overworld Wild Pokemon — Developer Guide (0.4.0)

This document describes the **implemented** architecture. It does not invent Gen1Recomp APIs.

## 1. Project structure

Repository root **is** the mod (DramaticShape layout):

```text
manifest.json  main.lua  options.lua  mod.card
assets/  lib/  docs/  tests/  scripts/
```

Local engine: `./scripts/bootstrap.sh` → `.deps/gen1recomp` with symlink
`mods/overworld_wild_spawns` → repo root.

## 2. Mod lifecycle

`main.lua` returns `function(mod)`. During load:

1. Virtual `V.require` loads `lib/*.lua`
2. `Config.defineOptions`
3. `SpawnRender:registerContent()` — **only** content-registry writes
4. Register HUD / preview / behaviour-tick pipelines
5. Hook `encounter.roll` + `movement.collision` when enabled
6. Subscribe to map/world/battle/save/options events

Gen1Recomp freezes content registries after all mods load.

## 3. Content registration

`SpawnRender:registerContent()` registers:

- `SPRITE_OW_WILD_PLACEHOLDER`
- `SPRITE_OW_WILD_FALLBACK` → `assets/fallback/pokemon_missing.png`
- `SPRITE_OW_WILD_<SPECIES>` per `mod.content.pokemon` entry (battle front or fallback)

Sets `contentRegistrationOpen = false` afterward.

## 4. Registry freeze

Never call `mod.content.sprites:register|override|patch|remove` from map callbacks,
test spawn, or preview. Runtime uses `speciesSpriteIds` lookup + image path resolve only.

## 5. Sprite resolution

Ordered candidates (species **id** first, not display name alone):

explicit map → dex-padded PNG → species_id PNG → display-name token →
battle front/back → menu icon → optional save-dir cache → fallback

## 6. Runtime image cache

`resolvedAssetBySpeciesId` / `runtimeImageCache` hold paths and bake results.
Optional bake writes `overworld_wild_spawns-cache/<id>.png` as a **LÖVE virtual**
path (never `getSaveDirectory()` absolute paths).

## 7. Fallback sprite

`assets/fallback/pokemon_missing.png` is always registered. Hidden behaviours
**do not** load fallback art — they draw shake/dust only.

## 8. Encounter data source

`game.data.encounters[mapId]`:

| Kind | Free overworld spawn? |
|---|---|
| `grass` | Yes (routes + caves) |
| `water` | Yes (Surf table on water tiles) |
| `fishing` | **No** — rod only; preview index only |

## 9. Map analysis

`Surface.resolve(game, map, encDef)`:

1. Grass table + `isGrassCell` tiles → `GRASS`
2. Grass table + indoor/cave rule → `CAVE` (walkable tiles)
3. Water table → `WATER`
4. Else unsupported → vanilla left intact

Indoor rule mirrors Gen1Recomp:
`map.def.index >= field.indoorEncounters.firstIndoorMap` and
`tileset ~= excludedTileset` (FOREST), with tileset/id fallbacks for fixtures.

## 10. Encounter-tile detection

| Mode | Source |
|---|---|
| grass | `Map:isGrassCell` |
| water | `Map:isWaterCell` |
| walkable (cave) | walkable ∧ ¬warp ∧ ¬water |

Rejects: blocked, warp, NPC, other wild, player, distance band.

## 11. Spawn regions

`SpawnRegions.build` flood-fills 4-connected eligible tiles.
`allocate` spreads target count by region size (tiny patches ≤1, ~6 tiles/mon cap).

## 12. Spawn capacity

```text
raw = minVisible + floor(eligibleTiles / tilesPerAdditional) + softSpanBonus
raw *= densityFactor(low/normal/high/very_high)
clamp to [minVisible, maxVisible] and eligible/3
```

Eligible tiles dominate; raw width×height is not used alone.

## 13. Entity lifecycle

`AVAILABLE` → (`ENCOUNTER_STARTING`) → despawn → battle → `REMOVED`
Records in `logic.spawns` / `logic.entities` / `logic.byMap`.

## 14. Render path

Entities implement `pose()` / `draw()` on `ow.entities`.
Scaled draw uses `love.graphics.draw` + nearest filter; feet-biased growth.
Engine `TileRenderer:drawCellBottom` after every entity on grass provides
the player/NPC grass overdraw — no custom black mask.

## 15. Grass overlay

Implemented by Gen1Recomp for all `ow.entities` on grass cells.
Mod sets `grass_tuck_px = 0` by default so sprites are not pushed into the turf.
`inGrassOverlay` tracks live cell grass for HUD.

## 16. Sprite scaling

`SpriteScale.compute`: visible bounds (when ImageData available) → target height
~16–28px → species overrides → clamp [1, 2]. Collision remains one cell.

## 17. Behaviour state machines

See `lib/behavior.lua`. Tick via `lib/behavior_tick.lua` present pipeline
(`owwild_behavior_tick`) because Gen1Recomp has no `world.tick` and only
updates `ow.npcs`.

Aggressive alert reuses `ow.emote = { npc = entity, frames = 60, ... }`
(same emotion-bubble path as trainers).

## 18. Battle trigger

`world:queueScript({ { "start_battle", "wild", species, level } })`
`pendingBattle` + entity state prevent double starts.
Contact: `world.stepped` tile match + `movement.collision` bump.

## 19. Water support

- Surf table → visible water entities on water tiles
- Stay on connected water for wander
- Slight visual sink (`waterSink = 2`)
- Vanilla water `encounter.roll` **not** suppressed
- Fishing tables never used for free spawns

## 20. Cave support

- No dependence on grass graphics
- Walkable indoor tiles
- Hidden uses dust/shadow, never grass shake

## 21. Developer mode

HUD pipeline `owwild_debug_hud`: Target / Active / Regions / Surface + nearest
entity detail (behaviour, scale, sight, hidden flags).
Overlays: spawn tiles + optional behaviour/sight fills.

## 22. Preview browser

`ui.options.rows` activate row + Start Menu item (no button option type).
Global encounter index; Test spawn 7 phases; never mutates registries.

## 23. Logging

`[OverworldSpawn][LEVEL]` via `debug_log.lua`. Forced on when `dev_mode`.

## 24. Tests

```sh
cd .deps/gen1recomp
luajit mods/overworld_wild_spawns/tests/overworld_wild_spawns_test.lua
```

## 25. Release build

```sh
./scripts/bootstrap.sh   # once
./scripts/build-mod.py
```

Produces `dist/overworld_wild_spawns-0.4.0.zip` with `manifest.json` at ZIP root.
Includes `docs/`. Excludes `tests/`, `scripts/`, `.deps/`, root `ARCHITECTURE.md`.

## 26. Known technical constraints

- No public wild-battle helper beyond script verb `start_battle`
- No continuous mod tick except present pipelines / events listed above
- Trainer sight has no wall LOS in vanilla; this mod **does** block aggressive sight on non-walkable tiles
- Single-frame sheets ignore SpriteRenderer facing; Idle Look flips in custom draw
- Voxel path may not mirror 2D scale

## 27. Adding behaviours

1. Add constant + weights in `lib/behavior.lua`
2. Allow on surfaces in `Surface.BEHAVIORS`
3. Implement branch in `Behavior.tick`
4. Expose option toggle if player-facing
5. Extend tests + docs

## 28. Species configuration

Central tables only:

- `SPECIES_AFFINITY` in `behavior.lua`
- `SPECIES_SCALE` in `sprite_scale.lua`
- Optional `speciesAssetPaths` in `spawn_render.lua`

Avoid scattered `if speciesId == ...` in spawn_logic.

## Implemented knacks (carry forward)

- ZIP root = mod root
- ASCII-only manager metadata (`manifest.json` / `mod.card` / `options.lua`)
- No registry writes after load
- Pre-register all species sprites at load
- Species id for asset identity
- Real art vs fallback
- LÖVE virtual paths only for images
- Vanilla encounter fail-safe
- Pokédex independence
- Entity create ≠ render success diagnostics
- Debug phases on Test spawn
- Preview browser without freezing registries
