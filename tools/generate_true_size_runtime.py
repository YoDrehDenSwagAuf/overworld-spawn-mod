#!/usr/bin/env python3
"""Generate True Size runtime SpriteRenderer sheets (HGSS-native philosophy).

TRUE SIZE means: preserve the native visual size and detail of original HGSS /
PokeMMO follower artwork — NOT Pokédex-height → XS–XXL targetHeight classes.

Sources (never Classic degraded 16×16 runtime):
  HGSS:      assets/enhanced_overworld/followsprites
  Followers: assets/enhanced_overworld/poke_followers
  Pokédex:   HGSS idle-down stand-in (1-frame)
  Swimming / Levitates: assets/enhanced_overworld/water_sprites/{kind}

Outputs under assets/generated/true_size/{pack}/ plus species geometry tables.

HGSS default path: extract → shared alpha bounds → pad → save (NO resampling).
Other packs: fit visible content to HGSS nativeVisualHeight (nearest-neighbor).
Classic assets are never overwritten. Voxel remains Classic at runtime.
"""
from __future__ import annotations

import argparse
import copy
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
HEIGHTS_PATH = ROOT / "tools/gen1_heights.json"
HGSS_SRC = ROOT / "assets/enhanced_overworld/followsprites"
HGSS_MAP = ROOT / "assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json"
FOLLOWERS_SRC = ROOT / "assets/enhanced_overworld/poke_followers"
WATER_ROOT = ROOT / "assets/enhanced_overworld/water_sprites"
OUT_ROOT = ROOT / "assets/generated/true_size"
DEV_OUT = OUT_ROOT / "dev"
REPORT_PATH = ROOT / "docs/analysis/TRUE_SIZE_NATIVE_HGSS.md"

FRAME_SPECS = (
    ("idle", "down"),
    ("idle", "up"),
    ("idle", "left"),
    ("walk", "down"),
    ("walk", "up"),
    ("walk", "left"),
)

DEFAULT_LAYOUT = {
    "columns": 4,
    "rows": 4,
    "directions": {"down": 0, "left": 1, "right": 2, "up": 3},
    "idleColumn": 0,
    "walkColumns": [0, 1, 2, 3],
}

# Transparent safety margin around shared visible bounds (runtime canvas).
TRUE_SIZE_PADDING = 2

# Soft warning threshold — do not auto-clamp; report for review.
SOFT_WARN_VISIBLE_PX = 48

# HGSS LAND is absolute visual size authority for swimming / levitate.
# Height is primary; width/area are sanity caps so wide poses cannot look huge.
WATER_WIDTH_RATIO_LIMIT = 1.30
WATER_AREA_RATIO_LIMIT = 1.30
WATER_WIDTH_RATIO_WARN = 1.35
WATER_AREA_RATIO_WARN = 1.35
WATER_AREA_RATIO_FAIL = 1.50
WATER_HEIGHT_FAIL_PX = 1  # runtime opaque height may exceed land by at most this
# Perceived-size blend (height dominates; area secondary; width soft).
WATER_HEIGHT_WEIGHT = 0.60
WATER_AREA_WEIGHT = 0.30
WATER_WIDTH_WEIGHT = 0.10
# Target perceived water/land ratio (<1 → water slightly smaller than land).
WATER_PERCEIVED_TARGET = 0.97
# Tiny final bias after per-species perceived matching (not the primary fix).
WATER_PRESENTATION_SCALE = 0.98
LEVITATE_PRESENTATION_SCALE = 0.98
# Audit thresholds on final perceived ratio.
WATER_PERCEIVED_WARN_LO = 0.90
WATER_PERCEIVED_WARN_HI = 1.04
WATER_PERCEIVED_FAIL_HI = 1.06

# Prototype species for native-HGSS validation before regenerating all 151.
PROTOTYPE_SPECIES = (19, 9, 95)  # Rattata, Blastoise, Onix

# Declarative art-direction overrides (dex → fields).
# Default sizing is always "native". Overrides never add renderer branches.
MANUAL_OVERRIDES = {
    # Onix: native HGSS is already tall (~29px body); modest NN scale for
    # overworld presence without literal Pokédex length.
    95: {"visualScale": 1.15, "notes": "modest presence boost; NN only"},
    # Floating / unusual silhouettes — reserved for later tuning.
    # 92: {"anchorOffsetY": -2},  # Gastly
    # 93: {"anchorOffsetY": -2},  # Haunter
}


def visible_bounds(im: Image.Image):
    if im.mode != "RGBA":
        im = im.convert("RGBA")
    return im.getchannel("A").getbbox()


def opaque_bounds_union(tiles: list[Image.Image]):
    """Tight union of opaque (alpha>0) pixels across tiles."""
    boxes = [visible_bounds(t) for t in tiles]
    if not any(boxes):
        return None
    ux0 = min(b[0] for b in boxes if b)
    uy0 = min(b[1] for b in boxes if b)
    ux1 = max(b[2] for b in boxes if b)
    uy1 = max(b[3] for b in boxes if b)
    return {
        "minX": ux0,
        "minY": uy0,
        "maxX": ux1,
        "maxY": uy1,
        "visibleWidth": ux1 - ux0,
        "visibleHeight": uy1 - uy0,
    }


def measure_sheet_opaque_bounds(path: Path, frames: int = 6):
    """Opaque content bounds of a generated vertical walker sheet."""
    if not path.exists():
        return None
    im = Image.open(path).convert("RGBA")
    if frames < 1:
        frames = 1
    fw, fh = im.width, im.height // frames
    if fw < 1 or fh < 1:
        return None
    tiles = [im.crop((0, i * fh, fw, (i + 1) * fh)) for i in range(frames)]
    return opaque_bounds_union(tiles)


