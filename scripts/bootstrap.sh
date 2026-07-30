#!/usr/bin/env bash
# Clone Gen1Recomp + DramaticShapeVoxelMod and link this repo's mod in.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_URL="${GEN1RECOMP_URL:-https://github.com/bryanthaboi/gen1recomp.git}"
VOXEL_URL="${VOXEL_URL:-https://github.com/DramaticShape/DramaticShapeVoxelMod.git}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd "$ROOT"

if [ ! -d "$ROOT/gen1recomp/.git" ]; then
  say "cloning Gen1Recomp engine"
  git clone --depth 1 "$ENGINE_URL" "$ROOT/gen1recomp"
else
  say "Gen1Recomp already present"
fi

if [ ! -d "$ROOT/DramaticShapeVoxelMod/.git" ]; then
  say "cloning Dramatic Shape Voxel Mod"
  git clone --depth 1 "$VOXEL_URL" "$ROOT/DramaticShapeVoxelMod"
else
  say "DramaticShapeVoxelMod already present"
fi

[ -d "$ROOT/mods/overworld-spawns" ] \
  || fail "missing mods/overworld-spawns in this repository"

say "linking overworld-spawns into gen1recomp/mods/"
mkdir -p "$ROOT/gen1recomp/mods"
ln -sfn "$ROOT/mods/overworld-spawns" "$ROOT/gen1recomp/mods/overworld-spawns"

say "linking Dramatic Shape into gen1recomp/mods/DRAMATIC_SHAPE"
ln -sfn "$ROOT/DramaticShapeVoxelMod" "$ROOT/gen1recomp/mods/DRAMATIC_SHAPE"

cat <<EOF

Bootstrap complete.

Next steps:
  1. Copy a legal Pokemon Red/Blue/Yellow ROM into gen1recomp/
       e.g.  gen1recomp/Pokemon Red.gb
  2. Decode assets:
       cd gen1recomp && ./scripts/setup.sh
  3. Play:
       ./scripts/run.sh
  4. Enable "Overworld Spawns" in the F10 Mod Manager.
     Optionally enable Dramatic Shape and press 3 for VOXEL mode.

EOF
