#!/usr/bin/env python3
"""Encode a plain-text report into the viewer-native binary .NFO, in colour.

palettize4.py writes {name}.nfo through encode() here; this tool also
restages older files without a full reconversion.  The output is the byte
image of the Atari viewer's 80-column VBXE text screen: fixed 160-byte line
records of 80 {glyph, attr} cell pairs, space-padded, no terminators, plus
one all-$00 record marking the end.  Every input line must be <= 80
characters (the viewer contract).

The attr byte is the VBXE text-mode colour: bits 0-6 = palette-0 entry
e = hue*8 + luma/2 (the viewer's de-interleaved palette, even lumas only),
bit 7 = opaque background (never set here).  line_attrs() colours the
palettize_4 report layout - gold labels, blue values; see PEN_* below, which
ui.asm's UI_PEN_* mirror for the selector screen.

    python nfo_encode.py Chrome_cr_report.txt Chrome_cr.nfo
    python nfo_encode.py in.txt                # -> in.nfo
    python nfo_encode.py old.nfo               # recolour an existing .nfo in place
    python nfo_encode.py Viewer/out            # recolour every *.nfo under a folder
    python nfo_encode.py x.nfo --preview x.png # render it as the viewer shows it
"""

import sys, os, re

NFO_COLS = 80
RECORD = NFO_COLS * 2


def pen(hue, luma):
    """Atari (hue, even luma) -> VBXE text-mode foreground entry."""
    return hue * 8 + luma // 2


# Colour scheme - mirrored by UI_PEN_* in Viewer/ui.asm.
PEN_LABEL = pen(15, 8)    # $7C gold        - the category left of ':'
PEN_SEP = pen(8, 8)       # $44 blue        - the ':' itself
PEN_RULE = pen(7, 8)      # $3C deep blue   - the ==== banner rule
PEN_VALUE = pen(7, 4)     # $3A blue        - everything right of ':'
PEN_NOTE = pen(8, 6)      # $43 blue        - ( ... ) and <- ... asides
PEN_TITLE = pen(1, 14)    # $0F bright gold - banner title, section headings
PEN_GOOD = pen(12, 12)    # $66 green       - LOSSLESS
PEN_BAD = pen(3, 6)       # $1B red         - LOSSY
PEN_PLAIN = pen(0, 14)    # $07 near-white  - the old single pen

# The ==== banner rule follows the menu separator bar's colours, one char per
# 2 lo-res separator px.  Written by Convertor/make_logo.py --export-sep from
# the exported separator - don't hand-edit between the markers.
# RULE_ATTRS-BEGIN
RULE_ATTRS = [
    0x38, 0x38, 0x38, 0x38, 0x38, 0x39, 0x39, 0x39, 0x39, 0x39,
    0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3B, 0x3B, 0x3B, 0x3B,
    0x3B, 0x3C, 0x3C, 0x3C, 0x3C, 0x3C, 0x3D, 0x3D, 0x3D, 0x7D,
    0x0D, 0x7D, 0x7E, 0x7E, 0x7E, 0x7E, 0x7F, 0x0F, 0x7F, 0x0F,
    0x0F, 0x7F, 0x0F, 0x7F, 0x7E, 0x7E, 0x7E, 0x7E, 0x7D, 0x0D,
    0x7D, 0x3D, 0x3D, 0x3D, 0x3C, 0x3C, 0x3C, 0x3C, 0x3C, 0x3B,
    0x3B, 0x3B, 0x3B, 0x3B, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A,
    0x39, 0x39, 0x39, 0x39, 0x39, 0x38, 0x38, 0x38, 0x38, 0x38,
]
# RULE_ATTRS-END

ROW_COLON = 21           # palettize4 row(): label cols 0-20, ':' at 21
RULE_RE = re.compile(r"^(=+)([^=].*?)(=+)$")
RESULT_RE = re.compile(r"^(RESULT)(:)(\s*)(LOSSLESS|LOSSY)")


def _value(attrs, line, start, end=None):
    """Colour line[start:end] as a value: VALUE, with ( ... ) and a trailing
    '<- ...' aside in NOTE."""
    end = len(line) if end is None else end
    depth = 0
    aside = False
    for i in range(start, end):
        ch = line[i]
        if line.startswith("<-", i):
            aside = True
        if ch == "(":
            depth += 1
        attrs[i] = PEN_NOTE if (depth or aside) else PEN_VALUE
        if ch == ")" and depth:
            depth -= 1


