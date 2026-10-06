"""describe.py - change a finished conversion's description, no re-convert.

THE DESCRIPTION LIVES IN FOUR FILES AND THEY MUST AGREE:

    {B}_stats.json    "description" (+ "args"."description")  <- Gather reads
    {B}_report.txt    the Description row, wrapped at 57       <- Report tab
    {B}.nfo           the same report as the Atari screen      <- Info screen
    {B}_summary.txt   header, embedded report, [data] footer   <- Load settings

Editing only the stats would fix IMAGES.LST and leave the Atari Info screen
saying the old text, and the .nfo is binary - so this rewrites all four from
one call.  The picture itself (.v1k .raw .map .pal .png) is never opened.

REBUILT, NOT PATCHED, WHERE A RENDERER EXISTS.  The report rows use
palettize4's own layout (label padded to 21, value at column 23, wrap at 57),
the .nfo comes from nfo_encode.encode() - the encoder palettize4's bytes
match - and the summary goes back through snapshot.write_conversion with its
original `when` and `convertor` kept.  The result is what a fresh conversion
with --description would have written, byte for byte, in those rows.

QT-FREE, like everything outside ui/: set_description.py and File > Edit
descriptions... both call it.
"""

import glob
import json
import os
import textwrap

from . import review, runner, snapshot
from .imageslst import NAME_CAP

# nfo_encode.py lives beside palettize4.py; imageslst already put that
# directory on sys.path.
import nfo_encode  # noqa: E402

#: palettize4's report layout: "{label:<21}: {value}", continuations at 23.
LABEL_W = 21
VALUE_COL = 23
WRAP = 80 - VALUE_COL
LABEL = 'Description'


class DescribeError(Exception):
    """A description that cannot be applied, with a sentence saying why."""


def clean(text):
    """The text as it will be stored, or DescribeError.

    PRINTABLE ASCII ONLY: the .nfo is a byte-per-glyph screen image and the
    viewer's font has nothing for a curly quote or an accented letter.
    """
    text = ' '.join((text or '').split())
    bad = sorted(set(c for c in text if not ' ' <= c <= '~'))
    if bad:
        raise DescribeError('not printable ASCII (the Atari cannot show '
                            'them): %s' % ' '.join(repr(c) for c in bad))
    if len(text) > NAME_CAP:
        raise DescribeError('%d characters - the status line holds %d'
                            % (len(text), NAME_CAP))
    return text


def default_for(stats):
    """palettize4's own default: the input filename, no extension/period."""
    src = stats.get('source_name') or os.path.basename(stats.get('input', ''))
    return os.path.splitext(src)[0].rstrip('.')[:NAME_CAP].rstrip()


def stats_path(folder):
    """The folder's newest {B}_stats.json, or ''."""
    found = glob.glob(os.path.join(folder, '*_stats.json'))
    return max(found, key=os.path.getmtime) if found else ''


def current(folder):
    """The description Gather would use for this folder now, or None."""
    path = stats_path(folder)
    if not path:
        return None
    with open(path) as fh:
        return json.load(fh).get('description') or ''


def report_rows(text):
    """The Description row(s) exactly as palettize4 writes them."""
    parts = textwrap.wrap(text, WRAP) or ['']
    return (['%-*s: %s' % (LABEL_W, LABEL, parts[0])]
            + [' ' * VALUE_COL + p for p in parts[1:]])


def replace_report_rows(report, text):
    """The report with its Description row(s) swapped for `text`.

    A report with no Description row (written before 0.19) gets one under
    Input, which is where palettize4 puts it.
    """
    lines = report.rstrip('\n').split('\n')
    at = next((i for i, ln in enumerate(lines)
               if ln[:LABEL_W].rstrip() == LABEL), None)
    if at is None:
        at = next((i + 1 for i, ln in enumerate(lines)
                   if ln[:LABEL_W].rstrip() == 'Input'), 1)
        end = at
    else:
        end = at + 1
        while end < len(lines) and lines[end].startswith(' ' * VALUE_COL) \
                and lines[end].strip():
            end += 1
    lines[at:end] = report_rows(text)
    return '\n'.join(lines) + '\n'


