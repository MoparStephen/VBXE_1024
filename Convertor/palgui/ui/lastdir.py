"""lastdir.py - the folder each file dialog last used, kept across launches.

ONE KEY PER KIND OF THING, NOT ONE FOR THE WHOLE APP.  Source images, the
output tree, saved queues and the Atari staging folder are usually in four
different places; a single shared "last folder" would send the Open image
dialog to wherever the last queue was saved.  The keys:

    image        Open image, Queue images, Retarget queue
    output       the Output directory browse
    previews     Open a previews folder
    settings     Load settings from a conversion or preview
    conversions  the folder-of-conversions picks (re-convert, descriptions, gather)
    sources      "where are the source images now?" (re-convert)
    staging      the Atari staging folder (gather)
    queue        Save / Load queue

Stored in QSettings beside the window layout (the registry on Windows), so it
survives a restart.  A remembered folder that has since been deleted or
unplugged is ignored and the dialog falls back to its old context start.
"""

import os

from PySide6.QtCore import QSettings

#: QSettings scope - shared with the window layout in ui/main.py.
ORG = 'VBXE'
APP = 'VBXE PAL Studio'

_GROUP = 'last_dir'


def _store():
    return QSettings(ORG, APP)


def get(key, fallback=''):
    """The folder last used for `key`, if it still exists; else `fallback`."""
    try:
        d = str(_store().value('%s/%s' % (_GROUP, key), '') or '')
    except Exception:                   # noqa: BLE001 - never block a dialog
        d = ''
    return d if d and os.path.isdir(d) else fallback


def remember(key, path):
    """Record the folder of `path` (a file or a folder) for `key`.

    Call it with whatever the dialog returned; an empty path (Cancel) is a
    no-op, so callers need not test first.
    """
    if not path:
        return
    d = path if os.path.isdir(path) else os.path.dirname(path)
    if not d:
        return
    try:
        _store().setValue('%s/%s' % (_GROUP, key), os.path.abspath(d))
    except Exception:                   # noqa: BLE001 - never block a dialog
        pass
