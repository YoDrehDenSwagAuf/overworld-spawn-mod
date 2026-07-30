# Manual test guide — Overworld Wild Pokemon 0.2.0

Earliest suitable grass map verified from Gen1Recomp encounter data / tests:
**ROUTE_1** (Pallet Town → Route 1). Grass rate 25; first slot PIDGEY Lv3.

## New game, before Pokédex

1. Import `dist/overworld_wild_spawns-0.2.0.zip` in Gen1Recomp Mod Manager (F10).
2. Enable **Overworld Wild Pokemon**.
3. Optionally enable **DEBUG LOG** (and **FORCE TEST SPAWN** if you need an immediate probe).
4. Start a **new game**. Do **not** obtain the Pokédex yet.
5. Leave Pallet Town north onto **Route 1**.
6. Check the debug log (if enabled):
   - `spawn system initialized on ROUTE_1`
   - `eligible tiles=…`
   - `suppress_ready=true` only after a successful visible spawn
   - `pokedex_owned=false diag-only` (diagnostic only — not a gate)
7. Wait for / look for a visible wild Pokemon in grass (not on the player tile).
8. Walk onto it. Confirm battle species and level match the overworld sprite.
9. Turn **Show wild Pokemon in the overworld** off.
10. Confirm classic random grass encounters work again on Route 1.

## Fail-safe check

If visible spawns cannot initialize (no grass tiles, renderer error, etc.):

- Log should show `restore vanilla encounters: …`
- Classic grass rolls must still occur
- The player must never be teleported

## Without Dramatic Shape

Leave **DRAMATIC_SHAPE** disabled. Visible spawns must still appear via the
base Gen1Recomp 2D `SpriteRenderer` / `ow.entities` path.
