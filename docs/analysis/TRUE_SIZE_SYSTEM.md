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

## Grass / scaleInfo

Native True Size entities mirror `frameWidth`/`frameHeight` into `scaleInfo`.
`GrassOcclusion.refreshEntity` prefers SpriteDef frame height over a stale
16×16 `scaleInfo`, so feet-band immersion does not assume a Classic tile.

Generator reserves 1px top pad when bottom-aligning (nearest-neighbor) so
flush ear tips are not lost under neighboring overdraw.

## Dramatic Shape

1.7.9 still fixed 16×16. No monkey-patch. Future
`exports.variableSpriteGeometry = true` enables True Size under Voxel.
