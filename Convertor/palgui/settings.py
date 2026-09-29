"""settings.py - one Settings record, one field per palettize4.py flag.

THE ONLY PLACE THAT KNOWS HOW A FLAG IS SPELLED.  Every path to the converter -
Preview, Convert, a queued job, the Copy-command-line button - goes through
to_argv(), so the preview cannot drift away from the conversion by disagreeing
about an argument.  tests/test_palgui.py scrapes `palettize4.py --help` and
asserts this class covers every flag in it, which is what will catch the day a
twenty-second one is added.

DEFAULTS ARE COPIED FROM THE ARGPARSE BLOCK, NOT INVENTED, and to_argv() emits
nothing for a field still sitting on its default.  A default-valued Settings
therefore produces the shortest command line that does the job, which is what
makes the Copy-command-line button worth having: what lands on the clipboard is
something you would have been willing to type.

--quiet and --json are not fields.  The GUI always wants both - it reads the
stats off stdout and has nowhere to put the text report - so runner.py appends
them rather than offering controls that only have one sensible setting.
"""

import copy
import os


# --- the choices, copied from palettize4.py's argparse ----------------------
#: FILTERS, in the order palettize4.py's dict declares them.
FILTERS = ('nearest', 'box', 'bilinear', 'hamming', 'bicubic', 'lanczos')

FITS = ('stretch', 'cover', 'fit')

#: Error-diffusion kernels: smooth and organic, but SERIAL PYTHON over every
#: pixel, so these are the slow ones (seconds, not milliseconds).
DITHER_DIFFUSION = ('floyd', 'atkinson', 'jjn', 'stucki', 'sierra', 'burkes')

#: Ordered masks: vectorized, so fast.  `blue` is the one to reach for - see
#: its tooltip in ui/options.py.
DITHER_ORDERED = ('bayer2', 'bayer4', 'bayer8', 'blue')

DITHERS = ('none',) + DITHER_DIFFUSION + DITHER_ORDERED

# --- the hardware the GUI targets -------------------------------------------
# FOUR FLAGS ARE NOT CHOICES, THEY ARE THE MACHINE.  The VBXE viewer that reads
# these files runs one mode: 320x240, attributes every 8 pixels, four palettes
# of 256 entries.  A run at any other setting produces files it cannot display,
# so the panel states these rather than offering them - a spin box you can only
# use to make a mistake is worse than no spin box.
#
# THE GAP BETWEEN THIS AND Settings IS DELIBERATE.  Settings stays a faithful
# mirror of the command line, so a preset, a queue file or a hand-written argv
# can still carry anything palettize4 accepts, and palettize4 itself still
# takes any integer for all four.  The constants live here rather than in
# ui/options.py so there is one place to change when a viewer arrives that can
# do something else.

#: --resize.  THE GUI'S ONE DELIBERATE DEPARTURE FROM palettize4's DEFAULTS:
#: the converter defaults to no resample, and every run from here asks for one.
#: to_argv therefore always emits it, which is correct - what is on the command
#: line has to be what ran.
RESIZE_FIXED = '320x240'

#: --cell.  The hardware's attribute granularity.
CELL_FIXED = 8

#: --palettes.  The viewer's .map bytes carry the palette id in two bits, so
#: nothing downstream would know what to do with a fifth.
PALETTES_FIXED = 4

#: --slots.  A full palette.  With slot 0 reserved this leaves 255 usable
#: entries each, so the colour budget is 4 x 255 = 1020.
SLOTS_FIXED = 256


