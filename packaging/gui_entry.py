"""PyInstaller entry point for the windowed build of VBXE PAL Studio.

Kept tiny and separate from Convertor/palgui/__main__.py: the frozen GUI never
wants the --selftest branch or the "your venv is missing PySide6" advice, both
of which only make sense when running from source.  All this does is hand argv
to the same run() the launcher and the tests use.
"""

import sys

from palgui.ui.main import run

if __name__ == "__main__":
    sys.exit(run(sys.argv))
