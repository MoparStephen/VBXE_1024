#!/usr/bin/env python3
"""
make_logo.py - concept logos for the VBXE_1024 menu/info banner.

The menu XDL's banner band is 320x34 at 8bpp (MENU_BANNER_VRAM, pitch 320); the
outer 32px at each edge hold the palette-demo ramp squares, leaving a 256x34
area (x 32-287) for a logo.  Every logo here is drawn as a 256x34 array of
indices into the *modified* palette 0 the menu/viewer screens run with (see
UI_Apply_TextPalette, Viewer/ui.asm):

    index e       (0..127)  = master colour 2e      (even entries)
    index 128+e             = master colour 2e+1    (odd entries)

Colours are chosen as Atari (hue, luma) pairs and mapped through that
de-interleave, so every pixel is exactly a palette-0 colour - no quantising.

Outputs (Viewer/Assets/Logo/):
  palette0_modified.png          16x16 swatch grid of palette 0 in index order
  logo_<n>_<name>.png            true 256x34 render
  logo_<n>_<name>_x4.png         4x nearest-neighbour preview
  logo_sheet.png                 every concept at 3x inside a 320-wide banner mock-up

  --export N                     also write Viewer/Assets/MENU.RAW (320x36) for
                                 concept N - init_vbxe.asm assembly-embeds it
                                 into the .xex (Load_Menu_Logo1-3); no
                                 MENU.MAP - the banner's attribute map is zeroed
                                 at boot, i.e. palette 0 everywhere
                                 for concept N

  sep_<style>.png / sep_sheet.png  menu separator previews (160 lo-res px,
                                 mirrored blue/gold chrome ramps)
  --export-sep STYLE             also write Viewer/Assets/MENU_SEP.RAW - the
                                 160-byte separator row init_vbxe.asm loads
                                 straight into MENU_SEP_VRAM ($33000) - and
                                 rewrite nfo_encode.py's RULE_ATTRS so the
                                 .nfo ==== rule carries the same colours
"""
import argparse
import os

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ASSETS = os.path.join(REPO, "Viewer", "Assets")
OUT_DIR = os.path.join(ASSETS, "Logo")
MASTER_PAL = r"C:\Users\Stephen\source\repos\My Atari 8-bit code\Libraries\vbxe_pal.pal"

LOGO_W, LOGO_H = 256, 34  # usable logo area
BANNER_W, BANNER_H = 320, 34  # visible banner band
BANNER_ROWS = 36  # MENU_BANNER_ROWS - the .RAW buffer height
LOGO_X = 32  # logo's left edge inside the banner
DEMO_SQ = 16  # MENU_DEMO_SQUARE
DEMO_ROW_BOT = DEMO_SQ + 1  # MENU_DEMO_ROW_BOT


# --- palette -----------------------------------------------------------------
def load_master():
    d = np.frombuffer(open(MASTER_PAL, "rb").read(), np.uint8)
    return d.reshape(256, 3)


def load_pal0():
    """The de-interleaved palette 0: even master entries -> 0..127, odd -> 128..255."""
    m = load_master()
    return np.concatenate([m[0::2], m[1::2]])


def idx(hue, luma):
    """Atari (hue 0-15, luma 0-15) -> index in the modified palette 0."""
    hue = int(np.clip(hue, 0, 15))
    luma = int(np.clip(luma, 0, 15))
    return (128 if luma & 1 else 0) + hue * 8 + (luma >> 1)


def ramp_pal(channel):
    """Palette set 1/2/3 (channel 0/1/2): colour i = i in that one component -
    the same ramp Apply_Menu_Palettes (view1024.asm) generates at runtime."""
    pal = np.zeros((256, 3), np.uint8)
    pal[:, channel] = np.arange(256)
    return pal


# --- fonts / masks ---------------------------------------------------------------
FONTS = {}


def font(name):
    if name not in FONTS:
        FONTS[name] = open(os.path.join(ASSETS, name), "rb").read()
    return FONTS[name]


def glyph(ch, fname):
    d = font(fname)
    o = ord(ch) * 8
    return np.array([[(d[o + r] >> (7 - b)) & 1 for b in range(8)] for r in range(8)], bool)


