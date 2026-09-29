#!/usr/bin/env python3
"""Build IMAGES.LST for a folder of converter output.

The Atari viewer reads IMAGES.LST at directory-scan time to show each image's
description (from its _stats.json, else the source filename minus extension)
on the selector status line.  It is an 8-byte key (the .MAP base name,
upper-cased, space-padded) plus that description per record, $9B-terminated.  Run this on the folder you build the disk image from
so the keys line up with the on-disk 8.3 names.

    python build_images_lst.py OUTDIR                # -> OUTDIR/images.lst
    python build_images_lst.py OUTDIR path/to/images.lst
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from palgui.imageslst import write


def main(argv):
    if not 1 <= len(argv) <= 2:
        raise SystemExit(__doc__)
    folder = argv[0]
    dst = argv[1] if len(argv) == 2 else None
    path, count = write(folder, dst)
    print("%s  (%d entr%s)" % (path, count, "y" if count == 1 else "ies"))


if __name__ == "__main__":
    main(sys.argv[1:])
