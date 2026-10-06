"""review.py - a folder of saved previews, read back as something to step through.

THIRTY-ONE PICTURES IS NOT A COMPARISON UNTIL YOU CAN WALK IT.  snapshot.py
makes every Preview leave a numbered pair behind, and a folder of them fills up
in an afternoon; but on disk they are only files.  Matching Preview_17.png back
to the settings that produced it means opening Preview_17.txt in another window
and reading a paragraph, and choosing between them means doing that thirty-one
times.  This module turns the folder into an ordered list of Shots, each one
carrying its picture, its summary, and - the part that matters - the Settings
that made it, ready to go straight back into the options panel.

TWO WAYS BACK, AND THE OLDER FILES STILL WORK.  A summary written now ends with
a `[data]` footer holding the settings and the stats verbatim, so a Shot from
one of those rebuilds the entire Result tab.  A summary written before that
footer existed still contains its `run with` command line, and Settings knows
how to parse one - so the snapshots already sitting in out/*/previews give back
every setting they were run with, and only the numbers are missing.  A reader
that worked solely on the new format would have declared the existing folders
unreadable, which for a feature whose whole point is looking back at what you
already did would be a strange place to start.

A .png WITH NO .txt IS STILL LISTED.  It is still a picture, and half a pair
left by a run that died between the two writes is exactly the thing you want to
be able to look at.  The reverse is not listed: a summary of a picture that is
not there is a puzzle, not an entry.

QT-FREE, like everything outside ui/.
"""

import json
import os

from . import snapshot, summary
from .settings import Settings

#: The header summary.as_text() gives the reproducing command line.  Matching
#: on the header rather than on "the line starting with python" means a summary
#: that mentions an interpreter anywhere else cannot be mistaken for one.
RUN_WITH = 'run with'


class Shot(object):
    """One saved preview: the picture, the summary, and how to get back to it."""

    def __init__(self, index, png, txt='', text='', settings=None, stats=None):
        self.index = index
        self.png = png
        self.txt = txt
        self.text = text
        #: None when neither the footer nor a command line could be found.
        self.settings = settings
        #: None for every snapshot written before the footer existed.
        self.stats = stats

    def label(self):
        return snapshot.STEM % self.index

    def dither(self):
        return self.settings.dither if self.settings else '?'

    def bias(self):
        return ('%.2f' % self.settings.effective_bias()
                if self.settings else '?')

    def result(self):
        """The list's right-hand column: the two numbers, or why there are none.

        SAYING WHERE THE NUMBERS WENT rather than showing a blank.  An empty
        cell reads as a run that produced nothing; this one reads as a file
        written before the footer, which is a different and much less alarming
        thing.
        """
        if not self.stats:
            return 'no data - summary in the Report tab'
        colours = self.stats.get('output_colours', 0)
        psnr = summary.psnr_text(self.stats)
        return '%d col%s' % (colours, ', %s' % psnr if psnr else '')

    def __repr__(self):
        return 'Shot(%d, %r)' % (self.index, os.path.basename(self.png))


def shots(directory):
    """Every snapshot in `directory`, ordered by number.

    ORDERED BY THE NUMBER, NOT BY THE LISTING.  os.listdir gives lexical order,
    in which Preview_10 sorts before Preview_09 once the zero padding runs out
    past ninety-nine - and a next button that jumps backwards is worse than no
    next button.
    """
    try:
        entries = os.listdir(directory)
    except OSError:                 # noqa: BLE001 - not a folder is not an error
        return []
    found = {}
    for entry in entries:
        n = snapshot.number_of(entry)
        if n is None:
            continue
        ext = os.path.splitext(entry)[1].lower()
        found.setdefault(n, {})[ext] = os.path.join(directory, entry)
    out = []
    for n in sorted(found):
        pair = found[n]
        png = pair.get('.png')
        if not png:
            continue
        txt = pair.get('.txt')
        out.append(parse(txt, index=n, png=png) if txt
                   else Shot(n, png))
    return out


def parse(txt_path, index=None, png=''):
    """One Shot from its summary file."""
    if index is None:
        index = snapshot.number_of(os.path.basename(txt_path)) or 0
    if not png:
        png = os.path.splitext(txt_path)[0] + '.png'
    text = ''
    try:
        with open(txt_path) as fh:
            text = fh.read()
    except OSError:                 # noqa: BLE001 - the picture still counts
        pass
    settings, stats = recover(text)
    return Shot(index, png, txt=txt_path, text=text,
                settings=settings, stats=stats)


def recover(text):
    """(settings, stats) out of a summary, best source first.

    THE FOOTER WINS WHEN IT IS THERE because it is the settings object itself
    rather than a rendering of it, and because it is the only place the stats
    survive at all.  The command line is the fallback, and it is a complete one
    for the settings - to_argv emits everything that changes the run.
    """
    settings = stats = None
    data = data_block(text)
    if data:
        if isinstance(data.get('settings'), dict):
            settings = Settings.from_dict(data['settings'])
        if isinstance(data.get('stats'), dict):
            stats = data['stats']
    if settings is None:
        line = command_line(text)
        if line:
            settings = Settings.from_command_line(line)
    return settings, stats


def data_block(text):
    """The parsed `[data]` footer, or None.

    rpartition, so a summary that happens to quote the marker earlier - a
    report echoing a previous one, say - cannot shadow the real footer at the
    bottom.
    """
    _head, marker, tail = text.rpartition(snapshot.DATA_MARKER)
    if not marker:
        return None
    parts = tail.split('\n', 1)             # the marker's own note, then JSON
    if len(parts) < 2:
        return None
    try:
        data = json.loads(parts[1])
    except ValueError:              # noqa: BLE001 - a truncated write, say
        return None
    return data if isinstance(data, dict) else None


def command_line(text):
    """The line under the summary's `run with` heading, or ''."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip().lower() != RUN_WITH:
            continue
        for follow in lines[i + 1:]:
            stripped = follow.strip()
            # The rule under the heading, then blanks, then the line itself.
            if not stripped or set(stripped) == set('-'):
                continue
            return stripped
        return ''
    return ''


def delete(shots_to_go):
    """Remove each shot's .png and .txt.  -> ([removed paths], [errors]).

    NO CONFIRMATION HERE - that is the pane's job, which can show a dialog;
    this is the part a test can run.  Numbering needs no repair afterwards:
    snapshot.next_index is max + 1, so a gap is never refilled.
    """
    removed, errors = [], []
    for shot in shots_to_go:
        for path in (shot.png, shot.txt):
            if not path or not os.path.isfile(path):
                continue
            try:
                os.remove(path)
                removed.append(path)
            except OSError as exc:  # noqa: BLE001 - reported, keep going
                errors.append('%s: %s' % (path, exc))
    return removed, errors
