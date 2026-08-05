#!/usr/bin/env python3
"""Bake native 16×96 water silhouette sheets from water_runtime sources.

Sources:
  assets/generated/water_runtime/swimming/*.png
  assets/generated/water_runtime/levitates/*.png

Outputs (filenames preserved):
  assets/generated/swimming_silhouette_runtime/{name}.png
  assets/generated/levitates_silhouette_runtime/{name}.png

Per 16×16 frame:
  - recolor every opaque pixel to a dark blue-teal
  - preserve alpha (scaled)
  - sink visible content 1–3 px downward based on free pixels below
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC_ROOT = ROOT / "assets/generated/water_runtime"
KINDS = (
    {
        "kind": "swimming",
        "src": SRC_ROOT / "swimming",
        "out": ROOT / "assets/generated/swimming_silhouette_runtime",
    },
    {
        "kind": "levitates",
        "src": SRC_ROOT / "levitates",
        "out": ROOT / "assets/generated/levitates_silhouette_runtime",
    },
)

SHEET_W = 16
SHEET_H = 96
CARD = 16
FRAMES = 6

# Dark blue-teal silhouette (RGB 0–255). ~12% brightness, no interior detail.
SIL_R, SIL_G, SIL_B = 13, 30, 39
ALPHA_SCALE = 0.86


def visible_bounds(frame: Image.Image) -> tuple[int, int, int, int] | None:
    """Return (min_x, min_y, max_x, max_y) inclusive of opaque pixels, or None."""
    px = frame.load()
    w, h = frame.size
    min_x, min_y, max_x, max_y = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            if px[x, y][3] > 0:
                if x < min_x:
                    min_x = x
                if y < min_y:
                    min_y = y
                if x > max_x:
                    max_x = x
                if y > max_y:
                    max_y = y
    if max_x < 0:
        return None
    return min_x, min_y, max_x, max_y


def sink_for_frame(bounds: tuple[int, int, int, int] | None, h: int = CARD) -> int:
    if bounds is None:
        return 0
    _min_x, _min_y, _max_x, max_y = bounds
    free_below = (h - 1) - max_y
    if free_below >= 3:
        return 3
    if free_below == 2:
        return 2
    if free_below == 1:
        return 1
    # No free pixels: shift up by 1 then sink 1 if possible (net 0), or sink 0.
    return 0


def transform_frame(frame: Image.Image) -> Image.Image:
    frame = frame.convert("RGBA")
    bounds = visible_bounds(frame)
    sink = sink_for_frame(bounds)
    # If no free space below but content has top margin, nudge up then sink.
    if sink == 0 and bounds is not None:
        min_x, min_y, max_x, max_y = bounds
        free_below = (CARD - 1) - max_y
        if free_below <= 0 and min_y >= 1:
            # Shift content up by 1 to create space, then sink 1.
            shifted = Image.new("RGBA", (CARD, CARD), (0, 0, 0, 0))
            shifted.paste(frame, (0, -1))
            frame = shifted
            sink = 1

    if sink > 0:
        sunk = Image.new("RGBA", (CARD, CARD), (0, 0, 0, 0))
        sunk.paste(frame, (0, sink))
        frame = sunk

    px = frame.load()
    out = Image.new("RGBA", (CARD, CARD), (0, 0, 0, 0))
    opx = out.load()
    for y in range(CARD):
        for x in range(CARD):
            r, g, b, a = px[x, y]
            if a <= 0:
                continue
            na = max(0, min(255, int(round(a * ALPHA_SCALE))))
            if na <= 0:
                continue
            opx[x, y] = (SIL_R, SIL_G, SIL_B, na)
    return out


def transform_sheet(src: Image.Image) -> Image.Image:
    src = src.convert("RGBA")
    if src.size != (SHEET_W, SHEET_H):
        raise ValueError(f"expected {SHEET_W}x{SHEET_H}, got {src.size}")
    out = Image.new("RGBA", (SHEET_W, SHEET_H), (0, 0, 0, 0))
    for i in range(FRAMES):
        y0 = i * CARD
        frame = src.crop((0, y0, CARD, y0 + CARD))
        out.paste(transform_frame(frame), (0, y0))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--kind", choices=("swimming", "levitates", "all"), default="all")
    parser.add_argument("--max", type=int, default=0, help="limit sheets per kind (debug)")
    args = parser.parse_args()

    manifest = {
        "schemaVersion": 1,
        "format": "gen1recomp-water-silhouette-sprite-renderer-sheet",
        "sheetWidth": SHEET_W,
        "sheetHeight": SHEET_H,
        "frames": FRAMES,
        "walker": True,
        "color": {"r": SIL_R, "g": SIL_G, "b": SIL_B},
        "alphaScale": ALPHA_SCALE,
        "sink": "1-3px per frame from free pixels below visible bounds",
        "kinds": {},
    }

    total = 0
    for meta in KINDS:
        if args.kind != "all" and meta["kind"] != args.kind:
            continue
        src_dir: Path = meta["src"]
        out_dir: Path = meta["out"]
        if not src_dir.is_dir():
            print(f"skip missing source: {src_dir}", file=sys.stderr)
            continue
        out_dir.mkdir(parents=True, exist_ok=True)
        files = sorted(src_dir.glob("*.png"))
        if args.max > 0:
            files = files[: args.max]
        written = 0
        skipped = 0
        for src_path in files:
            dst = out_dir / src_path.name
            if dst.exists() and not args.force:
                skipped += 1
                continue
            try:
                with Image.open(src_path) as im:
                    out = transform_sheet(im)
                out.save(dst)
                written += 1
            except Exception as exc:  # noqa: BLE001
                print(f"FAIL {src_path.name}: {exc}", file=sys.stderr)
                return 1
        manifest["kinds"][meta["kind"]] = {
            "source": str(src_dir.relative_to(ROOT)),
            "output": str(out_dir.relative_to(ROOT)),
            "written": written,
            "skippedExisting": skipped,
            "totalSource": len(files),
        }
        total += written
        print(f"{meta['kind']}: wrote {written}, skipped {skipped}, sources {len(files)}")

    out_manifest = ROOT / "assets/generated/water_silhouette_runtime_manifest.json"
    out_manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"total written: {total}")
    print(f"manifest: {out_manifest.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
