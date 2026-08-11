#!/usr/bin/env python3
"""Generate True Size runtime SpriteRenderer sheets for Wilds of Kanto.

Sources (never Classic degraded 16×16 runtime):
  HGSS:      assets/enhanced_overworld/followsprites
  Followers: assets/enhanced_overworld/poke_followers (16×96 → NN upscale into canvas)
  Pokédex:   HGSS idle-down stand-in (1-frame) when battle fronts are unavailable
  Swimming / Levitates: assets/enhanced_overworld/water_sprites/{kind}

Outputs under assets/generated/true_size/{pack}/ plus species_geometry.json.

Nearest-neighbor only. Shared bbox / bottom baseline per species sheet.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
HEIGHTS_PATH = ROOT / "tools/gen1_heights.json"
HGSS_SRC = ROOT / "assets/enhanced_overworld/followsprites"
HGSS_MAP = ROOT / "assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json"
FOLLOWERS_SRC = ROOT / "assets/enhanced_overworld/poke_followers"
WATER_ROOT = ROOT / "assets/enhanced_overworld/water_sprites"
OUT_ROOT = ROOT / "assets/generated/true_size"

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

# Manual art-direction overrides (dex → fields).
MANUAL_OVERRIDES = {
    10: {"class": "XS", "targetHeight": 15},   # Caterpie
    13: {"class": "XS", "targetHeight": 15},   # Weedle
    23: {"class": "L", "targetHeight": 28, "targetWidth": 30},  # Ekans
    24: {"class": "XL", "targetHeight": 32, "targetWidth": 34},  # Arbok
    25: {"class": "S", "targetHeight": 18},    # Pikachu
    50: {"class": "XS", "targetHeight": 14},   # Diglett
    51: {"class": "S", "targetHeight": 18},    # Dugtrio
    92: {"class": "M", "targetHeight": 22},    # Gastly
    93: {"class": "L", "targetHeight": 26},    # Haunter
    95: {"class": "XXL", "targetHeight": 40, "targetWidth": 28},  # Onix (tall, not absurdly long)
    102: {"class": "S", "targetHeight": 18},   # Exeggcute
    115: {"class": "XL", "targetHeight": 34},  # Kangaskhan
    128: {"class": "L", "targetHeight": 28, "targetWidth": 32},  # Tauros
    129: {"class": "S", "targetHeight": 18},   # Magikarp
    130: {"class": "XXL", "targetHeight": 40, "targetWidth": 36},  # Gyarados
    131: {"class": "XL", "targetHeight": 34, "targetWidth": 34},  # Lapras
    143: {"class": "XXL", "targetHeight": 38, "targetWidth": 36},  # Snorlax
    142: {"class": "XL", "targetHeight": 32},  # Aerodactyl
    149: {"class": "XL", "targetHeight": 34},  # Dragonite
    150: {"class": "XL", "targetHeight": 34},  # Mewtwo
    6: {"class": "XL", "targetHeight": 32},    # Charizard reference
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
    """Vertical 16×96 (or similar) walker strip → per-frame tiles."""
    fw = src.width
    fh = src.height // frames
    tiles = []
    for i in range(frames):
        tiles.append(src.crop((0, i * fh, fw, (i + 1) * fh)).convert("RGBA"))
    return tiles


def fit_to_canvas(tiles: list[Image.Image], frame_w: int, frame_h: int):
    boxes = [visible_bounds(t) for t in tiles]
    if not any(boxes):
        empty = [Image.new("RGBA", (frame_w, frame_h), (0, 0, 0, 0)) for _ in tiles]
        return empty, {"method": "empty", "scale": 1.0, "resized": False}

    ux0 = min(b[0] for b in boxes if b)
    uy0 = min(b[1] for b in boxes if b)
    ux1 = max(b[2] for b in boxes if b)
    uy1 = max(b[3] for b in boxes if b)
    cw = max(1, ux1 - ux0)
    ch = max(1, uy1 - uy0)

    # Prefer pad-only when content fits; else NN downscale OR upscale to fill height.
    # Reserve 1px top breathing room when bottom-aligning (avoids flush-to-top
    # ear tips that look clipped under grass / neighboring tile overdraw).
    usable_h = (frame_h - 1) if frame_h >= 16 else frame_h
    usable_h = max(1, usable_h)
    scale = min(frame_w / cw, usable_h / ch)
    # Prefer integer scales when close.
    for candidate in (2.0, 1.5, 1.0, 0.5):
        if abs(scale - candidate) <= 0.08 and cw * candidate <= frame_w and ch * candidate <= usable_h:
            scale = candidate
            break
    if scale > 1.0:
        # Prefer integer upscale for pixel art.
        iscale = max(1, int(math.floor(scale + 1e-6)))
        if cw * iscale <= frame_w and ch * iscale <= usable_h:
            scale = float(iscale)

    resized = abs(scale - 1.0) > 1e-6
    cards = []
    for tile, bbox in zip(tiles, boxes):
        card = Image.new("RGBA", (frame_w, frame_h), (0, 0, 0, 0))
        if bbox is None:
            cards.append(card)
            continue
        window = tile.crop((ux0, uy0, ux1, uy1))
        if resized:
            nw = max(1, int(round(cw * scale)))
            nh = max(1, int(round(ch * scale)))
            window = window.resize((nw, nh), Image.Resampling.NEAREST)
        else:
            nw, nh = window.size
        dx = (frame_w - nw) // 2
        dy = frame_h - nh
        card.paste(window, (dx, dy), window)
        cards.append(card)

    return cards, {
        "method": "shared_bbox_nearest_pad" if not resized else "shared_bbox_nearest_scale",
        "scale": round(scale, 4),
        "resized": resized,
        "contentWidth": cw,
        "contentHeight": ch,
        "resampling": "nearest" if resized else "none",
    }


def stack_sheet(cards: list[Image.Image], frame_w: int, frame_h: int) -> Image.Image:
    sheet = Image.new("RGBA", (frame_w, frame_h * len(cards)), (0, 0, 0, 0))
    for i, card in enumerate(cards):
        sheet.paste(card, (0, i * frame_h), card)
    return sheet


def compressed_target(height_m: float) -> tuple[str, int]:
    """Compressed true-to-size → (class, targetHeight px)."""
    h = max(0.1, float(height_m))
    # Smooth compression toward ~14..42
    # t in (0,1): 1 - 1/(1+h)
    t = 1.0 - 1.0 / (1.0 + h * 0.85)
    target = int(round(14 + t * (42 - 14)))
    target = max(14, min(42, target))
    if target <= 16:
        cls = "XS"
    elif target <= 20:
        cls = "S"
    elif target <= 24:
        cls = "M"
    elif target <= 29:
        cls = "L"
    elif target <= 35:
        cls = "XL"
    else:
        cls = "XXL"
    return cls, target


def pack_frame_geometry(target_h: int, target_w: int | None, pack: str) -> dict:
    h = int(target_h)
    w = int(target_w or max(16, min(42, int(round(h * 0.95)))))
    # Pack aspect tweaks (same visual height).
    if pack == "followers":
        w = max(16, min(42, int(round(h * 0.90))))
    elif pack == "pokedex":
        w = max(16, min(42, int(round(h * 0.85))))
        # 1-frame stand-in still uses same canvas height.
    elif pack in ("swimming", "levitate"):
        w = max(16, min(42, int(round(h * 1.0))))
    elif pack == "pokemmo" or pack == "hgss":
        w = max(16, min(42, int(round(h * 1.0))))
    return {
        "frameWidth": w,
        "frameHeight": h,
        "anchorX": w / 2,
        "anchorY": h,
    }


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
            # Prefer default form for Gen1 coverage report.
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


def build_species_table(heights: dict[int, float]) -> dict[int, dict]:
    table = {}
    for dex in range(1, 152):
        h = heights.get(dex, 1.0)
        cls, th = compressed_target(h)
        tw = None
        ov = MANUAL_OVERRIDES.get(dex)
        if ov:
            cls = ov.get("class", cls)
            th = int(ov.get("targetHeight", th))
            tw = ov.get("targetWidth")
        packs = {}
        for pack in ("followers", "pokemmo", "pokedex", "swimming", "levitate"):
            geo = pack_frame_geometry(th, tw, pack)
            packs[pack] = {
                **geo,
                "relativeDir": f"assets/generated/true_size/{'hgss' if pack == 'pokemmo' else pack}",
                "frames": 1 if pack == "pokedex" else 6,
                "walker": pack != "pokedex",
            }
        table[dex] = {
            "class": cls,
            "targetHeight": th,
            "heightM": h,
            "manualOverride": ov is not None,
            "packs": packs,
        }
    return table


def write_species_geometry_lua(table: dict[int, dict], path: Path) -> None:
    """Emit a compact Lua module body for SPECIES table (data-driven)."""
    lines = [
        "-- AUTO-GENERATED by tools/generate_true_size_runtime.py — do not hand-edit.",
        "-- Source of truth also mirrored in assets/generated/true_size/species_geometry.json",
        "return {",
    ]
    for dex in range(1, 152):
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
        lines.append(
            f"  [{dex}]={{class={json.dumps(e['class'])},targetHeight={e['targetHeight']},"
            f"heightM={e['heightM']},manualOverride={'true' if e['manualOverride'] else 'false'},"
            f"packs={{{','.join(pack_parts)}}}}},"
        )
    lines.append("}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def generate_pack_hgss(table, layout, force: bool, stats: dict) -> None:
    out_dir = OUT_ROOT / "hgss"
    out_dir.mkdir(parents=True, exist_ok=True)
    man = {"schemaVersion": 1, "pack": "hgss", "sheets": {}, "notes": [
        "Built from ORIGINAL followsprites — not followsprites_runtime.",
        "Nearest-neighbor; shared bbox; bottom-center anchor.",
    ]}
    for dex in range(1, 152):
        geo = table[dex]["packs"]["pokemmo"]
        fw, fh = geo["frameWidth"], geo["frameHeight"]
        sources = hgss_source(dex)
        for variant, src in sources.items():
            out_name = f"{dex:03d}-{variant}.png"
            out_path = out_dir / out_name
            rel = f"assets/generated/true_size/hgss/{out_name}"
            if out_path.exists() and not force:
                man["sheets"][f"{dex}:{variant}"] = {
                    "path": rel, "status": "cached",
                    "frameWidth": fw, "frameHeight": fh,
                }
                stats["hgss_cached"] += 1
                continue
            im = Image.open(src).convert("RGBA")
            cols = int(layout.get("columns", 4))
            rows = int(layout.get("rows", 4))
            tw, th = im.width // cols, im.height // rows
            tiles = extract_grid_tiles(im, layout, tw, th)
            cards, meta = fit_to_canvas(tiles, fw, fh)
            sheet = stack_sheet(cards, fw, fh)
            assert sheet.size == (fw, fh * 6)
            sheet.save(out_path, optimize=True)
            man["sheets"][f"{dex}:{variant}"] = {
                "path": rel, "status": "written", "source": str(src.relative_to(ROOT)),
                "frameWidth": fw, "frameHeight": fh, "anchorX": geo["anchorX"],
                "anchorY": geo["anchorY"], **meta,
                "degradedRuntimeUsedAsSource": False,
            }
            stats["hgss_written"] += 1
            if meta.get("resized"):
                stats["hgss_resized"] += 1
            else:
                stats["hgss_pad_only"] += 1
        if not sources:
            stats["hgss_missing"] += 1
    (out_dir / "manifest.json").write_text(json.dumps(man, indent=2) + "\n")


def generate_pack_followers(table, force: bool, stats: dict) -> None:
    out_dir = OUT_ROOT / "followers"
    out_dir.mkdir(parents=True, exist_ok=True)
    man = {"schemaVersion": 1, "pack": "followers", "sheets": {}, "notes": [
        "Built from poke_followers 16×96 strips via NN into variable canvases.",
        "Classic poke_followers assets are never overwritten.",
    ]}
    for dex in range(1, 152):
        geo = table[dex]["packs"]["followers"]
        fw, fh = geo["frameWidth"], geo["frameHeight"]
        sources = follower_source(dex)
        for variant, src in sources.items():
            out_name = f"{dex:03d}-{variant}.png"
            out_path = out_dir / out_name
            rel = f"assets/generated/true_size/followers/{out_name}"
            if out_path.exists() and not force:
                man["sheets"][f"{dex}:{variant}"] = {
                    "path": rel, "status": "cached",
                    "frameWidth": fw, "frameHeight": fh,
                }
                stats["followers_cached"] += 1
                continue
            im = Image.open(src).convert("RGBA")
            tiles = extract_strip_tiles(im, 6)
            cards, meta = fit_to_canvas(tiles, fw, fh)
            sheet = stack_sheet(cards, fw, fh)
            sheet.save(out_path, optimize=True)
            man["sheets"][f"{dex}:{variant}"] = {
                "path": rel, "status": "written", "source": str(src.relative_to(ROOT)),
                "frameWidth": fw, "frameHeight": fh, **meta,
            }
            stats["followers_written"] += 1
        if not sources:
            stats["followers_missing"] += 1
    (out_dir / "manifest.json").write_text(json.dumps(man, indent=2) + "\n")


def generate_pack_pokedex(table, layout, force: bool, stats: dict) -> None:
    """1-frame stand-in from HGSS idle-down (battle fronts not shipped in-repo)."""
    out_dir = OUT_ROOT / "pokedex"
    out_dir.mkdir(parents=True, exist_ok=True)
    man = {"schemaVersion": 1, "pack": "pokedex", "sheets": {}, "notes": [
        "1-frame True Size stand-in from HGSS idle-down (battle fronts not in repo).",
        "Falls back to Classic pokedex battle-front if sheet missing at runtime.",
    ]}
    for dex in range(1, 152):
        geo = table[dex]["packs"]["pokedex"]
        fw, fh = geo["frameWidth"], geo["frameHeight"]
        sources = hgss_source(dex)
        for variant, src in list(sources.items()):
            out_name = f"{dex:03d}-{variant}.png"
            out_path = out_dir / out_name
            rel = f"assets/generated/true_size/pokedex/{out_name}"
            if out_path.exists() and not force:
                man["sheets"][f"{dex}:{variant}"] = {
                    "path": rel, "status": "cached",
                    "frameWidth": fw, "frameHeight": fh, "frames": 1,
                }
                stats["pokedex_cached"] += 1
                continue
            im = Image.open(src).convert("RGBA")
            cols = int(layout.get("columns", 4))
            rows = int(layout.get("rows", 4))
            tw, th = im.width // cols, im.height // rows
            tiles = extract_grid_tiles(im, layout, tw, th)
            idle_down = [tiles[0]]
            cards, meta = fit_to_canvas(idle_down, fw, fh)
            sheet = stack_sheet(cards, fw, fh)
            assert sheet.size == (fw, fh)
            sheet.save(out_path, optimize=True)
            man["sheets"][f"{dex}:{variant}"] = {
                "path": rel, "status": "written", "source": str(src.relative_to(ROOT)),
                "frameWidth": fw, "frameHeight": fh, "frames": 1, **meta,
            }
            stats["pokedex_written"] += 1
        if not sources:
            stats["pokedex_missing"] += 1
    (out_dir / "manifest.json").write_text(json.dumps(man, indent=2) + "\n")


def generate_pack_water(table, kind: str, force: bool, stats: dict) -> None:
    pack = "levitate" if kind == "levitates" else "swimming"
    out_dir = OUT_ROOT / pack
    out_dir.mkdir(parents=True, exist_ok=True)
    man = {"schemaVersion": 1, "pack": pack, "kind": kind, "sheets": {}, "notes": [
        f"Built from ORIGINAL water_sprites/{kind} — not water_runtime 16×16.",
    ]}
    sources = water_sources(kind)
    layout = DEFAULT_LAYOUT
    covered = set()
    for (dex, variant), src in sorted(sources.items()):
        covered.add(dex)
        geo = table[dex]["packs"][pack]
        fw, fh = geo["frameWidth"], geo["frameHeight"]
        out_name = f"{dex:03d}-{variant}.png"
        out_path = out_dir / out_name
        rel = f"assets/generated/true_size/{pack}/{out_name}"
        if out_path.exists() and not force:
            man["sheets"][f"{dex}:{variant}"] = {
                "path": rel, "status": "cached",
                "frameWidth": fw, "frameHeight": fh,
            }
            stats[f"{pack}_cached"] += 1
            continue
        im = Image.open(src).convert("RGBA")
        tw, th = im.width // 4, im.height // 4
        tiles = extract_grid_tiles(im, layout, tw, th)
        cards, meta = fit_to_canvas(tiles, fw, fh)
        sheet = stack_sheet(cards, fw, fh)
        sheet.save(out_path, optimize=True)
        man["sheets"][f"{dex}:{variant}"] = {
            "path": rel, "status": "written", "source": str(src.relative_to(ROOT)),
            "frameWidth": fw, "frameHeight": fh, **meta,
            "degradedRuntimeUsedAsSource": False,
        }
        stats[f"{pack}_written"] += 1
    stats[f"{pack}_species"] = len(covered)
    (out_dir / "manifest.json").write_text(json.dumps(man, indent=2) + "\n")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--pack", choices=("all", "hgss", "followers", "pokedex", "swimming", "levitate"),
                    default="all")
    args = ap.parse_args(argv)

    heights_raw = json.loads(HEIGHTS_PATH.read_text())
    heights = {int(k): float(v) for k, v in heights_raw.items()}
    table = build_species_table(heights)

    layout = DEFAULT_LAYOUT
    if HGSS_MAP.exists():
        layout = (json.loads(HGSS_MAP.read_text()).get("layout") or DEFAULT_LAYOUT)

    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    (OUT_ROOT / "species_geometry.json").write_text(
        json.dumps({str(k): v for k, v in table.items()}, indent=2) + "\n"
    )
    write_species_geometry_lua(table, OUT_ROOT / "species_table.lua")

    stats = {k: 0 for k in (
        "hgss_written", "hgss_cached", "hgss_missing", "hgss_resized", "hgss_pad_only",
        "followers_written", "followers_cached", "followers_missing",
        "pokedex_written", "pokedex_cached", "pokedex_missing",
        "swimming_written", "swimming_cached", "levitate_written", "levitate_cached",
        "swimming_species", "levitate_species",
    )}

    packs = args.pack
    if packs in ("all", "hgss"):
        generate_pack_hgss(table, layout, args.force, stats)
    if packs in ("all", "followers"):
        generate_pack_followers(table, args.force, stats)
    if packs in ("all", "pokedex"):
        generate_pack_pokedex(table, layout, args.force, stats)
    if packs in ("all", "swimming"):
        generate_pack_water(table, "swimming", args.force, stats)
    if packs in ("all", "levitate"):
        generate_pack_water(table, "levitates", args.force, stats)

    # Class distribution
    dist = {}
    for dex, e in table.items():
        dist[e["class"]] = dist.get(e["class"], 0) + 1
    report = {
        "stats": stats,
        "sizeClassDistribution": dist,
        "manualOverrides": sorted(MANUAL_OVERRIDES.keys()),
        "speciesCount": 151,
    }
    (OUT_ROOT / "generation_report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
