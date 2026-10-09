"""recover.py - get back the settings a conversion was made with.

A CONVERSION MADE BEFORE 0.19 LEFT NO RECIPE.  The files the Atari reads are
there, and a _stats.json with half the options in it, but the "run with" line
and the dither only ever reached disk for PREVIEWS.  Re-converting everything
(to pick up the Description / Convertor Version rows, or a better packer) means
knowing what each image was made with, and guessing thirty of them by eye is
the job this module exists to not do.

BEST SOURCE FIRST, AND SAY WHICH ONE WAS USED:

    exact          {name}_summary.txt (0.19+), or _stats.json "args"
    preview match  a previews/Preview_NN.png pixel-identical to the
                   conversion's _preview.png - that snapshot's settings made it
    verified       derived from _stats.json + _report.txt, then re-run with
                   each candidate dither and one reproduced _preview.png exactly
    best guess     derived, and no candidate reproduced it (the packer has
                   changed since, or an option nothing recorded was used)

THE DITHER CANDIDATES ARE `none` AND `blue` AT 1.0 ONLY.  That is not a
guess about the algorithm: the early conversions were only ever dithered with
blue at full strength, and trying the other nine would cost minutes per image
to rule out things that never happened.

EACH JOB RE-CONVERTS INTO THE FOLDER IT CAME FROM.  --out is the root that was
scanned and --name is the folder's own name, NOT the name in the stats: two
folders (Plasma1 and plasma) both recorded `plasma`, and re-using that would
have one overwrite the other.  Files the new 8-char name leaves behind are
listed as orphans, not moved - that is the user's call.

QT-FREE, like everything outside ui/: File > Load settings from... and File >
Build re-conversion queue... call it, and so does recover_queue.py.
"""

import glob
import json
import os
import re
import shutil
import tempfile

from . import review, runner, snapshot
from .imageslst import atari_name
from .jobs import Queue
from .settings import Settings

EXACT = 'exact'
PREVIEW_MATCH = 'preview match'
VERIFIED = 'verified'
BEST_GUESS = 'best guess'

#: (dither, strength) tried, in order, when nothing recorded the dither.
DITHER_CANDIDATES = (('none', 1.0), ('blue', 1.0))

#: What palettize4 writes per image, as suffixes on the base name.  Used to
#: spot the files a rename to the 8-char name leaves behind.
_OUTPUT_SUFFIXES = ('_preview.png', '_palettes.png', '_report.txt',
                    '_stats.json', snapshot.SUMMARY_SUFFIX, '.raw', '.map',
                    '.pal', '.v1k', '.nfo')

_RESAMPLED_ASPECT = re.compile(r'display-aspect=([0-9.:]+)')
_DITHERING = re.compile(r'^Dithering\s*:\s*(\w+)(?:,\s*strength\s*([0-9.]+))?',
                        re.M)


class Recovery(object):
    """What was found for one output folder."""

    def __init__(self, folder):
        self.folder = folder
        self.settings = None        # Settings, or None if nothing usable
        self.confidence = ''        # one of the four constants, or ''
        self.source = ''            # which file the settings came from
        self.notes = []             # warnings worth reading
        self.orphans = []           # files the re-convert will not replace

    @property
    def image(self):
        return os.path.basename(self.folder.rstrip('\\/'))

    def ok(self):
        return self.settings is not None and not self.missing_input()

    def missing_input(self):
        return self.settings is None or not os.path.isfile(
            self.settings.input)

    def line(self):
        if self.settings is None:
            return '%-20s %-13s %s' % (self.image, 'SKIP',
                                        '; '.join(self.notes))
        bits = [self.confidence, 'dither %s' % self.settings.dither,
                'bias %.2f' % self.settings.effective_bias(),
                'coh %g' % float(self.settings.coherence)]
        if self.settings.fit != 'stretch':
            bits.append('fit %s' % self.settings.fit)
        return '%-20s %-13s %s%s' % (
            self.image, 'MISSING SRC' if self.missing_input() else 'ok',
            ', '.join(bits),
            ''.join('\n%21s! %s' % ('', n) for n in self.notes))


# --- one file -> Settings ----------------------------------------------------
def settings_from_stats(stats, report=''):
    """(Settings, exact) from a _stats.json dict and its _report.txt text.

    `exact` is True only when the stats carry palettize4's own "args" (0.19+).
    Otherwise the settings are DERIVED - every option the stats and the
    report name, defaults for the rest - and the dither is only known when the
    report has a Dithering line.
    """
    args = stats.get('args')
    if isinstance(args, dict):
        d = dict(args)
        for key in ('name', 'description', 'resize'):
            if d.get(key) is None:
                d[key] = ''
        return Settings.from_dict(d), True

    s = Settings()
    s.input = stats.get('input') or ''
    s.resize = stats.get('resize') or ''
    if stats.get('filter'):
        s.filter = stats['filter']
    if stats.get('fit'):
        s.fit = stats['fit']
    if stats.get('reserve0') is not None:
        s.reserve0 = bool(stats['reserve0'])
    bias = float(stats.get('color_bias') or 0.0)
    if bias >= 1.0:
        s.max_colors = True
    else:
        s.color_bias = bias
    if stats.get('coherence') is not None:
        s.coherence = float(stats['coherence'])
    s.description = stats.get('description') or ''
    m = _RESAMPLED_ASPECT.search(report or '')
    if m:
        s.display_aspect = m.group(1)
    if stats.get('dither'):
        s.dither = stats['dither']
        s.dither_strength = float(stats.get('dither_strength') or 1.0)
    else:
        m = _DITHERING.search(report or '')
        if m:
            s.dither = m.group(1).lower()      # 0.21+ reports say "Blue"
            if m.group(2):
                s.dither_strength = float(m.group(2))
    return s, False


