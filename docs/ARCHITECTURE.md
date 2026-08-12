# Architecture — Wilds of Kanto 1.0.2

Public name: **Wilds of Kanto**. Technical id: `overworld_wild_spawns`.

## Components

| Module | Role |
|---|---|
| `main.lua` | Load-phase wiring, hooks, exports |
| `options.lua` | Mod Manager schema |
| `lib/config.lua` | Defaults + option helpers |
| `lib/game_compat.lua` | Generation detection + small Gen1 adapter facade |
| `lib/game_compat/gen1.lua` | Thin Red/Blue/Yellow wrappers (species, surf, party, map) |
| `lib/game_compat/gen2.lua` | Unsupported stub (no Johto implementation) |
| `lib/json_decode.lua` | Minimal JSON decoder for mappings |
| `lib/animated_sprites.lua` | Follow-sprite mapping / source atlas helpers |
| `lib/runtime_sheets.lua` | Resolve build-time 16×96 SpriteRenderer sheets |
| `lib/sprite_providers.lua` | Sprite Style providers (HGSS/PokeMMO / Poke Followers / Pokedex) |
| `lib/water_shadow_renderer.lua` | Voxel flat underwater shadows for Hidden / Silhouettes |
| `lib/sprite_style_menu.lua` | Start-menu Sprite Style picker (`ui.start_menu.items`) |
| `lib/enhanced_world_sprite.lua` | Deprecated dynamic-card adapter (unused for body) |
| `lib/tile.lua` | Gen1Recomp tile size (16x16) |
| `lib/movement.lua` | Tile-step movement + NPC walkPhase/stepFlip |
| `lib/cell_occupancy.lua` | Atomic spawn / move cell reservations |
| `lib/followers_water_compat.lua` | Optional Followers EX water sprite swaps |
| `lib/follower/` | Standalone follower core (selection, control engine, trailers) |
| `lib/catching/` | Optional overworld Poké Ball throw / catch (HUD, meter, projectile) |
| `lib/grass_occlusion.lua` | Flat feet-overdraw + above-lift helpers |
| `lib/voxel_adapter.lua` | DS hooks; emergency overlay filter |
| `lib/surface.lua` | GRASS / CAVE / WATER surface resolve |
| `lib/spawn_regions.lua` | Connected regions + density target |
| `lib/behavior.lua` | Behaviour pick + state machines |
| `lib/behavior_tick.lua` | Present-pipeline AI tick + hidden FX |
| `lib/sprite_scale.lua` | Legacy visible-bounds → one-tile 2D scale |
| `lib/grass.lua` | Tile eligibility / pickers |
| `lib/encounter_pick.lua` | Weighted table picks |
| `lib/encounter_index.lua` | Preview location index |
| `lib/spawn_logic.lua` | Lifecycle, spawn, battle |
| `lib/spawn_render.lua` | Sprite register + entities + pose/draw |
| `lib/spawn_state.lua` | Fail-safe readiness flags |
| `lib/diagnostics.lua` | HUD snapshot / renderer source lines |
| `lib/debug_hud.lua` | Present-only debug HUD |
| `lib/debug_overlay.lua` | Spawn-tile markers |
| `lib/preview_browser.lua` | Dev species browser + anim preview |

## Game compatibility (internal)

`GameCompat` is a small facade so shared Wilds systems do not own Gen1-only
assumptions. It is **not** playable Gen2 support.

```text
GameCompat.current(mod, game)      → Gen1 adapter or nil
GameCompat.generation(mod, game)   → 1, 2, or nil
GameCompat.isSupported(mod, game)  → true only when an adapter is supported
GameCompat.isGen1(mod, game)
GameCompat.isGen2(mod, game)
GameCompat.gameVersion(game)       → "red"|"blue"|"yellow"|"gold"|other|nil
GameCompat.speciesId(species, game, mod)
GameCompat.isSurfing(game, ow)
GameCompat.isWaterCell(map, x, y)
GameCompat.party(game)             → same save.party table
GameCompat.currentMapId(game, ow)
```

Detection uses Gen1Recomp `GameVersion.get()` + `GameVersion.generation(id)`
(set in `bootGame` before mod entry). Gold is generation 2; the Gen2 stub
stays `supported = false`, so no Gen1 gameplay hooks install there.

Production `manifest.json` omits `games` / `gen2compat` (Mod Manager: **Gen 1**).
Do not add `"games": ["gen1", "gen2"]` until the Gen2 adapter is boot-safe.
That future claim is what produces the engine label **Gen 1+2**.
See `docs/analysis/GEN2_PREPARATION.md`.

## Verified contracts

### SpriteRenderer frame order (Gen1Recomp)

```text
STAND = { down = 0, up = 1, left = 2, right = 2 }
WALK  = { down = 3, up = 4, left = 5, right = 5 }
```

Right uses left frames + horizontal mirror. Sheet is 16×96 (6 stacked 16×16 frames).

### NPC pose contract

```text
pose() → sprite, visualX, visualY, facing, phase, flip [, hop]
phase = Movement.walkPhase (NPC: mid-step → 1)
flip  = stepFlip (toggles after each completed tile step)
```

### Dramatic Shape

```text
posesOf uses: sprite, visualX, e.py, facing, phase, flip
lift = e.py - visualY
ground = groundAt(map, e.cellX, e.cellY)
sprite.def.image → static loadable sheet (Assets.image)
SpriteBillboards builds 16×16 UVs into that sheet per frame index
(Battle Art / Potato / Dramaless: Wilds may wrap mesh() for variable SpriteDef
geometry when that provider is active and exposes exports.lib.require)
```

## Flat vs Voxel presentation

```text
FLAT (no Dramatic Shape / voxel off)
  Entity:draw → SpriteRenderer:draw(facing, phase, flip)

VOXEL (Dramatic Shape drawWorld active)
  Wild entities stay in ow.entities
  pose() → native SpriteRenderer (frames=6, walker=true)
  VoxelScene SpriteBillboards → depth + occlusion + grass + shadows + FP
  ctx.drawFx → alert emotes only; Pokemon BODY only if SPATIAL_OVERLAY_EMERGENCY
```

Primary Pokemon renderer: `NATIVE_SPRITE_RENDERER`.

## Runtime sheets

```text
Source:  assets/enhanced_overworld/followsprites/{dex}-{form}-{n|s}.png
Build:   tools/generate_runtime_sprite_sheets.py
Output:  assets/generated/followsprites_runtime/{dex:03d}-{normal|shiny}.png
```

Path types:

```text
relativePath = assets/generated/followsprites_runtime/001-normal.png
loadPath     = mod.assets:path(relativePath)
             = mods/overworld_wild_spawns/assets/generated/.../001-normal.png
```

`SpriteRenderer.def.image` and `Assets.image` always use `loadPath`.
Existence is checked via `mod.read(relative)` / Assets on `loadPath`, never via
`love.filesystem.getInfo(relative)` alone.

## Non-negotiables

- No Pokedex gate for spawns
- No player teleport
- Battle starts exactly once per encounter
- No content-registry mutation after load
- Hidden encounters never show Pokemon follow-sprites
- No post-voxel Pokemon body draw on the success path
- `def.image` is stable for an entity lifetime (no per-frame texture swap)
