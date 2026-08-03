# Wilds of Kanto — User Guide (1.0.0)

Visible wild Pokemon appear in the overworld. Walk into one (or into a shaking grass patch) to start that exact wild battle. Classic random grass encounters stay available until the visible spawn system is ready on the current map.

This mod never changes your player spawn point and never requires the Pokédex.
Technical mod id: `overworld_wild_spawns` (stable for options/saves).

## 1. What the mod does

- Spawns tangible wild Pokemon (or hidden grass/cave markers) from each map’s real encounter table
- Four behaviours: Idle Look, Grass Wander, Aggressive, Hidden
- Density scales with encounter-area size so long routes feel fuller than tiny patches
- Pokemon in tall grass use the same engine feet-overdraw as the player and NPCs
- Sprites scale for readability but never exceed one map tile (16×16); transparent
  image margins are ignored so large PNGs do not look oversized

## 2. Installation

1. Build or download `wilds-of-kanto-v1.0.0.zip`
2. In Gen1Recomp open **Mod Manager (F10)** → Import the ZIP
3. Enable **Wilds of Kanto**

The ZIP root must contain `manifest.json` directly (no wrapping folder).

## 3. Enable / disable

| Control | Effect |
|---|---|
| Mod Manager switch off | Mod not loaded; fully vanilla |
| Option **Show Wild Mons** off | Removes entities, restores vanilla grass rolls |

No game restart is required; options apply live.

## 4. Prerequisites

- Gen1Recomp with a legal Gen 1 ROM decoded
- No other mods required
- Dramatic Shape Voxel Mod is optional

## 5. Pokédex is not required

Spawns work from the first map that has wild encounters (typically Route 1), before Oak’s parcel / Pokédex.

## 6. How visible Pokemon work

On map enter the mod:

1. Resolves the encounter surface (grass / cave / water)
2. Reads the matching encounter table
3. Finds eligible tiles and groups them into connected regions
4. Computes a target count from density settings
5. Spawns Pokemon with species/level from the table and a behaviour type

Touching a visible Pokemon (or a hidden marker) starts a battle with **that** species and level.

## 7. The four behaviours

| Behaviour | What you see | Battle |
|---|---|---|
| **Idle Look** | Stands still; glances a new direction every 5–10s | Contact |
| **Grass Wander** | Walks randomly inside its grass/cave/water region | Contact |
| **Aggressive** | Spots you in a straight facing line, shows `!`, then chases (may leave grass) | Unavoidable after alert; contact |
| **Hidden Grass / Cave** | No Pokemon sprite; grass shakes (or cave dust) | Step onto the tile |

Default mix (approximate): Idle 30% · Wander 35% · Aggressive 15% · Hidden 20%. Aggressive weight can be lowered in options.

## 8. How battles are triggered

- Exactly one battle per entity
- Species/level come from the entity (never re-rolled on contact)
- Vanilla random grass rolls are suppressed only after the spawn system is ready
- Fishing, Surf vanilla rolls, trainers, statics, and legendaries stay vanilla unless noted below

## 9. Spawn density

Target count is roughly:

```text
clamp(minVisible + floor(eligibleTiles / tilesPerAdditional), min, max)
```

adjusted by **Spawn Amount** (Low / Normal / High / Very High).

Long routes with many encounter tiles get more Pokemon. Tiny patches stay sparse. Pokemon are distributed across connected grass/cave/water regions, not all clustered next to you.

## 10. Appearance in grass

Gen1Recomp already draws tall-grass feet overdraw over every entity on a grass cell. This mod:

- Keeps Pokemon on `ow.entities` so that overdraw applies
- Avoids burying sprites with extra tuck offsets
- Scales very small art up (nearest-neighbor) so the head stays visible above the grass line

## 11. Water support

| Kind | Status |
|---|---|
| Surf / water encounter tables | **Supported** for visible water Pokemon on water tiles |
| Old / Good / Super Rod | **Not** free-spawned; remain rod-only |
| Land species on water | Never |

Water Pokemon stay on connected water. Vanilla Surf random encounters remain active (the mod does not suppress water rolls).

## 12. Cave support

Caves often have no tall-grass graphics but still use the grass encounter table indoors. The mod detects indoor/cave maps the same way Gen1Recomp does and spawns on walkable non-warp tiles.

- Behaviours: Idle, Wander, Aggressive, Hidden Cave (dust/shadow — not grass shake)
- Vanilla indoor encounter rolls remain the fail-safe if init fails

