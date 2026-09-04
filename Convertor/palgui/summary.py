"""summary.py - what a run did, as data, so it can be a table OR a text file.

ONE DESCRIPTION, TWO RENDERERS.  The Result tab and the Preview_NN.txt written
beside a snapshot have to say the same things in the same order - a saved
summary that omits the verdict, or calls it something else, is a summary you
cannot compare against the pane you were looking at when you saved it.  So the
ordering and the wording live here, once, as tuples; ui/statspane.py turns them
into rows of a QTableWidget and as_text() turns them into aligned plain text.

QT-FREE, like everything outside ui/.  That is not incidental: it is what lets
a snapshot be written from jobs.run_queue() with no display attached, and what
lets the wording be tested without one.

TONES ARE SEMANTIC, NOT COLOURS.  A row says it is a warning; the pane decides
that warnings are amber and the text file decides they are nothing at all.  A
theme colour reaching into this module would drag PySide6 in behind it.

THE ORDER IS THE ORDER YOU ASK THE QUESTIONS.  "How many colours did I get" and
"what did it cost" first, because they are the answer; components, duplication
and per-palette occupancy after, because they are only the diagnosis when the
answer disappoints.

ACCURACY AND BLOCKINESS ARE TWO QUESTIONS, NOT ONE.  RMSE and PSNR say how far
the screen is from the picture the cell rule forbade; they CANNOT say whether
the damage arrived as noise or as 8-pixel stripes, because the same total error
scores the same either way.  `cell seams` is the one that answers that, and it
is why 700 clean colours can beat 900 blocky ones - a trade no single number in
this pane could show before.
"""

import os


#: Tones a row can carry.  ('palette', i) is the fourth, and is an identity
#: rather than a judgement - palette 2 is not worse than palette 1.
OK = 'ok'
WARN = 'warn'
ERR = 'err'

#: An OKLab difference below this is generally invisible; the README's worked
#: example calls 0.012 below threshold.
VISIBLE_ERROR = 0.02

#: Above this share of recoloured pixels the lossy phase stopped being a
#: touch-up and became the strategy.
RECOLOURED_BAD = 5.0
RECOLOURED_WARN = 1.0

#: How much harder the image may jump across an 8-pixel cell boundary than the
#: ideal does before the grid counts as visible.  MEASURED, NOT GUESSED: a
#: smooth photo lands near 1.02 and shows nothing, plasma.bmp at bias 1.0 hits
#: 1.38 and is obviously striped.  Retune here if your eye disagrees - these
#: two numbers are the only place that judgement lives.
SEAM_WARN = 1.10
SEAM_BAD = 1.30

#: Share of cells carrying at least one substituted pixel.  Not the same
#: question as the seam index: this is how MUCH of the picture is compromised,
#: that is how VISIBLE the compromise is.
CELLS_DAMAGED_WARN = 25.0


