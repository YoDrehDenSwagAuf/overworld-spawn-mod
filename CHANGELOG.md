# Changelog

## 1.12.1
- Menu now supports controller.
- A button will increment/cycle through sub-menu options.
- Removes the duplicate "FOLLOWER" in party menu.
- Replaces "FOLLOWER"/"FOLLOWING" with "FOLLOW"/"DISMISS".

## 1.12.0

### Followers EX walk cycle fix — no more dragging trailers

- **Root cause**: Followers EX (priority 160) wraps its hooks on top of Wilds'
  (priority 80) ControlEngine wrappers after `game.ready`. The restore-then-reinstall
  path had equality guards (`PF.update == wrappedUpdate`) that failed when EX's
  wrapper sat on top, making restore a no-op. EX's hook logic double-drove the
  pack, breaking walk-phase overrides and causing 2nd+ followers to drag along
  without animating.
- **Fix**: `ControlEngine:restore()` and `_restoreOverworldUpdateWrap()` now
  unconditionally restore to the vanilla originals captured at first `install()`.
  On `game.ready`, the re-wrap strips Followers EX out of the update chain
  entirely — equivalent to how things worked when EX's init crashed, but deliberate
  and clean.
- Added `setOptionsChangedHandler` to the mod interface: Followers EX calls this
  to hook in; the handler detects the attempt and schedules the restore+reinstall
  for the first `game.ready` frame after EX finishes its init.

### Submerged / water follower sprites (poke_followers)

- **File naming updated**: All poke_followers sprites now live in a single flat
  directory: `follower_NNN_normal.png`, `follower_NNN_shiny.png`,
  `follower_NNN_grayscale.png`, `follower_NNN_submerged.png`,
  `follower_NNN_normal_submerged.png`, `follower_NNN_shiny_submerged.png`,
  `follower_NNN_grayscale_submerged.png`.
- **Direct file loading bypasses `mod:read`**: The `mod:read` existence check
  silently failed for binary assets in some engine configurations. All submerged
  resolution paths now use `love.filesystem.getInfo` directly. This applies to
  follower trailers (`_refreshTrailerWaterSprites`), the follower water resolver
  (`SpawnLogic:resolveWaterSprite`), wild water encounters
  (`SpriteResolver:resolveWaterSprite`), and the provider chain
  (`followers_ex:resolveWater`).
- **Surface transition tracking**: `ControlEngine:update` now tracks the trail
  surface each frame. On any land↔water transition, `_refreshTrailerWaterSprites`
  re-resolves every party-mon trailer sprite — submerged sheets apply immediately
  on entering water, land sheets restore on exit.
- **Post-battle / party-change resilience**: After battle or party changes,
  `syncTrailers` may recreate trailer entities with fresh land sprites while
  still on water. Detecting entity reference changes while surface is water now
  triggers a sprite refresh.
- **Sprite style gating**: Submerged poke_followers sheets only activate when the
  selected sprite style is `"followers"` (GSC). HGSS/PokeMMO and Pokédex styles
  continue to use the swimming/levitates water registry.
- **Wild water encounters** also get submerged poke_followers art (gated on
  followers style) via `SpriteResolver:resolveWaterSprite`.

### POKE FOLLOW EX & WILDS OF KANTO sub-menus — stepper refactor

- **Every option now cycles with left/right arrow keys** instead of opening a
  dropdown sub-menu. Each row is self-contained: left decreases, right increases,
  the label updates instantly, and the value takes effect immediately.
- **Left arrow detection fix**: The engine's `input:wasPressed` API was unreliable
  in the menu context. Steppers now poll `love.keyboard.isDown` directly with
  manual edge detection and hold-to-repeat (16-frame initial delay, 4-frame cadence).
- **Follower count stepper now applies**: The count change writes to
  `game.save.pokepcFollowerCount` and `mod.options`, sets a pending-sync flag,
  and the control engine detects the count mismatch on its next update frame.
  Follower count wraps 0↔6 at the ends.
