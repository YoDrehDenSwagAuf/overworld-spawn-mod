# SpriteCollab format investigation (PMDCollab/SpriteCollab)

Investigated from live GitHub sources on 2026-08-21 (API + raw file fetches; no full 1.9GB clone). Repo size ≈ 1.9GB; default branch `master`.

Primary sources:
- https://github.com/PMDCollab/SpriteCollab
- https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master/...
- Companion bot logic: https://github.com/PMDCollab/SpriteBot (`Constants.py`, `TrackerUtils.py`, `SpriteUtils.py`)
- Format wiki: https://wiki.pmdo.pmdcollab.org/PMD_Sprite_Format

Reference copies saved under `third_party/SpriteCollab-*`.

---

## 1. LICENSE.md (exact) and README use policy

### LICENSE.md

`LICENSE.md` is the full **Creative Commons Attribution-NonCommercial 4.0 International** public license text (CC BY-NC 4.0). Exact copy: `third_party/SpriteCollab-LICENSE.md` (17607 bytes).

Title line: `# Attribution-NonCommercial 4.0 International`

Core grant (Section 2(a)(1)): reproduce/Share and produce Adapted Material **for NonCommercial purposes only**.

Attribution conditions (Section 3(a)): retain creator identification, copyright notice, license notice, warranty disclaimer, URI to material; indicate modifications; indicate CC BY-NC 4.0.

### README use policy (verbatim substance)

From live `README.md`:

> By submitting files to the bot, you provide permission for others to copy and redistribute the material in any medium or format, or remix, transform, and build upon the material, as long as the work is `non-commercial` and `appropriate credit` is given. For specific terms, view the CC BY-NC license: https://creativecommons.org/licenses/by-nc/4.0/

Also: portraits must be **40×40**, prefer ≤15 colors; do not replace Chunsoft portraits/emotions unless incomplete; no unofficial Pokémon/forms; special slots allowed for Alternate / AltColor / Beta / named official spin-off forms.

**Integration implication for Wilds of Kanto:** SpriteCollab fan assets are **non-commercial only**. Official Chunsoft-origin assets in the repo are tracked separately under credit id `CHUNSOFT` (license field often `Unspecified` in per-folder `credits.txt`).

Historical per-credit licenses also appear in `license_history/`:
- `LICENSE.CC_BY-NC_4.md` — current
- `LICENSE.PMDCollab_1.md` — credit retained (no NC clause in that short text)
- `LICENSE.PMDCollab_2.md` — credit retained **and** not for profit

---

## 2. How credits / attribution work

### `credit_names.txt` (artist registry)

Tab-separated, header:

```
Name	Discord	Contact
CHUNSOFT	CHUNSOFT	https://www.spike-chunsoft.com/
Audino	<@!117780585635643396>	https://github.com/audinowho
...
```

Maps Discord IDs / handles → display name + contact URL. Used when resolving credit IDs from `credits.txt`.

### Per-asset `credits.txt`

Present in each species/form folder that has assets. Format is **5 tab-separated fields** (SpriteBot `CreditEvent`):

```
datetime	author_id	CUR|OLD	license_token	comma,separated,changed,assets
```

Examples (Bulbasaur sprite root):

```
2020-10-07 17:58:43.323442	CHUNSOFT	CUR	Unspecified	Walk,Attack,Strike,Shoot,Dance,Shake,Sleep,Hurt,Idle,Swing,Double,Hop,Charge,Rotate,EventSleep,Wake,Eat,Tumble,Pose,Pull,Pain,Float,DeepBreath,Nod,Sit,LookUp,Sink,Trip,Laying,LeapForth,Head,Cringe,LostBalance,TumbleBack,Faint,HitGround
```

AltColor shiny Bulbasaur (`sprite/0001/0001/credits.txt`) shows revision history with `OLD`/`CUR` and `PMDCollab_1` / artist Discord IDs.

`OLD` lines are ignored when compiling current credits (`getCreditEntries` skips `old == "OLD"`).

### `spritebot_credits.txt`

Large compiled pack (~1MB). Header:

```
All custom graphics not originating from official PMD games are licensed under Attribution-NonCommercial 4.0 International http://creativecommons.org/licenses/by-nc/4.0/.
All graphics referred to in this file can be found in http://sprites.pmdcollab.org/
```