class Settings(object):
    """Every palettize4.py option, with the converter's own defaults."""

    #: field name -> default.  The order is the order argv comes out in, which
    #: is also roughly the order the options panel groups them.
    DEFAULTS = (
        ('input', ''),
        ('out', 'out'),
        ('name', ''),               # '' -> let palettize4 use the input stem
        ('cell', 8),
        ('palettes', 4),
        ('slots', 256),
        ('reserve0', True),
        ('colors', 0),              # 0 = auto = palettes * usable
        ('resize', '320x240'),      # the viewer's only mode; see above
        ('filter', 'lanczos'),
        ('fit', 'stretch'),
        ('display_aspect', '4:3'),
        ('description', ''),        # '' -> palettize4 uses the input stem
        ('color_bias', 0.0),
        ('max_colors', False),
        ('optimize', True),
        ('coherence', 1.5),
        ('dither', 'none'),
        ('dither_strength', 1.0),
        ('seed', 0),
    )

    def __init__(self, **kw):
        for field, default in self.DEFAULTS:
            setattr(self, field, kw.pop(field, default))
        if kw:
            raise TypeError('unknown setting(s): %s' % ', '.join(sorted(kw)))

    # --- copying ------------------------------------------------------------
    def clone(self):
        return copy.deepcopy(self)

    def __eq__(self, other):
        if not isinstance(other, Settings):
            return NotImplemented
        return self.to_dict() == other.to_dict()

    def __repr__(self):
        return 'Settings(%s)' % ', '.join(
            '%s=%r' % (f, getattr(self, f)) for f, d in self.DEFAULTS
            if getattr(self, f) != d)

    # --- the command line ---------------------------------------------------
    #: flag -> (field, converter), and switch -> (field, value).  THESE MIRROR
    #: to_argv AND ARE CHECKED AGAINST IT: a round-trip test asserts that
    #: from_argv(s.to_argv()) == s for a matrix of settings, so a flag added to
    #: one and forgotten in the other fails rather than silently reading back
    #: as a default.
    _FLAGS = {
        '--out': ('out', str),
        '--name': ('name', str),
        '--cell': ('cell', int),
        '--palettes': ('palettes', int),
        '--slots': ('slots', int),
        '--colors': ('colors', int),
        '--resize': ('resize', str),
        '--filter': ('filter', str),
        '--fit': ('fit', str),
        '--display-aspect': ('display_aspect', str),
        '--description': ('description', str),
        '--color-bias': ('color_bias', float),
        '--coherence': ('coherence', float),
        '--dither': ('dither', str),
        '--dither-strength': ('dither_strength', float),
        '--seed': ('seed', int),
    }
    _SWITCHES = {
        '--no-reserve0': ('reserve0', False),
        '--max-colors': ('max_colors', True),
        '--no-optimize': ('optimize', False),
    }

    def to_argv(self, out=None, name=None):
        """The palettize4.py arguments, WITHOUT the interpreter or the script.

        `out` and `name` override the stored ones, which is how Preview sends a
        run into its scratch directory without disturbing the settings the user
        is editing.

        A field still on its default emits nothing.  That is not only brevity:
        a preset written by an older version of this GUI still produces the
        command line palettize4 would default to for anything it does not
        mention.
        """
        out = self.out if out is None else out
        name = self.name if name is None else name
        argv = [self.input, '--out', out]
        if name:
            argv += ['--name', name]

        # --- the packing model ----------------------------------------------
        if int(self.cell) != 8:
            argv += ['--cell', '%d' % int(self.cell)]
        if int(self.palettes) != 4:
            argv += ['--palettes', '%d' % int(self.palettes)]
        if int(self.slots) != 256:
            argv += ['--slots', '%d' % int(self.slots)]
        if not self.reserve0:
            argv += ['--no-reserve0']
        if int(self.colors) > 0:
            argv += ['--colors', '%d' % int(self.colors)]

        # --- resampling -------------------------------------------------------
        # --filter, --fit AND --display-aspect DO NOTHING WITHOUT --resize:
        # palettize4.py only consults them inside `if args.resize:`.  Emitting
        # them anyway would put settings on the command line that had no effect,
        # which is the confusion the Copy-command-line button exists to avoid.
        if self.resize:
            argv += ['--resize', self.resize]
            if self.filter != 'lanczos':
                argv += ['--filter', self.filter]
            if self.fit != 'stretch':
                argv += ['--fit', self.fit]
                # --display-aspect is in turn only read by cover/fit.
                if self.display_aspect != '4:3':
                    argv += ['--display-aspect', self.display_aspect]

        # --- what the viewer's selector shows for it --------------------------
        if self.description.strip():
            argv += ['--description', self.description.strip()]

        # --- strategy ---------------------------------------------------------
        # --max-colors and --color-bias 1.0 are the same run; sending both would
        # be noise on the line, so the shorthand wins when it is set.
        if self.max_colors:
            argv += ['--max-colors']
        elif float(self.color_bias) != 0.0:
            argv += ['--color-bias', '%g' % float(self.color_bias)]
        if not self.optimize:
            argv += ['--no-optimize']
        if float(self.coherence) != 1.5:
            argv += ['--coherence', '%g' % float(self.coherence)]

        # --- dither -----------------------------------------------------------
        if self.dither != 'none':
            argv += ['--dither', self.dither]
            if float(self.dither_strength) != 1.0:
                argv += ['--dither-strength',
                         '%g' % float(self.dither_strength)]

        if int(self.seed) != 0:
            argv += ['--seed', '%d' % int(self.seed)]
        return argv

    def command_line(self, script='palettize4.py', python='python',
                     out=None, name=None):
        """The run as a line you could paste into a shell.  For the clipboard.

        out/name FORWARD TO to_argv FOR A REASON.  Every run now lands in a
        per-image subdirectory that the caller computes (runner.job_dir), so a
        line built from self.out alone would say --out out while the run
        actually used --out out/alicia - and pasting it would quietly write to
        the wrong place.  The line has to describe the run, not the record.
        """
        parts = [python, script] + self.to_argv(out=out, name=name)
        return ' '.join(quote(p) for p in parts)

    # --- effective values the UI wants to show ------------------------------
    def usable_per_palette(self):
        """Slots a real colour can land in - palettize4.py calls this `cap`."""
        return int(self.slots) - (1 if self.reserve0 else 0)

    def colour_budget(self):
        """palettes * cap: the count above which the source gets reduced.

        THE NUMBER THAT DECIDES WHETHER --dither DOES ANYTHING AT ALL, because
        palettize4.py only dithers inside its pre-quantization branch.  See
        runner.dither_was_inert().
        """
        return int(self.palettes) * self.usable_per_palette()

    def effective_bias(self):
        """--max-colors is exactly --color-bias 1.0; palettize4 agrees."""
        if self.max_colors:
            return 1.0
        return max(0.0, min(1.0, float(self.color_bias)))

    def effective_name(self):
        """What palettize4 will call the outputs if we do not pass --name."""
        if self.name:
            return self.name
        if not self.input:
            return ''
        return os.path.splitext(os.path.basename(self.input))[0]

    # --- serialisation -------------------------------------------------------
    def to_dict(self):
        return dict((f, getattr(self, f)) for f, d in self.DEFAULTS)

    @classmethod
    def from_dict(cls, d):
        """Tolerant of both missing and unknown keys.

        A preset saved by another version should load with whatever it does
        share rather than refusing outright - the alternative is a dialog
        telling the user their file is bad when nineteen of its twenty fields
        were perfectly usable.
        """
        s = cls()
        for field, _default in cls.DEFAULTS:
            if field in d:
                setattr(s, field, d[field])
        # A BLANK RESIZE IS AN OLD FILE, NOT A REQUEST.  Presets and queues
        # written before the target size was fixed carry resize='' - meaning
        # "no resample", which now means "output the viewer cannot display".
        # Upgrading it here is the difference between an old preset still
        # working and an old preset silently producing an unusable file.
        # Direct construction is left alone, so Settings(resize='') is still
        # available to the tests that exercise to_argv's suppression rules.
        if not s.resize:
            s.resize = RESIZE_FIXED
        return s

    @classmethod
    def from_argv(cls, argv):
        """The inverse of to_argv: a command line back into a Settings.

        WHAT THIS IS FOR is reading a saved Preview_NN.txt.  Its `run with`
        block is the exact line that produced the picture beside it, so it is
        also the only complete record of the settings in the thirty-odd
        snapshots written before there was any machine-readable footer.  Given
        a way to parse it, an afternoon of previews becomes something you can
        step back through; without one, those files are pictures with a
        paragraph of prose attached.

        TOLERANT LIKE from_dict, and for the same reason.  An unrecognised flag
        is skipped rather than raised on: a line written by a later version
        should still give back the fifteen fields it does share, instead of a
        dialog saying the file is bad.

        A LINE WITH NO --resize READS BACK AS THE FIXED 320x240, not as ''.
        Every line this GUI writes carries --resize, so the only way to reach
        that case is a hand-written one - and for those, the viewer's size is a
        far better guess than "no resample, output nothing can display".
        """
        s = cls()
        argv = [str(a) for a in argv]
        i = 0
        while i < len(argv):
            tok = argv[i]
            if tok in cls._SWITCHES:
                field, value = cls._SWITCHES[tok]
                setattr(s, field, value)
                i += 1
            elif tok in cls._FLAGS:
                field, cast = cls._FLAGS[tok]
                if i + 1 < len(argv):
                    try:
                        setattr(s, field, cast(argv[i + 1]))
                    except ValueError:      # noqa: BLE001 - keep the default
                        pass
                i += 2
            elif tok.startswith('-'):
                # Unknown.  Eat a value with it only if the next token does not
                # look like a flag itself, so `--quiet --json` loses neither.
                i += 2 if (i + 1 < len(argv)
                           and not argv[i + 1].startswith('-')) else 1
            else:
                if not s.input:             # the one positional argparse takes
                    s.input = tok
                i += 1
        return s

    @classmethod
    def from_command_line(cls, line):
        """from_argv over a pasted line, minus any `python palettize4.py`."""
        argv = split_command_line(line)
        while argv and not argv[0].startswith('-'):
            head = os.path.basename(argv[0]).lower()
            if head.endswith('.py') or head.split('.')[0] in ('python',
                                                              'python3', 'py'):
                argv.pop(0)
                continue
            break
        return cls.from_argv(argv)


def split_command_line(line):
    """The inverse of quote(): one pasted line back into a list of arguments.

    NOT shlex.  shlex in POSIX mode treats a backslash as an escape character,
    and the lines this has to read are full of Windows paths - the real files
    contain an --out whose value is a Windows path, and shlex quietly
    swallows every separator in it.  quote() only ever escapes a double quote, so
    that is the only escape understood here and a backslash is just a
    backslash.
    """
    out, cur = [], []
    quoted = started = False
    i = 0
    while i < len(line):
        c = line[i]
        if quoted:
            if c == '\\' and line[i + 1:i + 2] == '"':
                cur.append('"')
                i += 2
                continue
            if c == '"':
                quoted = False
            else:
                cur.append(c)
        elif c == '"':
            quoted = started = True
        elif c in ' \t':
            if started:
                out.append(''.join(cur))
                cur, started = [], False
        else:
            cur.append(c)
            started = True
        i += 1
    if started:
        out.append(''.join(cur))
    return out


def quote(s):
    """Shell-ish quoting, good enough for a line meant to be read and pasted."""
    s = str(s)
    if s and not any(c in s for c in ' \t"\'\\&|<>^()'):
        return s
    return '"%s"' % s.replace('"', '\\"')
