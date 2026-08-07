# HGSS / PokeMMO runtime quality analysis

## Source format

- Mapping: `assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json`
- Typical Gen1 sheet: **128×128** RGBA = **4×4** grid of **32×32** tiles
- Rows (directions): down, left, right, up
- Columns (animation): idle, idle-bob, walk, walk-bob
- Runtime keeps SpriteRenderer’s 6 frames: idle down/up/left + walk down/up/left
- Right is mirrored from left by Gen1Recomp (not stored)

## Renderer constraint

`SpriteRenderer` hard-codes **16×16** quads. Larger native frames are not possible
without changing the renderer (forbidden for this work). Runtime cards remain
**16×16** in a **16×96** walker sheet. Old and new runtime frame size: **16×16**.

## Generator rules

- Nearest-neighbor only (no bilinear/bicubic)
- One shared scale from the union opaque bbox (stable size)
- Each frame cropped to its own opaque pixels, then placed on the shared pivot
- Max-fit into 16×16; skip resize when content already fits; never upscale
- Source under `assets/enhanced_overworld/followsprites` is never modified

- Manifest methods: `{'shared_bbox_nearest': 1298}`
- Resampling: `NEAREST only`

## Sample comparison

| Species | Source tile | Content bbox | Source opaque | Scale | New f0 opaque | Old f0 opaque |
|---|---|---|---:|---:|---:|---:|
| Caterpie (010) | 32x32 | 13x16 | 160 | 1.0 | 107 | — |
| Pikachu (025) | 32x32 | 16x18 | 198 | 0.889 | 145 | — |
| Mankey (056) | 32x32 | 25x15 | 224 | 0.64 | 96 | 96 |
| Gengar (094) | 32x32 | 21x19 | 285 | 0.762 | 154 | — |
| Onix (095) | 32x32 | 22x29 | 346 | 0.552 | 85 | — |
| Gyarados (130) | 32x32 | 30x30 | 608 | 0.533 | 154 | — |
| Snorlax (143) | 32x32 | 27x26 | 471 | 0.593 | 154 | — |
| Mewtwo (150) | 32x32 | 23x27 | 341 | 0.593 | 118 | — |

### Mankey

- Source content ~25×15–16 inside 32×32 (wide silhouette)
- Old runtime idle-down opaque: **96** → New: **96** (detail preserved; shared pivot)
- Shared pivot keeps idle/walk feet aligned (no horizontal/vertical jitter)
- Cannot keep 32×32 native pixels: SpriteRenderer requires 16×16 cards

Artifacts (8× nearest previews): `/opt/cursor/artifacts/hgss_compare/`

