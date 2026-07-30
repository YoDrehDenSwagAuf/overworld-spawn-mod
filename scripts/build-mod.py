#!/usr/bin/env python3
"""Build dist/overworld_wild_spawns-<version>.zip for Gen1Recomp import.

Requires gen1recomp/ (see ./scripts/bootstrap.sh). Packs via the official
modkit, then verifies archive layout and re-runs the modkit validator.
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

REQUIRED_MANIFEST_FIELDS = (
    "id",
    "name",
    "version",
    "api",
    "entry",
    "category",
    "description",
    "game_version",
)

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
FORBIDDEN_PREFIXES = (
    ".git/",
    "tests/",
    "__pycache__/",
    ".modkit/",
)
FORBIDDEN_NAMES = {
    ".git",
    ".gitignore",
    ".DS_Store",
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
    if not isinstance(data, dict):
        fail("manifest.json must be a JSON object")
    for field in REQUIRED_MANIFEST_FIELDS:
        if field not in data or data[field] in (None, ""):
            fail(f"manifest missing required field: {field}")
    if data.get("id") != "overworld_wild_spawns":
        fail("manifest id must be overworld_wild_spawns")
    entry = data["entry"]
    if not (MOD_DIR / entry).is_file():
        fail(f"entry file missing: {entry}")
    schema = data.get("options_schema")
    if schema:
        if not isinstance(schema, str) or not schema:
            fail("options_schema must be a non-empty string when present")
        if not (MOD_DIR / schema).is_file():
            fail(f"options_schema file missing: {schema}")
    return data


def ensure_engine() -> Path:
    modkit = ENGINE / "tools" / "modkit.py"
    if not modkit.is_file():
        fail(
            "gen1recomp/tools/modkit.py not found; run ./scripts/bootstrap.sh "
            "first so the real Gen1Recomp modkit can pack and validate"
        )
    return modkit


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


def run_modkit(*args: str) -> None:
    modkit = ensure_engine()
    ensure_linked()
    cmd = [sys.executable, str(modkit), "--repo", str(ENGINE), *args]
    print("==>", " ".join(cmd))
    try:
        subprocess.check_call(cmd, cwd=str(ENGINE))
    except subprocess.CalledProcessError as err:
        fail(f"modkit {' '.join(args)} failed with exit {err.returncode}")


def should_include(rel: str) -> bool:
    name = Path(rel).name
    if name in FORBIDDEN_NAMES or rel in EXCLUDE_EXACT:
        return False
    for prefix in FORBIDDEN_PREFIXES:
        if rel == prefix.rstrip("/") or rel.startswith(prefix):
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
        raw_manifest = zf.read("manifest.json") if "manifest.json" in names else None

    if "manifest.json" not in names:
        fail("ZIP missing manifest.json at archive root")
    assert raw_manifest is not None

    # Reject a single outer folder wrapper (e.g. overworld-spawn-mod-main/).
    top = {n.split("/", 1)[0] for n in names if n and not n.startswith(".modkit/")}
    if len(top) == 1:
        only = next(iter(top))
        if f"{only}/manifest.json" in names and "manifest.json" not in names:
            fail("ZIP has an outer root folder; manifest must sit at archive root")
        if only.endswith("/") or (only in names and all("/" in n or n == only for n in names)):
            pass
        if all(n == only or n.startswith(only + "/") for n in names if not n.startswith(".modkit/")):
            if f"{only}/manifest.json" in names:
                fail("ZIP has an outer root folder; manifest must sit at archive root")

    try:
        parsed = json.loads(raw_manifest.decode("utf-8"))
    except json.JSONDecodeError as err:
        fail(f"ZIP manifest.json is not valid JSON: {err}")

    for field in REQUIRED_MANIFEST_FIELDS:
        if field not in parsed or parsed[field] in (None, ""):
            fail(f"ZIP manifest missing required field: {field}")

    entry = parsed.get("entry") or "main.lua"
    if entry not in names:
        fail(f"ZIP missing entry {entry} at archive root")

    schema = parsed.get("options_schema")
    if schema and schema not in names:
        fail(f"ZIP missing options_schema file: {schema}")

    for name in names:
        rel = name.rstrip("/")
        base = Path(rel).name
        if base in FORBIDDEN_NAMES or rel.startswith(".git/") or "/.git/" in f"/{rel}/":
            fail(f"ZIP contains forbidden path: {name}")
        if rel.startswith("tests/") or "/tests/" in f"/{rel}/":
            fail(f"ZIP contains test/dev path: {name}")
        if rel.startswith("__pycache__/") or "/__pycache__/" in f"/{rel}/":
            fail(f"ZIP contains cache path: {name}")

    print("verify ok:")
    print(f"  manifest.json at ZIP root: yes")
    print(f"  entry: {entry}")
    if schema:
        print(f"  options_schema: {schema}")
    print(f"  files: {len(names)}")
    for n in sorted(names):
        print(f"  - {n}")


def main() -> int:
    if not MOD_DIR.is_dir():
        fail(f"missing mod directory: {MOD_DIR}")
    manifest = read_manifest()

    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)
    out_name = f"{manifest['id']}-{manifest['version']}.zip"
    out_zip = DIST / out_name

    # Validate source tree with the real Gen1Recomp modkit before packing.
    run_modkit("validate", "mods/overworld_wild_spawns")
    run_modkit("lint", "mods/overworld_wild_spawns")
    run_modkit("pack", "mods/overworld_wild_spawns", "-o", str(out_zip))

    if not out_zip.is_file():
        fail(f"expected output missing: {out_zip}")
    verify_zip(out_zip, manifest)

    # Re-validate the packed tree (still linked from source; pack already
    # ran validate --strict). Echo success for the agent/report.
    run_modkit("validate", "mods/overworld_wild_spawns")

    print(f"wrote {out_zip}")
    print("modkit validator: ok")
    print("manifest.json at ZIP root: confirmed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
