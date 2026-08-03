#!/usr/bin/env python3
"""Fail before pack if manager-facing metadata is not ASCII-safe UTF-8.

Gen1Recomp's Mod Manager currently ellipsizes display strings with byte-wise
string.sub. Multibyte UTF-8 in visible metadata can raise:

  UTF-8 decoding error: Not enough space

This script guards the compatible release path by requiring:

  - UTF-8 without BOM for manifest.json and mod.card
  - valid UTF-8 decode
  - no non-ASCII code points in visible manager metadata fields
  - no C0/C1 control characters (except tab/LF/CR) in those fields
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "manifest.json"
MOD_CARD = ROOT / "mod.card"
OPTIONS = ROOT / "options.lua"

UTF8_BOM = b"\xef\xbb\xbf"
UTF16_LE_BOM = b"\xff\xfe"
UTF16_BE_BOM = b"\xfe\xff"

# Manifest keys shown or listed by the Mod Manager / importer.
MANIFEST_VISIBLE_KEYS = (
    "id",
    "name",
    "version",
    "entry",
    "profile",
    "category",
    "game_version",
    "description",
    "options_schema",
    "github",
)

CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")


def fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def check_encoding(path: Path) -> bytes:
    if not path.is_file():
        fail(f"missing {path.relative_to(ROOT)}")
    raw = path.read_bytes()
    if raw.startswith(UTF8_BOM):
        fail(f"{path.name}: UTF-8 BOM is not allowed (save as UTF-8 without BOM)")
    if raw.startswith(UTF16_LE_BOM) or raw.startswith(UTF16_BE_BOM):
        fail(f"{path.name}: UTF-16 is not allowed (must be UTF-8 without BOM)")
    # Heuristic: many NUL bytes suggest UTF-16 / binary mis-save.
    if raw and raw.count(b"\x00") > max(2, len(raw) // 50):
        fail(f"{path.name}: looks like UTF-16 or binary; use UTF-8 without BOM")
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as err:
        fail(f"{path.name}: invalid UTF-8 ({err})")
    # Reject Windows-1252 high bytes that are not valid UTF-8 sequences.
    # (Already covered by utf-8 decode, but keep an explicit message.)
    return raw


def non_ascii_report(label: str, value: str) -> list[str]:
    hits: list[str] = []
    for i, ch in enumerate(value):
        if ord(ch) > 127:
            line = value.count("\n", 0, i) + 1
            hits.append(
                f"{label}: non-ASCII U+{ord(ch):04X} {ch!r} at char {i} (line {line})"
            )
        elif CONTROL_RE.match(ch):
            line = value.count("\n", 0, i) + 1
            hits.append(
                f"{label}: control U+{ord(ch):04X} at char {i} (line {line})"
            )
    return hits


def walk_strings(prefix: str, value: object) -> list[str]:
    hits: list[str] = []
    if isinstance(value, str):
        hits.extend(non_ascii_report(prefix, value))
    elif isinstance(value, list):
        for idx, item in enumerate(value):
            hits.extend(walk_strings(f"{prefix}[{idx}]", item))
    elif isinstance(value, dict):
        for key, item in value.items():
            hits.extend(non_ascii_report(f"{prefix}.<key>", str(key)))
            hits.extend(walk_strings(f"{prefix}.{key}", item))
    return hits


def validate_manifest(raw: bytes) -> dict:
    try:
        data = json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as err:
        fail(f"manifest.json invalid JSON: {err}")
    if not isinstance(data, dict):
        fail("manifest.json must be a JSON object")

    hits: list[str] = []
    for key in MANIFEST_VISIBLE_KEYS:
        if key not in data:
            continue
        hits.extend(walk_strings(f"manifest.{key}", data[key]))

    # Also scan any other string fields that might be shown later.
    for key, value in data.items():
        if key in MANIFEST_VISIBLE_KEYS:
            continue
        if isinstance(value, (str, list, dict)):
            hits.extend(walk_strings(f"manifest.{key}", value))

    if hits:
        for h in hits:
            print(f"error: {h}", file=sys.stderr)
        fail("manifest.json contains non-ASCII or control characters in metadata")
    return data


_LUA_STRING_RE = re.compile(
    r"""(?P<key>\w+)\s*=\s*(?P<q>["'])(?P<val>(?:\\.|(?!(?P=q)).)*)(?P=q)"""
)
_LUA_LIST_STRING_RE = re.compile(
    r"""(?P<q>["'])(?P<val>(?:\\.|(?!(?P=q)).)*)(?P=q)"""
)


def _unescape_lua(s: str) -> str:
    return (
        s.replace(r"\\", "\\")
        .replace(r"\"", '"')
        .replace(r"\'", "'")
        .replace(r"\n", "\n")
        .replace(r"\t", "\t")
    )


def validate_mod_card(raw: bytes) -> None:
    text = raw.decode("utf-8")
    # Comments are not shown by the manager; still keep file ASCII-safe for
    # the compatible release path because the detail pane loads this chunk.
    hits = non_ascii_report("mod.card", text)
    if hits:
        for h in hits:
            print(f"error: {h}", file=sys.stderr)
        fail("mod.card contains non-ASCII or control characters")

    # Visible string values (summary, author, tags, differences, credits, ...).
    for m in _LUA_LIST_STRING_RE.finditer(text):
        val = _unescape_lua(m.group("val"))
        # Skip pure URL / id-like tokens still must be ASCII (already covered).
        more = non_ascii_report("mod.card.string", val)
        if more:
            for h in more:
                print(f"error: {h}", file=sys.stderr)
            fail("mod.card visible string is not ASCII")


def validate_options(raw: bytes) -> None:
    """Options labels/descriptions are shown in the Mod Manager panel."""
    text = raw.decode("utf-8")
    visible_keys = {"label", "description", "key"}
    hits: list[str] = []
    for m in _LUA_STRING_RE.finditer(text):
        key = m.group("key")
        if key not in visible_keys and key != "type":
            # choice display names are bare strings in tables; handled below.
            continue
        val = _unescape_lua(m.group("val"))
        hits.extend(non_ascii_report(f"options.{key}", val))

    # Choice labels like "FAST", "NORMAL" and any other quoted strings that
    # reach the options UI (conservative: all quoted strings in options.lua).
    for m in _LUA_LIST_STRING_RE.finditer(text):
        val = _unescape_lua(m.group("val"))
        hits.extend(non_ascii_report("options.string", val))

    # Deduplicate overlapping regex hits.
    uniq = sorted(set(hits))
    if uniq:
        for h in uniq:
            print(f"error: {h}", file=sys.stderr)
        fail("options.lua contains non-ASCII in manager-visible strings")


def main() -> int:
    man_raw = check_encoding(MANIFEST)
    card_raw = check_encoding(MOD_CARD)
    validate_manifest(man_raw)
    validate_mod_card(card_raw)

    if OPTIONS.is_file():
        opt_raw = check_encoding(OPTIONS)
        validate_options(opt_raw)

    print("validate-manager-ascii: ok")
    print(f"  {MANIFEST.name}: UTF-8 no BOM, ASCII metadata")
    print(f"  {MOD_CARD.name}: UTF-8 no BOM, ASCII metadata")
    if OPTIONS.is_file():
        print(f"  {OPTIONS.name}: UTF-8 no BOM, ASCII option strings")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
