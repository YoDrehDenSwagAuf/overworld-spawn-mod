# Manual test guide — Wilds of Kanto 1.8.0

## After installing 1.8.0

1. Remove any previous Wilds of Kanto install from the Mod Manager.
2. Install only `wilds-of-kanto-v1.8.0.zip`.
3. Confirm the Mod Manager shows version **1.8.0**.

## Settings

1. Open Mod Settings → Wilds of Kanto.
2. Confirm core options:
   Sprite Style / Pokémon Size / Spawn Amount / Random Enc / Water Mons / OW Catch / Dev Overlay
   (plus Show Wild Mons, Grass View, Idle/Roam/Chase/Hidden Mons).
2b. **Pokémon Size** defaults to **Classic**. With Gen1Recomp (≥ #1020) in Flat:
    set **True Size**, Sprite Style **HGSS / PokeMMO**, spawn/test Charizard —
    expect ~32px tall art, feet on the cell, collision still 1 tile.
    With Dramatic Shape 1.7.9 Voxel + True Size: expect Classic geometry fallback
    (no crop/stretch corruption); DEV log explains DS gap.
3. Confirm **OW Catch** is ON/OFF (default **ON**) and toggles live.
4. Confirm **Water Mons** is a five-way choice:
   Swim Sprites / Hid Silhouette / Silhouettes / Classic Enc / Disabled
   (default **Swim Sprites**).
5. Confirm **Test Spawn** opens a Pokémon list (OPTIONS activate / OPEN).
6. Open the normal Start / Pause menu — Wilds should **not** inject
   SPRITE STYLE / SPAWN AMOUNT / RANDOM ENC / WATER MONS there.
7. Load an older save: Water Mons `true`/`false` must migrate without crash
   (`true` → Swim Sprites, `false` → Classic Enc).
8. Confirm **Sprite Style** includes **PMDCollab** (optional; default remains
   Poke Followers / GSC). With PMDCollab: wilds/followers walk with directional
   frames and occasional idle animations while standing.
9. Talk to a follower / town Pokémon with Sprite Style set to Dex, HGSS,
   Poke-Followers, **and** PMDCollab — a PMDCollab portrait should appear in
   all four cases (portraits are independent of Sprite Style). Ok/Ball must
   still work on followers.

## Overworld Catch (optional)

1. With OW Catch **ON**, confirm a small Ball HUD in the top-right on a grass route.
2. Hold **C** (default Catch Key) to charge the power meter (vertical 1–6 + green ground tiles); release to throw; **Q** (default Ball Switch) cycles Balls. Bindings can be changed in Wilds settings.
2b. With Dramatic Shape on: hold C, mouse-wheel zoom in/out — green markers stay on the same world cells.
2c. Force fail: Ball break → mon reappears → `!` → aggressive; with distance, throw again at the same mon before contact battle.
2d. Throw at a human NPC → `"Ouch, yo, WTF"`; at a Town Pokémon → `"Grrrr..."` (no catch).
2e. Mobile/controller alternative (TouchControls or gamepad logical A/B/D-Pad; default Catch Combo **B+A**, Switch Combo **B+Left/Right**):
    - Tap **B** alone → normal vanilla B (no meter / no Ball cycle).
    - Hold **B** + tap **RIGHT** / **LEFT** → next / previous Ball; player must not walk.
    - Hold **B** + hold **A** → same meter + green preview; release **A** → throw.
    - While charging, release **B** first → cancel (no Ball consumed).
    - Optional presets: Select+A / Select+Left/Right. Select alone stays native Select. Start+Select is never catch input.
    - OW CATCH **OFF**, START menu, dialogue, battle: A/B/D-Pad stay 100% vanilla.
3. Face a wild mon 1–6 tiles ahead — hit wobbles; miss still consumes a Ball.
4. Failed catch: mon breaks free → `!` → aggressive → normal Wilds battle.
5. Successful catch: Party or Box message; wild removed; no battle.
6. Safari Zone: throws disabled (native Safari menu only).
7. Toggle OW Catch **OFF**: HUD gone, throw ignored; **ON** again restores it.
8. Dramatic Shape Voxel: Ball arc / wobble visible via normal entity rendering.
9. First Person (if installed): no crash; projectile visibility may be limited
   by the external FP mod — document only, no invasive hacks.

## Water display modes

Test each Water Mons mode on a water route (Cerulean / Route 19 / 21) with
Spawn Amount = Normal. Repeat briefly on Flat and Voxel (and First Person if
available), and with Sprite Style HGSS/PokeMMO / Poke Followers / Pokedex.

### Swim Sprites (default)

1. Full Swimming / Levitates sprites, animations, Water Chase, Water Idle,
   Water Wander — identical to 1.7.x.
2. Land Pokémon, followers, Safari, cave unchanged.

### Hid Silhouette

**Flat 2D**
1. No Pokémon sprite on water — only a small dark circle on the surface.
2. Circle drifts slightly; keeps the same tile / chase / collision behaviour.
3. Touching still starts the normal wild battle with the real species.
4. Land Pokémon remain full sprites.

**Voxel / First Person**
1. Generic flat underwater shadow marker (no question mark, no Pokémon body).
2. Lies nearly horizontal under the water surface (~1–2 px sink).
3. Moves with the entity; no upright trainer billboard / no 2D HUD overlay.
4. Water Idle / Wander / Aggressive chase and encounter behaviour unchanged.

### Silhouettes

**Flat 2D**
1. Active Sprite Style / water kind unchanged; runtime dark blue-teal tint.
2. Sits a few pixels lower; proximity brightening within ~1–2 tiles.
3. Land Pokémon never receive the tint.

**Voxel / First Person**
1. Native pre-rendered silhouette sheets drawn as flat underwater shadows
   (local WaterShadowRenderer transform; not upright trainer lean).
2. Depth / object occlusion like normal water Pokémon.
3. No coloured water sprite leaking through.
4. Under-water sink ~2–3 px; animation + facing/mirroring still work.
5. Water Idle / Wander / Aggressive still animate and chase.

### Cave Spawns

1. Default **Reachable Only**: no Pokémon behind walls / on decorative plateaus.
2. **Mixed**: most on reachable paths; up to ~20% atmospheric scenery in
   inaccessible pockets (0 scenery when total target &lt; 3).
3. Scenery never aggros through walls or starts battles.
4. Dev Overlay: `CAVE · REACHABLE` / `CAVE · SCENERY`.

### Classic Enc

1. No visible water Pokémon.
2. Classic surf / fishing encounters still roll.
3. With **Random Enc = OFF**, land classic rolls stay off, but water / fishing
   rolls remain on.
4. Land visible spawns unchanged.

### Disabled

1. No visible water Pokémon.
2. No water / fishing classic encounters (even if Random Enc is ON).
3. Land Random Enc and land visible spawns unchanged.

## Safari Zone

1. Enter the Safari Zone (paid session with Safari Balls).
2. Observe several visible Pokémon: some idle, some wander.
3. Approach a SAFARI_FLEE Pokémon (Dev Overlay helps):
   - Exclamation mark appears once
   - Pokémon faces the player
   - Runs 2–5 tiles away without walking through walls/entities
   - Stays visible afterward (no despawn from overworld flee)
4. Touch any visible Safari Pokémon → native Safari encounter
   (BALL / BAIT / ROCK / RUN). Species and level match the overworld entity.
5. Confirm no normal team wild battle inside Safari.
6. With Random Enc ON or OFF: no classic step encounters during the active
   Safari session while visible spawns are running.
7. Leave the Safari Zone → normal aggressive chase must work again on routes.
8. Repeat briefly on Red / Blue / Yellow and across Safari areas when possible.

## Cave

1. Enter Diglett Tunnel and Mt. Moon several times.
2. Visible cave Pokémon must not appear behind walls / in cut-off pockets.
3. Wander and aggressive cave Pokémon must stay in reachable cells.
4. With Dev Overlay ON, HUD should report cave reachability READY (or a
   conservative FALLBACK — never unfiltered cave).

## Water density / chase

1. Visit Cerulean and a larger water route with Spawn Amount = Normal.
2. Water must look clearly sparser than 1.5.x (small ponds may be empty).
3. Compare Low vs High Spawn Amount — density should change moderately.
4. Species still come from Surf / rod pools; Super-Rod-only stay Deep.
5. Aggressive water Pokémon can still chase on water (outside Safari) in
   Swim Sprites / Hid Silhouette / Silhouettes.

## Dev Overlay

1. Enable Dev Overlay.
2. Labels appear above wild Pokémon (IDLE / WANDER / AGGRO / WATER * /
   SAFARI IDLE / SAFARI WANDER / SAFARI FLEE).
3. Facing arrows update (↑ ↓ ← →).
4. Safari flee overlays may show STATE / STEPS while fleeing.
5. Detail HUD can show Safari active / noticed / flee steps when focused.
6. HUD Water Mons line shows the mode string (e.g. `silhouettes`).

## Followers EX

1. With Followers EX + compatible style, follower uses the selected sprite style.
2. Enter/leave water: follower Swimming/Levitates transitions once per change.
3. Wild collision still blocks through followers.
4. Sprite Style = HGSS / PokeMMO: follower walk frames animate while following.
5. Style switch mid-walk must not freeze the follower on a stand frame.
6. With Followers EX installed: only one follower entity; log line
   `[Wilds] External follower mod detected; integrated follower core remains owner.`

## Unified follower core (standalone — no companion mods)

1. Red / Blue / Yellow with **only** Wilds installed: game boots to overworld.
2. Party submenu FOLLOWER selects a healthy mon; FOLLOWING marks active.
3. Mod Settings: Control Mode, Trainer Trail, Followers 0–6 apply live.
4. Trainer control + count 1: one follower behind the player.
5. Pokémon control + Trainer Trail: player is mon, trainer trails.
6. Follower Count 3 / 6: pack trailers; no duplicate entities.
7. Selection survives Route → house / Center → Route and save/load.
8. Bike / Surf: no crash, no leftover trailers; return to land restores.
9. Talk once on primary follower; Yellow Pikachu keeps vanilla talk when relevant.
10. Legacy Followers EX / PokéPC: migration warning; prefer disabling them.

## PokeMMO walk animation

1. Sprite Style = HGSS / PokeMMO on a grass route.
2. GRASS_WANDER Pokémon must show walk frames while moving between tiles.
3. IDLE_LOOK still turns without walk frames.
4. AGGRESSIVE search wander and chase must also animate walk frames.
5. Swimming / Levitates water sheets must keep the same native walk contract
   under Swim Sprites.

## Aggressive search wander

1. Outside Safari, AGGRESSIVE Pokémon should occasionally take a step while scanning.
2. Sight / chase must still work after a search step.
3. Voxel and Flat must both keep chase behaviour.
4. Land→water chase entry still works when a Swimming / Levitates sprite exists
   and Water Mons is a spawn-enabled mode.

## Pokémon Gold — followers + town talk

These steps are for a live Gold boot. Gen1 Red / Blue / Yellow must keep the
existing follower and town-talk behaviour from the sections above.

### Followers

1. Boot Gold.
2. Open party.
3. Select first Pokémon.
4. Choose FOLLOW.
5. Leave menu.
6. Pokémon appears behind player.
7. Walk 20+ steps.
8. Follower stays behind player.
9. Enter town (Route 29 → Cherrygrove).
10. Enter building.
11. Exit building.
12. No duplicate / wild teleport.
13. Surf.
14. Follower switches to swimming sprite.
15. Leave water.
16. Follower returns to land sprite.
17. Test HGSS / PokeMMO True Size.
18. Test Poké Followers style.
19. DISMISS — follower disappears, no stale trailer.

### Town Pokémon

20. Find a curated Johto town Pokémon (e.g. New Bark Sentret).
21. Face it.
22. Press A.
23. Pokémon faces player.
24. Cry/text appears.
25. No battle.
26. Normal nearby NPC still talks normally.

## Gen 2 Stadium2 Voxel + True Size (renderer)

Requires **STADIUM2_OVERWORLD_MODELS** as the **active** Voxel renderer
(not merely installed next to another Voxel mod). This matrix checks
billboard geometry only. Logical footprint stays **one cell**. Complete
Gen 2 gameplay compatibility is a separate concern.

Dev Overlay should report something like:

```text
Size requested: true_size
Size effective: true_size
Voxel provider: STADIUM2_OVERWORLD_MODELS
Variable geometry: YES (wilds_adapter)
```

or `YES (native_variable_geometry)` on a future Stadium2 that already
consumes `frameWidth`. On adapter failure: `Size effective: classic`
with an honest reason.

### GSC / Classic (Sprite Style = Poké Followers or GSC)

| Entity | Check |
| --- | --- |
| Wild | 16×16 billboard, feet on the cell, walk frames, shadow |
| Follower | same 16×16; land↔water transition keeps Classic |
| Water | Swim Sprites / Hid Silhouette / Silhouettes / Classic Enc / Disabled unchanged |

### HGSS True Size (Sprite Style = HGSS / PokeMMO)

Use current SpeciesGeometry sizes (do not hardcode). Typical examples:
Rattata small, Pikachu small/medium, Blastoise large, Onix very large/tall.

| Species | Wild | Follower | Water |
| --- | --- | --- | --- |
| Small (e.g. Rattata) | visibly smaller than Classic 16×16 stretch; feet on cell | same | swimming SpriteDef keeps its pack geometry |
| Medium (e.g. Pikachu) | between small and large | same | same |
| Large (e.g. Blastoise) | larger billboard; still 1-cell collision | same | same |
| Extreme (Onix) | tall/wide billboard; still 1-cell collision / encounter | same | swimming Onix stays large, not 16×16 |

For each cell above, check:

1. Scale matches SpeciesGeometry (not collapsed to 16×16)
2. Feet / pivot sit on the cell (anchor on Stadium2’s classic +8 / −8 pivot)
3. Walking animation + mirrored facing
4. Depth occlusion (behind buildings, tall grass)
5. Shadow / ghost silhouette matches the visible quad
6. Water modes still work (no separate Stadium2 water renderer)
7. Follower count / land↔water / map transitions do not drop geometry
8. Ambient / town Pokémon use the same SpriteDef path (no wild-only special case)

Large Pokémon must look larger **without** occupying extra map cells.

If two Wilds runtimes appear (Stadium2 embedded Wilds + this mod), that is
an external Stadium2 coexistence issue — do not expect Wilds to disable
the other copy.

### Gen1 regression

27. Boot Red — existing follower works.
28. Existing town Pokémon talk works.
29. Yellow special follower behaviour unchanged.
30. Blue follower + town talk unchanged.

