# Changelog

## 1.3.0

### Water Pokémon sprites (Swimming / Levitates)

- Added dedicated Swimming sprites for visible water Pokémon
- Added Levitates water-sprite fallback
- Added normal and shiny water variants
- Added Pokédex-ID-based water sprite mapping
- Added automatic water sprite fallback independent of selected land style
- Reused the native SpriteRenderer animation pipeline
- Added water sprite validation and diagnostics

## 1.2.0

### Removed Hidden Idle; Random Enc + Water Mons

- Removed Hidden Idle grass encounter mode
- Removed periodic grass rustle and reveal effects
- Replaced Grass Enc choice with simple **Random Enc** toggle (`random_encounters`,
  default ON) covering classic grass / cave / water step encounters
- Preserved visible overworld Pokémon and water spawns
- Kept visible grass and water spawn animations (lift/splash; no grass rustle)
- Simplified in-game settings: **SPRITE STYLE**, **SPAWN AMOUNT**, **RANDOM ENC**,
  **WATER MONS**
- Added **Water Mons** (`water_spawns`, default ON): visible Pokémon from the
  map water encounter table on connected water (`WATER_IDLE` / `WATER_WANDER`)
- Migrates saved `grass_encounters` once:
  `classic`/`both` → Random Enc ON, `hidden` → OFF
- Spawn Amount remains Start-Menu only

## 1.1.0

### Grass Enc + Hidden Idle

- Added **Grass Enc** (`grass_encounters`): Classic / Hidden / Both.
  **Hidden** is the default.
- **Hidden Idle** lurkers reserve grass tiles, rustle with native tall-grass
  redraws, reveal on step (rustle → body → short hop → battle once).
- Classic grass RNG follows the selected mode; in **Both**, Hidden Idle wins
  on a reserved cell (no double encounter). Caves and water are unchanged.
- Start Menu quick settings order: **SPRITE STYLE**, **SPAWN AMOUNT**,
  **GRASS ENC**.
- **Spawn Amount** removed from Mod Settings (internal `spawn_density` key
  and density math unchanged); still adjustable from the Start Menu.
- Developer HUD reports grass-encounter mode, hidden targets, and per-entity
  Hidden Idle state.

## 1.0.2

### Sprite providers + quick picker

- Added optional **Gold Sprites** provider support
  (`Gold_Silver_Sprites` battle fronts via read-only `mod:find()` adapter).
- Quick sprite style selection from the normal in-game Start Menu
  (**SPRITE STYLE**), writing the same `sprite_style` option as Mod Settings.
- Switch between **Auto**, **Gold Sprites**, **Followers EX**, **PokeMMO**,
  and **Pokedex**; Auto prefers Gold → Followers EX → PokeMMO → Pokedex.
- Improved provider fallbacks when optional mods are missing, plus clearer
  HUD/status reporting and documentation for the provider matrix.

## 1.0.0

### Stable release

- First stable major release of Wilds of Kanto.
- Native trainer/NPC-compatible `SpriteRenderer` rendering for wild Pokemon.
- Improved Dramatic Shape and first-person compatibility (depth, walls, grass,
  shadows) on the native sheet path.
- Animated overworld sprites via follow-sprite runtime sheets.
- Wall and object occlusion through the Dramatic Shape / engine billboard path.
- Simplified mod settings for version 1.0.
- All visible setting labels limited to 14 characters (Gen1Recomp truncation).
- Removed obsolete and non-functional public settings (density fine-tuning,
  legacy sprite size / opacity menus, old strict billboard debug probes, and
  legacy option aliases).
- GitHub update support via manifest `github` field
  (`YoDrehDenSwagAuf/overworld-spawn-mod`).
- MIT license for original project source plus third-party notices for
  non-MIT assets.
- Automated tag-triggered release workflow producing
  `wilds-of-kanto-v1.0.0.zip` with `manifest.json` at the ZIP root.

### Settings (public)

| Label | Purpose | Default |
|---|---|---|
| Show Wild Mons | Master switch for visible wilds | ON |
| Hide Grass RNG | Suppress vanilla grass rolls when ready | ON |
| Sprite Style | Auto / Gold Sprites / Followers EX / PokeMMO / Pokedex | AUTO |
| Spawn Amount | Density preset | NORMAL |
| Grass View | Immersed vs above tall grass | IMMERSED |
| Idle Mons | Allow idle look behaviour | ON |
| Roam Mons | Allow wandering | ON |
| Chase Mons | Allow aggressive chase | ON |
| Hidden Mons | Allow hidden markers | ON |
| Dev Mode | Diagnostics / preview browser | OFF |

