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
        # Prefer integer scales when close (pixel-art friendly).
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


def water_sources(kind: str, max_dex: int = 151) -> dict[tuple[int, str], Path]:
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
        lines.append(
            f"  [{dex}]={{sizing={json.dumps(sizing)},class={json.dumps(e.get('class', 'M'))},"
            f"nativeVisualWidth={int(e.get('nativeVisualWidth') or 0)},"
            f"nativeVisualHeight={int(e.get('nativeVisualHeight') or 0)},"
            f"visualScale={float(e.get('visualScale') or 1.0)},"
            f"heightM={float(e.get('heightM') or 0)},"
            f"manualOverride={ov_flag},"
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
) -> None:
    """Generate a non-HGSS pack sheet fitted to HGSS perceived visible height."""
    out_dir = OUT_ROOT / pack
    out_dir.mkdir(parents=True, exist_ok=True)
    ref_h = int(entry.get("scaledVisualHeight") or entry.get("nativeVisualHeight") or 16)
    ov = override_for(dex)
    # Match HGSS visible body height; pack-specific canvas follows content.
    cards, meta = compose_native_sheet(
        tiles,
        padding=TRUE_SIZE_PADDING,
        visual_scale=1.0,
        target_visible_height=ref_h,
        allow_resample=True,
        extra_padding_x=int(ov.get("extraPaddingX", 0) or 0),
        extra_padding_y=int(ov.get("extraPaddingY", 0) or 0),
        anchor_offset_x=float(ov.get("anchorOffsetX", 0) or 0),
        anchor_offset_y=float(ov.get("anchorOffsetY", 0) or 0),
    )
    fw, fh = meta["runtimeFrameWidth"], meta["runtimeFrameHeight"]
    if pack == "pokedex":
        cards = cards[:1]
        frames = 1
    entry["packs"][pack] = pack_entry(fw, fh, meta["anchorX"], meta["anchorY"], pack)

    name = src.name.lower()
    if "shiny" in name or name.endswith("-s.png") or name.endswith("_s.png"):
        variant = "shiny"
    else:
        variant = "normal"

    out_name = f"{dex:03d}-{variant}.png"
    out_path = out_dir / out_name
    rel = f"assets/generated/true_size/{pack}/{out_name}"
    key = f"{dex}:{variant}"
    if out_path.exists() and not force:
        manifest["sheets"][key] = {
            "path": rel, "status": "cached",
            "runtimeFrameWidth": fw, "runtimeFrameHeight": fh,
        }
        stats[f"{pack}_cached"] += 1
        return
    sheet = stack_sheet(cards, fw, fh)
    sheet.save(out_path, optimize=True)
    manifest["sheets"][key] = {
        "speciesId": dex,
        "path": rel,
        "status": "written",
        "sourceImage": str(src.relative_to(ROOT)),
        "nativeVisualWidth": meta["nativeVisualWidth"],
        "nativeVisualHeight": meta["nativeVisualHeight"],
        "runtimeFrameWidth": fw,
        "runtimeFrameHeight": fh,
        "anchorX": meta["anchorX"],
        "anchorY": meta["anchorY"],
        "padding": meta["padding"],
        "visualScale": meta["scale"],
        "wasResized": meta["wasResized"],
        "resizeReason": meta["resizeReason"],
        "hgssReferenceVisibleHeight": ref_h,
        "frames": frames,
    }
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
    found = False
    for (sid, variant), src in sources.items():
        if sid != dex:
            continue
        found = True
        im = Image.open(src).convert("RGBA")
        tw, th = im.width // 4, im.height // 4
        tiles = extract_grid_tiles(im, layout, tw, th)
        generate_matched_pack_for_dex(
            dex, pack, tiles, src, entry, force, stats, manifest, frames=6)
    if not found:
        stats[f"{pack}_missing"] = stats.get(f"{pack}_missing", 0) + 1


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
                    help="Comma-separated dex ids (default: all 1..151)")
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
        species_list = list(range(1, 152))

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

    existing = load_existing_table() if (args.prototype or len(species_list) < 151) else {}
    updates: dict[int, dict] = {}
    refs = {a["speciesId"]: a for a in analyses}

    for dex in species_list:
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
            "ORIGINAL water_sprites/swimming; visible scale matched to HGSS land reference.",
        ]}
        for dex in species_list:
            generate_water_for_dex(dex, "swimming", updates[dex], args.force, stats, man, layout)
        (OUT_ROOT / "swimming" / "manifest.json").write_text(json.dumps(man, indent=2) + "\n")

    if packs in ("all", "levitate"):
        man = {"schemaVersion": 2, "pack": "levitate", "sheets": {}, "notes": [
            "ORIGINAL water_sprites/levitates; visible scale matched to HGSS land reference.",
        ]}
        for dex in species_list:
            generate_water_for_dex(dex, "levitates", updates[dex], args.force, stats, man, layout)
        (OUT_ROOT / "levitate" / "manifest.json").write_text(json.dumps(man, indent=2) + "\n")

    # Merge prototype updates into full table; for full runs replace entirely.
    if args.prototype or len(species_list) < 151:
        table = merge_table(existing, updates)
        # Ensure all 1..151 keys exist
        for dex in range(1, 152):
            if dex not in table:
                table[dex] = build_species_entry(dex, layout, heights, analyze_hgss_native(dex, layout))
    else:
        table = updates
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