- **Label overlap eliminated**: All labels and values shortened to fit within the
  16-character Game Boy screen limit. `CONTROL MODE` → `CONTROL`,
  `TRAINER TRAIL` → `TRAIL`, `SPAWN AMOUNT` → `SPAWN AMT`,
  `SPRITE STYLE` → `GFX STYLE`, values like `HGSS / PokeMMO` → `HGSS`,
  `Reachable Only` → `REACH`, etc.
- **LEADER row removed** from POKE FOLLOW EX sub-menu — follower deselection via
  the party menu is the cleaner path.

### Party menu follower selection

- Non-active party mons show **FOLLOWER**; the currently-active mon shows
  **ACTIVE**. Legacy rows (LEADER, FOLLOWING) are actively stripped.
- Selecting **ACTIVE** deselects the follower: clears the leader, sets follower
  count to 0, removes trailers, and shows the confirmation message
  `"<name> is no longer following."` via the engine's TextBox stack.
- `getActiveFollowerMon` and `getLeaderMon` return `nil` when `followerCount ≤ 0`,
  preventing the ACTIVE label from persisting after deselection.

### Yellow version Pikachu quirk

- Removed `ensureYellowLeaderLayout` — it was physically reordering the party
  array to put Pikachu in slot 1 whenever a follower was selected. Wilds'
  trailer system designates the follower via save data (`pokepcLeader`),
  not party order.

### TEST SPAWN cleanup

- Removed the duplicate top-level "Test Spawn" row from the OPTIONS menu
  (was registered separately in `preview_browser.lua`). Now only appears
  inside the WILDS OF KANTO sub-menu.

### PC Grid UI integration

- Exposed `_G._wildsSpriteService` from `main.lua` so other mods can resolve
  follower-style overworld icons.

## 1.11.1

### Fix Poke Followers EX OPTIONS menu follower settings path

- Root cause: Gen1Recomp has **no** `mod.options:set` (only `define`/`get`).
  In-game menus were silently failing option writes via `pcall(options:set)`
- Menus now write the same `loader.modOptions` / `save.options.modOptions`
  buckets Mod Manager uses (`Config.setOption`)
- Shared `handleOptionsChanged` from `main.lua` is injected into SettingsMenus
  (no duplicated logic/follower/ambient notify path)
- ListMenu navigation uses close-then-push so parent is not left stale under
  child (`ListMenu:close` only pops when it is stack top)
- Control Mode, Trainer Trail, and Followers (0–6) share that path
- Regression tests simulate the real ListMenu choose → child → apply flow
  (`tests/settings_menus_listmenu_path_unit_test.lua`)

### Remove Sprite Color mode; fix GSC true-color rendering

- Removed the Sprite Color (Colored / Classic) option and its submenu entry
- Follower, wild, ambient, and party-menu sprites now always render true-color
- Fixes the built-in Poke Followers / GSC sheets (8-bit RGBA) being force-baked
  through the 4-shade DMG gray ramp in Classic mode, which made them look broken
- Legacy "classic" saves are ignored and migrated to "colored"

## 1.11.0

### OPTIONS menus, Sprite Color / Fade, Town Pokémon

- Moved Wilds and follower settings into START → OPTIONS submenus
- Restored Wilds Sprite Fade setting (Solid / Faded; Solid = alpha 1.0)
- Added peaceful Town Pokémon (ambient NPCs; Idle / Wander only)
- Added ambient Pokémon interactions and text cries
- Ambient Pokémon use the selected Sprite Style
- Updated README for the collaborative Wilds of Kanto project
- Both OPTIONS submenus share the same central `mod.options` keys as Mod Settings
- No top-level START menu entries for Wilds / Followers

## 1.10.0

### Sprite defaults, built-in GSC pack, menus (PR #38 follow-up)

- Poke Followers / GSC is now the default overworld sprite style
- Added built-in GSC/Poke Followers sprite set (`assets/enhanced_overworld/poke_followers`)
- Rebuilt HGSS/PokeMMO runtime sprites with improved detail preservation
  (nearest-neighbor only, shared pivot, no source mutation)
