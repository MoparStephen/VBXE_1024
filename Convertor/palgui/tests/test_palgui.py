"""test_palgui.py - the headless half, on a Python with nothing installed.

NO QT IS IMPORTED HERE AND THAT IS THE TEST AS MUCH AS THE ASSERTIONS ARE.  If
this file ever needs PySide6 to run, something below ui/ has grown a Qt import
and the layering has quietly gone.

THE FLAG-COVERAGE TEST IS THE IMPORTANT ONE.  Everything else checks that the
code does what it currently does; that one checks that it still covers what
palettize4.py currently OFFERS, by scraping the converter's own --help.  The
day a twenty-second flag is added, the GUI silently not exposing it is exactly
the failure nobody notices, and that test is the only thing that will say so.

Run from the Convertor directory:

    python -m unittest discover -s palgui/tests -t .
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

import palgui
from palgui import (describe, gather, imageslst, jobs, presets, recover,
                    review, runner, snapshot, summary)
from palgui.imageslst import atari_name
from palgui.settings import (DITHERS, FILTERS, FITS, RESIZE_FIXED,
                            Settings, split_command_line)

CONVERTOR = runner.CONVERTOR

#: Flags the GUI deliberately does not offer as controls, with the reason.  A
#: flag may only be in this list because it has a good reason to be, and that
#: reason has to be written down here rather than assumed.
NOT_A_CONTROL = {
    '--quiet': 'always passed - the GUI has nowhere to put the text report',
    '--json': 'always passed - the GUI reads the stats off stdout',
    '--help': 'argparse\'s own',
}


def _sample():
    """A source certainly present and certainly over the colour budget."""
    # Convertor/ first, then the repo's "Images To Convert", where the
    # sources moved to - without it every end-to-end test quietly skips.
    for where in (CONVERTOR, os.path.join(os.path.dirname(CONVERTOR),
                                          'Images To Convert')):
        for name in ('plasma.bmp', 'stanley.bmp', 'sunset.jpg', 'dragon.png'):
            p = os.path.join(where, name)
            if os.path.isfile(p):
                return p
    return None


#: A literal backslash.  Spelled this way because the Windows paths these
#: tests build are the whole reason split_command_line exists, and a source
#: file full of doubled escapes hides which ones are real.
BS = chr(92)


def _write_png(path, size):
    """A real image on disk - snapshot.save copies it, so it has to open."""
    from PIL import Image
    Image.new('RGB', size, (10, 20, 30)).save(path)


class TestFlagCoverage(unittest.TestCase):
    """Does Settings still cover every flag palettize4.py has?"""

    def test_every_flag_is_covered(self):
        p = subprocess.run([sys.executable, runner.script_path(), '--help'],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        flags = set(_norm(f)
                    for f in re.findall(r'(--[a-z0-9][a-z0-9-]*)', p.stdout))

        # What Settings can emit, over every field driven to a non-default.
        #
        # PROBED FROM A BASE WITH THE DEPENDENCIES ALREADY SATISFIED, because
        # to_argv() correctly suppresses --filter without --resize and
        # --dither-strength without --dither.  Probing from a bare default
        # would therefore "prove" the GUI cannot produce flags it produces
        # perfectly well the moment the option they depend on is on.
        emitted = set()
        for field, default in Settings.DEFAULTS:
            for value in _probe_values(field, default):
                s = Settings(input='x.png', resize='320x240', fit='cover',
                             dither='blue')
                setattr(s, field, value)
                emitted.update(_norm(a) for a in s.to_argv()
                               if a.startswith('--'))

        missing = flags - emitted - set(NOT_A_CONTROL)
        self.assertFalse(
            missing,
            'palettize4.py offers flags the GUI cannot produce: %s.  Add a '
            'field to Settings and a control to ui/options.py, or add it to '
            'NOT_A_CONTROL with the reason.' % ', '.join(sorted(missing)))

    def test_no_invented_flags(self):
        """And nothing the converter would reject."""
        p = subprocess.run([sys.executable, runner.script_path(), '--help'],
                           capture_output=True, text=True)
        known = set(re.findall(r'(--[a-z0-9][a-z0-9-]*)', p.stdout))
        s = Settings(input='x.png', resize='320x240', filter='nearest',
                     fit='cover', display_aspect='16:9', cell=4, palettes=2,
                     slots=64, reserve0=False, colors=500, color_bias=0.5,
                     optimize=False, coherence=3.0, dither='blue',
                     dither_strength=0.5, seed=7)
        for a in s.to_argv():
            if a.startswith('--'):
                self.assertIn(a, known, '%s is not a palettize4 flag' % a)

    def test_choices_match(self):
        """The combo boxes offer exactly what argparse accepts."""
        p = subprocess.run([sys.executable, runner.script_path(), '--help'],
                           capture_output=True, text=True)
        text = ' '.join(p.stdout.split())
        for name, values in (('filter', FILTERS), ('fit', FITS),
                             ('dither', DITHERS)):
            for v in values:
                self.assertIn(v, text,
                              '%s is offered for --%s but --help does not '
                              'mention it' % (v, name))


def _norm(flag):
    """--no-reserve0 and --reserve0 are one option, not two.

    argparse's BooleanOptionalAction prints both spellings and Settings emits
    whichever the value calls for, so comparing them unnormalised would report
    a flag as missing purely because the default happens to be the true one.
    """
    if flag.startswith('--no-'):
        return '--' + flag[len('--no-'):]
    return flag


def _probe_values(field, default):
    """Non-default values for a field, enough to make to_argv() emit it."""
    if field == 'input':
        return ['x.png']
    if field == 'out':
        return ['build']
    if field == 'name':
        return ['img7']
    if isinstance(default, bool):
        return [not default]
    if field == 'resize':
        return ['640x480']       # anything but the GUI's own fixed target
    if field == 'filter':
        return ['nearest']
    if field == 'fit':
        return ['cover']
    if field == 'display_aspect':
        return ['16:9']
    if field == 'dither':
        return ['blue']
    if isinstance(default, int):
        return [default + 1]
    if isinstance(default, float):
        return [default + 0.5]
    return ['x']


class TestSettings(unittest.TestCase):

    def test_defaults_emit_almost_nothing(self):
        """A default Settings is the shortest command line that does the job.

        --resize IS THE ONE EXCEPTION AND IS MEANT TO BE.  palettize4 defaults
        to no resample; the GUI targets a viewer that only has one mode, so
        every run from here asks for 320x240 and the line has to say so.  If
        this assertion ever loosens to `assertIn`, a future default could start
        riding along unnoticed.
        """
        s = Settings(input='a.png')
        self.assertEqual(s.to_argv(),
                         ['a.png', '--out', 'out', '--resize', RESIZE_FIXED])

    def test_dependent_flags_are_suppressed(self):
        """--filter/--fit/--display-aspect do nothing without --resize.

        palettize4 only reads them inside `if args.resize:`, so emitting them
        would put settings on the copied command line that had no effect.
        """
        s = Settings(input='a.png', resize='', filter='nearest', fit='cover',
                     display_aspect='16:9')
        self.assertNotIn('--filter', s.to_argv())
        self.assertNotIn('--fit', s.to_argv())
        self.assertNotIn('--display-aspect', s.to_argv())
        s.resize = '320x240'
        argv = s.to_argv()
        self.assertIn('--filter', argv)
        self.assertIn('--fit', argv)
        self.assertIn('--display-aspect', argv)

    def test_display_aspect_needs_a_non_stretch_fit(self):
        s = Settings(input='a.png', resize='320x240', display_aspect='16:9')
        self.assertNotIn('--display-aspect', s.to_argv())

    def test_max_colors_wins_over_bias(self):
        """They are the same run; sending both would be noise."""
        s = Settings(input='a.png', max_colors=True, color_bias=0.3)
        argv = s.to_argv()
        self.assertIn('--max-colors', argv)
        self.assertNotIn('--color-bias', argv)
        self.assertEqual(s.effective_bias(), 1.0)

    def test_out_and_name_override(self):
        s = Settings(input='a.png', out='build', name='img2')
        self.assertEqual(s.to_argv(out='/tmp/x', name='preview'),
                         ['a.png', '--out', '/tmp/x', '--name', 'preview',
                          '--resize', RESIZE_FIXED])

    def test_budget_follows_reserve0(self):
        s = Settings()
        self.assertEqual(s.usable_per_palette(), 255)
        self.assertEqual(s.colour_budget(), 1020)
        s.reserve0 = False
        self.assertEqual(s.colour_budget(), 1024)

    def test_effective_name_is_the_input_stem(self):
        s = Settings(input=os.path.join('a', 'b', 'dragon.png'))
        self.assertEqual(s.effective_name(), 'dragon')
        s.name = 'img3'
        self.assertEqual(s.effective_name(), 'img3')

    def test_dict_round_trip(self):
        s = Settings(input='a.png', dither='blue', color_bias=0.5,
                     coherence=2.0)
        self.assertEqual(Settings.from_dict(s.to_dict()), s)

    def test_from_dict_tolerates_junk(self):
        """A preset from another version loads with what it does share."""
        s = Settings.from_dict({'dither': 'floyd', 'nonsense': 1})
        self.assertEqual(s.dither, 'floyd')
        self.assertEqual(s.coherence, 1.5)

    def test_from_dict_upgrades_a_blank_resize(self):
        """An old preset must not quietly run at native size.

        Files written before the target was fixed carry resize='', which used
        to mean "no resample" and now means "output the viewer cannot show".
        Direct construction is left alone so to_argv's suppression rules stay
        testable - it is only the deserialised case that upgrades.
        """
        self.assertEqual(Settings.from_dict({'resize': ''}).resize,
                         RESIZE_FIXED)
        self.assertEqual(Settings.from_dict({}).resize, RESIZE_FIXED)
        self.assertEqual(Settings(resize='').resize, '')

    def test_command_line_quotes_spaces(self):
        s = Settings(input=r'C:\my images\a.png')
        self.assertIn('"C:\\my images\\a.png"', s.command_line())


class TestRunner(unittest.TestCase):

    def test_build_command_always_asks_for_json(self):
        cmd = runner.build_command(Settings(input='a.png'), out='o')
        self.assertEqual(cmd[0], sys.executable)
        self.assertTrue(cmd[1].endswith('palettize4.py'))
        self.assertIn('--quiet', cmd)
        self.assertIn('--json', cmd)

    def test_parse_stats_ignores_chatter_before_the_object(self):
        """numpy and PIL can warn on stdout; losing a run to that is absurd."""
        obj = {'output_colours': 12, 'lossless': True}
        out = 'some warning\nanother line\n%s\n' % json.dumps(obj)
        self.assertEqual(runner.parse_stats(out), obj)

    def test_parse_stats_without_stats_is_an_error(self):
        with self.assertRaises(runner.RunError):
            runner.parse_stats('nothing useful here')

    def test_classify_names_the_scipy_case(self):
        err = runner.classify(1, '--dither needs scipy: pip install scipy')
        self.assertEqual(err.kind, 'scipy')
        self.assertIn('scipy', err.message)

    def test_classify_takes_the_last_line_of_a_traceback(self):
        err = runner.classify(1, 'Traceback...\n  File x\nValueError: bad wh')
        self.assertIn('ValueError: bad wh', err.message)

    def test_dither_was_inert(self):
        """The check that stops a dither comparison failing silently."""
        s = Settings(input='a.png', dither='blue')
        self.assertTrue(runner.dither_was_inert(s, {'prequantized': False}))
        self.assertFalse(runner.dither_was_inert(s, {'prequantized': True}))
        s.dither = 'none'
        self.assertFalse(runner.dither_was_inert(s, {'prequantized': False}))

    def test_headline_says_lossless(self):
        s = Settings()
        self.assertIn('LOSSLESS',
                      runner.headline(s, {'lossless': True,
                                          'output_colours': 900}))
        self.assertIn('lossy',
                      runner.headline(s, {'lossless': False,
                                          'output_colours': 900,
                                          'strategy': 'fidelity'}))


class TestPresets(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='palgui-presets-')
        self._was = presets.PRESET_DIR
        presets.PRESET_DIR = self.dir

    def tearDown(self):
        presets.PRESET_DIR = self._was
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_round_trip_keeps_punctuation_in_the_name(self):
        """The file name cannot hold brackets; the display name must."""
        name = 'Pixel art (no resample)'
        presets.save(name, Settings(filter='nearest', dither='none'))
        self.assertEqual(presets.names(), [name])
        self.assertEqual(presets.load(name).filter, 'nearest')

    def test_paths_are_not_a_recipe(self):
        """Applying a preset must not silently change which image you are on."""
        presets.save('p', Settings(input='a.png', out='build', name='img1',
                                   dither='blue'))
        onto = Settings(input='b.png', out='mine', name='img9')
        got = presets.load('p', onto=onto)
        self.assertEqual(got.input, 'b.png')
        self.assertEqual(got.out, 'mine')
        self.assertEqual(got.name, 'img9')
        self.assertEqual(got.dither, 'blue')

    def test_description_is_not_a_recipe(self):
        """A description belongs to one image, never to a preset."""
        presets.save('p', Settings(description='A cat'))
        got = presets.load('p', onto=Settings(description='A dog'))
        self.assertEqual(got.description, 'A dog')

    def test_description_round_trips_through_argv(self):
        s = Settings(input='a.png', description='Sunset, "Malibu" 2024')
        argv = s.to_argv()
        self.assertIn('--description', argv)
        self.assertEqual(Settings.from_argv(argv).description, s.description)
        self.assertNotIn('--description', Settings(input='a.png').to_argv())

    def test_builtins_only_land_in_an_empty_directory(self):
        presets.ensure_builtins()
        n = len(presets.names())
        self.assertTrue(n)
        presets.delete(presets.names()[0])
        presets.ensure_builtins()
        self.assertEqual(len(presets.names()), n - 1)


class TestJobs(unittest.TestCase):

    def test_queue_edits(self):
        q = jobs.Queue()
        a = q.add(Settings(input='a.png'))
        b = q.add(Settings(input='b.png'))
        self.assertEqual([j.label for j in q], ['a', 'b'])
        self.assertEqual(q.move(0, 1), 1)
        self.assertEqual([j.label for j in q], ['b', 'a'])
        q.remove(0)
        self.assertEqual(len(q), 1)
        self.assertIs(q[0], a)
        del b

    def test_results_are_not_saved(self):
        """A stale colour count would look exactly like a fact."""
        q = jobs.Queue()
        job = q.add(Settings(input='a.png', dither='blue'))
        job.state = jobs.DONE
        job.stats = {'output_colours': 900}
        path = os.path.join(tempfile.mkdtemp(prefix='palgui-q-'), 'q.json')
        q.save(path)
        back = jobs.Queue.load(path)
        self.assertEqual(back[0].state, jobs.PENDING)
        self.assertEqual(back[0].settings.dither, 'blue')
        shutil.rmtree(os.path.dirname(path), ignore_errors=True)

    def test_retarget_moves_the_whole_queue(self):
        """What turns a saved queue into a script."""
        q = jobs.Queue()
        for d in ('none', 'blue', 'floyd'):
            q.add(Settings(input='plasma.bmp', dither=d, name='plasma'))
        q[0].state = jobs.DONE
        q[0].stats = {'output_colours': 900}
        self.assertEqual(q.retarget('eye.png'), 3)
        for job in q:
            self.assertEqual(job.settings.input, 'eye.png')
            # CLEARED, not carried: three jobs still named `plasma` would
            # write eye.png's results into plasma's folder, over each other.
            self.assertEqual(job.settings.name, '')
            self.assertEqual(job.label, 'eye')
            self.assertEqual(job.state, jobs.PENDING)
            self.assertIsNone(job.stats)
        self.assertEqual([j.settings.dither for j in q],
                         ['none', 'blue', 'floyd'])

    def test_collisions_are_found_before_you_press_run(self):
        q = jobs.Queue()
        for d in ('none', 'blue', 'floyd'):
            q.add(Settings(input='plasma.bmp', dither=d))
        clash = q.collisions()
        self.assertEqual(len(clash), 1)
        self.assertEqual(clash[0][1], [0, 1, 2])

    def test_a_distinct_name_or_out_is_not_a_collision(self):
        q = jobs.Queue()
        q.add(Settings(input='plasma.bmp', name='a'))
        q.add(Settings(input='plasma.bmp', name='b'))
        self.assertEqual(q.collisions(), [])
        q = jobs.Queue()
        q.add(Settings(input='plasma.bmp', out='one'))
        q.add(Settings(input='plasma.bmp', out='two'))
        self.assertEqual(q.collisions(), [])
        # Different images in one folder do not collide either.
        q = jobs.Queue()
        q.add(Settings(input='plasma.bmp'))
        q.add(Settings(input='eye.png'))
        self.assertEqual(q.collisions(), [])

    def test_a_saved_queue_keeps_no_snapshot(self):
        """A queue file is a plan; a snapshot is a result."""
        q = jobs.Queue()
        job = q.add(Settings(input='a.png'))
        job.snapshot = ('p.png', 'p.txt')
        self.assertNotIn('snapshot', job.to_dict())
        back = jobs.Job.from_dict(job.to_dict())
        self.assertIsNone(back.snapshot)
        job.reset()
        self.assertIsNone(job.snapshot)

    def test_note_reports_an_inert_dither(self):
        q = jobs.Queue()
        job = q.add(Settings(input='a.png', dither='blue'))
        job.state = jobs.DONE
        job.stats = {'prequantized': False, 'master_colours': 40,
                     'output_colours': 40}
        self.assertIn('had no effect', job.note())

    def test_counts(self):
        q = jobs.Queue()
        q.add(Settings(input='a.png')).state = jobs.DONE
        q.add(Settings(input='b.png')).state = jobs.FAILED
        q.add(Settings(input='c.png'))
        self.assertEqual(q.counts(), (1, 1, 3))


def _serial_diffuse(p4, arr, pal, algo, strength=1.0):
    """Error diffusion the obvious way: one pixel at a time, in scan order.

    THE DEFINITION, KEPT SEPARATELY FROM THE IMPLEMENTATION.  palettize4's own
    dither_to_palette walks anti-diagonals so it can do a whole diagonal per
    numpy call, which is ~15x faster and much less obviously correct.  This is
    the version that is obviously correct, and TestDither below asserts the
    fast one still agrees with it - so the optimisation cannot quietly drift
    into a different dither.
    """
    import numpy as np
    from scipy.spatial import cKDTree
    tree = cKDTree(pal.astype(np.float64))
    kernel = p4.DITHER_KERNELS[algo]
    H, W, _ = arr.shape
    work = arr.astype(np.float64)
    out = np.empty((H, W), np.int64)
    for y in range(H):
        for x in range(W):
            old = work[y, x]
            j = int(tree.query(old)[1])
            out[y, x] = j
            err = (old - pal[j]) * strength
            for dx, dy, wt in kernel:
                xx, yy = x + dx, y + dy
                if 0 <= xx < W and 0 <= yy < H:
                    work[yy, xx] += err * wt
    return pal[out].astype(np.uint8)


class TestDither(unittest.TestCase):
    """The fast wavefront must equal the serial definition, exactly."""

    def setUp(self):
        import importlib.util
        for mod in ('numpy', 'scipy'):
            if importlib.util.find_spec(mod) is None:
                self.skipTest('dithering needs numpy and scipy')
        self.p4 = runner.palettize4()

    def _palette(self, arr, n=64):
        import numpy as np
        u, c = np.unique(arr.reshape(-1, 3), axis=0, return_counts=True)
        pal, _ = self.p4.median_cut(u, c, min(n, len(u)))
        return pal

    def test_wavefront_slope_covers_every_kernel(self):
        """The whole optimisation rests on this inequality holding."""
        c = self.p4._WAVEFRONT_C
        for name, kernel in self.p4.DITHER_KERNELS.items():
            for dx, dy, _w in kernel:
                self.assertGreater(
                    dx + c * dy, 0,
                    '%s reaches to (%d,%d), which a slope of %d walks in the '
                    'wrong order' % (name, dx, dy, c))

    def test_matches_the_serial_definition(self):
        import numpy as np
        rng = np.random.default_rng(0)
        # Small, because the reference is the slow one.  Shapes chosen for the
        # edges: a single pixel, a single row, a single column - all cases
        # where a diagonal holds one pixel or none.
        shapes = ((1, 1), (1, 9), (9, 1), (3, 3), (11, 7))
        for shape in shapes:
            arr = rng.integers(0, 256, shape + (3,), dtype=np.uint8)
            pal = self._palette(arr)
            for algo in self.p4.DITHER_KERNELS:
                for strength in (1.0, 0.5):
                    got = self.p4.dither_to_palette(arr, pal, algo, strength)
                    want = _serial_diffuse(self.p4, arr, pal, algo, strength)
                    self.assertTrue(
                        np.array_equal(got, want),
                        '%s at strength %s on a %s image differs from the '
                        'serial definition' % (algo, strength, shape))

    def test_matches_on_a_real_image(self):
        """Random noise exercises the edges; a photograph exercises the
        gradients the dither actually exists for."""
        import numpy as np
        sample = _sample()
        if not sample:
            self.skipTest('no sample image in %s' % CONVERTOR)
        img = self.p4.Image.open(sample).convert('RGB').resize(
            (40, 30), self.p4.FILTERS['lanczos'])
        arr = np.asarray(img)
        pal = self._palette(arr, 32)
        for algo in ('floyd', 'atkinson', 'stucki'):
            got = self.p4.dither_to_palette(arr, pal, algo)
            want = _serial_diffuse(self.p4, arr, pal, algo)
            self.assertTrue(np.array_equal(got, want), algo)

    def test_output_is_in_the_palette(self):
        """Whatever the ordering, every pixel must be a palette colour."""
        import numpy as np
        rng = np.random.default_rng(1)
        arr = rng.integers(0, 256, (20, 16, 3), dtype=np.uint8)
        pal = self._palette(arr)
        allowed = set(map(tuple, pal.tolist()))
        for algo in ('floyd', 'blue', 'bayer4'):
            out = self.p4.dither_to_palette(arr, pal, algo)
            self.assertEqual(out.shape, arr.shape)
            got = set(map(tuple, out.reshape(-1, 3).tolist()))
            self.assertTrue(got <= allowed,
                            '%s emitted a colour not in the palette' % algo)


class TestOutputLayout(unittest.TestCase):
    """One image, one folder - runner.job_dir and runner.resolve."""

    def test_folder_is_named_for_the_output_base(self):
        s = Settings(input=os.path.join('pics', 'bgneon.bmp'))
        self.assertEqual(runner.job_dir(s), os.path.join('out', 'bgneon'))
        s.name = 'img7'
        self.assertEqual(runner.job_dir(s), os.path.join('out', 'img7'))

    def test_relative_stays_relative(self):
        """So a copied command line is not a path from this machine only."""
        s = Settings(input='a.png')
        self.assertFalse(os.path.isabs(runner.job_dir(s)))
        s.out = os.path.join(tempfile.gettempdir(), 'build')
        self.assertTrue(os.path.isabs(runner.job_dir(s)))

    def test_no_input_means_no_subfolder(self):
        """Rather than a directory literally called '' inside out/."""
        self.assertEqual(runner.job_dir(Settings()), 'out')

    def test_resolve_anchors_relative_paths_at_convertor(self):
        """palettize4 does makedirs against ITS cwd, which is not ours."""
        self.assertEqual(runner.resolve('out'),
                         os.path.join(CONVERTOR, 'out'))
        absolute = os.path.join(tempfile.gettempdir(), 'x')
        self.assertEqual(runner.resolve(absolute), absolute)

    def test_the_command_line_names_the_folder_that_ran(self):
        """Paste it and it writes where the GUI wrote, not one level up."""
        s = Settings(input=os.path.join('pics', 'bgneon.bmp'))
        line = s.command_line(out=runner.job_dir(s))
        self.assertIn(os.path.join('out', 'bgneon'), line)


class TestSnapshot(unittest.TestCase):
    """Numbering and writing of the Preview_NN pairs."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='palgui-snap-')

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _touch(self, name):
        with open(os.path.join(self.dir, name), 'w') as fh:
            fh.write('x')

    def test_first_index_is_one(self):
        self.assertEqual(snapshot.next_index(self.dir), 1)

    def test_a_directory_that_is_not_there_yet(self):
        self.assertEqual(
            snapshot.next_index(os.path.join(self.dir, 'nope')), 1)

    def test_counts_up_from_the_highest(self):
        self._touch('Preview_01.png')
        self._touch('Preview_02.png')
        self.assertEqual(snapshot.next_index(self.dir), 3)

    def test_a_gap_is_not_filled(self):
        """MAX + 1, NOT COUNT + 1.

        Delete Preview_02 out of three and a count would hand the next run 03,
        overwriting the one that was deliberately kept.
        """
        self._touch('Preview_01.png')
        self._touch('Preview_03.png')
        self.assertEqual(snapshot.next_index(self.dir), 4)

    def test_half_a_pair_still_reserves_its_number(self):
        """A .txt whose picture never got written is not a free slot."""
        self._touch('Preview_07.txt')
        self.assertEqual(snapshot.next_index(self.dir), 8)

    def test_unrelated_files_are_ignored(self):
        self._touch('Preview.png')
        self._touch('notes.txt')
        self._touch('Preview_two.png')
        self.assertEqual(snapshot.next_index(self.dir), 1)

    def test_dir_for_is_under_the_image_folder(self):
        got = snapshot.dir_for(os.path.join('a', 'out'), 'bgneon')
        self.assertEqual(got, os.path.join('a', 'out', 'bgneon', 'previews'))

    def test_save_writes_a_pair_and_keeps_every_colour(self):
        """The picture is copied, so the colour count cannot drift."""
        try:
            from PIL import Image
        except ImportError:
            self.skipTest('Pillow is not installed')
        src = os.path.join(self.dir, 'src.png')
        img = Image.new('RGB', snapshot.SIZE)
        for x in range(snapshot.SIZE[0]):
            for y in range(snapshot.SIZE[1]):
                img.putpixel((x, y), (x % 256, y % 256, (x + y) % 256))
        img.save(src)
        before = snapshot.describe(src)

        where = os.path.join(self.dir, 'out')
        index, png, txt = snapshot.save(where, src, 'the summary')
        self.assertEqual(index, 1)
        self.assertTrue(os.path.isfile(png))
        self.assertTrue(os.path.isfile(txt))
        self.assertEqual(snapshot.describe(png), before)
        self.assertEqual(snapshot.describe(png)[3], False)

        # And the second one does not tread on the first.
        index2, png2, _ = snapshot.save(where, src, 'again')
        self.assertEqual(index2, 2)
        self.assertNotEqual(png, png2)

    def test_a_result_that_is_not_320x240_is_nearest_resampled(self):
        """Only nearest can be trusted not to invent a colour."""
        try:
            from PIL import Image
        except ImportError:
            self.skipTest('Pillow is not installed')
        src = os.path.join(self.dir, 'big.png')
        Image.new('RGB', (640, 480), (10, 20, 30)).save(src)
        _i, png, _t = snapshot.save(self.dir, src, 'x')
        w, h, colours, resampled = snapshot.describe(png)
        self.assertEqual((w, h), snapshot.SIZE)
        self.assertEqual(colours, 1)
        self.assertFalse(resampled)     # it IS 320x240 now


