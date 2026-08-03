#!/usr/bin/env python3
"""Build Gen1Recomp-compatible 16×96 SpriteRenderer sheets from water sprites.

Reuses the same frame extraction / fit logic as generate_runtime_sprite_sheets.py
(idle down/up/left + walk down/up/left → vertical 16×96 strip).

Sources:
  assets/enhanced_overworld/water_sprites/swimming/
  assets/enhanced_overworld/water_sprites/levitates/

Outputs:
  assets/generated/water_runtime/swimming/{dex:03d}-{variant}[-form].png
  assets/generated/water_runtime/levitates/{dex:03d}-{variant}[-form].png
  assets/generated/water_runtime/manifest.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image

# Reuse shared conversion helpers from the follow-sprite generator.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_runtime_sprite_sheets import (  # noqa: E402
    CARD,
    FRAME_SPECS,
    SHEET_H,
    SHEET_W,
    build_sheet,
)

ROOT = Path(__file__).resolve().parents[1]
WATER_ROOT = ROOT / "assets/enhanced_overworld/water_sprites"
OUT_ROOT = ROOT / "assets/generated/water_runtime"

KINDS = (
    {
        "kind": "swimming",
        "mapping": WATER_ROOT / "swimming" / "swimming_sprite_mapping.json",
        "source_dir": WATER_ROOT / "swimming",
        "out_dir": OUT_ROOT / "swimming",
    },
    {
        "kind": "levitates",
        "mapping": WATER_ROOT / "levitates" / "levitates_sprite_mapping.json",
        "source_dir": WATER_ROOT / "levitates",
        "out_dir": OUT_ROOT / "levitates",
    },
)

# Same 4×4 overworld grid as follow-sprites (tile size derived from image).
DEFAULT_LAYOUT = {
    "columns": 4,
    "rows": 4,
    "directions": {"down": 0, "left": 1, "right": 2, "up": 3},
    "idleColumn": 0,
    "walkColumns": [0, 1, 2, 3],
}


def normalize_suffix(suffix) -> str | None:
    if suffix is None:
        return None
    s = str(suffix).strip()
    if not s or s.lower() in ("null", "none", "default"):
        return None
    if s.startswith("_"):
        s = s[1:]
    return s or None


def out_file_name(species_id: int, variant: str, suffix: str | None) -> str:
    base = f"{species_id:03d}-{variant}"
    if suffix:
        return f"{base}-{suffix}.png"
    return f"{base}.png"


def manifest_key(species_id: int, variant: str, kind: str, suffix: str | None) -> str:
    key = f"{species_id}:{variant}:{kind}"
    if suffix:
        key = f"{key}:{suffix}"
    return key


def infer_tile_size(src: Image.Image, columns: int = 4, rows: int = 4) -> tuple[int, int]:
    return src.width // columns, src.height // rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--max-species", type=int, default=0)
    parser.add_argument("--kind", choices=("swimming", "levitates", "all"), default="all")
    args = parser.parse_args()

    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    layout = DEFAULT_LAYOUT

    manifest = {
        "schemaVersion": 1,
        "format": "gen1recomp-water-sprite-renderer-sheet",
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
        "waterSpriteOrder": ["swimming", "levitates"],
        "scale": "visible-bounds fit, nearest-neighbor, bottom-center, shared per sheet",
        "sheets": {},
    }

    written = 0
    skipped = 0
    errors = 0
    kinds = KINDS if args.kind == "all" else [k for k in KINDS if k["kind"] == args.kind]

    for spec in kinds:
        kind = spec["kind"]
        mapping_path = spec["mapping"]
        if not mapping_path.is_file():
            print(f"error: mapping missing: {mapping_path}", file=sys.stderr)
            return 1
        data = json.loads(mapping_path.read_text(encoding="utf-8"))
        files = data.get("files") or []
        preferred = data.get("preferredWaterKind")  # optional top-level
        species_pref = {}
        if isinstance(data.get("speciesPreferred"), dict):
            species_pref = data["speciesPreferred"]

        out_dir = spec["out_dir"]
        out_dir.mkdir(parents=True, exist_ok=True)
        source_dir = spec["source_dir"]

        for entry in files:
            if not isinstance(entry, dict):
                continue
            sid = entry.get("speciesId")
            try:
                sid = int(sid)
            except (TypeError, ValueError):
                errors += 1
                print(f"error: non-numeric speciesId in {kind}: {entry}", file=sys.stderr)
                continue
            if args.max_species and sid > args.max_species:
                continue

            variant = str(entry.get("variant") or "normal").lower()
            if variant not in ("normal", "shiny"):
                errors += 1
                print(f"error: bad variant {variant} for {sid} {kind}", file=sys.stderr)
                continue

            suffix = normalize_suffix(entry.get("suffix"))
            target = entry.get("target")
            if not target:
                errors += 1
                continue

            src_path = source_dir / target
            out_name = out_file_name(sid, variant, suffix)
            out_path = out_dir / out_name
            rel_out = f"assets/generated/water_runtime/{kind}/{out_name}"
            key = manifest_key(sid, variant, kind, suffix)

            pref_kind = None
            if isinstance(entry.get("preferredWaterKind"), str):
                pref_kind = entry["preferredWaterKind"]
            elif preferred:
                pref_kind = preferred
            elif str(sid) in species_pref:
                pref_kind = species_pref[str(sid)]

            if out_path.is_file() and not args.force:
                skipped += 1
                manifest["sheets"][key] = {
                    "speciesId": sid,
                    "variant": variant,
                    "kind": kind,
                    "form": suffix,
                    "path": rel_out,
                    "source": f"assets/enhanced_overworld/water_sprites/{kind}/{target}",
                    "status": "cached",
                    "frames": 6,
                    "width": SHEET_W,
                    "height": SHEET_H,
                    "preferredWaterKind": pref_kind,
                }
                continue

            if not src_path.is_file():
                print(f"warn: missing source {src_path}", file=sys.stderr)
                errors += 1
                continue

            try:
                with Image.open(src_path) as probe:
                    tw, th = infer_tile_size(probe, layout["columns"], layout["rows"])
                sheet = build_sheet(src_path, layout, tw, th)
                assert sheet.size == (SHEET_W, SHEET_H), sheet.size
                sheet.save(out_path, optimize=True)
                written += 1
                manifest["sheets"][key] = {
                    "speciesId": sid,
                    "variant": variant,
                    "kind": kind,
                    "form": suffix,
                    "path": rel_out,
                    "source": f"assets/enhanced_overworld/water_sprites/{kind}/{target}",
                    "status": "written",
                    "frames": 6,
                    "width": SHEET_W,
                    "height": SHEET_H,
                    "preferredWaterKind": pref_kind,
                }
            except Exception as exc:  # noqa: BLE001
                print(f"error: {kind} {sid} {variant} {suffix}: {exc}", file=sys.stderr)
                errors += 1

    man_path = OUT_ROOT / "manifest.json"
    man_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        f"water runtime sheets: written={written} cached={skipped} errors={errors} "
        f"sheets={len(manifest['sheets'])} out={OUT_ROOT}"
    )
    return 0 if errors == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