- Added **Poke Followers EX** in-game Start Menu submenu (`POKE FOLLOW EX`)
- Added **Wilds of Kanto** in-game Start Menu submenu
- Unified menu settings with Mod Settings (same `mod.options` keys)
- Preserved Voxel-compatible native SpriteRenderer path
- Existing explicit sprite-style saves are not overwritten; invalid/missing
  values migrate to Poke Followers / GSC

### Follower water movement (PR #38 follow-up)

- Fixed pack/trailer freeze on Surf: trail goals and steps are surface-aware for
  Pokémon follower roles only (`primary`, `party_trailer`)
- **Decoupled trailer ticks from `PikachuFollower.update`:** `ControlEngine:update`
  runs from an `OverworldController.update` wrap every logic frame (including Surf)
- Trailer `npc.update` is a no-op; `advanceTrailerStep` runs once per control update
- `shouldSpawn` may suppress stock Pikachu while surfing without stopping Wilds trailers
- Surf trail anchor is always the player (Yellow stock Pikachu is not used on water)
- Trainer trailers are hidden while surfing and restored on land (no swim)
- `FollowersWaterCompat` updates every Pokémon trailer with a per-entity cache
  and `entity.pokepcMon` species (no shared active-entity overwrite)
- Sprite rebind preserves `moving` / `targetX` / `targetY` / `progress`
- Tests: `tests/follower_water_movement_unit_test.lua`,
  `tests/follower_control_update_unit_test.lua`

### Unified follower core — standalone (PR 1 follow-up)

- Wilds no longer requires Followers EX or PokéPC Followers to run
- Registered `SPRITE_PIKACHU` at load from built-in HGSS/PokeMMO walker sheets
  (fixes standalone crash when companion mods are absent)
- Ported Followers EX ControlEngine concepts into `lib/follower/control_engine.lua`
  (control modes, trainer trail, follower count 0–6, pack trailers)
- Added Wilds Mod Settings: Control Mode, Trainer Trail, Followers
- Migrates legacy FOLLOWERS_EX / pokepc* / selected_mon settings once
- PokéPC party selection, fingerprint (now includes species), talk, and
  persistence remain built-in
- Legacy companion mods are detected for migration only; Wilds owns runtime
- Reuses existing Wilds runtime walker sheets (no PokéPC asset copy required)
- Prepared `resolveFollowerSprite` for the shared resolver (PR 2)
- Box LEADER UI and town-borrow spawns remain documented follow-ups

### Earlier 1.10.0 draft notes

- Integrated PokéPC follower selection and persistence into Wilds
- Integrated Followers EX follower lifecycle concepts (single-follower owner)
- Added Red, Blue and Yellow follower compatibility
- Documented the safe-location sprite reset root cause
- Credits: masterwebx / Followers EX, gamecorner-033 / PokéPC Followers

## 1.9.0

### Sprite Style simplification + Voxel water shadows

- Simplified Sprite Style options to HGSS/PokeMMO, Poke Followers and Pokedex
- Set HGSS/PokeMMO as the default sprite style
- Fixed Hidden Silhouettes being invisible in Voxel mode
- Added a generic question-mark-free underwater shadow marker
- Changed Voxel Silhouettes to render as flat underwater shadows
- Preserved Flat 2D water presentation

## 1.8.0

### Water Pokémon display modes + cave reachability

- Replaced the Water Mons on/off toggle with five presentation modes:
  **Swim Sprites** (default), **Hid Silhouette**, **Silhouettes**,
  **Classic Enc**, **Disabled**
- **Swim Sprites** preserves the previous swimming / levitates behaviour 100%
- **Hid Silhouette** keeps water AI / chase / collision, draws only a small
  dark animated circle on the water surface (no Pokémon sprite)
- **Silhouettes** Flat 2D: temporary dark blue-teal draw tint + proximity
  brightness + sink. Voxel: native pre-rendered 16×96 silhouette sheets for
  correct Dramatic Shape depth / occlusion (no runtime tint, no emergency body)
