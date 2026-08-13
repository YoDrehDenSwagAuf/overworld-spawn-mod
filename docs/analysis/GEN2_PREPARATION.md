# GameCompat: experimental Gen2 / Pokémon Gold wild encounters

**Date:** 2026-08-13  
**Branch:** `cursor/game-compat-gen2-prep-4e37`  
**Engine inspected:** Gen1Recomp `dev` **`df35193`**  
**Status:** Production `manifest.json` advertises **Gen1 + Gen2**. Gold loads Wilds and gets **visible overworld wild Pokémon** from Gold encounter tables, plus one curated New Bark town Pokémon. Followers, catching, and Safari stay off.

This is **not** full Gen2 support.

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
| Gold | GEN 1+2 badge | Visible wilds from Gold encounter tables; New Bark Sentret; **no** followers / catching / Safari |

---

## Architecture

```text
                    Wilds Core
                        │
              shared wild entity layer
                        │
              shared sprite/render layer
                        │
              shared movement/AI layer
                        │
          ┌─────────────┴─────────────┐
          │                           │
   Gen1 Encounter Provider     Gen2 Encounter Provider
          │                           │
     Kanto data                  Johto / Gold data
          │                           │
      Red/Blue/Yellow                 Gold
```

- Shared: `lib/spawn_logic.lua`, `lib/spawn_render.lua`, `lib/movement.lua`, `lib/behavior.lua`, density, collision, exact-once battle.
- Gen1 source: `game.data.encounters[mapId]` (map-first) via `lib/game_compat/gen1.lua`.
- Gen2 source: `data.gen2Encounters` (kind-first `grass[mapId]` / `water[mapId]`) via `lib/gen2/encounters.lua`.
- Do **not** merge Johto into Gen1 tables. Do **not** route Gen1 through Gold data.

---

## Gold encounter data source

Verified on `/tmp/gen1recomp-src` HEAD `df35193`.

Gold does **not** use Gen1 `game.data.encounters[mapId]`. `Game2.lua` loads `data.gen2Encounters` from the ROM-extracted `data/generated/encounters.lua`.

Kind-first shape (`src/battle/gen2/Encounter.lua`):

```text
gen2Encounters.grass[mapId] = { rates = {MORN,DAY,NITE}, slots = { MORN=..., DAY=..., NITE=... } }
gen2Encounters.water[mapId] = { rate, slots = {3} }
```

- Grass slot chances: `{ 30, 60, 80, 90, 95, 99, 100 }` (percent)
- Water: `{ 60, 90, 100 }`
- `DARK` reuses `NITE`
- Time of day: `world.daytime` / `World:timeOfDay()` / `World:timeOfDayId()` (`MORN=0, DAY=1, NITE=2, DARK=3`)
- Wilds prefers `Encounter.grassSlot` / `Encounter.waterSlot` when the engine module is requireable; otherwise the same chances are applied locally to the normalized table.

Pokédex / habitat data is **not** used for when/where. The generated ROM table is the source. This clone of the engine does not ship `data/generated/encounters.lua`; production Gold with a real extract supplies it. Tests use kind-first fixtures, not a hand-authored Johto dump.

**Not visible Wilds spawns** (same as Gen1): fishing, headbutt, rock smash. Rods stay engine-side.

---

## Engine facts (do not assume Gen1)

| Need | Gold API | Gen1 counterpart (do not use on Gold) |
|---|---|---|
| World object | `game.world` (`src/world/gen2/World.lua`) | `game.overworld` |
| Mod world | `mod.world` = `src.world.gen2.WorldAPI` | `src.world.WorldAPI` |
| Party | `game.save.party` (`src/core/gen2/Save.lua`) | `game.save.party` (same field, different Save class) |
| Map id | `world.map.id` (e.g. `ROUTE_29`) | `overworld.map.id` |
| Surf | `src.world.gen2.FieldMoves.isSurfing(playerState)` (`"surf"` / `"surf_pika"`) | `player.surfing` |
| Water | `Map:isWaterCell` → `Permissions.isWater(cellCollision)` | Same method name; Gen2 `Permissions` |
| Species | `game.data.pokemon[id].dex` / `.index` | Same resolver, 1–151 names |
| Encounters | `data.gen2Encounters` kind-first | `game.data.encounters[mapId]` map-first |
| Wild battle | `WorldAPI:queueScript({{"start_battle","wild",species,level}})` → `src.battle.gen2.Mon` + `World:startBattle({ wild = mon })` | Same script op, Gen1 battle stack |
| Collision | `Player:tryMove` `reason = "entity"`; `ctx.entity` **not** set; Wilds uses `_spawnAt(toX,toY)` | Same reason name |

