"""check_version.py - refuse a release whose tag, GUI and viewer disagree.

ONE VERSION FOR THE WHOLE REPO.  The viewer and the converter ship as a pair
(a viewer that loads .V1K is no use without a converter that writes one), so
a release is numbered once, after the viewer's loading-screen version:

    Viewer/view1024.asm      V_0 '.' V_1 V_2 [V_3]   screen codes -> "0.16"
    Convertor/palgui/__init__.py  __version__         -> '0.16'
    git tag                       v<version>          -> v0.16

build_app.ps1 / build_app.sh name the archive from __version__, so a tag
pushed without bumping it publishes a zip labelled with the OLD number - the
mistake this script exists to stop.  release.yml runs it before building.

    python packaging/check_version.py            # GUI vs viewer only
    python packaging/check_version.py v0.16      # ... and the tag
    python packaging/check_version.py refs/tags/v0.16
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INIT_PY = os.path.join(ROOT, 'Convertor', 'palgui', '__init__.py')
VIEWER_ASM = os.path.join(ROOT, 'Viewer', 'view1024.asm')


def gui_version():
    with open(INIT_PY) as f:
        m = re.search(r"^__version__\s*=\s*['\"]([^'\"]+)['\"]", f.read(),
                      re.M)
    if not m:
        raise SystemExit('no __version__ in %s' % INIT_PY)
    return m.group(1)


def _screen_char(code):
    """Atari internal screen code -> character: $10-$19 digits, $00 none,
    $61-$7A lower-case letters (same codes as ATASCII in that range)."""
    if code == 0:
        return ''
    if 0x10 <= code <= 0x19:
        return chr(ord('0') + code - 0x10)
    if 0x61 <= code <= 0x7A:
        return chr(code)
    raise SystemExit('unexpected version screen code $%02X in %s'
                     % (code, VIEWER_ASM))


def viewer_version():
    """"V_0.V_1V_2V_3" as the loading screen draws it (init_vbxe.asm)."""
    with open(VIEWER_ASM, encoding='latin-1') as f:
        src = f.read()
    codes = {}
    for n in range(4):
        m = re.search(r'^\.def\s+V_%d\s*=\s*\$([0-9A-Fa-f]+)' % n, src, re.M)
        if not m:
            raise SystemExit('no V_%d in %s' % (n, VIEWER_ASM))
        codes[n] = int(m.group(1), 16)
    c = [_screen_char(codes[n]) for n in range(4)]
    return '%s.%s%s%s' % tuple(c)


def main(argv):
    gui, viewer = gui_version(), viewer_version()
    print('palgui __version__ : %s' % gui)
    print('viewer V_0..V_3    : %s' % viewer)
    ok = gui == viewer
    if argv:
        tag = argv[0].split('/')[-1]
        print('tag                : %s' % tag)
        ok = ok and tag == 'v' + gui
    if not ok:
        print('VERSION MISMATCH - bump Convertor/palgui/__init__.py and the '
              'V_0..V_3 defines in Viewer/view1024.asm to match the tag',
              file=sys.stderr)
        return 1
    print('versions agree')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
