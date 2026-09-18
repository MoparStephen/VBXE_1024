#!/usr/bin/env python3
"""Re-encode a plain-text report into the viewer-native binary .NFO.

palettize4.py writes both {name}_report.txt and {name}.nfo directly; this
standalone tool is for restaging older/hand-edited text reports without a full
reconversion.  The output is the byte image of the Atari viewer's 80-column
VBXE text screen: fixed 160-byte line records of 80 {glyph, attr=$07} cell
pairs, space-padded, no terminators, plus one all-$00 record marking the end.
Every input line must be <= 80 characters (the viewer contract).

    python nfo_encode.py Chrome_cr_report.txt Chrome_cr.nfo
    python nfo_encode.py in.txt            # -> in.nfo
"""

import sys, os

NFO_COLS = 80
ATTR = 0x07


def encode(text):
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    while lines and lines[-1] == "":
        lines.pop()                       # trailing newline(s) are not records
    out = bytearray()
    for ln in lines:
        for ch in ln[:NFO_COLS].ljust(NFO_COLS):   # clip to the 80-col screen
            out.append(ord(ch) & 0xFF)
            out.append(ATTR)
    out.extend(b"\x00" * (NFO_COLS * 2))  # end-of-text sentinel record
    return bytes(out)


def main(argv):
    if not 1 <= len(argv) <= 2:
        raise SystemExit(__doc__)
    src = argv[0]
    dst = argv[1] if len(argv) == 2 else os.path.splitext(src)[0] + ".nfo"
    with open(src, "r") as f:
        data = encode(f.read())
    with open(dst, "wb") as f:
        f.write(data)
    print("%s -> %s  (%d records)" % (src, dst, len(data) // (NFO_COLS * 2)))


if __name__ == "__main__":
    main(sys.argv[1:])
