# Changelog

## 0.2.0

### Fixed

- **Fail-safe for vanilla grass encounters.** Classic random grass rolls are
  suppressed only after the visible spawn system is ready for the current map
  (`initialized`, encounter data, eligible tiles, renderer, verified entity
  pipeline). If any prerequisite fails, vanilla encounters stay active.
- Soft-lock where enabling the mod disabled grass rolls without showing
  overworld Pokemon.
- Progressive spawn-tile search so small maps are not left with zero candidates.
- `pcall` paths now log errors and restore vanilla encounters instead of
  swallowing failures.

### Changed

- Initialization order: map → encounter data → tiles → renderer → controlled
  spawn → only then allow grass suppression.
- Default `initial_spawns` is 1 (minimal standing-spawn vertical path).
- Wander is off by default until the standing-spawn path is proven in play.
- Debug options: `debug_logging`, `force_test_spawn`.

### Notes

- The Pokédex was never a spawn gate in this mod and remains unused as one.
- DramaticShapeVoxelMod stays optional; base 2D Gen1Recomp rendering is enough.
- Does **not** change the player spawn point, warp, or teleport the player.

## 0.1.0

### Added

- Loader-recognizable `manifest.json` at the mod root (`api` 2, `options_schema`, current `game_version` range from Gen1Recomp `dev`).
- Visible wild Pokemon on grass tiles using each map's real encounter table.
- Exact wild battle on contact (species and level match the visible spawn).
- Mod Manager toggle plus option `Show wild Pokemon in the overworld` (`enabled`, default true).
- When `enabled` is false: clear mod entities, unwrap encounter/collision hooks, and restore vanilla grass rolls.
- Spawn caps, min/max player distance, spawn interval, and simple grass wander.
- Optional suppression of vanilla random grass rolls via public `encounter.roll` hook.
- Dual-mode rendering: vanilla 2D SpriteRenderer and VoxelScene billboards when Dramatic Shape is active.
- Map/save lifecycle cleanup; spawns are runtime-only and never written into the playthrough save.
- Repository root is the mod (DramaticShapeVoxelMod layout). Release ZIP is built with `modkit pack` so `manifest.json` sits at the archive root - no wrapping folder, no `mods/` / `scripts/` / `.git`.
