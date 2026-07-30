#!/usr/bin/env python3
"""Build dist/overworld_wild_spawns-<version>.zip for Gen1Recomp import.

Prefers the official Gen1Recomp modkit pack command when gen1recomp/ is
present; otherwise packs runtime files directly with the same ZIP-root layout.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD_DIR = ROOT / "mods" / "overworld_wild_spawns"
DIST = ROOT / "dist"
ENGINE = ROOT / "gen1recomp"

# Runtime files to include when falling back to a manual zip.
INCLUDE_PREFIXES = (
    "manifest.json",
    "main.lua",
    "options.lua",
    "mod.card",
    "README.md",
    "CHANGELOG.md",
    "lib/",
    "assets/",
)
EXCLUDE_EXACT = {
    "tests/overworld_wild_spawns_test.lua",
    ".modkitignore",
}


def fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def read_manifest() -> dict:
    path = MOD_DIR / "manifest.json"
    if not path.is_file():
        fail(f"missing {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as err:
        fail(f"manifest.json invalid JSON: {err}")
    if data.get("id") != "overworld_wild_spawns":
        fail("manifest id must be overworld_wild_spawns")
    if not data.get("version"):
        fail("manifest version missing")
    entry = data.get("entry") or "main.lua"
    if not (MOD_DIR / entry).is_file():
        fail(f"entry file missing: {entry}")
    return data


def ensure_linked() -> Path:
    """Ensure the mod is visible under gen1recomp/mods for modkit."""
    target = ENGINE / "mods" / "overworld_wild_spawns"
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink() or target.exists():
        if target.resolve() != MOD_DIR.resolve():
            if target.is_symlink() or target.is_file():
                target.unlink()
            elif target.is_dir():
                shutil.rmtree(target)
            target.symlink_to(MOD_DIR)
    else:
        target.symlink_to(MOD_DIR)
    return target


def pack_with_modkit(out_zip: Path) -> None:
    modkit = ENGINE / "tools" / "modkit.py"
    if not modkit.is_file():
        fail("gen1recomp/tools/modkit.py not found; run ./scripts/bootstrap.sh")
    ensure_linked()
    cmd = [
        sys.executable,
        str(modkit),
        "--repo",
        str(ENGINE),
        "pack",
        "mods/overworld_wild_spawns",
        "-o",
        str(out_zip),
    ]
    print("==>", " ".join(cmd))
    subprocess.check_call(cmd, cwd=str(ENGINE))


def should_include(rel: str) -> bool:
    if rel in EXCLUDE_EXACT or rel == ".modkitignore":
        return False
    if rel.startswith("tests/"):
        return False
    for prefix in INCLUDE_PREFIXES:
        if rel == prefix or rel.startswith(prefix):
            return True
    return False


def pack_manual(out_zip: Path) -> None:
    files = []
    for base, _dirs, names in os.walk(MOD_DIR):
        for name in names:
            full = Path(base) / name
            rel = full.relative_to(MOD_DIR).as_posix()
            if should_include(rel):
                files.append(rel)
    files.sort()
    with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for rel in files:
            zf.write(MOD_DIR / rel, arcname=rel)


def verify_zip(out_zip: Path, manifest: dict) -> None:
    with zipfile.ZipFile(out_zip, "r") as zf:
        names = zf.namelist()
    if "manifest.json" not in names:
        fail("ZIP missing manifest.json at archive root")
    if manifest["entry"] not in names:
        fail(f"ZIP missing entry {manifest['entry']} at archive root")
    # Reject a single outer folder wrapper (e.g. overworld-spawn-mod-main/).
    top = {n.split("/", 1)[0] for n in names if n and not n.startswith(".modkit/")}
    if len(top) == 1 and f"{next(iter(top))}/manifest.json" in names:
        fail("ZIP has an outer root folder; manifest must sit at archive root")
    raw = zipfile.ZipFile(out_zip).read("manifest.json")
    parsed = json.loads(raw.decode("utf-8"))
    entry = parsed.get("entry") or "main.lua"
    if entry not in names:
        fail("manifest entry file not present inside ZIP")
    print("verify ok:")
    print(f"  files: {len(names)}")
    for n in sorted(names):
        print(f"  - {n}")


def main() -> int:
    manifest = read_manifest()
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)
    out_name = f"{manifest['id']}-{manifest['version']}.zip"
    out_zip = DIST / out_name

    if (ENGINE / "tools" / "modkit.py").is_file():
        pack_with_modkit(out_zip)
    else:
        print("==> modkit unavailable; packing manually")
        pack_manual(out_zip)

    if not out_zip.is_file():
        fail(f"expected output missing: {out_zip}")
    verify_zip(out_zip, manifest)
    print(f"wrote {out_zip}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