Internal option keys for the remaining settings are unchanged so existing
saved values keep working.

## 0.7.1

### Fixed

- **Question-mark fallback despite generated sheets**: `RuntimeSheets` now
  resolves sheets through `mod.assets:path(relative)` (the same load path
  Gen1Recomp `Assets.image` / `SpriteRenderer` expect) instead of registering
  bare `assets/generated/...` relative paths. Existence checks use `mod.read`
  / resolved load paths — `love.filesystem.getInfo(relative)` alone no longer
  decides that a packaged mod asset is missing.
- Registration for valid dex IDs writes `kind=native_runtime_sheet`,
  `frames=6`, `walker=true`, and the mod-resolved `def.image`.
- Developer HUD shows relative path, resolved path, registration kind, and
  fallback reason. Probe logs for dex 1 / 25 / 151 run at content registration.

### Required after update

- Replace the old mod ZIP completely (do not leave two copies installed).
- Fully restart the game so the content registry reloads.
- Clear any stale `overworld_wild_spawns-cache/` in the save directory if an
  older bake still shadows species sprites.

## 0.7.0

### Changed

- **Native SpriteRenderer path for wild Pokemon.** Visible wilds now use the
  same trainer/NPC contract Dramatic Shape already supports: a stable
  `SpriteRenderer` with `frames=6`, `walker=true`, and a static 16×96 sheet.
- Build-time generator writes
  `assets/generated/followsprites_runtime/{dex}-{normal|shiny}.png` from the
  follow-sprite source atlas (nearest-neighbor, bottom-center, shared scale).
- `pose()` returns NPC-compatible `facing` / `phase` / `flip` (`Movement.walkPhase`
  + `stepFlip`). Right-facing uses the engine left-frame mirror.
- Primary renderer label: `NATIVE_SPRITE_RENDERER`. First Person, depth buffer,
  wall/building occlusion, grass, shadows, and silhouettes come from Dramatic
  Shape with no Wilds-specific body overlay on the success path.
- `EnhancedWorldSprite` dynamic 16×16 cards remain in-repo as deprecated
  compatibility code and are unused for the Pokemon body.

### Frame order (verified against Gen1Recomp `SpriteRenderer.lua`)

```text
0 idle down / 1 idle up / 2 idle left
3 walk down / 4 walk up / 5 walk left
```

### Fallback chain

1. Generated runtime sheet (requested variant)
2. Generated runtime sheet (normal)
3. Legacy Pokédex / battle PNG as SpriteRenderer
4. Black fallback as SpriteRenderer

## 0.6.0

### Changed

- **Follow-sprites replace the Anima atlas** as the active enhanced overworld
  sprite source. One PNG per species/variant under
  `assets/enhanced_overworld/followsprites/`, with a shared
  `followsprites_mapping.json`.
- Species identity remains Pokédex / species ID only (never localized names).
- Idle and walk animations in four directions; walk uses a 4-frame cycle per
  direction (rows = directions, columns = frames — verified against the real
  PNGs).
- Normal and shiny files are mapped; **runtime Gen1 wild spawns always use
  normal** because Gen1Recomp does not expose a reliable pre-battle shiny flag.
  The developer preview browser can still force Shiny for inspection.
- Public option kept as enhanced overworld sprites
  (`use_animated_overworld_sprites`); it now toggles follow-sprites vs legacy
  Pokédex images. The old Anima atlas is no longer selectable.
- Commercial `POKEMON 1.png` is gitignored and blocked from release ZIPs.
  Old per-species Anima mapping JSONs remain in the repo unused.

### Fallback chain

1. Requested follow-sprite variant
2. Normal follow-sprite (if shiny missing)
3. Legacy Pokédex / battle PNG
4. Black fallback

## 0.5.7

### Added

- **Animated overworld Pokémon sprites** for all 151 Gen I species: directional
  idle and walk animations, language-independent Pokédex/species-ID mapping,
  and automatic fallback to the previous Pokédex-image presentation when the
  option is off or a mapping is missing/invalid.
- Mod option: **Use animated overworld Pokemon sprites**
  (`use_animated_overworld_sprites`, default on).
- Sprite credit: animated overworld art is based on Anima’s **GBC Pokémon**
  pack — https://anima-nel.itch.io/gbc-pokemon

### Diagnosis / Fixed

