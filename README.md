# Overworld Spawn Mod

Gen1Recomp mod that spawns **visible wild Pokémon** in eligible overworld encounter areas and starts the matching wild battle on contact.

**It does not change the player spawn point** and never teleports or repositions the player.

Compatible with vanilla 2D Gen1Recomp; optionally coexists with Dramatic Shape Voxel mode (`DRAMATIC_SHAPE`).

## Workspace layout

```
overworld-spawn-mod/
├── mods/overworld_wild_spawns/   ← the mod (import ZIP or symlink into gen1recomp/mods/)
├── scripts/
│   ├── bootstrap.sh              ← clone engine + Voxel Mod, link this mod
│   ├── build-mod.py              ← pack dist/overworld_wild_spawns-0.1.0.zip
│   └── build-mod.ps1
├── gen1recomp/                   ← engine execution root (created by bootstrap)
└── DramaticShapeVoxelMod/        ← reference Voxel Mod (created by bootstrap)
```

## Quick start

### 1. Bootstrap

```sh
./scripts/bootstrap.sh
```

### 2. Place a legal ROM

```
gen1recomp/Pokemon Red.gb
```

### 3. Decode + launch

```sh
cd gen1recomp
./scripts/setup.sh
./scripts/run.sh
```

### 4. Enable the mod

F10 → Mod Manager → enable **Overworld Wild Pokémon**.

Optional: enable **Dramatic Shape Voxel Mod**, press `3` for VOXEL — spawn billboards appear via the shared entity `pose()` contract.

### 5. Package for import

```sh
./scripts/build-mod.py
# → dist/overworld_wild_spawns-0.1.0.zip
```

The ZIP has `manifest.json` and `main.lua` at the archive root (no outer folder).

## Docs

- [mods/overworld_wild_spawns/README.md](mods/overworld_wild_spawns/README.md) — install, options, behavior
- [ARCHITECTURE.md](ARCHITECTURE.md) — Gen1Recomp / Dramatic Shape API survey

## Legal

You must supply your own legally obtained Pokémon Red/Blue/Yellow ROM. This project does not distribute Nintendo ROM data.
