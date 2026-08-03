#!/usr/bin/env python3
"""Build Gen1Recomp-compatible 16×96 SpriteRenderer sheets from follow-sprites.

Verified SpriteRenderer frame tables (src/render/SpriteRenderer.lua):

  STAND = { down = 0, up = 1, left = 2, right = 2 }
  WALK  = { down = 3, up = 4, left = 5, right = 5 }

Right-facing uses the left frames with a horizontal mirror in the engine.
Walk column 1 of each follow-sprite direction row is used as the single
native walk frame (column 0 matches idle; columns 1/3 are the step pair).

Output:
  assets/generated/followsprites_runtime/{dex:03d}-normal.png
  assets/generated/followsprites_runtime/{dex:03d}-shiny.png
  assets/generated/followsprites_runtime/manifest.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MAPPING = ROOT / "assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json"
OUT_DIR = ROOT / "assets/generated/followsprites_runtime"

# SpriteRenderer STAND / WALK order (verified against Gen1Recomp).
FRAME_SPECS = (
    ("idle", "down"),   # 0
    ("idle", "up"),     # 1
    ("idle", "left"),   # 2
    ("walk", "down"),   # 3
    ("walk", "up"),     # 4
    ("walk", "left"),   # 5
)

CARD = 16
SHEET_W = 16
SHEET_H = 96  # 6 × 16


def visible_bounds(im: Image.Image) -> tuple[int, int, int, int] | None:
    """Return (left, top, right, bottom) exclusive of fully transparent padding."""
    if im.mode != "RGBA":
        im = im.convert("RGBA")
    alpha = im.getchannel("A")
    bbox = alpha.getbbox()
    return bbox


def crop_tile(src: Image.Image, col: int, row: int, tw: int, th: int) -> Image.Image:
    x0 = col * tw
    y0 = row * th
    return src.crop((x0, y0, x0 + tw, y0 + th)).convert("RGBA")


def fit_to_card(tile: Image.Image, scale: float) -> Image.Image:
    """Nearest-neighbor scale + bottom-center paste into a 16×16 transparent card."""
    card = Image.new("RGBA", (CARD, CARD), (0, 0, 0, 0))
    bbox = visible_bounds(tile)
    if bbox is None:
        return card
    l, t, r, b = bbox
    content = tile.crop((l, t, r, b))
    nw = max(1, int(round(content.width * scale)))
    nh = max(1, int(round(content.height * scale)))
    nw = min(nw, CARD)
    nh = min(nh, CARD)
    scaled = content.resize((nw, nh), Image.Resampling.NEAREST)
    x = (CARD - nw) // 2
    y = CARD - nh  # feet on bottom edge
    card.paste(scaled, (x, y), scaled)
    return card


def common_scale(tiles: list[Image.Image]) -> float:
    """One scale for all frames of a species so size does not jitter."""
    max_w = 0
    max_h = 0
    for tile in tiles:
        bbox = visible_bounds(tile)
        if bbox is None:
            continue
        l, t, r, b = bbox
        max_w = max(max_w, r - l)
        max_h = max(max_h, b - t)
    if max_w <= 0 or max_h <= 0:
        return 1.0
    return min(CARD / max_w, CARD / max_h, 1.0)


def walk_col(layout: dict) -> int:
    cols = layout.get("walkColumns") or [0, 1, 2, 3]
    if len(cols) >= 2:
        return int(cols[1])  # first distinct step pose
    return int(cols[0]) if cols else 1


def idle_col(layout: dict) -> int:
    return int(layout.get("idleColumn", 0))


def direction_row(layout: dict, direction: str) -> int:
    dirs = layout.get("directions") or {
        "down": 0, "left": 1, "right": 2, "up": 3,
    }
    return int(dirs[direction])


def extract_source_tiles(src: Image.Image, layout: dict, tw: int, th: int) -> list[Image.Image]:
    tiles: list[Image.Image] = []
    ic = idle_col(layout)
    wc = walk_col(layout)
    for anim, direction in FRAME_SPECS:
        row = direction_row(layout, direction)
        col = ic if anim == "idle" else wc
        tiles.append(crop_tile(src, col, row, tw, th))
    return tiles


def build_sheet(src_path: Path, layout: dict, tw: int, th: int) -> Image.Image:
    src = Image.open(src_path).convert("RGBA")
    if tw <= 0 or th <= 0:
        tw = src.width // int(layout.get("columns", 4))
        th = src.height // int(layout.get("rows", 4))
    tiles = extract_source_tiles(src, layout, tw, th)
    scale = common_scale(tiles)
    sheet = Image.new("RGBA", (SHEET_W, SHEET_H), (0, 0, 0, 0))
    for i, tile in enumerate(tiles):
        card = fit_to_card(tile, scale)
        sheet.paste(card, (0, i * CARD), card)
    return sheet


def variant_meta(entry: dict, variant: str) -> dict | None:
    block = entry.get(variant)
    if not isinstance(block, dict):
        return None
    rel = block.get("path") or (
        f"assets/enhanced_overworld/followsprites/{block.get('file')}"
        if block.get("file") else None
    )
    if not rel:
        return None
    return {
        "path": rel,
        "file": block.get("file"),
        "tileWidth": int(block.get("tileWidth") or 0),
        "tileHeight": int(block.get("tileHeight") or 0),
        "form": block.get("form"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mapping", type=Path, default=MAPPING)
    parser.add_argument("--out", type=Path, default=OUT_DIR)
    parser.add_argument("--max-species", type=int, default=0,
                        help="If >0, only generate speciesId <= this (0 = all)")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    if not args.mapping.is_file():
        print(f"error: mapping missing: {args.mapping}", file=sys.stderr)
        return 1

    data = json.loads(args.mapping.read_text(encoding="utf-8"))
    layout = data.get("layout") or {}
    species = data.get("species") or {}
    args.out.mkdir(parents=True, exist_ok=True)

    manifest = {
        "schemaVersion": 1,
        "format": "gen1recomp-sprite-renderer-sheet",
        "sheetWidth": SHEET_W,
        "sheetHeight": SHEET_H,
        "frameWidth": CARD,
        "frameHeight": CARD,
        "frames": 6,
        "walker": True,
        "frameOrder": [
            "idle_down", "idle_up", "idle_left",
            "walk_down", "walk_up", "walk_left",
        ],
        "rightFacing": "mirror_left",
        "rightFacingNote": (
            "Follow-sprite right frames can be artistically distinct from "
            "mirrored left. The native SpriteRenderer / Dramatic Shape path "
            "mirrors left for right (trainer contract). Flat 2D may still "
            "use dedicated right quads from the source atlas optionally."
        ),
        "walkSourceColumn": walk_col(layout),
        "idleSourceColumn": idle_col(layout),
        "scale": "visible-bounds fit, nearest-neighbor, bottom-center, shared per species",
        "sheets": {},
    }

    written = 0
    skipped = 0
    errors = 0

    for key in sorted(species.keys(), key=lambda k: int(k)):
        sid = int(key)
        if args.max_species and sid > args.max_species:
            continue
        entry = species[key]
        for variant in ("normal", "shiny"):
            meta = variant_meta(entry, variant)
            if not meta:
                continue
            src_path = ROOT / meta["path"]
            out_name = f"{sid:03d}-{variant}.png"
            out_path = args.out / out_name
            rel_out = f"assets/generated/followsprites_runtime/{out_name}"
            if out_path.is_file() and not args.force:
                skipped += 1
                manifest["sheets"][f"{sid}:{variant}"] = {
                    "speciesId": sid,
                    "variant": variant,
                    "path": rel_out,
                    "source": meta["path"],
                    "form": meta.get("form"),
                    "status": "cached",
                }
                continue
            if not src_path.is_file():
                print(f"warn: missing source {src_path}", file=sys.stderr)
                errors += 1
                continue
            try:
                sheet = build_sheet(
                    src_path, layout, meta["tileWidth"], meta["tileHeight"])
                assert sheet.size == (SHEET_W, SHEET_H), sheet.size
                sheet.save(out_path, optimize=True)
                written += 1
                manifest["sheets"][f"{sid}:{variant}"] = {
                    "speciesId": sid,
                    "variant": variant,
                    "path": rel_out,
                    "source": meta["path"],
                    "form": meta.get("form"),
                    "status": "written",
                    "width": SHEET_W,
                    "height": SHEET_H,
                }
            except Exception as exc:  # noqa: BLE001
                print(f"error: {sid} {variant}: {exc}", file=sys.stderr)
                errors += 1

    man_path = args.out / "manifest.json"
    man_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        f"runtime sheets: written={written} cached={skipped} errors={errors} "
        f"out={args.out}"
    )
    return 0 if errors == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
