# True Size system (1.14.0)

## Sizing philosophy (native HGSS)

True Size means **preserve original HGSS / PokeMMO follower artwork scale**,
not “Pokédex metres → XS–XXL targetHeight”.

- **Authority:** shared alpha bounds of original `followsprites` (not runtime 16×16)
- **Default:** no resampling (`TRUE_SIZE_PADDING = 2` only)
- **Optional:** declarative `visualScale` / anchor offsets (nearest-neighbor)
- **Other packs:** match HGSS *visible* body height, then their own padded canvas
- **Prototype first:** Rattata / Blastoise / Onix — see `TRUE_SIZE_NATIVE_HGSS.md`
- Logical footprint stays **one cell**. Classic + Voxel unchanged.

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
Onix artwork + Follower Onix proved Gen1Recomp variable SpriteRenderer works.

**Root cause (final):** `applyProviderSprite` re-called `VariableSize.applyToDef`
with `speciesId = entity.species` (a **name** like `"ONIX"`). `packGeometry`
only accepts dex `1..151`, so apply failed with `no_geometry`, **stripped**
`frameWidth`/`frameHeight`, but **left the `true_size/` image**.  
`SpriteRenderer.new` then baked **16×16 quads** on the tall sheet → cropped
Wild. Followers pass numeric dex via `spriteDefWithGeometry`.

Secondary issues fixed earlier: Wild def copies dropping geometry; water rebind
without `presentation`/`packId`; skip checks using `(frameWidth or 16)`.

**Fix:** Prefer `enhancedDexId` / resolved dex in `applyProviderSprite`; resolve
species names inside `applyToDef`; **never** clear geometry while a `true_size/`
image remains; compare SpriteRenderer **instance** `frameWidth`/`frameHeight`
in skip-rebuild checks (draw uses instance values, not only `def`).

Logical footprint stays 16×16. Visual geometry comes from `sprite.frameWidth`
/ `getPoseGeometry()`.

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

## Dramatic Shape / Battle Art / Potato / Dramaless / Stadium2 Voxel

Capability is tied to the **active** Voxel renderer
(`VariableSize.activeVoxelProvider()`). Installing Battle Art while Potato,
Dramaless, or Stadium2 is the live pipeline does not enable True Size.

| Provider | Mod ID | Public `exports.lib.require` | HGSS in Voxel |
| --- | --- | --- | --- |
| Battle Art Voxel Fork | `BATTLE_ART_VOXEL_FORK` | yes (1.8.3) | True Size via existing adapter |
| Potato Voxel | `potato_voxel` | yes (1.4.0) | True Size via adapter; `shadowBlob()` unchanged |
| Dramaless Shape | `DRAMALESS_SHAPE` | yes (1.6.4) | True Size via adapter |
| Stadium2 Overworld Models | `STADIUM2_OVERWORLD_MODELS` | yes (current Gen 2 voxel) | True Size via adapter |
| Original Dramatic Shape | `DRAMATIC_SHAPE` | n/a for Wilds wrap | Classic unless native `variableSpriteGeometry` |

Wilds does **not** copy VoxelScene / SpriteBillboards / shaders. Failure or
a missing public accessor keeps Classic 16×16 and logs once (DEV).

`VariableSize.canUseTrueSizeInVoxel()` reports live capability of the active
provider (adapter or upstream export), not a version number.

Stadium2 support is **renderer compatibility only** (Wilds SpriteDef geometry
→ Stadium2 `SpriteBillboards`). Some Stadium2 builds have embedded their own
Wilds runtime. Wilds probes public exports (`embeddedWilds` / `wilds` table)
and logs the situation; it does not disable Stadium2 handlers or rewrite
Stadium2 files. Dual-runtime coexistence is an external Stadium2 change.