def crop(mask):
    ys, xs = np.nonzero(mask)
    if len(ys) == 0:
        return mask[:0, :0]
    return mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def text_mask(s, fname="ATARI.F08", sx=1, sy=1, track=0):
    """Boolean mask of a string; cells are 8 wide + track (may be negative), cropped."""
    cw = 8 + track
    m = np.zeros((8, cw * len(s) + 16), bool)
    for i, ch in enumerate(s):
        m[:, i * cw:i * cw + 8] |= glyph(ch, fname)
    m = crop(m)
    return np.kron(m, np.ones((sy, sx), bool))


def place(mask, x, y, shape=(LOGO_H, LOGO_W)):
    out = np.zeros(shape, bool)
    h, w = mask.shape
    out[y:y + h, x:x + w] = mask[:shape[0] - y, :shape[1] - x]
    return out


def centre_x(mask, w=LOGO_W):
    return (w - mask.shape[1]) // 2


def shift(mask, dx, dy):
    out = np.zeros_like(mask)
    h, w = mask.shape
    out[max(dy, 0):h + min(dy, 0), max(dx, 0):w + min(dx, 0)] = \
        mask[max(-dy, 0):h - max(dy, 0), max(-dx, 0):w - max(dx, 0)]
    return out


def dilate(mask, diag=True):
    out = mask.copy()
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        out |= shift(mask, dx, dy)
    if diag:
        for dx, dy in ((1, 1), (-1, -1), (1, -1), (-1, 1)):
            out |= shift(mask, dx, dy)
    return out


def rows_span(mask):
    ys = np.nonzero(mask.any(axis=1))[0]
    return ys.min(), ys.max()


def cols_span(mask):
    xs = np.nonzero(mask.any(axis=0))[0]
    return xs.min(), xs.max()


def canvas():
    return np.zeros((LOGO_H, LOGO_W), np.uint8)  # index 0 = black


# --- concepts --------------------------------------------------------------------
def c1_hue_sweep():
    """'VBXE 1024' with a hue sweep across the columns + a tagline."""
    c = canvas()
    big = text_mask("VBXE 1024", "ATARI.F08", 3, 3)  # 18 px tall
    tag = text_mask("1024 COLOURS ON SCREEN", "ATARI.F08")
    by = 3
    bm = place(big, centre_x(big), by)
    tm = place(tag, centre_x(tag), by + big.shape[0] + 4)
    x0, x1 = cols_span(bm)
    y0, y1 = rows_span(bm)
    c[shift(bm, 2, 2) & ~bm] = idx(0, 2)  # drop shadow
    for y, x in zip(*np.nonzero(bm)):
        hue = 1 + round(14 * (x - x0) / max(1, x1 - x0))
        luma = 14 - round(8 * (y - y0) / max(1, y1 - y0))  # light top -> darker bottom
        c[y, x] = idx(hue, luma)
    c[tm] = idx(0, 10)
    return c


def c2_spectrum_swatch():
    """All 256 palette-0 colours as a swatch block + big '1024' + 'VBXE / VIEWER'."""
    c = canvas()
    # 16x16 swatch, 2px per colour, hue across / luma down, 32x32 at left
    sx0, sy0 = 4, 1
    for h in range(16):
        for l in range(16):
            c[sy0 + l * 2:sy0 + l * 2 + 2, sx0 + h * 2:sx0 + h * 2 + 2] = idx(h, l)
    big = text_mask("1024", "CGA.F08", 4, 4, track=0)  # ~28 px tall
    bx = sx0 + 32 + 8
    by = (LOGO_H - big.shape[0]) // 2
    bm = place(big, bx, by)
    y0, y1 = rows_span(bm)
    c[shift(bm, 1, 1) & ~bm] = idx(7, 2)
    for y, x in zip(*np.nonzero(bm)):
        c[y, x] = idx(0, 15 - round(7 * (y - y0) / max(1, y1 - y0)))  # white -> grey
    tx = bx + big.shape[1] + 8
    t1 = text_mask("VBXE", "ATARI.F08", 2, 2)
    t2 = text_mask("VIEWER", "ATARI.F08")
    m1 = place(t1, tx, 6)
    m2 = place(t2, tx, 6 + t1.shape[0] + 4)
    c[m1] = idx(9, 12)
    c[m2] = idx(0, 9)
    return c


