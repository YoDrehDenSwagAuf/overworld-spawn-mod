# Variable-size / True Size prototype findings

Status: **Flat Charizard prototype ready; full migration STOPPED** because Dramatic Shape 1.7.9 does not consume Gen1Recomp’s geometry contract.

## 1. Gen1Recomp API (actual, not issue-only)

Upstream issue [#1016](https://github.com/bryanthaboi/gen1recomp/issues/1016) was implemented in PR [#1020](https://github.com/bryanthaboi/gen1recomp/pull/1020) and merged **2026-08-10** (`d3af63e0…` into gen1recomp main; current tip inspected includes the fields in `SpriteRenderer.lua`).

### SpriteDef fields (Schemas.lua)

| Field | Required | Default |
|-------|----------|---------|
| `frameWidth` | optional int ≥1 | `16` |
| `frameHeight` | optional int ≥1 | `16` |
| `anchorX` | optional number | `frameWidth / 2` |
| `anchorY` | optional number | `frameHeight` |

**Bottom-center anchoring is the default.** Large sprites grow upward from the world feet point.

### SpriteRenderer geometry accessors

- `sprite:getFrameGeometry(frame)` → `{ frame, x, y, width, height, anchorX, anchorY, quad }`
- `sprite:getPoseGeometry(facing, walkPhase, stepFlip)` → geometry + `facing`, `walkPhase`, `stepFlip`, `mirror`
- `sprite:getScreenOrigin(px, py, camX, camY)` → top-left screen coords using the declared anchor

### Behaviour confirmed in source

- Walker STAND/WALK tables unchanged; work with any frame height (vertical stride = `frameHeight`).
- Horizontal mirroring uses **actual** `frameWidth`.
- `trueColor` / `markTrueColor` uses **actual** frame width × drawn height.
- Logical cell occupancy is **not** tied to visual size (engine contract).

## 2. Dramatic Shape 1.7.9

Inspected tag `1.7.9` (`791bebc`), files:

- `lib/SpriteBillboards.lua` → `buildCard` hardcodes `frame * 16`, UV 16-wide, verts `{0,0}…{16,16}`
- `lib/VoxelScene.lua` → `drawEntity` / `frameFor` never call `getPoseGeometry` / `getFrameGeometry`
- `lib/Mat4.lua` → `billboard` / `caster` hard-code the 16-wide foot pivot (`T(px+8) * T(-8,0,0)`)

**Conclusion:** 1.7.9 does **not** understand variable-size geometry.

Failure modes for a 32×32 Charizard under Voxel today:

| Code | Meaning |
|------|---------|
| **A** | Fixed 16×16 billboard mesh |
| **C** | Fixed 16×16 UV rectangle |
| **D** | Ignores SpriteRenderer anchor (Mat4 ±8) |
| **E** | Never calls the new geometry API |

Wilds deliberately **does not** monkey-patch DS. When True Size is selected and Voxel is active on an incompatible DS, geometry falls back to **Classic** and a DEV log is emitted.

What DS needs (separate task):

1. `SpriteBillboards.buildCard` (or successor) reads `def.frameWidth` / `frameHeight` or `sprite:getPoseGeometry`.
2. Mesh verts sized to those dimensions; UVs from geometry `x/y/width/height`.
3. `Mat4.billboard` / `caster` pivot by **anchor** (half-width / feet), not hard-coded 8.
4. Optional export flag e.g. `exports.variableSpriteGeometry = true` for capability detection.

## 3. Wilds prototype (this PR)

- Option **Pokémon Size**: `Classic` (default) | `True Size`
- Prototype species: **Charizard (dex 6)** only, pack **HGSS / PokeMMO**
- Assets: `assets/generated/variable_size_prototype/hgss/006-{normal,shiny}.png` — **32×192** (6×32×32)
- Source: **original** `assets/enhanced_overworld/followsprites/006-b-{n,s}.png` (128×128 / 32×32 tiles)
- **Not** sourced from degraded `followsprites_runtime` 16×16 sheets
- Generator: `tools/generate_variable_size_prototype.py` (nearest-neighbor, shared bbox, feet on bottom)
- Metadata: `lib/species_geometry.lua`, capability gate: `lib/variable_size.lua`
- Collision / spawn / catching / followers trail logic untouched (still one cell)

## 4. Why full migration did not proceed

Per task order: migrate all 151 only if Flat **and preferably** Voxel prototype PASS.

- Flat Charizard True Size: **implemented / unit-tested** (requires Gen1Recomp with #1020)
- Voxel Charizard True Size: **FAIL by design** until DS consumes geometry

Therefore:

- Classic remains default
- Current 16×16 runtime sheets remain the live path for all species
- No batch HGSS rebuild of 151
- No renderer hacks

## 5. Next steps (human / follow-up)

1. Manual Flat playtest: HGSS + True Size + Charizard — directions, walk, trueColor, feet on cell.
2. Manual Voxel: confirm Classic fallback / no crop corruption on player or other mons.
3. Upstream or companion DS patch for variable billboards.
4. After Voxel PASS: size-class table, rebuild HGSS from originals, shared species heights across packs.
