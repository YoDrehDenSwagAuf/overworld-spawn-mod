# Manual test guide — Wilds of Kanto 1.8.0

## After installing 1.8.0

1. Remove any previous Wilds of Kanto install from the Mod Manager.
2. Install only `wilds-of-kanto-v1.8.0.zip`.
3. Confirm the Mod Manager shows version **1.8.0**.

## Settings

1. Open Mod Settings → Wilds of Kanto.
2. Confirm core options:
   Sprite Style / Sprite Sizes / Spawn Amount / Random Enc / Water Mons /
   Dev Overlay (plus Show Wild Mons, Grass View, Idle/Roam/Chase/Hidden Mons).
3. Confirm Sprite Style choices are exactly:
   HGSS / PokeMMO, Poke Followers, Pokedex (no Auto / Gold).
4. Confirm Sprite Sizes choices: Original (default) / Relative.
5. Confirm **Test Spawn** opens a Pokémon list (OPTIONS activate / OPEN).
6. Open the normal Start / Pause menu — Wilds should **not** inject
   SPRITE STYLE / SPAWN AMOUNT / RANDOM ENC / WATER MONS there.
7. Load an older save with `sprite_style=auto` or `gold` or `followers_ex`:
   no crash; values normalize; look matches previous Original sizes.

## Sprite styles + sizes

1. **HGSS / PokeMMO + Original**: look matches 1.7.1 exactly.
2. **HGSS / PokeMMO + Relative**: Caterpie / Pikachu visibly smaller;
   Charizard / Snorlax / Onix stay full native size; no jitter between frames.
3. Switch Original ↔ Relative: sprites refresh, no respawn, no crash.
4. **Poke Followers** without pack installed: falls back to HGSS / PokeMMO.
5. **Pokedex**: static images, no crash, battle fronts unchanged.
6. Active follower follows the selected style; size mode affects bundled
   HGSS / PokeMMO land sheets only.
7. Land → water → land: Swimming / Levitates unchanged; water chase intact.

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
3. Cave wander stays on reachable cells.

## Water

1. Toggle Water Mons ON/OFF live.
2. Confirm Swimming / Levitates sheets still animate.
3. Land → water chase still reserves a free shore cell before sprite swap.
4. Relative size mode does not alter water sprite cards in this release.

## Regression smoke

1. Random Enc ON/OFF independent of visible spawns.
2. Aggressive land chase + water chase.
3. Cell occupancy / no stacking.
4. Dramatic Shape / First Person / Voxel (if installed): no new render path.
5. Battle sprites and encounter routing unchanged.
