#!/usr/bin/env python3
"""Draws the app icon: 8-bit headphones shared by two (one cup per person)
with a heart between them, on a night-sky tile. Pixel art on a 32x32 grid,
scaled up without smoothing. Writes AppIcon.icns (via iconutil) and
AppIcon.png (1024 px preview). No dependencies beyond the standard library.

    python3 packaging/make_icon.py
"""
import os
import struct
import subprocess
import sys
import tempfile
import zlib

N = 32

PAL = {
    ".": None,                 # transparent
    "k": (20, 14, 38),         # outline
    "b": (36, 28, 82),         # sky
    "B": (48, 38, 108),        # sky, lighter band
    "e": (62, 50, 138),        # tile edge highlight
    "s": (255, 240, 200),      # star
    "t": (130, 120, 200),      # dim star
    "w": (240, 236, 250),      # band
    "W": (255, 255, 255),      # band highlight
    "g": (170, 160, 205),      # band shadow
    "c": (64, 208, 255),       # left cup
    "C": (170, 240, 255),      # left cup highlight
    "d": (30, 130, 200),       # left cup shadow
    "o": (255, 176, 60),       # right cup
    "O": (255, 226, 150),      # right cup highlight
    "p": (205, 110, 30),       # right cup shadow
    "h": (255, 70, 110),       # heart
    "H": (255, 180, 200),      # heart highlight
    "r": (180, 30, 70),        # heart shadow
    "n": (54, 46, 80),         # cushion
    "N": (90, 80, 120),        # cushion highlight
}


def blank(ch="."):
    return [[ch] * N for _ in range(N)]


def tile():
    """Rounded square background from cell 2 to 29, pixel-stepped corners."""
    g = blank()
    lo, hi = 2, 29
    cut = {0: 3, 1: 2, 2: 1}  # rows from the edge -> cells cut at the corner
    for y in range(lo, hi + 1):
        d = min(y - lo, hi - y)
        c = cut.get(d, 0)
        for x in range(lo + c, hi - c + 1):
            g[y][x] = "b"
    # horizontal "retro" bands toward the bottom
    for y in (21, 22, 25, 26, 28):
        for x in range(N):
            if g[y][x] == "b":
                g[y][x] = "B"
    # outline + inner top highlight
    out = blank()
    for y in range(N):
        for x in range(N):
            if g[y][x] != ".":
                out[y][x] = g[y][x]
                continue
            if any(0 <= y + dy < N and 0 <= x + dx < N and g[y + dy][x + dx] != "."
                   for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0))):
                out[y][x] = "k"
    for x in range(N):
        y = next((y for y in range(N) if out[y][x] in "bB"), None)
        if y is not None:
            out[y][x] = "e"
    for y, x, ch in ((5, 6, "s"), (4, 24, "t"), (8, 27, "s"), (6, 15, "t"),
                     (11, 4, "t"), (13, 26, "t")):
        out[y][x] = ch
    out[5][5] = out[5][7] = out[4][6] = out[6][6] = "t"   # twinkle
    return out


def put(g, rows, ox, oy):
    for dy, row in enumerate(rows):
        for dx, ch in enumerate(row):
            if ch != ".":
                g[oy + dy][ox + dx] = ch


# Left half of the headphones (columns 0-15, rows from 0); the right half is
# its mirror image with the other cup colour. One cup per person.
LEFT = {
    5:  "...........kkkkk",
    6:  ".........kkWWWWW",
    7:  "........kWWwwwww",
    8:  ".......kWwwggggg",
    9:  "......kWwgkkkkkk",
    10: "......kWwgk.....",
    11: ".....kWwgk......",
    12: ".....kWwgk......",
    13: ".....kWwgk......",
    14: "...kkkkkkkk.....",
    15: "...kCCccdkkk....",
    16: "...kCcccdkNk....",
    17: "...kCcccdkNk....",
    18: "...kccccdkNk....",
    19: "...kccccdknk....",
    20: "...kccccdknk....",
    21: "...kccccdknk....",
    22: "...kdcccdkkk....",
    23: "...kdddddk......",
    24: "....kkkkk.......",
    # a cable from each cup, joined into one plug: a Y splitter
    25: "......g.........",
    26: "......gggggggggg",
    27: "...............W",
    28: "..............kW",
}

# Between the cups, under the band.
HEART = [
    ".kk..kk.",
    "kHhkkhhk",
    "kHhhhhhk",
    "khhhhhrk",
    ".khhhrk.",
    "..khrk..",
    "...kk...",
]

SWAP = {"c": "o", "C": "O", "d": "p"}


def draw():
    g = tile()
    for y, row in LEFT.items():
        for x, ch in enumerate(row):
            if ch != ".":
                g[y][x] = ch
                g[y][N - 1 - x] = SWAP.get(ch, ch)
    put(g, HEART, 12, 11)
    return g


def png(pixels, size, cell=None):
    """RGBA PNG of the grid, each cell `cell` px (default: fills the canvas),
    centred in a size x size canvas. Whole-pixel cells keep the art crisp."""
    cell = cell or size // N
    off = (size - cell * N) // 2
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        gy = (y - off) // cell
        for x in range(size):
            gx = (x - off) // cell
            rgb = PAL[pixels[gy][gx]] if 0 <= gy < N and 0 <= gx < N and y >= off and x >= off else None
            raw += bytes((*rgb, 255)) if rgb else b"\0\0\0\0"

    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def icon_png(g, size):
    """macOS icons leave a margin (the tile is ~82% of the canvas); large
    sizes get one, small ones use every pixel to stay readable."""
    if size >= 128:
        return png(g, size, cell=size * 28 // 1024)
    return png(g, size)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    g = draw()
    with open(os.path.join(root, "AppIcon.png"), "wb") as f:
        f.write(icon_png(g, 1024))
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for base in (16, 32, 128, 256, 512):
            for mult in (1, 2):
                size = base * mult
                path = os.path.join(iconset, f"icon_{base}x{base}{'@2x' if mult == 2 else ''}.png")
                if size < N:  # 16 px: let sips shrink the 32 px art
                    with open(path, "wb") as f:
                        f.write(png(g, N))
                    subprocess.run(["sips", "-z", str(size), str(size), path], check=True, capture_output=True)
                else:
                    with open(path, "wb") as f:
                        f.write(icon_png(g, size))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(root, "AppIcon.icns")], check=True)
    print("Wrote AppIcon.icns and AppIcon.png")


if __name__ == "__main__":
    sys.exit(main())
