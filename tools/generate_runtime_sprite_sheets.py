#!/usr/bin/env python3
"""Build Gen1Recomp-compatible SpriteRenderer sheets from HGSS follow-sprites.

Verified SpriteRenderer frame tables (src/render/SpriteRenderer.lua):

  STAND = { down = 0, up = 1, left = 2, right = 2 }
  WALK  = { down = 3, up = 4, left = 5, right = 5 }

Quads are hard-coded to 16×16 px (`newQuad(0, f * 16, 16, 16, …)`).
Larger native frames are therefore impossible without changing SpriteRenderer,
which this project must not do. Runtime cards remain 16×16.

Source follow-sprites are typically 4×4 grids of 32×32 tiles (128×128 sheets).
Rows = directions (down/left/right/up), columns = animation frames
(idle, idle-bob, walk, walk-bob).

Runtime keeps only the six frames SpriteRenderer needs:
  idle down/up/left, walk down/up/left
(Right is mirrored from left by the engine.)

Quality rules (this rebuild):
  * Nearest-neighbor only — never bilinear/bicubic.
  * Shared opaque bounding box across the six needed frames (stable pivot,
    no per-frame auto-centering → no walk jitter).
  * Max-fit into 16×16: never upscale; skip resize when content already fits.
  * Prefer exact ½ scale when it is essentially the maximum that fits
    (cleaner pixels than awkward ratios like 0.53).
  * Source under assets/enhanced_overworld/followsprites is never modified.

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

FRAME_SPECS = (
    ("idle", "down"),
    ("idle", "up"),
    ("idle", "left"),
    ("walk", "down"),
    ("walk", "up"),
    ("walk", "left"),
)

CARD = 16
SHEET_W = 16
SHEET_H = 96  # 6 × 16


def visible_bounds(im: Image.Image) -> tuple[int, int, int, int] | None:
    if im.mode != "RGBA":
        im = im.convert("RGBA")
    return im.getchannel("A").getbbox()


def crop_tile(src: Image.Image, col: int, row: int, tw: int, th: int) -> Image.Image:
    x0 = col * tw
    y0 = row * th
    return src.crop((x0, y0, x0 + tw, y0 + th)).convert("RGBA")


def idle_col(layout: dict) -> int:
    return int(layout.get("idleColumn", 0))


def walk_col(layout: dict) -> int:
    cols = layout.get("walkColumns") or [0, 1, 2, 3]
    if len(cols) >= 3:
        return int(cols[2])
    if len(cols) >= 2:
        return int(cols[1])
    return int(cols[0]) if cols else 2


def direction_row(layout: dict, direction: str) -> int:
    dirs = layout.get("directions") or {
        "down": 0, "left": 1, "right": 2, "up": 3,
    }
    return int(dirs[direction])


def _visible_content_key(tile: Image.Image) -> bytes:
    bbox = visible_bounds(tile)
    if bbox is None:
        return b""
    return tile.crop(bbox).tobytes()


def pick_walk_column(
    src: Image.Image, layout: dict, tw: int, th: int, direction: str
) -> int:
    cols = layout.get("walkColumns") or [0, 1, 2, 3]
    ic = idle_col(layout)
    row = direction_row(layout, direction)
    idle_key = _visible_content_key(crop_tile(src, ic, row, tw, th))
    for col in cols:
        col = int(col)
        if col == ic:
            continue
        if _visible_content_key(crop_tile(src, col, row, tw, th)) != idle_key:
            return col
    return walk_col(layout)


def extract_source_tiles(src: Image.Image, layout: dict, tw: int, th: int) -> list[Image.Image]:
    tiles: list[Image.Image] = []
    ic = idle_col(layout)
    for anim, direction in FRAME_SPECS:
        row = direction_row(layout, direction)
        if anim == "idle":
            col = ic
        else:
            col = pick_walk_column(src, layout, tw, th, direction)
        tiles.append(crop_tile(src, col, row, tw, th))
    return tiles


def fit_shared_trim(tiles: list[Image.Image]) -> tuple[list[Image.Image], dict]:
    """Shared-scale / shared-pivot nearest fit into CARD×CARD.

    SpriteRenderer quads are hard-coded 16×16, so cards cannot be larger.
    Within that limit we:
      * measure one union opaque bbox across all needed frames
      * pick one max-fit scale (never upscale; skip resize when content fits)
      * crop each frame to its own opaque pixels, scale with that shared scale
      * place every frame relative to the same union pivot (feet on bottom,
        horizontally centered on the union) — no per-frame auto-centering
    """
    boxes = [visible_bounds(t) for t in tiles]
    empty = [Image.new("RGBA", (CARD, CARD), (0, 0, 0, 0)) for _ in tiles]
    if not any(boxes):
        return empty, {
            "method": "empty",
            "scale": 1.0,
            "contentWidth": 0,
            "contentHeight": 0,
            "resized": False,
        }

    left = min(b[0] for b in boxes if b)
    top = min(b[1] for b in boxes if b)
    right = max(b[2] for b in boxes if b)
    bottom = max(b[3] for b in boxes if b)
    cw = max(1, right - left)
    ch = max(1, bottom - top)

    scale = min(CARD / cw, CARD / ch, 1.0)
    if 0.5 <= scale < 1.0 and cw > CARD and ch > CARD:
        half_ok = (cw / 2) <= CARD and (ch / 2) <= CARD
        if half_ok and abs(scale - 0.5) <= 0.08:
            scale = 0.5

    resized = scale < 0.999
    union_nw = max(1, min(CARD, int(round(cw * scale))))
    union_nh = max(1, min(CARD, int(round(ch * scale))))
    origin_x = (CARD - union_nw) // 2
    origin_y = CARD - union_nh

    out: list[Image.Image] = []
    for tile, bbox in zip(tiles, boxes):
        card = Image.new("RGBA", (CARD, CARD), (0, 0, 0, 0))
        if bbox is None:
            out.append(card)
            continue
        fl, ft, fr, fb = bbox
        window = tile.crop((fl, ft, fr, fb))
        fw = max(1, fr - fl)
        fh = max(1, fb - ft)
        if resized:
            nw = max(1, min(CARD, int(round(fw * scale))))
            nh = max(1, min(CARD, int(round(fh * scale))))
            scaled = window.resize((nw, nh), Image.Resampling.NEAREST)
        else:
            nw, nh = fw, fh
            scaled = window
        x = origin_x + int(round((fl - left) * scale))
        y = origin_y + int(round((ft - top) * scale))
        # Clamp so a rounding slip cannot draw outside the card.
        x = max(0, min(CARD - nw, x))
        y = max(0, min(CARD - nh, y))
        card.paste(scaled, (x, y), scaled)
        out.append(card)

    return out, {
        "method": "shared_bbox_nearest",
        "scale": round(scale, 4),
        "contentWidth": cw,
        "contentHeight": ch,
        "outWidth": union_nw,
        "outHeight": union_nh,
        "resized": resized,
        "resampling": "nearest" if resized else "none",
    }


def build_sheet(src_path: Path, layout: dict, tw: int, th: int) -> tuple[Image.Image, dict]:
    src = Image.open(src_path).convert("RGBA")
    if tw <= 0 or th <= 0:
        tw = src.width // int(layout.get("columns", 4))
        th = src.height // int(layout.get("rows", 4))
    tiles = extract_source_tiles(src, layout, tw, th)

    cards, fit_meta = fit_shared_trim(tiles)
    meta = {
        "tileWidth": tw,
        "tileHeight": th,
        **fit_meta,
    }

    sheet = Image.new("RGBA", (SHEET_W, SHEET_H), (0, 0, 0, 0))
    for i, card in enumerate(cards):
        sheet.paste(card, (0, i * CARD), card)
    return sheet, meta


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
        "schemaVersion": 2,
        "format": "gen1recomp-sprite-renderer-sheet",
        "sheetWidth": SHEET_W,
        "sheetHeight": SHEET_H,
        "frameWidth": CARD,
        "frameHeight": CARD,
        "frames": 6,
        "walker": True,
        "rendererConstraint": (
            "SpriteRenderer quads are fixed at 16×16; larger frames are not used."
        ),
        "frameOrder": [
            "idle_down", "idle_up", "idle_left",
            "walk_down", "walk_up", "walk_left",
        ],
        "rightFacing": "mirror_left",
        "walkSourceColumn": walk_col(layout),
        "idleSourceColumn": idle_col(layout),
        "discardedSourceFrames": (
            "Per direction: idle bob, walk bob, and dedicated right-facing row "
            "(engine mirrors left). Only stand/walk phase 0/1 are kept."
        ),
        "scale": (
            "Shared opaque bbox across needed frames sets one max-fit scale "
            "(never upscale). Each frame is cropped to its own pixels, scaled "
            "with nearest-neighbor only, and placed on the shared pivot."
        ),
        "resampling": "NEAREST only",
        "sheets": {},
    }

    written = 0
    skipped = 0
    errors = 0
    methods: dict[str, int] = {}

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
                sheet, build_meta = build_sheet(
                    src_path, layout, meta["tileWidth"], meta["tileHeight"])
                assert sheet.size == (SHEET_W, SHEET_H), sheet.size
                sheet.save(out_path, optimize=True)
                written += 1
                method = str(build_meta.get("method"))
                methods[method] = methods.get(method, 0) + 1
                manifest["sheets"][f"{sid}:{variant}"] = {
                    "speciesId": sid,
                    "variant": variant,
                    "path": rel_out,
                    "source": meta["path"],
                    "form": meta.get("form"),
                    "status": "written",
                    "width": SHEET_W,
                    "height": SHEET_H,
                    "tileWidth": build_meta.get("tileWidth"),
                    "tileHeight": build_meta.get("tileHeight"),
                    "method": method,
                    "scale": build_meta.get("scale"),
                }
            except Exception as exc:  # noqa: BLE001
                print(f"error: {sid} {variant}: {exc}", file=sys.stderr)
                errors += 1

    manifest["methods"] = methods
    man_path = args.out / "manifest.json"
    man_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        f"runtime sheets: written={written} cached={skipped} errors={errors} "
        f"methods={methods} out={args.out}"
    )
    return 0 if errors == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
