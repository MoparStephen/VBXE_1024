"""python -m palgui [image] - launch VBXE PAL Studio, the palettize4 front end.

USE THE LAUNCHER unless you have a reason not to:

    run_palgui.cmd            (Windows - works from anywhere, including Explorer)
    ./run_palgui.sh           (elsewhere)

Doing it by hand needs TWO things to be true at once, and neither announces
itself when it is wrong:

    cd C:\\Users\\Stephen\\source\\Claude\\VBXE_1024\\Convertor   <- the CONVERTOR dir
    ..\\.venv\\Scripts\\python -m palgui                          <- the VENV's python

Standing in .venv\\Scripts does not put it on PATH - PowerShell does not search
the current directory - so `python` there is still the system install, which has
no PySide6.  And `-m palgui` imports `palgui` by name, which only resolves when
the Convertor directory is the working directory; get that wrong and it fails
inside Python's import machinery before this file runs at all, with

    No module named 'palgui'

THE VENV NEEDS THE CONVERTER'S DEPENDENCIES TOO, not just Qt.  Preview shells
out to palettize4.py under sys.executable - the same interpreter running the
GUI - so numpy, Pillow and scipy have to be in there beside PySide6.  Miss
scipy and everything works until the first --dither, which then fails with a
message about scipy that looks like a bug in this program and is not.

The headless half needs none of this: `python -m palgui.runner` is not a thing,
but settings/runner/presets/jobs import on the system Python with nothing
installed, which is what tools/tests drive them with.
"""

import os
import sys

CONVERTOR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(CONVERTOR)


def _venv_python():
    for rel in (r'.venv\Scripts\python.exe', '.venv/bin/python'):
        p = os.path.join(REPO, rel)
        if os.path.exists(p):
            return p
    return None


#: The output tree a real run would use.  The selftest must never touch it.
REAL_OUT = os.path.join(CONVERTOR, 'out')


def _listing(directory):
    """Every path under `directory`, or [] if it is not there."""
    out = []
    for root, dirs, files in os.walk(directory):
        for name in list(dirs) + files:
            out.append(os.path.join(root, name))
    return out