def c3_chrome():
    """'VIEW1024' in an 80s chrome gradient (sky over gold) with an outline."""
    c = canvas()
    big = text_mask("VIEW1024", "ATARI.F08", 3, 4, track=-1)  # 24 px tall
    bm = place(big, centre_x(big), (LOGO_H - big.shape[0]) // 2)
    y0, y1 = rows_span(bm)
    mid = (y0 + y1) / 2
    c[dilate(bm) & ~bm] = idx(7, 4)  # dark blue outline
    for y, x in zip(*np.nonzero(bm)):
        if y <= mid:
            t = (y - y0) / max(1, mid - y0)
            col = idx(9, 6 + round(8 * t))  # sky: blue -> near white
        elif y == int(mid) + 1:
            col = idx(0, 15)  # horizon glint
        else:
            t = (y - mid) / max(1, y1 - mid)
            col = idx(2, 12 - round(8 * t))  # ground: gold -> brown
        c[y, x] = col
    return c


def mosaic_mask(text, track=-1):
    return text_mask(text, "CGA.F08", track=track)  # 1x, cropped


def mosaic_mask_draw(c, text, ox, track=-1, height=None, oy=None, drop_cols=(), mask=None):
    """Draw text as a block mosaic (CGA 1x, 3x3 blocks + 1 gap): hue sweeps
    across, luma falls down, alternate blocks 2 lumas darker.  With height,
    the block rows are stretched (1px gaps kept) so the ink spans exactly
    height rows from oy.  drop_cols: blank glyph columns to close up (kerning);
    blocks keep the colours of their original column.  mask: a pre-edited
    mosaic_mask(text, track) to draw instead.  Returns the x just past the
    mosaic."""
    g = mosaic_mask(text, track) if mask is None else mask
    bs = 4  # 3x3 block + 1 gap
    gh, gw = g.shape
    if height is None:
        if oy is None:
            oy = (LOGO_H - gh * bs) // 2 + 1
        rows = [(oy + gy * bs, oy + gy * bs + bs - 1) for gy in range(gh)]
    else:
        # row gy starts at round(gy*(H+1)/gh); the last row ends on oy+H-1
        starts = [oy + round(gy * (height + 1) / gh) for gy in range(gh + 1)]
        rows = [(starts[gy], starts[gy + 1] - 1) for gy in range(gh)]
    for gy in range(gh):
        for gx in range(gw):
            if g[gy, gx]:
                hue = 1 + (gx * 15) // max(1, gw - 1)
                luma = 14 - (gy * 8) // max(1, gh - 1) - ((gx + gy) & 1) * 2
                y0, y1 = rows[gy]
                x = ox + (gx - sum(d < gx for d in drop_cols)) * bs
                c[y0:y1, x:x + bs - 1] = idx(hue, luma)
    return ox + (gw - len(drop_cols)) * bs


def c4_mosaic():
    """'1024' built from blocks, each a different colour + 'VBXE' / '1024 COLOURS'."""
    c = canvas()
    tx = mosaic_mask_draw(c, "1024", 6) + 10
    t1 = text_mask("VBXE", "ATARI.F08", 3, 2)
    t2 = text_mask("1024 COLOURS", "ATARI.F08")
    m1 = place(t1, tx, 5)
    m2 = place(t2, tx, 5 + t1.shape[0] + 5)
    c[shift(m1, 1, 1) & ~m1] = idx(0, 3)
    c[m1] = idx(0, 14)
    c[m2] = idx(12, 10)
    return c


def c5_raster_bars():
    """Classic rainbow raster bars behind black knockout 'VBXE 1024'."""
    c = canvas()
    bar = 6  # rows per bar
    hues = [4, 3, 2, 1, 15, 13, 12, 10, 8, 6]
    for y in range(LOGO_H):
        b, r = divmod(y + 1, bar)
        tri = [4, 8, 12, 14, 10, 6][r]  # shaded bar profile
        c[y, :] = idx(hues[b % len(hues)], tri)
    big = text_mask("VBXE 1024", "ATARI.F08", 3, 4)
    bm = place(big, centre_x(big), (LOGO_H - big.shape[0]) // 2)
    c[dilate(bm) & ~bm] = idx(0, 15)  # white rim
    c[bm] = 0  # knockout
    return c


def c6_four_by_256():
    """'1024' as four digits in the four palette tints (4 x 256 = 1024)."""
    c = canvas()
    digits = "1024"
    hues = [3, 12, 8, 1]  # red, green, blue, gold - like the ramps
    dm = [text_mask(d, "ATARI.F08", 4, 4) for d in digits]
    gap = 4
    total = sum(m.shape[1] for m in dm) + gap * 3
    lab = text_mask("VBXE", "ATARI.F08", 2, 2)
    lab2 = text_mask("4 x 256", "ATARI.F08")
    block = max(lab.shape[1], lab2.shape[1])
    x = (LOGO_W - (block + 10 + total)) // 2
    m1 = place(lab, x + (block - lab.shape[1]) // 2, 6)
    m2 = place(lab2, x + (block - lab2.shape[1]) // 2, 6 + lab.shape[0] + 5)
    c[m1] = idx(0, 14)
    c[m2] = idx(0, 9)
    x += block + 10
    for m, h in zip(dm, hues):
        mm = place(m, x, (LOGO_H - m.shape[0]) // 2)
        y0, y1 = rows_span(mm)
        c[shift(mm, 2, 2) & ~mm] = idx(h, 2)
        for y, xx in zip(*np.nonzero(mm)):
            c[y, xx] = idx(h, 14 - round(8 * (y - y0) / max(1, y1 - y0)))
        x += m.shape[1] + gap
    return c


BLUES = [7, 8, 9]  # blue -> light blue
GOLDS = [1, 15]  # gold, yellow-gold
DIAG_PERIOD = 16  # px along x+y per light->dark->light streak


def diag_luma(d):
    """Triangle wave over the 16-shade ramp along the diagonal, kept >= 4."""
    t = d % DIAG_PERIOD
    tri = t if t < DIAG_PERIOD // 2 else DIAG_PERIOD - 1 - t  # 0..7..0
    return 4 + round(tri * 11 / (DIAG_PERIOD // 2 - 1))


def family(hues):
    """hue_fn cycling through one hue family, one hue per diagonal streak."""
    return lambda d: hues[(d // DIAG_PERIOD) % len(hues)]


def blue_gold(d):
    """hue_fn alternating blue / gold streaks, each cycling its own family."""
    s = d // (DIAG_PERIOD // 2)
    fam = BLUES if s % 2 == 0 else GOLDS
    return fam[(s // 2) % len(fam)]


def chrome_diag(c, mask, hue_fn, outline=True):
    """Colour mask with 45-degree chrome streaks (+ a dark blue 1px outline)."""
    if outline:
        c[dilate(mask) & ~mask] = idx(7, 2)
    for y, x in zip(*np.nonzero(mask)):
        d = x + y
        c[y, x] = idx(hue_fn(d), diag_luma(d))


def mosaic_vbxe(top_fn, bot_fn):
    c = canvas()
    tx = mosaic_mask_draw(c, "VBXE", 4, track=0) + 10
    t1 = text_mask("1024 Colour", "ATARI.F08", 1, 2)
    t2 = text_mask("Slideshow", "ATARI.F08", 1, 2)
    gap = 3
    ty = (LOGO_H - (t1.shape[0] + gap + t2.shape[0])) // 2
    chrome_diag(c, place(t1, tx, ty), top_fn)
    chrome_diag(c, place(t2, tx, ty + t1.shape[0] + gap), bot_fn)
    return c


def c7_mosaic_vbxe_split():
    """Mosaic 'VBXE' + chrome '1024 Colour' (blue) over 'Slideshow' (gold)."""
    return mosaic_vbxe(family(BLUES), family(GOLDS))


def c8_mosaic_vbxe_mixed():
    """Mosaic 'VBXE' + both lines in alternating blue/gold chrome streaks."""
    return mosaic_vbxe(blue_gold, blue_gold)


# --- round 3: concept 7 refined -------------------------------------------------
M7_TRACK = 1  # right-hand text: +1 keeps a clear 1px gap between letter outlines
M7_LINE_GAP = 3  # rows between the two lines' outlines
M7_COL_GAP = 10  # mosaic -> text


def spread(total, n):
    """Split total into n near-equal integer parts, evenly interleaved."""
    return [round((i + 1) * total / n) - round(i * total / n) for i in range(n)]


def text_mask_stretched(s, target_w, fname="ATARI.F08", sy=1, track=0):
    """Like text_mask (sx=1), but each glyph cell is widened by duplicating ink
    columns (cols 1-6, evenly spread) so the cropped width is exactly target_w."""
    extra = target_w - text_mask(s, fname, 1, 1, track).shape[1]
    assert extra >= 0, (s, target_w)
    parts = []
    for ch, e in zip(s, spread(extra, len(s))):
        g = glyph(ch, fname)
        reps = np.ones(8, int)
        for k in range(e):
            reps[1 + int((k + 0.5) * 6 / e)] += 1
        parts.append(np.repeat(g, reps, axis=1))
        if track > 0:
            parts.append(np.zeros((8, track), bool))
    m = crop(np.concatenate(parts, axis=1))
    assert m.shape[1] == target_w, (s, m.shape[1], target_w)
    return np.kron(m, np.ones((sy, 1), bool))


def m7_variant(stretch, outline, final=False, drop_cols=(), x_rows=None):
    """Concept 7 refined: mosaic 'VBXE' the same height as the chrome text,
    letter outlines kept apart, 'Slideshow' centred or stretched under
    '1024 Colour', with or without the dark blue outline.  final: uniform
    3px mosaic blocks (27 rows) and a 3-row line gap so the text matches."""
    c = canvas()
    t1 = text_mask("1024 Colour", "ATARI.F08", 1, 2, M7_TRACK)
    if stretch:
        t2 = text_mask_stretched("Slideshow", t1.shape[1], "ATARI.F08", 2, M7_TRACK)
    else:
        t2 = text_mask("Slideshow", "ATARI.F08", 1, 2, M7_TRACK)
    ink_gap = M7_LINE_GAP if final else M7_LINE_GAP + 2  # outline rows sit inside the gap
    text_h = t1.shape[0] + ink_gap + t2.shape[0]  # ink extent
    pad = 1 if outline else 0  # visible extent adds the outline rows
    vis_h = text_h + 2 * pad
    top = (LOGO_H - vis_h) // 2  # visible top row
    ty = top + pad  # ink top row

    g = mosaic_mask("VBXE", 0)
    assert not g[:, list(drop_cols)].any(), drop_cols  # only close up blank columns
    if x_rows is not None:
        # re-stack the X's glyph rows (cell 2; V's ink starts at col 0, so the
        # crop didn't shift the 8-wide cells)
        assert g[:, 0].any()
        g[:, 16:24] = g[list(x_rows), 16:24]
    mw = (g.shape[1] - len(drop_cols)) * 4 - 1  # mosaic ink width
    total_w = mw + M7_COL_GAP + t1.shape[1] + 2 * pad
    mx = (LOGO_W - total_w) // 2
    tx = mx + mw + M7_COL_GAP + pad

    if final:
        assert mosaic_mask("VBXE", 0).shape[0] * 4 - 1 == vis_h, vis_h
        mosaic_mask_draw(c, "VBXE", mx, track=0, oy=top, drop_cols=drop_cols, mask=g)
    else:
        mosaic_mask_draw(c, "VBXE", mx, track=0, height=vis_h, oy=top)
    chrome_diag(c, place(t1, tx, ty), family(BLUES), outline)
    bx = tx + (t1.shape[1] - t2.shape[1]) // 2
    chrome_diag(c, place(t2, bx, ty + t1.shape[0] + ink_gap), family(GOLDS), outline)
    return c


def c9_m7_centred_outline():
    return m7_variant(stretch=False, outline=True)


def c10_m7_stretched_outline():
    return m7_variant(stretch=True, outline=True)


def c11_m7_centred_plain():
    return m7_variant(stretch=False, outline=False)


def c12_m7_stretched_plain():
    return m7_variant(stretch=True, outline=False)


def c13_m7_final():
    return m7_variant(stretch=False, outline=False, final=True)


def c14_m7_final_kern():
    """The menu header logo (exported to Assets/MENU.RAW): concept 13 with 'BXE'
    moved one block left - mosaic column 7 (blank, between V and B) removed."""
    return m7_variant(stretch=False, outline=False, final=True, drop_cols=(7,))


def c15_m7_final_x():
    """The menu header logo (exported to Assets/MENU.RAW): concept 14 with the X
    made top/bottom symmetrical - its glyph rows re-stacked as 1,2,3,4,3,2,1."""
    return m7_variant(stretch=False, outline=False, final=True, drop_cols=(7,),
                      x_rows=(0, 1, 2, 3, 2, 1, 0))


# --- menu separator (MENU_SEP_VRAM) ------------------------------------------------
SEP_W = 160  # MENU_SEP_PITCH: 1 row, lo-res (each px = 2 med-res px), palette 0
SEP_STREAK = DIAG_PERIOD  # lo-res px per light->dark->light streak
SEP_GOLD_CUT = 10  # gold_blue: golds at luma >= this sit at the centre, then blue takes over
SEP_GOLD_BLUE_1 = {  # gold_blue variants whose blue fade sticks to one hue
    "gold_blue7": [7],
    "gold_blue8": [8],
    "gold_blue9": [9],
}
SEP_STYLES = ("gold_blue7", "gold_blue8", "gold_blue9", "gold_blue", "blue", "mirror", "intertwined")


def brightness(rgb):
    """Rec.601 luma of an RGB triple (0-255)."""
    r, g, b = (float(v) for v in rgb)
    return 0.299 * r + 0.587 * g + 0.114 * b


def shades(hues, pal0, min_luma=0, below=None):
    """Palette-0 indices of every (hue, luma) in hues, brightest first (ties
    by hue order).  below: keep only shades darker than this brightness."""
    out = [(brightness(pal0[idx(h, l)]), k, idx(h, l))
           for k, h in enumerate(hues) for l in range(min_luma, 16)]
    if below is not None:
        out = [s for s in out if s[0] < below]
    return [i for _, _, i in sorted(out, key=lambda s: (-s[0], s[1]))]


def fade(order, half):
    """Left half of a centre-bright fade: `order` (brightest first) spread over
    `half` px, 1-2 px per shade - darkest at x=0, brightest at x=half-1."""
    return np.repeat(np.array(order[::-1], np.uint8), spread(half, len(order))[::-1])


def separator(style="blue"):
    """The 160-byte menu separator row, mirrored about the centre.
    'blue'      all 48 blue shades (hues 7/8/9), brightest at the centre,
                fading by measured brightness to the darkest at each end.
    'gold_blue' gold (hues 1/15, luma >= SEP_GOLD_CUT) at the centre, then the
                blues darker than that gold, fading out to each end.
    'gold_blueN' the same gold centre (same pixel widths), then a blue fade in
                hue N only (lumas 9..0) - no hue flicker between steps.
    'mirror'    16-px chrome streaks: blue 7, 8, 9 then gold 1, 15 - the logo's
                two chrome families (luma follows diag_luma).
    'intertwined' blue/gold streaks alternating every 8 px (blue_gold)."""
    half = SEP_W // 2
    if style in ("blue", "gold_blue") or style in SEP_GOLD_BLUE_1:
        pal0 = load_pal0()
        if style == "blue":
            order = shades(BLUES, pal0)
            left = fade(order, half)
        else:
            golds = shades(GOLDS, pal0, SEP_GOLD_CUT)
            darker = brightness(pal0[golds[-1]])
            blues = shades(BLUES if style == "gold_blue" else SEP_GOLD_BLUE_1[style], pal0, below=darker)
            order = golds + blues
            # the gold centre keeps the pixel widths of the original mixed
            # gold_blue; the blue fade fills the rest of the half
            gold_w = sum(spread(half, len(golds) + len(shades(BLUES, pal0, below=darker)))[:len(golds)])
            left = np.concatenate([fade(blues, half - gold_w), fade(golds, gold_w)])
        lum = [brightness(pal0[i]) for i in left]
        assert all(a <= b for a, b in zip(lum, lum[1:])), style  # dark -> bright
        assert len(set(left.tolist())) == len(order)
    elif style == "mirror":
        fams = BLUES + GOLDS
        assert len(fams) * SEP_STREAK == half
        hue_fn = lambda x: fams[x // SEP_STREAK]
    elif style == "intertwined":
        hue_fn = blue_gold
    else:
        raise ValueError(style)
    if style in ("mirror", "intertwined"):
        left = np.array([idx(hue_fn(x), diag_luma(x)) for x in range(half)], np.uint8)
    sep = np.concatenate([left, left[::-1]])
    assert sep.shape == (SEP_W,) and (sep == sep[::-1]).all()
    return sep


def rule_attrs(sep, pal0):
    """The separator as 80 text-mode attrs (one char = 2 lo-res px), for the
    .nfo ==== rule.  Text mode only reaches palette-0 entries 0-127 (even
    lumas): an odd-luma entry 128+e drops to its even neighbour e.  Each char
    takes the brighter of its two px, which keeps the result symmetrical."""
    out = []
    for c in range(SEP_W // 2):
        pair = sep[2 * c:2 * c + 2]
        i = int(max(pair, key=lambda j: (brightness(pal0[j]), j)))
        out.append(i & 0x7F)
    assert out == out[::-1]
    return out


def write_rule_attrs(attrs):
    """Rewrite RULE_ATTRS between the markers in nfo_encode.py."""
    path = os.path.join(HERE, "nfo_encode.py")
    src = open(path).read()
    head, rest = src.split("# RULE_ATTRS-BEGIN\n")
    _, tail = rest.split("# RULE_ATTRS-END\n")
    rows = [", ".join("0x%02X" % a for a in attrs[i:i + 10]) for i in range(0, len(attrs), 10)]
    body = "RULE_ATTRS = [\n" + "".join("    %s,\n" % r for r in rows) + "]\n"
    with open(path, "w", newline="\n") as f:
        f.write(head + "# RULE_ATTRS-BEGIN\n" + body + "# RULE_ATTRS-END\n" + tail)


def sep_preview(sep, pal0, rows=4):
    """RGB preview: each lo-res px doubled to 320 wide, `rows` tall."""
    return np.repeat(np.tile(pal0[sep][None], (rows, 1, 1)), 2, axis=1)


CONCEPTS = [
    ("hue_sweep", c1_hue_sweep),
    ("spectrum_swatch", c2_spectrum_swatch),
    ("chrome", c3_chrome),
    ("mosaic", c4_mosaic),
    ("raster_bars", c5_raster_bars),
    ("four_by_256", c6_four_by_256),
    ("mosaic_vbxe_split", c7_mosaic_vbxe_split),
    ("mosaic_vbxe_mixed", c8_mosaic_vbxe_mixed),
    ("m7_centred_outline", c9_m7_centred_outline),
    ("m7_stretched_outline", c10_m7_stretched_outline),
    ("m7_centred_plain", c11_m7_centred_plain),
    ("m7_stretched_plain", c12_m7_stretched_plain),
    ("m7_final", c13_m7_final),
    ("m7_final_kern", c14_m7_final_kern),
    ("m7_final_x", c15_m7_final_x),
]


# --- rendering -------------------------------------------------------------------
def banner_mock(logo_rgb, pal0):
    """320x34 RGB banner: the logo at x 32 plus the edge ramp squares."""
    pals = [pal0, ramp_pal(0), ramp_pal(1), ramp_pal(2)]
    ramp = np.arange(256, dtype=np.uint8).reshape(16, 16)
    img = np.zeros((BANNER_H, BANNER_W, 3), np.uint8)
    img[:, LOGO_X:LOGO_X + LOGO_W] = logo_rgb
    # left block TL=0 TR=1 / BL=2 BR=3; right block mirrored via attributes
    layout = [(0, 0, 0), (0, 16, 1), (DEMO_ROW_BOT, 0, 2), (DEMO_ROW_BOT, 16, 3),
              (0, 288, 1), (0, 304, 0), (DEMO_ROW_BOT, 288, 3), (DEMO_ROW_BOT, 304, 2)]
    for y, x, p in layout:
        img[y:y + DEMO_SQ, x:x + DEMO_SQ] = pals[p][ramp]
    return img


def scale(img, n):
    return np.kron(img, np.ones((n, n, 1), np.uint8)) if img.ndim == 3 else np.kron(img, np.ones((n, n)))


def save_rgb(arr, path):
    Image.fromarray(arr, "RGB").save(path)


def palette_swatch(pal0):
    cell = 12
    img = np.zeros((16 * cell, 16 * cell, 3), np.uint8)
    for i in range(256):
        r, col = divmod(i, 16)
        img[r * cell:(r + 1) * cell - 1, col * cell:(col + 1) * cell - 1] = pal0[i]
    return img


def export(logo):
    raw = np.zeros((BANNER_ROWS, BANNER_W), np.uint8)
    raw[:LOGO_H, LOGO_X:LOGO_X + LOGO_W] = logo
    path = os.path.join(ASSETS, "MENU.RAW")
    raw.tofile(path)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=OUT_DIR)
    ap.add_argument("--export", type=int, metavar="N", help="write Viewer/Assets/MENU.RAW for concept N (1-based)")
    ap.add_argument("--export-sep", choices=SEP_STYLES, metavar="STYLE",
                    help="write Viewer/Assets/MENU_SEP.RAW (%s)" % "|".join(SEP_STYLES))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    pal0 = load_pal0()
    save_rgb(palette_swatch(pal0), os.path.join(args.out, "palette0_modified.png"))
    pal_set = {tuple(p) for p in pal0}

    sheet_scale, label_h, pad = 3, 18, 6
    sheet_w = BANNER_W * sheet_scale + pad * 2
    sheet_h = len(CONCEPTS) * (BANNER_H * sheet_scale + label_h + pad) + pad
    sheet = Image.new("RGB", (sheet_w, sheet_h), (24, 24, 24))
    draw = ImageDraw.Draw(sheet)

    for n, (name, fn) in enumerate(CONCEPTS, 1):
        logo = fn()
        assert logo.shape == (LOGO_H, LOGO_W) and logo.dtype == np.uint8
        rgb = pal0[logo]
        assert all(tuple(p) in pal_set for p in rgb.reshape(-1, 3)), name
        base = os.path.join(args.out, f"logo_{n}_{name}")
        save_rgb(rgb, base + ".png")
        save_rgb(scale(rgb, 4), base + "_x4.png")
        y = pad + (n - 1) * (BANNER_H * sheet_scale + label_h + pad)
        draw.text((pad, y + 2), f"{n}. {name}", fill=(220, 220, 220))
        sheet.paste(Image.fromarray(scale(banner_mock(rgb, pal0), sheet_scale), "RGB"), (pad, y + label_h))
        print(f"  {n}. {name:16s} {len(np.unique(logo)):3d} colours")

    sheet.save(os.path.join(args.out, "logo_sheet.png"))
    print(f"wrote {len(CONCEPTS)} concepts + sheet to {args.out}")

    # separator previews: each style alone, plus under the current logo (15)
    logo_rgb = banner_mock(pal0[CONCEPTS[-1][1]()], pal0)
    gap = np.zeros((2, BANNER_W, 3), np.uint8)
    mock_h = BANNER_H + 2 + 1 + 2  # logo, gap, separator row, gap
    sep_sheet = Image.new("RGB", (sheet_w, pad + len(SEP_STYLES) * (mock_h * sheet_scale + label_h + pad)),
                          (24, 24, 24))
    draw = ImageDraw.Draw(sep_sheet)
    for n, style in enumerate(SEP_STYLES):
        prev = sep_preview(separator(style), pal0)
        save_rgb(scale(prev, 4), os.path.join(args.out, f"sep_{style}.png"))
        mock = np.concatenate([logo_rgb, gap, prev[:1], gap])
        y = pad + n * (mock_h * sheet_scale + label_h + pad)
        draw.text((pad, y + 2), style, fill=(220, 220, 220))
        sep_sheet.paste(Image.fromarray(scale(mock, sheet_scale), "RGB"), (pad, y + label_h))
    sep_sheet.save(os.path.join(args.out, "sep_sheet.png"))
    print(f"wrote separator previews ({', '.join(SEP_STYLES)}) to {args.out}")

    if args.export:
        name, fn = CONCEPTS[args.export - 1]
        path = export(fn())
        print(f"exported {path} for {args.export}. {name}")

    if args.export_sep:
        path = os.path.join(ASSETS, "MENU_SEP.RAW")
        sep = separator(args.export_sep)
        sep.tofile(path)
        print(f"exported {path} ({args.export_sep})")
        write_rule_attrs(rule_attrs(sep, pal0))
        print("updated RULE_ATTRS in nfo_encode.py (the .nfo ==== rule)")


if __name__ == "__main__":
    main()
