#!/usr/bin/env bash
# Clone Gen1Recomp + DramaticShapeVoxelMod under .deps/ and link this repo (the mod).
# Layout matches DramaticShapeVoxelMod: the repository root IS the mod.
# Engine clones live in .deps/ so modkit pack never walks them (dot-dirs are skipped).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/.deps"
ENGINE_URL="${GEN1RECOMP_URL:-https://github.com/bryanthaboi/gen1recomp.git}"
VOXEL_URL="${VOXEL_URL:-https://github.com/DramaticShape/DramaticShapeVoxelMod.git}"
ENGINE="$DEPS/gen1recomp"
VOXEL="$DEPS/DramaticShapeVoxelMod"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd "$ROOT"

[ -f "$ROOT/manifest.json" ] || fail "missing manifest.json at repo root"
[ -f "$ROOT/main.lua" ] || fail "missing main.lua at repo root"

mkdir -p "$DEPS"

# Migrate legacy in-tree clones from earlier bootstrap versions.
if [ -d "$ROOT/gen1recomp/.git" ] && [ ! -d "$ENGINE/.git" ]; then
  say "migrating gen1recomp/ → .deps/gen1recomp/"
  mv "$ROOT/gen1recomp" "$ENGINE"
fi
if [ -d "$ROOT/DramaticShapeVoxelMod/.git" ] && [ ! -d "$VOXEL/.git" ]; then
  say "migrating DramaticShapeVoxelMod/ → .deps/DramaticShapeVoxelMod/"
  mv "$ROOT/DramaticShapeVoxelMod" "$VOXEL"
fi

if [ ! -d "$ENGINE/.git" ]; then
  say "cloning Gen1Recomp engine (dev branch)"
  git clone --depth 1 --branch dev "$ENGINE_URL" "$ENGINE"
else
  say "Gen1Recomp already present at .deps/gen1recomp"
fi

if [ ! -d "$VOXEL/.git" ]; then
  say "cloning Dramatic Shape Voxel Mod"
  git clone --depth 1 "$VOXEL_URL" "$VOXEL"
else
  say "DramaticShapeVoxelMod already present at .deps/DramaticShapeVoxelMod"
fi

say "linking this repo into .deps/gen1recomp/mods/overworld_wild_spawns"
mkdir -p "$ENGINE/mods"
rm -f "$ENGINE/mods/overworld-spawns"
ln -sfn "$ROOT" "$ENGINE/mods/overworld_wild_spawns"

say "linking Dramatic Shape into .deps/gen1recomp/mods/DRAMATIC_SHAPE"
ln -sfn "$VOXEL" "$ENGINE/mods/DRAMATIC_SHAPE"

cat <<EOF

Bootstrap complete.

Next steps:
  1. Copy a legal Pokemon Red/Blue/Yellow ROM into .deps/gen1recomp/
       e.g.  .deps/gen1recomp/Pokemon Red.gb
  2. Decode assets:
       cd .deps/gen1recomp && ./scripts/setup.sh
  3. Play:
       ./scripts/run.sh
  4. Enable "Wilds of Kanto" in the F10 Mod Manager.
     Optionally enable Dramatic Shape and press 3 for VOXEL mode.
  5. Package an importable ZIP (manifest.json at archive root):
       ./scripts/build-mod.py

EOF
