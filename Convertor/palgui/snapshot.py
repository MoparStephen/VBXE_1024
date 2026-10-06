"""snapshot.py - keep a numbered picture and a summary of a preview.

A PREVIEW IS OTHERWISE UNRECOVERABLE.  It goes into a scratch directory that
the next preview overwrites and that the app deletes on the way out, so
comparing floyd against atkinson against blue means holding three pictures in
your head at once - which is exactly the thing eyes are bad at.  A snapshot
turns each preview into a file pair you can put side by side afterwards:

    out/bgneon/previews/Preview_01.png    the converted 320x240 picture
    out/bgneon/previews/Preview_01.txt    every setting that produced it

THE PICTURE IS COPIED, NOT RE-ENCODED.  palettize4 already wrote a 320x240 PNG
of exactly the colours the hardware will show; copying the bytes keeps the
colour count exact by construction, and a PNG is lossless so there is nothing
to gain by writing it again.  The nearest-neighbour path below only exists for
a result that is somehow NOT 320x240 - and it is nearest because that is the
only resample that cannot invent a colour the palette does not contain.

NUMBERING IS MAX + 1, NOT COUNT + 1.  Delete Preview_02 out of a set of three
and a count would hand the next run 03, quietly overwriting the one you kept.

THE PAIR READS BACK IN.  palgui/review.py turns a folder of these into a list
you step through, which is what makes forty snapshots a comparison rather than
forty files.  The summary carries the reproducing command line, so even a
snapshot written before any of that still gives its settings back; a `[data]`
footer is appended now so the numbers come back too, and a browsed snapshot can
rebuild the whole Result tab rather than only its own picture.

QT-FREE, like everything outside ui/.
"""

import json
import os
import re
import shutil
import time

from . import __version__, summary


#: {name}_summary.txt - the record a real CONVERSION leaves beside its files.
SUMMARY_SUFFIX = '_summary.txt'

#: The subdirectory, under the per-image output folder.  Snapshots pile up -
#: forty of them is a normal afternoon - and burying a conversion's eleven real
#: output files under that pile would make the folder useless for its main job.
DIRNAME = 'previews'

#: What the viewer shows, so what a snapshot is.
SIZE = (320, 240)

STEM = 'Preview_%02d'
_NUMBERED = re.compile(r'^Preview_(\d+)\.(?:png|txt)$', re.IGNORECASE)

#: The machine-readable tail of a summary.  LAST IN THE FILE AND CLEARLY
#: LABELLED, because the summary's job is to be read: a JSON blob at the top
#: would push the verdict off the first screen for the sake of a reader that
#: does not care where in the file it finds things.
DATA_MARKER = '[data]'
DATA_NOTE = 'machine-readable; the summary above is the part meant for reading'


def number_of(name):
    """The NN in Preview_NN.png / Preview_NN.txt, or None for anything else.

    Here rather than in review.py so that ONE module owns what a snapshot is
    called - the writer and the reader disagreeing about that is how a folder
    ends up half-visible.
    """
    m = _NUMBERED.match(name)
    return int(m.group(1)) if m else None


def dir_for(out_root, name):
    """<out_root>/<name>/previews - where this image's snapshots live."""
    return os.path.join(out_root, name, DIRNAME)


def next_index(directory):
    """The lowest number that would not tread on a file already there.

    Scans for BOTH extensions, so a stray Preview_04.txt with no picture still
    reserves 04 - the pair is the unit, and half a pair from a run that failed
    part way should not be completed by an unrelated one.
    """
    highest = 0
    try:
        entries = os.listdir(directory)
    except OSError:                 # noqa: BLE001 - not there yet is fine
        entries = []
    taken = set()
    for entry in entries:
        n = number_of(entry)
        if n is not None:
            taken.add(n)
            highest = max(highest, n)
    n = highest + 1
    while n in taken:               # unreachable via max+1, cheap insurance
        n += 1
    return n


def save(directory, preview_png, text, index=None, data=None):
    """Write the pair.  Returns (index, png_path, txt_path).

    The picture goes down first: a .txt with no .png beside it is a puzzle,
    while a .png with no .txt is at least still a picture.

    `data` is anything JSON can hold - in practice the settings and the stats -
    appended under DATA_MARKER.  THE PROSE ALONE IS NOT ENOUGH TO COME BACK
    FROM: the command line in it recovers every setting, but the numbers are
    sentences, and a browsed snapshot with no stats can show its picture and
    its text while the Result tab sits empty.  Two kilobytes on a four-kilobyte
    file buys the whole pane back.
    """
    os.makedirs(directory, exist_ok=True)
    if index is None:
        index = next_index(directory)
    stem = STEM % index
    png = os.path.join(directory, stem + '.png')
    txt = os.path.join(directory, stem + '.txt')
    _copy_image(preview_png, png)
    body = text.rstrip('\n')
    if data is not None:
        body += '\n\n' + data_block(data)
    with open(txt, 'w') as fh:
        fh.write(body + '\n')
    return index, png, txt


