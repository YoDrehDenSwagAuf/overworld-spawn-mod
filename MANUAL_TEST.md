# Manual test guide — Wilds of Kanto 1.6.0

## After installing 1.6.0

1. Remove any previous Wilds of Kanto install from the Mod Manager.
2. Install only `wilds-of-kanto-v1.6.0.zip`.
3. Confirm the Mod Manager shows version **1.6.0**.

## Settings

1. Open Mod Settings → Wilds of Kanto.
2. Confirm core options:
   Sprite Style / Spawn Amount / Random Enc / Water Mons / Dev Overlay
   (plus Show Wild Mons, Grass View, Idle/Roam/Chase/Hidden Mons).
3. Confirm **Test Spawn** opens a Pokémon list (OPTIONS activate / OPEN).
4. Open the normal Start / Pause menu — Wilds should **not** inject
   SPRITE STYLE / SPAWN AMOUNT / RANDOM ENC / WATER MONS there.
5. Load an older save: settings must not crash; obsolete Dev Mode keys are ignored.

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
5. Aggressive water Pokémon can still chase on water.

## Dev Overlay

1. Enable Dev Overlay.
2. Labels appear above wild Pokémon (IDLE / WANDER / AGGRO / WATER *).
3. Facing arrows update (↑ ↓ ← →).
4. Behaviour changes update the label; despawned Pokémon lose their label.
5. Flat 2D must work. Dramatic Shape / First Person use the safe projection
   path when available (no voxel pipeline rewrite).

## Test Spawn

1. Open Test Spawn, pick a species, confirm spawn beside the player.
2. Occupied neighbour tiles are skipped; if none are free → `No free spawn tile`.
3. Current Sprite Style is used; occupancy is respected.

## Follower (Followers EX installed)

1. Select PokeMMO / Gold / Pokedex / Auto — follower land art updates without respawn.
2. Surf — follower switches to Swimming or Levitates when available.
3. Leave water — follower re-resolves the **current** land style (not a stale cache).
4. Shiny / form / follow queue / entity id stay stable.
5. Without Followers EX installed, Wilds must not crash.

## Regression smoke

- Land wander / aggressive chase still work.
- Land→water chase still works when water sprites exist.
- Native SpriteRenderer / Dramatic Shape / First Person unchanged.
- Cell occupancy still prevents overlaps.
