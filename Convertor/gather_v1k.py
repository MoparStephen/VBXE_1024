#!/usr/bin/env python3
"""Gather converted images into one Atari staging folder.

Recursively scans ROOT for .v1k files, copies each (with its .nfo) into OUTDIR
under a legal 8-char Atari name, and writes OUTDIR/images.lst - the manifest
the viewer's selector reads for each image's description.  Older
conversions with long names are renamed on the way over ("Charger 01.v1k" ->
CHARGER0.v1k); names that collide get a counter (CHARGE01, CHARGE02 ...).

    python gather_v1k.py ROOT OUTDIR             # copy + images.lst
    python gather_v1k.py ROOT OUTDIR --dry-run   # just show what would happen
    python gather_v1k.py ROOT OUTDIR --clean     # empty OUTDIR's old images first
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from palgui import gather


def main(argv):
    ap = argparse.ArgumentParser(
        description="Collect .v1k + .nfo files into an Atari staging folder "
                    "with 8-char names and an images.lst.")
    ap.add_argument("root", help="folder to scan (recursively) for .v1k files")
    ap.add_argument("outdir", help="staging folder to copy them into")
    ap.add_argument("--dry-run", action="store_true",
                    help="list what would be copied/renamed; write nothing")
    ap.add_argument("--clean", action="store_true",
                    help="delete .v1k/.nfo/images.lst already in OUTDIR first")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.root):
        raise SystemExit("%s: not a folder" % args.root)

    if args.dry_run:
        items = gather.plan(args.root, args.outdir)
    else:
        items, manifest = gather.run(args.root, args.outdir, do_clean=args.clean)
    for it in items:
        print(it.line())
    print(gather.summary(items))
    if not args.dry_run:
        print("manifest: %s" % manifest)
    ok = any(not i.problem for i in items)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
