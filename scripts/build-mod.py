#!/usr/bin/env python3
"""Build dist/overworld_wild_spawns-<version>.zip for Gen1Recomp import.

This repository root IS the mod (same layout as DramaticShapeVoxelMod).
Packs via the official Gen1Recomp modkit so the ZIP has manifest.json at
the archive root - never a wrapping folder, never the repo/workspace tree.
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
MOD_DIR = ROOT  # repo root == mod root (DramaticShape layout)
DIST = ROOT / "dist"
# Engine clone lives under .deps/ so modkit never packs it (dot-dirs skipped).
ENGINE = ROOT / ".deps" / "gen1recomp"

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

# Runtime files allowed in a manual fallback zip.
INCLUDE_PREFIXES = (
    "manifest.json",
    "main.lua",
    "options.lua",
    "mod.card",
    "README.md",
    "CHANGELOG.md",
    "lib/",
    "assets/",
    "data/",
)

# Paths that must never appear in a release ZIP (repo / GitHub / tooling).
FORBIDDEN_PREFIXES = (
    ".git/",
    ".github/",
    "tests/",
    "scripts/",
    "mods/",
    "__pycache__/",
    ".deps/",
    "gen1recomp/",
    "DramaticShapeVoxelMod/",
    "dist/",
)
FORBIDDEN_NAMES = {
    ".git",
    ".gitignore",
    ".DS_Store",
    ".modkitignore",
    "ARCHITECTURE.md",
}
FORBIDDEN_EXACT = {
    "scripts/bootstrap.sh",
    "scripts/build-mod.py",
    "scripts/build-mod.ps1",
    "scripts/validate-manager-ascii.py",
    "tests/overworld_wild_spawns_test.lua",
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
            ".deps/gen1recomp/tools/modkit.py not found; run ./scripts/bootstrap.sh "
            "first so the real Gen1Recomp modkit can pack and validate"
        )
    return modkit


def ensure_linked() -> Path:
    """Ensure the mod (repo root) is visible under gen1recomp/mods."""
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
    if name in FORBIDDEN_NAMES or rel in FORBIDDEN_EXACT:
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
        base_path = Path(base)
        # Never walk into nested clones / build output / VCS.
        try:
            rel_dir = base_path.relative_to(MOD_DIR).as_posix()
        except ValueError:
            continue
        if rel_dir != ".":
            top = rel_dir.split("/", 1)[0]
            if top in {
                ".git",
                ".deps",
                "gen1recomp",
                "DramaticShapeVoxelMod",
                "dist",
                "scripts",
                "tests",
                "mods",
                ".github",
            }:
                continue
        for name in names:
            full = base_path / name
            rel = full.relative_to(MOD_DIR).as_posix()
            if should_include(rel):
                files.append(rel)
    files.sort()
    with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for rel in files:
            zf.write(MOD_DIR / rel, arcname=rel)


def verify_manager_ascii_in_zip(zf: zipfile.ZipFile) -> None:
    """Re-check packaged manager metadata encoding after pack."""
    for name in ("manifest.json", "mod.card", "options.lua"):
        if name not in zf.namelist():
            if name == "options.lua":
                continue
            fail(f"ZIP missing {name} at archive root")
        raw = zf.read(name)
        if raw.startswith(b"\xef\xbb\xbf"):
            fail(f"ZIP {name}: UTF-8 BOM is not allowed")
        if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
            fail(f"ZIP {name}: UTF-16 is not allowed")
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as err:
            fail(f"ZIP {name}: invalid UTF-8 ({err})")
        non = [c for c in text if ord(c) > 127]
        if non:
            uniq = sorted({f"U+{ord(c):04X}" for c in non})
            fail(f"ZIP {name}: non-ASCII in manager metadata: {', '.join(uniq)}")
        print(f"  {name}: UTF-8 no BOM, ASCII-only")


def verify_zip(out_zip: Path, manifest: dict) -> None:
    with zipfile.ZipFile(out_zip, "r") as zf:
        names = list(zf.namelist())
        raw_manifest = zf.read("manifest.json") if "manifest.json" in names else None
        verify_manager_ascii_in_zip(zf)

    if "manifest.json" not in names:
        fail("ZIP missing manifest.json at archive root")
    if "main.lua" not in names and (manifest.get("entry") or "main.lua") not in names:
        fail("ZIP missing main.lua / entry at archive root")
    if "mod.card" not in names:
        fail("ZIP missing mod.card at archive root")
    assert raw_manifest is not None

    # Reject a single outer folder wrapper (e.g. overworld-spawn-mod-main/).
    meaningful = [n for n in names if n and not n.startswith(".modkit/")]
    top = {n.split("/", 1)[0] for n in meaningful}
    if "manifest.json" not in names:
        fail("ZIP missing manifest.json at archive root")
    # If every path is under one directory and that dir's manifest exists
    # but root manifest does not, it is the forbidden wrapper layout.
    if len(top) == 1:
        only = next(iter(top))
        if only != "manifest.json" and f"{only}/manifest.json" in names:
            fail("ZIP has an outer root folder; manifest must sit at archive root")

    # Repo / GitHub / tooling must never ship.
    for name in names:
        rel = name.rstrip("/")
        base = Path(rel).name
        if base in FORBIDDEN_NAMES:
            fail(f"ZIP contains forbidden path: {name}")
        for prefix in FORBIDDEN_PREFIXES:
            if rel == prefix.rstrip("/") or rel.startswith(prefix):
                fail(f"ZIP contains forbidden path: {name}")
        if rel in FORBIDDEN_EXACT:
            fail(f"ZIP contains forbidden path: {name}")
        # Nested repo layout leftovers
        if "/mods/" in f"/{rel}/" or rel.startswith("mods/"):
            fail(f"ZIP contains mods/ path: {name}")
        if "/scripts/" in f"/{rel}/" or rel.startswith("scripts/"):
            fail(f"ZIP contains scripts/ path: {name}")
        if "/.git/" in f"/{rel}/" or rel.startswith(".git"):
            fail(f"ZIP contains .git path: {name}")
        if "/.github/" in f"/{rel}/" or rel.startswith(".github"):
            fail(f"ZIP contains .github path: {name}")

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

    # Simulate Gen1Recomp LauncherMods.locateRoot: prefer flat root.
    if "manifest.json" not in names:
        fail("Gen1Recomp loader would not find manifest.json at ZIP root")

    print("verify ok:")
    print("  manifest.json at ZIP root: yes")
    print("  main.lua at ZIP root: yes")
    print("  mod.card at ZIP root: yes")
    print("  no outer root folder: yes")
    print("  no scripts/: yes")
    print("  no mods/: yes")
    print("  no .git / .github: yes")
    print(f"  entry: {entry}")
    if schema:
        print(f"  options_schema: {schema}")
    print(f"  files: {len(names)}")
    for n in sorted(names):
        print(f"  - {n}")


def run_ascii_guard() -> None:
    """Fail before pack if manager metadata has BOM / invalid UTF-8 / non-ASCII."""
    script = ROOT / "scripts" / "validate-manager-ascii.py"
    if not script.is_file():
        fail(f"missing ASCII guard: {script}")
    cmd = [sys.executable, str(script)]
    print("==>", " ".join(cmd))
    try:
        subprocess.check_call(cmd, cwd=str(ROOT))
    except subprocess.CalledProcessError as err:
        fail(f"validate-manager-ascii failed with exit {err.returncode}")


def main() -> int:
    if not (MOD_DIR / "manifest.json").is_file():
        fail(f"missing mod manifest at repo root: {MOD_DIR / 'manifest.json'}")
    manifest = read_manifest()

    # Manager-facing metadata must be ASCII-safe UTF-8 (no BOM) before pack.
    run_ascii_guard()

    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)
    out_name = f"{manifest['id']}-{manifest['version']}.zip"
    out_zip = DIST / out_name

    # Validate + pack with the real Gen1Recomp modkit (flat archive root).
    run_modkit("validate", "mods/overworld_wild_spawns")
    run_modkit("lint", "mods/overworld_wild_spawns")
    run_modkit("pack", "mods/overworld_wild_spawns", "-o", str(out_zip))

    if not out_zip.is_file():
        fail(f"expected output missing: {out_zip}")
    verify_zip(out_zip, manifest)

    # Re-validate after pack.
    run_modkit("validate", "mods/overworld_wild_spawns")

    # Also write an unversioned alias matching the user-facing name.
    alias = DIST / f"{manifest['id']}.zip"
    shutil.copy2(out_zip, alias)

    print(f"wrote {out_zip}")
    print(f"wrote {alias}")
    print("modkit validator: ok")
    print("manifest.json at ZIP root: confirmed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