def data_block(data):
    """The footer: a labelled marker, then one line of JSON.

    ONE LINE, so a reader can take everything after the marker and hand it
    straight to json.loads without counting braces.
    """
    return '%s  %s\n%s' % (DATA_MARKER, DATA_NOTE,
                           json.dumps(data, sort_keys=True))


def write_for_run(out_root, settings, stats, paths, command, report):
    """Everything a finished preview leaves behind.  -> (index, png, txt).

    BELOW ui/ BECAUSE TWO CALLERS NEED IT.  The window writes one of these
    after a Preview, and jobs.run_queue() writes one per job when a whole
    queue is previewed - and that half must not import Qt.  Two functions
    deciding separately what a snapshot contains is how the file the tests
    check and the file on disk drift apart.

    `out_root` is the --out the run BELONGS to, already absolute, not the
    scratch directory it actually ran in.  A preview is a rehearsal of a
    conversion, and its snapshot files under the conversion it rehearses.
    """
    where = dir_for(out_root, settings.effective_name() or 'preview')
    w, h, colours, resampled = describe(paths['preview'])
    index = next_index(where)
    text = summary.as_text(
        settings, stats, command=command, report=report,
        header='Preview %02d' % index,
        extra=[('when', time.strftime('%Y-%m-%d %H:%M:%S')),
               ('convertor', __version__),
               ('image', '%s.png   %d x %d, %d colour%s%s'
                % (STEM % index, w, h, colours,
                   '' if colours == 1 else 's',
                   '  (nearest-resampled from the run)' if resampled else ''))])
    return save(where, paths['preview'], text, index=index,
                data={'settings': settings.to_dict(), 'stats': stats})


def write_conversion(out_dir, settings, stats, command, report, when=None,
                     convertor=None):
    """{name}_summary.txt beside a finished CONVERSION.  -> its path.

    A CONVERSION USED TO LEAVE NO RECORD OF HOW IT WAS MADE.  palettize4's
    _report.txt is the Atari Info screen and stays exactly that; the Result
    tab, the `run with` line and the settings themselves only ever reached disk
    for previews.  This is the same file a Preview_NN.txt is - same renderer,
    same [data] footer - so File > Load settings from... and palgui/recover.py
    read either one, and re-converting next month is one click, not a guess.

    One per image, overwritten by the next conversion, like the eleven files
    it describes.  Below ui/ for the same reason write_for_run is: the window
    and jobs.run_queue() both call it.

    `when` / `convertor` default to now and this release.  palgui/describe.py
    passes the originals when it rewrites a summary after the fact - editing a
    description is not a new conversion.
    """
    name = stats.get('name') or settings.effective_name() or 'image'
    path = os.path.join(out_dir, name + SUMMARY_SUFFIX)
    text = summary.as_text(
        settings, stats, command=command, report=report,
        header='Conversion - %s' % name,
        extra=[('when', when or time.strftime('%Y-%m-%d %H:%M:%S')),
               ('convertor', convertor or __version__)])
    body = text.rstrip('\n') + '\n\n' + data_block(
        {'settings': settings.to_dict(), 'stats': stats})
    tmp = path + '.tmp'
    with open(tmp, 'w') as fh:
        fh.write(body + '\n')
    os.replace(tmp, path)
    return path


def describe(preview_png):
    """(width, height, colours, needs_resample) for the source PNG.

    Read here rather than taken from the stats because the stats describe the
    RUN and this describes the FILE - and when those two disagree it is the
    file that ends up in the folder.
    """
    from PIL import Image
    with Image.open(preview_png) as opened:
        rgb = opened.convert('RGB')
        size = (rgb.width, rgb.height)
        # maxcolors high enough that getcolors never gives up and returns
        # None - the exact count is the whole point of saving a PNG.
        colours = len(rgb.getcolors(maxcolors=1 << 24) or [])
    return size[0], size[1], colours, size != SIZE


def _copy_image(src, dst):
    """Byte-for-byte when it is already 320x240; nearest-neighbour when not."""
    from PIL import Image
    with Image.open(src) as opened:
        already = (opened.width, opened.height) == SIZE
        if not already:
            opened.convert('RGB').resize(SIZE, Image.NEAREST).save(dst)
    if already:
        shutil.copyfile(src, dst)