def set_description(folder, text, dry_run=False):
    """Give one conversion folder a new description.  -> (old, new, files).

    `files` is what was (or, dry run, would be) rewritten.  A blank `text`
    resets to the converter's default.  Unchanged text changes nothing.
    """
    spath = stats_path(folder)
    if not spath:
        raise DescribeError('%s holds no _stats.json' % folder)
    with open(spath) as fh:
        stats = json.load(fh)
    new = clean(text) or default_for(stats)
    old = stats.get('description') or ''
    base = spath[:-len('_stats.json')]
    rpath = base + '_report.txt'
    npath = base + '.nfo'
    mpath = base + snapshot.SUMMARY_SUFFIX

    report = _read(rpath)
    new_report = replace_report_rows(report, new) if report else ''
    args = stats.get('args')
    if (new == old and new_report == report
            and (not isinstance(args, dict)
                 or args.get('description') in (None, new))):
        return old, new, []

    files = [spath]
    if report:
        files += [rpath, npath]
    if os.path.isfile(mpath):
        files.append(mpath)
    if dry_run:
        return old, new, files

    stats['description'] = new
    if isinstance(args, dict):
        args['description'] = new
    _write(spath, json.dumps(stats, indent=2))
    if report:
        _write(rpath, new_report)
        _write(npath, nfo_encode.encode(new_report), binary=True)
    if os.path.isfile(mpath):
        _rewrite_summary(mpath, folder, stats, new, new_report)
    return old, new, files


def _rewrite_summary(path, folder, stats, new, report):
    """The summary again, through the same renderer, keeping when/version."""
    text = _read(path)
    settings, _old_stats = review.recover(text)
    if settings is None:
        return
    settings.description = new
    header = dict((ln.split(':', 1)[0].strip(), ln.split(':', 1)[1].strip())
                  for ln in text.split('\n')[:8] if ':' in ln)
    command = settings.command_line(script='palettize4.py',
                                    out=runner.job_dir(settings))
    snapshot.write_conversion(folder, settings, stats, command, report,
                              when=header.get('when'),
                              convertor=header.get('convertor'))


# --- one list for every image ---------------------------------------------
def folders(out_root):
    """Every immediate subfolder of out_root that holds a conversion."""
    return [os.path.join(out_root, d)
            for d in sorted(os.listdir(out_root), key=str.lower)
            if os.path.isdir(os.path.join(out_root, d))
            and stats_path(os.path.join(out_root, d))]


def export_list(out_root, path):
    """Write `folder = description` for every conversion.  -> count."""
    lines = ['# One line per image: <folder> = <description>',
             '# Up to %d printable ASCII characters.  A blank description '
             'resets to the filename.' % NAME_CAP,
             '# Apply:  python set_description.py %s --apply %s --go'
             % (os.path.basename(os.path.abspath(out_root)) or out_root,
                os.path.basename(path)),
             '']
    fs = folders(out_root)
    width = min(max([len(os.path.basename(f)) for f in fs] or [0]), 24)
    for f in fs:
        lines.append('%-*s = %s' % (width, os.path.basename(f), current(f)))
    with open(path, 'w') as fh:
        fh.write('\n'.join(lines) + '\n')
    return len(fs)


def read_list(path):
    """[(folder name, description), ...] from a list file."""
    rows = []
    with open(path) as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip('\n')
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            if '=' not in line:
                raise DescribeError('line %d has no "=": %s' % (n, line))
            name, _eq, desc = line.partition('=')
            rows.append((name.strip(), desc.strip()))
    return rows


def apply_list(out_root, path, dry_run=True):
    """Apply a list file.  -> [(folder, old, new, files or error), ...]."""
    results = []
    for name, desc in read_list(path):
        folder = os.path.join(out_root, name)
        try:
            old, new, files = set_description(folder, desc, dry_run=dry_run)
            results.append((name, old, new, files))
        except (DescribeError, OSError, ValueError) as exc:  # noqa: BLE001
            results.append((name, None, desc, str(exc)))
    return results


def _read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:                 # noqa: BLE001 - optional sidecar
        return ''


def _write(path, data, binary=False):
    """Whole file or nothing: write beside it, then replace."""
    tmp = path + '.tmp'
    with open(tmp, 'wb' if binary else 'w') as fh:
        fh.write(data)
    os.replace(tmp, path)
