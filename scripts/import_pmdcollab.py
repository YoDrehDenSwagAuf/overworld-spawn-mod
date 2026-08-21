#!/usr/bin/env python3
"""Import PMDCollab/SpriteCollab assets into Wilds runtime packs.

Developer supplies a local SpriteCollab checkout. This script NEVER clones or
downloads at runtime — Wilds ships only the derived assets under
assets/pmdcollab/.

Usage:
  python3 scripts/import_pmdcollab.py /path/to/SpriteCollab
  python3 scripts/import_pmdcollab.py ../SpriteCollab --dex-max 251

Output:
  assets/pmdcollab/sprites/{dex:03d}-{normal|shiny}.png
  assets/pmdcollab/portraits/{dex:03d}/{emotion}.png
  assets/pmdcollab/sprite_table.lua
  assets/pmdcollab/portrait_table.lua
  assets/pmdcollab/SOURCE.json
  assets/pmdcollab/LICENSE.txt
  assets/pmdcollab/CREDITS.txt
  THIRD_PARTY_ASSETS.md (repo root, updated section)

Walk sheet layout (Gen1Recomp SpriteRenderer walker contract):
  frames 0..2  STAND down / up / left
  frames 3..5  WALK  down / up / left
  frames 6+    IDLE blocks: down, up, left, right (each idleFrameCount)

Direction rows in upstream Walk/Idle-Anim.png (SpriteBot Constants.DIRECTIONS):
  0 Down, 1 DownRight, 2 Right, 3 UpRight, 4 Up, 5 UpLeft, 6 Left, 7 DownLeft
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image

IMPORTER_VERSION = "2"
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "pmdcollab"

# Cardinals Wilds needs, mapped to SpriteCollab sheet row indices.
DIR_ROWS = {
    "down": 0,
    "right": 2,
    "up": 4,
    "left": 6,
}
WALKER_DIRS = ("down", "up", "left")  # right = mirrored left in engine
IDLE_DIRS = ("down", "up", "left", "right")

# Safe generic dialogue emotions (never Pain/Sad/Crying/Dizzy/etc.).
SAFE_EMOTIONS = (
    "Normal",
    "Happy",
    "Joyous",
    "Inspired",
    "Determined",
)
# Filename slug for runtime (lowercase, no spaces).
EMOTION_SLUG = {
    "Normal": "normal",
    "Happy": "happy",
    "Joyous": "joyous",
    "Inspired": "inspired",
    "Determined": "determined",
}

GENERIC_POOL = ("happy", "joyous", "inspired", "determined", "normal")


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def verify_source(src: Path) -> None:
    if not src.is_dir():
        fail(f"SpriteCollab path not found: {src}")
    for req in ("LICENSE.md", "sprite", "portrait", "sprite_config.json"):
        if not (src / req).exists():
            fail(
                f"Not a SpriteCollab checkout (missing {req}). "
                f"Pass the path to a local clone of "
                f"https://github.com/PMDCollab/SpriteCollab"
            )


def git_sha(src: Path) -> str | None:
    """HEAD of SpriteCollab checkout only (not a parent unrelated repo)."""
    try:
        top = subprocess.check_output(
            ["git", "-C", str(src), "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if not top:
            return None
        # Fixture folders nested in Wilds must not report Wilds' SHA.
        if not (Path(top) / "sprite").is_dir() or not (Path(top) / "portrait").is_dir():
            return None
        out = subprocess.check_output(
            ["git", "-C", str(src), "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        return out or None
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return None

        top = subprocess.check_output(
            ["git", "-C", str(src), "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        # Accept when checkout root matches src (or src is inside that repo).
        if Path(top).resolve() != src.resolve() and src.resolve() != Path(top).resolve():
            # Still OK if src is the sparse checkout root of SpriteCollab.
            if not (src / ".git").exists() and not (Path(top) / "sprite").is_dir():
                return None
        out = subprocess.check_output(
            ["git", "-C", str(src), "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        return out or None
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return None


def parse_anim_data(path: Path) -> dict[str, dict]:
    """Return {name: {frameWidth, frameHeight, durations, copyOf}}."""
    tree = ET.parse(path)
    root = tree.getroot()
    anims: dict[str, dict] = {}
    for anim in root.findall("Anims/Anim"):
        name = (anim.findtext("Name") or "").strip()
        if not name:
            continue
        copy_of = anim.findtext("CopyOf")
        if copy_of:
            anims[name] = {"copyOf": copy_of.strip()}
            continue
        durs = [int(d.text or 0) for d in anim.findall("Durations/Duration")]
        anims[name] = {
            "frameWidth": int(anim.findtext("FrameWidth") or 0),
            "frameHeight": int(anim.findtext("FrameHeight") or 0),
            "durations": durs,
            "shadowSize": int(root.findtext("ShadowSize") or 1),
        }
    # Resolve CopyOf (one level is enough for Idle/Walk).
    for name, meta in list(anims.items()):
        if "copyOf" in meta:
            src = anims.get(meta["copyOf"])
            if src and "copyOf" not in src:
                anims[name] = dict(src)
                anims[name]["copyOf"] = meta["copyOf"]
    return anims


def find_marker(cell: Image.Image, pred) -> tuple[float, float] | None:
    """Return first matching opaque marker pixel (integer coords as floats)."""
    w, h = cell.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = cell.getpixel((x, y))
            if a > 200 and pred(r, g, b):
                return float(x), float(y)
    return None


def offset_body_center(offsets: Image.Image, fw: int, fh: int, col: int, row: int) -> tuple[float, float]:
    """Offsets.png (PMD Sprite Format): green = body center, black = head,
    red/blue = hands. Returns body-center (green), else frame center."""
    x0, y0 = col * fw, row * fh
    cell = offsets.crop((x0, y0, x0 + fw, y0 + fh)).convert("RGBA")
    hit = find_marker(cell, lambda r, g, b: g > 200 and r < 100 and b < 100)
    if hit:
        return hit
    return fw / 2.0, fh / 2.0


def shadow_ground_point(shadow: Image.Image, fw: int, fh: int, col: int, row: int) -> tuple[float, float] | None:
    """Shadow.png: white pixel = shadow center (ground contact under the sprite)."""
    x0, y0 = col * fw, row * fh
    cell = shadow.crop((x0, y0, x0 + fw, y0 + fh)).convert("RGBA")
    return find_marker(cell, lambda r, g, b: r > 200 and g > 200 and b > 200)


def alpha_feet_xy(tile: Image.Image) -> tuple[float, float] | None:
    """Visible feet contact ≈ horizontal center of alpha bbox, bottom pixel.

    PIL getbbox() lower/right edges are exclusive.
    """
    if tile.mode != "RGBA":
        tile = tile.convert("RGBA")
    bbox = tile.getchannel("A").getbbox()
    if not bbox:
        return None
    x0, _y0, x1, y1 = bbox
    return (x0 + x1 - 1) / 2.0, float(y1 - 1)


def extract_frame(sheet: Image.Image, fw: int, fh: int, col: int, row: int) -> Image.Image:
    x0, y0 = col * fw, row * fh
    return sheet.crop((x0, y0, x0 + fw, y0 + fh)).convert("RGBA")


def paste_at_contact(
    dst: Image.Image,
    src: Image.Image,
    ground_y: float,
    contact_x: float,
    contact_y: float,
    body_x: float | None = None,
) -> None:
    """Paste src so (contact_x, contact_y) lands on (canvas_mid, ground_y).

    contact is SpriteCollab Shadow white (preferred) or visible alpha feet.
    Horizontal: prefer Offsets green body-center when provided so asymmetric
    frames do not drift when padding changes.
    """
    dw, _dh = dst.size
    if src.mode != "RGBA":
        src = src.convert("RGBA")
    # Exact integer paste so contact maps onto the ground row without 0.5 drift.
    y = int(round(ground_y)) - int(round(contact_y))
    if body_x is not None:
        x = int(round(dw / 2.0 - body_x))
    else:
        x = int(round(dw / 2.0 - contact_x))
    dst.alpha_composite(src, (x, y))


def walk_mid_col(n_frames: int) -> int:
    if n_frames <= 1:
        return 0
    if n_frames >= 3:
        return min(2, n_frames - 1)
    return 1


def resolve_variant_dir(species_dir: Path, shiny: bool) -> Path | None:
    """Default form: root for normal; 0000/0001 for shiny when present."""
    if not shiny:
        if (species_dir / "Walk-Anim.png").is_file() and (species_dir / "AnimData.xml").is_file():
            return species_dir
        return None
    shiny_dir = species_dir / "0000" / "0001"
    if (shiny_dir / "Walk-Anim.png").is_file() and (shiny_dir / "AnimData.xml").is_file():
        return shiny_dir
    # Some packs put shiny under 0001/ directly (AltColor etc.) — do not use as
    # default shiny; fall back to missing so caller uses normal.
    return None


def frame_contact(
    tile: Image.Image,
    shadow_sheet: Image.Image | None,
    fw: int,
    fh: int,
    col: int,
    row: int,
) -> tuple[float, float, str]:
    """Return (contact_x, contact_y, source) in tile coords.

    Prefer Shadow.png white (PMD ground / shadow center). Fall back to the
    visible alpha feet. Offsets green is body center — not ground.
    """
    if shadow_sheet is not None:
        gp = shadow_ground_point(shadow_sheet, fw, fh, col, row)
        if gp:
            return gp[0], gp[1], "shadow_white"
    feet = alpha_feet_xy(tile)
    if feet:
        return feet[0], feet[1], "alpha_feet"
    return fw / 2.0, float(fh), "frame_bottom"


def build_combined_sheet(
    walk_sheet: Image.Image,
    walk_meta: dict,
    idle_sheet: Image.Image | None,
    idle_meta: dict | None,
    offsets: Image.Image | None,
    shadow: Image.Image | None = None,
    idle_shadow: Image.Image | None = None,
) -> tuple[Image.Image, dict]:
    """Build Gen1Recomp walker sheet with a stable ground anchor.

    SpriteCollab Offsets.png markers (wiki PMD Sprite Format):
      green = body center, black = head, red = left hand, blue = right hand.
    SpriteCollab Shadow.png:
      white = shadow center (intended ground contact under the sprite).

    Gen1Recomp SpriteRenderer maps world stand point through anchorX/anchorY.
    Using canvas_h as anchorY was wrong: frames carry large transparent padding
    below the contact row, so the art floated ~1 tile high. We anchor on the
    Shadow white (or alpha feet) contact row, and place every frame so that
    contact shares the same canvas Y/X (no animation jitter).
    """
    wfw = int(walk_meta["frameWidth"])
    wfh = int(walk_meta["frameHeight"])
    walk_n = len(walk_meta.get("durations") or []) or max(1, walk_sheet.width // max(wfw, 1))

    idle_n = 0
    ifw = wfw
    ifh = wfh
    if idle_sheet is not None and idle_meta and "frameWidth" in idle_meta:
        ifw = int(idle_meta["frameWidth"])
        ifh = int(idle_meta["frameHeight"])
        idle_n = len(idle_meta.get("durations") or []) or max(1, idle_sheet.width // max(ifw, 1))

    mid = walk_mid_col(walk_n)
    # (frame_index, tile, body_x|None, contact_x, contact_y)
    tiles: list[tuple[int, Image.Image, float | None, float, float]] = []

    stand_down = extract_frame(walk_sheet, wfw, wfh, 0, DIR_ROWS["down"])
    _cx0, _cy0, anchor_source = frame_contact(
        stand_down, shadow, wfw, wfh, 0, DIR_ROWS["down"])

    for i, dname in enumerate(WALKER_DIRS):
        row = DIR_ROWS[dname]
        for phase, col, frame_i in ((0, 0, i), (1, mid, i + 3)):
            tile = extract_frame(walk_sheet, wfw, wfh, col, row)
            bx = None
            if offsets is not None:
                bx, _ = offset_body_center(offsets, wfw, wfh, col, row)
            cx, cy, _ = frame_contact(tile, shadow, wfw, wfh, col, row)
            tiles.append((frame_i, tile, bx, cx, cy))

    idle_durations: list[int] = []
    if idle_n > 0 and idle_sheet is not None and idle_meta:
        idle_durations = list(idle_meta.get("durations") or [4] * idle_n)
        base = 6
        for di, dname in enumerate(IDLE_DIRS):
            row = DIR_ROWS[dname]
            for fi in range(idle_n):
                tile = extract_frame(idle_sheet, ifw, ifh, fi, row)
                cx, cy, _ = frame_contact(tile, idle_shadow, ifw, ifh, fi, row)
                tiles.append((base + di * idle_n + fi, tile, None, cx, cy))

    # Canvas: room above/below the shared contact row for all frames.
    max_above = 0.0
    max_below = 2.0
    max_half_w = 0
    for _fi, tile, _bx, _cx, cy in tiles:
        bbox = tile.getchannel("A").getbbox()
        if not bbox:
            continue
        above = cy - bbox[1]
        below = max(tile.size[1] - cy, bbox[3] - cy)
        if above > max_above:
            max_above = above
        if below > max_below:
            max_below = below
        vis_w = bbox[2] - bbox[0]
        if vis_w // 2 + 2 > max_half_w:
            max_half_w = vis_w // 2 + 2

    pad = 2
    canvas_w = max(wfw, ifw, max_half_w * 2 + pad * 2)
    ground_y = float(pad + int(math.ceil(max_above)))
    canvas_h = int(math.ceil(ground_y + max_below + pad))
    if canvas_h < 1:
        canvas_h = max(wfh, ifh)
    if canvas_w < 1:
        canvas_w = max(wfw, ifw)

    total_frames = 6 + (idle_n * len(IDLE_DIRS) if idle_n > 0 else 0)
    # Gen1Recomp walker sheets are vertical strips (see docs/ARCHITECTURE.md).
    out = Image.new("RGBA", (canvas_w, canvas_h * total_frames), (0, 0, 0, 0))

    for frame_i, tile, bx, cx, cy in tiles:
        cell = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
        paste_at_contact(cell, tile, ground_y, cx, cy, body_x=bx)
        out.paste(cell, (0, frame_i * canvas_h))

    # World anchor = shared contact in canvas space (body/contact → mid X).
    anchor_x = canvas_w / 2.0
    anchor_y = ground_y

    meta = {
        "frameWidth": canvas_w,
        "frameHeight": canvas_h,
        "frames": total_frames,
        "walkerFrames": 6,
        "idleFrameCount": idle_n,
        "idleDurations": idle_durations,
        "idleDirections": list(IDLE_DIRS),
        "anchorX": round(anchor_x, 2),
        "anchorY": round(anchor_y, 2),
        "sourceWalkFrameWidth": wfw,
        "sourceWalkFrameHeight": wfh,
        "sourceIdleFrameWidth": ifw if idle_n else None,
        "sourceIdleFrameHeight": ifh if idle_n else None,
        "sourceGroundY": round(float(_cy0), 2),
        "walkFrameCount": walk_n,
        "walkMidColumn": mid,
        "anchorSource": anchor_source,
    }
    return out, meta


def read_credits_authors(credits_path: Path, wanted: set[str]) -> list[str]:
    """Return unique CUR author ids for matching asset names."""
    if not credits_path.is_file():
        return []
    authors: list[str] = []
    seen: set[str] = set()
    for line in credits_path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        _dt, author, status, _lic, assets = parts[0], parts[1], parts[2], parts[3], parts[4]
        if status.strip().upper() == "OLD":
            continue
        asset_names = {a.strip() for a in assets.split(",") if a.strip()}
        if wanted and asset_names.isdisjoint(wanted):
            continue
        a = author.strip()
        if a and a not in seen:
            seen.add(a)
            authors.append(a)
    return authors


def load_credit_names(src: Path) -> dict[str, tuple[str, str]]:
    """author_id -> (display_name, contact)."""
    path = src / "credit_names.txt"
    out: dict[str, tuple[str, str]] = {}
    if not path.is_file():
        return out
    for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines()):
        if i == 0 and line.startswith("Name"):
            continue
        parts = line.split("\t")
        if len(parts) < 1:
            continue
        name = parts[0].strip()
        discord = parts[1].strip() if len(parts) > 1 else ""
        contact = parts[2].strip() if len(parts) > 2 else ""
        if name:
            out[name] = (name, contact)
        if discord:
            out[discord] = (name or discord, contact)
    return out


def lua_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def write_sprite_table(path: Path, species: dict[int, dict], source_sha: str | None) -> None:
    lines = [
        "-- AUTO-GENERATED by scripts/import_pmdcollab.py — do not hand-edit.",
        f"-- Importer version {IMPORTER_VERSION}. Source SHA: {source_sha or 'unknown'}",
        "return {",
    ]
    for dex in sorted(species):
        entry = species[dex]
        lines.append(f"  [{dex}]={{")
        for variant in ("normal", "shiny"):
            v = entry.get(variant)
            if not v:
                continue
            durs = ",".join(str(int(x)) for x in (v.get("idleDurations") or []))
            lines.append(
                f'    {variant}={{rel="{lua_escape(v["rel"])}",'
                f'frameWidth={v["frameWidth"]},frameHeight={v["frameHeight"]},'
                f'frames={v["frames"]},walkerFrames=6,'
                f'idleFrameCount={v["idleFrameCount"]},'
                f'idleDurations={{{durs}}},'
                f'anchorX={v["anchorX"]},anchorY={v["anchorY"]},'
                f'sourcePath="{lua_escape(v.get("sourcePath") or "")}"}},'
            )
        lines.append("  },")
    lines.append("}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_portrait_table(path: Path, portraits: dict[int, dict], source_sha: str | None) -> None:
    lines = [
        "-- AUTO-GENERATED by scripts/import_pmdcollab.py — do not hand-edit.",
        f"-- Importer version {IMPORTER_VERSION}. Source SHA: {source_sha or 'unknown'}",
        "return {",
    ]
    for dex in sorted(portraits):
        entry = portraits[dex]
        lines.append(f"  [{dex}]={{")
        for variant in ("normal", "shiny"):
            v = entry.get(variant)
            if not v:
                continue
            emo_parts = []
            for slug, rel in sorted(v["emotions"].items()):
                emo_parts.append(f'{slug}="{lua_escape(rel)}"')
            lines.append(
                f'    {variant}={{emotions={{{",".join(emo_parts)}}},'
                f'sourcePath="{lua_escape(v.get("sourcePath") or "")}"}},'
            )
        lines.append("  },")
    lines.append("}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def save_png(im: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, format="PNG", optimize=True)


def import_species(
    src: Path,
    dex: int,
    credit_names: dict[str, tuple[str, str]],
    credit_acc: dict[str, set[str]],
) -> tuple[dict | None, dict | None]:
    folder = f"{dex:04d}"
    species_dir = src / "sprite" / folder
    portrait_dir = src / "portrait" / folder
    sprite_out: dict = {}
    portrait_out: dict = {}

    for shiny in (False, True):
        variant = "shiny" if shiny else "normal"
        vdir = resolve_variant_dir(species_dir, shiny)
        if vdir is None:
            continue
        anims = parse_anim_data(vdir / "AnimData.xml")
        walk_meta = anims.get("Walk")
        if not walk_meta or "frameWidth" not in walk_meta:
            continue
        walk_path = vdir / "Walk-Anim.png"
        if not walk_path.is_file():
            continue
        walk_im = Image.open(walk_path)
        idle_im = None
        idle_meta = anims.get("Idle")
        idle_path = vdir / "Idle-Anim.png"
        if idle_path.is_file() and idle_meta and "frameWidth" in idle_meta:
            idle_im = Image.open(idle_path)
        else:
            idle_meta = None
        offsets = None
        off_path = vdir / "Walk-Offsets.png"
        if off_path.is_file():
            offsets = Image.open(off_path)
        shadow = None
        sh_path = vdir / "Walk-Shadow.png"
        if sh_path.is_file():
            shadow = Image.open(sh_path)
        idle_shadow = None
        if idle_im is not None:
            ish_path = vdir / "Idle-Shadow.png"
            if ish_path.is_file():
                idle_shadow = Image.open(ish_path)

        sheet, meta = build_combined_sheet(
            walk_im, walk_meta, idle_im, idle_meta, offsets, shadow, idle_shadow
        )
        rel = f"assets/pmdcollab/sprites/{dex:03d}-{variant}.png"
        save_png(sheet, ROOT / rel)
        source_rel = str(vdir.relative_to(src)).replace("\\", "/")
        sprite_out[variant] = {
            **meta,
            "rel": rel,
            "sourcePath": source_rel,
            "anims": ["Walk"] + (["Idle"] if meta["idleFrameCount"] > 0 else []),
        }

        wanted = {"Walk", "Idle"}
        for author in read_credits_authors(vdir / "credits.txt", wanted):
            credit_acc[author].add(f"sprite/{folder} {variant}")

    # Portraits: root for normal; 0000/0001 for shiny when present.
    for shiny in (False, True):
        variant = "shiny" if shiny else "normal"
        pdir = portrait_dir / "0000" / "0001" if shiny else portrait_dir
        if not pdir.is_dir():
            continue
        emotions: dict[str, str] = {}
        for emo_name, slug in EMOTION_SLUG.items():
            src_png = pdir / f"{emo_name}.png"
            if not src_png.is_file():
                continue
            im = Image.open(src_png).convert("RGBA")
            if im.size != (40, 40):
                # Upstream standard is 40x40; keep as-is if odd but still ship.
                pass
            rel = f"assets/pmdcollab/portraits/{dex:03d}/{variant}/{slug}.png"
            save_png(im, ROOT / rel)
            emotions[slug] = rel
        if not emotions:
            continue
        # Require at least Normal when present; otherwise keep whatever we got.
        portrait_out[variant] = {
            "emotions": emotions,
            "sourcePath": str(pdir.relative_to(src)).replace("\\", "/"),
        }
        for author in read_credits_authors(pdir / "credits.txt", set(EMOTION_SLUG.keys())):
            credit_acc[author].add(f"portrait/{folder} {variant}")

    return (sprite_out or None), (portrait_out or None)


def write_credits(
    out_path: Path,
    src: Path,
    sha: str | None,
    credit_names: dict[str, tuple[str, str]],
    credit_acc: dict[str, set[str]],
) -> None:
    lines = [
        "PMDCollab / SpriteCollab attribution for Wilds of Kanto derived assets",
        "=" * 72,
        "",
        "Source: https://github.com/PMDCollab/SpriteCollab",
        f"Revision: {sha or 'unknown'}",
        "License: Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)",
        "License URI: https://creativecommons.org/licenses/by-nc/4.0/",
        "Browse: http://sprites.pmdcollab.org/",
        "",
        "Wilds redistributes a Gen1–Gen2 subset of SpriteCollab Walk/Idle overworld",
        "sprites and selected portrait emotions, converted at build time into compact",
        "runtime sheets. Official Chunsoft-origin art may appear with credit id",
        "CHUNSOFT (license field often Unspecified upstream).",
        "",
        "Contributor credits below are taken from upstream credit_names.txt and",
        "per-folder credits.txt (CUR entries only). Author names are not invented.",
        "",
        "Contributors referenced by imported assets:",
        "",
    ]
    for author in sorted(credit_acc.keys(), key=lambda a: a.lower()):
        display, contact = credit_names.get(author, (author, ""))
        lines.append(f"- {display}")
        if author != display:
            lines.append(f"  id: {author}")
        if contact:
            lines.append(f"  contact: {contact}")
        # Cap contribution list length for readability
        contribs = sorted(credit_acc[author])
        if len(contribs) > 12:
            shown = contribs[:12] + [f"... +{len(contribs) - 12} more"]
        else:
            shown = contribs
        lines.append(f"  assets: {', '.join(shown)}")
        lines.append("")
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_third_party_md(sha: str | None) -> None:
    path = ROOT / "THIRD_PARTY_ASSETS.md"
    body = f"""# Third-Party Assets — PMDCollab / SpriteCollab