- Fixed Water Silhouettes in Voxel mode using native pre-rendered sheets
- Preserved the existing Flat 2D water presentation
- Prevented normal Water sprites from leaking into Voxel silhouette modes
- **Classic Enc** / **Disabled** water RNG overrides unchanged
- Added **Cave Spawns** choice: **Reachable Only** (default) / **Mixed**
- Restricted normal cave spawns to player-reachable areas (not mere walkability)
- Mixed allows ~20% atmospheric scenery in inaccessible cave pockets
- Prevented unreachable scenery Pokémon from chasing through walls
- Legacy Water Mons: `true` → `swimming_sprites`, `false` → `classic_encounters`

## 1.7.1

### PokeMMO walk frames + follower swap stability + aggressive search wander

- **Root cause of frozen PokeMMO walk:** runtime sheet generator picked source
  column 1 (idle bob). After bottom-align fit, idle and walk frames were
  pixel-identical, so `phase` 0/1 could not change the drawn frame.
- Generator now picks the first walk column whose silhouette differs from idle
  (typically column 2). Regenerated all follow-sprite and water runtime sheets.
- Native walker sheets still use Gen1Recomp's 6-frame stand/walk contract;
  extra source walk frames remain unused by design.
- Removed speculative Followers sprite-API probing; only verified
  `getActiveFollowerMon` is used.
- Stabilized active-follower selection (sticky entity) and skip
  `SpriteRenderer.new` when the bound def is unchanged.
- Kept `usingEnhancedSprite = false` for native sheets and aggressive search
  wander from the earlier 1.7.1 draft.
- Safari / SAFARI_FLEE behaviour unchanged.

## 1.7.0

### Safari Zone compatibility + Safari Flee

- Added native Safari encounter routing for visible Pokémon
- Disabled normal aggressive behaviour inside active Safari sessions
- Added Safari Flee behaviour for selected Pokémon
- Added alert and short-distance escape movement
- Preserved native Safari catch and flee mechanics
- Disabled step-based encounters during visible Safari gameplay
- Added safe Vanilla Safari fallback

## 1.6.0

### Settings consolidation + cave / water / overlay / follower style

- Consolidated all gameplay settings into Mod Settings
- Removed obsolete and duplicate developer options
- Added behaviour/facing developer overlay
- Preserved the Pokémon test-spawn selector
- Restricted cave spawns and movement to reachable cells
- Reduced visible water Pokémon density and increased spacing
- Applied selected sprite style to the active follower
- Added follower Swimming/Levitates sprite transitions

## 1.5.0

### World collision + follower water sprites

- Prevented overlapping wild Pokémon spawns
- Added atomic movement target reservations
- Prevented wild Pokémon from walking through entities
- Added optional follower Swimming/Levitates sprite switching
- Fixed land-to-water chase entry: reserve free water cell before sprite swap
- Kept committed land surface until the first water tile commits
- Prefer alternate free shore water cells when the direct entry is occupied
- Temporary occupancy blocks no longer abort shore chases
- Preserved native SpriteRenderer rendering

## 1.4.1

### Water spawn / aggro / sprite-style regressions

- Restored land aggressive chase as a separate state machine from water
- Added SpawnFx fail-safe so AI/battle cannot stay blocked forever
- Fixed movement busy invariants and alert chaseReady timeout
- Water Behaviour empty-pool fallback is `WATER_IDLE` (not land `IDLE_LOOK`)
- Relaxed water zone/rod filters; raised water spawn targets (`max_water_mons=12`)
- Diversity soft-fails instead of emptying water pools
- Added `WaterSpawn.isWaterCapable` (types → swimming/levitates → local encounters)
- SpriteResolver cache keys include `species:variant:form:surface:style`
- Explicit PokeMMO rejects Followers EX on land; style wrap re-asserted on spawn

## 1.4.0

### Water spawn variety + chase

- Added Surf and fishing encounter pools to visible water spawns
- Added shore-distance-based water spawn zones
- Added deep-water-only Super Rod species
- Improved visible water Pokémon variety
- Added aggressive water Pokémon
- Added land-to-water chase transitions for compatible aggressive Pokémon
- Added automatic Swimming/Levitates sprite transition during water chase
- Prevented water Pokémon from chasing onto land

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
