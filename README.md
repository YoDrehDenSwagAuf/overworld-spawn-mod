# Wilds of Kanto

Wilds of Kanto brings visible and reactive wild Pokemon into the overworld of
[Gen1Recomp](https://github.com/bryanthaboi/gen1recomp).

Instead of every encounter existing only behind a random battle transition,
wild Pokemon can appear directly in encounter areas, stand in tall grass,
wander around, react to the player, or remain hidden as movement in the grass.

The goal is not to replace the original Gen 1 identity. It is to add a version
of the overworld I used to imagine when playing these games as a child.

> Brings visible and reactive wild Pokemon into the Gen 1 overworld, with
> roaming, hidden and aggressive encounters across grass, caves and other
> supported areas.

<!-- Optional: add a screenshot or banner here -->

## What it does

On maps with wild encounter data, the mod reads Gen1Recomp’s imported encounter
tables and places tangible wild Pokemon (or hidden markers) on eligible tiles.

- Species and levels come from the real encounter table for the current map
- Spawns work without the Pokédex — Route 1 before Oak’s parcel is fine
- Spawn density scales with encounter-area size; larger routes can hold more
  active Pokemon, distributed across connected regions
- Tall-grass presentation uses the engine’s feet overdraw (like the player)
- Small species get nearest-neighbor sprite scaling so they stay readable
- Real Pokemon art is preferred; a black fallback sprite is used when no image
  resolves (hidden behaviours draw no Pokemon sprite)
- Vanilla random grass encounters remain as a fail-safe until the visible
  system is ready; they can stay suppressed afterward via options
- Story progress, player position, and warps are never modified

## Encounter behaviors

### Idle

Stays in place, glances a new direction every few seconds. Walking into it can
start a wild battle with that exact species and level.

### Wander

Moves randomly inside its connected encounter region (grass, cave walkables, or
water). Contact can start a battle.

### Aggressive

Has a facing sight line. When it spots the player it shows an exclamation mark
(`!`), then chases — and may leave tall grass after alerting. Contact after the
alert starts an unavoidable battle. Sight is blocked by non-walkable tiles.
Aggressive chase uses the same tile-step movement style as NPCs and is safe for
optional Dramatic Shape Voxel presentation (the `!` is the engine emote, not a
second Pokemon entity).

### Hidden

Shows no Pokemon sprite. On grass, the tile shakes; in caves, a dust/shadow
marker is used instead. Stepping onto the tile starts the encounter.

**Surface notes:** Idle and Wander are available on grass, cave, and water.
Aggressive and Hidden are used on grass and caves. Water currently supports
Idle and Wander only (no aggressive chase or hidden water markers).

## Features

- Visible wild Pokemon in supported overworld encounter areas
- Four behaviours: Idle, Wander, Aggressive, Hidden
- Map-aware spawn density and connected spawn regions
- Grass, cave (no grass graphics required), and Surf-water surfaces
- Fishing stays rod-only — fishing tables never free-spawn
- Sprite scaling capped to one map tile (16×16); transparent margins ignored
- Engine tall-grass overlay with relative occlusion for small sprites
- Fallback sprite when art is missing
- Developer mode with debug HUD, tile/behaviour overlays, and Pokemon preview
  browser (asset status, encounter locations, Test spawn)
- Optional coexistence with [Dramatic Shape Voxel Mod](https://github.com/DramaticShape/DramaticShapeVoxelMod)
  (not required); per-entity 2D fallback if a wild pose would break Voxel
- Vanilla grass encounter fallback when the spawn system is not ready

## Compatibility and testing status

The current version has been tested primarily with Pokemon Blue.

The implementation uses Gen1Recomp’s imported encounter and map data rather
than Blue-specific hard-coded tables, so it is intended to work with the other
supported Gen 1 games as well. However, Red and Yellow have not yet received
the same amount of hands-on testing.

I also have not completed a full start-to-finish playthrough with the mod
enabled. The core systems are working, but unusual maps, scripted sequences or
late-game areas may still reveal edge cases.

Bug reports are especially helpful when they include the ROM version, map name,
screenshot and relevant debug log.

### Water

Surf / water encounter tables can produce visible water Pokemon on water tiles.
They stay on connected water for wander. Vanilla Surf random encounters remain
active (water rolls are not suppressed). Fishing encounters stay rod-only.
Aggressive and Hidden behaviours are not used on water. Bridges and unusual
water layouts may still need more testing.

### Caves

Cave / indoor wild maps do not require visible grass tiles. Eligible spawn
tiles are walkable non-warp indoor cells (Gen1Recomp’s indoor encounter rule).
Hidden encounters use a dust/shadow effect instead of grass shake. Individual
caves may still need additional testing.

## Installation

1. Install [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp)
2. Import your own legally obtained Gen 1 ROM supported by Gen1Recomp
3. Download a Wilds of Kanto release ZIP (`wilds-of-kanto-v*.zip`)
4. Open Gen1Recomp → Mod Manager (F10) → Import the ZIP
5. Enable **Wilds of Kanto**
6. Reload the map / continue play if you were already in the overworld
7. Adjust options in the Mod Manager as you like

The ZIP root must contain `manifest.json` directly (no wrapping folder).
Dramatic Shape Voxel Mod is optional and not required.

This project does not include a ROM.

## Options

All options are live (`mod.options_changed`); no restart is required.

| Option | Default | Description |
| --- | --- | --- |
| Show wild Pokemon in the overworld | on | Master switch for visible spawns |
| Hide random grass encounters | on | Suppress vanilla grass rolls only after visible spawns are ready |
| Spawn density | Normal | Target count relative to encounter-area size |
| Maximum visible Pokemon | 12 | Hard cap on the current map |
| Minimum visible Pokemon | 1 | Floor when eligible tiles exist |
| Tiles per additional Pokemon | 24 | Eligible tiles needed for each Pokemon above the minimum |
| Spawn refill interval | Normal (8) | Player steps between refill attempts |
| On enter | 1 | Immediate spawn wave size (still capped by density) |
| Enable idle Pokemon | on | Allow Idle behaviour |
| Enable wandering Pokemon | on | Allow Wander behaviour |
| Enable aggressive Pokemon | on | Allow Aggressive behaviour |
| Enable hidden encounters | on | Allow Hidden grass / cave markers |
| Aggressive encounter frequency | Normal | Relative weight when picking Aggressive |
| Sprite fade | Solid | Opacity of overworld sprites |
| Minimum Pokemon sprite size | 16 | Minimum visible height after scaling (px) |
| Show Pokemon in grass | on | Prefer engine tall-grass feet overdraw |
| Enable grass movement effects | on | Hidden shake / dust pulses when supported |
| Developer mode | off | Debug HUD + Pokemon preview browser |
| Keep spawn debug HUD visible | off | Keep HUD up while developer mode is on |
| Show valid spawn tiles | off | Highlight eligible spawn tiles |
| Show behavior overlays | off | Region / sight / behaviour overlays (dev) |
| Allow test spawn outside encounter areas | off | Debug placement for Test spawn |
| Debug log | off | Verbose diagnostics (also forced on in developer mode) |
| Force test spawn | off | Force one diagnostic spawn from the map table |
| Preview filter | ALL | Species list filter for the preview browser |
| Preview search | (empty) | Search by species name or ID |
| Preview map filter | (empty) | Optional map/route id substring filter |
| Preview encounter kind | ANY | Location-list kind filter (any / grass / water / fishing) |

Legacy aliases `max_spawns` and `spawn_every_steps` remain so older saved option
files still resolve.

## Developer mode

Developer mode is optional and not needed for normal play. When enabled it:

- Shows map and encounter diagnostics (surface, species, slots, eligible tiles,
  regions, target / active counts, asset and renderer status)
- Opens the Pokemon preview browser (OPTIONS → POKEMON PREVIEW → OPEN, or
  Start Menu → WILDS PREVIEW)
- Lists species from ROM/content data without requiring the Pokédex
- Shows encounter locations and asset / entity status
- Supports phased Test spawn for diagnosis

Please include Developer mode HUD details or log lines when filing bug reports.

## Why I made this

I have always loved the original Pokemon games, and Gen1Recomp immediately
felt like a special project. Seeing those games rebuilt as a native LÖVE2D
experience, with a real modding platform on top, made me want to contribute
something of my own.

The Dramatic Shape Voxel Mod pushed that feeling even further. It showed how
much new atmosphere could be added without losing the identity of the
original games.

When I played Pokemon as a child, I often imagined that the creatures were
actually present in the routes around me: hiding in the grass, moving between
tiles, or noticing the player before a battle began. Wilds of Kanto is my
attempt to turn a little of that imagined version into something playable.

I work as a software developer, but I am not a game developer. This is my
first game mod, and building it has been a genuinely fun learning experience.

## Related projects

Wilds of Kanto is an independent fan project. It is not part of Gen1Recomp and
not part of the Dramatic Shape Voxel Mod. It does not require the voxel mod.

- [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp)  
  The native LÖVE2D recreation and modding platform that makes this mod possible.

- [Dramatic Shape Voxel Mod](https://github.com/DramaticShape/DramaticShapeVoxelMod)  
  An impressive presentation mod that turns the overworld into a 3D diorama and
  was a major source of inspiration for this project.

## Known limitations

- Tested primarily with Pokemon Blue; Red and Yellow need more hands-on checks
- No full start-to-finish playthrough with the mod enabled yet
- Unusual maps may still have odd encounter-area edge cases
- Sprite sizes are not always perfect because source art varies
- Some species may use the fallback sprite when no image resolves
- Water support is real but narrower than land (Idle / Wander only; Surf rolls
  stay vanilla)
- Cave maps may still need additional verification
- Aggressive chase uses tile steps and can struggle on complex layouts
- Compatibility with other mods is not fully guaranteed
- Temporary overworld presentation often uses battle-front art scaled to 16×16
- Voxel billboards may not mirror custom 2D scale exactly

## Documentation

- [User Guide](docs/USER_GUIDE.md)
- [Developer Guide](docs/DEVELOPER_GUIDE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Manual test checklist](MANUAL_TEST.md)
- [Changelog](CHANGELOG.md)

## Building from source

Requires a local Gen1Recomp checkout (provided by the bootstrap script) and
Python 3.

```sh
./scripts/bootstrap.sh   # once — clones engine under .deps/ and links this mod
./scripts/build-mod.py
```

Output:

```text
dist/wilds-of-kanto-v0.4.2.zip          # public release name
dist/overworld_wild_spawns-0.4.2.zip    # technical-id alias
dist/overworld_wild_spawns.zip          # unversioned alias
```

The archive root must contain the mod files directly:

```text
manifest.json
main.lua
options.lua
mod.card
assets/
lib/
docs/
…
```

Do not zip the whole git repository. `tests/`, `scripts/`, `.deps/`, and
`.git/` stay out of the package.

Headless validation (after bootstrap):

```sh
cd .deps/gen1recomp
luajit mods/overworld_wild_spawns/tests/overworld_wild_spawns_test.lua
python3 tools/modkit.py validate mods/overworld_wild_spawns
```

## Contributing and bug reports

Feedback and bug reports are welcome. When something looks wrong, please include:

- ROM version (Red / Blue / Yellow)
- Map name
- Whether a save was mid-story or a new game
- Screenshot if possible
- Relevant `[WildsOfKanto]` debug log lines (Developer mode helps)

## Legal

This is an unofficial fan-made mod. It does not include a Pokemon ROM or
copyrighted game data. A legally obtained ROM supported by Gen1Recomp is
required.

Pokemon and related trademarks belong to their respective owners.
This project is not affiliated with or endorsed by Nintendo, Game Freak,
The Pokemon Company, Gen1Recomp or Dramatic Shape.
