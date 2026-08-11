#!/usr/bin/env python3
"""Build ONE Charizard variable-size HGSS prototype sheet for Gen1Recomp #1016.

Uses ORIGINAL assets under assets/enhanced_overworld/followsprites — never the
degraded 16×16 followsprites_runtime output.

Output:
  assets/generated/variable_size_prototype/hgss/006-normal.png  (32×192)
  assets/generated/variable_size_prototype/hgss/006-shiny.png
  assets/generated/variable_size_prototype/hgss/manifest.json

Frame tables match SpriteRenderer STAND/WALK (right = mirror left).
Nearest-neighbor only; shared opaque union; feet on bottom edge.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / "assets/enhanced_overworld/followsprites"
MAPPING = ROOT / "assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json"
OUT_DIR = ROOT / "assets/generated/variable_size_prototype/hgss"

FRAME_SPECS = (
    ("idle", "down"),
    ("idle", "up"),
    ("idle", "left"),
    ("walk", "down"),
    ("walk", "up"),
    ("walk", "left"),
)

DEFAULT_DEX = 6
DEFAULT_FW = 32
DEFAULT_FH = 32


def visible_bounds(im: Image.Image):
    if im.mode != "RGBA":
        im = im.convert("RGBA")
    return im.getchannel("A").getbbox()


def crop_tile(src: Image.Image, col: int, row: int, tw: int, th: int) -> Image.Image:
    return src.crop((col * tw, row * th, (col + 1) * tw, (row + 1) * th)).convert("RGBA")


def content_key(tile: Image.Image) -> bytes:
    bbox = visible_bounds(tile)
    if bbox is None:
        return b""
    return tile.crop(bbox).tobytes()


def pick_walk_column(src, layout, tw, th, direction: str) -> int:
    dirs = layout.get("directions") or {"down": 0, "left": 1, "right": 2, "up": 3}
    idle_col = int(layout.get("idleColumn", 0))
    walk_cols = layout.get("walkColumns") or [0, 1, 2, 3]
    row = int(dirs[direction])
    idle_key = content_key(crop_tile(src, idle_col, row, tw, th))
    for col in walk_cols:
        col = int(col)
        if col == idle_col:
            continue
        if content_key(crop_tile(src, col, row, tw, th)) != idle_key:
            return col
    if len(walk_cols) >= 3:
        return int(walk_cols[2])
    return int(walk_cols[-1])


def extract_tiles(src: Image.Image, layout: dict, tw: int, th: int) -> list[Image.Image]:
    dirs = layout.get("directions") or {"down": 0, "left": 1, "right": 2, "up": 3}
    idle_col = int(layout.get("idleColumn", 0))
    tiles = []
    for anim, direction in FRAME_SPECS:
        row = int(dirs[direction])
        if anim == "idle":
            col = idle_col
        else:
            col = pick_walk_column(src, layout, tw, th, direction)
        tiles.append(crop_tile(src, col, row, tw, th))
    return tiles


def build_sheet(tiles: list[Image.Image], frame_w: int, frame_h: int):
    boxes = [visible_bounds(t) for t in tiles]
    if not any(boxes):
        sheet = Image.new("RGBA", (frame_w, frame_h * len(tiles)), (0, 0, 0, 0))
        return sheet, {"method": "empty", "scale": 1.0, "resized": False}

    ux0 = min(b[0] for b in boxes if b)
    uy0 = min(b[1] for b in boxes if b)
    ux1 = max(b[2] for b in boxes if b)
    uy1 = max(b[3] for b in boxes if b)
    content_w = ux1 - ux0
    content_h = uy1 - uy0
    scale = 1.0
    if content_w > frame_w or content_h > frame_h:
        scale = min(frame_w / content_w, frame_h / content_h)
    resized = scale != 1.0

    sheet = Image.new("RGBA", (frame_w, frame_h * len(tiles)), (0, 0, 0, 0))
    for i, tile in enumerate(tiles):
        cropped = tile.crop((ux0, uy0, ux1, uy1))
        if resized:
            nw = max(1, int(round(content_w * scale)))
            nh = max(1, int(round(content_h * scale)))
            cropped = cropped.resize((nw, nh), Image.NEAREST)
        else:
            nw, nh = cropped.size
        dx = (frame_w - nw) // 2
        dy = frame_h - nh
        frame = Image.new("RGBA", (frame_w, frame_h), (0, 0, 0, 0))
        frame.paste(cropped, (dx, dy), cropped)
        sheet.paste(frame, (0, i * frame_h), frame)

    return sheet, {
        "method": "shared_bbox_nearest_pad" if not resized else "shared_bbox_nearest_scale",
        "scale": scale,
        "resized": resized,
        "contentWidth": content_w,
        "contentHeight": content_h,
        "unionBox": [ux0, uy0, ux1, uy1],
        "sourceFilter": "NEAREST",
    }


def source_paths(dex: int) -> dict[str, Path]:
    # Prefer gender-neutral / male "b" then "f"/"m" variants used by the pack.
    candidates = {
        "normal": [
            SRC_DIR / f"{dex:03d}-b-n.png",
            SRC_DIR / f"{dex:03d}-f-n.png",
            SRC_DIR / f"{dex:03d}-m-n.png",
            SRC_DIR / f"{dex:03d}-n.png",
        ],
        "shiny": [
            SRC_DIR / f"{dex:03d}-b-s.png",
            SRC_DIR / f"{dex:03d}-f-s.png",
            SRC_DIR / f"{dex:03d}-m-s.png",
            SRC_DIR / f"{dex:03d}-s.png",
        ],
    }
    out = {}
    for variant, paths in candidates.items():
        for p in paths:
            if p.exists():
                out[variant] = p
                break
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dex", type=int, default=DEFAULT_DEX)
    ap.add_argument("--frame-width", type=int, default=DEFAULT_FW)
    ap.add_argument("--frame-height", type=int, default=DEFAULT_FH)
    args = ap.parse_args(argv)

    if not MAPPING.exists():
        print("mapping missing:", MAPPING, file=sys.stderr)
        return 1
    mapping = json.loads(MAPPING.read_text())
    layout = mapping.get("layout") or {}

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    paths = source_paths(args.dex)
    if "normal" not in paths:
        print("no source for dex", args.dex, file=sys.stderr)
        return 1

    manifest = {
        "schemaVersion": 1,
        "purpose": "variable_size_prototype",
        "species": {},
        "notes": [
            "Prototype only — do not batch-convert all 151 here.",
            "Source = ORIGINAL followsprites; not followsprites_runtime.",
            "Nearest-neighbor; shared bbox; bottom-center anchor.",
        ],
    }

    for variant, path in paths.items():
        src = Image.open(path).convert("RGBA")
        cols = int((mapping.get("layout") or {}).get("columns") or 4)
        rows = int((mapping.get("layout") or {}).get("rows") or 4)
        tw = src.width // cols
        th = src.height // rows
        tiles = extract_tiles(src, layout, tw, th)
        sheet, meta = build_sheet(tiles, args.frame_width, args.frame_height)
        out_name = f"{args.dex:03d}-{variant}.png"
        out_path = OUT_DIR / out_name
        sheet.save(out_path, optimize=True)
        f0 = sheet.crop((0, 0, args.frame_width, args.frame_height))
        f3 = sheet.crop((0, 3 * args.frame_height, args.frame_width, 4 * args.frame_height))
        distinct = f0.tobytes() != f3.tobytes()
        key = f"{args.dex}:{variant}"
        manifest["species"][key] = {
            "dex": args.dex,
            "variant": variant,
            "path": f"assets/generated/variable_size_prototype/hgss/{out_name}",
            "sourcePath": str(path.relative_to(ROOT)),
            "tileWidth": tw,
            "tileHeight": th,
            "frameWidth": args.frame_width,
            "frameHeight": args.frame_height,
            "anchorX": args.frame_width / 2,
            "anchorY": args.frame_height,
            "frames": 6,
            "walker": True,
            "class": "XL",
            "idleWalkDistinct": distinct,
            "degradedRuntimeUsedAsSource": False,
            **meta,
        }
        print(out_name, sheet.size, "distinct", distinct, meta["method"])

    (OUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("wrote", OUT_DIR / "manifest.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
