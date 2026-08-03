#!/usr/bin/env python3
"""Build dist/wilds-of-kanto-v<version>.zip for Gen1Recomp import.

This repository root IS the mod (same layout as DramaticShapeVoxelMod).
Packs via the official Gen1Recomp modkit so the ZIP has manifest.json at
the archive root - never a wrapping folder, never the repo/workspace tree.

Public release name: wilds-of-kanto-v<version>.zip
Technical id aliases: overworld_wild_spawns-<version>.zip / overworld_wild_spawns.zip
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
    "github",
)

# Runtime files allowed in a manual fallback zip.
INCLUDE_PREFIXES = (
    "manifest.json",
    "main.lua",
    "options.lua",
    "mod.card",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "README.md",
    "CHANGELOG.md",
    "MANUAL_TEST.md",
    "lib/",
    "assets/",
    "data/",
    "docs/",
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
    "assets/_inspect/",
)
FORBIDDEN_NAMES = {
    ".git",
    ".gitignore",
    ".DS_Store",
    ".modkitignore",
}
FORBIDDEN_EXACT = {
    "scripts/bootstrap.sh",
    "scripts/build-mod.py",
    "scripts/build-mod.ps1",
    "scripts/validate-manager-ascii.py",
    "tests/overworld_wild_spawns_test.lua",
    "tests/voxel_aggressive_compat_test.lua",
    "tests/animated_sprites_unit_test.lua",
    # Root pointer only; docs/ARCHITECTURE.md is shipped.
    "ARCHITECTURE.md",
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
    if data.get("github") != "YoDrehDenSwagAuf/overworld-spawn-mod":
        fail("manifest github must be YoDrehDenSwagAuf/overworld-spawn-mod")
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


def run_modkit(*args: str) -> bool:
    """Run modkit; return False when unavailable instead of aborting the build."""
    try:
        modkit = ensure_engine()
        ensure_linked()
    except SystemExit:
        return False
    except Exception as err:
        print(f"modkit engine unavailable: {err}")
        return False
    cmd = [sys.executable, str(modkit), "--repo", str(ENGINE), *args]
    print("==>", " ".join(cmd))
    try:
        subprocess.check_call(cmd, cwd=str(ENGINE))
        return True
    except subprocess.CalledProcessError as err:
        print(f"modkit {' '.join(args)} failed with exit {err.returncode}")
        return False
    except FileNotFoundError as err:
        print(f"modkit launch failed: {err}")
        return False


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
                "tools",
                "mods",
                ".github",
            }:
                continue
        for name in names:
            full = base_path / name
            rel = full.relative_to(MOD_DIR).as_posix()
            if rel.endswith("POKEMON 1.png"):
                continue
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
    if "LICENSE" not in names:
        fail("ZIP missing LICENSE at archive root")
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
        # Allow docs/ARCHITECTURE.md; forbid only the root pointer file.
        # Nested repo layout leftovers
        if "/mods/" in f"/{rel}/" or rel.startswith("mods/"):
            fail(f"ZIP contains mods/ path: {name}")
        if "/scripts/" in f"/{rel}/" or rel.startswith("scripts/"):
            fail(f"ZIP contains scripts/ path: {name}")
        if "/.git/" in f"/{rel}/" or rel.startswith(".git"):
            fail(f"ZIP contains .git path: {name}")
        if "/.github/" in f"/{rel}/" or rel.startswith(".github"):
            fail(f"ZIP contains .github path: {name}")
        if rel.endswith("POKEMON 1.png") or rel.endswith("Pokemon_Sprites/POKEMON 1.png"):
            fail(f"ERROR: old commercial POKEMON 1.png is included: {name}")

    follow_map = "assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json"
    if follow_map not in names:
        fail(f"ZIP missing required follow-sprite asset: {follow_map}")
    follow_pngs = [
        n for n in names
        if n.startswith("assets/enhanced_overworld/followsprites/")
        and n.lower().endswith(".png")
    ]
    if not follow_pngs:
        print("WARNING: ZIP contains no follow-sprite PNGs (license/local-import mode?)")
    else:
        print(f"  follow-sprite PNGs: {len(follow_pngs)}")

    runtime_manifest = "assets/generated/followsprites_runtime/manifest.json"
    if runtime_manifest not in names:
        fail(f"ZIP missing required runtime sheet manifest: {runtime_manifest}")
    runtime_pngs = [
        n for n in names
        if n.startswith("assets/generated/followsprites_runtime/")
        and n.lower().endswith(".png")
    ]
    if len(runtime_pngs) < 151:
        fail(
            f"ZIP runtime sheets too few ({len(runtime_pngs)}); "
            "expected generated 16x96 SpriteRenderer sheets"
        )
    print(f"  native runtime sheets: {len(runtime_pngs)}")
    sample = "assets/generated/followsprites_runtime/001-normal.png"
    if sample not in names:
        fail(f"ZIP missing sample runtime sheet: {sample}")

    water_map_swim = (
        "assets/enhanced_overworld/water_sprites/swimming/swimming_sprite_mapping.json"
    )
    water_map_lev = (
        "assets/enhanced_overworld/water_sprites/levitates/levitates_sprite_mapping.json"
    )
    if water_map_swim not in names:
        fail(f"ZIP missing water swimming mapping: {water_map_swim}")
    if water_map_lev not in names:
        fail(f"ZIP missing water levitates mapping: {water_map_lev}")
    water_src = [
        n for n in names
        if n.startswith("assets/enhanced_overworld/water_sprites/")
        and n.lower().endswith(".png")
    ]
    if len(water_src) < 100:
        fail(f"ZIP water source PNGs too few ({len(water_src)})")
    print(f"  water source PNGs: {len(water_src)}")
    water_runtime_manifest = "assets/generated/water_runtime/manifest.json"
    if water_runtime_manifest not in names:
        fail(f"ZIP missing water runtime manifest: {water_runtime_manifest}")
    water_runtime = [
        n for n in names
        if n.startswith("assets/generated/water_runtime/")
        and n.lower().endswith(".png")
    ]
    if len(water_runtime) < 100:
        fail(f"ZIP water runtime sheets too few ({len(water_runtime)})")
    print(f"  water runtime sheets: {len(water_runtime)}")
    for sample_water in (
        "assets/generated/water_runtime/swimming/001-normal.png",
        "assets/generated/water_runtime/levitates/063-normal.png",
    ):
        if sample_water not in names:
            fail(f"ZIP missing sample water runtime sheet: {sample_water}")

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


def verify_follow_sprite_assets() -> None:
    """Build-time check for follow-sprites + shared mapping JSON."""
    legacy_atlas = (
        MOD_DIR
        / "assets"
        / "enhanced_overworld"
        / "Pokemon_Sprites"
        / "POKEMON 1.png"
    )
    # Local copy may exist for developers; it must never be required or shipped.
    if legacy_atlas.is_file():
        print(
            "note: local Anima atlas present but ignored "
            f"({legacy_atlas.relative_to(MOD_DIR).as_posix()})"
        )

    mapping = (
        MOD_DIR
        / "assets"
        / "enhanced_overworld"
        / "followsprites_mapping"
        / "followsprites_mapping.json"
    )
    sprite_dir = MOD_DIR / "assets" / "enhanced_overworld" / "followsprites"
    if not mapping.is_file():
        fail(f"followsprites mapping missing: {mapping.relative_to(MOD_DIR).as_posix()}")
    if not sprite_dir.is_dir():
        fail(f"followsprites dir missing: {sprite_dir.relative_to(MOD_DIR).as_posix()}")

    try:
        data = json.loads(mapping.read_text(encoding="utf-8"))
    except json.JSONDecodeError as err:
        fail(f"followsprites mapping JSON invalid: {err}")

    species = data.get("species") or {}
    if not isinstance(species, dict) or not species:
        fail("followsprites mapping has no species entries")

    pngs = {p.name.lower(): p for p in sprite_dir.iterdir() if p.suffix.lower() == ".png"}
    print(
        f"followsprites assets: mapping ok, species={len(species)}, pngs={len(pngs)}"
    )
    if len(pngs) < 1:
        print("WARNING: no follow-sprite PNGs found (license/local-import mode?)")

    # Spot-check Gen1 anchors used by MANUAL_TEST.
    for sid in (1, 25, 151):
        entry = species.get(str(sid)) or species.get(sid)
        if not entry or not (entry.get("normal") or entry.get("shiny")):
            fail(f"followsprites mapping missing required species {sid}")


def ensure_runtime_sheets() -> None:
    """Build Gen1Recomp 16×96 SpriteRenderer sheets from follow-sprites."""
    script = ROOT / "tools" / "generate_runtime_sprite_sheets.py"
    out_dir = ROOT / "assets" / "generated" / "followsprites_runtime"
    manifest = out_dir / "manifest.json"
    if not script.is_file():
        fail(f"missing sheet generator: {script}")
    print("==> generating native runtime sprite sheets")
    subprocess.check_call([sys.executable, str(script)], cwd=str(ROOT))
    if not manifest.is_file():
        fail(f"runtime sheet manifest missing after generate: {manifest}")
    sample = out_dir / "001-normal.png"
    if not sample.is_file():
        fail(f"runtime sheet sample missing: {sample}")


def ensure_water_runtime_sheets() -> None:
    """Build water swimming/levitates 16×96 SpriteRenderer sheets."""
    script = ROOT / "tools" / "generate_water_runtime_sheets.py"
    validate = ROOT / "tools" / "validate_water_sprites.py"
    out_dir = ROOT / "assets" / "generated" / "water_runtime"
    manifest = out_dir / "manifest.json"
    if not script.is_file():
        fail(f"missing water sheet generator: {script}")
    print("==> generating water runtime sprite sheets")
    subprocess.check_call([sys.executable, str(script)], cwd=str(ROOT))
    if not manifest.is_file():
        fail(f"water runtime manifest missing after generate: {manifest}")
    sample = out_dir / "swimming" / "001-normal.png"
    if not sample.is_file():
        fail(f"water runtime sample missing: {sample}")
    if validate.is_file():
        print("==> validating water sprites")
        subprocess.check_call([sys.executable, str(validate)], cwd=str(ROOT))


def main() -> int:
    if not (MOD_DIR / "manifest.json").is_file():
        fail(f"missing mod manifest at repo root: {MOD_DIR / 'manifest.json'}")
    manifest = read_manifest()

    # Manager-facing metadata must be ASCII-safe UTF-8 (no BOM) before pack.
    run_ascii_guard()
    verify_follow_sprite_assets()
    ensure_runtime_sheets()
    ensure_water_runtime_sheets()

    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)
    # Public release filename (product name). Keep technical-id aliases too.
    out_name = f"wilds-of-kanto-v{manifest['version']}.zip"
    out_zip = DIST / out_name

    # Prefer Gen1Recomp modkit; fall back to manual pack when luajit/modkit fails.
    modkit_ok = (
        run_modkit("validate", "mods/overworld_wild_spawns")
        and run_modkit("lint", "mods/overworld_wild_spawns")
        and run_modkit("pack", "mods/overworld_wild_spawns", "-o", str(out_zip))
    )
    if not modkit_ok or not out_zip.is_file():
        print("modkit unavailable/failed; packing manually from repo root")
        pack_manual(out_zip)

    if not out_zip.is_file():
        fail(f"expected output missing: {out_zip}")
    verify_zip(out_zip, manifest)

    if modkit_ok:
        run_modkit("validate", "mods/overworld_wild_spawns")

    # Prefer a single public release ZIP so Mod Manager update detection has
    # one unambiguous archive. Optional technical-id copies stay local-only.
    id_versioned = DIST / f"{manifest['id']}-{manifest['version']}.zip"
    id_alias = DIST / f"{manifest['id']}.zip"
    shutil.copy2(out_zip, id_versioned)
    shutil.copy2(out_zip, id_alias)

    print(f"wrote {out_zip}  (primary release asset)")
    print(f"wrote {id_versioned}  (local technical-id alias)")
    print(f"wrote {id_alias}  (local unversioned alias)")
    print(f"modkit validator: {'ok' if modkit_ok else 'skipped (manual pack)'}")
    print("manifest.json at ZIP root: confirmed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
