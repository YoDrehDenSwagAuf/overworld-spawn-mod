# Wilds of Kanto

Wilds of Kanto makes Kanto feel alive in
[Gen1Recomp](https://github.com/bryanthaboi/gen1recomp).

Wild Pokémon appear in the overworld, react to the player, and can be followed
by party Pokémon — without replacing the classic Gen 1 feel.

It also includes **experimental Pokémon Gold / Gen 2 support (beta)**.
The mod targets **Gen 1 + Gen 2** in Gen1Recomp's Mod Manager.

## Features

- Visible overworld Pokémon with idle, roam, chase, and hidden behaviours
- Optional overworld Poké Ball catching
- Built-in party followers (trainer or Pokémon control)
- Water Pokémon (swimming sprites, silhouettes, or classic encounters)
- Cave spawn filtering
- Town / ambient Pokémon
- Sprite styles: Poké Followers / GSC, HGSS / PokeMMO, Pokédex, PMDCollab
- Sprite size follows Sprite Style — GSC uses Classic (one-tile 16×16);
  HGSS uses True Size (larger relative species sizes) when the active renderer
  can consume variable SpriteDef geometry; PMDCollab keeps native imported sizes
- PMDCollab dialogue portraits for Wilds Pokémon talk (followers, town Pokémon,
  generic cries) — independent of the selected overworld Sprite Style
- Red / Blue / Yellow, plus experimental Pokémon Gold (beta)
- Safari compatibility
- Stable species-based sprite identity (reordered Pokédex / Fakemon mods keep
  the correct Wilds art, or the missing-sprite fallback)

## Pokémon Gold / Gen 2 Support — Beta

Wilds includes experimental support for Pokémon Gold through Gen1Recomp's
Gen 2 compatibility layer.

- **Gen 1:** Red / Blue / Yellow
- **Gen 2:** Pokémon Gold (**beta**)

> Pokémon Gold support is currently in beta. The core systems are working,
> but Gen2 has only recently been integrated and there may still be map,
> follower, interaction, battle, sprite, or compatibility edge cases.
> Please report anything that behaves differently from Gen1.

Currently working: overworld wilds from Gold encounter data, roam / chase,
random-encounter suppression, Wilds settings, HGSS and Poké Followers / GSC
sprites (including True Size where supported), swimming / water presentation,
town Pokémon on curated Johto towns, party followers, and overworld catching
(same throw UX as Gen1). Safari and special engine catch sessions stay off.

If reporting a Gen2 issue, include Pokémon Gold, map / location, sprite style,
follower count / control mode if relevant, Voxel mod if enabled, and
reproduction steps.

## Settings

Open from the pause menu:

```text
START → OPTIONS → Poke Followers EX
START → OPTIONS → Wilds of Kanto
```

Both menus read and write the same `mod.options` keys as Mod Settings.
There is no second settings store. Defaults match `options.lua`.

**Test Spawn** remains available from OPTIONS / Mod Settings as an OPEN row.

### Followers

| Setting | Values | Default | Description |
|---------|--------|---------|-------------|
| Control Mode | Trainer / Pokémon | Trainer | Who you control in the overworld. |
| Trainer Trail | On / Off | Off | When controlling a Pokémon, the trainer follows behind. |
| Followers | 0–6 | 1 | Extra party Pokémon trailing the leader. |
| Leader | Party menu | — | Choose the lead follower from the party menu. |

### Wild Pokémon

| Setting | Values | Default | Description |
|---------|--------|---------|-------------|
| Show Wild Mons | On / Off | On | Spawn visible wild Pokémon in eligible areas. |
| Sprite Style | Poke Followers / GSC · HGSS / PokeMMO · Pokédex · PMDCollab | Poke Followers / GSC | Overworld sprite style for wilds and followers. GSC uses Classic (16×16); HGSS uses True Size; PMDCollab uses native imported geometry with directional walk and occasional idle animations. Dialogue portraits are separate (always PMDCollab for supported Wilds Pokémon talk). |
| Sprite Fade | Solid / Faded | Solid | Opacity of normal wild sprites (Solid = fully opaque). Does not affect followers, Town Pokémon, silhouettes, or UI. |
| Spawn Amount | Low / Normal / High / Very High | Normal | How many visible overworld Pokémon can appear (including water). |
| Random Enc | On / Off | On | Classic step-based random encounters. Visible overworld Pokémon stay active. |
| Water Mons | Swim Sprites / Hid Silhouette / Silhouettes / Classic Enc / Disabled | Swim Sprites | How water Pokémon appear. |
| Cave Spawns | Reachable Only / Mixed | Reachable Only | Cave spawn reachability filter. Mixed allows ~20% atmospheric scenery in inaccessible pockets. |
| Town Pokémon | On / Off | On | Peaceful ambient Pokémon in safe towns and interiors. |
| Grass View | Above / Immersed | Immersed | Draw wilds fully above tall grass, or partially hidden inside it. |
| Silhouette | Off / Undiscovered / All | Off | Off keeps normal colours. Undiscovered silhouettes species not yet caught / registered in the Pokédex. All silhouettes every encounter-zone wild. |
| Idle Mons | On / Off | On | Allow idle look behaviour. |
| Roam Mons | On / Off | On | Allow wander behaviour. |
| Chase Mons | On / Off | On | Allow aggressive chase behaviour. |
| Hidden Mons | On / Off | On | Allow hidden grass / cave markers. |

### Overworld Catching

| Setting | Values | Default | Description |
|---------|--------|---------|-------------|
| OW Catch | On / Off | On | Direct Poké Ball throws at visible wild Pokémon. |
| Catch Key | C / V / F / G / R / T | C | Desktop key that charges and throws. |
| Ball Switch | Q / E / R / F / G / T | Q | Desktop key that cycles Balls. |
| Catch Combo | B + A / Select + A / Disabled | B + A | Controller/touch charge-and-throw combo. |
| Switch Combo | B + Left/Right / Select + Left/Right / Disabled | B + Left/Right | Controller/touch Ball-switch combo. |
| Catch HUD Size | 0–10 | 5 | Size of the Ball HUD. 0 hides the HUD only; catching stays on. |

Hold Catch Key (or Catch Combo) to charge 1–6 tiles, release to throw.
Throws only hit battleable wilds directly ahead. A miss still consumes a Ball.
Failed catches make the Pokémon aggressive through the normal `!` → chase →
battle flow. Safari sessions disable overworld throws.

### Developer

| Setting | Values | Default | Description |
|---------|--------|---------|-------------|
| Dev Overlay | On / Off | Off | Show behaviour and facing labels above wild Pokémon. |

## Encounter Behaviors

| Behavior | Description |
|----------|-------------|
| **Idle** | Pokémon stands around and looks about. |
| **Wander** | Pokémon moves within its area. |
| **Aggressive** | Pokémon notices the trainer, reacts, and chases. |
| **Hidden** | Pokémon stays hidden or is shown only via its marker. |
| **Safari Flee** | Safari Zone only — Pokémon flees after being noticed. |

## Installation

1. Install the latest release from
   [GitHub Releases](https://github.com/YoDrehDenSwagAuf/overworld-spawn-mod/releases).
   Use the packed `wilds-of-kanto-v*.zip` (manifest.json at the archive root).
   Do not import the GitHub "Source code" / `overworld-spawn-mod-main` ZIP.
2. Place the mod in your Gen1Recomp mods directory.
3. Enable **Wilds of Kanto**.
4. No separate Followers EX or PokéPC install is required.

Follower selection, control modes, and overworld sprites are built in.
Legacy Followers EX / PokéPC installs are detected only for settings migration.

## Compatibility

- Pokémon Red
- Pokémon Blue
- Pokémon Yellow
- Pokémon Gold (beta)
- Dramatic Shape Voxel Mod (True Size stays on when the **active** Voxel
  renderer can consume variable SpriteDef geometry: Battle Art Voxel, Potato
  Voxel, Dramaless Shape, and Stadium2 via public `SpriteBillboards`. Original
  Dramatic Shape stays Classic unless it ships native variable geometry.)

## Collaborators

Active collaborators on this project:

- [YoDrehDenSwagAuf](https://github.com/YoDrehDenSwagAuf) — Wilds of Kanto /
  overworld systems / integration
- [masterwebx](https://github.com/masterwebx) (WEX) — Followers EX / follower
  systems
- [TheRhysWyrill](https://github.com/TheRhysWyrill) (TRW) — PokéPC / follower
  selection / integration / Poke Followers / GSC - Sprites
- **ShockSlayer / Crystal Clear team** — for the GSC-style Pokémon sprite work that the Poké Followers / GSC presentation is based on
- [gamecorner-033](https://github.com/gamecorner-033) — Original PokéPC / Overworld Catching inspiration / overworld follower concepts and related work

## Credits

Short credits only — full license, asset, and third-party notices live in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Release history: [CHANGELOG.md](CHANGELOG.md).

Developer documentation:

- [docs/DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
