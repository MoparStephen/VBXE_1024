#!/bin/sh
# ---------------------------------------------------------------------------
# run_palgui.sh - launch VBXE PAL Studio (the palettize4 front end) from
# anywhere.  See run_palgui.cmd for why the interpreter path and the working
# directory are forced, and why the venv needs numpy/Pillow/scipy as well as
# PySide6.
# ---------------------------------------------------------------------------
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT/Convertor"

for PY in "$ROOT/.venv/bin/python" "$ROOT/.venv/Scripts/python.exe"; do
    [ -x "$PY" ] && exec "$PY" -m palgui "$@"
done

echo "The GUI's virtualenv is missing.  Create it with:" >&2
echo >&2
echo "    python -m venv .venv" >&2
echo "    .venv/bin/python -m pip install PySide6 Pillow numpy scipy" >&2
echo >&2
echo "palettize4.py itself needs none of Qt - it runs on any Python with" >&2
echo "numpy and Pillow:" >&2
echo >&2
echo "    python Convertor/palettize4.py IMAGE.png --out build" >&2
exit 1
