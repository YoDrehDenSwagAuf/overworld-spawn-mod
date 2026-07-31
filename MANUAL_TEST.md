# Manual test guide — Wilds of Kanto 0.4.2

## A. Normal 2D presentation

1. Import `dist/wilds-of-kanto-v0.4.2.zip`, enable mod + Developer mode.
2. Open the Pokemon preview browser.
3. Select a very small species and a very large species.
4. Check HUD / detail: Source image size, Visible bounds, Tile size 16×16,
   Desired scale, Maximum one-tile scale, Final 2D scale, Rendered visible size.
5. Test-spawn both. Confirm each occupies at most one map tile (outline).
6. Stand them in tall grass — upper body remains visible (relative occlusion).
7. Confirm logical footprint stays one tile (adjacent walk / contact).

## B. Voxel Mod + aggressive chase

1. Enable Dramatic Shape Voxel Mod and Wilds of Kanto.
2. Press the Voxel hotkey (usually `3`) so VOXEL is active.
3. Force / wait for an aggressive wild Pokemon (or test-spawn with aggressive
   behaviour if available via options).
4. Enter its facing sight line.
5. Confirm one `!` bubble (engine emote), short pause, no teleport.
6. Chase in all four directions; let it leave grass.
7. Contact → exactly one wild battle.
8. After battle, return to the overworld: terrain, camera, NPCs, Voxel world
   still intact; no blank / flat-fallback world.
9. Dev HUD: stable entity id unchanged across alert→chase; Voxel update OK
   (or per-entity 2D fallback only for a broken entity).

## C. Error case (per-entity Voxel fallback)

1. With Voxel active, use a test adapter / injected failure (dev) so one wild
   entity's Voxel update fails.
2. Confirm only that entity falls back to 2D.
3. Confirm the rest of the Voxel world keeps rendering.

## D. Automated (ROM-free)

```sh
cd .deps/gen1recomp
lua mods/overworld_wild_spawns/tests/overworld_wild_spawns_test.lua
lua mods/overworld_wild_spawns/tests/voxel_aggressive_compat_test.lua
```

## E. Regression checklist

- [ ] Vanilla grass encounters still work when spawn system is not ready
- [ ] Pokédex empty does not block spawns
- [ ] Player position never teleports
- [ ] Four behaviours still selectable (Idle / Wander / Aggressive / Hidden)
- [ ] Content registries are not written after load
