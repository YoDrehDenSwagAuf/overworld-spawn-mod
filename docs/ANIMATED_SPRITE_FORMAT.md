# Animated overworld sprite format

Wilds of Kanto loads directional idle/walk animations from a shared atlas and
151 per-species JSON project files.

## Identity rule

```text
Identity = numeric speciesId / National Pokedex ID
Display  = localized name (UI / logs only)
```

Never look up sprites by `speciesName` or any localized Pokemon name.

## Assets (as shipped)

```text
assets/enhanced_overworld/
  Pokemon_Sprites/
    POKEMON 1.png                 # shared atlas (1536×480)
  pokedex_mapping/
    pokemon_001_project.json
    pokemon_002_project.json
    ...
    pokemon_151_project.json
```

Filename pattern:

```lua
string.format("pokemon_%03d_project.json", speciesId)
```

## JSON schema

```json
{
  "schemaVersion": 1,
  "speciesId": 5,
  "speciesName": "Charmeleon",
  "sourceSheet": "POKEMON 1.png",
  "cellWidth": 16,
  "cellHeight": 16,
  "animations": {
    "idle":  { "down": [], "up": [], "left": [], "right": [] },
    "walk":  { "down": [], "up": [], "left": [], "right": [] },
    "fly":   { "down": [], "up": [], "left": [], "right": [] },
    "follow":{ "down": [], "up": [], "left": [], "right": [] },
    "surf":  { "down": [], "up": [], "left": [], "right": [] }
  }
}
```

- `speciesId` must match the filename number and the lookup key.
- `speciesName` is English documentation / developer UI only.
- `sourceSheet` must match the shared atlas filename (`POKEMON 1.png`).
- `fly` / `follow` / `surf` are parsed and may be empty; overworld spawn uses
  idle + walk only.

## Frames

```json
{ "col": 32, "row": 0, "w": 1, "h": 1 }
```

```text
pixelX      = col * cellWidth
pixelY      = row * cellHeight
pixelWidth  = w   * cellWidth
pixelHeight = h   * cellHeight
```

`w` / `h` are cell counts, not pixels:

| w×h | pixels |
|-----|--------|
| 1×1 | 16×16  |
| 2×1 | 32×16  |
| 1×2 | 16×32  |
| 2×2 | 32×32  |

## Directions

JSON uses `down` / `up` / `left` / `right`.

Game facing mapping:

| Facing | Animation |
|--------|-----------|
| Front / south / down | down |
| Back / north / up | up |
| Left / west | left |
| Right / east | right |

## Validation

On load, each file checks:

1. Filename id
2. JSON `speciesId`
3. Lookup key

All three must agree. Frames must lie inside the atlas. Empty `fly`/`follow`/
`surf` arrays are fine. Missing individual idle/walk directions mark the
species `ENHANCED_PARTIAL` and use controlled fallbacks.

## Runtime fallbacks

Idle missing for a direction:

1. First walk frame, same direction
2. Idle down
3. First walk frame down
4. Legacy PNG
5. Black fallback

Walk missing for a direction:

1. Idle, same direction
2. Walk down
3. Idle down
4. Legacy PNG
5. Black fallback

Global presentation fallback chain:

1. Enhanced atlas (when option on and mapping valid)
2. Legacy species / battle PNG path
3. `assets/fallback/pokemon_missing.png`

## 2D vs Dramatic Shape Voxel

| Path | How the frame is shown |
|------|------------------------|
| Flat 2D `Entity:draw` | Atlas image + quad at **native** frame size |
| Voxel camera on | Stable `EnhancedWorldSprite` → cached **16×16** card via `resolveImage()` in DS `SpriteBillboards` |

Dramatic Shape does **not** accept atlas+quad for entity billboards. Cards are
fitted proportionally (bottom-center) into 16×16. Post-voxel `Entity:draw` is
only used if the world billboard bind fails (`SPATIAL_OVERLAY_EMERGENCY`).
Animation state is shared; cards are keyed by
`speciesId:animation:direction:frameIndex:width:height` and created at most once.

## Performance

- Atlas loaded once
- All 151 JSON files read once at mod load
- Frames normalized once
- Quads cached as `speciesId:animation:direction:frameIndex`
- No content-registry mutation after load
- Animation advances in entity `update`, never in `draw`

## Option

`use_animated_overworld_sprites` (default `true`). Toggling live refreshes
existing entities without respawn or registry writes.
