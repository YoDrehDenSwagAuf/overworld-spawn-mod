# Manual test guide — Wilds of Kanto 0.7.0

## Developer HUD (nearest entity)

```text
Body renderer: NATIVE_SPRITE_RENDERER
Sprite sheet: assets/generated/followsprites_runtime/025-normal.png
Sprite frames: 6
Walker: true
Facing: ...
Phase: ...
Flip: ...
In ow.entities: YES
Dramatic Shape pose accepted: YES
Overlay body draw: NO
First person compatible: NATIVE
```

## Flat 2D (no Dramatic Shape)

1. Idle Look changes facing with phase 0.
2. Wander / chase uses walk phase mid-step and toggles flip after each tile.
3. Sprite size is one tile; no jitter between frames.
4. Hidden grass entities show no Pokemon body.

## Dramatic Shape — orbit

1. Grass covers feet (immersed).
2. Bushes / walls / buildings occlude the Pokemon.
3. Pokemon in front of objects stays visible.
4. Shadow matches the current frame.
5. No double body (no post-voxel body draw).

## Dramatic Shape — First Person

1. View from front / left / right / behind — facing remaps natively.
2. Card stays upright and yawed to the camera (no edge-on vanish).
3. Walls and buildings still occlude.
4. No overlay-sized screen sprite; size matches trainers.
5. Walk while looking at the Pokemon — phase/flip animate.

## Regenerating sheets

```text
python3 tools/generate_runtime_sprite_sheets.py --force
# or
powershell -File tools/generate_runtime_sprite_sheets.ps1 -Force
```