Then per-artist blocks listing Portrait/Sprite contributions by species+form+emotion/anim names.

### `tracker.json`

Per-species metadata including `sprite_credit` / `portrait_credit`:

```json
{ "primary": "CHUNSOFT", "secondary": ["<@!...>"], "total": N }
```

Also completion phases, file presence maps, Discord CDN links, bounties, pending submissions.

---

## 3. Directory structure

Repo root:

```
LICENSE.md
README.md
credit_names.txt
license_history/
portrait/          # 4-digit species folders 0000…
sprite/            # 4-digit species folders 0000…
sprite_config.json
spritebot_credits.txt
tracker.json
```

**No** `portrait_names.txt`. Emotion names live in `sprite_config.json` → `emotions`.

Per species:

```
sprite/NNNN/
  AnimData.xml
  credits.txt
  <Anim>-Anim.png
  <Anim>-Offsets.png
  <Anim>-Shadow.png
  FFFF/                    # form subgroup
    ...
    SSSS/                  # shiny subgroup
      ...
      GGGG/                # gender subgroup
portrait/NNNN/
  credits.txt
  <Emotion>.png
  <Emotion>^.png           # optional flipped
  FFFF/...                 # same subgroup nesting
```

Default (non-shiny, default gender) assets for the base form usually live **directly** under `sprite/NNNN/` and `portrait/NNNN/`, not under `0000/`.

---

## 4. Species ID naming

**Four-digit zero-padded National Dex IDs**, not names:

| Path | Species |
|------|---------|
| `0000` | Missingno_ |
| `0001` | Bulbasaur |
| `0025` | Pikachu |
| `0095` | Onix |

Names come from `tracker.json` (`"name": "Bulbasaur"`) and SpriteBot commands (`!sprite Pikachu`), **not** from folder names. There is no `Bulbasaur/` directory.

---

## 5. Forms, gender, shiny structure

Encoded as nested **4-digit subgroup directories**. SpriteBot `fileSystemToJson` tier rules:

| Depth | Index meaning |
|-------|----------------|
| Species | `NNNN` dex |
| Tier 1 (form) | `0000` = default (empty name); other ids = named forms (`Altcolor`, `Mega`, `Libre`, …) from tracker |
| Tier 2 (shiny) | `0001` = **Shiny**; `0000` = non-shiny placeholder when gender nesting needed |
| Tier 3 (gender) | `0001` = Male; `0002` = Female |

`isShinyIdx`: shiny iff `full_idx[2] == "0001"`.

Examples:

| Path | Meaning |
|------|---------|
| `sprite/0001/` | Bulbasaur default |
| `sprite/0001/0000/0001/` | Bulbasaur Shiny |
| `sprite/0001/0001/` | Bulbasaur Altcolor |
| `sprite/0025/0006/` | Pikachu Libre |
| `sprite/0025/0000/0000/0002/` | Pikachu Female |
| `sprite/0025/0000/0001/0002/` | Pikachu Shiny Female |
| `portrait/0025/0006/` | Libre portraits (many `Emotion^.png`) |

---

## 6. Animation XML schema (`AnimData.xml`)

Root:

```xml
<AnimData>
  <ShadowSize>0|1|2</ShadowSize>
  <Anims>
    <Anim>...</Anim>
  </Anims>
</AnimData>
```

Per `<Anim>` (non-copy):

| Tag | Role |
|-----|------|
| `Name` | Action name (must match PNG basename prefix) |
| `Index` | Optional SkyTemple/ROM index (unique when set) |
| `FrameWidth` / `FrameHeight` | Pixel size of one cell (even numbers) |
| `Durations` / `Duration` | One integer per frame; units = 1/60s frames |
| `RushFrame` / `HitFrame` / `ReturnFrame` | Optional attack timing indices |
| `CopyOf` | Alias another anim (no PNGs for the copy) |

**Directions are not listed in XML.** Direction count is inferred from sheet height ÷ `FrameHeight` (must be 1 or 8).

Full Bulbasaur XML saved as `third_party/SpriteCollab-0001-AnimData.xml`.

---

## 7. Animation names

Canonical list from `sprite_config.json` → `actions` (also `dungeon_actions`, `starter_actions`).

Common overworld / dungeon set includes: `Idle`, `Walk`, `Sleep`, `Hurt`, `Attack`, `Charge`, `Shoot`, `Strike`, … plus many combat/special names.

