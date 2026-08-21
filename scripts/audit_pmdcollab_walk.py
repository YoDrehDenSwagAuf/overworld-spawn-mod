#!/usr/bin/env python3
"""Audit ALL imported PMDCollab Walk animations (dex 1–251).

Compares SpriteCollab source Walk frames against generated Wilds sheets /
sprite_table.lua metadata. Exits non-zero if any species with >1 distinct
source Walk frame lacks >1 distinct exported walk-cycle frames.

Usage:
  python3 scripts/audit_pmdcollab_walk.py /tmp/SpriteCollab
  python3 scripts/audit_pmdcollab_walk.py /tmp/SpriteCollab --report /tmp/pmd_walk_audit.txt
"""
from __future__ import annotations

import argparse
import importlib.util
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def load_importer():
    spec = importlib.util.spec_from_file_location(
        "import_pmdcollab", ROOT / "scripts" / "import_pmdcollab.py"
    )
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(mod)
    return mod


def parse_walk(xml_path: Path):
    if not xml_path.is_file():
        return None
    root = ET.parse(xml_path).getroot()
    for anim in root.findall("Anims/Anim"):
        if anim.findtext("Name") == "Walk":
            fw = int(anim.findtext("FrameWidth") or 0)
            fh = int(anim.findtext("FrameHeight") or 0)
            durs = [int(x.text or 0) for x in anim.findall("Durations/Duration")]
            return fw, fh, durs
    return None