class TestSummary(unittest.TestCase):
    """The rows the Result tab and the saved Preview_NN.txt both render."""

    STATS = {
        'output_colours': 900, 'master_colours': 1000, 'lossless': False,
        'strategy': 'fidelity', 'recoloured_pixels': 200,
        'recoloured_pct': 0.26, 'mean_oklab_error': 0.011,
        'duplicated_across_palettes': 40, 'distinct_in_all_palettes': 980,
        'components': 12, 'largest_component': 300, 'prequantized': True,
        'width': 320, 'height': 240, 'pixels': 76800,
        'cells_per_line': 40, 'cells': 9600, 'resized': True,
        'resize': '320x240', 'filter': 'lanczos', 'fit': 'cover',
        'per_palette': [{'colours': 255, 'unique_to_palette': 200}] * 4,
        # Consistent with recoloured_pixels above on purpose: identical +
        # recoloured == compared is an invariant of the real converter, and a
        # fixture that broke it would teach the wrong shape.
        'ideal_vs_output': {
            'compared_pixels': 76800, 'identical_pixels': 76600,
            'identical_pct': 99.74, 'rgb_rmse': 2.41, 'psnr_db': 40.5,
            'mean_oklab_error': 0.0031, 'max_oklab_error': 0.0912,
            'cells_compared': 9600, 'cells_damaged': 1210,
            'cells_damaged_pct': 12.6, 'seam_index': 1.38,
        },
    }

    def test_rows_lead_with_the_answer(self):
        got = summary.rows(Settings(input='a.png'), self.STATS)
        self.assertEqual(got[0], ('head', 'result'))
        self.assertEqual(got[1][1], 'verdict')

    def test_no_stats_is_not_a_crash(self):
        got = summary.rows(Settings(), None)
        self.assertEqual(len(got), 1)

    def test_tones_are_tokens_not_colours(self):
        """summary.py must stay importable without PySide6."""
        for row in summary.rows(Settings(input='a.png'), self.STATS):
            if row[0] == 'row':
                self.assertIn(type(row[3]).__name__,
                              ('NoneType', 'str', 'tuple'))

    def test_an_inert_dither_is_recorded_in_writing(self):
        """A saved summary naming a dither that never ran is the whole trap."""
        s = Settings(input='a.png', dither='floyd')
        stats = dict(self.STATS, prequantized=False)
        text = summary.as_text(s, stats)
        self.assertIn('NO EFFECT', text)
        # A short phrase: the note is wrapped, so anything longer than
        # a few words can legitimately straddle a line break.
        self.assertIn('no reduction ran', text)

    def test_a_dither_that_ran_says_so_plainly(self):
        s = Settings(input='a.png', dither='floyd', dither_strength=0.5)
        text = summary.as_text(s, self.STATS)
        self.assertIn('floyd', text)
        self.assertNotIn('NO EFFECT', text)
        self.assertIn('0.5', text)

    def test_as_text_carries_the_command_and_the_report(self):
        s = Settings(input='a.png')
        text = summary.as_text(s, self.STATS,
                               command='python palettize4.py a.png',
                               report='palettize4 report\nmaster: 1000\n')
        self.assertIn('python palettize4.py a.png', text)
        self.assertIn('master: 1000', text)
        self.assertIn('a.png', text)
        # The verdict and the colour count, which are the whole point.
        self.assertIn('lossy - fidelity', text)
        self.assertIn('900', text)

    def test_the_accuracy_block_is_rendered(self):
        s = Settings(input='a.png')
        keys = [r[1] for r in summary.rows(s, self.STATS) if r[0] == 'row']
        for want in ('PSNR', 'RMSE (sRGB)', 'cells damaged', 'cell seams'):
            self.assertIn(want, keys)
        text = summary.as_text(s, self.STATS)
        self.assertIn('40.5 dB', text)
        self.assertIn('1.38x', text)

    def test_a_visible_grid_is_called_out_in_writing(self):
        """The blockiness warning has to survive into the saved snapshot.

        Reading 'cell seams 1.38x' on disk a week later means nothing without
        the sentence that says which way to move the bias.
        """
        s = Settings(input='a.png')
        text = summary.as_text(s, self.STATS)
        self.assertIn('THE CELL GRID IS SHOWING', text)
        quiet = dict(self.STATS)
        quiet['ideal_vs_output'] = dict(self.STATS['ideal_vs_output'],
                                        seam_index=1.01)
        self.assertNotIn('THE CELL GRID IS SHOWING',
                         summary.as_text(s, quiet))

    def test_the_two_mean_errors_are_told_apart(self):
        """One averages recoloured pixels, one averages the picture."""
        s = Settings(input='a.png')
        text = summary.as_text(s, self.STATS)
        self.assertIn('recoloured px only', text)
        self.assertIn('every pixel, not just recoloured', text)

    def test_a_run_from_before_this_feature_is_not_a_crash(self):
        """Every _stats.json already on disk lacks the block.

        Rendering zeros for those would read as a flawless result, so the
        section has to disappear rather than lie.
        """
        s = Settings(input='a.png')
        old = dict(self.STATS)
        del old['ideal_vs_output']
        keys = [r[1] for r in summary.rows(s, old) if r[0] == 'row']
        self.assertNotIn('PSNR', keys)
        self.assertIn('colours on screen', keys)
        self.assertEqual(summary.psnr_text(old), '')
        self.assertEqual(summary.accuracy(old), {})

    def test_psnr_text_has_one_spelling(self):
        self.assertEqual(summary.psnr_text(self.STATS), '40.5 dB')
        same = dict(self.STATS)
        same['ideal_vs_output'] = dict(self.STATS['ideal_vs_output'],
                                       psnr_db=None)
        self.assertEqual(summary.psnr_text(same), 'identical')
        self.assertEqual(summary.psnr_text(None), '')

    def test_the_table_and_the_file_say_the_same_things(self):
        """Both renderers consume ONE row list; this is what pins that."""
        s = Settings(input='a.png')
        text = summary.as_text(s, self.STATS)
        for row in summary.rows(s, self.STATS):
            if row[0] == 'row':
                self.assertIn(row[1], text, '%s is missing from the file'
                              % row[1])


