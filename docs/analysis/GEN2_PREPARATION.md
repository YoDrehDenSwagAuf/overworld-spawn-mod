# Gen 2 preparation — manifest, detection, remaining Gen1 surfaces

This is **not** playable Gen 2 support. Production Wilds stays Gen 1 only
until a real Gen2 adapter is boot-safe.

Verified against Gen1Recomp `dev` HEAD `c3136bf`
(`src/mods/Manifest.lua`, `src/mods/ModTargets.lua`, `src/core/GameVersion.lua`,
`src/mods/Loader.lua`, `src/core/Version.lua`, `src/core/Game.lua`,
`src/core/Game2.lua`, launcher labels via `ModTargets.label` /
`ModTargets.chip`).

## Future manifest (do not activate yet)

Canonical field is `games`. `gen2compat` is the legacy Gen 2 opt-in; it only
**adds** Gen 2 and is derived from the resolved `games` list. Prefer `games`.

When the Gen2 adapter is boot-safe, production `manifest.json` should gain:

```json
"games": ["gen1", "gen2"]
```

Full example (not production): `docs/analysis/future-manifest-games.example.json`.

Do **not** use `"gen2compat": true` unless an older engine that lacks `games`
must be supported. Do **not** set `games` while `Gen2.supported = false`:
the loader would run Wilds under Gold while the runtime still refuses Gen 2.

Current production `manifest.json` omits `games` and `gen2compat`. That is
the legacy reading: Gen 1 only (`red,blue,yellow`), label **`Gen 1`**.

| Manifest | Versions | Label | Chip |
|---|---|---|---|
| (no `games`) | red, blue, yellow | Gen 1 | GEN 1 |
| `"games": ["gen1"]` | red, blue, yellow | Gen 1 | GEN 1 |
| `"games": ["gen1", "gen2"]` | red, blue, yellow, gold | Gen 1+2 | GEN 1+2 |
| `"games": ["all"]` | launcher order | Gen 1+2 | GEN 1+2 |
| `"games": ["gen2"]` | gold | Gen 2 | GEN 2 |

Silver / Crystal are **not** engine version ids yet (`ModTargets.expand("silver")`
is nil). `games: ["crystal"]` is an unknown token under manifest API 2.

Empty `games` array falls back to legacy Gen 1 rather than orphaning the mod.

## `game_version`

Current: `">=0.0.0-0 <2.0.0"`.

Engine `src/core/Version.lua` is still `0.0.0-dev` in the working tree; CI
stamps a real `X.Y.Z` into packed `game.love`. Loader **skips** the range
check on any `0.0.0-*` placeholder (`Loader.devEngine`) so a checkout does
not fail every mod.

`<2.0.0` still matches current 0.x / future 1.x stamps. The `games` field
does **not** require a newer engine semver — it is already in this engine.
Do not widen the range until a stamped 2.0.0+ engine exists.

Recommended until then: keep `>=0.0.0-0 <2.0.0`.

## Generation detection

Canonical API:

```lua
local id = GameVersion.get()            -- "red"|"blue"|"yellow"|"gold"
local gen = GameVersion.generation(id)  -- 1 or 2
```

`GameVersion.VERSIONS.gold.generation = 2`. Red / Blue / Yellow omit the
field; `generation()` reads that as 1. `GameVersion.info(id)`, `isYellow()`,
`isGold()` also exist. Do not hardcode Gold/Silver/Crystal in Wilds.

Lifecycle (verified):

1. `GameVersion` is zero-require and loads during `love.conf`
   (`GameVersion.current` defaults to `"red"`).
2. `bootGame(version)` calls `GameVersion.set(...)` **before** `Game:load` /
   `Game2:load`.
3. `Loader:_gateGeneration()` runs **before any mod entry chunk**.
4. `game.ready` fires after services are up (`Game.lua` / `Game2.lua`).

A real engine boot therefore never hits Wilds' "module missing" path.
That path exists only for standalone Wilds unit tests.

Wilds `GameCompat.generation()`:

- Module present → use `GameVersion.generation`; **never** assume Gen 1.
  Gold at entry with a nil `game` object is still generation 2.
- Explicit unknown version → `nil` / unsupported (not guessed as Gen 1).
- Module absent → Gen 1 so existing standalone tests keep working.

`isSupported` is true only when `current()` returns an adapter with
`supported == true`. Production: Gen1 only.

## Boot gate (STATE A)

`main.lua` skips generation-specific gameplay when
`GameCompat.isSupported(mod, game)` is false:

- no `encounter.roll` / `movement.collision` wraps
- no follower `install()` / Yellow stock Pikachu hooks
- no ambient install
- no catching / WILDS AI pipeline registration or `game.ready` level sync
- map / world / battle / save / options handlers return immediately

Content registration still runs (load-phase freeze). Voxel adapters
(Battle Art / Potato / Dramaless) still install — those paths are
intentionally unchanged in this PR.

Log once: `[Wilds] Unsupported game generation; Gen1 gameplay hooks disabled.`

This is **boot-safe ≠ supported gameplay**. Even after a future
`"games": ["gen1", "gen2"]` flip, Gen2 must not spawn Wilds Pokémon,
install Gen1 encounter/follower/catching hooks, or touch Gen1 map
structures until a real Gen2 adapter exists.

## Remaining Gen1 surfaces (next PRs)

### A. Species resolution — classified, not blindly converted

