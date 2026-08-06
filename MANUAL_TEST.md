# Manual test guide — Wilds of Kanto 1.8.0

## After installing 1.8.0

1. Remove any previous Wilds of Kanto install from the Mod Manager.
2. Install only `wilds-of-kanto-v1.8.0.zip`.
3. Confirm the Mod Manager shows version **1.8.0**.

## Settings

1. Open Mod Settings → Wilds of Kanto.
2. Confirm core options:
   Sprite Style / Spawn Amount / Random Enc / Water Mons / Dev Overlay
   (plus Show Wild Mons, Grass View, Idle/Roam/Chase/Hidden Mons).
3. Confirm **Water Mons** is a five-way choice:
   Swim Sprites / Hid Silhouette / Silhouettes / Classic Enc / Disabled
   (default **Swim Sprites**).
4. Confirm **Test Spawn** opens a Pokémon list (OPTIONS activate / OPEN).
5. Open the normal Start / Pause menu — Wilds should **not** inject
   SPRITE STYLE / SPAWN AMOUNT / RANDOM ENC / WATER MONS there.
6. Load an older save: Water Mons `true`/`false` must migrate without crash
   (`true` → Swim Sprites, `false` → Classic Enc).

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