---

## Adapter + capabilities

| Adapter | `supported` | `generation` | `MAX_SPECIES` |
|---|---|---|---|
| `lib/game_compat/gen1.lua` | `true` | 1 | 151 |
| `lib/game_compat/gen2.lua` | `true` | 2 | 251 |

`GameCompat.supportsFeature(feature)`:

| Feature | Gen1 | Gen2 |
|---|---|---|
| `core` | true | true |
| `species` | true | true |
| `party` | true | true |
| `surf` | true | true |
| `encounters` | true | **true** |
| `followers` | true | **false** |
| `catching` | true | **false** |
| `ambient` | true | **true** |
| `townPokemon` | true | **true** |
| `safari` | true | **false** |

`main.lua` uses `supports(feature)` for every gameplay install. Gold logs:

```
[Wilds] Pokémon Gold: experimental Gen2 wild encounters. Followers, catching, and Safari stay off.
```

---

## Gen2 adapter methods

| Method | Implementation |
|---|---|
| `speciesId` | Engine record `.dex` / `.index`, then `AnimatedSprites.resolveSpeciesId`. No 251-name table. |
| `isSurfing` | `FieldMoves.isSurfing(world.playerState or save.playerState)` |
| `isWaterCell` | `map:isWaterCell(x, y)` |
| `party` | `game.save.party` |
| `currentMapId` | `world.map.id` |
| `encountersForMap` | `lib/gen2/encounters.lua` over `data.gen2Encounters` |
| `pickEncounter` | Engine `Encounter.grassSlot` / `waterSlot` when present |
| `startWildBattle` | `world:queueScript({ { "start_battle", "wild", species, level } })` |

Encounter tables stay out of `lib/game_compat/gen2.lua`.

Town Pokémon: `lib/gen2/town_pokemon.lua` — **New Bark Town, one Sentret** only. Not grass rolls. Not a Johto dump.

---

## Sprites / True Size

HGSS source `assets/enhanced_overworld/followsprites/` includes National Dex **1..649** (hence 152..251). `AnimatedSprites:load` already materializes every mapped id. Generated True Size / runtime sheets are extended to **251** without rewriting existing 1..151 geometry.

Poke Followers / GSC art covers **1..251**. Water swimming/levitate sheets exist for a subset of Gen2 ids; missing water art uses the existing Wilds fallback (do not mix HGSS and Poke Followers families).

Voxel consumes `frameWidth` / `frameHeight` / `anchorX` / `anchorY` the same way. No Gen2-specific Voxel code.

---

## Manual test checklist

**GOLD**

1. Start Gold with Wilds enabled.
2. Enter Route 29.
3. Visible Wild Pokémon appear.
4. Species fit Gold Route 29 encounter data (time-of-day groups).
5. Levels look correct.
6. Pokémon move with the shared Wild AI.
7. Grass presentation works if applicable.
8. Touch one.
9. Normal Gold battle starts.
10. Same species/level appears in battle.
11. Return from battle.
12. No duplicate battle.
13. Change map.
14. Old Wilds disappear.
15. New map uses its own encounter source.
16. New Bark Town shows one ambient Sentret (NPC-like, not a grass roll).

**GEN1**

17. Boot Red.
18. Route 1 behaves exactly as before.
19. Yellow follower behavior still works.
20. Catching still works.
21. True Size still works.

---

## Remaining Gen2 work (do not implement here)

**Followers for Gold**

- Sprite resolver can already accept 152..251 once assets exist.
- Still need Gold party/field-move/surf follower wiring and capability `followers = true`.
- Do not enable until that path is adapted.

**Overworld Catching for Gold**

- Needs Gold inventory, party/box, and battle-capture adaptation.
- Keep `catching = false` until those exist.

---

## Tests

| File | Role |
|---|---|
| `tests/gold_boot_unit_test.lua` | Gold loads `main.lua`; encounters/ambient on; followers/catching/Safari off |
| `tests/gen2_encounters_unit_test.lua` | Route 29 TOD groups, water, empty map, no Gen1 leak |
| `tests/gen2_wilds_unit_test.lua` | Shared SpawnLogic; Sentret Lv3 → Gold `start_battle` once |
| `tests/true_size_gen2_geometry_unit_test.lua` | 1..151 snapshot + 152..251 geometry |
| `tests/ambient_pokemon_unit_test.lua` | New Bark Sentret; no Kanto fallback on Gold |
| `tests/game_compat_unit_test.lua` | Capabilities, species, battle queue |
| `tests/manifest_targets_unit_test.lua` | Production `games` → red/blue/yellow/gold + Gen 1+2 label |
