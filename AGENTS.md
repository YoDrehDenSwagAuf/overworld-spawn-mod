# AGENTS.md

## Cursor Cloud specific instructions

This repo (`overworld-spawn-mod`) is a single **Lua mod** for the **Gen1Recomp**
engine (a Pokémon Red/Blue/Yellow port that runs on LÖVE2D). The mod itself is
pure Lua under `mods/overworld-spawns/`; there is no compiled build step.

### Interpreter
- The environment update script installs **LuaJIT** (`luajit`), which is the
  canonical interpreter: LÖVE 11.x embeds LuaJIT 2.1 and the code targets Lua
  5.1 semantics. Do **not** validate with `lua5.4` — it will green-light syntax
  the game can't run.

### First-time setup to run tests (engine is fetched on demand)
- The engine and the reference Voxel mod are **not** vendored; they are cloned by
  `./scripts/bootstrap.sh` into `./gen1recomp/` and `./DramaticShapeVoxelMod/`
  (both git-ignored) and this mod is symlinked into `gen1recomp/mods/`.
- Run `./scripts/bootstrap.sh` once per fresh VM before testing. It is idempotent
  (skips clones that already exist). This is intentionally **not** in the startup
  update script because it clones external repos over the network.

### Test / lint (all ROM-free, run from the `gen1recomp/` root after bootstrap)
- This mod's suite: `luajit mods/overworld-spawns/tests/overworld_spawns_test.lua`
  (loads the mod through the real engine loader against the committed
  `tests/fixture_data` dataset — no ROM needed).
- Broader engine gate (what CI runs): `./scripts/test.sh --quick`.
  - There is **no separate linter**; the ROM-free LuaJIT test tiers are the lint
    gate. Engine CI = `./scripts/test.sh`.
  - Known unrelated noise: the bundled `DRAMATIC_SHAPE` reference mod (an
    optional dependency cloned by bootstrap) currently has 2 failing tests on its
    default branch (missing `lib/TileShape.lua`). `overworld-spawns` passes all
    of its own checks; do not treat the Voxel-mod failures as this repo's bug.

### Running the full game (GUI) — needs a user-supplied ROM
- The playable game requires **LÖVE 11.x** plus a **legally-obtained** Pokémon
  Red/Blue/Yellow ROM (never committed; see `.gitignore`). Steps live in the
  root `README.md`: place the ROM in `gen1recomp/`, run
  `cd gen1recomp && ./scripts/setup.sh` (Python venv + Pillow decode), then
  `./scripts/run.sh`. This cannot run headlessly in the cloud (no ROM + needs a
  display); use the ROM-free test harness above to validate mod logic instead.
