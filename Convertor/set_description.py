#!/usr/bin/env python3
"""Change the description of converted images without re-converting them.

Rewrites the four files that carry it - {name}_stats.json (what Gather puts in
IMAGES.LST), {name}_report.txt, {name}.nfo (the Atari Info screen) and
{name}_summary.txt - and nothing else.  See palgui/describe.py.

    python set_description.py out --export descriptions.txt   # current values
    python set_description.py out --apply descriptions.txt    # dry run
    python set_description.py out --apply descriptions.txt --go
    python set_description.py "out/Charger 01" "1970 Dodge Charger" --go

Without --go nothing is written; the old -> new list is shown instead.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from palgui import describe


def main(argv):
    ap = argparse.ArgumentParser(
        description="Set conversions' descriptions (stats, report, .nfo, "
                    "summary) without re-converting.")
    ap.add_argument("folder", help="a conversion folder, or with --export / "
                                   "--apply the folder holding them (out)")
    ap.add_argument("text", nargs="?", default=None,
                    help="the new description for one folder")
    ap.add_argument("--export", metavar="LIST",
                    help="write every folder's current description to LIST")
    ap.add_argument("--apply", metavar="LIST",
                    help="set every description named in LIST")
    ap.add_argument("--go", action="store_true",
                    help="actually write (default is a dry run)")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.folder):
        raise SystemExit("%s: not a folder" % args.folder)

    if args.export:
        n = describe.export_list(args.folder, args.export)
        print("%d descriptions written to %s - edit it, then --apply it"
              % (n, args.export))
        return 0

    if args.apply:
        rows = describe.apply_list(args.folder, args.apply,
                                   dry_run=not args.go)
    elif args.text is not None:
        try:
            old, new, files = describe.set_description(
                args.folder, args.text, dry_run=not args.go)
            rows = [(os.path.basename(os.path.normpath(args.folder)),
                     old, new, files)]
        except describe.DescribeError as exc:
            rows = [(args.folder, None, args.text, str(exc))]
    else:
        ap.error("give TEXT, --export LIST or --apply LIST")

    changed = failed = 0
    for name, old, new, files in rows:
        if isinstance(files, str):
            failed += 1
            print("FAIL  %-24s %s" % (name, files))
        elif files:
            changed += 1
            print("%s  %-24s %r -> %r"
                  % ("SET " if args.go else "WOULD", name, old, new))
    print("%d changed, %d unchanged, %d failed%s"
          % (changed, len(rows) - changed - failed, failed,
             "" if args.go else "  (dry run - add --go to write)"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
