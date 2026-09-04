"""runner.py - find palettize4.py, build the run, read what came back.

QT-FREE ON PURPOSE.  This is the half that knows how to talk to the converter,
and it is worth being able to drive a queue from a script or a CI step with no
display and no PySide6 installed.  ui/worker.py owns the QProcess that makes a
run asynchronous; everything about WHAT to run and what the answer MEANS lives
here, and run_blocking() below is the same thing synchronously for tests.

THE INTERPRETER IS sys.executable, NOT 'python'.  The GUI only runs at all
because it is on an interpreter with PySide6, and that same interpreter is the
one the venv also gave numpy/Pillow/scipy to.  Shelling out to a bare `python`
would find the system install instead, which on a fresh machine is the one
without scipy - and the failure would show up as a dither that mysteriously
refuses to run rather than as an install problem.

FAILURES ARE CLASSIFIED, NOT RE-RAISED RAW.  palettize4.py exits through
sys.exit() with a bare sentence for the two things a user actually does wrong
(no scipy, unreadable image), and a traceback for everything else.  classify()
turns those into something the status bar can say in one line.
"""

import importlib.util
import json
import os
import subprocess
import sys

from . import summary


#: palettize4.py lives one directory up from this package.
CONVERTOR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(CONVERTOR)
SCRIPT = os.path.join(CONVERTOR, 'palettize4.py')

#: The base name Preview runs use inside the scratch directory.  Fixed, so the
#: scratch dir holds one set of files that get overwritten rather than growing
#: a new set per preview.
PREVIEW_NAME = 'preview'


class RunError(Exception):
    """A run that did not produce stats, with a sentence fit for a status bar.

    `detail` is the raw stderr, kept for the "show the whole thing" dialog -
    the one-liner is what goes on screen, and a traceback is not a one-liner.
    """

    def __init__(self, message, detail='', kind='error'):
        Exception.__init__(self, message)
        self.message = message
        self.detail = detail
        self.kind = kind


def resolve(path):
    """An --out as an absolute directory, relative ones taken from Convertor/.

    palettize4.py does os.makedirs(args.out) against ITS OWN cwd, which is not
    necessarily ours: the GUI can be launched from anywhere and a queue can be
    driven from a script.  `out` therefore has to be absolutised before it is
    handed to a subprocess, and Convertor/ is the anchor because that is what
    the default `out` has always meant.
    """
    if not path:
        return CONVERTOR
    if os.path.isabs(path):
        return path
    return os.path.join(CONVERTOR, path)


def job_dir(settings, out=None):
    """<out>/<name> - one directory per image, which is where a run writes.

    ONE IMAGE, ONE FOLDER.  palettize4 writes eleven files per run into a flat
    --out, so converting a second image drops eleven more beside them and a
    third overwrites the first `img7.raw` you were looking for.  Naming the
    folder after the output base - --name when it is set, the input stem when
    it is not - keeps the folder and the files inside it saying the same thing.

    RELATIVE STAYS RELATIVE, so a copied command line still reads
    `--out out\alicia` rather than a path that only exists on this machine.
    """
    root = settings.out if out is None else out
    name = settings.effective_name()
    if not name:
        return root
    return os.path.join(root, name)


def script_path():
    """Where palettize4.py is, checked - a missing script is a clear message."""
    if not os.path.isfile(SCRIPT):
        raise RunError('palettize4.py is not next to palgui/ (looked in %s)'
                       % CONVERTOR)
    return SCRIPT


def build_command(settings, out=None, name=None, python=None):
    """The full argv, interpreter first, ready for QProcess or subprocess.

    --quiet and --json are appended here rather than being Settings fields:
    every caller wants machine-readable stats on stdout and none of them has
    anywhere to put the human report, which palettize4 writes to
    {name}_report.txt regardless.
    """
    python = python or sys.executable
    return ([python, script_path()]
            + list(settings.to_argv(out=out, name=name))
            + ['--quiet', '--json'])


def run_blocking(settings, out=None, name=None, timeout=None):
    """Run the converter and return its stats dict.  Tests and scripts use this.

    The GUI does NOT use it - a floyd dither on a big source is seconds of
    serial Python, and a frozen window is a worse answer than a spinner.  See
    ui/worker.py.
    """
    cmd = build_command(settings, out=out, name=name)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout)
    except OSError as exc:
        raise RunError('could not start %s: %s'
                       % (os.path.basename(cmd[0]), exc))
    if p.returncode != 0:
        raise classify(p.returncode, p.stderr)
    return parse_stats(p.stdout, p.stderr)


def parse_stats(stdout, stderr=''):
    """The JSON object palettize4 printed for --json.

    Anything the script wrote before it is tolerated: numpy and PIL are both
    capable of emitting a warning to stdout on some installs, and losing a
    whole run to that would be absurd.  The stats object is the last line that
    parses as a JSON dict.
    """
    for line in reversed((stdout or '').strip().splitlines()):
        line = line.strip()
        if not line.startswith('{'):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict) and 'output_colours' in obj:
            return obj
    raise RunError('the converter exited cleanly but printed no stats',
                   detail=(stderr or stdout or '').strip())


