"""main.py - the window.

LAYOUT: the comparison in the middle, options on the left, the run's numbers on
the right, palettes and the queue tabbed along the bottom.  There is no
document and no undo stack here - the state IS the options panel, and the thing
you undo is pressing Preview again.

THE PREVIEW IS THE REAL CONVERTER WRITING TO A SCRATCH DIRECTORY.  Everything
in this file is bookkeeping around that one fact: which run is current, whether
its result still matches the controls, and where the files went.  The moment a
control moves, the picture on screen is out of date and says so - a preview you
cannot trust to match the settings beside it is worse than no preview, because
you will tune against it.

THE STATUS BAR IS WHERE A RUN LIVES.  Elapsed seconds while it goes (an
error-diffusion dither is genuinely slow and a still window looks hung), then
the headline: how many colours, and what it cost.
"""

import os
import shutil
import tempfile

from PySide6.QtCore import QSettings, Qt
from PySide6.QtGui import QAction, QImage, QKeySequence
from PySide6.QtWidgets import (QApplication, QComboBox, QDialog,
                               QDialogButtonBox, QDockWidget, QFileDialog,
                               QInputDialog, QLabel, QMainWindow, QMessageBox,
                               QPlainTextEdit, QScrollArea, QToolBar,
                               QVBoxLayout)

from .. import imageslst, jobs, presets, runner, snapshot, summary
from . import theme
from .compare import FLIP, SIDE_BY_SIDE, ComparePane
from .imageview import FIT
from .joblist import JobList
from .options import OptionsPanel
from .palettepane import PalettePane
from .reviewpane import ReviewPane
from .statspane import StatsPane
from .worker import Worker


#: QSettings scope for the remembered window layout.  Nothing else is stored -
#: presets and queues are files in the repo, deliberately, so they can be read
#: and committed; this is only where the furniture was left.
ORG = 'VBXE'
APP = 'VBXE PAL Studio'

#: Bumped whenever the set of docks changes.  restoreState matches docks by
#: objectName, and a blob written before a panel existed does not mention it -
#: which can leave the new one hidden, in the wrong area, or zero-height, with
#: nothing on screen to explain why.  A mismatch here discards the saved layout
#: ONCE.  One session of furniture in the wrong place beats a panel that is not
#: there and no way to find out why.
LAYOUT_VERSION = 2


