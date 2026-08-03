# Manual test guide — Wilds of Kanto 1.5.0

## After installing 1.5.0

1. Remove any older Wilds of Kanto / `overworld_wild_spawns` copy from `mods/`.
2. Install only `wilds-of-kanto-v1.5.0.zip`.
3. Fully restart the game (content registry freezes after load).
4. Optional: delete `overworld_wild_spawns-cache/` in the save directory.

## Options smoke check

Confirm visible labels are not truncated (max 14 characters):

```text
Show Wild Mons / Sprite Style / Spawn Amount / Random Enc / Water Mons
Grass View / Idle Mons / Roam Mons / Chase Mons / Hidden Mons / Dev Mode
```

Start Menu quick settings:

```text
SPRITE STYLE / SPAWN AMOUNT / RANDOM ENC / WATER MONS
```

## World collision

1. Set Spawn Amount high and enter a small route.
2. Observe for several minutes.
3. No two wild Pokémon share a cell.
4. Wanderers do not walk through each other.
5. Two chasers block like NPCs (wait / alternate paths; no tile swap).
6. Wilds do not spawn on or walk through trainers, NPCs, or an active follower.

## Follower water sprites

1. Enable Followers EX with an active follower.
2. Confirm land follower sprite on foot.
3. Start surfing.
4. Follower switches to Swimming or Levitates when available (same entity).
5. Move in water; follow queue / ownership stay with Followers EX.
6. Exit water; correct land sprite returns.
7. Without a water sprite: no crash; land art kept (`Follower water sprite: unavailable`).

## Land → water chase

1. Aggressive land Pokémon at the shore with Swimming or Levitates sprite.
2. Surf past within a few tiles of shore.
3. Pokémon may enter an unoccupied adjacent water tile.
4. Water sprite is visible immediately (no land-sprite flicker).
5. Entity id / shiny / chase / battle payload unchanged.
6. Species without water sprites stop at the shore.
7. Occupied water cells block entry.

## Water spawn variety

### Near shore

1. Small coastal route with Water Mons ON.
2. Confirm Old-/Good-Rod and Surf species can appear near shore.
3. Confirm no Super-Rod-only species spawn directly at the shore.

### Deep water

1. Large water area (e.g. Route 19 / sea routes).
2. Surf far from land.
3. Super-Rod species may appear in deep water.
4. Swimming / Levitates sprites remain correct.

### Water aggression

1. Spawn / find an aggressive water Pokémon (`WATER_AGGRESSIVE`).
2. Surf nearby within sight.
3. Alert → chase on water only → battle on contact once.
4. Leave water: chase aborts; Pokémon stays on water.

### Toggles

- Water Mons OFF: no visible water entities; land Pokémon do not enter water.
- Random Enc OFF: classic Surf/rod rolls off; visible aggressive water battles still work.
- Spawn Amount still scales water target counts.

### Dramatic Shape / rendering regression

- Flat 2D, Dramatic Shape Orbit, First Person unchanged.
- No depth/occlusion changes, no double bodies, no new overlays.
- No sprite flicker during land→water transition.
