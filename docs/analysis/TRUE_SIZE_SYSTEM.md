# True Size system (1.14.0)

## Architecture

```
pokemon_size option  →  requestedMode
                              │
                 ┌────────────┴────────────┐
                 ▼                         ▼
            Flat renderer            Voxel renderer
                 │                         │
                 ▼                         ▼
            TRUE SIZE               capability check
                                         │
                          ┌──────────────┴──────────────┐
                          ▼                             ▼
                   supports geometry              incompatible
                          │                             │
                          ▼                             ▼
                     TRUE SIZE                       CLASSIC
```

`requestedMode` is the saved user preference. `effectiveMode` is what rendering
uses. **Voxel never writes `pokemon_size`.**

## Assets

| Pack | Path | Count (normal+shiny) | Source |
|------|------|----------------------|--------|
| HGSS | `true_size/hgss` | 302 | original `followsprites` |
| Followers | `true_size/followers` | 302 | `poke_followers` strips |
| Pokédex | `true_size/pokedex` | 302 | HGSS idle-down 1-frame stand-in |
| Swimming | `true_size/swimming` | 256 | original `water_sprites/swimming` |
| Levitate | `true_size/levitate` | 42 | original `water_sprites/levitates` |

Classic assets under `followsprites_runtime` / `water_runtime` / `poke_followers`
are never overwritten.

## Consumers

Wild spawn_render · sprite_providers · water_sprite_registry ·
follower sprite_service / control_engine / water_compat · ambient_pokemon

All call `VariableSize.applyToDef` / preserve geometry fields.

## Follower visual trail spacing

Logical footprint stays **one cell**. When `effectiveMode == true_size`,
`ControlEngine` consumes older points from `pokepcTrailHistory` using

`gap = max(gap(previous), gap(current))` from `SpeciesGeometry.followGap`.

Classic / Voxel-effective-Classic keep the historic 1-cell snake.

## Wild vs Follower geometry (root cause of Wild clipping)

**Symptom:** True Size Wilds clipped on land, grass, **and** water; Followers
of the same species rendered correctly. Grass alone was not the root cause.

**Root cause:** Wild `SpriteDef` rebuilds dropped `frameWidth` / `frameHeight` /
`anchorX` / `anchorY`, so Gen1Recomp `SpriteRenderer` fell back to **16×16**
quads on taller True Size sheets. Water rebinds then called
`VariableSize.applyToDef` without `presentation`/`packId`, swapping swimming
sheets for land packs.

**First divergence:** Follower `spriteDefWithGeometry` always copies geometry;
Wild `Entity.new` / water resolver / `applyProviderSprite` did not.

**Fix:** Preserve geometry on every Wild def copy; pass `presentation`/`packId`
into `applyToDef` for water/levitate; treat missing geometry as unequal in
skip-rebuild checks (`or 16` hid mismatches).

Logical footprint stays 16×16. Visual geometry comes from `sprite.def` /
`getPoseGeometry()`.

## Grass / scaleInfo

Native True Size entities mirror `frameWidth`/`frameHeight` into `scaleInfo`
for diagnostics / feet-band cover only — SpriteScale one-tile clamp must not
drive native True Size draws.

**Classic Flat:** engine `TileRenderer:drawCellBottom` (bottom **8px** of the
16×16 cell) — unchanged.

**True Size Flat:** `GrassOcclusion.installTileRendererWrap` intercepts
`drawCellBottom` for entities that queued a feet-band during `Entity:draw`:

- Immersed → `setScissor` to `computeTrueSizeCover()` (~4–6px at feet)
- Above → skip overdraw entirely

Scissor restore is guarded with `pcall`. Voxel untouched. Feet-band remains a
separate native Tall Grass overdraw concern after the geometry fix.

## Dramatic Shape

1.7.9 still fixed 16×16. No monkey-patch. Future
`exports.variableSpriteGeometry = true` enables True Size under Voxel.
