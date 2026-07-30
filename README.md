# Overworld Wild Pokémon

Visible wild Pokémon appear in eligible overworld encounter areas (grass in 0.1.0) using each map's real encounter table. Walk onto one to start that exact wild battle.

**This mod does not change the player spawn point.** It never teleports, warps, or repositions the player on load, map enter, or enable.

Compatible with vanilla 2D Gen1Recomp; optionally coexists with Dramatic Shape Voxel mode (`DRAMATIC_SHAPE`).

## Repository layout

Same model as [DramaticShapeVoxelMod](https://github.com/DramaticShape/DramaticShapeVoxelMod): **the repository root is the mod**.

```text
overworld_wild_spawns/          ← importable mod root
├── manifest.json
├── main.lua
├── options.lua
├── mod.card
├── README.md
├── CHANGELOG.md
├── assets/
├── lib/
├── tests/                      ← excluded from release ZIP
├── scripts/                    ← bootstrap / pack tooling (excluded)
├── ARCHITECTURE.md             ← excluded from release ZIP
└── .deps/                      ← local engine clones (gitignored, not packed)
```

Do **not** import a raw GitHub source archive as the mod. Use the release ZIP from `./scripts/build-mod.py`.

## Install

1. Build or download `overworld_wild_spawns-0.1.0.zip` (or `overworld_wild_spawns.zip`).
2. In Gen1Recomp, open the **Mod Manager** (F10) and import the ZIP.
3. Enable **Overworld Wild Pokémon** with the normal Mod Manager switch.

### ZIP layout (required)

Opening the ZIP must show `manifest.json` immediately — no wrapping folder, no `mods/`, no `scripts/`:

```text
overworld_wild_spawns.zip
├── manifest.json
├── main.lua
├── options.lua
├── mod.card
├── README.md
├── CHANGELOG.md
├── assets/
└── lib/
```

Build (requires `./scripts/bootstrap.sh` once):

```sh
./scripts/build-mod.py
# or
pwsh ./scripts/build-mod.ps1
```

Output:

- `dist/overworld_wild_spawns-0.1.0.zip`
- `dist/overworld_wild_spawns.zip` (alias)

### Symlink / developer install

```sh
./scripts/bootstrap.sh
# links this repo into .deps/gen1recomp/mods/overworld_wild_spawns
# then enable in F10 Mod Manager
```
## Enable / disable

| Control | Effect |
|---|---|
| Mod Manager switch (off) | Mod not loaded: vanilla behavior, no overworld wild entities, no hooks |
| Option **Show wild Pokémon in the overworld** (`enabled`, default **true**) | When false while the mod is loaded: remove all mod entities, unwrap encounter/collision hooks, and restore vanilla random grass encounters |

## Options

- **Show wild Pokémon in the overworld** — spawn visible wild Pokémon in eligible areas
- **MAX SPAWNS** — cap per map (default 5)
- **SPAWN RATE** — steps between spawn attempts (default NORMAL / 8)
- **ON ENTER** — initial wave size (default 3)
- **HIDE RANDOM GRASS** — suppress vanilla random grass rolls (default on)
- **SPRITE FADE** — opacity so mons read as tucked into grass

## Supported encounter areas (0.1.0)

- Grass tiles on maps with a grass encounter table (`rate > 0` and slots)

Not yet spawning in: water, caves-as-distinct-tables, fishing-only zones, indoor maps, towns without encounter data.

Spawns never appear on blocked tiles, warps/exits, the player, or occupied cells.

## Classic random encounters

When the mod is enabled and **HIDE RANDOM GRASS** is on:

- Vanilla **grass** random rolls are suppressed via the public `encounter.roll` hook
- Encounters instead start by contacting a visible wild Pokémon

Still fully vanilla:

- Fishing
- Surf / water rolls
- Static overworld Pokémon
- Scripted encounters
- Legendaries as map objects
- Trainer battles
- Safari Zone engine behavior (aside from grass rolls if that map uses grass tables)

If you turn **HIDE RANDOM GRASS** off, classic grass rolls and visible spawns can both occur.

## Spawn limits (defaults)

| Setting | Default |
|---|---|
| Max visible wild Pokémon per map | 5 |
| Min distance from player | 4 tiles |
| Max distance / despawn | 12 tiles |
| Spawn check interval | every 8 player steps |
| Wander | occasional step within grass |

## Map changes and saves

- Leaving a map removes all mod-created Pokémon for that map
- Entering a map re-reads encounter data and may spawn an initial wave
- Save/load does not persist wild entities; the system reinitializes for the current map
- No durable writes to player position, story flags, NPCs, Pokédex, party, boxes, or items
- Mod options live in Gen1Recomp's global options file, not inside the playthrough save blob as map state

## Dramatic Shape Voxel Mod

Compatible with Dramatic Shape Voxel Mod (`DRAMATIC_SHAPE`) when present — no hard or optional dependency is declared in the manifest.

- This mod does **not** replace render pipelines, cameras, or voxel modules
- Wild entities use the engine `pose()` / `draw()` contract and sit on `OverworldState.entities`
- With Dramatic Shape enabled and VOXEL mode active, billboards are drawn by VoxelScene automatically
- Without Dramatic Shape, vanilla 2D rendering works unchanged
- Staged overworld battles in Dramatic Shape cull non-player entities from the arena shot (known Dramatic Shape behavior)
- Compatibility was checked against the public entity contract in source; full in-engine VOXEL playtesting still depends on a local ROM + LÖVE setup

## Headless tests

From a Gen1Recomp checkout with this mod linked:

```sh
luajit mods/overworld_wild_spawns/tests/overworld_wild_spawns_test.lua
python3 tools/modkit.py validate mods/overworld_wild_spawns
python3 tools/modkit.py lint mods/overworld_wild_spawns
```

## Known limitations

- Grass-only spawn zones in 0.1.0
- Species art falls back to a bundled placeholder when battle fronts are unavailable
- Complex flee/aggro AI is not implemented; mons stand or wander slowly in grass
- Player must supply their own legal Gen 1 ROM for Gen1Recomp asset decode