class TestCommandLine(unittest.TestCase):
    """to_argv's inverse.  The only way back into the 31 snapshots on disk."""

    #: Enough variation to touch every branch in to_argv.
    MATRIX = []
    for _dither in ('none', 'floyd', 'blue'):
        for _fit in ('stretch', 'cover', 'fit'):
            for _extra in ({}, {'max_colors': True},
                           {'color_bias': 0.35, 'coherence': 0.0},
                           {'colors': 700, 'reserve0': False,
                            'optimize': False, 'seed': 9},
                           {'cell': 16, 'palettes': 2, 'slots': 64}):
                MATRIX.append(dict(_extra, dither=_dither, fit=_fit))

    def test_a_line_reproduces_the_run_it_came_from(self):
        """THE PROPERTY THAT MATTERS, and it is argv-level not field-level.

        to_argv deliberately drops flags that cannot do anything - no
        --display-aspect under `fit stretch`, no --dither-strength under
        `dither none` - so those values are genuinely not on the line and no
        parser can invent them.  What must hold is that what comes back
        RE-EMITS THE SAME LINE: the recovered settings run the same run.
        """
        for kw in self.MATRIX:
            s = Settings(input='C:%sUsers%sme%smy pics%sa b.png'
                         % (BS, BS, BS, BS), name='x', filter='nearest',
                         display_aspect='16:9', dither_strength=0.4, **kw)
            back = Settings.from_argv(s.to_argv())
            self.assertEqual(back.to_argv(), s.to_argv(), '%r' % kw)
            line = s.command_line()
            self.assertEqual(Settings.from_command_line(line).command_line(),
                             line, '%r' % kw)

    def test_field_equality_when_no_flag_was_suppressed(self):
        """With no dead fields set, the round trip is exact."""
        for kw in self.MATRIX:
            kw = dict(kw)
            kw['display_aspect'] = '16:9' if kw['fit'] != 'stretch' else '4:3'
            kw['dither_strength'] = 0.4 if kw['dither'] != 'none' else 1.0
            s = Settings(input='a.png', filter='nearest', **kw)
            self.assertEqual(Settings.from_argv(s.to_argv()), s)

    def test_a_windows_path_survives(self):
        """shlex would eat these, which is why this parser exists."""
        win = 'out%sisabelle_fuhrman_eyes' % BS
        self.assertEqual(split_command_line('--out "%s"' % win),
                         ['--out', win])
        self.assertEqual(split_command_line('a "b c" d'), ['a', 'b c', 'd'])
        self.assertEqual(split_command_line('"say %s"hi%s""' % (BS, BS)),
                         ['say "hi"'])
        self.assertEqual(split_command_line('   '), [])

    def test_the_interpreter_and_script_are_dropped(self):
        s = Settings.from_command_line(
            'python palettize4.py a.png --out o --dither blue')
        self.assertEqual(s.input, 'a.png')
        self.assertEqual(s.dither, 'blue')
        self.assertEqual(Settings.from_argv(['a.png']).input, 'a.png')

    def test_an_unknown_flag_is_skipped_not_fatal(self):
        """A line from a later version must still give back what it shares."""
        s = Settings.from_argv(['a.png', '--newthing', '3', '--dither', 'blue',
                                '--quiet', '--json'])
        self.assertEqual(s.input, 'a.png')
        self.assertEqual(s.dither, 'blue')

    def test_a_junk_value_keeps_the_default(self):
        s = Settings.from_argv(['a.png', '--seed', 'banana'])
        self.assertEqual(s.seed, 0)


