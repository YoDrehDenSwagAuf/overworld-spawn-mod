# Changelog

## 0.1.0

### Added

- Visible wild Pokémon on grass tiles using each map's real encounter table.
- Exact wild battle on contact (species and level match the visible spawn).
- Mod Manager toggle plus option `Show wild Pokémon in the overworld` (`enabled`, default true).
- Spawn caps, min/max player distance, spawn interval, and simple grass wander.
- Optional suppression of vanilla random grass rolls via public `encounter.roll` hook.
- Dual-mode rendering: vanilla 2D SpriteRenderer and VoxelScene billboards when Dramatic Shape is active.
- Map/save lifecycle cleanup; spawns are runtime-only and never written into the playthrough save.
- Packaging scripts and automated modkit tests.

### Notes

- Does **not** change the player spawn point, warp, or teleport the player.
- Water, cave, fishing, static, scripted, legendary, trainer, and Safari encounters are not replaced.