Starter/partner extras (seen on Bulbasaur/Pikachu/Squirtle): `EventSleep`, `Wake`, `Eat`, `Tumble`, `Pose`, `Pull`, `Pain`, `Float`, `DeepBreath`, `Nod`, `Sit`, `LookUp`, `Sink`, `Trip`, `Laying`, `LeapForth`, `Head`, `Cringe`, `LostBalance`, `TumbleBack`, `Faint`, `HitGround`.

**There is no `Swim` action** in `sprite_config.json` actions list, and **zero `Swim` keys** anywhere in `tracker.json`.

---

## 8. Frame dimensions and frame counts

Per-anim; **not** global. Frame count = number of `<Duration>` entries = sheet width ÷ `FrameWidth`.

### Bulbasaur `0001` (ShadowSize=1)

| Anim | Size | Frames | Notes |
|------|------|--------|-------|
| Walk | 40×40 | 6 | 8 dirs → sheet 240×320 |
| Idle | 32×40 | 3 | 8 dirs → 96×320 |
| Attack | 64×72 | 11 | Rush/Hit/Return |
| Sleep | 24×24 | 2 | **1 dir** → 48×24 |
| EventSleep | 24×24 | 2 | **8 dirs** → 48×192 |
| Float | 24×24 | 4 | 8 dirs |
| Sink | 24×32 | 12 | **1 dir** → 288×32 |
| Hurt | 40×56 | 2 | 8 dirs |

### Pikachu `0025` (ShadowSize=1)

Walk 32×40×4; Idle 40×56×6; Attack 80×80×10; plus `QuickStrike`, `Shock`; full starter set.

### Onix `0095` (ShadowSize=2)

Walk 88×112×4; Idle 96×104×4; Attack 128×152×11; dungeon set only (no starter anims). `Slam`→CopyOf Attack; `Twirl`→CopyOf Rotate.

---

## 9. Direction ordering (CRITICAL — not guessed)

**Not present in `AnimData.xml`.** Authoritative order from SpriteBot `Constants.DIRECTIONS`, used when iterating `dir in range(total_dirs)` top→bottom:

```python
DIRECTIONS = [
  "Down",        # row 0  (South)
  "DownRight",   # row 1  (SE)
  "Right",       # row 2  (East)
  "UpRight",     # row 3  (NE)
  "Up",          # row 4  (North)
  "UpLeft",      # row 5  (NW)
  "Left",        # row 6  (West)
  "DownLeft",    # row 7  (SW)
]
```

Sheet layout (wiki + SpriteBot):
- **X axis:** frames left → right (sequence)
- **Y axis:** directions top → bottom (order above)
- Sheet must be **1 or 8** directions (`SpriteUtils` enforces this)

Cell at `(frame j, direction d)`:
`tile_rect = (j * FrameWidth, d * FrameHeight, FrameWidth, FrameHeight)`

---

## 10. Offsets / anchors / shadow metadata

Each non-`CopyOf` anim has three same-sized PNGs:

| File | Content |
|------|---------|
| `<Name>-Anim.png` | Visible pixels |
| `<Name>-Offsets.png` | Body-part markers |
| `<Name>-Shadow.png` | Shadow placement / size |

### Offsets.png (RGB markers on transparent)

From wiki + measured Bulbasaur Walk frame0:

| Color | Meaning |
|-------|---------|
| Green `(0,255,0)` | Body center |
| Red `(255,0,0)` | Left hand (entity’s left) |
| Blue `(0,0,255)` | Right hand |
| Black `(0,0,0)` | Head (status icons); defaults to center if missing |

Overlapping markers combine channels.

### Shadow.png

| Color | Meaning |
|-------|---------|
| White | Shadow center / cast point |
| Green component | Small shadow area |
| Red component | Normal shadow area |
| Blue component | Large shadow area |

`AnimData.xml` `<ShadowSize>` selects which shadow size class to prefer (Bulbasaur/Pikachu=`1`, Onix=`2`).

---

## 11. Portraits

Confirmed by `sprite_config.json` and README:

- **Size:** 40×40 PNG (`portrait_size: 40`)
- **Sheet packing (bot templates):** `portrait_tile_x: 5`, `portrait_tile_y: 8` → 200×320 sheet
- **On disk in repo:** one file per emotion: `Normal.png`, `Happy.png`, …
- **Flipped:** `Normal^.png` etc. (`^` = horizontal flip companion; SpriteBot treats as “mirrored emotions”)

