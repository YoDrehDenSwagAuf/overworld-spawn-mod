# Manual test guide — Wilds of Kanto 1.0.0

## After installing 1.0.0

1. Remove any older Wilds of Kanto / `overworld_wild_spawns` copy from `mods/`.
2. Install only `wilds-of-kanto-v1.0.0.zip`.
3. Fully restart the game (content registry freezes after load).
4. Optional: delete `overworld_wild_spawns-cache/` in the save directory.

## Options smoke check

Confirm visible labels are not truncated (max 14 characters):

```text
Show Wild Mons / Hide Grass RNG / Mon Sprites / Spawn Amount / Grass View
Idle Mons / Roam Mons / Chase Mons / Hidden Mons / Dev Mode
```

Defaults for 1.0: Mon Sprites ON, Spawn Amount NORMAL, Grass View IMMERSED,
Roam / Chase / Hidden ON, Dev Mode OFF.

## Developer HUD (nearest entity)

```text
Species key: PIKACHU
Dex ID: 25
Runtime manifest key: 25:normal
Runtime relative path: assets/generated/followsprites_runtime/025-normal.png
Runtime resolved path: mods/overworld_wild_spawns/assets/generated/followsprites_runtime/025-normal.png
Runtime sheet load: READY
Runtime image dimensions: 16x96
Registration kind: native_runtime_sheet
Fallback used: NO
Body renderer: NATIVE_SPRITE_RENDERER
Sprite frames: 6
Walker: true
Overlay body draw: NO
First person compatible: NATIVE
```

## Flat 2D (no Dramatic Shape)

1. Idle Look changes facing with phase 0.
2. Wander / chase uses walk phase mid-step and toggles flip after each tile.
3. Real Pokemon art (not question mark) for Bulbasaur / Pikachu / Mew.
4. Hidden grass entities show no Pokemon body.

## Dramatic Shape — orbit + First Person

Same native sheet path: depth, walls, grass, shadows, upright FP billboards.
No post-voxel Pokemon body on the success path.

## Update detection

See [docs/RELEASE_TEST.md](docs/RELEASE_TEST.md) for the GitHub Release /
Mod Manager update checklist (`github` = `YoDrehDenSwagAuf/overworld-spawn-mod`).
