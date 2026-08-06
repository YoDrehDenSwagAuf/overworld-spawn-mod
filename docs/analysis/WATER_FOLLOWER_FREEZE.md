# Water Follower Freeze — Root Cause (PR #38 follow-up)

## Reproduction (expected)

```text
Only Wilds · Control Mode=Trainer · Followers=1 or 3
Land: trailers follow
Surf: swimming/levitates sprite binds
Player moves on water: trailers stay frozen on last land/shore cell
```

## Confirmed root cause

### 1. Trail placement rejects water cells

`ControlEngine:_walkableBehind` / `_seedTrailBehind` only accept:

```lua
ow.map:isWalkableCell(x, y)
```

Gen1 water/surf tiles are **not** normal NPC-walkable. When the player surfs:

- new trail goals cannot be seeded on water
- goals freeze on the last land/shore cell accepted by `isWalkableCell`
- trailers keep targeting that land cell while the player leaves them behind

Evidence: `lib/follower/control_engine.lua` `_walkableBehind` (~774–788),
`_seedTrailBehind` (~801–810), `syncTrailers` goal seeding (~885, ~907).

### 2. Stock follower suppressed on surf; trailers remain

`newShouldSpawn` returns false when `ow.player.surfing` (~1152). With
`follower_count > 0`, trailers own the field. They receive water sprites from
`FollowersWaterCompat` but keep land NPC movement rules.

### 3. `npc:update` is not water-safe for trailers

`syncTrailers` starts a step (`moving=true`, `targetX/Y`) then may call
`npc:update(ow.map, ow.entities)`. Stock NPC movement validates land walkability
and will not complete a water step even if a water goal were forced.

### 4. Secondary: single-entity water sprite cache

`FollowersWaterCompat:activeFollower()` picks **one** `_activeEntity`. Pack
trailers are collected but only one gets reliable land↔water rebinds; species
fallback may use global `getActiveFollowerMon` instead of `entity.pokepcMon`.

## Not the cause

- Water sprite routing itself (swimming/levitates resolve works)
- Global map walkability (must stay land-only for trainers/wilds)

## Fix (implemented)

### Phase A — surface-aware cells (necessary, not sufficient)

1. `ControlEngine:isFollowerCellAllowed` — land vs water for `primary` / `party_trailer` only
2. Surface-aware `_walkableBehind` / `_seedTrailBehind` / `syncTrailers`
3. Hide `trainer_trailer` while surfing; restore on land
4. Per-entity water sprite cache in `FollowersWaterCompat`

### Phase B — update ownership (actual remaining freeze)

Stock `PikachuFollower.update` early-returns when `shouldSpawn` is false
(surfing / pack). Trailer sync previously ran only from a wrap of that
function, and trailer step advance depended on `npc:update` / catch-up.

**Confirmed architecture fix:**

1. `ControlEngine:update(game, ow)` is the sole per-logic-frame owner of
   `syncPlayerControlVisual` + `syncTrailers` + `advanceAllTrailers`
2. Installed via `OverworldController.update` wrap (after vanilla), not via
   `PikachuFollower.update`
3. Trailer `npc.update` is a no-op — ControlEngine advances interpolation
4. `shouldSpawnStockFollower` stays false on Surf; `shouldUpdateWildsTrailers`
   stays true
5. Surf trail anchor is always `ow.player` (never frozen Yellow stock Pikachu)
6. Tests: `tests/follower_water_movement_unit_test.lua`,
   `tests/follower_control_update_unit_test.lua`
