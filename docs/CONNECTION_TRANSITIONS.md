# Outdoor connection transitions

## Connection vs warp

| Kind | When | Wilds | Followers |
|---|---|---|---|
| `connection` | Outdoor↔outdoor seam (route/town/city/water) with map connections or route↔town heuristic | Soft keep + stream | Reuse entities; rebase trail |
| `warp` | Cave / dungeon / generic hard change | Full clear | `mapEnter` sync (may rebuild) |
| `door` | Safe interior (Center, house, gym, mart, lab, gate) | Full clear | `mapEnter` sync |
| `teleport` | Fly / Teleport / Dig | Full clear | `mapEnter` sync |
| `boot` | Save load / boot | Full clear | `syncAll` |

Direct outdoor connections are **not** treated like full warps.

## Streaming rule

On a soft connection:

1. Capture exit stash (player cell, wild ids, trailer refs).
2. Classify `TransitionContext`.
3. Rebase wild + follower coords: local → offset → new root local.
4. Reattach entities into `ow.entities` / `ow.npcs` (no wipe).
5. Keep origin-map wilds that are still near the player on a neighbor map.
6. Never create town/city wild spawns in this PR.

## Distances

| Knob | Default | Role |
|---|---|---|
| `connection_keep_radius` | 10 cells | Preferred keep distance |
| `connection_hard_despawn_radius` | 18 cells | Hard remove |
| `connection_max_age_steps` | 48 steps | Max transition lifetime outside keep radius |

Between keep and hard radius, normal despawn logic still applies. No unbounded persistence.

## Coordinate rebase

```text
old local (cellX/Y, px/py, targets, anchors)
  + connectionOffset (player delta preferred; map.def.connections when present)
  → new local root coords
```

Preserved: facing, movement progress, behavior state, shiny/level/encounter metadata, `wildsOriginMapId`.

## Follower persistence

On connection:

- Reattach existing `pokepcTrailers` into world lists
- Rebase trail head / goals
- `compositionDirty` only for real composition changes (count/species/mode)
- Map-ID alone does **not** rebuild `SpriteRenderer`

## Safe-interior cleanup

Doors into Centers/houses/labs/gates and cave warps still hard-clear wilds. No route wilds inside Pokémon Centers.

## Known limitations

- Soft keep uses Chebyshev distance in the new root space; neighbor rendering still depends on Gen1Recomp connection seams.
- Without `map.def.connections`, outdoor route↔town pairs use a name heuristic plus player-delta offset.
- Town wild spawns are intentionally not enabled.
- Diagnostic counters appear only in the Dev Overlay.
