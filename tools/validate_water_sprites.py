#!/usr/bin/env python3
"""Validate swimming / levitates water sprite mappings and runtime sheets."""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
WATER_ROOT = ROOT / "assets/enhanced_overworld/water_sprites"
RUNTIME_ROOT = ROOT / "assets/generated/water_runtime"

KINDS = {
    "swimming": {
        "prefix": "swimming_",
        "mapping": WATER_ROOT / "swimming" / "swimming_sprite_mapping.json",
        "source": WATER_ROOT / "swimming",
    },
    "levitates": {
        "prefix": "levitates_",
        "mapping": WATER_ROOT / "levitates" / "levitates_sprite_mapping.json",
        "source": WATER_ROOT / "levitates",
    },
}

NAME_RE = re.compile(
    r"^(swimming|levitates)_(\d+)-b-([ns])(?:_(.+))?\.png$",
    re.IGNORECASE,
)


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        fail(f"mapping JSON unreadable: {path}: {exc}")
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict", action="store_true", default=True)
    args = parser.parse_args()

    errors: list[str] = []
    warnings: list[str] = []
    stats = {
        "swimming_mapped": 0,
        "levitates_mapped": 0,
        "normal": 0,
        "shiny": 0,
        "unique_species": set(),
        "missing_files": 0,
        "invalid_sheets": 0,
        "generated_runtime_sheets": 0,
    }

    seen_keys: dict[str, set[tuple]] = defaultdict(set)

    for kind, meta in KINDS.items():
        if not meta["mapping"].is_file():
            errors.append(f"missing mapping: {meta['mapping']}")
            continue
        data = load_json(meta["mapping"])
        if data.get("prefix") and data["prefix"] != meta["prefix"]:
            errors.append(f"{kind}: prefix mismatch {data.get('prefix')!r}")
        files = data.get("files") or []
        for entry in files:
            if not isinstance(entry, dict):
                errors.append(f"{kind}: non-object file entry")
                continue
            sid = entry.get("speciesId")
            if not isinstance(sid, int) and not (isinstance(sid, str) and sid.isdigit()):
                errors.append(f"{kind}: non-numeric speciesId {sid!r}")
                continue
            sid = int(sid)
            variant = str(entry.get("variant") or "").lower()
            if variant not in ("normal", "shiny"):
                errors.append(f"{kind} {sid}: bad variant {variant!r}")
                continue
            suffix = entry.get("suffix")
            if suffix is not None:
                suffix = str(suffix)
            target = entry.get("target")
            if not isinstance(target, str) or not target:
                errors.append(f"{kind} {sid}: missing target")
                continue
            src = meta["source"] / target
            if not src.is_file():
                stats["missing_files"] += 1
                errors.append(f"missing file: {src.relative_to(ROOT)}")
                continue

            # Filename schema check
            name = Path(target).name
            m = NAME_RE.match(name)
            if not m:
                warnings.append(f"filename schema odd: {name}")
            else:
                if m.group(1).lower() != kind:
                    errors.append(f"prefix mismatch in {name}")
                if int(m.group(2)) != sid:
                    errors.append(f"speciesId mismatch in {name}")
                expect_var = "n" if variant == "normal" else "s"
                if m.group(3).lower() != expect_var:
                    errors.append(f"variant letter mismatch in {name}")

            key = (sid, variant, suffix)
            if key in seen_keys[kind]:
                errors.append(f"duplicate {kind} key {key}")
            seen_keys[kind].add(key)

            try:
                with Image.open(src) as im:
                    im.load()
                    if im.width % 4 != 0 or im.height % 4 != 0:
                        errors.append(f"source grid not 4x4 divisible: {src.name} {im.size}")
            except Exception as exc:  # noqa: BLE001
                errors.append(f"PNG unreadable: {src}: {exc}")

            stats[f"{kind}_mapped"] += 1
            stats[variant] += 1
            stats["unique_species"].add(sid)

    # Runtime sheets + manifest
    man_path = RUNTIME_ROOT / "manifest.json"
    if not man_path.is_file():
        errors.append(f"missing runtime manifest: {man_path}")
    else:
        man = load_json(man_path)
        sheets = man.get("sheets") or {}
        stats["generated_runtime_sheets"] = len(sheets)
        for key, entry in sheets.items():
            path = ROOT / entry.get("path", "")
            if not path.is_file():
                stats["invalid_sheets"] += 1
                errors.append(f"manifest path missing: {entry.get('path')}")
                continue
            try:
                with Image.open(path) as im:
                    if im.size != (16, 96):
                        stats["invalid_sheets"] += 1
                        errors.append(f"sheet not 16x96: {path.name} {im.size}")
                    else:
                        # Six non-empty frames preferred (warn only if all empty)
                        empty = 0
                        for i in range(6):
                            tile = im.crop((0, i * 16, 16, (i + 1) * 16))
                            if tile.getchannel("A").getbbox() is None:
                                empty += 1
                        if empty == 6:
                            stats["invalid_sheets"] += 1
                            errors.append(f"all frames empty: {path.name}")
            except Exception as exc:  # noqa: BLE001
                stats["invalid_sheets"] += 1
                errors.append(f"runtime PNG unreadable: {path}: {exc}")

    print(f"Swimming mapped: {stats['swimming_mapped']}")
    print(f"Levitates mapped: {stats['levitates_mapped']}")
    print(f"Normal: {stats['normal']}")
    print(f"Shiny: {stats['shiny']}")
    print(f"Unique species: {len(stats['unique_species'])}")
    print(f"Missing files: {stats['missing_files']}")
    print(f"Invalid sheets: {stats['invalid_sheets']}")
    print(f"Generated runtime sheets: {stats['generated_runtime_sheets']}")

    for w in warnings[:20]:
        print(f"WARNING: {w}")
    if len(warnings) > 20:
        print(f"WARNING: … {len(warnings) - 20} more")

    if errors:
        for e in errors[:40]:
            print(f"ERROR: {e}", file=sys.stderr)
        if len(errors) > 40:
            print(f"ERROR: … {len(errors) - 40} more", file=sys.stderr)
        print(f"FAILED with {len(errors)} error(s)", file=sys.stderr)
        return 2

    print("OK: water sprite validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