class TestReview(unittest.TestCase):
    """Reading a previews folder back into something you can step through."""

    def setUp(self):
        import importlib.util
        if importlib.util.find_spec('PIL') is None:
            self.skipTest('the snapshot writer needs Pillow')
        self.dir = tempfile.mkdtemp(prefix='palgui-review-')
        self.png = os.path.join(self.dir, 'src.png')
        _write_png(self.png, snapshot.SIZE)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _save(self, settings, stats=None, text='', index=None):
        data = None
        if stats is not None:
            data = {'settings': settings.to_dict(), 'stats': stats}
        body = text or summary.as_text(settings, stats or {},
                                       command=settings.command_line())
        return snapshot.save(self.dir, self.png, body, index=index, data=data)

    def test_an_empty_or_missing_directory(self):
        self.assertEqual(review.shots(os.path.join(self.dir, 'nope')), [])
        self.assertEqual(review.shots(self.dir), [])

    def test_order_follows_the_number_not_the_listing(self):
        """Past 99 the padding runs out and lexical order goes wrong."""
        s = Settings(input='a.png')
        for i in (9, 10, 100, 2):
            self._save(s, index=i)
        self.assertEqual([x.index for x in review.shots(self.dir)],
                         [2, 9, 10, 100])

    def test_the_footer_brings_back_settings_and_stats(self):
        s = Settings(input='a.png', dither='blue', color_bias=0.25)
        stats = {'output_colours': 750, 'lossless': False,
                 'ideal_vs_output': {'psnr_db': 38.2}}
        self._save(s, stats=stats)
        shot = review.shots(self.dir)[0]
        self.assertEqual(shot.settings, s)
        self.assertEqual(shot.stats, stats)
        self.assertIn('750 col', shot.result())
        self.assertIn('38.2 dB', shot.result())

    def test_a_summary_with_no_footer_still_gives_its_settings(self):
        """The 31 already on disk are all like this."""
        s = Settings(input='a.png', dither='floyd', color_bias=0.4,
                     fit='cover', display_aspect='16:9')
        self._save(s)                       # stats=None -> no footer
        shot = review.shots(self.dir)[0]
        self.assertIsNone(shot.stats)
        self.assertEqual(shot.settings.to_argv(), s.to_argv())
        self.assertIn('no data', shot.result())
        self.assertIn('palettize4', shot.text)

    def test_both_readers_agree(self):
        """THE INVARIANT TYING THE TWO PATHS TOGETHER.

        A summary carries its settings twice - once as the command line a
        human reads, once in the footer a machine reads.  If those ever
        disagree the file is lying to one of its two readers, and which one
        you believe would depend on how old the file was.
        """
        s = Settings(input='a.png', dither='blue', color_bias=0.25,
                     fit='fit', display_aspect='5:4', seed=3, colors=800)
        _i, _png, txt = self._save(s, stats={'output_colours': 1})
        with open(txt) as fh:
            text = fh.read()
        from_footer = Settings.from_dict(
            review.data_block(text)['settings'])
        from_line = Settings.from_command_line(review.command_line(text))
        self.assertEqual(from_footer.to_argv(), from_line.to_argv())

    def test_a_picture_without_a_summary_is_still_listed(self):
        s = Settings(input='a.png')
        self._save(s, index=1)
        os.remove(os.path.join(self.dir, snapshot.STEM % 1 + '.txt'))
        self._save(s, index=2)
        os.remove(os.path.join(self.dir, snapshot.STEM % 2 + '.png'))
        got = review.shots(self.dir)
        self.assertEqual([x.index for x in got], [1])
        self.assertIsNone(got[0].settings)
        self.assertEqual(got[0].text, '')

    def test_unrelated_files_are_ignored(self):
        self._save(Settings(input='a.png'))
        for junk in ('notes.txt', 'Preview.png', 'Preview_.txt', 'a_02.png'):
            with open(os.path.join(self.dir, junk), 'w') as fh:
                fh.write('x')
        self.assertEqual(len(review.shots(self.dir)), 1)

    def test_a_truncated_footer_falls_back_to_the_command_line(self):
        s = Settings(input='a.png', dither='blue')
        _i, _png, txt = self._save(s, stats={'output_colours': 1})
        with open(txt) as fh:
            text = fh.read()
        with open(txt, 'w') as fh:            # cut the JSON in half
            fh.write(text[:text.index(snapshot.DATA_MARKER) + 40])
        shot = review.parse(txt)
        self.assertIsNone(shot.stats)
        self.assertEqual(shot.settings.dither, 'blue')

    def test_the_footer_is_below_the_summary(self):
        """The prose is the part meant for reading; it stays on top."""
        s = Settings(input='a.png')
        _i, _png, txt = self._save(s, stats={'output_colours': 1})
        with open(txt) as fh:
            text = fh.read()
        self.assertLess(text.index('run with'),
                        text.index(snapshot.DATA_MARKER))
        self.assertIn('machine-readable', text)


