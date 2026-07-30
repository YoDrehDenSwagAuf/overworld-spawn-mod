# Overworld Spawns

Visible wild Pokémon appear on grass tiles using each map's real encounter table. Walk onto one to start that exact wild battle. Works in vanilla 2D and with the Dramatic Shape Voxel pipeline.

Persona: field-mechanic / Let's-Go-style overworld encounters without replacing the rest of Gen 1.

## Try it

From a Gen1Recomp checkout with decoded ROM data:

```sh
# 1. Drop this folder into the engine's mods directory (or symlink it)
ln -sfn /path/to/overworld-spawns mods/overworld-spawns

# 2. Enable the mod in-game (F10 Mod Manager) or via options
# 3. Walk Route 1 grass — visible spawns appear; step on one to battle
```

Headless check:

```sh
luajit mods/overworld-spawns/tests/overworld_spawns_test.lua
```

## How it works

| Layer | Module | Responsibility |
|---|---|---|
| Logic | `lib/spawn_logic.lua` | `map.entered` / `world.stepped`, encounter picks, touch → `start_battle` |
| Rendering | `lib/spawn_render.lua` | `pose()` / `draw()` entities on `OverworldState.entities` |
| Shared | `lib/config.lua` | Options + defaults |

Entities ride the engine entity list, so Dramatic Shape's `VoxelScene` billboards them in 3D automatically. No Voxel-specific draw hook is required.

## Options

- **MAX SPAWNS** — cap per map
- **SPAWN RATE** — steps between spawn attempts
- **ON ENTER** — initial wave size
- **HIDE RANDOM GRASS** — suppress vanilla random grass rolls (default on)
- **SPRITE FADE** — opacity so mons read as tucked into grass

## Dual-mode rendering

1. **2D / TILT** — `Entity:draw` via SpriteRenderer, slightly translucent + grass tuck.
2. **VOXEL (DRAMATIC_SHAPE)** — same entity `pose()` → `SpriteBillboards` depth cards.
3. Species art prefers the player's decoded battle front pics baked to 16×16; otherwise the bundled placeholder silhouette ships with the mod (no ROM bytes).
