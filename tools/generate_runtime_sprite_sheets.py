#!/usr/bin/env python3
"""Build Gen1Recomp-compatible 16×96 SpriteRenderer sheets from follow-sprites.

Verified SpriteRenderer frame tables (src/render/SpriteRenderer.lua):

  STAND = { down = 0, up = 1, left = 2, right = 2 }
  WALK  = { down = 3, up = 4, left = 5, right = 5 }

Right-facing uses the left frames with a horizontal mirror in the engine.

Follow-sprite sources are 4×4 grids (rows = directions, columns = frames):
  col 0 = idle pose
  col 1 = idle bob (same silhouette, Y+1) — discarded for runtime walk
  col 2 = distinct walk pose  ← used as the single native walk frame
  col 3 = walk bob (same as col 2, Y+1)

``fit_to_card`` bottom-aligns feet, so bob-only columns collapse to idle.
We therefore pick the first column whose visible content differs from idle
(typically column 2). Extra source walk frames beyond that one pose are not
used: Gen1Recomp SpriteRenderer only supports stand/walk (phase 0/1).

Size modes
----------
  original — identical to previous behaviour (height scale = 1.0).
  relative — multiply common_scale by a soft Pokédex-height factor so small
             species shrink inside the same 16×16 card; large species stay
             at full native size. Water sheets are not generated here.

Outputs (prefer keeping original sheets pixel-identical to prior releases):
  assets/generated/followsprites_runtime/{dex:03d}-{normal|shiny}.png
  assets/generated/followsprites_runtime_relative/{dex:03d}-{normal|shiny}.png
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MAPPING = ROOT / "assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json"
OUT_DIR_ORIGINAL = ROOT / "assets/generated/followsprites_runtime"
OUT_DIR_RELATIVE = ROOT / "assets/generated/followsprites_runtime_relative"
HEIGHTS_CACHE = ROOT / "tools/data/species_heights_m.json"
PREVIEW_DIR = ROOT / "tools/output/sprite_size_preview"

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

# Soft relative sizing from Pokédex height (meters). Clamped [0.68, 1.0].
# Missing / non-positive height → 1.0 (identical to Original).
HEIGHT_SCALE_MIN = 0.68
HEIGHT_SCALE_MAX = 1.0
HEIGHT_REF_M = 1.0
HEIGHT_EXPONENT = 0.35

# Visual overrides for clear special cases (not official-height faithful).
# Only applied in relative mode; does not change Original sheets.
HEIGHT_SCALE_OVERRIDES: dict[int, float] = {
    50: 0.72,   # Diglett
    51: 0.82,   # Dugtrio
    92: 0.82,   # Gastly
    93: 0.90,   # Haunter
    95: 1.00,   # Onix (length must not oversize)
    102: 0.72,  # Exeggcute
    103: 1.00,  # Exeggutor
    130: 1.00,  # Gyarados
}

PREVIEW_SPECIES = (
    (1, "Bulbasaur"),
    (10, "Caterpie"),
    (25, "Pikachu"),
    (6, "Charizard"),
    (95, "Onix"),
    (130, "Gyarados"),
    (143, "Snorlax"),
    (144, "Articuno"),
    (149, "Dragonite"),
    (150, "Mewtwo"),
    (151, "Mew"),
)

DOWNSAMPLE_COMPARE_SPECIES = (10, 25, 6, 95, 130, 143, 144, 150)


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


def _resize_nearest(content: Image.Image, nw: int, nh: int) -> Image.Image:
    return content.resize((nw, nh), Image.Resampling.NEAREST)


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
    scaled = _resize_nearest(content, nw, nh)
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


def relative_height_scale(height_m: float | None) -> float:
    """Soft, clamped height→scale factor. Never below HEIGHT_SCALE_MIN or above 1.0."""
    if height_m is None:
        return 1.0
    try:
        h = float(height_m)
    except (TypeError, ValueError):
        return 1.0
    if h <= 0:
        return 1.0
    scale = (h / HEIGHT_REF_M) ** HEIGHT_EXPONENT
    return max(HEIGHT_SCALE_MIN, min(HEIGHT_SCALE_MAX, scale))


def species_height_scale(species_id: int, height_m: float | None) -> tuple[float, bool]:
    """Return (scale, override_used) for relative mode."""
    if species_id in HEIGHT_SCALE_OVERRIDES:
        raw = HEIGHT_SCALE_OVERRIDES[species_id]
        return max(HEIGHT_SCALE_MIN, min(HEIGHT_SCALE_MAX, float(raw))), True
    return relative_height_scale(height_m), False


def load_heights(path: Path) -> dict[int, float]:
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    raw = data.get("heights") if isinstance(data, dict) else data
    out: dict[int, float] = {}
    if not isinstance(raw, dict):
        return out
    for key, value in raw.items():
        try:
            sid = int(key)
            out[sid] = float(value)
        except (TypeError, ValueError):
            continue
    return out


def walk_col(layout: dict) -> int:
    """Default walk column for layouts without per-tile inspection.

    Follow-sprite sheets use columns ``[idle, idle_bob, walk, walk_bob]``.
    Column 1 is the same silhouette as idle shifted down one pixel; after
    ``fit_to_card`` bottom-aligns feet, idle and walk become identical and
    SpriteRenderer phase 0/1 shows no animation. Prefer column 2 (first
    pose-distinct walk frame). Right is still mirrored from left by the engine.
    """
    cols = layout.get("walkColumns") or [0, 1, 2, 3]
    if len(cols) >= 3:
        return int(cols[2])
    if len(cols) >= 2:
        return int(cols[1])
    return int(cols[0]) if cols else 2


def idle_col(layout: dict) -> int:
    return int(layout.get("idleColumn", 0))


def direction_row(layout: dict, direction: str) -> int:
    dirs = layout.get("directions") or {
        "down": 0, "left": 1, "right": 2, "up": 3,
    }
    return int(dirs[direction])


def _visible_content_key(tile: Image.Image) -> bytes:
    """Offset-invariant fingerprint of a tile's opaque content."""
    bbox = visible_bounds(tile)
    if bbox is None:
        return b""
    return tile.crop(bbox).tobytes()