## 13. Options

All options are live (`mod.options_changed`). Map-density retargets on change; a map re-enter always rebuilds spawns.
Visible labels are limited to 14 characters.

### Public

| Label | Key | Default | Values | Effect |
|---|---|---|---|---|
| Show Wild Mons | `enabled` | true | on/off | Master switch |
| Hide Grass RNG | `suppress_random_grass` | true | on/off | Suppress vanilla grass rolls only when ready |
| Sprite Style | `sprite_style` | auto | Auto / Gold Sprites / Followers EX / PokeMMO / Pokedex | Overworld sprite source (Start Menu → SPRITE STYLE or Mod Settings) |
| Spawn Amount | `spawn_density` | normal | low / normal / high / very_high | Scales target count |
| Grass View | `pokemon_grass_render_mode` | immersed | Above / Immersed | Tall-grass presentation |
| Idle Mons | `enable_idle` | true | on/off | Allow Idle Look |
| Roam Mons | `enable_wander` | true | on/off | Allow Wander |
| Chase Mons | `enable_aggressive` | true | on/off | Allow Aggressive |
| Hidden Mons | `enable_hidden` | true | on/off | Allow Hidden markers |
| Dev Mode | `dev_mode` | false | on/off | HUD + preview browser |

### Developer rows

| Label | Key | Default | Effect |
|---|---|---|---|
| Debug HUD | `debug_hud_always_visible` | false | HUD stays up |
| Spawn Tiles | `show_spawn_tile_overlay` | false | Tile markers |
| Behavior View | `show_behavior_overlays` | false | Region / sight overlays |
| Outside Spawn | `allow_debug_spawn_outside_encounter_areas` | false | Debug placement |
| Debug Log | `debug_logging` | false | Verbose logs |
| Force Spawn | `force_test_spawn` | false | Force one diagnostic spawn |
| Preview Filter / Search / Map Filter / Encounter Kind | `preview_*` | … | Preview browser filters |

Density fine-tuning, sprite opacity, legacy aliases, and old strict billboard
debug probes are no longer public options; runtime defaults remain in code.

## 14. Dev Mode

Enable **Dev Mode**, then:

1. Read the top-right spawn HUD (Target / Active / Regions / Surface / …)
2. Open **OPTIONS → POKEMON PREVIEW → OPEN** (or Start Menu → **WILDS PREVIEW**)
3. Inspect assets and run **Test spawn** (7 phases)

## 15. Preview browser

Lists species from ROM/content data (not the Pokédex). Shows asset status, encounter locations, and Test spawn.

## 16. Fallback sprites

Presentation order:

1. Follow-sprite (when the option is on and the species mapping is valid)
2. Legacy species / battle PNG
3. `assets/fallback/pokemon_missing.png`

Spawns still appear in every case. Mapping errors affect only that species.
Sprite identity always uses the numeric Pokedex / species id — never the
localized display name. Shiny follow-sprites exist in assets/preview, but
Gen1 wild spawns currently always use the normal variant.

## 17. Known limitations

- Battle-front art scaled for overworld is temporary until dedicated OW sheets ship
- Aggressive AI uses tile steps (not full NPC pixel tweening)
- Water Pokemon are a best-effort swim presentation; vanilla Surf rolls stay on
- Fishing Pokemon never free-roam
- With Dramatic Shape, wild Pokemon use the same world billboards as trainers
  (depth + native grass). Large follow-sprite frames are fitted into 16x16 cards for
  Voxel only; flat 2D keeps native frame size.
- Aggressive chase keeps a stable entity id and uses the engine `!` emote

## 18. Troubleshooting

| Symptom | Check |
|---|---|
| No visible Pokemon | Dev Mode HUD: encounter data? eligible tiles? renderer? |
| Only random grass | Spawn system not READY → vanilla fail-safe is working |
| Too empty on long routes | Raise **Spawn Amount** |
| Too crowded | Lower **Spawn Amount** |
| Prefer classic static sprites | Set **Sprite Style** to **Pokedex** |
| Prefer Pokemon fully above grass | Set **Grass View** to Above |
| Want classic feel | Disable Chase / Hidden Mons, or turn Show Wild Mons off |

## 19. Uninstall

Disable or remove the mod in Mod Manager. No save edits are required; entities are runtime-only.

## 20. Savegame safety

The mod does not write player position, story flags, party, boxes, items, or Pokédex. Options live in Gen1Recomp’s global options file, not inside your playthrough blob as map state.
