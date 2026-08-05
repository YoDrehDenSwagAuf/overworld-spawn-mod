#!/usr/bin/env python3
"""Verify Original runtime sheets are pixel-identical to a force regenerate.

Expectation for Sprite Sizes = Original:
  all generated runtime PNG hashes unchanged vs committed Original sheets.

Usage:
  python3 tools/verify_original_runtime_hashes.py
"""
from __future__ import annotations

import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/generated/followsprites_runtime"
SCRIPT = ROOT / "tools/generate_runtime_sprite_sheets.py"


def file_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_digest(directory: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for path in sorted(directory.glob("*.png")):
        out[path.name] = file_digest(path)
    return out


def main() -> int:
    if not OUT.is_dir():
        print(f"error: missing {OUT}", file=sys.stderr)
        return 1
    baseline = tree_digest(OUT)
    if not baseline:
        print("error: no original PNGs found", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="ow_orig_") as tmp:
        tmp_dir = Path(tmp) / "followsprites_runtime"
        cmd = [
            sys.executable,
            str(SCRIPT),
            "--size-mode",
            "original",
            "--force",
            "--out-original",
            str(tmp_dir),
        ]
        print("regenerating Original sheets into temp dir…")
        subprocess.check_call(cmd, cwd=str(ROOT))
        regenerated = tree_digest(tmp_dir)

    missing = sorted(set(baseline) - set(regenerated))
    extra = sorted(set(regenerated) - set(baseline))
    changed = sorted(
        name for name in baseline
        if name in regenerated and baseline[name] != regenerated[name]
    )

    print(f"baseline pngs: {len(baseline)}")
    print(f"regenerated pngs: {len(regenerated)}")
    if missing or extra or changed:
        print("FAIL: Original runtime PNG hashes changed", file=sys.stderr)
        if missing[:10]:
            print("  missing:", ", ".join(missing[:10]), file=sys.stderr)
        if extra[:10]:
            print("  extra:", ", ".join(extra[:10]), file=sys.stderr)
        if changed[:10]:
            print("  changed:", ", ".join(changed[:10]), file=sys.stderr)
        print(f"  changed_count={len(changed)} missing={len(missing)} extra={len(extra)}")
        return 2

    print("OK: all generated runtime PNG hashes unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