def classify(returncode, stderr):
    """Turn a failed run into a RunError with a sentence worth reading."""
    text = (stderr or '').strip()
    low = text.lower()

    # palettize4.py:253 - sys.exit('--dither needs scipy: pip install scipy').
    # The single most likely failure on a fresh install, and the one where a
    # raw traceback would be least helpful, because there is no traceback.
    if 'needs scipy' in low:
        return RunError(
            'dithering needs scipy, which this interpreter does not have',
            detail=('%s\n\nInstall it into the interpreter running the GUI:\n\n'
                    '    %s -m pip install scipy\n' % (text, sys.executable)),
            kind='scipy')

    if 'cannot identify image file' in low or 'no such file or directory' in low:
        return RunError('the input image could not be read', detail=text,
                        kind='input')

    if 'memoryerror' in low:
        return RunError('ran out of memory - try --resize to a smaller target',
                        detail=text, kind='memory')

    # A traceback: the last line is the exception, and it is the only line worth
    # putting in a status bar.
    last = text.splitlines()[-1].strip() if text else ''
    if last:
        return RunError('palettize4 failed: %s' % last, detail=text)
    return RunError('palettize4 exited %d with no message' % returncode,
                    detail=text)


# --- the source, as the converter will see it --------------------------------
_p4 = None


def palettize4():
    """Import palettize4.py as a module, for the handful of pure functions in it.

    IMPORTED, NOT COPIED.  resize_image() is 50 lines of crop-and-pad arithmetic
    with a non-obvious pixel-aspect term in the letterbox case, and a second
    copy of it here would be a second copy that could be wrong.  The script has
    no import-time side effects - everything is under `if __name__ ==
    '__main__'` - so this is safe, and it is deliberately the ONLY thing this
    package imports from it.  Running a conversion still goes through a
    subprocess: see the module docstring.
    """
    global _p4
    if _p4 is None:
        spec = importlib.util.spec_from_file_location('palettize4',
                                                      script_path())
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _p4 = mod
    return _p4


def load_source(settings):
    """The input image AS THE PACKER WILL RECEIVE IT: resampled, cropped, padded.

    THE COMPARISON IS WORTHLESS WITHOUT THIS.  The result of a run is 320x240;
    the file on disk is very often 1600x1200.  Showing the raw file beside it
    means the two panes hold different pixels at different scales, so flipping
    between them shows a resample - the one thing the settings did NOT change -
    instead of the dithering they did.

    Returns (width, height, rgb_bytes) or None if the file cannot be read.
    Raises RunError only when the settings themselves are bad (an unparseable
    --resize), because that is worth saying out loud rather than silently
    showing the unresized original.
    """
    path = settings.input
    if not path or not os.path.isfile(path):
        return None
    p4 = palettize4()
    try:
        img = p4.Image.open(path).convert('RGB')
    except Exception as exc:            # noqa: BLE001 - Pillow raises broadly
        raise RunError('could not read %s: %s' % (os.path.basename(path), exc),
                       detail=str(exc), kind='input')
    if settings.resize:
        try:
            wh = p4._parse_wh(settings.resize)
        except ValueError:
            raise RunError('resize must look like 320x240, not %r'
                           % settings.resize, kind='settings')
        try:
            img, _mask = p4.resize_image(img, wh, settings.filter,
                                         settings.fit, settings.display_aspect)
        except Exception as exc:        # noqa: BLE001 - shown to the user
            raise RunError('could not resample: %s' % exc, detail=str(exc),
                           kind='settings')
    return (img.width, img.height, img.tobytes())


# --- reading the result -----------------------------------------------------
def dither_was_inert(settings, stats):
    """True when a dither was asked for and could not possibly have run.

    palettize4.py:442-449 only reaches dither_to_palette() inside
        if len(uniq) > NP * cap:
    so a source already inside the colour budget is passed through untouched
    and --dither is silently ignored.  WITHOUT THIS CHECK THE WHOLE POINT OF
    THE GUI FAILS QUIETLY: you compare `none`, `floyd` and `blue` on a piece of
    pixel art, get three identical images, and conclude dithering does nothing.
    """
    if settings.dither == 'none' or not stats:
        return False
    return not stats.get('prequantized', False)


def output_paths(stats, out_dir):
    """Absolute paths for everything the run wrote, from the stats `files` map.

    Read out of the stats rather than rebuilt from the settings so that the
    file names come from the code that wrote them - --name defaulting to the
    input stem is palettize4's rule to keep, not ours to reimplement.
    """
    files = (stats or {}).get('files', {})
    paths = {}
    for key, value in files.items():
        if isinstance(value, list):
            paths[key] = [os.path.join(out_dir, v) for v in value]
        else:
            paths[key] = os.path.join(out_dir, value)
    return paths


def headline(settings, stats):
    """The one line the status bar shows when a run lands.

    OUTPUT COLOURS AND WHETHER IT WAS LOSSLESS ARE THE TWO NUMBERS THAT MATTER;
    everything else in the stats pane is there to explain one of them.

    THE THIRD NUMBER IS PSNR, not the mean OKLab error that used to be here.
    That one averages over recoloured pixels only, so it moves in the opposite
    direction to the damage whenever a run recolours MORE pixels more gently -
    which is exactly what raising the colour bias does.  PSNR measures the
    whole picture, so two previews an hour apart can be compared on it.
    """
    if not stats:
        return ''
    colours = stats.get('output_colours', 0)
    budget = settings.colour_budget()
    psnr = summary.psnr_text(stats)
    if stats.get('lossless'):
        return 'LOSSLESS - %d colours of a possible %d' % (colours, budget)
    return ('lossy (%s) - %d colours, %.2f%% of pixels recoloured%s'
            % (stats.get('strategy', '?'), colours,
               stats.get('recoloured_pct', 0.0),
               ', %s vs ideal' % psnr if psnr else ''))
