# Manual test guide — Wilds of Kanto 0.4.1

Earliest grass map: **ROUTE_1**. Use Developer mode HUD while verifying.

## A. Small grass route (Route 1)

1. Import `dist/wilds-of-kanto-v0.4.1.zip`, enable mod + Developer mode.
2. New game → Route 1 (no Pokédex needed).
3. HUD: Target Pokemon is low (often 1–3); Active ≤ Target/Max.
4. Confirm behaviours appear over time (Idle / Wander / Aggressive / Hidden).
5. Confirm Pokemon stand in grass with feet covered (engine overdraw), heads visible.
6. Walk onto a visible mon → battle matches species/level.
7. Disable feature → entities gone, classic grass rolls return.

## B. Long route

1. Enter a long grass route (e.g. Route 4 / 9 / 10 depending on progress).
2. HUD Target should exceed a small route’s target.
3. Pokemon should appear across multiple grass patches, not one cluster.
4. Walk the full length: far ahead refills; far behind despawns without pop-in on top of you.

## C. Aggressive Pokemon

1. Face into an Aggressive mon’s line of sight (straight row/column).
2. Expect `!` bubble (engine emote), short pause, then chase.
3. It may leave grass while chasing.
4. Contact starts exactly one battle; no softlock if path blocked (gives up).
5. Walls block sight; diagonal does not activate.

## D. Hidden Grass

1. Find a tile with grass motion and **no** Pokemon sprite.
2. Step on it → battle with the entity’s preset species/level.
3. No fallback silhouette should appear.

## E. Water

1. Map with a water encounter table (Surf).
2. Visible water Pokemon only on water tiles; species from water table.
3. No land species on water.
4. Fishing with Old/Good/Super Rod still uses vanilla rod tables (no free-spawn Magikarp from fishing-only data).
5. Vanilla Surf random encounters still function.

## F. Cave

1. Enter Mt. Moon / Diglett’s Cave / similar with wild data.
2. Spawns appear on walkable floors **without** grass graphics.
3. No grass-shake hidden effect; dust/shadow allowed for Hidden Cave.
4. Idle / Wander / Aggressive still work.

## G. Small sprites

1. Encounter Pidgey, Kakuna, Caterpie, Diglett, etc.
2. Confirm minimum scale keeps them readable in grass.
3. Developer HUD nearest-entity block shows Original / Visible / Applied scale / Rendered size.

## H. Safety checks

- Player never teleports on load / enable / test spawn
- Pokédex empty still spawns
- Map exit clears entities
- Double contact does not queue two battles
- Content registry never registers sprites at runtime (Test spawn must not error `content is frozen`)