class TestAccuracy(unittest.TestCase):
    """compare_to_ideal(): the displayed image against the forbidden one.

    THE POINT OF THESE IS THE LAST ONE.  RMSE and PSNR cannot distinguish
    damage scattered as noise from damage collapsed into 8-pixel stripes, so
    without a test that holds the error constant and moves only its POSITION,
    the seam index would just be a third way of saying the same thing.
    """

    def setUp(self):
        import importlib.util
        if importlib.util.find_spec('numpy') is None:
            self.skipTest('the measurement is numpy')
        self.p4 = runner.palettize4()

    def _ramp(self, H=4, W=32):
        """A grey gradient: colour id == column, so every column jumps the
        same amount and the ideal has no seam of its own to divide out."""
        import numpy as np
        colors = np.stack([np.arange(64, dtype=np.uint8) * 4] * 3, axis=1)
        pix = np.tile(np.arange(W, dtype=np.int64), (H, 1))
        return colors, pix

    def _measure(self, colors, pix, out_cid, transparent=None, cell_w=8):
        import numpy as np
        if transparent is None:
            transparent = np.zeros(pix.shape, dtype=bool)
        return self.p4.compare_to_ideal(pix, out_cid, colors,
                                        self.p4.rgb_to_oklab(colors),
                                        transparent, cell_w)

    def test_an_image_against_itself_is_identical(self):
        colors, pix = self._ramp()
        acc = self._measure(colors, pix, pix.copy())
        self.assertEqual(acc['identical_pixels'], acc['compared_pixels'])
        self.assertEqual(acc['identical_pct'], 100.0)
        self.assertEqual(acc['rgb_rmse'], 0.0)
        self.assertEqual(acc['mean_oklab_error'], 0.0)
        self.assertEqual(acc['cells_damaged'], 0)
        # null, NOT inf: json.dump writes a bare Infinity, which is not JSON.
        self.assertIsNone(acc['psnr_db'])

    def test_one_changed_pixel_damages_exactly_one_cell(self):
        colors, pix = self._ramp()
        out = pix.copy()
        out[2, 9] = 40
        acc = self._measure(colors, pix, out)
        self.assertEqual(acc['identical_pixels'], acc['compared_pixels'] - 1)
        self.assertEqual(acc['cells_damaged'], 1)
        self.assertGreater(acc['max_oklab_error'], 0.0)
        self.assertIsNotNone(acc['psnr_db'])

    def test_transparent_pixels_are_counted_nowhere(self):
        """Letterbox bars are padding; a wider bar must not flatter a run."""
        import numpy as np
        colors, pix = self._ramp()
        transparent = np.zeros(pix.shape, dtype=bool)
        transparent[:, :8] = True
        out = pix.copy()
        out[:, :8] = 63                     # wreck the bar completely
        acc = self._measure(colors, pix, out, transparent)
        self.assertEqual(acc['compared_pixels'], pix.size - 8 * pix.shape[0])
        self.assertEqual(acc['identical_pct'], 100.0)
        self.assertEqual(acc['cells_damaged'], 0)
        self.assertEqual(acc['cells_compared'], 3 * pix.shape[0])

    def test_the_seam_index_sees_position_where_psnr_cannot(self):
        """Same pixels wrong, same amount wrong, different PLACE.

        Both runs shift one 8-pixel-wide band of every row by the same amount.
        In the first the band sits on the cell grid, so both of its edges land
        on a cell boundary; in the second it straddles, so both edges land
        between boundaries.  RMSE and PSNR must be equal to the bit - and the
        seam index must not be, or it is measuring error rather than
        blockiness and this whole number is decoration.
        """
        colors, pix = self._ramp()
        on_grid, straddling = pix.copy(), pix.copy()
        on_grid[:, 8:16] += 20
        straddling[:, 12:20] += 20
        a = self._measure(colors, pix, on_grid)
        b = self._measure(colors, pix, straddling)

        self.assertEqual(a['rgb_rmse'], b['rgb_rmse'])
        self.assertEqual(a['psnr_db'], b['psnr_db'])
        self.assertEqual(a['identical_pixels'], b['identical_pixels'])
        self.assertGreater(a['seam_index'], 2.0)
        self.assertLess(b['seam_index'], 1.0)

    def test_a_flat_image_has_no_seam_to_report(self):
        """Nothing to divide by, so say so rather than inventing a ratio."""
        import numpy as np
        colors, _ = self._ramp()
        pix = np.zeros((4, 32), dtype=np.int64)
        acc = self._measure(colors, pix, pix.copy())
        self.assertIsNone(acc['seam_index'])


