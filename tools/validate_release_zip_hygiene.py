#!/usr/bin/env python3
"""Fail if a Wilds release ZIP looks like a GitHub source archive.

The v2.1.6 GitHub release asset was a full-repo Download ZIP
(overworld-spawn-mod-main/) that included PowerShell, Python, and
bootstrap.sh. Those files are authoring tools, not runtime mod content.
Microsoft Defender classified that archive as Trojan:Script/Wacatac.B!ml.

This check does not try to evade antivirus. It only enforces the existing
packaging contract: ship the packed mod, not the repository.
"""
from __future__ import annotations

import importlib.util
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD_MOD = ROOT / "scripts" / "build-mod.py"

FORBIDDEN_PREFIXES = (
    ".git/",
    ".github/",
    "tests/",
    "scripts/",
    "tools/",
    "mods/",
    "__pycache__/",
    ".deps/",
)
FORBIDDEN_NAMES = {
    ".git",
    ".gitignore",
    ".DS_Store",
    ".modkitignore",
}
FORBIDDEN_EXACT = {
    "ARCHITECTURE.md",
}
FORBIDDEN_EXTENSIONS = {
    ".ps1",
    ".py",
    ".sh",
    ".bat",
    ".cmd",
    ".exe",
    ".dll",
    ".vbs",
    ".js",
    ".jar",
}
REQUIRED_ROOT = (
    "manifest.json",
    "main.lua",
    "mod.card",
    "options.lua",
    "LICENSE",
)


def fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def load_build_mod():
    spec = importlib.util.spec_from_file_location("build_mod", BUILD_MOD)
    if spec is None or spec.loader is None:
        fail(f"cannot import {BUILD_MOD}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def iter_files(zf: zipfile.ZipFile) -> list[str]:
    return [n.replace("\\", "/") for n in zf.namelist() if n and not n.endswith("/")]


def validate_names(names: list[str]) -> list[str]:
    errors: list[str] = []
    if any(n.startswith("overworld-spawn-mod-") for n in names):
        errors.append(
            "ZIP is wrapped as a GitHub source archive "
            "(overworld-spawn-mod-*/). Use scripts/build-mod.py."
        )
    for req in REQUIRED_ROOT:
        if req not in names:
            errors.append(f"missing {req} at archive root")
    for name in names:
        rel = name.lstrip("./")
        base = Path(rel).name
        suffix = Path(rel).suffix.lower()
        if base in FORBIDDEN_NAMES or rel in FORBIDDEN_EXACT:
            errors.append(f"forbidden name: {name}")
        if suffix in FORBIDDEN_EXTENSIONS:
            errors.append(f"forbidden authoring/host script: {name}")
        for prefix in FORBIDDEN_PREFIXES:
            top = prefix.rstrip("/")
            if rel == top or rel.startswith(prefix):
                errors.append(f"forbidden path: {name}")
                break
    return errors


def validate_zip(path: Path) -> int:
    if not path.is_file():
        fail(f"ZIP not found: {path}")
    with zipfile.ZipFile(path) as zf:
        names = iter_files(zf)
    errors = validate_names(names)
    if errors:
        for err in errors:
            print(f"error: {err}", file=sys.stderr)
        fail(f"{path.name}: {len(errors)} hygiene failure(s)")
    print("validate_release_zip_hygiene: ok")
    print(f"  zip: {path}")
    print(f"  files: {len(names)}")
    print("  no authoring scripts (.ps1/.py/.sh/...)")
    print("  no tests/scripts/tools/.github")
    print("  manifest.json at archive root")
    return 0


def self_test() -> int:
    build_mod = load_build_mod()
    failures = 0

    def check(cond: bool, msg: str) -> None:
        nonlocal failures
        if not cond:
            failures += 1
            print(f"FAIL: {msg}", file=sys.stderr)
        else:
            print(f"ok  {msg}")

    check(build_mod.should_include("main.lua") is True, "include main.lua")
    check(build_mod.should_include("lib/wilds_fs.lua") is True, "include lib/wilds_fs.lua")
    check(build_mod.should_include("assets/generated/true_size/species_table.lua") is True,
          "include generated lua table")
    check(build_mod.should_include("scripts/bootstrap.sh") is False, "exclude bootstrap.sh")
    check(build_mod.should_include("scripts/build-mod.ps1") is False, "exclude build-mod.ps1")
    check(build_mod.should_include("tools/generate_runtime_sprite_sheets.ps1") is False,
          "exclude tools/*.ps1")
    check(build_mod.should_include("tools/generate_runtime_sprite_sheets.py") is False,
          "exclude tools/*.py")
    check(build_mod.should_include("tests/sandbox_fs_compat_unit_test.lua") is False,
          "exclude tests/")
    check(build_mod.should_include(".github/workflows/release.yml") is False,
          "exclude .github/")

    dirty = [
        "overworld-spawn-mod-main/manifest.json",
        "overworld-spawn-mod-main/scripts/bootstrap.sh",
        "overworld-spawn-mod-main/tools/generate_runtime_sprite_sheets.ps1",
    ]
    dirty_errors = validate_names(dirty)
    check(any("source archive" in e for e in dirty_errors),
          "reject GitHub source-archive wrapper")
    check(any("bootstrap.sh" in e for e in dirty_errors),
          "reject bootstrap.sh in archive")
    check(any(".ps1" in e for e in dirty_errors),
          "reject PowerShell in archive")

    clean = [
        "manifest.json",
        "main.lua",
        "mod.card",
        "options.lua",
        "LICENSE",
        "lib/wilds_fs.lua",
        "assets/generated/followsprites_runtime/001-normal.png",
    ]
    check(validate_names(clean) == [], "accept packed mod file list")

    if failures:
        fail(f"self-test: {failures} failure(s)")
    print("validate_release_zip_hygiene --self-test: ok")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) != 2:
        print(
            "usage: validate_release_zip_hygiene.py <zip>|--self-test",
            file=sys.stderr,
        )
        return 2
    return validate_zip(Path(argv[1]))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