def rows(settings, stats, command=''):
    """The whole Result tab as tuples, in order.

    Yields ('head', text), ('row', key, value, tone) and ('note', text).
    `tone` is None, OK, WARN, ERR or ('palette', index).
    """
    if not stats:
        return [('row', '', 'no run yet - press Preview', None)]

    budget = settings.colour_budget()
    colours = stats.get('output_colours', 0)
    master = stats.get('master_colours', 0)
    out = []

    # --- the answer ---------------------------------------------------------
    out.append(('head', 'result'))
    if stats.get('lossless'):
        out.append(('row', 'verdict', 'LOSSLESS - every colour survived', OK))
    else:
        out.append(('row', 'verdict',
                    'lossy - %s' % stats.get('strategy', '?'), WARN))
    out.append(('row', 'colours on screen', '%d  (of a possible %d)'
                % (colours, budget),
                OK if colours >= budget * 0.9 else None))
    out.append(('row', 'master colours', '%d%s'
                % (master, '  (source was pre-quantized to this)'
                   if stats.get('prequantized') else ''), None))

    # --- what it cost -------------------------------------------------------
    if not stats.get('lossless'):
        out.append(('head', 'cost'))
        pct = stats.get('recoloured_pct', 0.0)
        out.append(('row', 'recoloured pixels', '%d  (%.3f%%)'
                    % (stats.get('recoloured_pixels', 0), pct),
                    ERR if pct > RECOLOURED_BAD else
                    (WARN if pct > RECOLOURED_WARN else None)))
        err = stats.get('mean_oklab_error', 0.0)
        # SAYING WHICH PIXELS IT AVERAGED OVER IS NOT PEDANTRY: the accuracy
        # section below carries a mean error too, over the whole image, and on
        # a typical run the two differ by more than an order of magnitude.
        out.append(('row', 'mean OKLab error', '%.4f  (recoloured px only%s)'
                    % (err, ', below the visible threshold'
                       if err and err < VISIBLE_ERROR else ''),
                    WARN if err >= VISIBLE_ERROR else None))

    # --- how close the screen is to the picture the cell rule forbade -------
    acc = accuracy(stats)
    if acc:
        out.append(('head', 'accuracy vs ideal'))
        out.append(('row', 'identical pixels', '%d of %d  (%.2f%%)'
                    % (acc.get('identical_pixels', 0),
                       acc.get('compared_pixels', 0),
                       acc.get('identical_pct', 0.0)), None))
        out.append(('row', 'RMSE (sRGB)',
                    '%.2f  (the norm distance)' % acc.get('rgb_rmse', 0.0),
                    None))
        psnr = acc.get('psnr_db')
        out.append(('row', 'PSNR',
                    'identical - the cell rule cost nothing' if psnr is None
                    else '%.1f dB' % psnr, OK if psnr is None else None))
        err = acc.get('mean_oklab_error', 0.0)
        out.append(('row', 'mean error vs ideal',
                    '%.4f  (every pixel, not just recoloured)' % err,
                    WARN if err >= VISIBLE_ERROR else None))
        out.append(('row', 'worst error vs ideal',
                    '%.4f' % acc.get('max_oklab_error', 0.0), None))
        dmg = acc.get('cells_damaged_pct', 0.0)
        out.append(('row', 'cells damaged', '%d of %d  (%.1f%%)'
                    % (acc.get('cells_damaged', 0),
                       acc.get('cells_compared', 0), dmg),
                    WARN if dmg > CELLS_DAMAGED_WARN else None))
        seam = acc.get('seam_index')
        out.append(('row', 'cell seams', seam_text(seam), seam_tone(seam)))
        if seam is not None and seam >= SEAM_WARN:
            out.append(('note', 'THE CELL GRID IS SHOWING: columns on an '
                        '8-pixel boundary jump %d%% harder than the same '
                        'columns do in the ideal.  Lower the colour bias to '
                        'trade colours back for smoother edges - the two move '
                        'in opposite directions, and the PSNR above cannot '
                        'see this.' % round((seam - 1.0) * 100)))

    # --- why you did not get more -------------------------------------------
    out.append(('head', 'why not more'))
    dup = stats.get('duplicated_across_palettes', 0)
    cap = settings.usable_per_palette()
    largest = stats.get('largest_component', 0)
    out.append(('row', 'duplicated entries', '%d' % dup,
                WARN if dup and colours < master else None))
    out.append(('row', 'distinct in palettes', '%d'
                % stats.get('distinct_in_all_palettes', 0), None))
    out.append(('row', 'components', '%d  (largest %d of %d usable)'
                % (stats.get('components', 0), largest, cap),
                WARN if largest > cap else None))
    if dup and colours < master:
        out.append(('note', 'a large duplicated count with fewer output '
                    'colours than master colours is cross-palette '
                    'duplication: raise the colour bias to spend those slots '
                    'on distinct colours instead'))
    if largest > cap:
        out.append(('note', 'one component needs more colours than a palette '
                    'holds, so a clean split was impossible - this is why the '
                    'run is lossy'))

    # --- the dither, and whether it happened at all -------------------------
    # THE ONE WARNING THIS WHOLE APP EXISTS FOR.  See runner.dither_was_inert:
    # a source already inside the budget is passed through untouched and
    # --dither is silently ignored, so three algorithms give three identical
    # pictures and you conclude dithering does nothing.  A SAVED SUMMARY THAT
    # NAMES A DITHER THE RUN NEVER RAN IS THAT TRAP IN WRITTEN FORM, found
    # again a week later with nothing on screen to contradict it - which is
    # why the note travels with the rows rather than living in the panel.
    if settings.dither != 'none':
        out.append(('head', 'dither'))
        inert = not stats.get('prequantized', False)
        out.append(('row', 'algorithm',
                    '%s  (NO EFFECT)' % settings.dither if inert
                    else settings.dither, WARN if inert else None))
        out.append(('row', 'strength',
                    '%g' % float(settings.dither_strength), None))
        if inert:
            out.append(('note', 'the source has only %d colours, which is '
                        'inside the %d budget, so no reduction ran and there '
                        'was nothing to dither.  Lower "pre-quantize" below '
                        '%d to force one.' % (master, budget, master)))

    # --- the palettes -------------------------------------------------------
    out.append(('head', 'per palette'))
    for i, p in enumerate(stats.get('per_palette', [])):
        out.append(('row', 'palette %d' % i, '%d / %d   (%d unique to it)'
                    % (p.get('colours', 0), cap,
                       p.get('unique_to_palette', 0)), ('palette', i)))

    # --- the picture's own facts --------------------------------------------
    out.append(('head', 'image'))
    out.append(('row', 'dimensions', '%d x %d  (%d px)'
                % (stats.get('width', 0), stats.get('height', 0),
                   stats.get('pixels', 0)), None))
    out.append(('row', 'cells', '%d per line, %d total'
                % (stats.get('cells_per_line', 0), stats.get('cells', 0)),
                None))
    if stats.get('resized'):
        out.append(('row', 'resampled', '-> %s via %s (fit %s)'
                    % (stats.get('resize'), stats.get('filter'),
                       stats.get('fit')), None))
    if stats.get('transparent_pixels'):
        out.append(('row', 'transparent px', '%d  (letterbox bars -> index 0)'
                    % stats['transparent_pixels'], None))

    if command:
        out.append(('head', 'run with'))
        out.append(('note', command))
    return out


