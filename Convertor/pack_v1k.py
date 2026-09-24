#!/usr/bin/env python3
"""Pack each converted image's .PAL + .MAP + .RAW into one .V1K file.

The single-file viewer opens ONE file per image instead of three.  A .V1K is
the three files concatenated in that order with NO header - every block is a
fixed size, so the viewer's offsets are constants:

    .pal   3072 bytes   4 palettes x 256 x RGB   -> VBXE $21000
    .map   9600 bytes   40 cells x 240 rows      -> VBXE $14000
    .raw  76800 bytes   320 x 240 pixels         -> VBXE $01000
    ----- 89472 bytes

.PAL comes first so the viewer's P-preview can read just the palettes and
close.  A wrong size anywhere is refused rather than packed, because the
viewer cannot tell a short block from the start of the next one.

    python pack_v1k.py OUTDIR [...]              # each .v1k beside its .map
    python pack_v1k.py OUTDIR --out DISKDIR      # all .v1k into one folder
    python pack_v1k.py out/alicia/alicia.map     # one image

A folder is searched itself and one level down (the GUI writes
out/<image>/<image>.map, a raw palettize4.py run writes them flat).
"""

import argparse
import glob
import os
import sys

BLOCKS = ((".pal", 3072), (".map", 9600), (".raw", 76800))
V1K_LEN = sum(size for _, size in BLOCKS)


def find_maps(target):
    """Every .map path named by target (a .map file or a folder)."""
    if os.path.isfile(target):
        return [target]
    paths = []
    for ext in ("map", "MAP"):
        for pat in ("*." + ext, os.path.join("*", "*." + ext)):
            paths.extend(glob.glob(os.path.join(target, pat)))
    seen, out = set(), []
    for path in sorted(paths):
        norm = os.path.normcase(os.path.abspath(path))
        if norm not in seen:                 # case-insensitive FS lists it twice
            seen.add(norm)
            out.append(path)
    return out


def pack(map_path, out_dir=None):
    """Write <stem>.v1k for one image.  Returns its path; raises ValueError."""
    stem = os.path.splitext(map_path)[0]
    data = bytearray()
    for ext, size in BLOCKS:
        path = stem + ext
        if not os.path.isfile(path):
            raise ValueError("%s: missing" % path)
        with open(path, "rb") as f:
            block = f.read()
        if len(block) != size:
            raise ValueError("%s: %d bytes, expected %d"
                             % (path, len(block), size))
        data += block
    assert len(data) == V1K_LEN
    base = os.path.basename(stem) + ".v1k"
    dst = os.path.join(out_dir, base) if out_dir else stem + ".v1k"
    with open(dst, "wb") as f:
        f.write(data)
    return dst


def main(argv):
    ap = argparse.ArgumentParser(
        description="Pack .pal + .map + .raw into single-file .v1k images.")
    ap.add_argument("targets", nargs="+",
                    help="converter output folder(s) or .map file(s)")
    ap.add_argument("--out", help="write every .v1k into this folder "
                                  "(default: beside its .map)")
    args = ap.parse_args(argv)

    if args.out:
        os.makedirs(args.out, exist_ok=True)

    maps = []
    for target in args.targets:
        found = find_maps(target)
        if not found:
            print("%s: no .map files found" % target, file=sys.stderr)
        maps.extend(found)

    packed = failed = 0
    for path in maps:
        try:
            print(pack(path, args.out))
            packed += 1
        except ValueError as exc:
            print("skipped - %s" % exc, file=sys.stderr)
            failed += 1

    print("%d packed, %d skipped" % (packed, failed))
    return 1 if failed or not packed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
