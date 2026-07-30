# Manual test guide — Overworld Wild Pokemon 0.3.0

Earliest suitable grass map verified from Gen1Recomp encounter data / tests:
**ROUTE_1** (Pallet Town → Route 1). Grass rate 25; first slot PIDGEY Lv3.

## A. New game, before Pokédex (normal play)

1. Import `dist/overworld_wild_spawns-0.3.0.zip` in Gen1Recomp Mod Manager (F10).
2. Enable **Overworld Wild Pokemon**.
3. Start a **new game**. Do **not** obtain the Pokédex yet.
4. Leave Pallet Town north onto **Route 1**.
5. Look for a visible wild Pokemon in grass (not on the player tile).
6. Walk onto it. Confirm battle species and level match the overworld sprite.
7. Turn **Show wild Pokemon in the overworld** off.
8. Confirm classic random grass encounters work again on Route 1.

## B. Developer mode diagnosis (required when visible spawns are missing)

1. Install the current release ZIP and enable the mod.
2. Open Mod Manager options for **Overworld Wild Pokemon**.
3. Enable **Developer mode** (`dev_mode`). Options are live — no restart required.
4. Optionally enable **Keep spawn debug HUD visible**.
5. Start a **new game**. Do **not** obtain the Pokédex.
6. Enter the first map with wild grass encounters (**Route 1**).
7. Check the debug HUD top-right for at least:

   ```text
   Overworld Spawn Debug
   Map: Route 1
   Encounter species: …
   Encounter slots: …
   Eligible spawn tiles: …
   Loaded assets: … / …
   Active Pokemon: … / …
   Spawn system: …
   Renderer: …
   ```

8. Note Species / Slots / Tiles / Assets / Active / status values.
9. Open the Pokemon preview browser:
   - **OPTIONS** menu → **POKEMON PREVIEW** → **OPEN**
   - or Start Menu → **OW PREVIEW**
10. Select a species that appears on the current route (e.g. Pidgey).
11. Check Asset / Renderer / Overworld entity lines and **SHOW PREVIEW**.
    - Preview must report the overworld path kind (`overworld`,
      `generated_overworld`, or `placeholder`) — not pretend a battle
      front sprite is a successful overworld representation.
12. Run **TEST SPAWN**. It must **not** raise
    `sprites: content is frozen after load`.
13. Read the result text: either all 7 steps passed, or the exact failing step:

    ```text
    1 Species resolved
    2 Sprite registered
    3 Runtime asset loaded
    4 Spawn tile resolved
    5 Entity created
    6 Entity registered
    7 Entity visible
    ```

14. If step 2 fails, the species has no pre-registered overworld sprite
    (Test spawn should be DISABLED in the detail view).
15. If step 4 fails with no valid tile, enable
    **Allow test spawn outside encounter areas** and retry Test spawn.
16. Interpret:

    | Observation | Likely fault |
    |---|---|
    | Encounter species/slots = 0 | Encounter data |
    | Eligible tiles = 0, species > 0 | Tile detection |
    | Loaded assets = 0 / N | Asset resolution |
    | Test spawn fails at step 2 | Sprite not registered at mod load |
    | Test spawn fails at step 3 | Runtime asset load/bake |
    | Test spawn fails at step 5 | Entity creation |
    | Test spawn fails at step 6 | World registration |
    | Test spawn fails at step 7 | Rendering / visibility |
    | Outside-encounter test works, normal does not | Encounter-tile detection |
    | `content is frozen after load` | Architecture bug — report |

16. Optional: enable **Show valid spawn tiles** and compare green markers to grass.
    Legend: green=valid, red=blocked, blue=warp, orange=NPC/player, yellow=distance.

## C. Fail-safe check

If visible spawns cannot initialize:

- HUD / log should show a non-READY status (`NO_ENCOUNTER_DATA`, `NO_ELIGIBLE_TILES`, `ERROR`, …)
- Classic grass rolls must still occur
- The player must never be teleported

## D. Without Dramatic Shape

Leave **DRAMATIC_SHAPE** disabled. Visible spawns and the developer HUD must
still work via the base Gen1Recomp 2D `SpriteRenderer` / `ow.entities` path and
the present-only `owwild_debug_hud` pipeline.
