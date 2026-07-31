# Overworld Wild Pokemon

Visible wild Pokemon in Gen1Recomp overworld encounter areas. Touch one to battle that exact species and level. Density scales with encounter area size; four behaviours (Idle, Wander, Aggressive, Hidden); grass feet-overdraw matches the player/NPCs.

**Does not change the player spawn point.** Pokédex is never required. Vanilla grass encounters stay active until the visible system is ready.

## Features (0.4.0)

- Map-aware spawn density and connected spawn regions
- Idle Look · Grass Wander · Aggressive (`!` chase) · Hidden grass/cave
- Engine tall-grass overlay + nearest-neighbor sprite scaling
- Grass, cave (no grass graphics), and Surf-water surfaces
- Fishing stays rod-only
- Developer HUD, tile overlay, Pokemon preview browser
- Fail-safe vanilla grass fallback

## Install

1. Build or download `overworld_wild_spawns-0.4.0.zip`
2. Gen1Recomp Mod Manager (F10) → Import → Enable

ZIP root must contain `manifest.json` (no wrapping folder).

```sh
./scripts/bootstrap.sh   # once
./scripts/build-mod.py
# → dist/overworld_wild_spawns-0.4.0.zip
```

## Quick start

1. Enable the mod
2. New game → Route 1 (before Pokédex is fine)
3. Look for wild Pokemon or shaking grass
4. Optional: raise **Spawn density** for busier long routes
5. Optional: **Developer mode** for the debug HUD and preview browser

## Documentation

| Doc | Audience |
|---|---|
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md) | Players — options, behaviours, water/caves, troubleshooting |
| [docs/DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md) | Modders — lifecycle, surfaces, AI, tests, release |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Compact component / data-flow overview |
| [MANUAL_TEST.md](MANUAL_TEST.md) | Manual test checklist |
| [CHANGELOG.md](CHANGELOG.md) | Version history |

## Current limitations

- Temporary overworld art from battle fronts when dedicated sheets are missing
- Aggressive chase uses tile steps
- Water spawns are Surf-table only; vanilla Surf rolls remain active
- Fishing never free-spawns
- Voxel billboards may not match custom 2D scale

## Headless tests

```sh
cd .deps/gen1recomp
luajit mods/overworld_wild_spawns/tests/overworld_wild_spawns_test.lua
python3 tools/modkit.py validate mods/overworld_wild_spawns
```

## Build

```sh
./scripts/build-mod.py
# or: pwsh ./scripts/build-mod.ps1
```
