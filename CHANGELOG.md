# Changelog

## 0.1.0

### Added

- Loader-recognizable `manifest.json` at the mod root (`api` 2, `options_schema`, current `game_version` range from Gen1Recomp `dev`).
- Visible wild Pokemon on grass tiles using each map's real encounter table.
- Exact wild battle on contact (species and level match the visible spawn).
- Mod Manager toggle plus option `Show wild Pokemon in the overworld` (`enabled`, default true).
- When `enabled` is false: clear mod entities, unwrap encounter/collision hooks, restore vanilla grass rolls.
- Spawn caps, min/max player distance, spawn interval, and simple grass wander.
- Optional suppression of vanilla random grass rolls via public `encounter.roll` hook.
- Dual-mode rendering: vanilla 2D SpriteRenderer and VoxelScene billboards when Dramatic Shape is active.
- Map/save lifecycle cleanup; spawns are runtime-only and never written into the playthrough save.
- Repository root is the mod (DramaticShapeVoxelMod layout). Release ZIP is built with `modkit pack` so `manifest.json` sits at the archive root - no wrapping folder, no `mods/` / `scripts/` / `.git`.

### Notes

- Does **not** change the player spawn point, warp, or teleport the player.
- Water, cave, fishing, static, scripted, legendary, trainer, and Safari encounters are not replaced.