- **Honest render-path instrumentation**: HUD now shows Requested vs Actual body
  renderer from real call counters (`poseCalls`, `enhancedResolveImageCalls`,
  emergency/post-voxel body draws, mesh/Assets probes) instead of wishful status.
- **`strict_world_billboard_debug`**: disables emergency/post-voxel Pokemon body
  draws so a broken DS billboard path can no longer hide behind an overlay.
- Optional **`strict_magenta_billboard_probe`** for a magenta 16×16 DS texture probe.
- **Entity:draw no longer paints the body** when `WORLD_BILLBOARD_*` owns it
  (prevents double-draw on top of voxel grass).
- `worldBillboardReady` is per-entity only; ENHANCED requires card READY +
  loadable `def.image` + SpriteBillboards mesh probe.
- Depth/grass HUD flags stay `UNVERIFIED` until counters prove
  `DRAMATIC_SPRITE_BILLBOARD`.

## 0.5.6

### Fixed / Changed

- **Stable `EnhancedWorldSprite` adapter**: Dramatic Shape receives a dedicated
  SpriteRenderer-compatible object (`def` + `resolveImage()`), not a mutated
  legacy SpriteRenderer. Legacy sprites stay untouched for the flat 2D path.
- `Entity:getWorldSprite()` / `Entity:pose()` deliver the adapter with
  `phase = 0` and `frames = 1`; frame changes come only from cached 16×16
  billboard cards returned by `resolveImage()`.
- UV mesh carrier is the static transparent
  `assets/runtime/dynamic_billboard_base.png`; live pixels stay on the card
  Image cache (`species:anim:dir:frame:w:h`).
- Post-voxel Pokemon **body** draw remains emergency-only
  (`SPATIAL_OVERLAY_EMERGENCY`). Success path uses native DS depth + grass mesh.
- `immersed` grass: `Grass renderer: DRAMATIC_SHAPE_NATIVE` (no custom grass
  color/mask). `above`: small `visualY` lift (`grass_above_lift_px`); object
  occlusion stays active.
- `animation.renderRevision` bumps only on visible animation changes.
- Developer HUD fields for adapter status, card cache, ground/visual Y, lift,
  and grass renderer.

## 0.5.5

### Fixed

- **Pokemon appearing in front of bushes / world objects with Dramatic Shape**:
  the post-voxel 2D overlay drew Pokemon after the finished scene, so they had
  no depth. Wild Pokemon now use Dramatic Shape `SpriteBillboards` again via
  `pose()` → cached 16×16 trueColor atlas cards (`WORLD_BILLBOARD_ENHANCED`),
  sharing player/trainer depth and object occlusion.
- Post-voxel body draw is only an emergency `SPATIAL_OVERLAY_FALLBACK`.
  Emotes/debug stay on the overlay seam.

### Changed

- `above` grass mode no longer means “screen overlay”; it only skips grass
  feet cover while world occlusion stays active.

## 0.5.4

### Added

- **Pokemon grass rendering** option (`pokemon_grass_render_mode`):
  - `immersed` (default) — lower part of the sprite hidden by tall-grass
    feet-overdraw, like the player and trainers
  - `above` — fully visible above grass (previous post-voxel look)
- Uses Gen1Recomp `TileRenderer:drawCellBottom` on the flat path (engine) and
  the same call after the post-voxel 2D Pokemon draw when Dramatic Shape is on
- Live toggle; legacy `show_pokemon_in_grass=false` maps to `above`
- Preview browser: Preview grass Immersed/Above toggle
- Developer HUD: grass mode / occlusion active / height

## 0.5.3

### Changed

- **Voxel wild Pokemon architecture**: abandoned atlas→16×16 card→Dramatic
  Shape billboard conversion. Dramatic Shape still renders the voxel world;
  Wilds of Kanto draws animated Pokemon with the **same** 2D atlas renderer
  as a post-voxel overlay (`WILDS_2D_POST_VOXEL`), using `Voxel3D.project`
  for screen placement. Wild entities with enhanced sprites are skipped from
  Dramatic Shape `posesOf` so Voxel does not also draw a legacy billboard
  (no double sprite).

### Known

- Post-voxel overlays are drawn after the 3D depth pass, so buildings do not
  occlude Pokemon bodies on this path (depth integration inactive).

## 0.5.1

### Fixed

- **Voxel Mod invisible / static wild sprites**: Dramatic Shape billboards
  expected `SpriteRenderer` sheets; animated atlas frames are now baked into
  cached 16×16 cards for the voxel path while 2D keeps atlas+quad.

## 0.5.0

See prior history in git for earlier releases.
