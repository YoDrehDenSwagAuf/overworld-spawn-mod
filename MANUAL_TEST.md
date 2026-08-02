# Manual test guide — Wilds of Kanto 0.6.0

## Critical: prove the actual body path

Developer mode on. Inspect one wild Pokemon in the HUD:

```text
Requested renderer: ...
Actual body renderer: ...
Sprite system: FOLLOW_SPRITES
Variant: NORMAL
Runtime shiny support: NOT AVAILABLE
Pose calls: ...
Enhanced resolveImage calls: ...
Dramatic billboard accepted: YES/NO
Post-voxel body draw calls: ...
Emergency overlay body draw calls: ...
Failure reason: ...
```

### Success (real DS billboard)

```text
Requested renderer: WORLD_BILLBOARD_ENHANCED
Actual body renderer: DRAMATIC_SPRITE_BILLBOARD
Sprite system: FOLLOW_SPRITES
Pose calls: > 0
Enhanced resolveImage calls: > 0
Dramatic billboard accepted: YES
Post-voxel body draw calls: 0
Emergency overlay body draw calls: 0
Depth integration: ACTIVE
Grass renderer: DRAMATIC_SHAPE_NATIVE
```

### Likely pre-fix failure (overlay)

```text
Actual body renderer: SPATIAL_OVERLAY_EMERGENCY
Emergency overlay body draw calls: > 0
Enhanced resolveImage calls: 0
Dramatic billboard accepted: NO
```

## A. Follow-sprite species

With enhanced sprites enabled, test-spawn or preview:

| Species | Expect |
|---------|--------|
| 1 | Bulbasaur follow-sprite idle/walk |
| 25 | Pikachu male follow-sprite (`025-m-n.png`) |
| 151 | Mew follow-sprite |
| >151 (preview only) | Listed in preview if mapped; not spawned by Gen1 gameplay |

## B. Directions

For species 1, 25, and 151:

- Idle: Down / Left / Right / Up
- Walk: Down / Left / Right / Up (4-frame cycle)

Confirm without and with Dramatic Shape.

## C. Behaviour

- Idle Look — turns to new idle facing
- Wander — walk frames while moving
- Aggressive chase — walk frames toward player
- Hidden Grass — no Pokemon sprite

## D. Renderer

- Without Dramatic Shape: 2D follow-sprite path
- With Dramatic Shape: world billboard, native grass/occlusion
- Grass, bush, wall, trainer depth checks

## E. Shiny

- Preview browser → Variant Normal / Shiny
- Normal gameplay always uses NORMAL (runtime shiny not available)
- Do not expect random overworld shinies

## F. Fallback

1. Temporarily rename one follow PNG (e.g. `025-m-n.png`) → legacy Pokédex art
2. Also remove/break legacy → black fallback
3. Restore files afterward

## G. Packaging

Release ZIP must contain:

- `assets/enhanced_overworld/followsprites/`
- `assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json`
- must **not** contain `assets/enhanced_overworld/Pokemon_Sprites/POKEMON 1.png`

## Strict World Billboard Debug

1. Enable Developer mode.
2. Enable **Strict World Billboard Debug**.
3. Optionally enable **Strict magenta billboard probe**.
4. Dramatic Shape on; spawn Species 5.
5. Emergency/post-voxel bodies are fully disabled.

| Result | Meaning |
|--------|---------|
| Pokemon visible (or magenta card) | DS billboard path works; check grass/depth next |
| Pokemon invisible + Failure reason | Overlay was hiding the real failure; fix that reason |

## Visual checks (only after Actual = DRAMATIC_SPRITE_BILLBOARD)

- Immersed grass: native voxel grass covers feet (same as player/trainer).
- Bush: bush can occlude Pokemon; Pokemon can stand in front.

## Body draw sites (instrumented)

1. Dramatic Shape `drawEntity` / `resolveImage` → billboard
2. `VoxelAdapter:drawOverlayFallbackBodies` → emergency overlay
3. `Entity:draw` / `_drawAnimatedSprite` → flat or emergency body
4. Hidden effects only (no Pokemon body)