class MainWindow(QMainWindow):

    def __init__(self, initial_input=''):
        QMainWindow.__init__(self)
        self.setWindowTitle('VBXE PAL Studio')
        self.resize(1500, 940)

        #: Where Preview writes.  One directory for the whole session, reused,
        #: so previewing forty times leaves eleven files rather than four
        #: hundred and forty.
        self.scratch = tempfile.mkdtemp(prefix='palgui-')

        #: The settings that produced what is on screen, or None.  NOT the same
        #: object as the panel's - that is the whole point of keeping it.
        self.shown = None
        self.shown_stats = None
        self.stale = False
        #: The previous panel state, so _settings_changed can see WHICH option
        #: moved rather than only that something did.
        self._last = None
        #: The source pane's pixel buffer.  QImage does not copy it.
        self._src_bytes = None
        #: Whether we currently hold an override cursor.  See _set_busy_cursor.
        self._busy = False
        #: (png, txt) of the snapshot the last run wrote, or None.  A preview
        #: run's own output lives in the scratch directory, which the next one
        #: overwrites - so for a queued preview this pair is the ONLY lasting
        #: record of that job's picture.  See _batch_landed.
        self._last_snapshot = None

        self.queue = jobs.Queue()
        self._batch = None          # index of the running job, or None
        #: True while Preview all is running: every job goes through the
        #: scratch directory and leaves a numbered snapshot instead of writing
        #: a conversion.  See _batch_next.
        self._batch_preview = False

        self.options = OptionsPanel()
        self.compare = ComparePane()
        self.stats = StatsPane()
        self.palettes = PalettePane()
        self.joblist = JobList(self.queue)
        self.review = ReviewPane()
        self.worker = Worker(self)

        self.setCentralWidget(self.compare)

        scroll = QScrollArea()
        scroll.setWidget(self.options)
        scroll.setWidgetResizable(True)
        # Vertical scrolling only.  The panel is five stacked forms; letting it
        # scroll sideways instead of widening hides the right-hand half of
        # every row, which is where all the values are.
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        scroll.setMinimumWidth(360)
        self.d_opts = self._dock('Options', scroll, Qt.LeftDockWidgetArea)
        d_opts = self.d_opts

        self.d_stats = self._dock('Result', self.stats, Qt.RightDockWidgetArea)
        d_stats = self.d_stats
        # The stats table is two columns of text, and the right-hand one holds
        # sentences ("lossy - fidelity (bias 0.00)").  Left to itself the dock
        # comes up at about 180px and wraps every one of them to three lines.
        d_stats.setMinimumWidth(300)
        self.resizeDocks([d_opts, d_stats], [370, 340], Qt.Horizontal)

        self.d_pal = self._dock('Palettes', self.palettes,
                                Qt.BottomDockWidgetArea)
        self.d_queue = self._dock('Queue', self.joblist,
                                  Qt.BottomDockWidgetArea)
        self.d_review = self._dock('Previews', self.review,
                                   Qt.BottomDockWidgetArea)
        d_pal, d_queue = self.d_pal, self.d_queue
        self.tabifyDockWidget(d_pal, d_queue)
        self.tabifyDockWidget(d_queue, self.d_review)
        d_pal.raise_()
        self.resizeDocks([d_pal], [230], Qt.Vertical)

        self._menus()
        self._toolbar()

        self.status = QLabel('open an image, then press Preview')
        self.status.setFont(theme.label_font(9))
        self.statusBar().addWidget(self.status, 1)
        self.hover = QLabel('')
        self.hover.setFont(theme.label_font(8))
        self.statusBar().addPermanentWidget(self.hover)

        # --- wiring -----------------------------------------------------------
        self.options.changed.connect(self._settings_changed)
        self.options.input_changed.connect(self._load_source)
        self.compare.hovered.connect(self._hovered)
        self.compare.viewChanged.connect(self._show_zoom)
        self.worker.started.connect(self._run_started)
        self.worker.finished.connect(self._run_finished)
        self.worker.failed.connect(self._run_failed)
        self.worker.tick.connect(self._run_tick)
        self.joblist.selected.connect(self._job_selected)
        self.joblist.add_requested.connect(self._job_add)
        self.joblist.add_files_requested.connect(self._job_add_files)
        self.joblist.update_requested.connect(self._job_update)
        self.joblist.run_requested.connect(self._batch_start)
        self.joblist.preview_requested.connect(
            lambda: self._batch_start(preview=True))
        self.joblist.stop_requested.connect(self._batch_stop)
        self.joblist.retarget_requested.connect(self._job_retarget)
        self.joblist.save_requested.connect(self._queue_save)
        self.joblist.load_requested.connect(self._queue_load)
        self.review.selected.connect(self._review_selected)
        self.review.open_requested.connect(self._browse_previews)

        # THE DEFAULT LAYOUT, CAPTURED BEFORE ANYTHING IS RESTORED OVER IT.
        # This is what View > Reset panels goes back to, so it has to be the
        # arrangement built above rather than whatever the last session left.
        self._default_state = self.saveState()
        self._default_geometry = self.saveGeometry()
        self._restore_layout()

        presets.ensure_builtins()
        self._reload_presets()
        if initial_input:
            s = self.options.to_settings()
            s.input = initial_input
            self.options.from_settings(s)
            self._load_source(initial_input)
        self.compare.setFocus()

    # ------------------------------------------------------------------------
    def _dock(self, title, widget, area):
        d = QDockWidget(title, self)
        d.setWidget(widget)
        d.setObjectName(title)
        self.addDockWidget(area, d)
        return d

    def _act(self, menu, text, shortcut, slot, tip=''):
        a = QAction(text, self)
        if shortcut:
            a.setShortcut(QKeySequence(shortcut))
        if tip:
            a.setStatusTip(tip)
        a.triggered.connect(slot)
        menu.addAction(a)
        return a

    def _menus(self):
        m = self.menuBar().addMenu('&File')
        self._act(m, 'Open image...', QKeySequence.Open,
                  self.options._browse_input)
        m.addSeparator()
        self._act(m, 'Browse previews...', '', self._browse_previews,
                  'Read a folder of saved previews back in and step through '
                  'them')
        m.addSeparator()
        self._act(m, 'Save queue...', '', self._queue_save)
        self._act(m, 'Load queue...', '', self._queue_load)
        m.addSeparator()
        self._act(m, 'Copy command line', 'Ctrl+Shift+C', self._copy_command,
                  'Put the equivalent palettize4.py command on the clipboard')
        self._act(m, 'Open output folder', '', self._open_output)
        self._act(m, 'Build images.lst...', '', self._build_images_lst,
                  'Scan a folder of converted images and write the images.lst '
                  'manifest the Atari viewer reads for long filenames')
        m.addSeparator()
        self._act(m, 'Quit', QKeySequence.Quit, self.close)

        m = self.menuBar().addMenu('&Run')
        self.a_preview = self._act(m, 'Preview', 'F5', self.preview,
                                   'Convert into a scratch directory and show '
                                   'the result')
        self.a_convert = self._act(m, 'Convert', 'Ctrl+Return', self.convert,
                                   'Write the real output files')
        m.addSeparator()
        self._act(m, 'Run queue (convert)', '', self._batch_start,
                  'Convert every job - one output directory per image')
        self._act(m, 'Preview queue', 'Ctrl+F5',
                  lambda: self._batch_start(preview=True),
                  'Preview every job, keeping a numbered snapshot of each '
                  'under out/<image>/previews/')
        self.a_cancel = self._act(m, 'Cancel', 'Esc', self.cancel)
        self.a_cancel.setEnabled(False)
        m.addSeparator()
        # Alt+Left / Alt+Right, not PgUp / PgDn: those belong to whatever has
        # focus, and a window-wide shortcut on them would stop the Report tab
        # scrolling.  Alt+arrow already means back and forward everywhere else.
        self.a_prev = self._act(m, 'Previous result', 'Alt+Left',
                                lambda: self._step_result(-1),
                                'The previous saved preview, or the previous '
                                'finished job')
        self.a_next = self._act(m, 'Next result', 'Alt+Right',
                                lambda: self._step_result(1),
                                'The next saved preview, or the next finished '
                                'job')

        m = self.menuBar().addMenu('&View')
        self._act(m, 'Flip source / converted', 'Tab', self.compare.flip)
        m.addSeparator()
        self._act(m, 'Fit', 'Ctrl+0', self.compare.fit)
        self._act(m, 'Zoom in', QKeySequence.ZoomIn,
                  lambda: self._zoom_step(1))
        self._act(m, 'Zoom out', QKeySequence.ZoomOut,
                  lambda: self._zoom_step(-1))

        # PANELS ARE CLOSABLE, SO THERE HAS TO BE A WAY BACK.  Qt puts the same
        # toggles on a right-click of the toolbar, but nothing on screen says
        # so - close the Options dock and the app looks broken rather than
        # tidied.  toggleViewAction() is the dock's own checkable action, so it
        # stays in step with the panel however it was hidden, including by the
        # little x in its title bar.
        m.addSeparator()
        panels = m.addMenu('&Panels')
        for dock in self._docks():
            panels.addAction(dock.toggleViewAction())
        panels.addSeparator()
        self._act(panels, 'Show all', '', self._show_all_panels)
        self._act(m, 'Reset panels', '', self._reset_panels,
                  'Put every panel back where it started')

        m = self.menuBar().addMenu('&Help')
        self._act(m, 'About', '', self._about)

    def _toolbar(self):
        tb = QToolBar('Run')
        tb.setObjectName('runbar')
        tb.setMovable(False)
        self.addToolBar(tb)
        tb.addAction(self.a_preview)
        tb.addAction(self.a_convert)
        tb.addAction(self.a_cancel)
        tb.addSeparator()
        # ON THE TOOLBAR AND NOT ONLY IN THE PREVIEWS DOCK.  Comparing pictures
        # means looking at the picture; a button at the bottom of the window
        # pulls your eye off the thing you are judging on every step.
        tb.addAction(self.a_prev)
        tb.addAction(self.a_next)
        tb.addSeparator()

        self.mode = QComboBox()
        self.mode.addItem('flip (A / B)', FLIP)
        self.mode.addItem('side by side', SIDE_BY_SIDE)
        self.mode.setToolTip(
            'Flip shows one image at a time in the same place, which is the '
            'only way to see a dither difference - hold SPACE, or press A and '
            'B.\n\n'
            'Side by side is for framing: what a cover crop threw away, or '
            'where the letterbox bars landed.')
        # ACTIVATED, NOT currentIndexChanged, throughout this toolbar.
        # `activated` fires only for a user pick, so syncing a box FROM the
        # view (below) cannot feed back into the view; and it fires even when
        # the same entry is re-chosen, which is what makes picking `fit` do
        # something when the box already says `fit`.
        self.mode.activated.connect(
            lambda _i: self.compare.set_mode(self.mode.currentData()))
        tb.addWidget(self.mode)

        self.zoom = QComboBox()
        self.zoom.addItem('fit', FIT)
        for z in (1, 2, 3, 4, 6, 8, 12, 16):
            self.zoom.addItem('%dx' % z, z)
        self.zoom.setToolTip(
            'Nearest-neighbour at every step, so the dither grain stays visible '
            'instead of being smoothed into the mush it is there to replace.\n\n'
            '4x and up is where you can actually judge one.')
        self.zoom.activated.connect(
            lambda _i: self.compare.set_zoom(self.zoom.currentData()))
        tb.addWidget(self.zoom)
        tb.addSeparator()

        tb.addWidget(QLabel(' preset '))
        self.presets = QComboBox()
        self.presets.setMinimumWidth(200)
        self.presets.setToolTip(
            'A named set of options, without the file paths - a recipe, not a '
            'job.  Applying one changes how the image in front of you is '
            'converted; it does not change which image that is.')
        self.presets.activated.connect(self._preset_apply)
        tb.addWidget(self.presets)
        self._act(tb, 'Save preset...', '', self._preset_save)
        self._act(tb, 'Delete preset', '', self._preset_delete)

    # --- the source image ------------------------------------------------------
    def _load_source(self, path, keep_result=False):
        """Show the input in the source pane, resampled the way the run will be.

        WITHOUT THIS THE WINDOW IS EMPTY UNTIL THE FIRST PREVIEW, which for a
        floyd dither on a big source is ten seconds of not knowing whether you
        even opened the right file.

        AND IT IS THE RESAMPLED SOURCE, NOT THE FILE.  runner.load_source runs
        the input through palettize4's own resize_image, so the source pane and
        the result pane hold the same grid at the same size.  Show the raw
        1600x1200 file beside a 320x240 result and the flip - the entire point
        of the pane - compares a resample instead of a dither.
        """
        if not path:
            self.compare.set_source(None)
            return
        try:
            src = runner.load_source(self.options.to_settings())
        except runner.RunError as exc:
            self.compare.set_source(None)
            self._say(exc.message, theme.ERR)
            return
        if src is None:
            self.compare.set_source(None)
            self._say('%s does not exist' % path, theme.ERR)
            return
        w, h, rgb = src
        # Kept alive on self: QImage wraps the buffer without copying it, and a
        # freed bytes object here is a crash, not a blank pane.
        self._src_bytes = rgb
        img = QImage(rgb, w, h, w * 3, QImage.Format_RGB888)
        self.compare.set_source(img)
        if keep_result:
            return
        self.compare.clear_result()
        self.stats.clear()
        self.palettes.clear()
        self.options.set_dither_note('')
        self.shown = None
        self.shown_stats = None
        self._say('%s - %dx%d as the packer will see it.  Press Preview.'
                  % (os.path.basename(path), w, h))

    # --- running ------------------------------------------------------------------
    def preview(self):
        s = self.options.to_settings()
        if not self._check_input(s):
            return
        self.worker.start(s, self.scratch, runner.PREVIEW_NAME)

    def convert(self):
        s = self.options.to_settings()
        if not self._check_input(s):
            return
        # ONE IMAGE, ONE FOLDER - see runner.job_dir.  The run is told the
        # subdirectory, so palettize4's own paths in stats['files'] stay
        # relative to it and output_paths() keeps working unchanged.
        out = runner.resolve(runner.job_dir(s))
        try:
            os.makedirs(out, exist_ok=True)
        except OSError as exc:      # noqa: BLE001 - shown to the user
            self._say('cannot create %s: %s' % (out, exc), theme.ERR)
            return
        self._batch = None
        self.worker.start(s, out, s.name or None)

    def cancel(self):
        if self.worker.busy():
            self.worker.cancel()
            self._batch = None
            self.joblist.set_running(False)
            self._set_running(False)
            self._say('cancelled', theme.TEXT_DIM)

    def _check_input(self, s):
        if not s.input:
            self._say('choose an image first', theme.WARN)
            return False
        if not os.path.isfile(s.input):
            self._say('%s does not exist' % s.input, theme.ERR)
            return False
        return True

    def _run_started(self, settings, out, name):
        self._set_running(True)
        what = 'preview' if out == self.scratch else 'convert -> %s' % out
        bits = [what]
        if settings.dither != 'none':
            # The dither is the reason a run takes seconds rather than a
            # moment, so naming it here is naming the wait.
            bits.append('dither %s' % settings.dither)
        self._say('running (%s)...' % ', '.join(bits), theme.ACCENT)

    def _run_tick(self, seconds):
        if self.worker.busy():
            self._say('running... %ds' % int(seconds), theme.ACCENT)

    def _run_finished(self, settings, out, name, stats):
        self._set_running(False)
        self.shown = settings.clone()
        self.shown_stats = stats
        self.stale = False

        paths = runner.output_paths(stats, out)
        preview = paths.get('preview')
        if preview and os.path.isfile(preview):
            img = QImage(preview)
            self.compare.set_result(img if not img.isNull() else None)
        self.palettes.load(paths.get('palettes'), stats, settings.reserve0)
        # THE LINE THAT WOULD REPRODUCE THIS PICTURE, which for a preview
        # is the CONVERT of it: --out out/<name>, not the scratch directory
        # this run actually used and not the internal --name preview it was
        # given.  A recipe naming a temporary directory is not a recipe.
        command = settings.command_line(
            script=os.path.basename(runner.SCRIPT),
            out=runner.job_dir(settings))
        self.stats.set_stats(settings, stats, command=command)
        report = summary.report_text(paths.get('report'))
        self.stats.set_report(report)

        # THE INERT-DITHER WARNING.  See runner.dither_was_inert - without it
        # the whole comparison this app exists for fails silently.
        if runner.dither_was_inert(settings, stats):
            self.options.set_dither_note(
                'no effect: the source has only %d colours, which is inside '
                'the %d budget, so no reduction ran and there was nothing to '
                'dither.  Lower "pre-quantize" below %d to force one.'
                % (stats.get('master_colours', 0), settings.colour_budget(),
                   stats.get('master_colours', 0)))
        else:
            self.options.set_dither_note('')

        line = runner.headline(settings, stats)
        colour = theme.OK if stats.get('lossless') else theme.TEXT
        if out == self.scratch and self.options.snapshots_wanted():
            fragment, ok = self._save_snapshot(settings, stats, paths,
                                               command, report)
            line += fragment
            if not ok:
                colour = theme.WARN
        self._say(line, colour)
        if self._batch is not None:
            self._batch_landed(stats, None)

    # --- keeping a preview ----------------------------------------------------
    def _save_snapshot(self, settings, stats, paths, command, report):
        """Write Preview_NN.png / .txt under the image's own output folder.

        RETURNS (fragment, ok) FOR THE STATUS LINE rather than saying
        anything itself.  The headline then stays one sentence - "LOSSLESS -
        1018 colours  +  saved Preview_04" - and, more to the point, a failure
        message written here would be overwritten by the headline a moment
        later and never seen.

        NEVER COSTS YOU THE PREVIEW.  A full disk, a read-only output tree or a
        folder someone has open elsewhere are all real, and none of them is a
        reason to throw away the conversion that just finished - the picture is
        already on screen and the settings are still in the panel.
        """
        out = runner.resolve(settings.out)
        where = snapshot.dir_for(out, settings.effective_name() or 'preview')
        try:
            _index, png, txt = snapshot.write_for_run(
                out, settings, stats, paths, command, report)
        except (OSError, KeyError, ValueError) as exc:  # noqa: BLE001 - shown
            return '   -  SNAPSHOT NOT WRITTEN: %s' % exc, False
        self._last_snapshot = (png, txt)
        # A list showing this same folder would otherwise silently omit the
        # shot just taken, which looks like the snapshot did not happen.
        if self.review.directory() == where:
            self.review.load(where)
        return ('   +  saved %s in %s'
                % (os.path.basename(png),
                   os.path.join(os.path.basename(os.path.dirname(where)),
                                os.path.basename(where)))), True

    def _run_failed(self, settings, err):
        self._set_running(False)
        self._say(err.message, theme.ERR)
        self._last_error = err
        if self._batch is not None:
            self._batch_landed(None, err)
            return
        if err.detail:
            self._show_text('palettize4 failed', err.detail)

    def _set_running(self, running):
        self.a_preview.setEnabled(not running)
        self.a_convert.setEnabled(not running)
        self.a_cancel.setEnabled(running)
        self._set_busy_cursor(running)

    def _set_busy_cursor(self, busy):
        """The pointer says a run is going, alongside the status bar.

        BUSY AND NOT WAIT.  Qt.WaitCursor is the plain hourglass and it means
        "this application cannot take input"; Qt.BusyCursor is the pointer WITH
        an hourglass and means "working, but still yours" - which is the true
        state here.  Cancel is live throughout, the panes still pan and zoom,
        and the queue keeps drawing.  An hourglass would be telling the user
        their Cancel button is dead when it is not.

        PUSHED AND POPPED EXACTLY ONCE.  setOverrideCursor is a STACK, not a
        setting: two pushes need two restores, and a run that ends by a route
        that pushed nothing would pop somebody else's cursor.  _set_running is
        called on every job of a queue and again on cancel, so the flag is what
        keeps that honest rather than trusting the call sites to pair up.
        """
        if bool(busy) == self._busy:
            return
        self._busy = bool(busy)
        if busy:
            QApplication.setOverrideCursor(Qt.BusyCursor)
        else:
            QApplication.restoreOverrideCursor()

    #: The options that change how the SOURCE pane looks, as opposed to how the
    #: result does.  Moving one of these has to re-resample the source, or the
    #: two panes stop being the same grid and the flip stops meaning anything.
    RESAMPLE_FIELDS = ('input', 'resize', 'filter', 'fit', 'display_aspect')

    def _settings_changed(self):
        """A control moved, so what is on screen no longer matches the panel."""
        now = self.options.to_settings()
        was = self._last or now
        self._last = now
        if any(getattr(now, f) != getattr(was, f)
               for f in self.RESAMPLE_FIELDS):
            self._load_source(now.input, keep_result=True)

        if self.shown is None:
            return
        # out/name do not change the picture, so changing where it will be
        # written must not declare the picture stale.
        a, b = now.to_dict(), self.shown.to_dict()
        for k in ('out', 'name'):
            a.pop(k, None)
            b.pop(k, None)
        stale = a != b
        if stale != self.stale:
            self.stale = stale
            if stale:
                self._say('settings changed - the preview is out of date, '
                          'press Preview (F5)', theme.WARN)

    # --- presets ----------------------------------------------------------------
    def _reload_presets(self, select=''):
        self.presets.blockSignals(True)
        self.presets.clear()
        self.presets.addItem('(none)')
        for n in presets.names():
            self.presets.addItem(n)
        if select:
            i = self.presets.findText(select)
            if i >= 0:
                self.presets.setCurrentIndex(i)
        self.presets.blockSignals(False)

    def _preset_apply(self, index):
        if index <= 0:
            return
        name = self.presets.itemText(index)
        try:
            s = presets.load(name, onto=self.options.to_settings())
        except (OSError, ValueError) as exc:   # noqa: BLE001 - shown below
            self._say('could not read preset %s: %s' % (name, exc), theme.ERR)
            return
        self.options.from_settings(s)
        self._say('applied preset "%s" - press Preview' % name)

    def _preset_save(self):
        name, ok = QInputDialog.getText(self, 'Save preset', 'Name:')
        if not ok or not name.strip():
            return
        presets.save(name.strip(), self.options.to_settings())
        self._reload_presets(select=name.strip())
        self._say('saved preset "%s"' % name.strip())

    def _preset_delete(self):
        name = self.presets.currentText()
        if self.presets.currentIndex() <= 0:
            return
        if QMessageBox.question(self, 'Delete preset',
                                'Delete the preset "%s"?' % name) \
                != QMessageBox.Yes:
            return
        presets.delete(name)
        self._reload_presets()

    # --- the queue ----------------------------------------------------------------
    def _job_add(self):
        s = self.options.to_settings()
        if not s.input:
            self._say('choose an image before queueing it', theme.WARN)
            return
        self.queue.add(s)
        self.joblist.refresh(keep=len(self.queue) - 1)

    def _job_add_files(self):
        base = self.options.to_settings()
        start = os.path.dirname(base.input) or runner.CONVERTOR
        paths, _ = QFileDialog.getOpenFileNames(
            self, 'Queue images', start,
            'Images (*.png *.bmp *.jpg *.jpeg *.gif *.tif *.tiff *.webp '
            '*.tga *.pcx *.ppm);;All files (*)')
        for p in paths:
            s = base.clone()
            s.input = p
            # A blank --name lets palettize4 use each input's own stem, which
            # is what you want for a batch; carrying one name across ten files
            # would have them overwrite each other.
            s.name = ''
            self.queue.add(s)
        if paths:
            self.joblist.refresh(keep=len(self.queue) - 1)
            self._say('queued %d image%s'
                      % (len(paths), '' if len(paths) == 1 else 's'))

    def _job_update(self, row):
        if not (0 <= row < len(self.queue)):
            return
        job = self.queue[row]
        job.settings = self.options.to_settings()
        job.label = job.settings.effective_name() or job.label
        job.reset()
        self.joblist.refresh(keep=row)

    def _job_retarget(self):
        """Point the whole queue at another image - a queue as a script.

        SAME DIALOG AS Add files..., because it is the same question asked
        once instead of once per job.
        """
        if not len(self.queue):
            self._say('the queue is empty - nothing to retarget', theme.WARN)
            return
        base = self.options.to_settings()
        start = os.path.dirname(base.input) or runner.CONVERTOR
        path, _ = QFileDialog.getOpenFileName(
            self, 'Point every job at this image', start,
            'Images (*.png *.bmp *.jpg *.jpeg *.gif *.tif *.tiff *.webp '
            '*.tga *.pcx *.ppm);;All files (*)')
        if not path:
            return
        moved = self.queue.retarget(path)
        self.joblist.refresh(keep=self.joblist.current_row())
        self._say('%d job%s now point at %s - results cleared, they described '
                  'a different picture'
                  % (moved, '' if moved == 1 else 's',
                     os.path.basename(path)))

    def _job_selected(self, job):
        """A queue row, restored: settings, picture, numbers and report.

        THE PICTURE WAS THE MISSING HALF.  The row already knew where its
        output went - the stats carry the directory and the file names - so
        clicking through a finished batch showed four sets of numbers and one
        stale image, which is the comparison this pane exists for done exactly
        backwards.

        AND THE REPORT TAB, which was never refreshed here at all: it kept
        whatever the last Preview left in it, so a job's fresh numbers sat
        above another run's report with nothing to say they disagreed.
        """
        self.options.from_settings(job.settings)
        self._load_source(job.settings.input, keep_result=True)
        if not job.stats:
            self.compare.clear_result()
            self.stats.clear()
            self.stats.set_report('')
            self.palettes.clear()
            return
        if job.snapshot:
            # A PREVIEWED JOB'S out_dir IS THE SCRATCH DIRECTORY, which the
            # next job overwrote and which the app deletes on exit - so
            # following it would show every row the last job's picture, and
            # nothing at all after a restart.  The snapshot is the record.
            png, txt = job.snapshot
            self._show_saved(png, summary.report_text(txt), None,
                             job.settings, job.stats)
            return
        out = job.stats.get('out_dir') or runner.resolve(
            runner.job_dir(job.settings))
        paths = runner.output_paths(job.stats, out)
        self._show_saved(paths.get('preview'),
                         summary.report_text(paths.get('report')),
                         paths.get('palettes'), job.settings, job.stats)

    # --- looking back at something already on disk ---------------------------
    def _show_saved(self, png, report, palettes, settings, stats, note=''):
        """Put a result that already exists on disk into the panes.

        SHARED BY THE QUEUE AND THE PREVIEWS PANE because they are the same
        act: a picture, a report and a set of numbers that were produced
        earlier, with the panel already holding the settings that made them.

        A MISSING FILE CLEARS THE PANE RATHER THAN LEAVING THE LAST ONE.
        Output can be deleted, moved or on a drive that is not plugged in, and
        the previous image left under a new set of numbers is a lie that looks
        exactly like a success.
        """
        img = QImage(png) if png and os.path.isfile(png) else QImage()
        self.compare.set_result(img if not img.isNull() else None)
        if palettes:
            self.palettes.load(palettes, stats, settings.reserve0)
        else:
            self.palettes.clear()
        if stats:
            self.stats.set_stats(settings, stats, command=settings.command_line(
                script=os.path.basename(runner.SCRIPT),
                out=runner.job_dir(settings)))
        else:
            self.stats.set_note(note or 'no numbers saved with this one')
        self.stats.set_report(report or '')
        # The panel now matches what is on screen, so the stale marker has to
        # agree - otherwise the next unrelated keystroke announces that a
        # picture you just loaded is out of date.
        self.shown = settings.clone()
        self.shown_stats = stats
        self.stale = False

    def _review_selected(self, shot):
        """One saved preview, back on screen with the settings that made it."""
        if shot is None:
            return
        if shot.settings is None:
            self._show_saved(shot.png, shot.text, None,
                             self.options.to_settings(), None,
                             note='this summary carries neither a footer nor '
                                  'a command line')
            self._say('%s - could not recover its settings' % shot.label(),
                      theme.WARN)
            return
        self.options.from_settings(shot.settings)
        self._load_source(shot.settings.input, keep_result=True)
        # A snapshot is two files: there is no palette sheet to load, and the
        # previous image's would be the wrong four palettes under this picture.
        self._show_saved(shot.png, shot.text, None, shot.settings, shot.stats,
                         note='written before summaries carried their numbers '
                              '- they are in the Report tab, in prose')
        row = self.review.current_row() + 1
        self._say('%s (%d of %d) - %s, bias %s.  Convert writes it for real.'
                  % (shot.label(), row, self.review.count(),
                     shot.dither(), shot.bias()))

    def _browse_previews(self):
        """Pick a previews folder, starting at the current image's own.

        THE DEFAULT IS THE POINT.  out/<image>/previews is where the button
        that made these files put them, so opening straight there turns a
        four-level directory walk into one click.
        """
        start = snapshot.dir_for(runner.resolve(self.options.to_settings().out),
                                 self.options.to_settings().effective_name()
                                 or '')
        if not os.path.isdir(start):
            start = runner.resolve(self.options.to_settings().out)
        where = QFileDialog.getExistingDirectory(
            self, 'Open a previews folder', start)
        if not where:
            return
        found = self.review.load(where)
        self.d_review.show()
        self.d_review.raise_()
        if not found:
            self._say('no Preview_NN pairs in %s' % where, theme.WARN)
        else:
            self._say('%d preview%s loaded - Alt+Left / Alt+Right to step '
                      'through them' % (found, '' if found == 1 else 's'))

    def _step_result(self, delta):
        """Previous / next, over whichever list has something in it.

        THE PREVIEWS PANE WINS WHEN IT IS LOADED, because that is what you were
        stepping through; the queue is the fallback so the same two buttons
        also walk a finished batch, which is the other place a row has a
        picture behind it.
        """
        if self.review.count():
            self.review.step(delta)
            return
        rows = len(self.queue)
        if not rows:
            return
        r = self.joblist.current_row()
        n = min(max(0 if r < 0 else r + delta, 0), rows - 1)
        if n != r:
            self.joblist.table.selectRow(n)

    def _batch_start(self, preview=False):
        """Run the whole queue, converting or previewing.

        PREVIEW ALL IS NOT A SECOND-CLASS RUN, it is the mode that works for
        the commonest use of a queue: one image, a dozen variants.  Converting
        those writes one image's filenames a dozen times, so eleven of the
        twelve results never exist for longer than it takes the next job to
        start.  Previewed, each one leaves a numbered pair instead.
        """
        if self.worker.busy():
            return
        if not len(self.queue):
            self._say('the queue is empty - Add puts the current settings in '
                      'it', theme.WARN)
            return
        note = ''
        if preview and not self.options.snapshots_wanted():
            # SWITCHED ON WHERE YOU CAN SEE IT, not forced behind the panel's
            # back.  A preview run that keeps nothing is the whole batch for no
            # files; a tick box reading "off" while thirty files appear is
            # worse still.  So the control moves, visibly, and says so.
            self.options.set_snapshots_wanted(True)
            note = ' - snapshots switched on, or this would keep nothing'
        elif not preview:
            clash = self.queue.collisions()
            if clash:
                worst = max(len(rows) for _t, rows in clash)
                note = (' - WARNING: %d jobs write to the same output and will '
                        'overwrite each other; Preview all keeps them all'
                        % worst)
        self.queue.reset()
        self._batch = -1
        self._batch_preview = preview
        self.joblist.set_running(True, 0)
        self._say('%s %d job%s%s'
                  % ('previewing' if preview else 'converting',
                     len(self.queue), '' if len(self.queue) == 1 else 's',
                     note), theme.WARN if 'WARNING' in note else None)
        self._batch_next()

    def _batch_stop(self):
        self._batch = None
        self._batch_preview = False
        self.worker.cancel()
        self.joblist.set_running(False)
        self.joblist.refresh()
        self._set_running(False)
        self._say('queue stopped', theme.TEXT_DIM)

    def _batch_next(self):
        if self._batch is None:
            return
        self._batch += 1
        if self._batch >= len(self.queue):
            done, failed, total = self.queue.counts()
            self._batch = None
            self.joblist.set_running(False)
            self.joblist.refresh()
            tail = self._batch_finished() if self._batch_preview else ''
            self._batch_preview = False
            self._say('queue finished - %d of %d done%s%s'
                      % (done, total,
                         ', %d failed' % failed if failed else '', tail),
                      theme.ERR if failed else theme.OK)
            return
        job = self.queue[self._batch]
        job.state = jobs.RUNNING
        self.joblist.set_running(True, self._batch)
        self.joblist.refresh(keep=self._batch)
        if self._batch_preview:
            # EXACTLY WHAT THE PREVIEW BUTTON DOES, one job at a time.  The
            # scratch directory already exists and each job's snapshot is
            # filed under its OWN image, so a mixed queue sorts itself.
            self.worker.start(job.settings, self.scratch, runner.PREVIEW_NAME)
            return
        out = runner.resolve(runner.job_dir(job.settings))
        try:
            os.makedirs(out, exist_ok=True)
        except OSError as exc:      # noqa: BLE001 - recorded on the row
            job.state = jobs.FAILED
            job.error = 'cannot create %s: %s' % (out, exc)
            self.joblist.refresh(keep=self._batch)
            self._batch_next()
            return
        self.worker.start(job.settings, out, job.settings.name or None)

    def _batch_landed(self, stats, err):
        job = self.queue[self._batch]
        if err is None:
            job.state = jobs.DONE
            job.stats = stats
            job.error = ''
            # THE ONLY LASTING RECORD OF A PREVIEWED JOB'S PICTURE.  Its own
            # output went to the scratch directory, which the next job is
            # about to overwrite; the snapshot is what survives.
            if self._batch_preview:
                job.snapshot = self._last_snapshot
        else:
            job.state = jobs.FAILED
            job.error = err.message
        self.joblist.refresh(keep=self._batch)
        self._batch_next()

    def _batch_finished(self):
        """Open the previews the batch just wrote, when they share a folder.

        FIFTEEN JOBS, ONE BUTTON, AND THE RESULT IS ALREADY ON SCREEN.  That
        is the point of previewing a queue; making you then find the folder by
        hand would put the walk back where it started.  A mixed queue writes
        several folders and there is no one right one to open, so it says how
        many instead.
        """
        folders = set()
        for job in self.queue:
            if job.snapshot:
                folders.add(os.path.dirname(job.snapshot[0]))
        if len(folders) == 1:
            where = folders.pop()
            if self.review.load(where):
                self.d_review.show()
                self.d_review.raise_()
            return ' - %s is open in Previews' % os.path.basename(
                os.path.dirname(where))
        if folders:
            return ' - snapshots written to %d folders' % len(folders)
        return ''

    def _queue_save(self):
        path, _ = QFileDialog.getSaveFileName(
            self, 'Save queue', runner.CONVERTOR, 'Queue (*.json)')
        if path:
            # Typing `mytests` otherwise writes a file that the Load dialog,
            # filtering on *.json, then refuses to show you.
            if not os.path.splitext(path)[1]:
                path += '.json'
            self.queue.save(path)
            self._say('saved %d job%s to %s'
                      % (len(self.queue), '' if len(self.queue) == 1 else 's',
                         path))

    def _queue_load(self):
        path, _ = QFileDialog.getOpenFileName(
            self, 'Load queue', runner.CONVERTOR, 'Queue (*.json)')
        if not path:
            return
        try:
            q = jobs.Queue.load(path)
        except (OSError, ValueError) as exc:    # noqa: BLE001 - shown below
            self._say('could not read %s: %s' % (path, exc), theme.ERR)
            return
        self.queue.jobs = q.jobs
        self.joblist.refresh(keep=0)
        self._say('loaded %d job%s' % (len(self.queue),
                                       '' if len(self.queue) == 1 else 's'))

    # --- panels ---------------------------------------------------------------
    def _docks(self):
        return (self.d_opts, self.d_stats, self.d_pal, self.d_queue,
                self.d_review)

    def _show_all_panels(self):
        for dock in self._docks():
            dock.show()

    def _reset_panels(self):
        """Back to the arrangement the window was built with."""
        self.restoreState(self._default_state)
        self._show_all_panels()
        self._say('panels reset')

    def _restore_layout(self):
        """Re-adopt last session's geometry and panel arrangement.

        WRAPPED, BECAUSE A SAVED BLOB IS NOT A CONTRACT.  restoreState matches
        docks by objectName, so a state written by a version with different
        panels can leave one of them hidden with no obvious cause - and an
        empty window that took three restarts to explain is a bad trade for
        remembering a splitter position.  Anything unexpected and we keep the
        defaults.
        """
        try:
            st = QSettings(ORG, APP)
            geom = st.value('geometry')
            state = st.value('state')
            if int(st.value('layout_version', 0) or 0) != LAYOUT_VERSION:
                state = None        # written before a panel existed; see above
            # A QSettings bool comes back as the string 'true' on some
            # backends, so compare rather than trusting truthiness - a
            # non-empty 'false' would switch the thing on.
            self.options.set_snapshots_wanted(
                str(st.value('snapshots', 'false')).lower() == 'true')
            if geom is not None:
                self.restoreGeometry(geom)
            if state is not None:
                self.restoreState(state)
        except Exception:               # noqa: BLE001 - fall back to defaults
            self.restoreState(self._default_state)

    def _save_layout(self):
        try:
            st = QSettings(ORG, APP)
            st.setValue('geometry', self.saveGeometry())
            st.setValue('state', self.saveState())
            st.setValue('layout_version', LAYOUT_VERSION)
            st.setValue('snapshots', self.options.snapshots_wanted())
        except Exception:               # noqa: BLE001 - never block a close
            pass

    # --- odds and ends -------------------------------------------------------------
    def _zoom_step(self, delta):
        self.compare.zoom_step(delta)

    def _show_zoom(self, zoom):
        """Put the view's actual zoom in the toolbar box.

        The box is a READOUT as much as a control, and it was previously only
        ever written to by the user - so the wheel, a shortcut, or the view
        promoting itself left it stating something that was no longer true.
        No blockSignals needed: the box reports through `activated`, which a
        programmatic setCurrentIndex does not raise.
        """
        i = self.zoom.findData(zoom)
        if i >= 0:
            self.zoom.setCurrentIndex(i)

    def _hovered(self, x, y):
        self.hover.setText('' if x < 0 else '%d, %d' % (x, y))

    def _copy_command(self):
        s = self.options.to_settings()
        QApplication.clipboard().setText(
            s.command_line(script=runner.SCRIPT))
        self._say('command line copied to the clipboard')

    def _open_output(self):
        """This image's folder if it exists, else the root it would go in."""
        s = self.options.to_settings()
        out = runner.resolve(runner.job_dir(s))
        if not os.path.isdir(out):
            out = runner.resolve(s.out)
        if not os.path.isdir(out):
            self._say('%s does not exist yet - press Convert' % out,
                      theme.WARN)
            return
        # QDesktopServices would be the tidy way, but it silently does nothing
        # under some desktop sessions; the explicit opener at least fails aloud.
        try:
            if os.name == 'nt':
                os.startfile(out)                    # noqa: S606
            else:
                import subprocess
                subprocess.Popen(['xdg-open', out])  # noqa: S603,S607
        except Exception as exc:                     # noqa: BLE001 - shown
            self._say('could not open %s: %s' % (out, exc), theme.ERR)

    def _build_images_lst(self):
        """Scan a folder of .MAP/.NFO output and write its images.lst manifest.

        RUN IT ON THE STAGING FOLDER.  The keys are the 8.3 base names the
        viewer sees on the disk, so point this at the folder you build the ATR
        from - not necessarily the same as out/<image>/.
        """
        start = runner.resolve(self.options.to_settings().out)
        if not os.path.isdir(start):
            start = str(runner.CONVERTOR)
        where = QFileDialog.getExistingDirectory(
            self, 'Folder to index for images.lst', start)
        if not where:
            return
        try:
            path, count = imageslst.write(where)
        except Exception as exc:                      # noqa: BLE001 - shown
            self._show_text('images.lst failed', repr(exc))
            return
        self._say('%s - %d entr%s' % (path, count,
                                      'y' if count == 1 else 'ies'))

    def _say(self, text, colour=None):
        self.status.setText(text)
        self.status.setStyleSheet('color:%s;' % (colour or theme.TEXT).name())

    def _show_text(self, title, text):
        d = QDialog(self)
        d.setWindowTitle(title)
        d.resize(760, 420)
        e = QPlainTextEdit(text)
        e.setReadOnly(True)
        e.setFont(theme.label_font(8))
        e.setLineWrapMode(QPlainTextEdit.NoWrap)
        b = QDialogButtonBox(QDialogButtonBox.Close)
        b.rejected.connect(d.reject)
        b.accepted.connect(d.accept)
        lay = QVBoxLayout(d)
        lay.addWidget(e)
        lay.addWidget(b)
        d.exec()

    def _about(self):
        self._show_text('VBXE PAL Studio', ABOUT % (runner.SCRIPT,
                                                    self.scratch))

    # --- shutdown --------------------------------------------------------------------
    def closeEvent(self, ev):
        self._save_layout()
        self.worker.cancel()
        # Closing mid-run reaches neither _run_finished nor cancel(), so the
        # override cursor would be left on the stack.  Harmless once the
        # process exits - but not when the window is one of several, or when
        # the app is being embedded.
        self._set_busy_cursor(False)
        # The scratch directory is ours and holds nothing but overwritten
        # previews, so it goes without asking.  Failing to remove it is not
        # worth a dialog on the way out.
        shutil.rmtree(self.scratch, ignore_errors=True)
        ev.accept()