def pick_walk_column(
    src: Image.Image, layout: dict, tw: int, th: int, direction: str
) -> int:
    """Pick a walk column whose silhouette differs from idle (not just a bob)."""
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
    # Last resort: documented default (column 2 in the 4-frame follower grid).
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


def card_visible_size(card: Image.Image) -> tuple[int, int]:
    bbox = visible_bounds(card)
    if bbox is None:
        return 0, 0
    l, t, r, b = bbox
    return r - l, b - t


def build_sheet(
    src_path: Path,
    layout: dict,
    tw: int,
    th: int,
    *,
    height_scale: float = 1.0,
) -> tuple[Image.Image, float, float]:
    """Return (sheet, base_fit_scale, final_scale)."""
    src = Image.open(src_path).convert("RGBA")
    if tw <= 0 or th <= 0:
        tw = src.width // int(layout.get("columns", 4))
        th = src.height // int(layout.get("rows", 4))
    tiles = extract_source_tiles(src, layout, tw, th)
    fit = common_scale(tiles)
    final = fit * float(height_scale)
    # Never exceed the card; height_scale is already ≤ 1.0.
    final = min(final, 1.0)
    sheet = Image.new("RGBA", (SHEET_W, SHEET_H), (0, 0, 0, 0))
    for i, tile in enumerate(tiles):
        card = fit_to_card(tile, final)
        sheet.paste(card, (0, i * CARD), card)
    return sheet, fit, final


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


