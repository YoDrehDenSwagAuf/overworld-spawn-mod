# GameCompat: experimental Gen2 / Pokémon Gold foundation

**Date:** 2026-08-13  
**Branch:** `cursor/game-compat-gen2-prep-4e37`  
**Engine inspected:** Gen1Recomp `dev` **`df35193`** (`Merge pull request #1204 from castdrian/ios-improvements`)  
**Status:** Production `manifest.json` now advertises **Gen1 + Gen2**. Gold can load Wilds. Gen2 gameplay is **not** implemented.

This is **not** full Gen2 support. Gold currently boots with Wilds enabled while Gen2 gameplay features are enabled incrementally.

---

## Current production state

| Field | Value |
|---|---|
| `games` | `["gen1", "gen2"]` |
| `game_version` | `>=0.0.0-0 <2.0.0` (unchanged; still valid on `df35193`) |
| `gen2compat` | **not used** (`games` is canonical) |
| Mod Manager label | `Gen 1+2` (`ModTargets.label`) |
| Mod Manager chip | `GEN 1+2` (`ModTargets.chip`) |
| Loader generation gate | Gold **passes** (`_gateGeneration` vs `games`) |
| `GameVersion.set()` | Still in `bootGame` **before** `Loader:load` |

**Expected player-visible result:**

| Game | Mod Manager | Runtime |
|---|---|---|
| Red / Blue / Yellow | GEN 1+2 badge | Unchanged Wilds gameplay |
| Gold | GEN 1+2 badge | Loads, options work, **no** Wild Pokémon / followers / catching yet |

---

## Engine facts (do not assume Gen1)

Verified on `/tmp/gen1recomp-src` HEAD `df35193`.

| Need | Gold API | Gen1 counterpart (do not use on Gold) |
|---|---|---|
| World object | `game.world` (`src/world/gen2/World.lua`) | `game.overworld` |
| Mod world | `mod.world` = `src.world.gen2.WorldAPI` | `src.world.WorldAPI` |
| Party | `game.save.party` (`src/core/gen2/Save.lua`) | `game.save.party` (same field, different Save class) |
| Map id | `world.map.id` (e.g. `ROUTE_29`) | `overworld.map.id` |
| Surf | `src.world.gen2.FieldMoves.isSurfing(playerState)` (`"surf"` / `"surf_pika"`) | `player.surfing` |
| Water | `Map:isWaterCell` → `Permissions.isWater(cellCollision)` | Same method name; Gen2 `Permissions` |
| Species | `game.data.pokemon[id].dex` (schema) / `.index` (`World.monIndex`) | Same resolver, 1–251 names |
| Species names | `CHIKORITA`, `CYNDAQUIL`, `TOTODILE`, `SENTRET`, `HO_OH`, `CELEBI` | Plus Gen1 names |
| Mod `game` | `Game2` | `Game` |

---

## Adapter + capabilities

| Adapter | `supported` | `generation` |
|---|---|---|
| `lib/game_compat/gen1.lua` | `true` | 1 |
| `lib/game_compat/gen2.lua` | `true` | 2 |

`GameCompat.current()`:

- generation 1 + Gen1.supported → Gen1
- generation 2 + Gen2.supported → Gen2
- otherwise → nil

`GameCompat.isSupported()` means an adapter exists. It is **not** permission to install every Wilds subsystem.

`GameCompat.supportsFeature(feature)`:

| Feature | Gen1 | Gen2 |
|---|---|---|
| `core` | true | true |
| `species` | true | true |
| `party` | true | true |
| `surf` | true | true |
| `encounters` | true | **false** |
| `followers` | true | **false** |
| `catching` | true | **false** |
| `ambient` | true | **false** |
| `townPokemon` | true | **false** |
| `safari` | true | **false** |

`main.lua` uses `supports(feature)` for every gameplay install. Gold logs:

```
[Wilds] Pokémon Gold: experimental Gen2 foundation. Encounters, followers, catching, and Kanto systems are disabled.
```

---

## Gen2 adapter methods (Gold APIs only)

| Method | Implementation |
|---|---|
| `speciesId` | Engine record `.dex` / `.index`, then `AnimatedSprites.resolveSpeciesId`. No 251-name table. |
| `isSurfing` | `FieldMoves.isSurfing(world.playerState or save.playerState)` |
| `isWaterCell` | `map:isWaterCell(x, y)` |
| `party` | `game.save.party` |
| `currentMapId` | `world.map.id` |

---

## What Gold must **not** run (this PR)

- Gen1 encounter hooks (`encounter.roll`, `movement.collision`)
- Kanto spawn tables / Wild spawn AI (`WILDS`)
- Ambient Kanto Pokémon
- Town Pokémon
- Safari compatibility
- Yellow Pikachu behavior
- Overworld Catching
- Followers (`ControlEngine`)
- Gen1 water spawn / battle hooks

True Size / sprite infrastructure may load if generation-neutral. Geometry tables remain 1..151; Gen2 species are **not** generated.

---

## Next PR only (do not implement here)

**Gold Route 29 → one visible Sentret → moves around → touch starts a normal Gold wild battle.**

No catching. No followers. No full Johto encounter table.

Likely work:

1. `Gen2.capabilities.encounters = true` (or a narrower `encounters.route29` flag).
2. Gold-only spawn source for `ROUTE_29` with a single `SENTRET`.
3. Gold movement/collision hook via `WorldAPI` / `Map` (not Gen1 `overworld.movement`).
4. Touch → `WorldAPI.start_battle` wild arm (`kind = "wild"`, `pokemon` from `World.createPokemon`).
5. Gold boot test: Route 29 installs; other maps stay empty; Gen1 tests still pass.

---

## Tests

| File | Role |
|---|---|
| `tests/gold_boot_unit_test.lua` | Gold loads `main.lua`; Gen1 systems off; options schema present |
| `tests/manifest_targets_unit_test.lua` | Production `games` → red/blue/yellow/gold + Gen 1+2 label |
| `tests/game_compat_unit_test.lua` | Gen2 adapter, capabilities, Gold species/surf/party/map |