class TestPreviewQueue(unittest.TestCase):
    """The loop the whole feature exists for, run for real with no display.

    Queue one image several ways, preview the queue, and end with a numbered
    pair per job that review.shots() can walk.  Converting the same queue is
    the before picture: one set of files, because every conversion of one
    image is called the same thing.
    """

    def setUp(self):
        self.sample = _sample()
        if not self.sample:
            self.skipTest('no sample image in %s' % CONVERTOR)
        self.out = tempfile.mkdtemp(prefix='palgui-pq-')

    def tearDown(self):
        shutil.rmtree(self.out, ignore_errors=True)

    def _queue(self, dithers=('none', 'bayer4', 'blue')):
        q = jobs.Queue()
        for d in dithers:
            q.add(Settings(input=self.sample, out=self.out, dither=d,
                           resize='160x120'))
        return q

    def test_previewing_a_queue_keeps_every_job(self):
        q = self._queue()
        done, failed, total = jobs.run_queue(q, preview=True)
        self.assertEqual((done, failed, total), (3, 0, 3))

        name = q[0].settings.effective_name()
        where = snapshot.dir_for(self.out, name)
        shots = review.shots(where)
        self.assertEqual([s.index for s in shots], [1, 2, 3])

        # Each job kept its OWN pair, and each pair remembers its own dither.
        self.assertEqual([os.path.basename(j.snapshot[0]) for j in q],
                         [s.label() + '.png' for s in shots])
        self.assertEqual([s.settings.dither for s in shots],
                         ['none', 'bayer4', 'blue'])
        for shot in shots:
            self.assertIsNotNone(shot.stats)

        # Three different dithers on a photographic source are three different
        # pictures; identical bytes would mean the queue ran one job thrice.
        blobs = set()
        for shot in shots:
            with open(shot.png, 'rb') as fh:
                blobs.add(fh.read())
        self.assertEqual(len(blobs), 3)

        # THE SCRATCH DIRECTORY IS GONE and nothing leaked beside previews/.
        self.assertEqual(sorted(os.listdir(os.path.join(self.out, name))),
                         [snapshot.DIRNAME])

    def test_converting_the_same_queue_leaves_one_result(self):
        """The before picture - and why Preview all exists."""
        q = self._queue()
        self.assertEqual(len(q.collisions()), 1)
        jobs.run_queue(q)
        name = q[0].settings.effective_name()
        made = os.listdir(os.path.join(self.out, name))
        self.assertNotIn(snapshot.DIRNAME, made)
        # One conversion's worth of files, not three.
        self.assertEqual(sum(1 for f in made if f.endswith('.raw')), 1)
        for job in q:
            self.assertIsNone(job.snapshot)

    def test_a_previewed_snapshot_reproduces_the_convert(self):
        """The recorded command line must not name the scratch directory.

        It is gone by the time anyone reads the summary, and a recipe pointing
        at a deleted temporary folder is not a recipe.
        """
        q = self._queue(('blue',))
        jobs.run_queue(q, preview=True)
        shot = review.shots(snapshot.dir_for(
            self.out, q[0].settings.effective_name()))[0]
        line = review.command_line(shot.text)
        self.assertIn(q[0].settings.effective_name(), line)
        self.assertNotIn('palgui-queue-', line)
        self.assertEqual(Settings.from_command_line(line).dither, 'blue')


class TestEndToEnd(unittest.TestCase):
    """One real conversion.  Slow, but it is the only thing that proves the
    argv this package builds is one palettize4 actually accepts."""

    def setUp(self):
        self.sample = _sample()
        if not self.sample:
            self.skipTest('no sample image in %s' % CONVERTOR)
        self.out = tempfile.mkdtemp(prefix='palgui-e2e-')

    def tearDown(self):
        shutil.rmtree(self.out, ignore_errors=True)

    def test_a_run_writes_what_the_stats_claim(self):
        s = Settings(input=self.sample, resize='160x120')
        stats = runner.run_blocking(s, out=self.out, name='t')
        self.assertGreater(stats['output_colours'], 0)
        self.assertEqual(stats['width'], 160)
        self.assertEqual(stats['height'], 120)
        paths = runner.output_paths(stats, self.out)
        for key in ('raw', 'map', 'preview', 'report', 'stats'):
            self.assertTrue(os.path.isfile(paths[key]), key)
        for p in paths['palettes']:
            self.assertEqual(os.path.getsize(p), 768)
        # .raw is one byte per pixel, .map one byte per cell.
        self.assertEqual(os.path.getsize(paths['raw']), 160 * 120)
        self.assertEqual(os.path.getsize(paths['map']),
                         stats['cells_per_line'] * 120)
        # A pixel whose colour id was not substituted is reproduced bit-exact,
        # so the new count and the old one have to partition the image.  This
        # is the only assertion tying the accuracy block to the numbers
        # palettize4 was already reporting.
        acc = summary.accuracy(stats)
        self.assertTrue(acc, 'the run wrote no ideal_vs_output block')
        self.assertEqual(acc['identical_pixels'] + stats['recoloured_pixels'],
                         acc['compared_pixels'])
        self.assertLessEqual(acc['cells_damaged'], acc['cells_compared'])
        # 160x120 is not the viewer's fixed 320x240, so no .v1k - and the
        # key is absent rather than null, so output_paths() still joins.
        self.assertNotIn('v1k', paths)

    def test_a_default_run_writes_the_v1k(self):
        """At the viewer's own geometry the .v1k is .pal + .map + .raw."""
        s = Settings(input=self.sample)
        stats = runner.run_blocking(s, out=self.out, name='t')
        paths = runner.output_paths(stats, self.out)
        parts = b''
        for key in ('palettes_combined', 'map', 'raw'):
            with open(paths[key], 'rb') as f:
                parts += f.read()
        with open(paths['v1k'], 'rb') as f:
            v1k = f.read()
        self.assertEqual(len(v1k), 3072 + 9600 + 76800)
        self.assertEqual(v1k, parts)

    def test_outputs_get_the_atari_name_and_report_settings(self):
        """A long/illegal --name is reduced to the 8-char Atari base, and the
        report says which dither and coherence the run used."""
        s = Settings(input=self.sample, resize='160x120', color_bias=0.5,
                     coherence=2.0, dither='floyd', dither_strength=0.5)
        stats = runner.run_blocking(s, out=self.out, name='2024 long name')
        self.assertEqual(stats['name'], 'I2024LON')
        self.assertEqual(stats['files']['nfo'], 'I2024LON.nfo')
        self.assertEqual(stats['dither'], 'floyd')
        self.assertEqual(stats['dither_strength'], 0.5)
        paths = runner.output_paths(stats, self.out)
        for key in ('raw', 'map', 'nfo', 'report'):
            self.assertTrue(os.path.isfile(paths[key]), key)
        with open(paths['report']) as f:
            lines = f.read().splitlines()
        labels = [ln[:21].strip() for ln in lines]
        i = labels.index('Strategy')
        self.assertEqual(labels[i + 1], 'Coherence')
        self.assertIn('2.00  (attribute-map smoothing)', lines[i + 1])
        self.assertEqual(labels[i + 2], 'Dithering')
        self.assertIn('floyd, strength 0.50', lines[i + 2])
        self.assertTrue(all(len(ln) <= 80 for ln in lines))

    def test_preview_and_convert_agree(self):
        """The claim the whole app rests on: a preview is the real conversion.

        Same settings into two directories, one the way Preview goes and one
        the way Convert goes; every data file must come out byte-identical.
        """
        s = Settings(input=self.sample, resize='160x120', dither='bayer4')
        a = runner.run_blocking(s, out=self.out, name=runner.PREVIEW_NAME)
        other = tempfile.mkdtemp(prefix='palgui-e2e2-')
        try:
            b = runner.run_blocking(s, out=other, name='real')
            self.assertEqual(a['output_colours'], b['output_colours'])
            pa, pb = (runner.output_paths(a, self.out),
                      runner.output_paths(b, other))
            for key in ('raw', 'map', 'palettes_combined'):
                with open(pa[key], 'rb') as f:
                    ba = f.read()
                with open(pb[key], 'rb') as f:
                    bb = f.read()
                self.assertEqual(ba, bb, '%s differs' % key)
        finally:
            shutil.rmtree(other, ignore_errors=True)


