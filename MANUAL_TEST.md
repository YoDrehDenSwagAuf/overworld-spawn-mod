# Manual test guide — Wilds of Kanto 0.5.7

## Critical: prove the actual body path

Developer mode on. Inspect one wild Pokemon in the HUD:

```text
Requested renderer: ...
Actual body renderer: ...
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