def empty_manifest(layout: dict, size_mode: str) -> dict:
    return {
        "schemaVersion": 1,
        "format": "gen1recomp-sprite-renderer-sheet",
        "sizeMode": size_mode,
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
        "walkSourceNote": (
            "Per-direction walk column is the first walkColumns entry whose "
            "visible content differs from idle (typically column 2). Column 1 "
            "is an idle bob that collapses under bottom-align fit_to_card."
        ),
        "idleSourceColumn": idle_col(layout),
        "discardedSourceFrames": (
            "Per direction: idle bob (col 1), walk bob (col 3), and dedicated "
            "right-facing row (engine mirrors left). Gen1Recomp only supports "
            "stand/walk phase 0/1."
        ),
        "scale": (
            "visible-bounds fit, nearest-neighbor, bottom-center, shared per species"
            + (
                "; relative height scale applied"
                if size_mode == "relative"
                else "; original (no height scale)"
            )
        ),
        "heightScale": {
            "enabled": size_mode == "relative",
            "formula": "(height_m / 1.0) ** 0.35 clamped to [0.68, 1.0]",
            "min": HEIGHT_SCALE_MIN,
            "max": HEIGHT_SCALE_MAX,
            "unit": "meters",
            "overrides": {str(k): v for k, v in sorted(HEIGHT_SCALE_OVERRIDES.items())},
        },
        "sheets": {},
    }


def generate_mode(
    *,
    mapping_path: Path,
    out_dir: Path,
    size_mode: str,
    heights: dict[int, float],
    max_species: int,
    force: bool,
    dir_label: str,
) -> tuple[int, int, int, dict]:
    data = json.loads(mapping_path.read_text(encoding="utf-8"))
    layout = data.get("layout") or {}
    species = data.get("species") or {}
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = empty_manifest(layout, size_mode)

    written = 0
    skipped = 0
    errors = 0
    scale_report: dict[str, dict] = {}

    for key in sorted(species.keys(), key=lambda k: int(k)):
        sid = int(key)
        if max_species and sid > max_species:
            continue
        entry = species[key]
        height_m = heights.get(sid)
        if size_mode == "relative":
            h_scale, override_used = species_height_scale(sid, height_m)
        else:
            h_scale, override_used = 1.0, False

        for variant in ("normal", "shiny"):
            meta = variant_meta(entry, variant)
            if not meta:
                continue
            src_path = ROOT / meta["path"]
            out_name = f"{sid:03d}-{variant}.png"
            out_path = out_dir / out_name
            rel_out = f"{dir_label}/{out_name}"
            if out_path.is_file() and not force:
                skipped += 1
                manifest["sheets"][f"{sid}:{variant}"] = {
                    "speciesId": sid,
                    "variant": variant,
                    "path": rel_out,
                    "source": meta["path"],
                    "form": meta.get("form"),
                    "status": "cached",
                    "sizeMode": size_mode,
                }
                continue
            if not src_path.is_file():
                print(f"warn: missing source {src_path}", file=sys.stderr)
                errors += 1
                continue
            try:
                sheet, fit, final = build_sheet(
                    src_path, layout, meta["tileWidth"], meta["tileHeight"],
                    height_scale=h_scale,
                )
                assert sheet.size == (SHEET_W, SHEET_H), sheet.size
                sheet.save(out_path, optimize=True)
                written += 1
                idle = sheet.crop((0, 0, CARD, CARD))
                vw, vh = card_visible_size(idle)
                manifest["sheets"][f"{sid}:{variant}"] = {
                    "speciesId": sid,
                    "variant": variant,
                    "path": rel_out,
                    "source": meta["path"],
                    "form": meta.get("form"),
                    "status": "written",
                    "width": SHEET_W,
                    "height": SHEET_H,
                    "sizeMode": size_mode,
                    "baseFitScale": fit,
                    "relativeHeightScale": h_scale,
                    "finalScale": final,
                    "heightM": height_m,
                    "overrideUsed": override_used,
                    "visibleWidth": vw,
                    "visibleHeight": vh,
                }
                if variant == "normal":
                    scale_report[str(sid)] = {
                        "speciesId": sid,
                        "height": height_m,
                        "baseFitScale": fit,
                        "relativeHeightScale": h_scale,
                        "finalScale": final,
                        "overrideUsed": override_used,
                        "visibleWidth": vw,
                        "visibleHeight": vh,
                    }
            except Exception as exc:  # noqa: BLE001
                print(f"error: {sid} {variant}: {exc}", file=sys.stderr)
                errors += 1

    man_path = out_dir / "manifest.json"
    man_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        f"runtime sheets [{size_mode}]: written={written} cached={skipped} "
        f"errors={errors} out={out_dir}"
    )
    return written, skipped, errors, scale_report


