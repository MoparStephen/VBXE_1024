"""gather.py - collect every .V1K (+ its .NFO) under a folder tree into one
Atari staging folder, with 8-char names and the IMAGES.LST that goes with them.

WHAT IT IS FOR.  Converted images end up scattered - out/<image>/ from the GUI,
flat folders from palettize4.py runs, older conversions still carrying their
long names.  The disk wants one folder of NAME.V1K / NAME.NFO pairs plus the
IMAGES.LST manifest the selector reads.  This builds that folder.

RENAMES ARE THE POINT.  Anything not already a legal Atari name (see
atari_name.py) is renamed on the way over, and two sources that reduce to the
same name get CHARGE01, CHARGE02 ...  The manifest's description comes from the
SOURCE side - its _stats.json (which is not copied), else the .NFO Input name
minus extension - so a legacy "Charger 01.v1k" still shows as "Charger 01".

QT-FREE, like everything outside ui/: used by ui/main.py's File menu and by the
standalone gather_v1k.py, and unit-tested without a display.
"""

import glob
import hashlib
import os
import shutil

from . import imageslst
from .imageslst import atari_name

#: .pal + .map + .raw, the only size the viewer accepts (see pack_v1k.py)
V1K_LEN = 3072 + 9600 + 76800


class Item(object):
    """One image to copy: source paths, the name it gets, and why it may not."""

    def __init__(self, v1k, nfo, name, description, problem=None):
        self.v1k = v1k                  # source .v1k path
        self.nfo = nfo                  # source .nfo path, or None
        self.name = name                # 8-char Atari base name
        self.description = description  # what IMAGES.LST shows
        self.problem = problem          # reason it is skipped, or None

    @property
    def renamed(self):
        # case alone is not a rename - SDX upper-cases every name anyway
        return os.path.splitext(os.path.basename(self.v1k))[0].upper() != self.name

    def line(self):
        """One human-readable line for the CLI / GUI result list."""
        src = self.v1k
        if self.problem:
            return 'SKIP  %s  (%s)' % (src, self.problem)
        return '%s  %-8s <- %s%s' % ('REN ' if self.renamed else 'COPY', self.name,
                                     src, '' if self.nfo else '  (no .nfo)')


def _find_v1k(root, skip=None):
    """Every .v1k under root, recursively, in a stable sorted order."""
    skip = os.path.normcase(os.path.abspath(skip)) if skip else None
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        here = os.path.normcase(os.path.abspath(dirpath))
        if skip and (here == skip or here.startswith(skip + os.sep)):
            dirnames[:] = []            # never re-gather the output folder
            continue
        dirnames.sort(key=str.lower)
        for fn in sorted(filenames, key=str.lower):
            if fn.lower().endswith('.v1k'):
                found.append(os.path.join(dirpath, fn))
    return found


def _sibling_nfo(v1k):
    """<stem>.nfo beside a .v1k, in whatever case it was written."""
    stem = os.path.splitext(v1k)[0]
    for ext in ('.nfo', '.NFO', '.Nfo'):
        if os.path.isfile(stem + ext):
            return stem + ext
    return None


def plan(root, out_dir=None):
    """[Item, ...] for everything under root - nothing is written.

    Names are assigned in walk order, so the same tree always maps the same
    way.  A file that is the wrong size, or byte-identical to one already
    listed (the same image staged in two folders), is listed with a problem
    and gets no name, so it cannot push a good image onto a numbered variant.
    """
    items, taken, seen = [], set(), {}
    for v1k in _find_v1k(root, skip=out_dir):
        nfo = _sibling_nfo(v1k)
        description = imageslst._description(v1k)
        size = os.path.getsize(v1k)
        if size != V1K_LEN:
            items.append(Item(v1k, nfo, None, description,
                              '%d bytes, expected %d' % (size, V1K_LEN)))
            continue
        with open(v1k, 'rb') as f:
            digest = hashlib.sha1(f.read()).hexdigest()
        if digest in seen:
            items.append(Item(v1k, nfo, None, description,
                              'duplicate of %s' % seen[digest]))
            continue
        stem = os.path.splitext(os.path.basename(v1k))[0]
        name = atari_name.unique_name(atari_name.short_name(stem), taken)
        taken.add(name)
        seen[digest] = name
        items.append(Item(v1k, nfo, name, description))
    return items


def clean(out_dir):
    """Delete the .v1k / .nfo / images.lst a previous gather left in out_dir."""
    removed = 0
    for pat in ('*.v1k', '*.V1K', '*.nfo', '*.NFO', 'images.lst', 'IMAGES.LST'):
        for path in glob.glob(os.path.join(out_dir, pat)):
            if os.path.isfile(path):
                os.remove(path)
                removed += 1
    return removed


def run(root, out_dir, do_clean=False):
    """Copy everything plan() finds into out_dir and write its images.lst.

    Returns (items, manifest path).  Copies are NAME.v1k / NAME.nfo - lower-case
    extensions, like palettize4 writes them; SDX upper-cases on the disk.
    """
    os.makedirs(out_dir, exist_ok=True)
    items = plan(root, out_dir)
    if do_clean:
        clean(out_dir)
    rows = []
    for it in items:
        if it.problem:
            continue
        shutil.copy2(it.v1k, os.path.join(out_dir, it.name + '.v1k'))
        if it.nfo:
            shutil.copy2(it.nfo, os.path.join(out_dir, it.name + '.nfo'))
        rows.append((imageslst.key_for(it.name), it.description))
    manifest = os.path.join(out_dir, 'images.lst')
    with open(manifest, 'wb') as f:
        f.write(imageslst.build_rows(rows))
    return items, manifest


def summary(items):
    """'N copied (R renamed), S skipped'."""
    ok = [i for i in items if not i.problem]
    ren = sum(1 for i in ok if i.renamed)
    return '%d copied (%d renamed), %d skipped' % (len(ok), ren,
                                                   len(items) - len(ok))
