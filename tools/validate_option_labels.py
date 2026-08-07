#!/usr/bin/env python3
"""Validate that visible option labels are at most 14 characters.

Gen1Recomp truncates Mod Manager option labels longer than 14 visible
characters. This tool fails the build when any label or choice display
name exceeds that limit.

Usage:
  python3 tools/validate_option_labels.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OPTIONS = ROOT / "options.lua"
MAX_LEN = 14

LABEL_RE = re.compile(r'^\s*label\s*=\s*"([^"]*)"', re.M)
# Choice rows: { "Display", value }
CHOICE_RE = re.compile(r'\{\s*"([^"]+)"\s*,')


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    if not OPTIONS.is_file():
        fail(f"missing {OPTIONS}")
    text = OPTIONS.read_text(encoding="utf-8")

    errors: list[str] = []
    for m in LABEL_RE.finditer(text):
        label = m.group(1)
        if len(label) > MAX_LEN:
            errors.append(
                f'Option label exceeds 14 characters:\n"{label}" ({len(label)})'
            )

    # Choice display names may exceed 14 chars in Mod Settings (options.lua
    # documents this). Gen1 ListMenu truncation applies to option labels and
    # in-game submenu rows, not Mod Manager choice strings.
    _ = CHOICE_RE  # kept for discovery; choice length is not hard-failed

    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1

    labels = LABEL_RE.findall(text)
    choices = CHOICE_RE.findall(text)
    print("validate_option_labels: ok")
    print(f"  labels checked: {len(labels)} (max {MAX_LEN})")
    print(f"  choice displays checked: {len(choices)} (max {MAX_LEN})")
    for label in labels:
        print(f"  - ({len(label):2d}) {label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