def line_attrs(line):
    """80 attr bytes for one report line (cells past the text get PEN_PLAIN -
    they are spaces, so the colour never shows)."""
    line = line[:NFO_COLS]
    attrs = [PEN_PLAIN] * NFO_COLS
    if not line.strip():
        return attrs
    m = RULE_RE.match(line)
    if m:                                             # =====title=====
        a, t = len(m.group(1)), len(m.group(2))
        for i in range(len(line)):
            attrs[i] = PEN_TITLE if a <= i < a + t else RULE_ATTRS[i]
        return attrs
    m = RESULT_RE.match(line)
    if m:                                             # RESULT: LOSSY ...
        attrs[0:6] = [PEN_LABEL] * 6
        attrs[6] = PEN_SEP
        v0 = m.start(4)
        good = m.group(4) == "LOSSLESS"
        attrs[v0:m.end(4)] = [PEN_GOOD if good else PEN_BAD] * len(m.group(4))
        _value(attrs, line, m.end(4))
        return attrs
    if len(line) > ROW_COLON and line[ROW_COLON] == ":" and line[:ROW_COLON].strip():
        colon = ROW_COLON                             # row(): label : value
    elif line.startswith(" " * (ROW_COLON + 2)):      # cont(): value only
        _value(attrs, line, 0)
        return attrs
    elif line.rstrip().endswith(":"):                 # Section heading:
        attrs[:len(line)] = [PEN_TITLE] * len(line)
        return attrs
    elif ": " in line:                                # free-form "label: value"
        colon = line.index(": ")
    else:
        _value(attrs, line, 0)
        return attrs
    attrs[:colon] = [PEN_LABEL] * colon
    attrs[colon] = PEN_SEP
    _value(attrs, line, colon + 1)
    return attrs


def encode(text):
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    while lines and lines[-1] == "":
        lines.pop()                       # trailing newline(s) are not records
    out = bytearray()
    for ln in lines:
        ln = ln[:NFO_COLS]                # clip to the 80-col screen
        for ch, attr in zip(ln.ljust(NFO_COLS), line_attrs(ln)):
            out.append(ord(ch) & 0xFF)
            out.append(attr)
    out.extend(b"\x00" * RECORD)          # end-of-text sentinel record
    return bytes(out)


def decode(data):
    """A .nfo's text, one line per record up to the sentinel (trailing
    spaces stripped) - the inverse of encode() for recolouring."""
    lines = []
    for r in range(0, len(data) - RECORD + 1, RECORD):
        rec = data[r:r + RECORD]
        if not any(rec):
            break
        lines.append(bytes(rec[0::2]).decode("latin-1").rstrip())
    return "\n".join(lines) + "\n"


def preview(data, png_path, scale=2):
    """Render a .nfo the way the viewer shows it: CGA.F08 glyphs, palette 0."""
    import numpy as np
    from PIL import Image
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    from make_logo import load_pal0
    font = open(os.path.join(here, "..", "Viewer", "Assets", "CGA.F08"), "rb").read()
    pal0 = load_pal0()
    rows = max(1, len(data) // RECORD - 1)
    img = np.zeros((rows * 8, NFO_COLS * 8, 3), np.uint8)
    for r in range(rows):
        for c in range(NFO_COLS):
            g, a = data[r * RECORD + c * 2], data[r * RECORD + c * 2 + 1]
            for y in range(8):
                bits = font[g * 8 + y]
                for x in range(8):
                    if bits & (0x80 >> x):
                        img[r * 8 + y, c * 8 + x] = pal0[a & 0x7F]
    img = np.repeat(np.repeat(img, scale, 0), scale, 1)
    Image.fromarray(img, "RGB").save(png_path)


def _recolour(path):
    with open(path, "rb") as f:
        data = encode(decode(f.read()))
    with open(path, "wb") as f:
        f.write(data)
    return data


def main(argv):
    png = None
    if "--preview" in argv:
        i = argv.index("--preview")
        png = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if not 1 <= len(argv) <= 2:
        raise SystemExit(__doc__)
    src = argv[0]
    if os.path.isdir(src):
        n = 0
        for root, _, files in os.walk(src):
            for fn in files:
                if fn.lower().endswith(".nfo"):
                    _recolour(os.path.join(root, fn))
                    n += 1
        print("recoloured %d .nfo files under %s" % (n, src))
        return
    if src.lower().endswith(".nfo") and len(argv) == 1:
        data = _recolour(src)
        print("%s recoloured  (%d records)" % (src, len(data) // RECORD))
    else:
        dst = argv[1] if len(argv) == 2 else os.path.splitext(src)[0] + ".nfo"
        with open(src, "r") as f:
            data = encode(f.read())
        with open(dst, "wb") as f:
            f.write(data)
        print("%s -> %s  (%d records)" % (src, dst, len(data) // RECORD))
    if png:
        preview(data, png)
        print("preview -> %s" % png)


if __name__ == "__main__":
    main(sys.argv[1:])
