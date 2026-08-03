# Manual test guide — Wilds of Kanto 1.4.0

## After installing 1.4.0

1. Remove any older Wilds of Kanto / `overworld_wild_spawns` copy from `mods/`.
2. Install only `wilds-of-kanto-v1.4.0.zip`.
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

### Land → water chase

1. Aggressive land Pokémon at the shore with Swimming or Levitates sprite.
2. Surf past within a few tiles of shore.
3. Pokémon may enter adjacent water, switch to water sprite immediately, continue chase.
4. Return to land: Pokémon stays in water; chase ends.
5. Species without water sprites stop at the shore (no land sprite on water).

### Toggles

- Water Mons OFF: no visible water entities; land Pokémon do not enter water.
- Random Enc OFF: classic Surf/rod rolls off; visible aggressive water battles still work.
- Spawn Amount still scales water target counts.

### Dramatic Shape

- Orbit / First Person during water chase and land→water transition.
- No sprite flicker, no clipping, depth remains correct.

## Sprite style matrix

With Gold Sprites / Followers EX / PokeMMO / Pokedex installed in turn:

1. Set Sprite Style and reload the map.
2. Confirm land sprites follow the selected style.
3. Confirm water entities still prefer Swimming → Levitates → fallback.