## Source

- Repository: [PMDCollab/SpriteCollab](https://github.com/PMDCollab/SpriteCollab)
- Browse: http://sprites.pmdcollab.org/
- Imported revision: `{sha or "unknown"}`
- Importer: `scripts/import_pmdcollab.py` (version {IMPORTER_VERSION})

## License

SpriteCollab materials are licensed under **Creative Commons
Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)**.

- Full license text shipped at `assets/pmdcollab/LICENSE.txt`
- Upstream: https://creativecommons.org/licenses/by-nc/4.0/

Non-commercial use only. Attribution required. See upstream LICENSE.md and
README use policy.

Official Chunsoft-origin graphics that appear in SpriteCollab are credited as
`CHUNSOFT` in upstream `credits.txt` (license field often `Unspecified`).

## What Wilds redistributes

Under `assets/pmdcollab/` Wilds ships **derived** Gen1–Gen2 runtime assets only:

- Overworld Walk (+ Idle when available) converted to Gen1Recomp walker sheets
- Selected portrait emotions for Pokémon dialogue (Normal + safe generic pool)
- Generated metadata tables and contributor credits

Wilds does **not** ship the full SpriteCollab repository, XML sources, or
dungeon-only animations.

## Attribution

See `assets/pmdcollab/CREDITS.txt` for contributor credits collected from
upstream `credit_names.txt` and per-folder `credits.txt`.

