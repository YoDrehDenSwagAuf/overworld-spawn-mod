# Wilds of Kanto

Wilds of Kanto makes Kanto feel alive in
[Gen1Recomp](https://github.com/bryanthaboi/gen1recomp).

Wild Pokémon appear in the overworld, react to the player, and can be followed
by party Pokémon — without replacing the classic Gen 1 feel.

## Features

- Visible overworld Pokémon
- Reactive encounter behaviours
- Integrated Pokémon followers
- Party follower selection
- Multiple followers
- Water Pokémon
- Swimming / silhouettes / classic water encounters
- Cave spawn filtering
- Safari compatibility
- Multiple sprite styles
- Town / Ambient Pokémon
- Red / Blue / Yellow
- Dramatic Shape Voxel compatibility

## Collaborators

Active collaborators on this project:

- [YoDrehDenSwagAuf](https://github.com/YoDrehDenSwagAuf) — Wilds of Kanto /
  overworld systems / integration
- [masterwebx](https://github.com/masterwebx) (WEX) — Followers EX / follower
  systems
- [TheRhysWyrill](https://github.com/TheRhysWyrill) (TRW) — PokéPC / follower
  selection / integration

## Encounter Behaviors

| Behavior | Description |
|----------|-------------|
| **Idle** | Pokémon stands around and looks about. |
| **Wander** | Pokémon moves within its area. |
| **Aggressive** | Pokémon notices the trainer, reacts, and chases. |
| **Hidden** | Pokémon stays hidden or is shown only via its marker. |
| **Safari Flee** | Safari Zone only — Pokémon flees after being noticed. |

## Settings

Open from the pause menu:

```text
START → OPTIONS → Poke Followers EX
START → OPTIONS → Wilds of Kanto
```

Both menus read and write the same `mod.options` keys as Mod Settings.
There is no second settings store.

### Poke Followers EX

| Setting | Values | Default | Description |
|---------|--------|---------|-------------|
| Control Mode | Trainer / Pokémon | Trainer | Who you control in the overworld. |
| Trainer Trail | On / Off | Off | When controlling a Pokémon, the trainer follows behind. |
| Followers | 0–6 | 1 | Extra party Pokémon trailing the leader. |
| Leader | Party menu | — | Choose the lead follower from the party menu. |

> Sprite Color (Colored / Classic) was removed: follower, wild, ambient, and
> party-menu sprites always render in true color, so 24-bit PNG packs
> (including the built-in Poke Followers / GSC sheets) are never force-baked
> to the GBC palette ramp.

### Wilds of Kanto

| Setting | Values | Default | Description |
|---------|--------|---------|-------------|
| Show Wild Mons | On / Off | On | Spawn visible wild Pokémon in eligible areas. |
| Spawn Amount | Low / Normal / High / Very High | Normal | How many visible overworld Pokémon can appear. |
| Random Enc | On / Off | On | Classic step-based random encounters. |
| Water Mons | Swim Sprites / Hid Silhouette / Silhouettes / Classic Enc / Disabled | Swim Sprites | How water Pokémon appear. |
| Cave Spawns | Reachable Only / Mixed | Reachable Only | Cave spawn reachability filter. |
| Sprite Style | Poke Followers / GSC · HGSS / PokeMMO · Pokédex | Poke Followers / GSC | Overworld sprite style for wilds and followers. |
| Sprite Fade | Solid / Faded | Solid | Opacity of normal wild sprites (Solid = fully opaque). |
| Town Pokémon | On / Off | On | Peaceful ambient Pokémon in safe towns and interiors. |
| Grass View | Above / Immersed | Immersed | Draw wilds above tall grass or immersed in it. |
| Idle Mons | On / Off | On | Allow idle look behaviour. |
| Roam Mons | On / Off | On | Allow wander behaviour. |
| Chase Mons | On / Off | On | Allow aggressive chase behaviour. |
| Hidden Mons | On / Off | On | Allow hidden grass / cave markers. |
| Dev Overlay | On / Off | Off | Show behaviour labels above Pokémon. |

**Test Spawn** remains available from OPTIONS / Mod Settings as an OPEN row.

## Installation

1. Install the latest release from
   [GitHub Releases](https://github.com/YoDrehDenSwagAuf/overworld-spawn-mod/releases).
2. Place the mod in your Gen1Recomp mods directory.
3. Enable **Wilds of Kanto**.
4. No separate Followers EX or PokéPC install is required.

Follower selection, control modes, and overworld sprites are built in.
Legacy Followers EX / PokéPC installs are detected only for settings migration.

## Compatibility

- Pokémon Red
- Pokémon Blue
- Pokémon Yellow
- Dramatic Shape Voxel Mod

## Credits

Short credits only — full license, asset, and third-party notices live in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Developer documentation:

- [docs/DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
