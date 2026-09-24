"""imageslst.py - build IMAGES.LST, the manifest the Atari viewer reads for
the selector status line's "Src: <original filename>" text.

THE ATARI DISK ONLY HOLDS 8.3 SHORT NAMES.  isabelle_fuhrman_eyes.jpg becomes
IMG0.MAP on the way to SpartaDOS X, and the long name is lost from the file
system.  It survives inside each image's .NFO as record 1 - the
"Input                : <name>" line palettize4.py writes.  The viewer used to
open every .NFO as the cursor passed over its row; that stutters a fresh
directory badly.  Instead this builds the long names once, off the Atari, into
one small file the viewer slurps in a single pass at scan time.

QT-FREE, like everything outside ui/ - it is called both from the GUI's File
menu (ui/main.py) and from the standalone build_images_lst.py, and it is
unit-tested without a display.

ONE RECORD PER IMAGE, $9B-TERMINATED (Atari CIO text, NOT "\\n").  Each record
is an 8-byte key - the .MAP base name, first 8 chars, upper-cased, space-padded,
exactly what SDX shows - followed by the source filename (<= NAME_CAP chars).
The viewer matches a record to a listing row by that key, so order does not
matter and a stale entry for a file that is not on the disk is simply ignored.
Run it on the folder you build the disk image from.
"""

import glob
import os
import re

KEY_LEN = 8              # .MAP base-name key; matches SDX's on-disk short name
NAME_CAP = 48            # chars the viewer's status line can show
EOL = 0x9B               # Atari end-of-line; SDX CIO GET RECORD splits on this

#: Everything a SpartaDOS X 8.3 name cannot hold.  A host-folder -> disk-image
#: step DROPS these and closes the gap, so "Charger 01" lands as CHARGER0, not
#: "CHARGER ".  '_' IS legal and is kept (Chrome_cr -> CHROME_C,
#: FJ_Marceline_300 -> FJ_MARCE on the disk).  Strip before truncating or the
#: key stops matching at the first space.
_ATARI_BADCHARS = re.compile(r"[^A-Za-z0-9_]")

_NFO_PITCH = 160         # bytes per .NFO line record (80 {glyph,attr} pairs)
_NFO_VALUE_OFF = 46      # record-1 byte offset of cell 23's glyph (value start)
_REPORT_VALUE_COL = 23   # _report.txt: column the Input value starts at


def _key(map_path):
    """The 8-byte match key for one .MAP path.

    Illegal chars (space, '.', '-', ...) stripped but '_' kept, then upper-cased,
    first 8, space-padded - the name the viewer reads back off the Atari disk.
    "Charger 01.map" -> "CHARGER0", "Chrome_cr.map" -> "CHROME_C".
    """
    stem = _ATARI_BADCHARS.sub("", os.path.splitext(os.path.basename(map_path))[0])
    return stem[:KEY_LEN].upper().ljust(KEY_LEN)


def _long_name(map_path):
    """Recover the original source filename for one .MAP file.

    Prefers the sibling .NFO (record 1), then <stem>_report.txt line 2, then
    finally the stem itself so a bare .MAP still gets a sensible label.
    """
    stem = os.path.splitext(map_path)[0]

    nfo = stem + ".nfo"
    if os.path.isfile(nfo):
        with open(nfo, "rb") as f:
            data = f.read()
        rec1 = data[_NFO_PITCH:_NFO_PITCH * 2]
        if len(rec1) == _NFO_PITCH:
            name = bytes(rec1[_NFO_VALUE_OFF::2]).decode("latin-1").rstrip()
            if name:
                return name

    report = stem + "_report.txt"
    if os.path.isfile(report):
        with open(report, "r", errors="replace") as f:
            f.readline()                      # record 0 - the banner
            line = f.readline().rstrip("\n")
        name = line[_REPORT_VALUE_COL:].rstrip()
        if name:
            return name

    return os.path.basename(stem)


def scan(folder):
    """[(key, name), ...] for every .MAP or .V1K under folder, deduped, sorted
    by key.

    Looks in folder itself AND one level down - the GUI writes
    out/<image>/<image>.map, a raw palettize4.py run writes them flat.  A
    disk folder for the single-file viewer may hold only .V1K (packed by
    pack_v1k.py) + .NFO, so .V1K counts as an image too; the key is the same
    base name either way.
    """
    paths = []
    for ext in ("map", "MAP", "v1k", "V1K"):
        for pat in ("*." + ext, os.path.join("*", "*." + ext)):
            paths.extend(glob.glob(os.path.join(folder, pat)))

    rows, seen = [], set()
    for path in sorted(paths):
        key = _key(path)
        if key in seen:                      # case-insensitive FS lists it twice
            continue
        seen.add(key)
        rows.append((key, _long_name(path)[:NAME_CAP]))

    rows.sort(key=lambda r: [ord(c) for c in r[0]])
    return rows


def build(folder):
    """The IMAGES.LST byte image for folder."""
    out = bytearray()
    for key, name in scan(folder):
        out += key.encode("latin-1")
        out += name.encode("latin-1", "replace")
        out.append(EOL)
    return bytes(out)


def write(folder, path=None):
    """Write IMAGES.LST (default: into folder).  Returns (path, record count)."""
    data = build(folder)
    if path is None:
        path = os.path.join(folder, "images.lst")
    with open(path, "wb") as f:
        f.write(data)
    return path, data.count(EOL)