def accuracy(stats):
    """palettize4's ideal_vs_output block, or {} for a run that predates it.

    EVERY _stats.json ALREADY ON DISK LACKS THIS BLOCK - the ones under out/
    and the twelve hand-made folders beside them.  Rendering zeros for those
    would read as a flawless result, which is the exact opposite of what is
    known about them, so the whole section is skipped instead.
    """
    if not stats:
        return {}
    block = stats.get('ideal_vs_output')
    return block if isinstance(block, dict) else {}


def psnr_text(stats):
    """The headline accuracy number for a status bar or a table cell.

    Here rather than in runner.py so that the pane, the status line and the
    queue column cannot end up rounding one number three different ways.
    """
    acc = accuracy(stats)
    if not acc:
        return ''
    if acc.get('psnr_db') is None:
        return 'identical'
    return '%.1f dB' % acc['psnr_db']


def seam_text(seam):
    """The blockiness number in the words the table has room for."""
    if seam is None:
        return 'n/a  (no column detail to measure)'
    if seam < SEAM_WARN:
        return '%.2fx  (grid not visible)' % seam
    return '%.2fx  (grid showing)' % seam


def seam_tone(seam):
    if seam is None or seam < SEAM_WARN:
        return None
    return ERR if seam >= SEAM_BAD else WARN


def as_text(settings, stats, command='', report='', header='', extra=()):
    """The whole thing as a plain-text file: header, rows, then the report.

    THE REPORT IS INCLUDED VERBATIM, not summarised.  palettize4 writes it and
    some of its wording exists nowhere else; a snapshot that paraphrased it
    would be a third description of one run, free to disagree with the other
    two.

    `extra` is (key, value) pairs for the header - what the snapshot itself is,
    which the stats cannot know.
    """
    lines = []
    if header:
        lines.append(header)
        lines.append('=' * 64)
    lines.append('%-8s: %s' % ('input', settings.input))
    for key, value in extra:
        lines.append('%-8s: %s' % (key, value))
    lines.append('')

    # The command goes in its own block rather than through rows(), so it is
    # near the top where you look for it instead of buried under the palettes.
    if command:
        lines.append('run with')
        lines.append('-' * 64)
        lines.append(command)
        lines.append('')

    lines.append('result')
    lines.append('-' * 64)
    body = rows(settings, stats)
    width = max([len(r[1]) for r in body if r[0] == 'row'] or [0])
    for row in body:
        if row[0] == 'head':
            lines.append('')
            lines.append('[%s]' % row[1])
        elif row[0] == 'row':
            lines.append('  %-*s : %s' % (width, row[1], row[2]))
        else:
            lines.extend(_wrap(row[1], width + 5))
    lines.append('')

    if report:
        lines.append('palettize4 report')
        lines.append('-' * 64)
        lines.append(report.rstrip('\n'))
        lines.append('')
    return '\n'.join(lines)


def _wrap(text, indent, width=76):
    """A note, wrapped and indented under the values it belongs to."""
    pad = ' ' * min(indent, 20)
    out, line = [], pad
    for word in text.split():
        if len(line) + 1 + len(word) > width and line.strip():
            out.append(line)
            line = pad
        line += (' ' if line.strip() else '') + word
    if line.strip():
        out.append(line)
    return out


def report_text(path):
    """palettize4's own {name}_report.txt, or '' if it is not there."""
    if not path or not os.path.isfile(path):
        return ''
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:                 # noqa: BLE001 - a sidecar, not the data
        return ''
