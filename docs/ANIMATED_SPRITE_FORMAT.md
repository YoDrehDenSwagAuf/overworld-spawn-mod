# Follow-sprite overworld format

Wilds of Kanto loads directional idle/walk animations from individual
follow-sprite PNGs plus one shared mapping JSON.

## Identity rule

```text
Identity = numeric speciesId / National Pokedex ID
Display  = localized name (UI / logs only)
```

Never look up sprites by `speciesName` or any localized Pokemon name.

## Assets (as shipped)

```text
assets/enhanced_overworld/
  followsprites/
    001-b-n.png
    001-b-s.png
    025-m-n.png
    ...
  followsprites_mapping/
    followsprites_mapping.json
  pokedex_mapping/                 # legacy Anima JSONs (unused at runtime)
  Pokemon_Sprites/                 # commercial atlas must NOT ship
```

Filename pattern (real files):

```text
{dex}-{form}-{variant}.png
```

- `dex`: 1–3+ digit species id (zero-padded in practice, e.g. `001`)
- `form`: `b` (both/neutral), `m` (male), `f` (female)
- `variant`: `n` (normal), `s` (shiny)

Preferred form order: `b`, then `m`, then `f`. Alternate gendered files stay on
disk and may be listed under `alternateForms`. Extra form suffixes (Unown,
Deoxys, etc.) are kept but skipped by the default mapper.

Regenerate mapping:

```text
powershell -File tools/generate_followsprites_mapping.ps1
```

## Sheet layout (verified)

Each PNG is a 4×4 tile grid. Coordinates are **0-based**.

```text
rows = directions
  row 0 = down
  row 1 = left
  row 2 = right
  row 3 = up

columns = animation frames (0..3)
```

- Idle = column 0 of the direction row
- Walk = columns 0–3 of the direction row (4-frame loop)
- Runtime Gen1Recomp sheets keep **one** distinct walk pose per direction
  (typically source column 2). Column 1 is an idle bob that collapses under
  bottom-align fit and must not be used as the walk frame. Columns beyond that
  (and the right-facing row) are discarded because SpriteRenderer only supports
  stand/walk (`phase` 0/1) with right = mirrored left.

Common sizes: 128×128 → 32×32 tiles; some legends use 256×256 → 64×64 tiles.

> Note: a draft that put directions in columns does **not** match these assets.
> `atlasdata.txt` agrees that rows are directions (with north/south labels
> swapped relative to the visual down/up rows).

## Shared mapping JSON

```json
{
  "schemaVersion": 1,
  "format": "individual-follow-sprites",
  "layout": {
    "columns": 4,
    "rows": 4,
    "coordinateBase": 0,
    "interpretation": "rows-are-directions-columns-are-frames",
    "animations": { "idle": { "...": "..." }, "walk": { "...": "..." } }
  },
  "species": {
    "1": {
      "speciesId": 1,
      "preferredForm": "b",
      "normal": {
        "file": "001-b-n.png",
        "path": "assets/enhanced_overworld/followsprites/001-b-n.png",
        "imageWidth": 128,
        "imageHeight": 128,
        "tileWidth": 32,
        "tileHeight": 32
      },
      "shiny": { "...": "..." }
    }
  }
}
```

Animation templates live once under `layout.animations`. Species entries only
store file paths and dimensions.

## Runtime

- Option `sprite_style` (default `pokemmo`) selects HGSS / PokeMMO /
  Poke Followers / Pokedex. Visible `followers` maps to provider `followers_ex`.
  Legacy values `auto` / `gold` / `crystal` / `followers_ex` migrate onto the
  public three-choice set. Legacy `use_animated_overworld_sprites` migrates to
  `pokemmo` / `pokedex`.
- Cache keys: `speciesId:variant` (images), `speciesId:variant:anim:dir:frame` (quads)
- Fallback: follow variant → follow normal → legacy Pokédex PNG → black
- Runtime shiny support: **NOT AVAILABLE** for Gen1 wild spawns (preview may force shiny)
- Build-time conversion writes Gen1Recomp SpriteRenderer sheets
  (`assets/generated/followsprites_runtime/`, 16×96, 6 frames, walker) used by
  Dramatic Shape and the preferred flat draw path