Also listed in `THIRD_PARTY_NOTICES.md`.
"""
    path.write_text(body, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", type=Path, help="Path to local SpriteCollab checkout")
    ap.add_argument("--dex-min", type=int, default=1)
    ap.add_argument("--dex-max", type=int, default=251)
    ap.add_argument("--clean", action="store_true", help="Remove prior sprites/portraits output")
    args = ap.parse_args()

    src = args.source.resolve()
    verify_source(src)
    sha = git_sha(src)
    credit_names = load_credit_names(src)

    if args.clean and OUT.exists():
        import shutil

        for sub in ("sprites", "portraits"):
            p = OUT / sub
            if p.exists():
                shutil.rmtree(p)

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "sprites").mkdir(exist_ok=True)
    (OUT / "portraits").mkdir(exist_ok=True)

    # License copy (exact upstream text).
    license_src = src / "LICENSE.md"
    (OUT / "LICENSE.txt").write_bytes(license_src.read_bytes())

    species_table: dict[int, dict] = {}
    portrait_table: dict[int, dict] = {}
    credit_acc: dict[str, set[str]] = defaultdict(set)
    missing_walk: list[int] = []
    missing_idle: list[int] = []
    missing_portrait: list[int] = []

    for dex in range(args.dex_min, args.dex_max + 1):
        spr, por = import_species(src, dex, credit_names, credit_acc)
        if not spr or "normal" not in spr:
            missing_walk.append(dex)
        else:
            species_table[dex] = spr
            if spr["normal"].get("idleFrameCount", 0) <= 0:
                missing_idle.append(dex)
        if not por or "normal" not in por:
            missing_portrait.append(dex)
        elif por:
            portrait_table[dex] = por

    write_sprite_table(OUT / "sprite_table.lua", species_table, sha)
    write_portrait_table(OUT / "portrait_table.lua", portrait_table, sha)
    write_credits(OUT / "CREDITS.txt", src, sha, credit_names, credit_acc)
    write_third_party_md(sha)

    source_info = {
        "repository": "https://github.com/PMDCollab/SpriteCollab",
        "commit": sha,
        "importerVersion": IMPORTER_VERSION,
        "dexMin": args.dex_min,
        "dexMax": args.dex_max,
        "safePortraitEmotions": list(EMOTION_SLUG.values()),
        "genericEmotionPool": list(GENERIC_POOL),
        "directionRows": DIR_ROWS,
        "walkerLayout": {
            "0": "stand_down",
            "1": "stand_up",
            "2": "stand_left",
            "3": "walk_down",
            "4": "walk_up",
            "5": "walk_left",
            "6+": "idle blocks: down, up, left, right",
        },
        "waterPolicy": "use_existing_wilds_water_system",
        "speciesImported": len(species_table),
        "portraitsImported": len(portrait_table),
        "missingWalk": missing_walk,
        "missingIdle": missing_idle,
        "missingPortraitNormal": missing_portrait,
    }
    (OUT / "SOURCE.json").write_text(
        json.dumps(source_info, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    # Size report
    sprite_files = list((OUT / "sprites").glob("*.png"))
    portrait_files = list((OUT / "portraits").rglob("*.png"))
    total = sum(p.stat().st_size for p in sprite_files + portrait_files)
    total += sum(
        (OUT / name).stat().st_size
        for name in (
            "sprite_table.lua",
            "portrait_table.lua",
            "SOURCE.json",
            "LICENSE.txt",
            "CREDITS.txt",
        )
        if (OUT / name).is_file()
    )

    print("import_pmdcollab: ok")
    print(f"  source: {src}")
    print(f"  commit: {sha or 'unknown'}")
    print(f"  species with walk: {len(species_table)}")
    print(f"  species with portraits: {len(portrait_table)}")
    print(f"  sprite PNGs: {len(sprite_files)}")
    print(f"  portrait PNGs: {len(portrait_files)}")
    print(f"  total bytes: {total} ({total / 1024 / 1024:.2f} MiB)")
    if missing_walk:
        print(f"  missing Walk: {missing_walk}")
    if missing_idle:
        print(f"  missing Idle (stand-only): {missing_idle}")
    if missing_portrait:
        print(f"  missing portraits: count={len(missing_portrait)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