def _selftest(argv):
    """Build the whole window offscreen, paint every view, and exit.

    THE POINT IS TO ANSWER "IS MY INSTALL RIGHT" WITHOUT A DISPLAY, and to fail
    loudly rather than opening a window that turns out to be empty.  It builds
    every pane, runs one real conversion through the blocking runner - which is
    the only way to know that numpy, Pillow and (with --dither) scipy are all
    where they need to be - and pushes the result through the panes the GUI
    would.  A wrong venv, a missing palettize4.py or an unreadable sample all
    surface here rather than on first use.
    """
    os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
    import shutil
    import tempfile
    import time

    from PySide6.QtCore import Qt
    from PySide6.QtGui import QImage
    from PySide6.QtWidgets import QApplication

    from . import __version__, jobs, presets, review, runner, summary
    from .settings import Settings
    from .ui.main import MainWindow, dark_palette

    app = QApplication(list(argv[:1]))
    dark_palette(app)

    # A sample that is certainly there, and certainly over the colour budget,
    # so the run exercises the reduce-and-dither path rather than skipping it.
    # Convertor/ first, then the repo's "Images To Convert" folder, which is
    # where the sources live now.
    sample = argv[1] if len(argv) > 1 else os.path.join(CONVERTOR, 'plasma.bmp')
    if len(argv) <= 1 and not os.path.isfile(sample):
        sample = os.path.join(os.path.dirname(CONVERTOR), 'Images To Convert',
                              'plasma.bmp')
    if not os.path.isfile(sample):
        sys.exit('selftest FAILED: no sample image at %s' % sample)

    # Captured before anything runs; compared again at the very end.
    real_out_before = sorted(_listing(REAL_OUT))

    w = MainWindow(sample)
    w.resize(1500, 940)
    w.show()
    app.processEvents()

    print('  %-16s ok  %s' % ('converter', runner.script_path()))
    print('  %-16s ok  %d saved' % ('presets', len(presets.names())))

    # --- one real conversion, blocking, with a dither ----------------------
    out = tempfile.mkdtemp(prefix='palgui-selftest-')
    s = Settings(input=sample, resize='320x240', dither='blue')
    try:
        stats = runner.run_blocking(s, out=out, name='preview')
    except runner.RunError as exc:
        sys.exit('selftest FAILED: %s\n%s' % (exc.message, exc.detail))
    print('  %-16s ok  %s' % ('conversion', runner.headline(s, stats)))

    paths = runner.output_paths(stats, out)
    img = QImage(paths['preview'])
    if img.isNull():
        sys.exit('selftest FAILED: the preview PNG would not load')
    w.compare.set_result(img)
    w.palettes.load(paths['palettes'], stats, s.reserve0)
    w.stats.set_stats(s, stats, command=s.command_line())
    w.joblist.queue.add(s)
    w.joblist.refresh()
    app.processEvents()

    # --- the accuracy block, in the sidecar AND in the pane ------------------
    # A NUMBER THAT ONLY REACHES THE JSON IS NOT DELIVERED.  The sidecar half
    # is covered by the unit tests; what can only be checked with a window up
    # is that summary.rows() actually rendered into the table.
    acc = summary.accuracy(stats)
    if not acc:
        sys.exit('selftest FAILED: the run wrote no ideal_vs_output block')
    if (acc['identical_pixels'] + stats['recoloured_pixels']
            != acc['compared_pixels']):
        sys.exit('selftest FAILED: identical + recoloured != compared px')
    shown = [w.stats.table.item(r, 0).text()
             for r in range(w.stats.table.rowCount())
             if w.stats.table.item(r, 0)]
    for key in ('PSNR', 'cells damaged', 'cell seams'):
        if key not in shown:
            sys.exit('selftest FAILED: the Result tab has no %r row' % key)
    seam = acc['seam_index']
    print('  %-16s ok  %s, %.1f%% of cells damaged, seams %s'
          % ('accuracy', summary.psnr_text(stats), acc['cells_damaged_pct'],
             '%.2fx' % seam if seam else 'n/a'))

    # SIDE BY SIDE FOR THE GRABS, so both image views are actually up.  In flip
    # mode one of them is hidden, and grabbing a hidden widget yields its
    # minimum size rather than a painted pane - a pass that proves nothing.
    w.compare.set_mode('side')
    app.processEvents()

    for widget, label in ((w.options, 'options'),
                          (w.compare, 'compare pane'),
                          (w.compare.source, 'source view'),
                          (w.compare.result, 'result view'),
                          (w.stats, 'result stats'),
                          (w.palettes, 'palette sheet'),
                          (w.joblist, 'queue')):
        pm = widget.grab()
        if pm.isNull():
            sys.exit('selftest FAILED: %s painted nothing' % label)
        print('  %-16s ok  %dx%d' % (label, pm.width(), pm.height()))

    # THE FLIP AND THE SIDE-BY-SIDE, CHECKED ON VISIBILITY rather than on the
    # widget tree.  Holding two widgets is not the same as showing them: an
    # earlier version moved the views between a splitter and a stack, and the
    # stack's own hide() survived the move, so side-by-side came up as a
    # correctly-populated splitter with both children invisible - an empty
    # pane under a caption saying "source left, converted right".  A count of
    # children would have passed that happily, which is why this asserts what
    # is on screen.
    w.compare.set_mode('flip')
    app.processEvents()
    for want_source in (True, False):
        w.compare.show_side(want_source)
        app.processEvents()
        want = w.compare.source if want_source else w.compare.result
        other = w.compare.result if want_source else w.compare.source
        if w.compare.showing() is not want or not want.isVisible():
            sys.exit('selftest FAILED: the flip did not reach the %s'
                     % want.label.lower())
        if other.isVisible():
            sys.exit('selftest FAILED: the flip left both views on screen')
    print('  %-16s ok  both sides' % 'flip')

    w.compare.set_mode('side')
    app.processEvents()
    if w.compare.split.count() != 2:
        sys.exit('selftest FAILED: side-by-side lost a view')
    for v in (w.compare.source, w.compare.result):
        if not v.isVisible():
            sys.exit('selftest FAILED: side-by-side holds %s but does not '
                     'show it' % v.label.lower())
        if v.grab().isNull():
            sys.exit('selftest FAILED: %s painted nothing side by side'
                     % v.label.lower())
    print('  %-16s ok  2 views, both visible' % 'side by side')

    # AND BACK, because the mode is a toggle in the toolbar and returning to
    # flip has to leave exactly one view up rather than two.
    w.compare.set_mode('flip')
    app.processEvents()
    if w.compare.source.isVisible() and w.compare.result.isVisible():
        sys.exit('selftest FAILED: back in flip mode with both views showing')
    print('  %-16s ok  one view' % 'back to flip')

    # THE FIXED MODEL.  cell / palettes / slots / resize are what the viewer
    # can display, not preferences, so the panel states them and offers no
    # control at all - and to_settings has to assert them rather than read
    # them.  Nothing in the headless tests can see this: Settings will happily
    # carry cell=16, and it is the PANEL's job never to produce one.
    from .settings import (CELL_FIXED, PALETTES_FIXED, RESIZE_FIXED,
                           SLOTS_FIXED, Settings)
    for name in ('cell', 'palettes', 'slots'):
        box = getattr(w.options, name, None)
        if box is not None and hasattr(box, 'value'):
            sys.exit('selftest FAILED: %s is still an editable control; the '
                     'viewer cannot use anything but the fixed model' % name)
    # KEEP THE INPUT SET.  from_settings with a blank input is a real edit as
    # far as the window is concerned - it clears the source pane - so probing
    # with a bare Settings() would leave the zoom checks below looking at an
    # empty view and blaming the zoom code for it.
    for preset in (Settings(input=sample),
                   Settings(input=sample, cell=16, palettes=2, slots=64,
                            resize='')):
        w.options.from_settings(preset)
        got = w.options.to_settings()
        want = (CELL_FIXED, PALETTES_FIXED, SLOTS_FIXED, RESIZE_FIXED)
        if (got.cell, got.palettes, got.slots, got.resize) != want:
            sys.exit('selftest FAILED: the panel produced %d-px cells, %d '
                     'palettes, %d slots at %r - a preset carrying an old '
                     'model must not survive into a run'
                     % (got.cell, got.palettes, got.slots, got.resize))
    w.options.from_settings(Settings(input=sample))
    print('  %-16s ok  %s, %d-px cells, %d x %d'
          % ('fixed model', RESIZE_FIXED, CELL_FIXED, PALETTES_FIXED,
             SLOTS_FIXED))

    # THE ZOOM BOX MUST AGREE WITH THE VIEW.  It used to be write-only - the
    # user set it and nothing ever set it back - so a wheel-zoom, or a drag at
    # fit silently promoting to 1:1, left it stating a zoom that was no longer
    # in force, and picking `fit` while it already said `fit` did nothing.
    from .ui.imageview import FIT
    w.compare.set_mode('flip')
    w.compare.fit()
    app.processEvents()
    if w.compare.source.zoom != FIT or w.zoom.currentData() != FIT:
        sys.exit('selftest FAILED: the view did not start at fit')
    if w.compare.source.pannable():
        sys.exit('selftest FAILED: the view claims it can pan at fit, where '
                 'the whole image is already on screen')
    w.compare.set_zoom(4)
    app.processEvents()
    if w.zoom.currentData() != 4:
        sys.exit('selftest FAILED: zoomed to 4x but the box says %r'
                 % w.zoom.currentText())
    if not w.compare.source.pannable():
        sys.exit('selftest FAILED: the view will not pan at 4x')
    w.compare.fit()
    app.processEvents()
    if w.zoom.currentData() != FIT:
        sys.exit('selftest FAILED: back at fit but the box says %r'
                 % w.zoom.currentText())
    print('  %-16s ok  box follows the view' % 'zoom readout')

    # PANELS ARE CLOSABLE, SO EVERY ONE OF THEM NEEDS A WAY BACK.  Checked by
    # actually hiding all four and bringing them back, because an action that
    # exists but is wired to the wrong dock looks identical from outside.
    for dock in w._docks():
        if dock.toggleViewAction() is None:
            sys.exit('selftest FAILED: %s has no toggle' % dock.objectName())
        dock.hide()
    app.processEvents()
    if any(d.isVisible() for d in w._docks()):
        sys.exit('selftest FAILED: a panel would not hide')
    for dock in w._docks():
        dock.toggleViewAction().trigger()
    app.processEvents()
    for dock in w._docks():
        if not dock.isVisible():
            sys.exit('selftest FAILED: %s did not come back from its toggle'
                     % dock.objectName())
    for dock in w._docks():
        dock.hide()
    app.processEvents()
    w._reset_panels()
    app.processEvents()
    for dock in w._docks():
        if not dock.isVisible():
            sys.exit('selftest FAILED: Reset panels left %s hidden'
                     % dock.objectName())
    print('  %-16s ok  %d, hide/toggle/reset' % ('panels', len(w._docks())))

    # RESET SETTINGS: the recipe goes back to Settings defaults, the image
    # stays.  Driven through the window, so the button's slot is what's tested.
    before = w.options.to_settings()
    w.options.dither.setCurrentText('blue')
    w.options.seed.setValue(7)
    w._settings_reset()
    after = w.options.to_settings()
    if (after.dither, after.seed) != ('none', 0) or after.input != before.input:
        sys.exit('selftest FAILED: Reset settings gave dither=%r seed=%r input=%r'
                 % (after.dither, after.seed, after.input))
    print('  %-16s ok  recipe to defaults, image kept' % 'reset settings')

    # LAST FOLDERS PERSIST through QSettings.  A throwaway key, removed after,
    # so the check never moves where the user's own dialogs open.
    from PySide6.QtCore import QSettings
    from .ui import lastdir
    probe = tempfile.mkdtemp(prefix='palgui-lastdir-')
    lastdir.remember('selftest', os.path.join(probe, 'x.png'))
    got = lastdir.get('selftest')
    gone = lastdir.get('selftest_missing', 'fallback')
    QSettings(lastdir.ORG, lastdir.APP).remove('last_dir/selftest')
    if os.path.normcase(got) != os.path.normcase(os.path.abspath(probe)) \
            or gone != 'fallback':
        sys.exit('selftest FAILED: last folder came back as %r / %r'
                 % (got, gone))
    print('  %-16s ok  remembered and read back' % 'last folders')

    # THE BUSY CURSOR, CHECKED FOR BALANCE.  setOverrideCursor is a stack, so
    # the failure mode is not "no cursor" but a pointer stuck as an hourglass
    # for the rest of the session - which nothing else here would notice, and
    # which looks like the app has hung when it has not.  Driven twice because
    # a queue calls _set_running once per job and must still push only once.
    if QApplication.overrideCursor() is not None:
        sys.exit('selftest FAILED: an override cursor was set before any run')
    w._set_running(True)
    w._set_running(True)
    if QApplication.overrideCursor() is None:
        sys.exit('selftest FAILED: no busy cursor while a run is going')
    w._set_running(False)
    if QApplication.overrideCursor() is not None:
        sys.exit('selftest FAILED: the busy cursor outlived the run')
    print('  %-16s ok  set and restored' % 'busy cursor')

    # SNAPSHOTS, DRIVEN THROUGH THE REAL SLOT.  _run_finished is the only
    # place that decides whether a preview leaves a file behind, so calling it
    # is the only check that would notice the option being read from the wrong
    # place - or the pair landing next to the conversion instead of under
    # previews/.
    from . import snapshot
    snap_root = tempfile.mkdtemp(prefix='palgui-snap-')
    s2 = Settings(input=sample, out=snap_root, dither='blue')
    where = snapshot.dir_for(snap_root, s2.effective_name())
    # The window writes this preference back to QSettings when it closes, so
    # put it back afterwards: a selftest is a check, not an edit to how the
    # user had the app set up.
    was_wanted = w.options.snapshots_wanted()

    w.options.set_snapshots_wanted(False)
    w._run_finished(s2, w.scratch, runner.PREVIEW_NAME, stats)
    if os.path.isdir(where) and os.listdir(where):
        sys.exit('selftest FAILED: a snapshot was written with the option off')

    # The preview files _run_finished reads live in the scratch directory, so
    # put this run's output there the way a real preview would.
    for src in os.listdir(out):
        shutil.copyfile(os.path.join(out, src),
                        os.path.join(w.scratch, src))
    w.options.set_snapshots_wanted(True)
    for want in (1, 2):
        w._run_finished(s2, w.scratch, runner.PREVIEW_NAME, stats)
        png = os.path.join(where, (snapshot.STEM % want) + '.png')
        txt = os.path.join(where, (snapshot.STEM % want) + '.txt')
        for path in (png, txt):
            if not os.path.isfile(path):
                sys.exit('selftest FAILED: preview %d wrote no %s'
                         % (want, os.path.basename(path)))
        size = snapshot.describe(png)[:2]
        if size != snapshot.SIZE:
            sys.exit('selftest FAILED: the snapshot is %dx%d, not %dx%d'
                     % (size + snapshot.SIZE))
        with open(txt) as fh:
            body = fh.read()
        # The two halves the summary exists to carry: the Result rows and
        # palettize4's own report.
        for phrase in ('verdict', 'colours on screen', 'run with',
                       'palettize4 report'):
            if phrase not in body:
                sys.exit('selftest FAILED: %s is missing from %s'
                         % (phrase, os.path.basename(txt)))
    if os.path.exists(os.path.join(snap_root, s2.effective_name(),
                                   'Preview_01.png')):
        sys.exit('selftest FAILED: the snapshot landed beside the conversion '
                 'instead of under previews/')
    print('  %-16s ok  2 pairs in %s'
          % ('snapshots', os.path.join(s2.effective_name(), 'previews')))

    # --- and straight back in again ------------------------------------------
    # THE PAIR JUST WRITTEN IS THE FIXTURE.  A reader tested only against files
    # a test invented proves the two halves agree with each other, not that
    # either agrees with what the app puts on disk - and the whole point of
    # this feature is reading back what the app wrote an hour ago.
    found = w.review.load(where)
    if found != 2:
        sys.exit('selftest FAILED: read %d snapshots back, expected 2' % found)
    if not w.review.step(1) or w.review.current_row() != 1:
        sys.exit('selftest FAILED: next did not move to the second preview')
    shot = w.review.current()
    if shot.settings is None or shot.settings.dither != s2.dither:
        sys.exit('selftest FAILED: the snapshot did not give back its dither')
    if shot.stats is None:
        sys.exit('selftest FAILED: the snapshot carried no [data] footer')
    if w.options.to_settings().dither != s2.dither:
        sys.exit('selftest FAILED: stepping did not load the options panel')
    if not w.compare.result.has_image():
        sys.exit('selftest FAILED: stepping put no picture in the pane')
    if 'palettize_4 report' not in w.stats.report.toPlainText():
        sys.exit('selftest FAILED: the Report tab did not follow the step')
    if w.stale:
        sys.exit('selftest FAILED: a freshly loaded preview reads as stale')
    print('  %-16s ok  %d read back, %s restored'
          % ('previews', found, shot.label()))
    w.review.clear()

    # --- the whole queue, previewed ------------------------------------------
    # THE MODE THE QUEUE EXISTS FOR ON ONE IMAGE.  Converting these two jobs
    # would write one image's filenames twice and leave the second; previewed,
    # both survive as numbered pairs.
    #
    # PUMPED THROUGH THE REAL EVENT LOOP, not by calling _run_finished by
    # hand.  Landing the jobs manually leaves the worker's QProcess behind and
    # the next start trips over a deleted C++ object - but more to the point,
    # the asynchronous path IS the thing being checked: a batch that only
    # works when something else drives it is not a batch.
    w.options.set_snapshots_wanted(False)
    # CLEARED FIRST.  The queue still holds the row the table screenshot
    # needed, and that job carries the DEFAULT --out - so previewing the queue
    # with it in would write snapshots into the real Convertor/out tree.  A
    # selftest is a check, not an edit to the user's output folder.
    w.queue.clear()
    for dither in ('bayer4', 'blue'):
        job = w.queue.add(Settings(input=sample, resize='160x120',
                                   out=snap_root, dither=dither))
        job.label = dither
    if len(w.queue.collisions()) != 1:
        sys.exit('selftest FAILED: two jobs on one image should collide')
    pairs_before = len(review.shots(where))
    w._batch_start(preview=True)
    if not w.options.snapshots_wanted():
        sys.exit('selftest FAILED: Preview all did not switch snapshots on')
    deadline = time.time() + 180
    while w._batch is not None and time.time() < deadline:
        app.processEvents()
    if w._batch is not None:
        sys.exit('selftest FAILED: the previewed queue never finished')
    _d, failed, _t = w.queue.counts()
    if failed:
        sys.exit('selftest FAILED: %d queued previews failed: %s'
                 % (failed, w.queue[0].error or w.queue[-1].error))
    if len(review.shots(where)) != pairs_before + 2:
        sys.exit('selftest FAILED: a previewed queue left %d new pairs, not 2'
                 % (len(review.shots(where)) - pairs_before))
    if w.review.count() != pairs_before + 2:
        sys.exit('selftest FAILED: the Previews pane did not open on them')
    # EACH ROW MUST SHOW ITS OWN PICTURE.  A previewed job ran in the scratch
    # directory, which the next job overwrote - so following its stats would
    # give every row the last job's image.
    shots = {}
    for row in range(len(w.queue)):
        job = w.queue[row]
        if not job.snapshot:
            sys.exit('selftest FAILED: previewed job %d kept no snapshot' % row)
        shots[job.snapshot[0]] = job.label
        w.joblist.table.selectRow(row)
        app.processEvents()
        if not w.compare.result.has_image():
            sys.exit('selftest FAILED: queue row %d showed no picture' % row)
    if len(shots) != len(w.queue):
        sys.exit('selftest FAILED: two queued previews share one snapshot')
    print('  %-16s ok  %d jobs, one pair each, rows keep their own picture'
          % ('preview queue', len(w.queue)))

    # A queue is a plan you can retarget and re-run.
    if w.queue.retarget(sample) != len(w.queue) or w.queue[0].settings.name:
        sys.exit('selftest FAILED: retarget did not clear the output names')
    if w.queue[0].state != jobs.PENDING:
        sys.exit('selftest FAILED: retarget kept a result from another image')
    qfile = os.path.join(snap_root, 'queue.json')
    w.queue.save(qfile)
    if len(jobs.Queue.load(qfile)) != len(w.queue):
        sys.exit('selftest FAILED: the queue did not survive a save and load')
    print('  %-16s ok  %d jobs retargeted, saved and loaded'
          % ('queue file', len(w.queue)))
    w.queue.clear()
    w.joblist.refresh()
    w.options.set_snapshots_wanted(was_wanted)

    # Marking a preview arms Delete marked... - the delete itself asks Yes /
    # No, so it is left to the headless review.delete test.
    if w.review.b_delete.isEnabled():
        sys.exit('selftest FAILED: Delete marked... armed with nothing ticked')
    w.review.table.item(0, 0).setCheckState(Qt.Checked)
    if not w.review.b_delete.isEnabled() or len(w.review.marked()) != 1:
        sys.exit('selftest FAILED: ticking a preview did not mark it')
    w.review.table.item(0, 0).setCheckState(Qt.Unchecked)
    # After a delete the pane reloads with the LAST row selected.
    w.review.load(w.review.directory(), at_end=True)
    if w.review.current_row() != w.review.count() - 1:
        sys.exit('selftest FAILED: reload after delete selected row %d, not '
                 'the last (%d)' % (w.review.current_row(),
                                    w.review.count() - 1))
    w.review.load(w.review.directory())
    print('  %-16s ok  tick arms Delete marked..., reload ends on the last'
          % 'delete previews')

    # File > Edit descriptions: names are skipped by the keyboard, and the
    # editor refuses what Save would (over 75 chars, non-ASCII).
    from PySide6.QtGui import QValidator
    from PySide6.QtTest import QTest
    from PySide6.QtWidgets import QStyleOptionViewItem
    dlg, t = w._descriptions_dialog('x', ['a/ONE', 'a/TWO'], ['one', 'two'])
    dlg.show()
    app.processEvents()
    if t.item(0, 0).flags() & Qt.ItemIsEnabled:
        sys.exit('selftest FAILED: description dialog names are enabled')
    t.setFocus()
    QTest.keyClick(t, Qt.Key_Left)
    QTest.keyClick(t, Qt.Key_Down)
    if (t.currentRow(), t.currentColumn()) != (1, 1):
        sys.exit('selftest FAILED: keyboard reached the name column (%d, %d)'
                 % (t.currentRow(), t.currentColumn()))
    ed = t.itemDelegateForColumn(1).createEditor(
        t.viewport(), QStyleOptionViewItem(), t.model().index(0, 1))
    if ed.maxLength() != 75:
        sys.exit('selftest FAILED: description editor allows %d chars'
                 % ed.maxLength())
    if ed.validator().validate('café', 0)[0] != QValidator.Invalid:
        sys.exit('selftest FAILED: description editor accepts non-ASCII')
    dlg.reject()
    print('  %-16s ok  names skipped, 75-char printable-ASCII editor'
          % 'descriptions')

    # File > Close image: the picture goes, the settings stay.
    if __version__ not in w.windowTitle():
        sys.exit('selftest FAILED: the title bar does not carry v%s'
                 % __version__)
    w.options.from_settings(Settings(input=sample, dither='blue',
                                     description='about to close'))
    app.processEvents()
    w._close_image()
    app.processEvents()
    after = w.options.to_settings()
    if after.input or after.description or after.dither != 'blue':
        sys.exit('selftest FAILED: Close image kept the image or lost a '
                 'setting (%r)' % after)
    if w.compare.result.has_image() or w.review.count():
        sys.exit('selftest FAILED: Close image left a picture on screen')
    print('  %-16s ok  image cleared, settings kept, title v%s'
          % ('close image', __version__))

    # THE GUARD THAT SHOULD HAVE BEEN HERE ALL ALONG.  Every run above is
    # supposed to go to a temporary directory, and the one time that stopped
    # being true it was a default --out on a job nobody remembered was in the
    # queue.  Comparing the real output tree before and after costs nothing
    # and turns a silent mess into a failure.
    if sorted(_listing(REAL_OUT)) != real_out_before:
        sys.exit('selftest FAILED: it wrote into %s - it must only ever use '
                 'temporary directories' % REAL_OUT)

    shutil.rmtree(snap_root, ignore_errors=True)

    shutil.rmtree(out, ignore_errors=True)
    w.close()
    print()
    print('selftest OK - VBXE PAL Studio is installed correctly.')
    return 0