def _magnify(im: Image.Image, factor: int) -> Image.Image:
    w, h = im.size
    return im.resize((w * factor, h * factor), Image.Resampling.NEAREST)


def write_preview(
    *,
    mapping_path: Path,
    heights: dict[int, float],
    preview_dir: Path,
    mag: int = 8,
) -> None:
    """Side-by-side Source / Original / Relative previews + CSV/JSON report."""
    data = json.loads(mapping_path.read_text(encoding="utf-8"))
    layout = data.get("layout") or {}
    species = data.get("species") or {}
    preview_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict] = []

    for sid, name in PREVIEW_SPECIES:
        entry = species.get(str(sid))
        if not entry:
            continue
        meta = variant_meta(entry, "normal")
        if not meta:
            continue
        src_path = ROOT / meta["path"]
        if not src_path.is_file():
            continue
        height_m = heights.get(sid)
        h_scale, override_used = species_height_scale(sid, height_m)

        src = Image.open(src_path).convert("RGBA")
        tw = meta["tileWidth"] or (src.width // int(layout.get("columns", 4)))
        th = meta["tileHeight"] or (src.height // int(layout.get("rows", 4)))
        # Source idle-down tile (raw).
        src_tile = crop_tile(src, idle_col(layout), direction_row(layout, "down"), tw, th)

        orig_sheet, fit, final_orig = build_sheet(
            src_path, layout, tw, th, height_scale=1.0)
        rel_sheet, _, final_rel = build_sheet(
            src_path, layout, tw, th, height_scale=h_scale)

        orig_card = orig_sheet.crop((0, 0, CARD, CARD))
        rel_card = rel_sheet.crop((0, 0, CARD, CARD))
        vw, vh = card_visible_size(rel_card)

        # Compose Source (idle tile) | Original | Relative at mag× nearest.
        panels = [_magnify(src_tile, mag), _magnify(orig_card, mag), _magnify(rel_card, mag)]
        gap = mag
        total_w = sum(p.width for p in panels) + gap * (len(panels) - 1)
        total_h = max(p.height for p in panels)
        canvas = Image.new("RGBA", (total_w, total_h), (32, 32, 40, 255))
        x = 0
        for p in panels:
            canvas.paste(p, (x, total_h - p.height), p)
            x += p.width + gap
        out_png = preview_dir / f"{sid:03d}_{name.lower()}_compare.png"
        canvas.save(out_png)

        rows.append({
            "speciesId": sid,
            "name": name,
            "height": height_m,
            "baseFitScale": fit,
            "relativeHeightScale": h_scale,
            "finalScale": final_rel,
            "overrideUsed": override_used,
            "visibleWidth": vw,
            "visibleHeight": vh,
            "originalFinalScale": final_orig,
            "preview": str(out_png.relative_to(ROOT)),
        })

    # Optional downsample method comparison (diagnostic only; NEAREST remains default).
    compare_dir = preview_dir / "downsample_compare"
    compare_dir.mkdir(parents=True, exist_ok=True)
    for sid in DOWNSAMPLE_COMPARE_SPECIES:
        entry = species.get(str(sid))
        if not entry:
            continue
        meta = variant_meta(entry, "normal")
        if not meta:
            continue
        src_path = ROOT / meta["path"]
        if not src_path.is_file():
            continue
        src = Image.open(src_path).convert("RGBA")
        tw = meta["tileWidth"] or (src.width // int(layout.get("columns", 4)))
        th = meta["tileHeight"] or (src.height // int(layout.get("rows", 4)))
        tile = crop_tile(src, idle_col(layout), direction_row(layout, "down"), tw, th)
        bbox = visible_bounds(tile)
        if bbox is None:
            continue
        content = tile.crop(bbox)
        fit = min(CARD / content.width, CARD / content.height, 1.0)
        h_scale, _ = species_height_scale(sid, heights.get(sid))
        final = min(fit * h_scale, 1.0)
        nw = max(1, min(CARD, int(round(content.width * final))))
        nh = max(1, min(CARD, int(round(content.height * final))))

        methods = {
            "NEAREST": Image.Resampling.NEAREST,
            "BOX": Image.Resampling.BOX,
            "LANCZOS": Image.Resampling.LANCZOS,
        }
        panels = []
        for label, resample in methods.items():
            scaled = content.resize((nw, nh), resample).convert("RGBA")
            if resample != Image.Resampling.NEAREST:
                # Hard alpha cleanup — avoid soft fringes for diagnostic comparison.
                pixels = scaled.load()
                for yy in range(scaled.height):
                    for xx in range(scaled.width):
                        r, g, b, a = pixels[xx, yy]
                        pixels[xx, yy] = (r, g, b, 255 if a >= 128 else 0)
            card = Image.new("RGBA", (CARD, CARD), (0, 0, 0, 0))
            card.paste(scaled, ((CARD - nw) // 2, CARD - nh), scaled)
            panels.append(_magnify(card, mag))
        gap = mag
        total_w = sum(p.width for p in panels) + gap * (len(panels) - 1)
        canvas = Image.new("RGBA", (total_w, panels[0].height), (32, 32, 40, 255))
        x = 0
        for p in panels:
            canvas.paste(p, (x, 0), p)
            x += p.width + gap
        canvas.save(compare_dir / f"{sid:03d}_NEAREST_BOX_LANCZOS.png")

    (preview_dir / "scale_report.json").write_text(
        json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    with (preview_dir / "scale_report.csv").open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "speciesId", "name", "height", "baseFitScale", "relativeHeightScale",
            "finalScale", "overrideUsed", "visibleWidth", "visibleHeight",
        ])
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k) for k in writer.fieldnames})
    print(f"preview report: {preview_dir} ({len(rows)} species)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mapping", type=Path, default=MAPPING)
    parser.add_argument("--out-original", type=Path, default=OUT_DIR_ORIGINAL)
    parser.add_argument("--out-relative", type=Path, default=OUT_DIR_RELATIVE)
    parser.add_argument("--heights", type=Path, default=HEIGHTS_CACHE)
    parser.add_argument(
        "--size-mode",
        choices=("original", "relative", "both"),
        default="both",
        help="Which runtime sheet variant(s) to generate (default: both)",
    )
    parser.add_argument("--max-species", type=int, default=0,
                        help="If >0, only generate speciesId <= this (0 = all)")
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--preview",
        action="store_true",
        help=f"Write side-by-side previews under {PREVIEW_DIR}",
    )
    parser.add_argument("--preview-dir", type=Path, default=PREVIEW_DIR)
    parser.add_argument("--preview-mag", type=int, default=8)
    args = parser.parse_args()

    if not args.mapping.is_file():
        print(f"error: mapping missing: {args.mapping}", file=sys.stderr)
        return 1

    heights = load_heights(args.heights)
    if args.size_mode in ("relative", "both") and not heights:
        print(
            f"warn: height cache missing or empty ({args.heights}); "
            "relative mode will use scale 1.0 for all species",
            file=sys.stderr,
        )

    total_errors = 0
    if args.size_mode in ("original", "both"):
        _, _, errors, _ = generate_mode(
            mapping_path=args.mapping,
            out_dir=args.out_original,
            size_mode="original",
            heights=heights,
            max_species=args.max_species,
            force=args.force,
            dir_label="assets/generated/followsprites_runtime",
        )
        total_errors += errors

    if args.size_mode in ("relative", "both"):
        _, _, errors, _ = generate_mode(
            mapping_path=args.mapping,
            out_dir=args.out_relative,
            size_mode="relative",
            heights=heights,
            max_species=args.max_species,
            force=args.force,
            dir_label="assets/generated/followsprites_runtime_relative",
        )
        total_errors += errors

    if args.preview:
        write_preview(
            mapping_path=args.mapping,
            heights=heights,
            preview_dir=args.preview_dir,
            mag=max(1, int(args.preview_mag)),
        )

    return 0 if total_errors == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
