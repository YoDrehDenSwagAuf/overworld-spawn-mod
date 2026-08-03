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

## Choose Your Overworld Sprite Style

Wilds of Kanto lets you choose which overworld Pokémon sprites you prefer
without changing the spawn or encounter system.

Available styles:

- **Auto** — automatically uses an installed compatible sprite pack and falls
  back to the built-in sprites.
- **Gold Sprites** — uses the Gold/Silver battle-front art from
  **OtaconRevengeance**’s [Gold Sprites](https://github.com/OtaconRevengeance/gold_sprites)
  mod (`Gold_Silver_Sprites`) when that mod is installed. Adapted as native
  1-frame SpriteRenderer definitions (no walker sheet; no asset copy).
- **Followers EX** — uses compatible walker sprites supplied through
  **Followers EX / PokePC Followers** when those mods are installed.
- **PokeMMO** — uses the animated sprite sheets bundled with Wilds of Kanto.
- **Pokedex** — uses the original Pokédex-based images.

You can switch styles at any time from the normal in-game menu or from the
Wilds of Kanto mod settings. Existing wild Pokémon update immediately without
being respawned.

External sprite styles require their corresponding mods to be installed
separately. Wilds of Kanto does not redistribute their assets.

### Optional Sprite Mods

To use an external sprite style, install the corresponding mod through the
Gen1Recomp Mod Manager or from its official GitHub release:

- [Gold Sprites](https://github.com/OtaconRevengeance/gold_sprites/releases)
  (`Gold_Silver_Sprites`)
- [Followers EX](https://github.com/masterwebx/gen1recomp-followers-ex)
  (`FOLLOWERS_EX`)
- [PokePC Followers](https://github.com/gamecorner-033/PokePCFollowers)
  (`PokePCFollowers_VoxelMerge`), required by Followers EX

After installation, restart Gen1Recomp and select the style from:

```text
START MENU -> SPRITE STYLE
```

or:

```text
MOD SETTINGS -> WILDS OF KANTO -> SPRITE STYLE
```

Auto preference order when multiple packs are present:

1. Gold Sprites
2. Followers EX
3. PokeMMO (built-in)
4. Pokedex
5. black fallback

## Sprite Pack Shoutouts

A big shoutout to the creators who made the different overworld styles
available to the community:

- **OtaconRevengeance** — creator of the
  [Gold Sprites](https://github.com/OtaconRevengeance/gold_sprites) mod.
- **masterwebx** — creator of
  [Followers EX](https://github.com/masterwebx/gen1recomp-followers-ex).
- **gamecorner-033** — creator/maintainer of
  [PokePC Followers](https://github.com/gamecorner-033/PokePCFollowers)
  (walker sheet provider used by Followers EX; overworld art credited there to
  ShockSlayer / Pokémon Crystal Clear).
- **Anima** — source of the earlier GBC Pokémon art pack that informed Wilds’
  animated overworld work
  ([anima-nel.itch.io/gbc-pokemon](https://anima-nel.itch.io/gbc-pokemon));
  current built-in **PokeMMO** sheets are Wilds’ own runtime follow-sprite
  derivatives (see `THIRD_PARTY_NOTICES.md`).
- **DramaticShape** — Dramatic Shape Voxel Mod compatibility work that keeps
  native SpriteRenderer sheets working in orbit / first-person views.

Wilds of Kanto only integrates with externally installed sprite mods. Their
assets remain owned and licensed by their respective creators.

## Sprite Styles (technical)

Wilds of Kanto supports multiple overworld Pokémon sprite styles through a
shared provider pipeline:

- **Auto** — prefers Gold Sprites, then Followers EX, then built-in PokeMMO,
  then Pokedex.
- **Gold Sprites** — read-only adapter for `Gold_Silver_Sprites` battle fronts.
- **Followers EX** — uses compatible sprites supplied by Followers EX /
  PokePC Followers when available.
- **PokeMMO** — uses Wilds of Kanto's built-in animated overworld sprites.
- **Pokedex** — uses the original Pokédex-based images.

All styles use the same native Gen1Recomp SpriteRenderer pipeline and remain
compatible with Dramatic Shape, including first-person rendering and world
occlusion.

The **PokeMMO** label refers to Wilds of Kanto’s own runtime follow-sprite
sheets (`assets/generated/followsprites_runtime/`). It does not ship or claim
Gold Sprites / Followers EX / PokePC assets.

Optional companion mods (runtime detection only — **no hard dependencies**):

- [Gold Sprites](https://github.com/OtaconRevengeance/gold_sprites)
  (`Gold_Silver_Sprites`)
- [Followers EX](https://github.com/masterwebx/gen1recomp-followers-ex)
  (`FOLLOWERS_EX`) — control / pack integration; depends on Wilds and the
  PokePC sprite pack.
- PokePC Followers Voxel Merge (`PokePCFollowers_VoxelMerge`) — walker sheet
  assets used by Followers EX.

Companion mods can also register a provider at runtime:

```lua
wilds.exports.registerSpriteProvider("followers_ex", provider)
```

## Animated Overworld Pokémon

Wilds of Kanto uses individual follow-sprite sheets as its preferred
animated overworld sprite source (the **PokeMMO** style above).

Each supported Pokémon can use:

- directional idle sprites for down, left, right, and up;
- directional walking sprites for down, left, right, and up;
- visible idle direction changes while looking around;
- walking animations while wandering or chasing the player.

The sprites are matched exclusively by Pokédex / species ID, so the system
remains independent of the selected game language.

Normal and shiny sprite variants are supported by the asset format. Shiny
sprites are only used during normal gameplay when the game provides a reliable
shiny state. They remain available in the developer preview for testing.

Choose **Sprite Style** from the Start Menu (**SPRITE STYLE**) or in the mod
settings (Auto / Gold Sprites / Followers EX / PokeMMO / Pokedex). Auto is the
default.

If a follow sprite or mapping is missing, the mod automatically falls back to:

1. the next provider in the style chain (see Sprite Styles);
2. the previous Pokédex-based sprite;
3. the black fallback sprite.

Follow-sprites work in both the normal 2D overworld path and with Dramatic
Shape. Idle look, wander, and aggressive chase behaviour keep the same logic as
before; hidden grass encounters still show no Pokémon sprite. Species above 151
may already exist in the mapping for later use, but Gen 1 gameplay only spawns
species the current game actually supports.

## What it does

On maps with wild encounter data, the mod reads Gen1Recomp’s imported encounter
tables and places tangible wild Pokemon (or hidden markers) on eligible tiles.

- Species and levels come from the real encounter table for the current map
- Spawns work without the Pokédex — Route 1 before Oak’s parcel is fine
- Spawn density scales with encounter-area size; larger routes can hold more
  active Pokemon, distributed across connected regions
- Tall-grass presentation: option for fully above grass or partially immersed
  (engine `drawCellBottom` feet overdraw, like the player)
- Small species get nearest-neighbor sprite scaling so they stay readable
- Real Pokemon art is preferred; **Sprite Style** selects Gold Sprites,
  Followers EX, Wilds PokeMMO-style sheets, or legacy Pokedex images (Auto by
  default)
- Otherwise legacy species / battle PNGs are used; a black fallback sprite is
  used when no image resolves (hidden behaviours draw no Pokemon sprite)
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
- Sprite scaling: legacy art is capped to one map tile; follow-sprite frames
  keep native tile size with feet anchored to the tile
- Engine tall-grass overlay with relative occlusion; Dramatic Shape uses
  world billboards so bushes/walls occlude Pokemon like trainers
- Fallback chain: follow-sprite → legacy PNG → black fallback
- Dev Mode with debug HUD, tile/behaviour overlays, and Pokemon preview
  browser (follow normal/shiny, idle/walk, encounter locations, Test spawn)
- Optional coexistence with [Dramatic Shape Voxel Mod](https://github.com/DramaticShape/DramaticShapeVoxelMod)
  (not required); wild Pokemon use native `SpriteRenderer` sheets (trainer contract) and
  cached 16×16 billboard cards so DS depth/grass/occlusion match trainers;
  emergency 2D overlay only if the adapter bind fails
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
Visible labels are limited to 14 characters so Gen1Recomp does not truncate them.

| Label | Purpose | Default |
| --- | --- | --- |
| Show Wild Mons | Master switch for visible spawns | ON |
| Hide Grass RNG | Suppress vanilla grass rolls only after visible spawns are ready | ON |
| Sprite Style | Auto / Gold Sprites / Followers EX / PokeMMO / Pokedex | AUTO |
| Spawn Amount | Density preset (Low / Normal / High / Very High) | NORMAL |
| Grass View | Immersed in tall grass, or fully Above | IMMERSED |
| Idle Mons | Allow Idle Look behaviour | ON |
| Roam Mons | Allow wandering inside encounter regions | ON |
| Chase Mons | Allow aggressive spot / chase behaviour | ON |
| Hidden Mons | Allow hidden grass / cave markers | ON |
| Dev Mode | Debug HUD + Pokemon preview browser | OFF |

Developer-only rows (shown in the same panel, intended for diagnosis):
Debug HUD, Spawn Tiles, Behavior View, Outside Spawn, Debug Log, Force Spawn,
and the Preview Filter / Search / Map Filter / Encounter Kind fields.

Fine-tuning that used to appear in older builds (hard caps, refill interval,
sprite opacity, legacy aliases, strict billboard probes) is no longer in the
public menu. Runtime defaults remain in code.

## Updates

Wilds of Kanto supports update detection through the Gen1Recomp Mod Manager.

Install the mod through the manager or import the official GitHub release ZIP.
When a newer GitHub release is available, the Mod Manager can display and
install the update.

Official repository / releases:
[YoDrehDenSwagAuf/overworld-spawn-mod](https://github.com/YoDrehDenSwagAuf/overworld-spawn-mod/releases)

## Dev Mode

Dev Mode is optional and not needed for normal play. When enabled it:

- Shows map and encounter diagnostics (surface, species, slots, eligible tiles,
  regions, target / active counts, asset and renderer status)
- Opens the Pokemon preview browser (OPTIONS → POKEMON PREVIEW → OPEN, or
  Start Menu → WILDS PREVIEW)
- Lists species from ROM/content data without requiring the Pokédex
- Shows encounter locations and asset / entity status
- Supports phased Test spawn for diagnosis

Please include Dev Mode HUD details or log lines when filing bug reports.
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
- [Release test checklist](docs/RELEASE_TEST.md)
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
dist/wilds-of-kanto-v1.0.0.zip          # public release name (upload this)
dist/overworld_wild_spawns-1.0.0.zip    # local technical-id alias
dist/overworld_wild_spawns.zip          # local unversioned alias
```

Tag a release with `v1.0.0` to run `.github/workflows/release.yml`, which
publishes the public ZIP as a GitHub Release asset.
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
- Relevant `[WildsOfKanto]` debug log lines (Dev Mode helps)

## Legal

This is an unofficial fan-made mod. It does not include a Pokemon ROM or
copyrighted game data. A legally obtained ROM supported by Gen1Recomp is
required.

Original Wilds of Kanto source code is MIT-licensed (see `LICENSE`). Third-party
sprites and derived sheets are not relicensed under MIT; see
`THIRD_PARTY_NOTICES.md`.

Pokemon and related trademarks belong to their respective owners.
This project is not affiliated with or endorsed by Nintendo, Game Freak,
The Pokemon Company, Gen1Recomp or Dramatic Shape.
