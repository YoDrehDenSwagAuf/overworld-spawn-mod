#!/usr/bin/env python3
"""Generate the Voxel Hidden Silhouettes underwater shadow marker.

Output: assets/generated/water_hidden_runtime/water_hidden_shadow.png
  - 16×16 RGBA
  - Flat dark blue-teal ellipse, soft transparent rim
  - No question mark / Pokémon detail

Also writes a legacy alias path used by older docs:
  assets/generated/water_hidden_runtime/hidden-water-shadow.png
  (same 16×16 bytes)

Usage:
  python3 tools/generate_hidden_water_shadow.py
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "assets/generated/water_hidden_runtime"
OUT = OUT_DIR / "water_hidden_shadow.png"
OUT_LEGACY = OUT_DIR / "hidden-water-shadow.png"

W, H = 16, 16
# Dark blue-teal (~WaterDisplay.SILHOUETTE / HIDDEN)
BASE = (10, 28, 36)


def ellipse_alpha(px: float, py: float, cx: float, cy: float, rx: float, ry: float) -> float:
    dx = (px + 0.5 - cx) / max(rx, 0.01)
    dy = (py + 0.5 - cy) / max(ry, 0.01)
    d = (dx * dx + dy * dy) ** 0.5
    if d >= 1.0:
        return 0.0
    if d <= 0.55:
        return 1.0
    t = (d - 0.55) / 0.45
    t = t * t * (3 - 2 * t)
    return 1.0 - t


def make_image() -> list[list[tuple[int, int, int, int]]]:
    # Visible oval ~10×5 inside the 16×16 canvas (spec: 9–12 × 4–7).
    rx, ry = 5.2, 2.4
    cx, cy = 8.0, 8.0
    alpha_scale = 0.82
    pixels: list[list[tuple[int, int, int, int]]] = []
    for y in range(H):
        row: list[tuple[int, int, int, int]] = []
        for x in range(W):
            a = max(0.0, min(1.0, ellipse_alpha(x, y, cx, cy, rx, ry) * alpha_scale))
            core = ellipse_alpha(x, y, cx, cy, rx * 0.55, ry * 0.55)
            r = int(BASE[0] * (1.0 - 0.15 * core))
            g = int(BASE[1] * (1.0 - 0.10 * core))
            b = int(BASE[2] * (1.0 - 0.05 * core))
            row.append((r, g, b, int(round(a * 255))))
        pixels.append(row)
    return pixels


def chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def encode_png(pixels: list[list[tuple[int, int, int, int]]]) -> bytes:
    raw = bytearray()
    for y in range(H):
        raw.append(0)
        for x in range(W):
            r, g, b, a = pixels[y][x]
            raw.extend((r, g, b, a))
    ihdr = struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def main() -> int:
    pixels = make_image()
    png = encode_png(pixels)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(png)
    OUT_LEGACY.write_bytes(png)
    print(f"wrote {OUT.relative_to(ROOT)} ({W}x{H}, {len(png)} bytes)")
    print(f"wrote {OUT_LEGACY.relative_to(ROOT)} (alias)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