class TestImagesLst(unittest.TestCase):
    """imageslst - where an IMAGES.LST description comes from, and the bytes.

    gather.py is the only writer now (File > Build images.lst is gone), so
    these test the pieces it calls; TestGather covers the whole trip.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='palgui-lst-')

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _touch(self, name, data=b''):
        path = os.path.join(self.dir, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as f:
            f.write(data)
        return path

    @staticmethod
    def _nfo(input_name, description=None):
        """An .NFO like palettize4's: banner, Input, then (0.19+) a
        Description row wrapped onto continuation records."""
        lines = [('=' * 31 + 'palettize_4 report' + '=' * 31),
                 '%-21s: %s' % ('Input', input_name)]
        if description is not None:
            parts = description.split('|')
            lines.append('%-21s: %s' % ('Description', parts[0]))
            lines += [' ' * 23 + p for p in parts[1:]]
            lines.append('%-21s: %s' % ('Dimensions', '320 x 240'))
        out = bytearray()
        for line in lines:
            for ch in line[:80].ljust(80):
                out.append(ord(ch) & 0xFF)
                out.append(0x07)
        out.extend(b'\x00' * 160)
        return bytes(out)

    def _desc(self, name):
        return imageslst._description(os.path.join(self.dir, name))

    def test_nfo_input_then_report_then_stem(self):
        self._touch('IMG1.nfo', self._nfo('sunset_beach.png'))
        self._touch('IMG3_report.txt',
                    ('banner\n%-21s: dragon_lores.bmp\n'
                     % 'Input').encode('latin-1'))
        self.assertEqual(self._desc('IMG1.v1k'), 'sunset_beach')
        self.assertEqual(self._desc('IMG3.v1k'), 'dragon_lores')
        self.assertEqual(self._desc('IMG2.v1k'), 'IMG2')

    def test_build_rows_is_9b_terminated_keyed_records(self):
        data = imageslst.build_rows([(imageslst.key_for('img1'), 'b'),
                                     (imageslst.key_for('img0'), 'a' * 90)])
        recs = data.split(bytes([imageslst.EOL]))
        self.assertEqual(recs[-1], b'')
        self.assertEqual(recs[0], b'IMG0    ' + b'a' * imageslst.NAME_CAP)
        self.assertEqual(recs[1], b'IMG1    b')

    def test_stats_description_wins_over_everything(self):
        self._touch('IMG0.nfo', self._nfo('photo_of_a_cat.jpg', 'From nfo'))
        self._touch('IMG0_stats.json',
                    json.dumps({'description': 'Tabby on a windowsill'})
                    .encode('utf-8'))
        self.assertEqual(self._desc('IMG0.v1k'), 'Tabby on a windowsill')

    def test_nfo_description_row_is_the_fallback_for_lost_stats(self):
        """A staged .V1K/.NFO pair has no _stats.json beside it."""
        self._touch('IMG0.nfo', self._nfo('cat.jpg',
                                          'Tabby on a|windowsill at dusk'))
        self.assertEqual(self._desc('IMG0.v1k'),
                         'Tabby on a windowsill at dusk')

    def test_fallback_drops_extension_and_trailing_period(self):
        self._touch('IMG0.nfo', self._nfo('my.photo.png'))
        self._touch('IMG1.nfo', self._nfo('odd name.'))
        self._touch('IMG2_stats.json', b'{"description": ""}')
        self._touch('IMG2.nfo', self._nfo('beach.jpg'))
        self.assertEqual([self._desc('IMG%d.v1k' % i) for i in range(3)],
                         ['my.photo', 'odd name', 'beach'])

    def test_key_matches_the_disk_short_name(self):
        """Spaces dropped and the gap closed; '_' kept - like the disk step."""
        self.assertEqual(imageslst.key_for('Charger 01'), 'CHARGER0')
        self.assertEqual(imageslst.key_for('Chrome_cr'), 'CHROME_C')
        self.assertEqual(imageslst.key_for('FJ_Marceline_300'), 'FJ_MARCE')
        self.assertEqual(imageslst.key_for('img0'), 'IMG0    ')

    def test_a_real_nfo_round_trips_its_description(self):
        """What palettize4 writes is what gather reads back."""
        sample = _sample()
        if not sample:
            self.skipTest('no sample image')
        out = os.path.join(self.dir, 'run')
        want = ('A long description that palettize4 has to wrap onto a '
                'second .nfo line')
        stats = runner.run_blocking(Settings(input=sample, description=want),
                                    out=out, name='wrap')
        nfo = os.path.join(out, stats['files']['nfo'])
        self.assertEqual(imageslst._nfo_description(nfo), want)


class TestAtariName(unittest.TestCase):
    """atari_name - the 8-char base every Atari-bound file gets."""

    def test_short_name(self):
        cases = {'Charger 01': 'CHARGER0', 'Chrome_cr': 'CHROME_C',
                 'FJ_Marceline_300': 'FJ_MARCE', '2024 trip': 'I2024TRI',
                 '!!!': 'IMG', 'a.b-c': 'ABC', '_x': '_X', '': 'IMG'}
        for src, want in cases.items():
            got = atari_name.short_name(src)
            self.assertEqual(got, want, src)
            self.assertTrue(atari_name.is_short_name(got), got)

    def test_is_short_name(self):
        self.assertTrue(atari_name.is_short_name('IMG0'))
        for bad in ('img0', '0IMG', 'TOOLONGNM', 'A-B', ''):
            self.assertFalse(atari_name.is_short_name(bad), bad)

    def test_unique_name(self):
        taken = {'CHARGER0'}
        self.assertEqual(atari_name.unique_name('CHARGER0', taken), 'CHARGE01')
        taken.add('CHARGE01')
        self.assertEqual(atari_name.unique_name('CHARGER0', taken), 'CHARGE02')
        self.assertEqual(atari_name.unique_name('IMG', {'IMG'}), 'IMG01')
        self.assertEqual(atari_name.unique_name('NEW', taken), 'NEW')


class TestGather(unittest.TestCase):
    """gather.plan / run - the Atari staging folder and its images.lst."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix='palgui-gather-')
        self.out = os.path.join(self.root, 'stage')

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def _touch(self, rel, data=b''):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as f:
            f.write(data)
        return path

    def _v1k(self, rel, fill=0):
        return self._touch(rel, bytes([fill]) * gather.V1K_LEN)

    def test_run_renames_dedupes_and_writes_the_manifest(self):
        self._v1k('a/IMG0.v1k')
        self._touch('a/IMG0.nfo', TestImagesLst._nfo('photo_of_a_cat.jpg'))
        self._v1k('b/Charger 01.v1k', 1)                  # legacy long name
        self._touch('b/Charger 01.nfo', TestImagesLst._nfo('Charger 01.jpg'))
        self._v1k('c/deep/Charger 02.V1K', 2)             # collides, no .nfo
        self._touch('c/deep/Charger 02_stats.json',        # not copied, but read
                    b'{"description": "Red Charger, side view"}')
        self._touch('d/short.v1k', b'x')                  # wrong size
        self._v1k('e/img0.v1k')                           # same bytes as IMG0

        items, manifest = gather.run(self.root, self.out)
        ok = {i.name: i for i in items if not i.problem}
        self.assertEqual(sorted(ok), ['CHARGE01', 'CHARGER0', 'IMG0'])
        self.assertFalse(ok['IMG0'].renamed)
        self.assertTrue(ok['CHARGER0'].renamed)
        self.assertEqual([i.v1k for i in items if i.problem],
                         [os.path.join(self.root, 'd', 'short.v1k'),
                          os.path.join(self.root, 'e', 'img0.v1k')])
        self.assertEqual(items[-1].problem, 'duplicate of IMG0')

        listing = sorted(os.listdir(self.out))
        self.assertEqual(listing, ['CHARGE01.v1k', 'CHARGER0.nfo',
                                   'CHARGER0.v1k', 'IMG0.nfo', 'IMG0.v1k',
                                   'images.lst'])
        with open(manifest, 'rb') as f:
            recs = f.read().split(bytes([imageslst.EOL]))[:-1]
        self.assertEqual(recs, [b'CHARGE01Red Charger, side view',
                                b'CHARGER0Charger 01',
                                b'IMG0    photo_of_a_cat'])

    def test_output_inside_root_is_not_regathered(self):
        self._v1k('img0.v1k')
        gather.run(self.root, self.out)
        items, _ = gather.run(self.root, self.out)
        self.assertEqual([i.name for i in items], ['IMG0'])
        self.assertFalse(items[0].renamed)              # case is not a rename

    def test_plan_writes_nothing(self):
        self._v1k('IMG0.v1k')
        gather.plan(self.root, self.out)
        self.assertFalse(os.path.exists(self.out))


class TestConversionRecord(unittest.TestCase):
    """0.19: a real conversion keeps its recipe, and the recipe comes back.

    Before this a Convert left only palettize4's _report.txt - the Result tab,
    the `run with` line and the settings reached disk for previews only.
    """

    def setUp(self):
        self.sample = _sample()
        if not self.sample:
            self.skipTest('no sample image in %s' % CONVERTOR)
        self.out = tempfile.mkdtemp(prefix='palgui-rec-')

    def tearDown(self):
        shutil.rmtree(self.out, ignore_errors=True)

    def _convert(self, **kw):
        kw.setdefault('resize', '160x120')
        q = jobs.Queue()
        job = q.add(Settings(input=self.sample, out=self.out, **kw))
        self.assertEqual(jobs.run_queue(q), (1, 0, 1))
        folder = runner.resolve(runner.job_dir(job.settings))
        return job, folder

    def test_convert_writes_a_summary_that_restores_every_setting(self):
        job, folder = self._convert(dither='blue', color_bias=0.4,
                                    coherence=0.5,
                                    description='Plasma, for the record')
        path = os.path.join(folder, job.stats['name'] +
                            snapshot.SUMMARY_SUFFIX)
        self.assertTrue(os.path.isfile(path))
        with open(path) as fh:
            text = fh.read()
        self.assertIn('run with', text)
        self.assertIn('palettize4 report', text)       # the Report tab
        self.assertIn('[accuracy vs ideal]', text)     # the Result tab
        self.assertIn('Plasma, for the record', text)
        self.assertIn('convertor  : %s' % palgui.__version__, text)
        s, how = recover.settings_from_file(path)
        self.assertTrue(how.startswith('exact'))
        self.assertEqual(s.to_argv(), job.settings.to_argv())

    def test_report_and_stats_carry_description_version_and_args(self):
        job, folder = self._convert(description='Seen on the status line')
        paths = runner.output_paths(job.stats, folder)
        with open(paths['report']) as fh:
            lines = fh.read().splitlines()
        labels = [ln[:21].strip() for ln in lines]
        self.assertEqual(labels[1:3], ['Input', 'Description'])
        self.assertIn('Seen on the status line', lines[2])
        i = labels.index('Strategy')
        self.assertEqual(labels[i - 1], 'Convertor Version')
        self.assertIn(palgui.__version__, lines[i - 1])
        self.assertEqual(job.stats['convertor_version'], palgui.__version__)
        args = job.stats['args']
        self.assertEqual(args['description'], 'Seen on the status line')
        self.assertNotIn('json', args)
        s, how = recover.settings_from_file(paths['stats'])
        self.assertTrue(how.startswith('exact'))
        self.assertEqual(s.to_argv(out='x', name='y'),
                         job.settings.to_argv(out='x', name='y'))


