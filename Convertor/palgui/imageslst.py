"""imageslst.py - build IMAGES.LST, the manifest the Atari viewer reads for
the selector status line's "Src: <description>" text.

THE DESCRIPTION IS THE USER'S, NOT THE FILENAME.  palettize4.py --description
(the GUI's Source > description field) stores it in {name}_stats.json; left
blank, it is the source filename minus its extension.  The original filename is
already on the image's Info screen (the .NFO's Input line), so the status line
is free to say something more useful.  The viewer used to open every .NFO as
the cursor passed over its row; that stutters a fresh directory badly.  Instead
this collects the descriptions once, off the Atari, into one small file the
viewer slurps in a single pass at scan time.

QT-FREE, like everything outside ui/ - it is called both from the GUI's File
menu (ui/main.py) and from the standalone build_images_lst.py, and it is
unit-tested without a display.

ONE RECORD PER IMAGE, $9B-TERMINATED (Atari CIO text, NOT "\\n").  Each record
is an 8-byte key - the .MAP base name, first 8 chars, upper-cased, space-padded,
exactly what SDX shows - followed by the description (<= NAME_CAP chars).
The viewer matches a record to a listing row by that key, so order does not
matter and a stale entry for a file that is not on the disk is simply ignored.
Run it on the folder you build the disk image from.
"""

import glob
import json
import os
import sys

# atari_name.py lives beside palettize4.py (one level up) so the standalone
# converter can use it without importing palgui; make it importable from here.
_CONVERTOR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _CONVERTOR not in sys.path:
    sys.path.insert(0, _CONVERTOR)
import atari_name  # noqa: E402

KEY_LEN = 8              # .MAP base-name key; matches SDX's on-disk short name
NAME_CAP = 75            # chars the viewer's status line can show ("Src: " + 75
                         # = 80 cols); = palettize4.DESC_CAP = NFO_NAME_CAP
EOL = 0x9B               # Atari end-of-line; SDX CIO GET RECORD splits on this

_NFO_PITCH = 160         # bytes per .NFO line record (80 {glyph,attr} pairs)
_NFO_VALUE_OFF = 46      # record-1 byte offset of cell 23's glyph (value start)
_REPORT_VALUE_COL = 23   # _report.txt: column the Input value starts at


def _key(map_path):
    """The 8-byte match key for one .MAP path.

    atari_name.short_name() of the base name, space-padded - the same rule the
    converter names its files with, so it is the name the viewer reads back off
    the Atari disk.  "Charger 01.map" -> "CHARGER0", "Chrome_cr.map" ->
    "CHROME_C", "2024 trip.v1k" -> "I2024TRI".
    """
    return key_for(os.path.splitext(os.path.basename(map_path))[0])


def key_for(name):
    """The 8-byte key for a base name (legalised, then space-padded)."""
    return atari_name.short_name(name).ljust(KEY_LEN)


def _description(map_path):
    """The status-line description for one .MAP / .V1K file.

    Prefers <stem>_stats.json's "description" (what palettize4 wrote, default
    already applied).  A conversion older than that falls back to what the
    converter would have defaulted to - the source filename without its
    extension - taken from the .NFO Input line, then the _report.txt one, and
    finally the stem itself so a bare .MAP still gets a sensible label.
    """
    stem = os.path.splitext(map_path)[0]
    stats = stem + "_stats.json"
    if os.path.isfile(stats):
        try:
            with open(stats, "r", encoding="utf-8") as f:
                desc = str(json.load(f).get("description") or "").strip()
        except (OSError, ValueError):       # noqa: BLE001 - fall back below
            desc = ""
        if desc:
            return desc
    return os.path.splitext(_long_name(map_path))[0].rstrip(".")


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
        rows.append((key, _description(path)[:NAME_CAP]))

    rows.sort(key=lambda r: [ord(c) for c in r[0]])
    return rows


def build(folder):
    """The IMAGES.LST byte image for folder."""
    return build_rows(scan(folder))


def build_rows(rows):
    """The IMAGES.LST byte image for [(key, description), ...] - for callers
    (palgui.gather) that know the descriptions from somewhere other than the
    folder being indexed.  Rows are written in key order, names capped."""
    out = bytearray()
    for key, name in sorted(rows, key=lambda r: [ord(c) for c in r[0]]):
        name = name[:NAME_CAP]
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