def _median_int(values: list[int]) -> int:
    if not values:
        return 0
    xs = sorted(int(v) for v in values)
    return int(xs[len(xs) // 2])


def frame_opaque_metrics(tile: Image.Image) -> dict | None:
    """Per-frame opaque metrics: bbox W/H + real opaque pixel count."""
    if tile.mode != "RGBA":
        tile = tile.convert("RGBA")
    bbox = visible_bounds(tile)
    if bbox is None:
        return None
    w = int(bbox[2] - bbox[0])
    h = int(bbox[3] - bbox[1])
    alpha = tile.crop(bbox).getchannel("A")
    # Count non-transparent pixels (perceived body mass, includes foam).
    opaque = 0
    for px in alpha.getdata():
        if px:
            opaque += 1
    return {
        "visibleWidth": w,
        "visibleHeight": h,
        "opaquePixelCount": int(opaque),
        "bboxArea": w * h,
    }


def median_frame_metrics(tiles: list[Image.Image]) -> dict | None:
    """Robust species size from per-frame medians (not union max)."""
    rows = [frame_opaque_metrics(t) for t in tiles]
    rows = [r for r in rows if r and r["opaquePixelCount"] > 0]
    if not rows:
        return None
    return {
        "visibleWidth": _median_int([r["visibleWidth"] for r in rows]),
        "visibleHeight": _median_int([r["visibleHeight"] for r in rows]),
        "opaquePixelCount": _median_int([r["opaquePixelCount"] for r in rows]),
        "frameCount": len(rows),
        "perFrame": rows,
        # Union bbox kept for diagnostics only — NOT size authority.
        "unionVisibleWidth": max(r["visibleWidth"] for r in rows),
        "unionVisibleHeight": max(r["visibleHeight"] for r in rows),
    }


def measure_sheet_median_metrics(path: Path, frames: int = 6) -> dict | None:
    if not path.exists():
        return None
    im = Image.open(path).convert("RGBA")
    if frames < 1:
        frames = 1
    fw, fh = im.width, im.height // frames
    if fw < 1 or fh < 1:
        return None
    tiles = [im.crop((0, i * fh, fw, (i + 1) * fh)) for i in range(frames)]
    return median_frame_metrics(tiles)


def hgss_land_reference_visible_bounds(dex: int) -> dict | None:
    """Opaque HGSS LAND perceived size authority (per-frame medians).

    Uses generated HGSS land runtime (normal first). Never rewrites land PNGs.
    Median W/H/opaque-pixels avoid side-frame union inflation (e.g. Poliwag).
    """
    for variant in ("normal", "shiny"):
        path = OUT_ROOT / "hgss" / f"{dex:03d}-{variant}.png"
        metrics = measure_sheet_median_metrics(path, frames=6)
        if metrics and metrics["visibleHeight"] > 0 and metrics["visibleWidth"] > 0:
            return {
                "visibleWidth": int(metrics["visibleWidth"]),
                "visibleHeight": int(metrics["visibleHeight"]),
                # Perceived area = opaque pixel count (not bbox W×H).
                "visibleArea": int(metrics["opaquePixelCount"]),
                "opaquePixelCount": int(metrics["opaquePixelCount"]),
                "unionVisibleWidth": int(metrics["unionVisibleWidth"]),
                "unionVisibleHeight": int(metrics["unionVisibleHeight"]),
                "metric": "median_frame",
                "variant": variant,
                "path": str(path.relative_to(ROOT)),
            }
    return None


def hgss_land_reference_visible_height(dex: int) -> int | None:
    """Back-compat: opaque land height only."""
    b = hgss_land_reference_visible_bounds(dex)
    return int(b["visibleHeight"]) if b else None


def perceived_size_coefficient(src: dict, land: dict) -> float:
    """Linear coefficient: perceivedRatio ≈ coefficient * uniformScale."""
    land_w = max(1, int(land["visibleWidth"]))
    land_h = max(1, int(land["visibleHeight"]))
    land_area = max(1, int(land.get("opaquePixelCount") or land.get("visibleArea") or 1))
    src_w = max(1, int(src["visibleWidth"]))
    src_h = max(1, int(src["visibleHeight"]))
    src_area = max(1, int(src.get("opaquePixelCount") or src.get("visibleArea") or 1))
    return (
        WATER_HEIGHT_WEIGHT * (src_h / float(land_h))
        + WATER_AREA_WEIGHT * math.sqrt(src_area / float(land_area))
        + WATER_WIDTH_WEIGHT * (src_w / float(land_w))
    )


def compute_land_authority_scale(
    land: dict,
    source: dict,
    *,
    width_ratio_limit: float = WATER_WIDTH_RATIO_LIMIT,
    area_ratio_limit: float = WATER_AREA_RATIO_LIMIT,
    multiplier: float = 1.0,
    presentation_bias: float = 1.0,
    perceived_target: float = WATER_PERCEIVED_TARGET,
) -> dict:
    """Uniform NN scale so water/levitate match HGSS land perceived size.

    1) Per-species perceived-size scale from median land vs source metrics.
    2) Hard caps: height ≤ land median, width ≤ land-union×limit (pose OK),
       opaque area ≤ land×limit.
    3) Tiny presentation bias (<1) after matching — never the primary fix.
    Never upscales past land authority.
    """
    land_w = max(1, int(land["visibleWidth"]))
    land_h = max(1, int(land["visibleHeight"]))
    land_area = max(1, int(land.get("opaquePixelCount") or land.get("visibleArea") or (land_w * land_h)))
    # Width ceiling uses the wider land footprint (union) so side-pose land
    # frames and legitimate swim width are not crushed by a skinny median.
    land_w_cap = max(
        land_w,
        int(land.get("unionVisibleWidth") or 0),
    )
    src_w = max(1, int(source["visibleWidth"]))
    src_h = max(1, int(source["visibleHeight"]))
    src_area = max(1, int(source.get("opaquePixelCount") or source.get("visibleArea") or (src_w * src_h)))

    coef = perceived_size_coefficient(
        {"visibleWidth": src_w, "visibleHeight": src_h, "opaquePixelCount": src_area},
        {"visibleWidth": land_w, "visibleHeight": land_h, "opaquePixelCount": land_area},
    )
    target = float(perceived_target or 1.0)
    if target <= 0:
        target = WATER_PERCEIVED_TARGET
    # Primary: match perceived body size of THIS species' land sprite.
    if coef > 1e-9:
        species_scale = target / coef
    else:
        species_scale = 1.0
    species_scale = min(1.0, species_scale)

    height_scale = min(1.0, land_h / float(src_h))
    max_w = max(1, int(math.floor(land_w_cap * float(width_ratio_limit) + 1e-9)))
    max_area = max(1, int(math.floor(land_area * float(area_ratio_limit) + 1e-9)))
    if src_w > 0 and (src_w * species_scale) > max_w:
        width_limit_scale = max_w / float(src_w)
    else:
        width_limit_scale = species_scale
    if src_area > 0 and (src_area * (species_scale ** 2)) > max_area:
        area_limit_scale = math.sqrt(max_area / float(src_area))
    else:
        area_limit_scale = species_scale

    final_scale = min(species_scale, height_scale, width_limit_scale, area_limit_scale)

    mult = float(multiplier or 1.0)
    if 0 < mult < 1.0:
        final_scale *= mult

    bias = float(presentation_bias or 1.0)
    if 0 < bias < 1.0:
        final_scale *= bias

    if final_scale <= 0:
        final_scale = min(1.0, height_scale)
    final_scale = min(final_scale, height_scale, 1.0)

    # Tighten against integer NN rounding so hard caps still hold.
    for _ in range(6):
        out_w = max(1, int(round(src_w * final_scale)))
        out_h = max(1, int(round(src_h * final_scale)))
        out_area = max(1, int(round(src_area * (final_scale ** 2))))
        over_w = out_w > max_w
        over_h = out_h > land_h
        over_a = out_area > max_area
        if not (over_w or over_h or over_a):
            break
        candidates = [final_scale]
        if over_w:
            candidates.append(max_w / float(src_w))
        if over_h:
            candidates.append(land_h / float(src_h))
        if over_a:
            candidates.append(math.sqrt(max_area / float(src_area)))
        next_scale = min(candidates)
        next_scale = min(next_scale, height_scale, 1.0)
        if abs(next_scale - final_scale) < 1e-9:
            final_scale = max(0.01, (max(1, out_w - 1)) / float(src_w))
            final_scale = min(final_scale, height_scale, 1.0)
        else:
            final_scale = next_scale

    out_w = max(1, int(round(src_w * final_scale)))
    out_h = max(1, int(round(src_h * final_scale)))
    out_area = max(1, int(round(src_area * (final_scale ** 2))))
    perc = (
        WATER_HEIGHT_WEIGHT * (out_h / float(land_h))
        + WATER_AREA_WEIGHT * math.sqrt(out_area / float(land_area))
        + WATER_WIDTH_WEIGHT * (out_w / float(land_w))
    )
    return {
        "speciesScale": round(species_scale, 6),
        "perceivedCoefficient": round(coef, 6),
        "perceivedTarget": target,
        "predictedPerceivedRatio": round(perc, 4),
        "heightScale": round(height_scale, 6),
        "widthLimitScale": round(width_limit_scale, 6),
        "areaLimitScale": round(area_limit_scale, 6),
        "finalVisualScale": round(final_scale, 6),
        "predictedOpaqueWidth": out_w,
        "predictedOpaqueHeight": out_h,
        "predictedOpaqueArea": out_area,
        "predictedWidthRatio": round(out_w / float(land_w), 4),
        "predictedHeightRatio": round(out_h / float(land_h), 4),
        "predictedAreaRatio": round(out_area / float(land_area), 4),
        "widthRatioLimit": float(width_ratio_limit),
        "areaRatioLimit": float(area_ratio_limit),
        "widthCapLandWidth": land_w_cap,
        "multiplier": mult,
        "presentationBias": bias,
        "landMetric": land.get("metric") or "median_frame",
    }


def crop_tile(src: Image.Image, col: int, row: int, tw: int, th: int) -> Image.Image:
    return src.crop((col * tw, row * th, (col + 1) * tw, (row + 1) * th)).convert("RGBA")


def content_key(tile: Image.Image) -> bytes:
    bbox = visible_bounds(tile)
    if bbox is None:
        return b""
    return tile.crop(bbox).tobytes()


def pick_walk_column(src, layout, tw, th, direction: str) -> int:
    dirs = layout.get("directions") or DEFAULT_LAYOUT["directions"]
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


def extract_grid_tiles(src: Image.Image, layout: dict, tw: int, th: int) -> list[Image.Image]:
    dirs = layout.get("directions") or DEFAULT_LAYOUT["directions"]
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


def extract_strip_tiles(src: Image.Image, frames: int = 6) -> list[Image.Image]:
    """Vertical walker strip → per-frame tiles."""
    fw = src.width
    fh = src.height // frames
    tiles = []
    for i in range(frames):
        tiles.append(src.crop((0, i * fh, fw, (i + 1) * fh)).convert("RGBA"))
    return tiles


def shared_alpha_bounds(tiles: list[Image.Image]):
    """Union of non-transparent bounds across ALL frames (shared animation space)."""
    boxes = [visible_bounds(t) for t in tiles]
    if not any(boxes):
        return None
    ux0 = min(b[0] for b in boxes if b)
    uy0 = min(b[1] for b in boxes if b)
    ux1 = max(b[2] for b in boxes if b)
    uy1 = max(b[3] for b in boxes if b)
    return {
        "minX": ux0,
        "minY": uy0,
        "maxX": ux1,
        "maxY": uy1,
        "nativeVisualWidth": ux1 - ux0,
        "nativeVisualHeight": uy1 - uy0,
        "perFrame": [
            None
            if b is None
            else {
                "minX": b[0],
                "minY": b[1],
                "maxX": b[2],
                "maxY": b[3],
                "visibleWidth": b[2] - b[0],
                "visibleHeight": b[3] - b[1],
            }
            for b in boxes
        ],
    }


def class_from_native_height(h: int) -> str:
    """Documentation / follower-spacing class derived from native visual height."""
    h = int(h)
    if h <= 16:
        return "XS"
    if h <= 20:
        return "S"
    if h <= 24:
        return "M"
    if h <= 29:
        return "L"
    if h <= 35:
        return "XL"
    return "XXL"


def compose_native_sheet(
    tiles: list[Image.Image],
    *,
    padding: int = TRUE_SIZE_PADDING,
    visual_scale: float = 1.0,
    extra_padding_x: int = 0,
    extra_padding_y: int = 0,
    anchor_offset_x: float = 0.0,
    anchor_offset_y: float = 0.0,
    target_visible_height: int | None = None,
    allow_resample: bool = False,
    forced_bounds: dict | None = None,
    snap_friendly_scales: bool = True,
):
    """Build a vertical 6-frame (or N-frame) sheet from shared source bounds.

    Critical: every frame uses the SAME source crop window and the SAME paste
    offset — never independently trim/center frames (avoids animation jitter).

    HGSS default: visual_scale=1.0, allow_resample=False → pixel copy only.
    Other packs: target_visible_height from HGSS reference → NN fit if needed.

    forced_bounds: optional union bounds (e.g. across normal+shiny) so every
    variant of a species shares one runtime canvas / geometry table entry.
    """
    bounds = forced_bounds or shared_alpha_bounds(tiles)
    if bounds is None:
        fw = max(16, 2 * padding)
        fh = max(16, 2 * padding)
        empty = [Image.new("RGBA", (fw, fh), (0, 0, 0, 0)) for _ in tiles]
        return empty, {
            "method": "empty",
            "wasResized": False,
            "resizeReason": None,
            "padding": padding,
            "runtimeFrameWidth": fw,
            "runtimeFrameHeight": fh,
            "anchorX": fw / 2,
            "anchorY": fh,
            "nativeVisualWidth": 0,
            "nativeVisualHeight": 0,
        }

    ux0, uy0 = bounds["minX"], bounds["minY"]
    ux1, uy1 = bounds["maxX"], bounds["maxY"]
    cw = int(bounds["nativeVisualWidth"])
    ch = int(bounds["nativeVisualHeight"])

    scale = float(visual_scale or 1.0)
    resize_reason = None
    if target_visible_height is not None and ch > 0:
        # Fit visible content height to HGSS reference (other packs).
        ref = max(1, int(target_visible_height))
        fit = ref / float(ch)
        scale = scale * fit
        if abs(fit - 1.0) > 1e-6:
            resize_reason = "match_hgss_visible_height"
            allow_resample = True

    if abs(scale - 1.0) > 1e-6 and not allow_resample and abs(visual_scale - 1.0) > 1e-6:
        # Explicit override scale on HGSS — nearest-neighbor permitted.
        allow_resample = True
        resize_reason = resize_reason or "manual_visual_scale"

    was_resized = abs(scale - 1.0) > 1e-6
    if was_resized and not allow_resample:
        # Should not happen for HGSS scale=1; refuse silent bilinear paths.
        scale = 1.0
        was_resized = False
        resize_reason = None

    if was_resized:
        # Prefer integer scales when close (pixel-art friendly), unless a
        # precise land-authority presentation scale must be preserved.
        if snap_friendly_scales:
            for candidate in (3.0, 2.0, 1.5, 1.0, 0.5):
                if abs(scale - candidate) <= 0.05:
                    scale = candidate
                    break
        nw = max(1, int(round(cw * scale)))
        nh = max(1, int(round(ch * scale)))
    else:
        nw, nh = cw, ch

    pad_x = int(padding) + int(extra_padding_x)
    pad_y = int(padding) + int(extra_padding_y)
    fw = nw + 2 * pad_x
    fh = nh + 2 * pad_y

    # Soft sanity — report only, never clamp.
    warn = None
    if nw > SOFT_WARN_VISIBLE_PX or nh > SOFT_WARN_VISIBLE_PX:
        warn = f"visible dimension > {SOFT_WARN_VISIBLE_PX}px ({nw}x{nh})"

    cards = []
    for tile in tiles:
        card = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
        window = tile.crop((ux0, uy0, ux1, uy1))
        if was_resized:
            window = window.resize((nw, nh), Image.Resampling.NEAREST)
        # Fixed paste — same offset for every frame (stable animation).
        card.paste(window, (pad_x, pad_y), window)
        cards.append(card)

    anchor_x = fw / 2.0 + float(anchor_offset_x or 0.0)
    # Feet / base at bottom of visible content (above bottom padding).
    anchor_y = float(pad_y + nh) + float(anchor_offset_y or 0.0)

    meta = {
        "method": "native_shared_bounds" if not was_resized else "native_shared_bounds_nn",
        "wasResized": was_resized,
        "resizeReason": resize_reason,
        "resampling": "nearest" if was_resized else "none",
        "scale": round(scale, 4),
        "padding": padding,
        "extraPaddingX": extra_padding_x,
        "extraPaddingY": extra_padding_y,
        "visibleMinX": ux0,
        "visibleMaxX": ux1,
        "visibleMinY": uy0,
        "visibleMaxY": uy1,
        "nativeVisualWidth": cw,
        "nativeVisualHeight": ch,
        "scaledVisualWidth": nw,
        "scaledVisualHeight": nh,
        "runtimeFrameWidth": fw,
        "runtimeFrameHeight": fh,
        "anchorX": anchor_x,
        "anchorY": anchor_y,
        "anchorOffsetX": anchor_offset_x,
        "anchorOffsetY": anchor_offset_y,
        "warning": warn,
    }
    return cards, meta


def stack_sheet(cards: list[Image.Image], frame_w: int, frame_h: int) -> Image.Image:
    sheet = Image.new("RGBA", (frame_w, frame_h * len(cards)), (0, 0, 0, 0))
    for i, card in enumerate(cards):
        sheet.paste(card, (0, i * frame_h), card)
    return sheet


def hgss_source(dex: int) -> dict[str, Path]:
    out = {}
    for variant, suffixes in (
        ("normal", ["-b-n.png", "-f-n.png", "-m-n.png", "-n.png"]),
        ("shiny", ["-b-s.png", "-f-s.png", "-m-s.png", "-s.png"]),
    ):
        for suf in suffixes:
            p = HGSS_SRC / f"{dex:03d}{suf}"
            if p.exists():
                out[variant] = p
                break
    return out


def follower_source(dex: int) -> dict[str, Path]:
    out = {}
    for variant in ("normal", "shiny"):
        p = FOLLOWERS_SRC / f"follower_{dex:03d}_{variant}.png"
        if p.exists():
            out[variant] = p
    return out


def water_sources(kind: str, max_dex: int = 251) -> dict[tuple[int, str], Path]:
    mapping = WATER_ROOT / kind / f"{kind}_sprite_mapping.json"
    src_dir = WATER_ROOT / kind
    if not mapping.exists():
        return {}
    data = json.loads(mapping.read_text())
    out = {}
    for entry in data.get("files") or []:
        sid = int(entry.get("speciesId") or 0)
        if sid < 1 or sid > max_dex:
            continue
        if entry.get("suffix"):
            continue
        variant = entry.get("variant") or "normal"
        if variant not in ("normal", "shiny"):
            continue
        target = entry.get("target")
        if not target:
            continue
        path = src_dir / target
        if path.exists():
            out[(sid, variant)] = path
    return out


def override_for(dex: int) -> dict:
    return dict(MANUAL_OVERRIDES.get(dex) or {})


def union_bounds(bounds_list: list[dict | None]) -> dict | None:
    valid = [b for b in bounds_list if b]
    if not valid:
        return None
    ux0 = min(b["minX"] for b in valid)
    uy0 = min(b["minY"] for b in valid)
    ux1 = max(b["maxX"] for b in valid)
    uy1 = max(b["maxY"] for b in valid)
    return {
        "minX": ux0,
        "minY": uy0,
        "maxX": ux1,
        "maxY": uy1,
        "nativeVisualWidth": ux1 - ux0,
        "nativeVisualHeight": uy1 - uy0,
    }


def hgss_variant_tiles(dex: int, layout: dict) -> dict[str, tuple[Path, list[Image.Image], int, int]]:
    """Load walker tiles per variant. Returns variant → (path, tiles, tw, th)."""
    out = {}
    cols = int(layout.get("columns", 4))
    rows = int(layout.get("rows", 4))
    for variant, src in hgss_source(dex).items():
        im = Image.open(src).convert("RGBA")
        tw, th = im.width // cols, im.height // rows
        out[variant] = (src, extract_grid_tiles(im, layout, tw, th), tw, th)
    return out


def analyze_hgss_native(dex: int, layout: dict) -> dict | None:
    variants = hgss_variant_tiles(dex, layout)
    if not variants:
        return None
    bound_list = []
    src = None
    tw = th = 0
    sheet_w = sheet_h = 0
    for variant, (path, tiles, vtw, vth) in variants.items():
        bound_list.append(shared_alpha_bounds(tiles))
        if src is None or variant == "normal":
            src = path
            tw, th = vtw, vth
            im = Image.open(path)
            sheet_w, sheet_h = im.size
    bounds = union_bounds(bound_list)
    if bounds is None:
        return None
    ov = override_for(dex)
    scale = float(ov.get("visualScale", 1.0))
    return {
        "speciesId": dex,
        "sourceImage": str(src.relative_to(ROOT)),
        "sourceSheetWidth": sheet_w,
        "sourceSheetHeight": sheet_h,
        "sourceFrameWidth": tw,
        "sourceFrameHeight": th,
        "visibleMinX": bounds["minX"],
        "visibleMaxX": bounds["maxX"],
        "visibleMinY": bounds["minY"],
        "visibleMaxY": bounds["maxY"],
        "nativeVisualWidth": bounds["nativeVisualWidth"],
        "nativeVisualHeight": bounds["nativeVisualHeight"],
        "visualScale": scale,
        "sizing": "native",
        "override": ov or None,
        "unionAcrossVariants": True,
    }


def pack_entry(fw: int, fh: int, ax: float, ay: float, pack: str) -> dict:
    return {
        "frameWidth": int(fw),
        "frameHeight": int(fh),
        "anchorX": float(ax),
        "anchorY": float(ay),
        "relativeDir": f"assets/generated/true_size/{'hgss' if pack == 'pokemmo' else pack}",
        "frames": 1 if pack == "pokedex" else 6,
        "walker": pack != "pokedex",
    }


def build_species_entry(dex: int, layout: dict, heights: dict[int, float],
                        hgss_ref: dict | None) -> dict:
    """Build one species geometry entry (native HGSS authority)."""
    ov = override_for(dex)
    height_m = float(heights.get(dex, 1.0))
    if hgss_ref is None:
        # Missing HGSS source — keep a Classic-sized placeholder pack table.
        cls = "M"
        packs = {}
        for pack in ("followers", "pokemmo", "pokedex", "swimming", "levitate"):
            packs[pack] = pack_entry(16, 16, 8.0, 16.0, pack)
        return {
            "sizing": "native",
            "class": cls,
            "heightM": height_m,
            "nativeVisualWidth": 0,
            "nativeVisualHeight": 0,
            "visualScale": float(ov.get("visualScale", 1.0)),
            "manualOverride": bool(ov),
            "missingSource": True,
            "packs": packs,
        }

    nvw = int(hgss_ref["nativeVisualWidth"])
    nvh = int(hgss_ref["nativeVisualHeight"])
    scale = float(ov.get("visualScale", 1.0))
    pad = TRUE_SIZE_PADDING
    extra_x = int(ov.get("extraPaddingX", 0) or 0)
    extra_y = int(ov.get("extraPaddingY", 0) or 0)
    ax_off = float(ov.get("anchorOffsetX", 0) or 0)
    ay_off = float(ov.get("anchorOffsetY", 0) or 0)

    # Predicted HGSS runtime geometry (matches compose_native_sheet).
    if abs(scale - 1.0) > 1e-6:
        sw = max(1, int(round(nvw * scale)))
        sh = max(1, int(round(nvh * scale)))
    else:
        sw, sh = nvw, nvh
    fw = sw + 2 * (pad + extra_x)
    fh = sh + 2 * (pad + extra_y)
    ax = fw / 2.0 + ax_off
    ay = float(pad + extra_y + sh) + ay_off

    # Perceived species size reference = scaled HGSS visible body height.
    ref_h = sh
    cls = class_from_native_height(ref_h)

    packs = {
        "pokemmo": pack_entry(fw, fh, ax, ay, "pokemmo"),
    }
    # Other packs: same perceived height; width from their own art at generate time.
    # Table stores HGSS-matched height target; width filled/updated when generated.
    for pack in ("followers", "pokedex", "swimming", "levitate"):
        # Placeholder equal to HGSS until pack generation overwrites measured size.
        packs[pack] = pack_entry(fw, fh, ax, ay, pack)

    return {
        "sizing": "native",
        "class": cls,
        "heightM": height_m,  # retained for docs only — NOT sizing authority
        "nativeVisualWidth": nvw,
        "nativeVisualHeight": nvh,
        "scaledVisualWidth": sw,
        "scaledVisualHeight": sh,
        "visualScale": scale,
        "padding": pad,
        "manualOverride": bool(ov),
        "override": ov or None,
        "missingSource": False,
        "packs": packs,
    }


def write_species_geometry_lua(table: dict[int, dict], path: Path) -> None:
    lines = [
        "-- AUTO-GENERATED by tools/generate_true_size_runtime.py — do not hand-edit.",
        "-- HGSS-native sizing: Pokédex height is NOT the primary visual authority.",
        "-- Source of truth also mirrored in assets/generated/true_size/species_geometry.json",
        "return {",
    ]
    for dex in sorted(table.keys()):
        e = table[dex]
        packs = e["packs"]
        pack_parts = []
        for pack, g in packs.items():
            pack_parts.append(
                f"{pack}={{frameWidth={g['frameWidth']},frameHeight={g['frameHeight']},"
                f"anchorX={g['anchorX']},anchorY={g['anchorY']},"
                f"frames={g['frames']},walker={'true' if g['walker'] else 'false'},"
                f"relativeDir={json.dumps(g['relativeDir'])}}}"
            )
        ov_flag = "true" if e.get("manualOverride") else "false"
        sizing = e.get("sizing") or "legacy_target_height"
        land_ref_parts = []
        if e.get("landReferenceVisibleWidth") is not None:
            land_ref_parts.append(
                f"landReferenceVisibleWidth={int(e['landReferenceVisibleWidth'])}")
        if e.get("landReferenceVisibleHeight") is not None:
            land_ref_parts.append(
                f"landReferenceVisibleHeight={int(e['landReferenceVisibleHeight'])}")
        if e.get("landReferenceVisibleArea") is not None:
            land_ref_parts.append(
                f"landReferenceVisibleArea={int(e['landReferenceVisibleArea'])}")
        land_ref_part = (",".join(land_ref_parts) + ",") if land_ref_parts else ""
        lines.append(
            f"  [{dex}]={{sizing={json.dumps(sizing)},class={json.dumps(e.get('class', 'M'))},"
            f"nativeVisualWidth={int(e.get('nativeVisualWidth') or 0)},"
            f"nativeVisualHeight={int(e.get('nativeVisualHeight') or 0)},"
            f"visualScale={float(e.get('visualScale') or 1.0)},"
            f"heightM={float(e.get('heightM') or 0)},"
            f"manualOverride={ov_flag},"
            f"{land_ref_part}"
            f"packs={{{','.join(pack_parts)}}}}},"
        )
    lines.append("}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def merge_table(existing: dict[int, dict], updates: dict[int, dict]) -> dict[int, dict]:
    out = dict(existing)
    out.update(updates)
    return out


def load_existing_table() -> dict[int, dict]:
    path = OUT_ROOT / "species_geometry.json"
    if not path.exists():
        return {}
    raw = json.loads(path.read_text())
    return {int(k): v for k, v in raw.items() if str(k).isdigit()}


def generate_hgss_for_dex(dex: int, layout: dict, entry: dict, force: bool, stats: dict,
                          manifest: dict) -> dict | None:
    out_dir = OUT_ROOT / "hgss"
    out_dir.mkdir(parents=True, exist_ok=True)
    ov = override_for(dex)
    variants = hgss_variant_tiles(dex, layout)
    if not variants:
        stats["hgss_missing"] += 1
        return None

    # One shared crop window across normal+shiny so table geometry matches every sheet.
    species_bounds = union_bounds([
        shared_alpha_bounds(tiles) for _, tiles, _, _ in variants.values()
    ])
    last_meta = None
    scale = float(ov.get("visualScale", 1.0))
    allow_nn = abs(scale - 1.0) > 1e-6

    for variant, (src, tiles, tw, th) in variants.items():
        out_name = f"{dex:03d}-{variant}.png"
        out_path = out_dir / out_name
        rel = f"assets/generated/true_size/hgss/{out_name}"
        cards, meta = compose_native_sheet(
            tiles,
            padding=TRUE_SIZE_PADDING,
            visual_scale=scale,
            extra_padding_x=int(ov.get("extraPaddingX", 0) or 0),
            extra_padding_y=int(ov.get("extraPaddingY", 0) or 0),
            anchor_offset_x=float(ov.get("anchorOffsetX", 0) or 0),
            anchor_offset_y=float(ov.get("anchorOffsetY", 0) or 0),
            allow_resample=allow_nn,
            forced_bounds=species_bounds,
        )
        fw, fh = meta["runtimeFrameWidth"], meta["runtimeFrameHeight"]
        # Species table uses the shared canvas (identical for every variant).
        entry["packs"]["pokemmo"] = pack_entry(
            fw, fh, meta["anchorX"], meta["anchorY"], "pokemmo")
        entry["nativeVisualWidth"] = meta["nativeVisualWidth"]
        entry["nativeVisualHeight"] = meta["nativeVisualHeight"]
        entry["scaledVisualWidth"] = meta["scaledVisualWidth"]
        entry["scaledVisualHeight"] = meta["scaledVisualHeight"]
        entry["class"] = class_from_native_height(meta["scaledVisualHeight"])
        entry["visualScale"] = scale
        if out_path.exists() and not force:
            manifest["sheets"][f"{dex}:{variant}"] = {
                "path": rel, "status": "cached", **{k: meta[k] for k in (
                    "runtimeFrameWidth", "runtimeFrameHeight", "nativeVisualWidth",
                    "nativeVisualHeight", "wasResized", "padding", "anchorX", "anchorY",
                )},
            }
            stats["hgss_cached"] += 1
            last_meta = meta
            continue
        sheet = stack_sheet(cards, fw, fh)
        assert sheet.size == (fw, fh * len(cards))
        sheet.save(out_path, optimize=True)
        record = {
            "speciesId": dex,
            "path": rel,
            "status": "written",
            "sourceImage": str(src.relative_to(ROOT)),
            "sourceFrameWidth": tw,
            "sourceFrameHeight": th,
            "visibleMinX": meta["visibleMinX"],
            "visibleMaxX": meta["visibleMaxX"],
            "visibleMinY": meta["visibleMinY"],
            "visibleMaxY": meta["visibleMaxY"],
            "nativeVisualWidth": meta["nativeVisualWidth"],
            "nativeVisualHeight": meta["nativeVisualHeight"],
            "runtimeFrameWidth": fw,
            "runtimeFrameHeight": fh,
            "anchorX": meta["anchorX"],
            "anchorY": meta["anchorY"],
            "padding": meta["padding"],
            "visualScale": scale,
            "wasResized": meta["wasResized"],
            "resizeReason": meta["resizeReason"],
            "resampling": meta["resampling"],
            "warning": meta.get("warning"),
            "degradedRuntimeUsedAsSource": False,
            "sizing": "native",
            "unionAcrossVariants": True,
        }
        manifest["sheets"][f"{dex}:{variant}"] = record
        stats["hgss_written"] += 1
        if meta["wasResized"]:
            stats["hgss_resized"] += 1
        else:
            stats["hgss_pad_only"] += 1
        if meta.get("warning"):
            stats["hgss_warnings"] += 1
        last_meta = meta
    return last_meta


def generate_matched_pack_for_dex(
    dex: int,
    pack: str,
    tiles: list[Image.Image],
    src: Path,
    entry: dict,
    force: bool,
    stats: dict,
    manifest: dict,
    frames: int = 6,
    *,
    reference_visible_height: int | None = None,
    land_reference: dict | None = None,
) -> None:
    """Generate a non-HGSS pack sheet fitted to HGSS perceived size.

    followers/pokedex: height fit via reference_visible_height / entry.
    swimming/levitate: LAND opaque W×H is absolute authority (height primary,
    width/area caps). Source art never independently decides species size.
    """
    out_dir = OUT_ROOT / pack
    out_dir.mkdir(parents=True, exist_ok=True)
    ov = override_for(dex)
    scale_info = None
    source_bounds = shared_alpha_bounds(tiles)
    snap = True
    resize_reason_override = None
    src_bounds = None

    if pack in ("swimming", "levitate") and land_reference:
        src_metrics = median_frame_metrics(tiles)
        if src_metrics and src_metrics["visibleWidth"] > 0 and src_metrics["visibleHeight"] > 0:
            src_bounds = {
                "visibleWidth": int(src_metrics["visibleWidth"]),
                "visibleHeight": int(src_metrics["visibleHeight"]),
                "visibleArea": int(src_metrics["opaquePixelCount"]),
                "opaquePixelCount": int(src_metrics["opaquePixelCount"]),
                "metric": "median_frame",
                "unionVisibleWidth": int(src_metrics["unionVisibleWidth"]),
                "unionVisibleHeight": int(src_metrics["unionVisibleHeight"]),
            }
        else:
            # Fallback: union crop window (legacy).
            src_bounds = {
                "visibleWidth": int((source_bounds or {}).get("nativeVisualWidth") or 16),
                "visibleHeight": int((source_bounds or {}).get("nativeVisualHeight") or 16),
            }
            src_bounds["visibleArea"] = src_bounds["visibleWidth"] * src_bounds["visibleHeight"]
            src_bounds["opaquePixelCount"] = src_bounds["visibleArea"]
            src_bounds["metric"] = "union_fallback"
        mult = float(ov.get("waterVisualScaleMultiplier", 1.0) or 1.0)
        bias = WATER_PRESENTATION_SCALE if pack == "swimming" else LEVITATE_PRESENTATION_SCALE
        scale_info = compute_land_authority_scale(
            land_reference, src_bounds, multiplier=mult, presentation_bias=bias)
        visual_scale = float(scale_info["finalVisualScale"])
        target_h = None
        ref_source = "hgss_land_median_frame"
        snap = False
        resize_reason_override = "match_hgss_land_perceived_size"
        allow_resample = True
        ref_h = int(land_reference["visibleHeight"])
        ref_w = int(land_reference["visibleWidth"])
    elif reference_visible_height is not None and int(reference_visible_height) > 0:
        ref_h = int(reference_visible_height)
        ref_w = int(land_reference["visibleWidth"]) if land_reference else 0
        ref_source = "hgss_land_opaque_height"
        visual_scale = 1.0
        target_h = ref_h
        allow_resample = True
    else:
        ref_h = int(entry.get("scaledVisualHeight") or entry.get("nativeVisualHeight") or 16)
        ref_w = int(entry.get("scaledVisualWidth") or entry.get("nativeVisualWidth") or 0)
        ref_source = "entry_scaled_visual_height"
        visual_scale = 1.0
        target_h = ref_h
        allow_resample = True

    cards, meta = compose_native_sheet(
        tiles,
        padding=TRUE_SIZE_PADDING,
        visual_scale=visual_scale,
        target_visible_height=target_h,
        allow_resample=allow_resample,
        snap_friendly_scales=snap,
        extra_padding_x=int(ov.get("extraPaddingX", 0) or 0),
        extra_padding_y=int(ov.get("extraPaddingY", 0) or 0),
        anchor_offset_x=float(ov.get("anchorOffsetX", 0) or 0),
        anchor_offset_y=float(ov.get("anchorOffsetY", 0) or 0),
    )
    if resize_reason_override and meta.get("wasResized"):
        meta["resizeReason"] = resize_reason_override
    fw, fh = meta["runtimeFrameWidth"], meta["runtimeFrameHeight"]
    if pack == "pokedex":
        cards = cards[:1]
        frames = 1
    entry["packs"][pack] = pack_entry(fw, fh, meta["anchorX"], meta["anchorY"], pack)
    if pack in ("swimming", "levitate") and land_reference:
        entry["landReferenceVisibleWidth"] = int(land_reference["visibleWidth"])
        entry["landReferenceVisibleHeight"] = int(land_reference["visibleHeight"])
        entry["landReferenceVisibleArea"] = int(land_reference["visibleArea"])
    elif pack in ("swimming", "levitate"):
        entry["landReferenceVisibleHeight"] = ref_h

    name = src.name.lower()
    if "shiny" in name or name.endswith("-s.png") or name.endswith("_s.png"):
        variant = "shiny"
    else:
        variant = "normal"

    out_name = f"{dex:03d}-{variant}.png"
    out_path = out_dir / out_name
    rel = f"assets/generated/true_size/{pack}/{out_name}"
    key = f"{dex}:{variant}"
    runtime_metrics = median_frame_metrics(cards)
    if runtime_metrics:
        runtime_w = int(runtime_metrics["visibleWidth"])
        runtime_h = int(runtime_metrics["visibleHeight"])
        runtime_area = int(runtime_metrics["opaquePixelCount"])
    else:
        opaque = opaque_bounds_union(cards)
        runtime_w = int(opaque["visibleWidth"]) if opaque else 0
        runtime_h = int(opaque["visibleHeight"]) if opaque else 0
        runtime_area = runtime_w * runtime_h
    land_w = int(land_reference["visibleWidth"]) if land_reference else ref_w
    land_h = int(land_reference["visibleHeight"]) if land_reference else ref_h
    land_area = int(land_reference.get("opaquePixelCount") or land_reference.get("visibleArea") or 0) if land_reference else max(1, land_w * land_h)
    if land_area <= 0:
        land_area = max(1, land_w * land_h)
    # Source metrics used for authority (median when available).
    src_med_w = int((src_bounds or {}).get("visibleWidth") or 0)
    src_med_h = int((src_bounds or {}).get("visibleHeight") or 0)
    src_med_a = int((src_bounds or {}).get("opaquePixelCount") or 0)
    if src_med_w <= 0 or src_med_h <= 0:
        src_med_w = int(meta.get("nativeVisualWidth") or 0)
        src_med_h = int(meta.get("nativeVisualHeight") or 0)
        src_med_a = src_med_w * src_med_h
    src_w, src_h = src_med_w, src_med_h
    src_area = src_med_a if src_med_a > 0 else (src_w * src_h)
    # Actual perceived ratio from median land vs runtime median.
    if land_w > 0 and land_h > 0 and land_area > 0 and runtime_w > 0 and runtime_h > 0 and runtime_area > 0:
        perceived_ratio = (
            WATER_HEIGHT_WEIGHT * (runtime_h / float(land_h))
            + WATER_AREA_WEIGHT * math.sqrt(runtime_area / float(land_area))
            + WATER_WIDTH_WEIGHT * (runtime_w / float(land_w))
        )
    else:
        perceived_ratio = None
    # Pre-correction perceived ratio from source medians (audit "before").
    if land_w > 0 and land_h > 0 and land_area > 0 and src_w > 0 and src_h > 0 and src_area > 0:
        perceived_before = (
            WATER_HEIGHT_WEIGHT * (src_h / float(land_h))
            + WATER_AREA_WEIGHT * math.sqrt(src_area / float(land_area))
            + WATER_WIDTH_WEIGHT * (src_w / float(land_w))
        )
    else:
        perceived_before = None
    record = {
        "speciesId": dex,
        "path": rel,
        "sourceImage": str(src.relative_to(ROOT)),
        "artFamily": "hgss_water",
        "nativeVisualWidth": meta["nativeVisualWidth"],
        "nativeVisualHeight": meta["nativeVisualHeight"],
        "scaledVisualWidth": meta["scaledVisualWidth"],
        "scaledVisualHeight": meta["scaledVisualHeight"],
        "landReferenceVisibleWidth": land_w or None,
        "landReferenceVisibleHeight": land_h or None,
        "landReferenceVisibleArea": land_area if land_w and land_h else None,
        "landReferenceUnionWidth": int((land_reference or {}).get("unionVisibleWidth") or 0) or None,
        "landReferenceUnionHeight": int((land_reference or {}).get("unionVisibleHeight") or 0) or None,
        "landReferenceMetric": (land_reference or {}).get("metric") or None,
        "sourceVisibleWidth": src_med_w or src_w,
        "sourceVisibleHeight": src_med_h or src_h,
        "sourceVisibleArea": src_area,
        "runtimeOpaqueWidth": runtime_w or None,
        "runtimeOpaqueHeight": runtime_h or None,
        "runtimeOpaqueArea": runtime_area or None,
        "perceivedRatioBefore": round(perceived_before, 4) if perceived_before is not None else None,
        "perceivedRatio": round(perceived_ratio, 4) if perceived_ratio is not None else None,
        "runtimeFrameWidth": fw,
        "runtimeFrameHeight": fh,
        "anchorX": meta["anchorX"],
        "anchorY": meta["anchorY"],
        "padding": meta["padding"],
        "visualScale": meta["scale"],
        "wasResized": meta["wasResized"],
        "resizeReason": meta["resizeReason"],
        "hgssReferenceVisibleHeight": land_h or ref_h,
        "hgssReferenceSource": ref_source,
        "frames": frames,
    }
    if scale_info:
        record.update({
            "speciesScale": scale_info.get("speciesScale"),
            "perceivedCoefficient": scale_info.get("perceivedCoefficient"),
            "perceivedTarget": scale_info.get("perceivedTarget"),
            "heightScale": scale_info["heightScale"],
            "widthLimitScale": scale_info["widthLimitScale"],
            "areaLimitScale": scale_info["areaLimitScale"],
            "presentationBias": scale_info.get("presentationBias"),
            "finalVisualScale": scale_info["finalVisualScale"],
            "widthRatio": round(runtime_w / float(max(1, land_w)), 4) if runtime_w else None,
            "heightRatio": round(runtime_h / float(max(1, land_h)), 4) if runtime_h else None,
            "areaRatio": round(runtime_area / float(max(1, land_area)), 4) if runtime_area else None,
        })
    if out_path.exists() and not force:
        record["status"] = "cached"
        manifest["sheets"][key] = record
        stats[f"{pack}_cached"] += 1
        return
    sheet = stack_sheet(cards, fw, fh)
    sheet.save(out_path, optimize=True)
    record["status"] = "written"
    manifest["sheets"][key] = record
    stats[f"{pack}_written"] += 1


def generate_followers_for_dex(dex, entry, force, stats, manifest):
    sources = follower_source(dex)
    if not sources:
        stats["followers_missing"] += 1
        return
    for variant, src in sources.items():
        im = Image.open(src).convert("RGBA")
        tiles = extract_strip_tiles(im, 6)
        # Force variant name via temp path tag — generate_matched uses src name.
        generate_matched_pack_for_dex(
            dex, "followers", tiles, src, entry, force, stats, manifest, frames=6)


def generate_pokedex_for_dex(dex, layout, entry, force, stats, manifest):
    sources = hgss_source(dex)
    if not sources:
        stats["pokedex_missing"] += 1
        return
    for variant, src in sources.items():
        im = Image.open(src).convert("RGBA")
        cols = int(layout.get("columns", 4))
        rows = int(layout.get("rows", 4))
        tw, th = im.width // cols, im.height // rows
        tiles = extract_grid_tiles(im, layout, tw, th)
        generate_matched_pack_for_dex(
            dex, "pokedex", [tiles[0]], src, entry, force, stats, manifest, frames=1)


def generate_water_for_dex(dex, kind, entry, force, stats, manifest, layout):
    pack = "levitate" if kind == "levitates" else "swimming"
    sources = water_sources(kind)
    # LAND opaque footprint is absolute size authority for water/levitate art.
    land_ref = hgss_land_reference_visible_bounds(dex)
    if land_ref is None:
        # No valid HGSS land reference — do not invent one; keep fallback.
        stats[f"{pack}_missing_land_ref"] = stats.get(f"{pack}_missing_land_ref", 0) + 1
        print(f"WARN #{dex:03d}: no HGSS land opaque reference for {pack}", flush=True)
        land_h = int(entry.get("scaledVisualHeight") or entry.get("nativeVisualHeight") or 0) or None
    else:
        land_h = int(land_ref["visibleHeight"])
    found = False
    for (sid, variant), src in sources.items():
        if sid != dex:
            continue
        found = True
        im = Image.open(src).convert("RGBA")
        tw, th = im.width // 4, im.height // 4
        tiles = extract_grid_tiles(im, layout, tw, th)
        generate_matched_pack_for_dex(
            dex, pack, tiles, src, entry, force, stats, manifest, frames=6,
            reference_visible_height=land_h,
            land_reference=land_ref,
        )
    if not found:
        stats[f"{pack}_missing"] = stats.get(f"{pack}_missing", 0) + 1


def audit_presentation_pack(pack: str, manifest: dict) -> dict:
    """Sorted perceived-size audit for swimming/levitate vs HGSS land."""
    rows = []
    warns = []
    fails = []
    for key, sheet in (manifest.get("sheets") or {}).items():
        if not key.endswith(":normal"):
            continue
        dex = int(sheet.get("speciesId") or key.split(":")[0])
        land_w = int(sheet.get("landReferenceVisibleWidth") or 0)
        land_h = int(sheet.get("landReferenceVisibleHeight") or 0)
        land_area = int(sheet.get("landReferenceVisibleArea") or (land_w * land_h) or 1)
        run_w = int(sheet.get("runtimeOpaqueWidth") or 0)
        run_h = int(sheet.get("runtimeOpaqueHeight") or 0)
        run_area = int(sheet.get("runtimeOpaqueArea") or (run_w * run_h) or 0)
        if land_w <= 0 or land_h <= 0 or run_w <= 0 or run_h <= 0 or run_area <= 0:
            continue
        wr = run_w / float(land_w)
        hr = run_h / float(land_h)
        ar = run_area / float(land_area)
        perc = sheet.get("perceivedRatio")
        if perc is None:
            perc = (
                WATER_HEIGHT_WEIGHT * hr
                + WATER_AREA_WEIGHT * math.sqrt(ar)
                + WATER_WIDTH_WEIGHT * wr
            )
        perc = float(perc)
        row = {
            "dex": dex,
            "pack": pack,
            "land": f"{land_w}x{land_h}",
            "runtime": f"{run_w}x{run_h}",
            "landVisibleWidth": land_w,
            "landVisibleHeight": land_h,
            "landOpaqueArea": land_area,
            "runtimeOpaqueWidth": run_w,
            "runtimeOpaqueHeight": run_h,
            "runtimeOpaqueArea": run_area,
            "widthRatio": round(wr, 4),
            "heightRatio": round(hr, 4),
            "areaRatio": round(ar, 4),
            "perceivedRatioBefore": sheet.get("perceivedRatioBefore"),
            "perceivedRatio": round(perc, 4),
            "perceivedAbsDeviation": round(abs(perc - 1.0), 4),
            "finalVisualScale": sheet.get("finalVisualScale"),
            "speciesScale": sheet.get("speciesScale"),
            "presentationBias": sheet.get("presentationBias"),
            "artFamily": sheet.get("artFamily"),
        }
        rows.append(row)
        reasons = []
        if run_h > land_h + WATER_HEIGHT_FAIL_PX:
            reasons.append(f"height {run_h}>{land_h}+{WATER_HEIGHT_FAIL_PX}")
        if perc > WATER_PERCEIVED_FAIL_HI:
            reasons.append(f"perceivedRatio {perc:.3f}>{WATER_PERCEIVED_FAIL_HI}")
        if ar > WATER_AREA_RATIO_FAIL:
            reasons.append(f"areaRatio {ar:.3f}>{WATER_AREA_RATIO_FAIL}")
        if reasons:
            fails.append({**row, "reasons": reasons})
        else:
            warn_reasons = []
            if perc < WATER_PERCEIVED_WARN_LO or perc > WATER_PERCEIVED_WARN_HI:
                warn_reasons.append(
                    f"perceivedRatio {perc:.3f} outside "
                    f"[{WATER_PERCEIVED_WARN_LO},{WATER_PERCEIVED_WARN_HI}]"
                )
            if wr > WATER_WIDTH_RATIO_WARN:
                warn_reasons.append(f"widthRatio {wr:.3f}>{WATER_WIDTH_RATIO_WARN}")
            if ar > WATER_AREA_RATIO_WARN:
                warn_reasons.append(f"areaRatio {ar:.3f}>{WATER_AREA_RATIO_WARN}")
            if warn_reasons:
                warns.append({**row, "reasons": warn_reasons})
    rows.sort(key=lambda r: r["perceivedAbsDeviation"], reverse=True)
    audit = {
        "pack": pack,
        "limits": {
            "perceivedTarget": WATER_PERCEIVED_TARGET,
            "perceivedWarnLo": WATER_PERCEIVED_WARN_LO,
            "perceivedWarnHi": WATER_PERCEIVED_WARN_HI,
            "perceivedFailHi": WATER_PERCEIVED_FAIL_HI,
            "widthRatioLimit": WATER_WIDTH_RATIO_LIMIT,
            "areaRatioLimit": WATER_AREA_RATIO_LIMIT,
            "widthRatioWarn": WATER_WIDTH_RATIO_WARN,
            "areaRatioWarn": WATER_AREA_RATIO_WARN,
            "areaRatioFail": WATER_AREA_RATIO_FAIL,
            "heightFailPx": WATER_HEIGHT_FAIL_PX,
            "presentationBias": WATER_PRESENTATION_SCALE if pack == "swimming" else LEVITATE_PRESENTATION_SCALE,
            "weights": {
                "height": WATER_HEIGHT_WEIGHT,
                "area": WATER_AREA_WEIGHT,
                "width": WATER_WIDTH_WEIGHT,
            },
        },
        "speciesCount": len(rows),
        "warningCount": len(warns),
        "failCount": len(fails),
        "sortedByPerceivedDeviation": rows,
        # Back-compat alias for older unit tests.
        "sortedByAreaRatio": rows,
        "warnings": warns,
        "failures": fails,
    }
    out_path = OUT_ROOT / f"{pack}_size_audit.json"
    out_path.write_text(json.dumps(audit, indent=2) + "\n")
    md_lines = [
        f"# True Size {pack} size audit",
        "",
        f"Species: {len(rows)}  Warnings: {len(warns)}  Failures: {len(fails)}",
        "",
        "| Dex | Land | Runtime | Perc before | Perc after | Scale |",
        "| --- | --- | --- | ---: | ---: | ---: |",
    ]
    for r in rows[:40]:
        md_lines.append(
            f"| {r['dex']:03d} | {r['land']} | {r['runtime']} | "
            f"{r.get('perceivedRatioBefore') or '-'} | {r['perceivedRatio']:.3f} | "
            f"{r.get('finalVisualScale')} |"
        )
    (OUT_ROOT / f"{pack}_size_audit.md").write_text("\n".join(md_lines) + "\n")
    print(
        f"AUDIT {pack}: species={len(rows)} warnings={len(warns)} failures={len(fails)} "
        f"→ {out_path.relative_to(ROOT)}",
        flush=True,
    )
    if fails:
        for f in fails[:10]:
            print(f"  FAIL #{f['dex']:03d}: {', '.join(f['reasons'])}", flush=True)
    return audit


def make_contact_sheet(species_ids, layout) -> Path:
    """Dev-only Classic | old True Size | native HGSS comparison (nearest, no smooth)."""
    DEV_OUT.mkdir(parents=True, exist_ok=True)
    cell = 48
    cols = 3
    rows = len(species_ids)
    sheet = Image.new("RGBA", (cols * cell + 8, rows * cell + 24), (32, 32, 40, 255))
    draw = ImageDraw.Draw(sheet)
    labels = ["Classic16", "OldTargetH", "NativeHGSS"]
    for i, lab in enumerate(labels):
        draw.text((i * cell + 4, 2), lab, fill=(220, 220, 220, 255))

    classic_runtime = ROOT / "assets/enhanced_overworld/followsprites_runtime"
    old_note = OUT_ROOT / "hgss"

    for r, dex in enumerate(species_ids):
        y = 18 + r * cell
        # Classic: show a 16×16-ish from runtime strip if present, else source tile.
        classic = None
        for p in (
            classic_runtime / f"{dex:03d}-b-n.png",
            classic_runtime / f"{dex:03d}-n.png",
        ):
            if p.exists():
                im = Image.open(p).convert("RGBA")
                # runtime often 16×96
                if im.height >= 16 and im.width == 16:
                    classic = im.crop((0, 0, 16, 16))
                break
        if classic is None:
            src = hgss_source(dex).get("normal")
            if src:
                im = Image.open(src).convert("RGBA")
                tw, th = im.width // 4, im.height // 4
                classic = crop_tile(im, 0, 0, tw, th).resize((16, 16), Image.Resampling.NEAREST)

        native_path = OUT_ROOT / "hgss" / f"{dex:03d}-normal.png"
        native = Image.open(native_path).convert("RGBA") if native_path.exists() else None
        if native is not None:
            fh = native.height // 6
            native_frame = native.crop((0, 0, native.width, fh))
        else:
            native_frame = None

        # Old targetHeight sheet may already have been overwritten — keep a
        # snapshot under dev/ if present; else synthesize label-only.
        old_snap = DEV_OUT / f"old_targetheight_{dex:03d}-normal.png"
        if old_snap.exists():
            old = Image.open(old_snap).convert("RGBA")
            ofh = old.height // 6
            old_frame = old.crop((0, 0, old.width, ofh))
        else:
            old_frame = None

        def paste_centered(img, col):
            if img is None:
                draw.rectangle(
                    [col * cell + 4, y + 4, col * cell + cell - 4, y + cell - 4],
                    outline=(80, 80, 90, 255),
                )
                return
            x0 = col * cell + (cell - img.width) // 2
            y0 = y + (cell - img.height) // 2
            sheet.paste(img, (x0, y0), img)

        paste_centered(classic, 0)
        paste_centered(old_frame, 1)
        paste_centered(native_frame, 2)
        draw.text((2, y + cell - 12), f"#{dex:03d}", fill=(180, 180, 200, 255))

    out = DEV_OUT / "native_hgss_prototype_contact.png"
    sheet.save(out)
    return out


def snapshot_old_targetheight(species_ids):
    """Preserve current True Size sheets before overwrite for contact-sheet compare."""
    DEV_OUT.mkdir(parents=True, exist_ok=True)
    for dex in species_ids:
        src = OUT_ROOT / "hgss" / f"{dex:03d}-normal.png"
        dst = DEV_OUT / f"old_targetheight_{dex:03d}-normal.png"
        if src.exists() and not dst.exists():
            Image.open(src).save(dst)


def write_phase_report(analyses: list[dict], stats: dict, contact: Path | None) -> None:
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# True Size — Native HGSS sizing (prototype)",
        "",
        "## Phase 1 — Source format",
        "",
        "- **Source path:** `assets/enhanced_overworld/followsprites` (NOT `followsprites_runtime`)",
        "- **Typical sheet:** 128×128 indexed/RGBA, **4×4** grid → **32×32** source frames",
        "- **Layout:** rows = directions (down/left/right/up), columns = animation frames",
        "- **Runtime walk sheet:** 6 frames (idle×3 directions + walk×3), vertical stack",
        "- **Species already differ in visible pixel size** inside the shared 32×32 cells",
        "- Source art is suitable for native-size runtime (no mandatory resize)",
        "",
        f"- Padding constant: `TRUE_SIZE_PADDING = {TRUE_SIZE_PADDING}`",
        f"- Soft warn threshold: `{SOFT_WARN_VISIBLE_PX}px` (report only, no clamp)",
        "",
        "## Shared bounds algorithm",
        "",
        "1. Extract the six walker frames from the source grid.",
        "2. Measure alpha bbox per frame.",
        "3. Take the **union** (shared minX/minY/maxX/maxY).",
        "4. Crop that **same window** from every frame.",
        "5. Paste every frame at the **same** padded offset (no per-frame centering).",
        "6. Bottom-center anchor at content feet (`anchorY = pad + contentH`).",
        "",
        "## Prototype species",
        "",
        "| Dex | Species | Source tile | Native visible | Runtime (pad=2) | Resized? | Override |",
        "|-----|---------|-------------|----------------|-----------------|----------|----------|",
    ]
    names = {19: "Rattata", 9: "Blastoise", 95: "Onix"}
    for a in analyses:
        dex = a["speciesId"]
        ov = a.get("override") or {}
        scale = float(ov.get("visualScale", a.get("visualScale", 1.0)))
        nvw, nvh = a["nativeVisualWidth"], a["nativeVisualHeight"]
        if abs(scale - 1.0) > 1e-6:
            sw, sh = int(round(nvw * scale)), int(round(nvh * scale))
            resized = f"yes NN×{scale}"
        else:
            sw, sh = nvw, nvh
            resized = "no"
        fw, fh = sw + 2 * TRUE_SIZE_PADDING, sh + 2 * TRUE_SIZE_PADDING
        lines.append(
            f"| {dex} | {names.get(dex, '?')} | {a['sourceFrameWidth']}×{a['sourceFrameHeight']} | "
            f"{nvw}×{nvh} | {fw}×{fh} | {resized} | {ov or '—'} |"
        )
    lines += [
        "",
        "## Philosophy",
        "",
        "- HGSS source artwork is the visual reference.",
        "- Pokédex real-world height is **not** the primary sizing authority.",
        "- Other packs match HGSS **visible** body height (not canvas size).",
        "- Logical footprint stays **one cell** (collision/AI/catch unchanged).",
        "- Classic + Voxel effective-Classic untouched.",
        "",
        "## Wild clipping note",
        "",
        "This refactor does **not** claim to fix Wild clipping. If a native-size",
        "Rattata still clips in Wild encounters, the bug remains in the Wild",
        "render/rebind path — do not hide it by shrinking art.",
        "",
        f"Generator stats: `{json.dumps(stats)}`",
        "",
    ]
    if contact:
        lines.append(f"Contact sheet: `{contact.relative_to(ROOT)}`")
        lines.append("")
    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_species_list(s: str | None, prototype: bool) -> list[int] | None:
    if prototype:
        return list(PROTOTYPE_SPECIES)
    if not s:
        return None  # all
    out = []
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        out.append(int(part))
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--force", action="store_true", help="Rewrite existing generated PNGs")
    ap.add_argument("--prototype", action="store_true",
                    help="Only Rattata(19), Blastoise(9), Onix(95); merge into existing table")
    ap.add_argument("--species", type=str, default=None,
                    help="Comma-separated dex ids (default: 1..--max-species)")
    ap.add_argument("--max-species", type=int, default=151,
                    help="When --species is omitted, generate 1..N (default 151). "
                         "Pass 251 to add Johto without rewriting 1..151 unless --force.")
    ap.add_argument("--pack", choices=("all", "hgss", "followers", "pokedex", "swimming", "levitate"),
                    default="all")
    ap.add_argument("--contact-sheet", action="store_true",
                    help="Write dev contact sheet for selected species")
    ap.add_argument("--analyze-only", action="store_true",
                    help="Print source analysis and exit without writing sheets")
    args = ap.parse_args(argv)

    heights_raw = json.loads(HEIGHTS_PATH.read_text()) if HEIGHTS_PATH.exists() else {}
    heights = {int(k): float(v) for k, v in heights_raw.items()}

    layout = DEFAULT_LAYOUT
    if HGSS_MAP.exists():
        layout = (json.loads(HGSS_MAP.read_text()).get("layout") or DEFAULT_LAYOUT)

    species_list = parse_species_list(args.species, args.prototype)
    if species_list is None:
        max_sp = int(args.max_species) if args.max_species else 151
        if max_sp < 1:
            max_sp = 151
        species_list = list(range(1, max_sp + 1))

    analyses = []
    for dex in species_list:
        a = analyze_hgss_native(dex, layout)
        if a:
            analyses.append(a)
            print(
                f"ANALYZE #{dex:03d}: source={a['sourceFrameWidth']}x{a['sourceFrameHeight']} "
                f"nativeVis={a['nativeVisualWidth']}x{a['nativeVisualHeight']} "
                f"scale={a['visualScale']} src={a['sourceImage']}"
            )
        else:
            print(f"ANALYZE #{dex:03d}: MISSING HGSS source", file=sys.stderr)

    if args.analyze_only:
        write_phase_report(analyses, {"analyze_only": True}, None)
        print(f"Wrote {REPORT_PATH.relative_to(ROOT)}")
        return 0

    # Snapshot old targetHeight sheets before prototype overwrite.
    if args.prototype or set(species_list) <= set(PROTOTYPE_SPECIES):
        snapshot_old_targetheight(species_list)

    # Always load the existing table so a 152..251 run cannot wipe 1..151.
    existing = load_existing_table()
    updates: dict[int, dict] = {}
    refs = {a["speciesId"]: a for a in analyses}

    for dex in species_list:
        # Keep previously generated Gen1 geometry identical unless --force.
        if (not args.force) and dex <= 151 and dex in existing:
            updates[dex] = copy.deepcopy(existing[dex])
            continue
        # Partial pack runs must keep already-measured pack geometry (e.g. do not
        # wipe followers/pokemmo when only regenerating swimming).
        if dex in existing and args.pack != "all":
            updates[dex] = copy.deepcopy(existing[dex])
            # Refresh land size authority fields from current HGSS analysis when present.
            ref = refs.get(dex)
            if ref and updates[dex].get("sizing") == "native":
                updates[dex]["nativeVisualWidth"] = ref["nativeVisualWidth"]
                updates[dex]["nativeVisualHeight"] = ref["nativeVisualHeight"]
        else:
            updates[dex] = build_species_entry(dex, layout, heights, refs.get(dex))

    stats = {k: 0 for k in (
        "hgss_written", "hgss_cached", "hgss_missing", "hgss_resized", "hgss_pad_only",
        "hgss_warnings",
        "followers_written", "followers_cached", "followers_missing",
        "pokedex_written", "pokedex_cached", "pokedex_missing",
        "swimming_written", "swimming_cached", "swimming_missing",
        "levitate_written", "levitate_cached", "levitate_missing",
    )}

    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    manifests = {}

    packs = args.pack
    if packs in ("all", "hgss"):
        man = {"schemaVersion": 2, "pack": "hgss", "sizing": "native", "padding": TRUE_SIZE_PADDING,
               "sheets": {}, "notes": [
                   "Built from ORIGINAL followsprites — not followsprites_runtime.",
                   "Native HGSS visible bounds + TRUE_SIZE_PADDING; no default resize.",
                   "Nearest-neighbor only when visualScale override or pack matching requires it.",
               ]}
        for dex in species_list:
            generate_hgss_for_dex(dex, layout, updates[dex], args.force, stats, man)
        (OUT_ROOT / "hgss" / "manifest.json").write_text(json.dumps(man, indent=2) + "\n")
        manifests["hgss"] = man

    if packs in ("all", "followers"):
        man = {"schemaVersion": 2, "pack": "followers", "sheets": {}, "notes": [
            "Visible content fitted to HGSS nativeVisualHeight (NN). Classic poke_followers untouched.",
        ]}
        for dex in species_list:
            generate_followers_for_dex(dex, updates[dex], args.force, stats, man)
        (OUT_ROOT / "followers" / "manifest.json").write_text(json.dumps(man, indent=2) + "\n")

    if packs in ("all", "pokedex"):
        man = {"schemaVersion": 2, "pack": "pokedex", "sheets": {}, "notes": [
            "1-frame stand-in from HGSS idle-down; perceived height matches HGSS native.",
        ]}
        for dex in species_list:
            generate_pokedex_for_dex(dex, layout, updates[dex], args.force, stats, man)
        (OUT_ROOT / "pokedex" / "manifest.json").write_text(json.dumps(man, indent=2) + "\n")

    if packs in ("all", "swimming"):
        man = {"schemaVersion": 2, "pack": "swimming", "sheets": {}, "notes": [
            "ORIGINAL water_sprites/swimming (HGSS/PokeMMO art family — not poke_followers).",
            "Per-species perceived-size match to HGSS LAND median frame metrics.",
            "Uniform NN scale + tiny presentation bias; never larger than land.",
        ]}
        for dex in species_list:
            generate_water_for_dex(dex, "swimming", updates[dex], args.force, stats, man, layout)
        (OUT_ROOT / "swimming" / "manifest.json").write_text(json.dumps(man, indent=2) + "\n")
        swim_audit = audit_presentation_pack("swimming", man)
        stats["swimming_audit"] = {
            "speciesCount": swim_audit["speciesCount"],
            "warningCount": swim_audit["warningCount"],
            "failCount": swim_audit["failCount"],
        }

    if packs in ("all", "levitate"):
        man = {"schemaVersion": 2, "pack": "levitate", "sheets": {}, "notes": [
            "ORIGINAL water_sprites/levitates (HGSS/PokeMMO art family — not poke_followers).",
            "Per-species perceived-size match to HGSS LAND median frame metrics.",
            "Uniform NN scale + tiny presentation bias; never larger than land.",
        ]}
        for dex in species_list:
            generate_water_for_dex(dex, "levitates", updates[dex], args.force, stats, man, layout)
        (OUT_ROOT / "levitate" / "manifest.json").write_text(json.dumps(man, indent=2) + "\n")
        lev_audit = audit_presentation_pack("levitate", man)
        stats["levitate_audit"] = {
            "speciesCount": lev_audit["speciesCount"],
            "warningCount": lev_audit["warningCount"],
            "failCount": lev_audit["failCount"],
        }

    # Merge into the existing table. Never drop 1..151 rows just because this
    # run only generated Johto ids. --force rewrites selected PNGs/rows only.
    table = merge_table(existing, updates)
    if args.prototype or len(species_list) < 151 or max(species_list) <= 151:
        for dex in range(1, 152):
            if dex not in table:
                table[dex] = build_species_entry(dex, layout, heights, analyze_hgss_native(dex, layout))
    else:
        for dex in range(1, 152):
            if dex not in table:
                table[dex] = build_species_entry(dex, layout, heights, analyze_hgss_native(dex, layout))

    (OUT_ROOT / "species_geometry.json").write_text(
        json.dumps({str(k): v for k, v in sorted(table.items())}, indent=2) + "\n"
    )
    write_species_geometry_lua(table, OUT_ROOT / "species_table.lua")

    contact = None
    if args.contact_sheet or args.prototype:
        contact = make_contact_sheet(species_list, layout)
        print(f"Contact sheet: {contact.relative_to(ROOT)}")

    write_phase_report(analyses, stats, contact)

    # Summary stats for selected set
    native_no_resize = stats["hgss_pad_only"]
    resized = stats["hgss_resized"]
    report = {
        "philosophy": "native_hgss",
        "padding": TRUE_SIZE_PADDING,
        "prototype": bool(args.prototype),
        "species": species_list,
        "stats": stats,
        "manualOverrides": sorted(MANUAL_OVERRIDES.keys()),
        "hgssNoResample": native_no_resize,
        "hgssResizedExplicit": resized,
        "analyses": [
            {
                "speciesId": a["speciesId"],
                "nativeVisualWidth": a["nativeVisualWidth"],
                "nativeVisualHeight": a["nativeVisualHeight"],
                "visualScale": a["visualScale"],
            }
            for a in analyses
        ],
    }
    (OUT_ROOT / "generation_report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    print(f"Report: {REPORT_PATH.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
