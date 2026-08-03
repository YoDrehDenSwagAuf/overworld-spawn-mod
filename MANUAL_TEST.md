# Manual test guide — Wilds of Kanto 1.0.2

## After installing 1.0.2

1. Remove any older Wilds of Kanto / `overworld_wild_spawns` copy from `mods/`.
2. Install only `wilds-of-kanto-v1.0.2.zip`.
3. Fully restart the game (content registry freezes after load).
4. Optional: delete `overworld_wild_spawns-cache/` in the save directory.

## Options smoke check

Confirm visible labels are not truncated (max 14 characters):

```text
Show Wild Mons / Hide Grass RNG / Sprite Style / Spawn Amount / Grass View
Idle Mons / Roam Mons / Chase Mons / Hidden Mons / Dev Mode
```

Sprite Style choices (also Start Menu → **SPRITE STYLE**):

```text
Auto / Gold Sprites / Followers EX / Crystal / PokeMMO / Pokedex
SPRITE STYLE / AUTO / GOLD SPRITES / FOLLOWERS EX / CRYSTAL / POKEMMO / POKEDEX
```

Defaults for 1.0: Sprite Style AUTO, Spawn Amount NORMAL, Grass View IMMERSED,
Roam / Chase / Hidden ON, Dev Mode OFF.

## Sprite style matrix

1. Only Wilds installed → Auto uses PokeMMO; Gold / Followers EX / Crystal fall back.
2. Wilds + Gold Sprites → Auto / Gold use Gold battle fronts (1-frame).
3. Wilds + Followers EX (+ PokePC) → Auto uses Followers when Gold absent.
4. Wilds + Crystal → Auto uses Crystal (static frame 001, normal/shiny) when
   Gold / Followers absent.
5. Wilds + multiple external mods → Auto prefers Gold → Followers EX → Crystal.
6. Explicit Crystal without pack → falls through to PokeMMO.
7. Hot-switch via Start Menu and Mod Settings — same `sprite_style` value,
   entities keep id/position/behaviour (sprite only).

Manual Crystal checks: Flat 2D, Dramatic Shape Orbit / First Person, normal +
shiny variants, grass/wall/object occlusion, install Crystal after Wilds,
remove Crystal and restart.

## Developer HUD (nearest entity)

```text
Requested style: AUTO
Active provider: GOLD
Provider mod: Gold_Silver_Sprites
Provider version: 1.0.1
Provider installed: YES
Species ID: 25
Variant: NORMAL
Sprite image: .../gold/battle/front/pikachu.png
Frames: 1
Walker: false
Fallback step: 1
Quick menu: READY
Body renderer: NATIVE_SPRITE_RENDERER
```

## Flat 2D (no Dramatic Shape)

1. Idle Look changes facing with phase 0.
2. Wander / chase uses walk phase mid-step and toggles flip after each tile.
3. Real Pokemon art (not question mark) for Bulbasaur / Pikachu / Mew.
4. Hidden grass entities show no Pokemon body.

## Dramatic Shape — orbit + First Person

Same native sheet path: depth, walls, grass, shadows, upright FP billboards.
No post-voxel Pokemon body on the success path. Gold / Pokedex 1-frame styles
use the legacy billboard scale path (still SpriteRenderer, no overlay).

## Update detection

See [docs/RELEASE_TEST.md](docs/RELEASE_TEST.md) for the GitHub Release /
Mod Manager update checklist (`github` = `YoDrehDenSwagAuf/overworld-spawn-mod`).
