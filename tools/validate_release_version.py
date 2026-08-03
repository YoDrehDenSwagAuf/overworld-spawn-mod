#!/usr/bin/env python3
"""Validate release tag / manifest / export / ZIP filename version alignment.

Usage:
  python3 tools/validate_release_version.py [v1.0.2]
  RELEASE_TAG=v1.0.2 python3 tools/validate_release_version.py

When no tag is provided, only cross-file consistency is checked (no tag step).
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "manifest.json"
MAIN = ROOT / "main.lua"
MOD_CARD = ROOT / "mod.card"
CHANGELOG = ROOT / "CHANGELOG.md"

TAG_RE = re.compile(r"^v(\d+\.\d+\.\d+)$")
EXPORT_RE = re.compile(r'mod\.exports\.version\s*=\s*"([^"]+)"')
CARD_VERSION_RE = re.compile(r'version\s*=\s*"([^"]+)"')


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def read_manifest_version() -> str:
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    version = data.get("version")
    if not isinstance(version, str) or not version:
        fail("manifest.json missing version")
    return version


def read_main_version() -> str:
    text = MAIN.read_text(encoding="utf-8")
    m = EXPORT_RE.search(text)
    if not m:
        fail("main.lua missing mod.exports.version")
    return m.group(1)


def read_mod_card_version() -> str | None:
    text = MOD_CARD.read_text(encoding="utf-8")
    m = CARD_VERSION_RE.search(text)
    if not m:
        return None
    return m.group(1)


def changelog_mentions(version: str) -> bool:
    if not CHANGELOG.is_file():
        return False
    return bool(re.search(rf"^##\s+{re.escape(version)}\b", CHANGELOG.read_text(encoding="utf-8"), re.M))


def main() -> int:
    tag_arg = None
    if len(sys.argv) > 1:
        tag_arg = sys.argv[1].strip()
    elif os.environ.get("RELEASE_TAG"):
        tag_arg = os.environ["RELEASE_TAG"].strip()
    elif os.environ.get("GITHUB_REF_TYPE") == "tag":
        tag_arg = os.environ.get("GITHUB_REF_NAME", "").strip() or None

    manifest_version = read_manifest_version()
    main_version = read_main_version()
    card_version = read_mod_card_version()

    print(f"Manifest: {manifest_version}")
    print(f"main.lua: {main_version}")
    if card_version is not None:
        print(f"mod.card: {card_version}")
    else:
        print("mod.card: (no version field)")

    if main_version != manifest_version:
        fail(
            "Release tag and manifest version do not match.\n"
            f"  main.lua={main_version} manifest={manifest_version}"
        )

    if card_version is not None and card_version != manifest_version:
        fail(
            "Release tag and manifest version do not match.\n"
            f"  mod.card={card_version} manifest={manifest_version}"
        )

    expected_zip = f"wilds-of-kanto-v{manifest_version}.zip"
    print(f"ZIP filename: {expected_zip}")

    if not changelog_mentions(manifest_version):
        fail(f"CHANGELOG.md missing section for {manifest_version}")

    if tag_arg:
        m = TAG_RE.match(tag_arg)
        if not m:
            fail(f"Release tag must look like vMAJOR.MINOR.PATCH, got: {tag_arg!r}")
        tag_version = m.group(1)
        print(f"Tag: {tag_arg}")
        if tag_version != manifest_version:
            fail(
                "ERROR: Release tag and manifest version do not match.\n"
                f"  Tag: {tag_arg}\n"
                f"  Manifest: {manifest_version}"
            )
    else:
        print("Tag: (not provided; consistency-only check)")

    print("validate_release_version: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