def dither_known(stats, report=''):
    """True when the stats or the report recorded the dither."""
    return bool(isinstance(stats.get('args'), dict) or stats.get('dither')
                or _DITHERING.search(report or ''))


def settings_from_file(path):
    """(Settings, description of the source) for File > Load settings from.

    A .txt is a summary or a Preview_NN.txt - its [data] footer, else its
    `run with` line.  A .json is a _stats.json.  Raises ValueError with a
    sentence when the file holds no settings.
    """
    if path.lower().endswith('.json'):
        with open(path) as fh:
            stats = json.load(fh)
        if not isinstance(stats, dict):
            raise ValueError('%s is not a _stats.json' % path)
        report = _read(_sibling(path, '_stats.json', '_report.txt'))
        s, exact = settings_from_stats(stats, report)
        return s, ('exact (stats args)' if exact else
                   'derived from stats - unrecorded options are defaults')
    shot = review.parse(path)
    if shot.settings is None:
        raise ValueError('%s carries no settings (no [data] footer and no '
                         '"run with" line)' % path)
    return shot.settings, 'exact (%s)' % os.path.basename(path)


# --- one folder -> Recovery --------------------------------------------------
def recover_folder(folder, out_root, finder=None, trial=True):
    """A Recovery for one out/<image>/ folder.  Nothing in it is written."""
    rec = Recovery(folder)
    stats_path = _newest(glob.glob(os.path.join(folder, '*_stats.json')))
    if not stats_path:
        rec.notes.append('no _stats.json - not a conversion folder')
        return rec
    try:
        with open(stats_path) as fh:
            stats = json.load(fh)
    except (OSError, ValueError) as exc:        # noqa: BLE001 - reported
        rec.notes.append('unreadable %s: %s'
                         % (os.path.basename(stats_path), exc))
        return rec
    report = _read(_sibling(stats_path, '_stats.json', '_report.txt'))
    preview = _sibling(stats_path, '_stats.json', '_preview.png')

    summary_path = _sibling(stats_path, '_stats.json',
                            snapshot.SUMMARY_SUFFIX)
    s = None
    if os.path.isfile(summary_path):
        shot = review.parse(summary_path)
        if shot.settings is not None:
            s, rec.confidence = shot.settings, EXACT
            rec.source = os.path.basename(summary_path)
    if s is None:
        derived, exact = settings_from_stats(stats, report)
        if exact:
            s, rec.confidence = derived, EXACT
            rec.source = os.path.basename(stats_path) + ' args'
    if s is None and os.path.isfile(preview):
        shot = _matching_preview(folder, preview)
        if shot is not None:
            s, rec.confidence = shot.settings, PREVIEW_MATCH
            rec.source = 'previews/%s.txt' % shot.label()
            if not s.description and stats.get('description'):
                s.description = stats['description']
    if s is None:
        s, _exact = settings_from_stats(stats, report)
        rec.source = os.path.basename(stats_path) + ' (derived)'
        rec.confidence = BEST_GUESS

    s = s.clone()
    s.out = out_root
    s.name = rec.image
    found = (finder or InputFinder()).find(s.input, folder)
    if found:
        s.input = found
    else:
        rec.notes.append('source image not found: %s' % s.input)
    rec.settings = s

    if rec.confidence == BEST_GUESS and not dither_known(stats, report):
        if trial and found and os.path.isfile(preview):
            hit = _trial_dither(s, preview)
            if hit:
                s.dither, s.dither_strength = hit
                rec.confidence = VERIFIED
            else:
                rec.notes.append('no dither candidate reproduced the old '
                                 '_preview.png - kept dither none')
        else:
            rec.notes.append('dither not recorded - assumed none')
    rec.orphans = orphans(folder, rec.image)
    return rec


def plan(out_root, search_dirs=(), trial=True, on_folder=None):
    """[Recovery, ...] for every immediate subfolder of out_root."""
    out_root = os.path.abspath(out_root)
    finder = InputFinder(search_dirs)
    recs = []
    for entry in sorted(os.listdir(out_root), key=str.lower):
        folder = os.path.join(out_root, entry)
        if not os.path.isdir(folder):
            continue
        if on_folder:
            on_folder(entry)
        recs.append(recover_folder(folder, out_root, finder, trial=trial))
    return recs


