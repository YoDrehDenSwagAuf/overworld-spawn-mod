# Manual test guide — Wilds of Kanto 1.7.0

## After installing 1.7.0

1. Remove any previous Wilds of Kanto install from the Mod Manager.
2. Install only `wilds-of-kanto-v1.7.0.zip`.
3. Confirm the Mod Manager shows version **1.7.0**.

## Settings

1. Open Mod Settings → Wilds of Kanto.
2. Confirm core options:
   Sprite Style / Spawn Amount / Random Enc / Water Mons / Dev Overlay
   (plus Show Wild Mons, Grass View, Idle/Roam/Chase/Hidden Mons).
3. Confirm **Test Spawn** opens a Pokémon list (OPTIONS activate / OPEN).
4. Open the normal Start / Pause menu — Wilds should **not** inject
   SPRITE STYLE / SPAWN AMOUNT / RANDOM ENC / WATER MONS there.
5. Load an older save: settings must not crash; obsolete Dev Mode keys are ignored.

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

## Water

1. Visit Cerulean and a larger water route with Spawn Amount = Normal.
2. Water must look clearly sparser than 1.5.x (small ponds may be empty).
3. Compare Low vs High Spawn Amount — density should change moderately.
4. Species still come from Surf / rod pools; Super-Rod-only stay Deep.
5. Aggressive water Pokémon can still chase on water (outside Safari).

## Dev Overlay

1. Enable Dev Overlay.
2. Labels appear above wild Pokémon (IDLE / WANDER / AGGRO / WATER * /
   SAFARI IDLE / SAFARI WANDER / SAFARI FLEE).
3. Facing arrows update (↑ ↓ ← →).
4. Safari flee overlays may show STATE / STEPS while fleeing.
5. Detail HUD can show Safari active / noticed / flee steps when focused.

## Followers EX

1. With Followers EX + compatible style, follower uses the selected sprite style.
2. Enter/leave water: follower Swimming/Levitates transitions once per change.
3. Wild collision still blocks through followers.

## Regression smoke

1. Route grass: Idle / Wander / Aggressive unchanged outside Safari.
2. Random Enc ON/OFF still gates classic step encounters outside Safari.
3. Voxel / First Person: chase and Safari flee still render via SpriteRenderer.
4. No content-registry mutation / no sprite provider rebuild required for Safari.