| Site | Kind | This PR |
|---|---|---|
| `GameCompat.speciesId` / `Gen1.SPECIES_TO_DEX` | SHARED via adapter | done |
| `follower/sprite_service.lua` `dexOf` | SHARED | uses GameCompat |
| `follower/control_engine.lua` `svc:dexOf` | SHARED (follower sprites) | uses sprite_service |
| `follower/control_engine.lua` `AnimatedSprites.resolveSpeciesId` (trail / submerged fallback) | SHARED, left on `AnimatedSprites` | **not converted** — mapping fallback could change True Size follow gaps |
| `lib/spawn_render.lua` / `sprite_resolver.lua` / `sprite_providers.lua` / `spawn_logic.lua` | SHARED render/spawn | left on `AnimatedSprites.resolveSpeciesId` (engine dex only; no name-table fallback). Converting would change unresolved-name behavior. |
| `lib/variable_size.lua` `resolveDex` | GEN1 DATA | still `SpeciesGeometry.normalizeDex` (adapter cap) |
| `lib/species_geometry.lua` `normalizeDex` | GEN1 DATA | cap owned by `Gen1.MAX_SPECIES` (151) |
| `lib/animated_sprites.lua` `MAX_SPECIES_GAME` | GEN1 diagnostic slots | cap owned by `Gen1.MAX_SPECIES` (151) |
| `lib/spawn_render.lua` probe `{1, 25, 151}` | GEN1 diagnostics | keep |
| `lib/sprite_providers.lua` probe 1 / 25 / 151 | GEN1 diagnostics | keep |
| `assets/generated/true_size/*` | ASSET GENERATION | keep 1..151; extend 152..251 later |
| `tools/generate_true_size_runtime.py` `max_dex=151` | ASSET GENERATION | keep |
| `scripts/build-mod.py` runtime PNG count ≥ 151 | PACKAGING | keep |
| CHANGELOG / analysis docs / mapping JSON | DOCUMENTATION | not runtime-sensitive |

Do not raise these to 251 in shared code. The Gen2 adapter will own 152..251.

### B. Maps / encounters — still Kanto runtime

Obvious Kanto-specific modules (later `data/gen1/` split):

- `lib/ambient_pokemon.lua` — town/center/lab kinds; hostile id patterns
  (`CERULEAN_CAVE`, `POKEMON_TOWER`, `SEAFOAM`, `VICTORY_ROAD`,
  `CINNABAR_ISLAND`, `INDIGO_PLATEAU`, …)
- `lib/safari_compat.lua` — `SAFARI_ZONE*` map table + native `Map.inRegion`
- `lib/surface.lua` — indoor/cave tileset rules (`FOREST`, `POKEMON_TOWER`,
  `MANSION`, `firstIndoorMap`)
- `lib/spawn_logic.lua` / `lib/water_spawn.lua` — `game.data.encounters[mapId]`,
  rods, `start_battle` wild script
- `lib/behavior.lua` — Safari land weights (`SAFARI_IDLE` / `WANDER` / `FLEE`)

Do not migrate these files in this PR.

### C. Catching — still Gen1 engine types (unchanged)

Later Gen2Adapter work; no gameplay changes here:

- bag: `game.save.inventory[ballType]` plus optional `src.inventory.Bag`
- balls: `POKE_BALL` / `GREAT_BALL` / `ULTRA_BALL` / `MASTER_BALL`
  (`lib/catching/init.lua`, `lib/catching/hud.lua`)
- party/storage: `src.pokemon.Pokemon.new`, `src.pokemon.Party.add`,
  `src.pokemon.Boxes.deposit`
- battle: not used for a successful overworld catch; wild *touch* battles
  remain `world:queueScript({ "start_battle", "wild", species, level })`
  in `lib/spawn_logic.lua`
- encounter object: `entity.species` / `entity.wildSpecies` /
  `logic` spawn records
- species ids: Gen1 names / dex via spawn records, not GameCompat yet

### D. Followers — shared lookups moved; Yellow stays Gen1

Already via GameCompat: species id (`dexOf`), party, surf, version string.

Intentionally Gen1-specific (do not genericize):

- `ControlEngine:_isYellow` / stock Pikachu (`yellowStockFollowActive`)
- `Interaction` Yellow Pikachu vanilla talk
- trail / jam / spacing / surface transition (unchanged)

Future: Gen1 adapter / Gen1 feature helper owns Yellow. Gen2 must not
assume a stock overworld Pikachu.

### E. Battle

Still Gen1 script verb `start_battle` plus Safari native path.

## Files currently using GameCompat

- `main.lua` — `isSupported` gameplay gate
- `lib/follower/sprite_service.lua` — `speciesId`
- `lib/follower/init.lua` — `isSupported`
- `lib/follower/selection.lua` — `party`
- `lib/follower/control_engine.lua` — `gameVersion` (Yellow), `isSurfing`
- `lib/follower/interaction.lua` — `gameVersion` (Yellow talk)
- `lib/followers_water_compat.lua` — `isSurfing`

## PR #2 scope (when opening Gold)

1. Implement `lib/game_compat/gen2.lua` methods from the contract comments
   (`speciesId`, `isSurfing`, `isWaterCell`, `party`, `currentMapId`)
   without guessing internals. Gold surf is `FieldMoves.isSurfing`, not
   Gen1 `player.surfing`.
2. Set `supported = true` only when a Gold boot does not install Gen1 hooks.
3. Then add `"games": ["gen1", "gen2"]` so the manager shows **Gen 1+2**.
4. Do not spawn Johto encounters, Gen2 followers, or catching until those
   adapters exist. Boot-safe ≠ gameplay.