def build_queue(recs):
    """A jobs.Queue of every Recovery whose source image was found."""
    q = Queue()
    for rec in recs:
        if rec.ok():
            q.add(rec.settings, label=rec.image)
    return q


def report_text(recs, queue_path=''):
    """The table a person reads before pressing Run queue."""
    lines = ['%-20s %-13s %s' % ('image', 'source', 'settings'), '-' * 76]
    lines += [r.line() for r in recs]
    usable = [r for r in recs if r.ok()]
    lines.append('')
    lines.append('%d of %d folders queued%s'
                 % (len(usable), len(recs),
                    ' -> %s' % queue_path if queue_path else ''))
    counts = {}
    for r in usable:
        counts[r.confidence] = counts.get(r.confidence, 0) + 1
    if counts:
        lines.append('  ' + ', '.join('%d %s' % (n, c)
                                      for c, n in sorted(counts.items())))
    orphaned = [(r, o) for r in recs for o in r.orphans]
    if orphaned:
        lines.append('')
        lines.append('Files a re-conversion will NOT replace (old names - '
                     'move them yourself):')
        for r, o in orphaned:
            lines.append('  %s' % os.path.join(r.image, o))
    return '\n'.join(lines)


# --- helpers -----------------------------------------------------------------
class InputFinder(object):
    """Where a recorded source image is now.

    The recorded path first (relative ones against Convertor/, as runner
    resolves --out), then the output folder itself, then a filename match
    anywhere under the search folders - sources get moved, and
    "C:/.../Convertor/MoreYouKnow.png" now living in "Images To Convert" is the
    normal case, not the odd one.
    """

    def __init__(self, search_dirs=()):
        self._index = None
        self._dirs = [d for d in search_dirs if d and os.path.isdir(d)]

    def find(self, recorded, folder):
        if not recorded:
            return ''
        for path in (recorded, runner.resolve(recorded),
                     os.path.join(folder, os.path.basename(recorded))):
            if os.path.isfile(path):
                return os.path.abspath(path)
        return self._lookup(os.path.basename(recorded).lower())

    def _lookup(self, base):
        if self._index is None:
            self._index = {}
            for top in self._dirs:
                for dirpath, dirnames, filenames in os.walk(top):
                    dirnames.sort(key=str.lower)
                    for fn in filenames:
                        self._index.setdefault(fn.lower(),
                                               os.path.join(dirpath, fn))
        return self._index.get(base, '')


def orphans(folder, image):
    """Converter outputs in `folder` whose base is not the one a re-convert
    named `image` will write (atari_name.short_name(image))."""
    base = atari_name.short_name(image).upper()
    found = []
    for fn in sorted(os.listdir(folder), key=str.lower):
        if not os.path.isfile(os.path.join(folder, fn)):
            continue
        low = fn.lower()
        suffix = next((x for x in _OUTPUT_SUFFIXES if low.endswith(x)), None)
        if suffix is None:
            continue
        stem = fn[:len(fn) - len(suffix)].upper()
        if stem == base:
            continue
        if suffix == '.pal' and stem[:-1] == base and stem[-1:].isdigit():
            continue                        # {base}0.pal .. {base}3.pal
        found.append(fn)
    return found


def _matching_preview(folder, preview_png):
    """The latest Preview_NN whose picture equals the conversion's."""
    want = _pixels(preview_png)
    if want is None:
        return None
    for shot in reversed(review.shots(os.path.join(folder,
                                                   snapshot.DIRNAME))):
        if shot.settings is not None and _pixels(shot.png) == want:
            return shot
    return None


def _trial_dither(settings, preview_png):
    """(dither, strength) of the first candidate that reproduces the old
    picture exactly, or None.  Runs into a temporary folder only."""
    want = _pixels(preview_png)
    if want is None:
        return None
    scratch = tempfile.mkdtemp(prefix='palgui-recover-')
    try:
        for dither, strength in DITHER_CANDIDATES:
            trial = settings.clone()
            trial.dither, trial.dither_strength = dither, strength
            try:
                stats = runner.run_blocking(trial, out=scratch,
                                            name=runner.PREVIEW_NAME)
            except runner.RunError:
                continue
            got = runner.output_paths(stats, scratch).get('preview')
            if got and _pixels(got) == want:
                return dither, strength
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return None


def _pixels(png):
    """(size, RGB bytes) of an image, or None if it cannot be read."""
    from PIL import Image
    try:
        with Image.open(png) as im:
            rgb = im.convert('RGB')
            return rgb.size, rgb.tobytes()
    except OSError:                 # noqa: BLE001 - treated as no match
        return None


def _sibling(path, old_suffix, new_suffix):
    return path[:len(path) - len(old_suffix)] + new_suffix


def _newest(paths):
    return max(paths, key=os.path.getmtime) if paths else ''


def _read(path):
    try:
        with open(path, errors='replace') as fh:
            return fh.read()
    except OSError:                 # noqa: BLE001 - optional sidecar
        return ''