### Emotion names (`sprite_config.json` → `emotions`)

```
Normal, Happy, Pain, Angry, Worried, Sad, Crying, Shouting,
Teary-Eyed, Determined, Joyous, Inspired, Surprised, Dizzy,
Special0, Special1, Sigh, Stunned, Special2, Special3
```

**No `portrait_names.txt`** in the repository. Mapping is this JSON array (index used for completion / sheet tiles).

Completion emotion sets: `completion_emotions` in the same JSON.

---

## 12. Swimming animations for Gen 1–2?

**No.** Exhaustive scan of `tracker.json`: **0** occurrences of action `Swim` for any species.

Water-adjacent actions that **do** exist for many Gen1 starters: `Float`, `Sink` (and normal `Walk` / `Idle`). Aquatic species (e.g. Gyarados, Lapras, Tentacool) typically use standard `Walk` (and sometimes form-specific anims), not Swim.

---

## 13. Credit metadata format (summary)

| Artifact | Format |
|----------|--------|
| `credits.txt` | `datetime\tauthor\tCUR\|OLD\tlicense\tasset,list` |
| `credit_names.txt` | `Name\tDiscord\tContact` |
| `tracker.json` credits | `{primary, secondary[], total}` |
| `spritebot_credits.txt` | Human-readable compiled attribution |
| License tokens | `CC_BY-NC_4`, `PMDCollab_1`, `PMDCollab_2`, `Unspecified` |

---

## 14. Sample file listings

### `#001` Bulbasaur

**`sprite/0001/`** (default): `AnimData.xml`, `credits.txt`, and for each anim the triad `*-Anim/Offsets/Shadow.png` for:

Walk, Attack, Charge, Cringe, DeepBreath, Double, Eat, EventSleep, Faint, Float, Head, HitGround, Hop, Hurt, Idle, Laying, LeapForth, LookUp, LostBalance, Nod, Pain, Pose, Pull, Rotate, Shake, Shoot, Sink, Sit, Sleep, Swing, Trip, Tumble, TumbleBack, Wake  

Plus form dirs: `0000/` (→ shiny `0001/`), `0001/` (Altcolor).

**`portrait/0001/`:**  
Angry, Crying, Determined, Dizzy, Happy, Inspired, Joyous, Normal, Pain, Sad, Shouting, Sigh, Special1, Stunned, Surprised, Teary-Eyed, Worried, `credits.txt`, plus `0000/`, `0001/` (Altcolor shiny portraits).

### `#025` Pikachu

**`sprite/0025/`:** full starter+dungeon set including **QuickStrike**, **Shock** (no Strike/Shake); form dirs `0000`, `0006` (Libre), `0007` (Cosplay). Female under `0000/0000/0002` and shiny female `0000/0001/0002`.

**`portrait/0025/`:** same emotion set as Bulbasaur plus **Special2**; many form dirs `0001`–`0015` (Gigantamax, cosplay, caps, …). Libre has full flipped `^.png` set.

### `#095` Onix

**`sprite/0095/`:** AnimData + dungeon anims only: Attack, Charge, Double, Hop, Hurt, Idle, Rotate, Shoot, Sleep, Swing, Walk (+ CopyOf Slam/Twirl); forms `0000` (shiny), `0001` (Altcolor). ShadowSize **2**.

**`portrait/0095/`:** `Normal.png`, `Surprised.png`, `credits.txt`, forms `0000`, `0001`.

---

## Practical integration notes

1. **License:** Fan content = CC BY-NC 4.0 → incompatible with commercial redistribution without separate permission; attribution required.
2. **Loader:** Parse `AnimData.xml` + load three PNGs per anim; slice by `FrameWidth`/`FrameHeight`; apply `DIRECTIONS` row order.
3. **Index species by `NNNN`**, resolve names via `tracker.json`.
4. **Prefer `Idle`/`Walk`/`Hurt`/`Sleep`** for overworld; use `Float`/`Sink` only where present (starters).
5. **Do not expect Swim.**
6. **Portraits:** 40×40 emotion PNGs; optional `^` flips.
7. **Credits:** ship `credits.txt` authors resolved through `credit_names.txt`, plus license notice + link to https://sprites.pmdcollab.org/ / repo.