def load_sprite_table(path: Path) -> dict[int, dict]:
    """Parse generated sprite_table.lua (one normal={...} line per species)."""
    import re

    text = path.read_text(encoding="utf-8")
    out: dict[int, dict] = {}
    current_dex: int | None = None
    for line in text.splitlines():
        dm = re.match(r"\s*\[(\d+)\]=\{", line)
        if dm:
            current_dex = int(dm.group(1))
            continue
        if current_dex is None:
            continue
        if "normal={" not in line:
            continue
        body = line
        fields: dict = {}
        for key in (
            "frameWidth",
            "frameHeight",
            "frames",
            "idleFrameCount",
            "walkFrameCount",
            "walkCycleBase",
            "anchorX",
            "anchorY",
        ):
            km = re.search(rf"{key}=([\d.]+)", body)
            if km:
                fields[key] = float(km.group(1)) if "." in km.group(1) else int(km.group(1))
        rel = re.search(r'rel="([^"]+)"', body)
        if rel:
            fields["rel"] = rel.group(1)
        wd = re.search(r"walkDurations=\{([^}]*)\}", body)
        if wd:
            fields["walkDurations"] = [
                int(x) for x in wd.group(1).split(",") if x.strip()
            ]
        out[current_dex] = fields
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("spritecollab", type=Path)
    ap.add_argument("--dex-min", type=int, default=1)
    ap.add_argument("--dex-max", type=int, default=251)
    ap.add_argument("--report", type=Path, default=None)
    ap.add_argument(
        "--assets",
        type=Path,
        default=ROOT / "assets" / "pmdcollab",
        help="Generated Wilds PMDCollab assets root",
    )
    args = ap.parse_args()
    imp = load_importer()
    table = load_sprite_table(args.assets / "sprite_table.lua")

    lines: list[str] = []
    failures: list[str] = []
    ok_n = 0
    missing_src = 0

    for dex in range(args.dex_min, args.dex_max + 1):
        src_dir = args.spritecollab / "sprite" / f"{dex:04d}"
        meta = parse_walk(src_dir / "AnimData.xml")
        entry = table.get(dex)
        if meta is None:
            missing_src += 1
            lines.append(f"#{dex:03d}: NO source Walk (skip)")
            continue
        fw, fh, durs = meta
        n = len(durs)
        anim_path = src_dir / "Walk-Anim.png"
        if not anim_path.is_file():
            failures.append(f"#{dex:03d}: AnimData Walk but missing Walk-Anim.png")
            continue
        im = Image.open(anim_path).convert("RGBA")
        distinct = {}
        for dname, row in imp.DIR_ROWS.items():
            if dname not in ("down", "up", "left", "right"):
                continue
            distinct[dname] = imp.count_distinct_cols(im, fw, fh, row, n)

        if not entry:
            failures.append(f"#{dex:03d}: missing sprite_table entry")
            continue
        rel = entry.get("rel")
        if not rel:
            failures.append(f"#{dex:03d}: no rel path")
            continue
        sheet_path = ROOT / rel
        if not sheet_path.is_file():
            failures.append(f"#{dex:03d}: missing generated sheet {rel}")
            continue

        wfc = int(entry.get("walkFrameCount") or 0)
        wcb = int(entry.get("walkCycleBase") or 0)
        gfw = int(entry.get("frameWidth") or 0)
        gfh = int(entry.get("frameHeight") or 0)
        gframes = int(entry.get("frames") or 0)
        sheet = Image.open(sheet_path).convert("RGBA")

        # Validate dimensions.
        if sheet.size[0] != gfw or sheet.size[1] != gfh * gframes:
            failures.append(
                f"#{dex:03d}: sheet size {sheet.size} != meta {gfw}x{gfh}*{gframes}"
            )
        if wfc != n:
            failures.append(
                f"#{dex:03d}: walkFrameCount {wfc} != source durations {n}"
            )
        expect_min = wcb + wfc * 4
        if gframes < expect_min:
            failures.append(
                f"#{dex:03d}: frames {gframes} < walkCycle end {expect_min}"
            )

        # Exported walk-cycle distinctness per direction.
        exp_distinct = {}
        for di, dname in enumerate(("down", "up", "left", "right")):
            hashes = set()
            for col in range(wfc):
                fi = wcb + di * wfc + col
                if fi < 0 or (fi + 1) * gfh > sheet.size[1]:
                    failures.append(f"#{dex:03d}: walk frame {fi} out of sheet")
                    continue
                tile = sheet.crop((0, fi * gfh, gfw, (fi + 1) * gfh))
                hashes.add(imp.visible_content_bytes(tile))
            exp_distinct[dname] = len(hashes)

        # Walker fallback stand vs walk must differ when source has >1 distinct.
        walker_ok = True
        for i, dname in enumerate(("down", "up", "left")):
            stand = sheet.crop((0, i * gfh, gfw, (i + 1) * gfh))
            walk = sheet.crop((0, (i + 3) * gfh, gfw, (i + 4) * gfh))
            same = imp.visible_content_bytes(stand) == imp.visible_content_bytes(walk)
            if distinct[dname] > 1 and same:
                walker_ok = False
                failures.append(
                    f"#{dex:03d}: walker stand/walk identical for {dname} "
                    f"(source distinct={distinct[dname]})"
                )

        src_multi = max(distinct.values()) > 1
        exp_multi = min(exp_distinct.values()) > 1 if wfc > 1 else False
        # If any cardinal has >1 source distinct, exported cycle for that dir
        # must also have >1.
        for dname in ("down", "up", "left", "right"):
            if distinct[dname] > 1 and exp_distinct.get(dname, 0) <= 1:
                failures.append(
                    f"#{dex:03d}: {dname} source distinct={distinct[dname]} "
                    f"but exported walk cycle distinct={exp_distinct.get(dname)}"
                )

        dex_fails = [f for f in failures if f.startswith(f"#{dex:03d}:")]
        if not dex_fails:
            ok_n += 1
            status = "OK"
        else:
            status = "FAIL"
        lines.append(
            f"#{dex:03d}: source Walk frames={n} durations={durs} "
            f"distinct={distinct} exported walkFrameCount={wfc} "
            f"walkCycleBase={wcb} expDistinct={exp_distinct} [{status}]"
        )

    report = "\n".join(lines) + "\n"
    report += f"\nSummary: OK={ok_n} failures={len(failures)} missing_src={missing_src}\n"
    if failures:
        report += "FAILURES:\n" + "\n".join(failures) + "\n"
    if args.report:
        args.report.write_text(report, encoding="utf-8")
    print(report)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
