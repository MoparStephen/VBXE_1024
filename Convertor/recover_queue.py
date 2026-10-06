#!/usr/bin/env python3
"""Build a re-conversion queue from a folder of existing conversions.

Looks at every OUTROOT/<image>/ folder, recovers the settings that image was
converted with (its _summary.txt, a matching preview snapshot, or its
_stats.json + _report.txt - see palgui/recover.py), and writes a queue .json
the GUI loads with File > Load queue... and runs with Run queue (convert).
Each job re-converts into the folder it came from.  Nothing under OUTROOT is
written; the only file created is the queue.

    python recover_queue.py out -o requeue.json --search "../Images To Convert"
    python recover_queue.py out --no-trial      # skip the dither re-runs
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from palgui import recover


def main(argv):
    ap = argparse.ArgumentParser(
        description="Recover each conversion's settings and write a "
                    "re-conversion queue for the GUI.")
    ap.add_argument("outroot", help="folder holding one subfolder per image")
    ap.add_argument("-o", "--queue", default="requeue.json",
                    help="queue file to write (default requeue.json)")
    ap.add_argument("--search", action="append", default=[], metavar="DIR",
                    help="folder to look for moved source images in, by "
                         "filename (repeatable, searched recursively)")
    ap.add_argument("--no-trial", action="store_true",
                    help="do not re-run none/blue to verify an unrecorded "
                         "dither (fast; such images are marked best guess)")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.outroot):
        raise SystemExit("%s: not a folder" % args.outroot)

    recs = recover.plan(args.outroot, args.search, trial=not args.no_trial,
                        on_folder=lambda n: sys.stderr.write("  %s\n" % n))
    queue = recover.build_queue(recs)
    queue.save(args.queue)
    print(recover.report_text(recs, os.path.abspath(args.queue)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
