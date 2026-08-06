# Follower Integration PR 1 — Analysis & Conflict Map

**Scope:** Follower core, selection, party binding, persistence, lifecycle, talk.
**Out of scope:** Shared sprite resolver (PR 2), ambient indoor Pokémon, water renderer rebuild.

Reference sources (read-only; no git-history merge):

- Wilds of Kanto — this repository (`overworld_wild_spawns`)
- [Followers EX](https://github.com/masterwebx/gen1recomp-followers-ex) (`FOLLOWERS_EX`)
- [PokéPC Followers](https://github.com/gamecorner-033/PokePCFollowers) (`PokePCFollowers_VoxelMerge`)

---

## Wilds of Kanto (pre-PR)

| Area | Finding |
|------|---------|
| Follower ownership | **None.** Entities owned by Followers EX / PokéPC. |
| Followers-EX detection | `lib/followers_water_compat.lua` via `mod:find("FOLLOWERS_EX"\|"PokePCFollowers_VoxelMerge")` + entity markers |
| Sprite style | `sprite_style`: `pokemmo` / `followers` / `pokedex` — applied to wilds **and** active follower |
| Follower sprite switch | Entity-local `SpriteRenderer` rebind in `FollowersWaterCompat` (skip when def unchanged) |
| Safe locations | **Not implemented** in Wilds |
| Map entry | `map.entered` → wild refresh; re-assert `makeEntity` wrap; follower rebind on next behavior tick |
| Update hooks | `behavior_tick` → `followersWater:tick` (style + water only) |
| Water follower | Swimming → levitates; no land masquerade for followers |
| Voxel | Wilds only attaches wild entities (`overworldWildSpawn`); followers untouched |
| Saved settings | Only `sprite_style` (no selected mon/slot) |
| Compatibility | `FollowersWaterCompat`, `followers_ex` provider, occupancy markers |

## Followers EX

| Area | Finding |
|------|---------|
| Creation | Trailer NPCs (`pokepcTrailer`) via ControlEngine; pack modes |
| Movement | Goal queue behind trail head; driven from wrapped `PikachuFollower.update` |
| Facing | Face move dir; idle does not mirror player |
| Lifecycle | `syncTrailers` soft reseed on map enter; compositionDirty rebuild |
| Indoors | No dedicated hide; wilds town extras skip indoor |
| Voxel | Billboard UV fix + grass lift |
| Sprite provider | PokePC `follower_<SPECIES>.png`; patches `SPRITE_PIKACHU` at load |
| Exports | `getActiveFollowerMon`, `setControlMode`, `syncTrailers`, … |
| Save | `pokepcControlMode`, `pokepcFollowerCount`, `pokepcLeader`, `followerPartyIndex` |
| Hooks | PikachuFollower, SpriteRenderer, interact, Box/Party UI, Wilds makeEntity |
| Hot reload | Multiple `_followersEx*` guards |
| R/B/Y | Yellow stock Pikachu talkable path; party reorder |

## PokéPC Followers

| Area | Finding |
|------|---------|
| Selection | Party submenu FOLLOWER / FOLLOWING |
| Persist | `mod.save selected_mon` + `selected_slot`; legacy `game.save.followerPartyIndex` |
| Fingerprint | `otId:atk:def:spd:spc:catchRate` |
| Health | `hp > 0`; fainted → fallback |
| Talk | Face player; cry; `"%s is following you!"`; Yellow Pikachu → vanilla |
| Bike/Surf | `shouldSpawn` false → purge |
| Map entry | `configureSpriteDef` then sync / purge |
| Sprite | **Mutates global `game.data.sprites[SPRITE_PIKACHU]`** + may `SpriteRenderer.new` |
| Icons | Global `generated.icons` mutation (not adopted) |
| Save keys | `selected_mon`, `selected_slot`, `followerPartyIndex`, `followerSpecies` |
| Hot reload | `PikachuFollower.__pokepcFollowersUniversal` + `restore` |
| Assets | `follower_001.png`…`151` (not redistributed by Wilds) |

---

## Feature comparison

```text
Feature                         | Wilds (pre)              | Followers EX              | PokéPC                    | Conflict                         | Preferred owner (PR1) | Integration strategy
--------------------------------+--------------------------+---------------------------+---------------------------+----------------------------------+-----------------------+----------------------------------
Follower entity create/remove   | none                     | trailers / pack           | PikachuFollower wrap      | dual entities if both run        | Wilds Follower Core   | Port single-follower lifecycle; defer when EX pack active
Movement / facing               | none                     | trail queue               | stock PikachuFollower     | EX pack vs stock                 | Wilds Follower Core   | Stock movement via PikachuFollower; no EX pack in PR1
Party selection UI              | none                     | LEADER / modes            | FOLLOWER submenu          | competing menus                  | PokéPC concepts       | Port FOLLOWER submenu only; no global icon mutate
Selection persistence           | none                     | pokepcLeader / index      | selected_mon + slot       | overlapping save keys            | PokéPC concepts       | Wilds save v1 + migrate PokéPC/EX keys once
Mon fingerprint                 | none                     | species|lvl|nick|ot|dvs   | ot|dvs|catchRate          | different keys                   | PokéPC concepts       | Use PokéPC fingerprint (stable for identical species)
Health / empty party            | n/a                      | partyTrailMons filters    | healthy gate              | none                             | PokéPC concepts       | Port healthy + first-healthy fallback
Talk                            | none                     | Yellow interact wrap      | wrappedTalk               | double TextBox if both           | PokéPC concepts       | Single talk owner; idempotent wrap
Bike / Surf despawn             | water rebind only        | restore trainer visual    | shouldSpawn false         | EX keeps trailers on bike?       | Wilds Follower Core   | PokéPC shouldSpawn rule; signal land/surfing to Wilds water
Sprite style (wilds+follower)   | owns                     | forces pokepc sheets      | SPRITE_PIKACHU mutate     | EX overrides Wilds style         | Wilds                 | Keep Wilds style; refresh via handler (PR2 resolver later)
Water follower presentation     | FollowersWaterCompat     | none dedicated            | despawn on surf           | Wilds wants water sprites        | Wilds                 | Keep existing water compat; lifecycle only signals surface
Global sprite def mutation      | avoids (entity-local)    | load-time patch + resolve | configureSpriteDef/update | Safe-location sprite reset bug   | Wilds                 | Never mutate global defs per update; local/cache only
SpriteRenderer.new thrash       | skip if def match        | per trailer create        | species/image mismatch    | flicker / default sprite flash   | Wilds                 | Reuse entity; new only on species/def change
Voxel                           | wilds only               | UV fix / grass lift       | resolveImage override     | competing draw paths             | Wilds (unchanged)     | Do not port EX UV/grass; keep wild voxel adapter
Ambient indoor Pokémon          | none                     | town extras (not ambient) | none                      | —                                | later PR              | Not in PR1
Hot reload                      | feature hooks            | many guards               | STATE_KEY restore         | wrapper chains                   | Wilds                 | Single `__wildsUnifiedFollowerState`
External mod coexistence        | soft detect              | depends on Wilds+PokePC   | standalone                | double hooks                     | Wilds guard           | Detect IDs; no second entity; migrate; warn
```

---

## Safe-location sprite bug (documented; full resolver = PR 2)

**Symptom:** Route → house / Pokémon Center / safe indoor → follower briefly or permanently shows wrong / default sprite.

**Root cause chain (PokéPC pattern):**

1. `wrappedOnMapEntered` / `wrappedUpdate` call `configureSpriteDef`, which **mutates** `game.data.sprites[SPRITE_PIKACHU].image` to the selected species path.
2. Stock `PikachuFollower.onMapEntered` may respawn or rebind using the global def; map content reload can **reset** `SPRITE_PIKACHU` back toward the registered/default image (often Pikachu / Charmander fallback).
3. `syncLiveFollowerDef` then sees image mismatch → **`SpriteRenderer.new`**, causing a frame of default art and movement-queue risk.
4. Followers EX additionally forces Yellow stock Pikachu art and Wilds `map.entered` refreshes can race depending on mod priority (Wilds 80 vs EX 160).

**Why location matters:** Indoor/safe map entry reloads field sprite registries / follower spawn path more aggressively than same-map steps, so the global mutable def is the wrong place to store follower identity.

**PR 1 mitigation (no full resolver):**

- Do not use global `SPRITE_PIKACHU` mutation as follower state.
- Entity-local def apply; skip `SpriteRenderer.new` when image/frames/walker unchanged.
- `requestFollowerSpriteRefresh(reason)` / `setSpriteRefreshHandler` for PR 2.
- Lifecycle must not reset selection or unnecessarily despawn across safe-map transitions.

---

## Ownership after PR 1

- **Single runtime owner key:** `PikachuFollower.__wildsUnifiedFollowerState`
- **Wilds owns** selection + (when no Followers EX control engine) entity lifecycle + talk.
- **When `FOLLOWERS_EX` control engine is active:** Wilds does not spawn a second trailer/entity; logs  
  `[Wilds] External follower mod detected; integrated follower core remains owner.`  
  and defers entity create/remove to the external engine while still owning Wilds save selection / migration / water signaling.
- **When PokéPC lifecycle is present without EX:** call public `exports.restore` if available, then install Wilds hooks (PokéPC concepts absorbed).

---

## Credits (ported concepts)

- masterwebx / Followers EX — lifecycle / map-enter stability ideas, public export surface
- gamecorner-033 / PokéPC Followers — selection, fingerprint, talk, party submenu
- ShockSlayer / Pokémon Crystal Clear — overworld follower art (via PokéPC; not redistributed)
- TRW / DAX — acknowledged in upstream follower lineage where credited by those projects