def main():
    if '--selftest' in sys.argv:
        return _selftest([a for a in sys.argv if a != '--selftest'])
    try:
        from .ui.main import run
    except ImportError as exc:
        if 'PySide6' not in str(exc) and 'shiboken' not in str(exc):
            raise
        venv = _venv_python()
        me = os.path.normpath(sys.executable)
        lines = ['', 'PySide6 is not available in this interpreter.',
                 '    running: %s' % me, '    because: %s' % exc, '']
        if venv and os.path.normpath(venv) != me:
            lines += ['The repo venv has it.  Use the launcher:', '',
                      '    %s' % os.path.join(REPO, 'run_palgui.cmd'
                                              if os.name == 'nt'
                                              else 'run_palgui.sh'),
                      '', 'or, from the Convertor directory:', '',
                      '    %s -m palgui' % os.path.relpath(venv, CONVERTOR)]
        else:
            lines += ['Create the venv:', '',
                      '    python -m venv .venv',
                      '    .venv%spython -m pip install PySide6 Pillow '
                      'numpy scipy'
                      % (r'\Scripts\ '.strip() if os.name == 'nt'
                         else '/bin/')]
        lines += ['', 'palettize4.py itself needs none of Qt:', '',
                  '    python palettize4.py IMAGE.png --out build', '']
        sys.exit('\n'.join(lines))
    return run(sys.argv)


if __name__ == '__main__':
    raise SystemExit(main())
