# Overworld Spawn Mod

Custom Gen1Recomp mod that spawns visible wild Pokémon on grass tiles and starts the matching wild battle on contact. Compatible with vanilla 2D and Dramatic Shape Voxel mode.

## Workspace layout

```
overworld-spawn-mod/
├── mods/overworld-spawns/     ← the mod (drop into gen1recomp/mods/)
├── scripts/bootstrap.sh       ← clone engine + Voxel Mod, link this mod
├── gen1recomp/                ← engine execution root (created by bootstrap)
└── DramaticShapeVoxelMod/     ← reference Voxel Mod (created by bootstrap)
```

Gen1Recomp is the main execution root after bootstrap. This repository ships the mod and setup scripts; the engine and Voxel Mod are cloned on demand.

## Quick start (ROM + LÖVE2D)

### 1. Bootstrap dependencies

```sh
./scripts/bootstrap.sh
```

This clones `bryanthaboi/gen1recomp` and `DramaticShape/DramaticShapeVoxelMod`, then symlinks:

- `mods/overworld-spawns` → `gen1recomp/mods/overworld-spawns`
- Voxel Mod → `gen1recomp/mods/DRAMATIC_SHAPE`

### 2. Place a legal ROM

Put **your own** dump of Pokémon Red or Blue (or Yellow) here:

```
gen1recomp/Pokemon Red.gb
# or
gen1recomp/Pokemon Blue.gb
# or
gen1recomp/Pokemon Yellow.gbc
```

Any filename ending in `.gb` / `.gbc` in the `gen1recomp/` root works. You can also pass an explicit path:

```sh
cd gen1recomp
./scripts/setup.sh --rom "/path/to/Pokemon Red.gb"
```

`setup.sh` will:

1. Create a Python venv and install Pillow
2. Decode ROM data into `data/generated/` and assets into `assets/generated/`
3. Verify LÖVE 11.x is installed

The ROM is **not** copied into the generated cache; keep it where you placed it (or pass `--rom` each time you rebuild).

### 3. Install LÖVE 11.x

- https://love2d.org — or `brew install --cask love` on macOS
- Linux: install the `love` package for your distro (11.x)

### 4. Launch

```sh
cd gen1recomp
./scripts/run.sh
# developer console / hot-reload:
./scripts/run.sh --developer
```

### 5. Enable the mod

In-game: open the **Mod Manager** (F10) and enable **Overworld Spawns**.

Optional: also enable **Dramatic Shape Voxel Mod**, then press `3` to raise the VOXEL ladder — spawn billboards appear in 3D automatically.

### 6. Test on Route 1

Start a new game, reach Route 1, and walk the grass. Visible spawns appear periodically; step onto one to fight that species at the table level.

## Architecture notes

See [ARCHITECTURE.md](ARCHITECTURE.md) for the Gen1Recomp hook/API survey and how Dual-mode rendering follows Dramatic Shape's entity contract.

## Legal

You must supply your own legally obtained Pokémon Red/Blue/Yellow ROM. This project does not distribute Nintendo ROM data. The mod package ships only original placeholder art and Lua logic.