ABOUT = """VBXE PAL Studio

A front end for palettize4.py, which packs an image into four 256-entry
palettes switched per 8-pixel cell.

Preview runs the real converter into a scratch directory and shows the
{name}_preview.png it wrote, so what is on screen is byte for byte what
Convert will put on disk.  There is no second implementation of the packer
here that could drift away from the first one.

  converter : %s
  scratch   : %s

Keys
  F5          preview
  Ctrl+Enter  convert
  Esc         cancel a run
  Tab         flip source / converted
  SPACE       flip while held
  A / B       show source / converted
  Ctrl+0      fit,  Ctrl+= / Ctrl+-  zoom
  wheel       zoom at the cursor,  drag  pan

The two panes always share one zoom and one pan, so a flip shows you a
difference rather than a movement.
"""


def dark_palette(app):
    from PySide6.QtGui import QColor, QPalette
    p = QPalette()
    p.setColor(QPalette.Window, QColor('#1b1f25'))
    p.setColor(QPalette.WindowText, QColor('#cfd8dc'))
    p.setColor(QPalette.Base, QColor('#14171c'))
    p.setColor(QPalette.AlternateBase, QColor('#1b1f25'))
    p.setColor(QPalette.Text, QColor('#cfd8dc'))
    p.setColor(QPalette.Button, QColor('#232830'))
    p.setColor(QPalette.ButtonText, QColor('#cfd8dc'))
    p.setColor(QPalette.Highlight, QColor('#4dd0e1'))
    p.setColor(QPalette.HighlightedText, QColor('#10141a'))
    p.setColor(QPalette.ToolTipBase, QColor('#232830'))
    p.setColor(QPalette.ToolTipText, QColor('#cfd8dc'))
    p.setColor(QPalette.PlaceholderText, QColor('#607d8b'))
    app.setStyle('Fusion')
    app.setPalette(p)


def run(argv=None):
    import sys
    argv = list(sys.argv if argv is None else argv)
    app = QApplication(argv)
    app.setApplicationName('VBXE PAL Studio')
    app.setApplicationDisplayName('VBXE PAL Studio')
    dark_palette(app)
    initial = argv[1] if len(argv) > 1 else ''
    w = MainWindow(initial)
    w.show()
    return app.exec()
