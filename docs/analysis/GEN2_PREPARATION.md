# Gen 2 preparation — manifest, detection, remaining Gen1 surfaces

This is **not** playable Gen 2 support. Production Wilds stays Gen 1 only
until a real Gen2 adapter is boot-safe.

Verified against Gen1Recomp `dev` (`src/mods/Manifest.lua`,
`src/mods/ModTargets.lua`, `src/core/GameVersion.lua`, `src/mods/Loader.lua`,
`src/core/Version.lua`).

## Future manifest (do not activate yet)

Canonical field is `games`. `gen2compat` is the legacy Gen 2 opt-in; it only
**adds** Gen 2 and is derived from the resolved `games` list. Prefer `games`.

When the Gen2 adapter is boot-safe:

```json
{
  "id": "overworld_wild_spawns",
  "api": 2,
  "games": ["gen1", "gen2"]
}
```

Gen1Recomp then:

- expands tokens to `red,blue,yellow,gold` (current engine; Silver is not a
  known version id yet)
- sets derived `gen2compat = true` for the loader gate
- shows Mod Manager / launcher label **`Gen 1+2`**
  (`ModTargets.label`, chip `GEN 1+2`)

Do **not** use `"gen2compat": true` unless an older engine that lacks `games`
must be supported. Do **not** set `games` while `Gen2.supported = false`:
the loader would run Wilds under Gold while the runtime still refuses Gen 2.

Current production `manifest.json` omits `games` and `gen2compat`. That is
the legacy reading: Gen 1 only (`red,blue,yellow`), label **`Gen 1`**.

| Manifest | Versions | Label |
|---|---|---|
| (no `games`) | red, blue, yellow | Gen 1 |
| `"games": ["gen1"]` | red, blue, yellow | Gen 1 |
| `"games": ["gen1", "gen2"]` | red, blue, yellow, gold | Gen 1+2 |
| `"games": ["all"]` | launcher order | Gen 1+2 |
| `"games": ["gen2"]` | gold | Gen 2 |

## `game_version`

Current: `">=0.0.0-0 <2.0.0"`.

Engine `src/core/Version.lua` is still `0.0.0-dev` in the working tree; CI
stamps a real `X.Y.Z` into packed `game.love`. Loader **skips** the range
check on any `0.0.0-*` placeholder so a checkout does not fail every mod.

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

`GameVersion` has zero requires, loads during `love.conf`, and
`GameVersion.set()` runs in `bootGame()` **before** `Loader:load` / mod
entry. `_gateGeneration()` also runs before any entry chunk.

Wilds `GameCompat.generation()` uses `GameVersion.generation` when the
module is present. Gold cannot be classified as Gen 1. The “module missing
→ Gen 1” path is standalone unit tests only.

## Remaining Gen1 surfaces (next PRs)

### A. Species / True Size / assets — keep 1..151 for Gen1

- `lib/species_geometry.lua` `normalizeDex` 1..151 — **Gen1 data**
- `lib/animated_sprites.lua` `MAX_SPECIES_GAME = 151` — **Gen1 diagnostic slots**
- `lib/variable_size.lua` packGeometry 1..151 — **Gen1 True Size**
- `lib/spawn_render.lua` probe `{1, 25, 151}` — **Gen1 diagnostics**
- `lib/sprite_providers.lua` probe 1 / 25 / 151 — **Gen1 diagnostics**
- `assets/generated/true_size/*` — **asset generation**, extend to 152..251 later
- `tools/generate_true_size_runtime.py` `max_dex=151` — **asset generation**
- `scripts/build-mod.py` runtime PNG count ≥ 151 — **packaging**

Do not raise these to 251 in shared code. The Gen2 adapter will own 152..251.

### B. Maps / encounters — still Kanto runtime

- `lib/spawn_logic.lua` / `lib/water_spawn.lua` — `game.data.encounters[mapId]`, rods
- `lib/surface.lua` — indoor/cave tileset rules (FOREST, firstIndoorMap)
- `lib/safari_compat.lua` — Safari Zone
- `lib/ambient_pokemon.lua` — Kanto town/center/lab kinds, hostile map patterns
  (`CERULEAN_CAVE`, `POKEMON_TOWER`, `SEAFOAM`, …)

Mark `lib/ambient_pokemon.lua` and `lib/safari_compat.lua` as the obvious
Kanto-specific modules for a later `data/gen1/` split.

### C. Catching — still Gen1 engine types

Unchanged. Later Gen2Adapter work:

- `save.inventory[ballType]` (`POKE_BALL` / `GREAT_BALL` / `ULTRA_BALL` / `MASTER_BALL`)
- `src.pokemon.Pokemon.new`, `src.pokemon.Party.add`, `src.pokemon.Boxes.deposit`
- battle start remains `world:queueScript({ "start_battle", "wild", species, level })`

### D. Followers — shared lookups moved; Yellow stays Gen1

Already via GameCompat: species id, party, surf, version string.

Intentionally Gen1-specific (do not genericize):

- `ControlEngine:_isYellow` / stock Pikachu
- `Interaction` Yellow Pikachu vanilla talk
- trail / jam / spacing / surface transition (unchanged)

### E. Battle

Still Gen1 script verb `start_battle` plus Safari native path.

## PR #2 scope (when opening Gold)

1. Implement `lib/game_compat/gen2.lua` methods; set `supported = true` only
   when boot does not install Gen1 hooks.
2. Then add `"games": ["gen1", "gen2"]` so the manager shows **Gen 1+2**.
3. Do not spawn Johto encounters, Gen2 followers, or catching until those
   adapters exist. Boot-safe ≠ gameplay.
