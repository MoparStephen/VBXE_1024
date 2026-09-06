"""Generate packaging/app.ico - a small 4-palette colour-grid glyph.

The committed app.ico is what the build wires in; this script is here so it can
be regenerated or tweaked without hunting for an art tool.  Run it with any
Python that has Pillow:

    python packaging/make_icon.py

It writes a multi-resolution .ico (16/24/32/48/64/128/256) next to itself.
"""

import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "app.ico")

# Four rows = four palettes; a sweep across each row = 256 slots.  The colours
# are just a legible spread, not any real palette.
ROWS = (
    (0x2E, 0x9B, 0xFF),   # blue
    (0x4C, 0xD9, 0x64),   # green
    (0xFF, 0xC1, 0x07),   # amber
    (0xFF, 0x5A, 0x5A),   # red
)
BG = (0x1E, 0x1E, 0x22)
MASTER = 256


def _lerp(a, b, t):
    return tuple(int(round(x + (y - x) * t)) for x, y in zip(a, b))


def _render(size):
    scale = size / MASTER
    img = Image.new("RGBA", (size, size), BG + (255,))
    d = ImageDraw.Draw(img)

    margin = max(1, int(round(28 * scale)))
    gap = max(1, int(round(10 * scale)))
    grid = size - 2 * margin
    row_h = (grid - gap * (len(ROWS) - 1)) / len(ROWS)
    cells = 8 if size >= 32 else 4

    for r, base in enumerate(ROWS):
        y0 = margin + r * (row_h + gap)
        y1 = y0 + row_h
        dark = _lerp(base, (0, 0, 0), 0.55)
        for c in range(cells):
            t = c / (cells - 1) if cells > 1 else 0.0
            x0 = margin + grid * c / cells
            x1 = margin + grid * (c + 1) / cells - max(1, int(round(3 * scale)))
            d.rectangle([x0, y0, x1, y1], fill=_lerp(dark, base, t) + (255,))
    return img


def main():
    sizes = [16, 24, 32, 48, 64, 128, 256]
    frames = [_render(s) for s in sizes]
    frames[-1].save(OUT, format="ICO",
                    sizes=[(f.width, f.height) for f in frames])
    print("wrote", OUT, "-", ", ".join("%dx%d" % (s, s) for s in sizes))


if __name__ == "__main__":
    main()
