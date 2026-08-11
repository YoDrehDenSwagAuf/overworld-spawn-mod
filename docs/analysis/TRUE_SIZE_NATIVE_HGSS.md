# True Size — Native HGSS sizing (prototype)

## Phase 1 — Source format

- **Source path:** `assets/enhanced_overworld/followsprites` (NOT `followsprites_runtime`)
- **Typical sheet:** 128×128 indexed/RGBA, **4×4** grid → **32×32** source frames
- **Layout:** rows = directions (down/left/right/up), columns = animation frames
- **Runtime walk sheet:** 6 frames (idle×3 directions + walk×3), vertical stack
- **Species already differ in visible pixel size** inside the shared 32×32 cells
- Source art is suitable for native-size runtime (no mandatory resize)

- Padding constant: `TRUE_SIZE_PADDING = 2`
- Soft warn threshold: `48px` (report only, no clamp)

## Shared bounds algorithm

1. Extract the six walker frames from the source grid.
2. Measure alpha bbox per frame.
3. Take the **union** (shared minX/minY/maxX/maxY).
4. Crop that **same window** from every frame.
5. Paste every frame at the **same** padded offset (no per-frame centering).
6. Bottom-center anchor at content feet (`anchorY = pad + contentH`).

## Prototype species

| Dex | Species | Source tile | Native visible | Runtime (pad=2) | Resized? | Override |
|-----|---------|-------------|----------------|-----------------|----------|----------|
| 19 | Rattata | 32×32 | 21×24 | 25×28 | no | — |
| 9 | Blastoise | 32×32 | 27×26 | 31×30 | no | — |
| 95 | Onix | 32×32 | 27×30 | 35×38 | yes NN×1.15 | {'visualScale': 1.15, 'notes': 'modest presence boost; NN only'} |

## Philosophy

- HGSS source artwork is the visual reference.
- Pokédex real-world height is **not** the primary sizing authority.
- Other packs match HGSS **visible** body height (not canvas size).
- Logical footprint stays **one cell** (collision/AI/catch unchanged).
- Classic + Voxel effective-Classic untouched.

## Wild clipping note

This refactor does **not** claim to fix Wild clipping. If a native-size
Rattata still clips in Wild encounters, the bug remains in the Wild
render/rebind path — do not hide it by shrinking art.

Generator stats: `{"hgss_written": 6, "hgss_cached": 0, "hgss_missing": 0, "hgss_resized": 2, "hgss_pad_only": 4, "hgss_warnings": 0, "followers_written": 6, "followers_cached": 0, "followers_missing": 0, "pokedex_written": 6, "pokedex_cached": 0, "pokedex_missing": 0, "swimming_written": 6, "swimming_cached": 0, "swimming_missing": 0, "levitate_written": 0, "levitate_cached": 0, "levitate_missing": 3}`

Contact sheet: `assets/generated/true_size/dev/native_hgss_prototype_contact.png`

