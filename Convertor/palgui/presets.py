"""presets.py - named Settings on disk, so a good run can be repeated.

A SETTLED SET OF OPTIONS IS THE THING YOU WANT BACK.  Finding that a portrait
wants `--fit cover --color-bias 0.5 --coherence 2` takes a dozen previews; not
being able to name and keep that means doing it again next time.  Presets are
plain JSON in palgui/presets/, one file per name, so they can be read, diffed
and committed like anything else in the repo.

INPUT AND OUT ARE DELIBERATELY NOT SAVED.  A preset is a recipe, not a job -
applying "portrait" should change how the image in front of you is converted,
not silently swap which image that is.  jobs.py keeps the whole Settings
including paths, because a queue entry IS a job.
"""

import json
import os
import re
import sys

from .settings import RESIZE_FIXED, Settings

#: FROZEN (a PyInstaller build): presets live beside the exe, in the folder the
#: user unzipped - writable and portable, unlike the read-only _internal\ tree
#: this package is unpacked into.  From source: in the package, as before, so
#: they diff and commit with the rest of the repo.
if getattr(sys, 'frozen', False):
    PRESET_DIR = os.path.join(os.path.dirname(os.path.abspath(sys.executable)),
                              'presets')
else:
    PRESET_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              'presets')

#: The fields a preset does not carry.  See the docstring.
NOT_A_RECIPE = ('input', 'out', 'name', 'description')


#: The display name is stored INSIDE the file, under this key, because the file
#: name has to survive a trip through a filesystem and "Pixel art (no
#: resample)" does not - _safe() eats the brackets.  Losing them only in the
#: combo box would be a small ugliness; losing them in the name you then try to
#: load again would be a bug.
NAME_KEY = '_name'


def _safe(name):
    """A file name from a display name.  Rejects nothing, mangles the rest."""
    s = re.sub(r'[^A-Za-z0-9 _.-]+', '', str(name)).strip()
    return s or 'preset'


def path_for(name):
    return os.path.join(PRESET_DIR, '%s.json' % _safe(name))


def names():
    """Preset display names, sorted, or [] if the directory is not there."""
    try:
        files = os.listdir(PRESET_DIR)
    except OSError:
        return []
    out = []
    for f in files:
        if not f.lower().endswith('.json'):
            continue
        stem = os.path.splitext(f)[0]
        try:
            with open(os.path.join(PRESET_DIR, f)) as fh:
                out.append(json.load(fh).get(NAME_KEY) or stem)
        except (OSError, ValueError):    # noqa: BLE001 - a bad file is skipped
            out.append(stem)             #   rather than taking the list with it
    return sorted(set(out))


def save(name, settings):
    """Write one preset.  Returns the path, for the status bar to name."""
    if not os.path.isdir(PRESET_DIR):
        os.makedirs(PRESET_DIR)
    d = settings.to_dict()
    for field in NOT_A_RECIPE:
        d.pop(field, None)
    d[NAME_KEY] = str(name)
    p = path_for(name)
    with open(p, 'w') as f:
        json.dump(d, f, indent=2, sort_keys=True)
        f.write('\n')
    return p


def load(name, onto=None):
    """Read one preset, applied over `onto` so the paths in it survive.

    Returns a NEW Settings; the caller's object is not touched, because the
    options panel wants to diff what changed to decide what to re-enable.
    """
    with open(path_for(name)) as f:
        d = json.load(f)
    base = (onto.clone() if onto is not None else Settings())
    for field, _default in Settings.DEFAULTS:
        if field in NOT_A_RECIPE:
            continue
        if field in d:
            setattr(base, field, d[field])
    return base


def delete(name):
    p = path_for(name)
    if os.path.isfile(p):
        os.remove(p)
        return True
    return False


# --- the ones worth shipping -------------------------------------------------
#: WRITTEN ON FIRST RUN, NOT AT INSTALL TIME, so a user who deletes one is not
#: fighting the package to keep it deleted - they come back only if the whole
#: directory is empty.  The three cover the cases the README argues about:
#: a photograph, a smooth-gradient source, and pixel art.
#:
#: EVERY ONE RESIZES, because the viewer is 320x240 and there is no such
#: thing as a run that skips it any more; `nearest` is what makes the
#: pixel-art preset pixel art, not the absence of a resample.
BUILTIN = {
    'Photo 320x240': dict(resize='320x240', filter='lanczos', fit='cover',
                          dither='none', color_bias=0.0),
    'Smooth gradient (blue noise)': dict(resize='320x240', filter='lanczos',
                                         fit='stretch', dither='blue',
                                         dither_strength=1.0, color_bias=0.0),
    'Pixel art': dict(resize=RESIZE_FIXED, filter='nearest',
                      fit='stretch', dither='none', color_bias=0.0),
    'Busy image, more colours': dict(resize='320x240', filter='lanczos',
                                     fit='cover', color_bias=0.6,
                                     coherence=2.0, dither='none'),
}


def ensure_builtins():
    """Lay down the shipped presets if the directory has nothing in it.

    A read-only PRESET_DIR (e.g. the app unpacked under Program Files) must not
    take the whole GUI down on first launch - the app is perfectly usable with
    no presets, and names() already tolerates the empty case.
    """
    if names():
        return
    for name, fields in BUILTIN.items():
        try:
            save(name, Settings(**fields))
        except OSError:
            return