class TestRecover(unittest.TestCase):
    """recover.plan - one output folder per image, back to a queue.

    Each case makes a real conversion and then strips it back to what a
    pre-0.19 folder held: no _summary.txt, no "args", no dither in the stats.
    """

    def setUp(self):
        self.sample = _sample()
        if not self.sample:
            self.skipTest('no sample image in %s' % CONVERTOR)
        self.root = tempfile.mkdtemp(prefix='palgui-recover-')
        self.out = os.path.join(self.root, 'out')

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def _old_conversion(self, name, **kw):
        kw.setdefault('resize', '160x120')
        s = Settings(input=self.sample, out=self.out, name=name, **kw)
        folder = runner.resolve(runner.job_dir(s))
        stats = runner.run_blocking(s, out=folder, name=name)
        base = os.path.join(folder, stats['name'])
        for key in ('args', 'dither', 'dither_strength', 'dither_applied',
                    'convertor_version'):
            stats.pop(key, None)
        with open(base + '_stats.json', 'w') as fh:
            json.dump(stats, fh)
        os.remove(base + '_report.txt')         # the oldest had none
        return s, folder, base

    def test_unrecorded_dither_is_verified_by_trial(self):
        self._old_conversion('BLUEONE', dither='blue')
        rec, = recover.plan(self.out)
        self.assertEqual(rec.confidence, recover.VERIFIED)
        self.assertEqual(rec.settings.dither, 'blue')
        self.assertEqual(rec.settings.name, 'BLUEONE')
        self.assertEqual(rec.settings.out, os.path.abspath(self.out))
        self.assertTrue(rec.ok())

    def test_a_matching_preview_is_the_exact_recipe(self):
        # 320x240: a snapshot is always that size, so only a full-size
        # conversion can match one pixel for pixel.
        s, folder, base = self._old_conversion('SNAP', dither='bayer4',
                                               coherence=0.5,
                                               resize='320x240')
        where = os.path.join(folder, snapshot.DIRNAME)
        decoy = s.clone()
        decoy.dither = 'none'
        _write_png(os.path.join(self.root, 'decoy.png'), (320, 240))
        snapshot.save(where, os.path.join(self.root, 'decoy.png'), 'x',
                      data={'settings': decoy.to_dict()})
        snapshot.save(where, base + '_preview.png', 'x',
                      data={'settings': s.to_dict()})
        rec, = recover.plan(self.out, trial=False)
        self.assertEqual(rec.confidence, recover.PREVIEW_MATCH)
        self.assertEqual(rec.source, 'previews/Preview_02.txt')
        self.assertEqual(rec.settings.dither, 'bayer4')
        self.assertEqual(float(rec.settings.coherence), 0.5)

    def test_a_moved_source_is_found_by_filename(self):
        _s, folder, base = self._old_conversion('MOVED')
        with open(base + '_stats.json') as fh:
            stats = json.load(fh)
        stats['input'] = os.path.join(self.root, 'gone',
                                      os.path.basename(self.sample))
        with open(base + '_stats.json', 'w') as fh:
            json.dump(stats, fh)
        rec, = recover.plan(self.out, trial=False)
        self.assertFalse(rec.ok())
        self.assertEqual(len(recover.build_queue([rec])), 0)
        moved = os.path.join(self.root, 'sources', 'deep')
        os.makedirs(moved)
        shutil.copy(self.sample, moved)
        rec, = recover.plan(self.out, [os.path.join(self.root, 'sources')],
                            trial=False)
        self.assertTrue(rec.ok())
        self.assertEqual(os.path.dirname(rec.settings.input), moved)

    def test_old_named_files_are_listed_not_touched(self):
        _s, folder, _base = self._old_conversion('KEEP')
        stale = os.path.join(folder, 'Keep Me Old.v1k')
        with open(stale, 'wb') as fh:
            fh.write(b'x')
        rec, = recover.plan(self.out, trial=False)
        self.assertEqual(rec.orphans, ['Keep Me Old.v1k'])
        self.assertTrue(os.path.isfile(stale))
        self.assertIn('Keep Me Old.v1k', recover.report_text([rec]))

    def test_a_folder_without_stats_is_skipped(self):
        os.makedirs(os.path.join(self.out, 'Samples'))
        rec, = recover.plan(self.out)
        self.assertIsNone(rec.settings)
        self.assertEqual(len(recover.build_queue([rec])), 0)


class TestDeletePreviews(unittest.TestCase):
    """review.delete - the half of Delete marked... that touches disk."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='palgui-del-')

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_delete_removes_both_files_and_numbering_does_not_reuse(self):
        png = os.path.join(self.dir, 'src.png')
        _write_png(png, (320, 240))
        for _ in range(3):
            snapshot.save(self.dir, png, 'x')
        shots = review.shots(self.dir)
        removed, errors = review.delete([shots[2]])
        self.assertEqual(errors, [])
        self.assertEqual(sorted(os.path.basename(p) for p in removed),
                         ['Preview_03.png', 'Preview_03.txt'])
        self.assertEqual([s.index for s in review.shots(self.dir)], [1, 2])
        review.delete([review.shots(self.dir)[0]])
        self.assertEqual(snapshot.next_index(self.dir), 3)


class TestDescribe(unittest.TestCase):
    """describe.py - a new description on a finished conversion, four files
    kept in step, the picture untouched."""

    LONG = ('A 1970 Dodge Charger at a car show, long enough that the report '
            'wraps it')

    def setUp(self):
        self.sample = _sample()
        if not self.sample:
            self.skipTest('no sample image in %s' % CONVERTOR)
        self.out = tempfile.mkdtemp(prefix='palgui-desc-')

    def tearDown(self):
        shutil.rmtree(self.out, ignore_errors=True)

    def _convert(self, name, **kw):
        q = jobs.Queue()
        job = q.add(Settings(input=self.sample, out=self.out, name=name,
                             resize='160x120', **kw))
        self.assertEqual(jobs.run_queue(q), (1, 0, 1))
        folder = runner.resolve(runner.job_dir(job.settings))
        return folder, os.path.join(folder, job.stats['name'])

    @staticmethod
    def _bytes(path):
        with open(path, 'rb') as fh:
            return fh.read()

    def test_all_four_files_match_a_fresh_conversion(self):
        """Edited after the fact == converted with --description, in every
        row that carries it; the picture files do not change at all."""
        folder, base = self._convert('EDITED')
        _fresh_folder, fresh = self._convert('FRESH', description=self.LONG)
        pictures = dict((ext, self._bytes(base + ext))
                        for ext in ('.raw', '.map', '.pal', '_preview.png'))
        with open(base + snapshot.SUMMARY_SUFFIX) as fh:
            when = [ln for ln in fh.read().splitlines()
                    if ln.startswith('when')]

        old, new, files = describe.set_description(folder, self.LONG)
        self.assertEqual(new, self.LONG)
        self.assertEqual(len(files), 4)

        with open(base + '_report.txt') as a, open(fresh + '_report.txt') as b:
            got, want = a.read().splitlines(), b.read().splitlines()
        self.assertEqual(got[1:4], want[1:4])        # Input + 2 Description
        self.assertEqual(len(got), len(want))
        self.assertEqual(imageslst._nfo_description(base + '.nfo'), self.LONG)
        with open(base + '_report.txt') as fh:
            self.assertEqual(self._bytes(base + '.nfo'),
                             describe.nfo_encode.encode(fh.read()))
        with open(base + '_stats.json') as fh:
            stats = json.load(fh)
        self.assertEqual(stats['description'], self.LONG)
        self.assertEqual(stats['args']['description'], self.LONG)
        s, _how = recover.settings_from_file(base + snapshot.SUMMARY_SUFFIX)
        self.assertEqual(s.description, self.LONG)
        with open(base + snapshot.SUMMARY_SUFFIX) as fh:
            self.assertEqual([ln for ln in fh.read().splitlines()
                              if ln.startswith('when')], when)
        for ext, data in pictures.items():
            self.assertEqual(self._bytes(base + ext), data, ext)

        # ... and it is what Gather puts in IMAGES.LST (gather.plan asks
        # imageslst._description; a 160x120 run has no .v1k to stage).
        self.assertEqual(imageslst._description(base + '.v1k'), self.LONG)

    def test_list_round_trip_and_refusals(self):
        folder, _base = self._convert('LISTED')
        lst = os.path.join(self.out, 'd.txt')
        self.assertEqual(describe.export_list(self.out, lst), 1)
        rows = describe.apply_list(self.out, lst)
        self.assertEqual(rows[0][3], [])            # unchanged -> no files
        with open(lst, 'a') as fh:
            fh.write('LISTED = Tabby on a windowsill\n')
        (_n, old, new, files), = describe.apply_list(self.out, lst)[-1:]
        self.assertTrue(files)
        self.assertEqual(describe.current(folder), old)   # dry run by default
        describe.apply_list(self.out, lst, dry_run=False)
        self.assertEqual(describe.current(folder), 'Tabby on a windowsill')
        # blank resets to the filename default
        describe.set_description(folder, '')
        self.assertEqual(describe.current(folder),
                         os.path.splitext(os.path.basename(self.sample))[0])
        for bad in ('café', 'x' * 76):
            with self.assertRaises(describe.DescribeError):
                describe.set_description(folder, bad)


if __name__ == '__main__':
    unittest.main()
