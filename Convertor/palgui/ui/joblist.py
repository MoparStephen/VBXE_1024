"""joblist.py - the batch queue, as a table you can read across.

THE COLUMNS ARE A COMPARISON, NOT A LOG.  Source, then the three settings that
actually change the answer (resize, dither, bias), then the result.  Queue one
image four times with four dithers and the table becomes the experiment: four
rows, same source, four colour counts to read down.  That is the reason the
queue exists at all - within-image comparison is what the flip pane does, and
across a SET is what a table does.

RUNS ONE AT A TIME, THROUGH THE SAME WORKER THE PREVIEW USES.  Not for
simplicity: palettize4 is numpy-heavy and an error-diffusion dither is serial
Python, so four at once on four cores would each be slower and the machine
would be unusable meanwhile.  One at a time also means Cancel means something.

SELECTING A ROW LOADS ITS SETTINGS BACK INTO THE PANEL, which makes the queue a
history as well as a plan: run six variants, click down the list, and the
options panel walks through what each one was.

PREVIEW ALL IS THE ONE YOU WANT FOR ONE IMAGE.  Run all CONVERTS, and a
conversion is named after its image - so fifteen jobs on one picture write the
same eleven filenames fifteen times and you are left with the last one.  Preview
all keeps a numbered snapshot of each instead, which is what fills a previews
folder you can then walk.  The status line names the collision before you press
anything rather than after; see jobs.Queue.collisions().
"""

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (QAbstractItemView, QHBoxLayout, QHeaderView,
                               QLabel, QMessageBox, QProgressBar, QPushButton,
                               QTableWidget, QTableWidgetItem, QVBoxLayout,
                               QWidget)

from .. import jobs
from . import theme

#: `fit` rather than `resize`: the size is fixed at 320x240 for every job,
#: and a column identical on every row is a column that costs width and
#: says nothing.  How the source is FITTED into that size still varies.
COLUMNS = ('source', 'name', 'fit', 'dither', 'bias', 'result')


class JobList(QWidget):
    """A table over a jobs.Queue, plus the buttons that edit it."""

    #: The user picked a row; the window loads its settings into the panel.
    selected = Signal(object)
    #: Add / update using whatever the options panel currently holds.
    add_requested = Signal()
    update_requested = Signal(int)
    add_files_requested = Signal()
    #: Run every pending job.
    run_requested = Signal()
    #: Run every job as a preview, keeping a numbered snapshot of each.
    preview_requested = Signal()
    stop_requested = Signal()
    #: Point the whole queue at a different image.
    retarget_requested = Signal()
    save_requested = Signal()
    load_requested = Signal()

    def __init__(self, queue, parent=None):
        QWidget.__init__(self, parent)
        self.queue = queue
        #: row -> the target it shares with another row.  Rebuilt on refresh.
        self._clashing = {}

        self.table = QTableWidget(0, len(COLUMNS))
        self.table.setHorizontalHeaderLabels(list(COLUMNS))
        self.table.verticalHeader().hide()
        self.table.setFont(theme.label_font(8))
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SingleSelection)
        self.table.setAlternatingRowColors(True)
        h = self.table.horizontalHeader()
        for i in range(len(COLUMNS) - 1):
            h.setSectionResizeMode(i, QHeaderView.ResizeToContents)
        h.setSectionResizeMode(len(COLUMNS) - 1, QHeaderView.Stretch)
        self.table.itemSelectionChanged.connect(self._selection)

        self.progress = QProgressBar()
        self.progress.setTextVisible(True)
        self.progress.hide()

        self.status = QLabel('the queue is empty')
        self.status.setFont(theme.label_font(8))
        self.status.setStyleSheet(theme.caption_style())

        self.b_add = self._button('Add', 'Queue the current settings as a new '
                                  'job.  Queue the same image several times '
                                  'with different dithers and the table becomes '
                                  'the comparison.')
        self.b_files = self._button('Add files...',
                                    'Queue several images at once, each with a '
                                    'copy of the current settings and its own '
                                    'file name as the output base name.')
        self.b_retarget = self._button(
            'Retarget...',
            'Point every job in the queue at a different image, clearing each '
            'job\'s output name so the new file\'s own name is used.\n\n'
            'This is what makes a saved queue a script: design fifteen '
            'variants once, then run the same fifteen over any picture.')
        self.b_update = self._button('Update',
                                     'Write the current settings back into the '
                                     'selected row.')
        self.b_remove = self._button('Remove', 'Drop the selected job.')
        self.b_clear = self._button(
            'Clear', 'Empty the queue, after a Yes / No.  Nothing on disk is '
            'touched - Save... first if you want the jobs back later.')
        self.b_up = self._button('Up', 'Move the selected job earlier.')
        self.b_down = self._button('Down', 'Move the selected job later.')
        self.b_save = self._button(
            'Save...', 'Write this queue to a .json file.  It records the '
            'jobs, not their results - a saved queue is a plan you can load, '
            'retarget and run again.')
        self.b_load = self._button('Load...', 'Replace this queue with one '
                                   'from a .json file.')
        self.b_preview = self._button(
            'Preview all',
            'Run every job as a PREVIEW, keeping a numbered snapshot of each '
            'in out/<image>/previews/.\n\n'
            'This is the one to use for comparing variants of a single image: '
            'Run all converts, and every conversion of one picture writes the '
            'same filenames, so fifteen jobs would leave you with the last '
            'one.  Snapshots are numbered, so all fifteen survive - and the '
            'Previews panel opens on them when the queue finishes.')
        self.b_run = self._button('Run all',
                                  'Run every pending job in order, one at a '
                                  'time, each into its own output directory.')
        self.b_stop = self._button('Stop', 'Stop after killing the running job. '
                                   'Jobs already done keep their results.')
        self.b_stop.setEnabled(False)

        self.b_add.clicked.connect(self.add_requested)
        self.b_files.clicked.connect(self.add_files_requested)
        self.b_update.clicked.connect(
            lambda: self.update_requested.emit(self.current_row()))
        self.b_remove.clicked.connect(self._remove)
        self.b_clear.clicked.connect(self._clear)
        self.b_up.clicked.connect(lambda: self._move(-1))
        self.b_down.clicked.connect(lambda: self._move(1))
        self.b_run.clicked.connect(self.run_requested)
        self.b_preview.clicked.connect(self.preview_requested)
        self.b_stop.clicked.connect(self.stop_requested)
        self.b_retarget.clicked.connect(self.retarget_requested)
        self.b_save.clicked.connect(self.save_requested)
        self.b_load.clicked.connect(self.load_requested)

        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        for b in (self.b_add, self.b_files, self.b_retarget, self.b_update,
                  self.b_remove, self.b_clear, self.b_up, self.b_down):
            row.addWidget(b)
        row.addStretch(1)
        for b in (self.b_save, self.b_load, self.b_preview, self.b_run,
                  self.b_stop):
            row.addWidget(b)
        bar = QWidget()
        bar.setLayout(row)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(4, 4, 4, 4)
        lay.setSpacing(4)
        lay.addWidget(bar)
        lay.addWidget(self.table, 1)
        lay.addWidget(self.progress)
        lay.addWidget(self.status)
        self.refresh()

    def _button(self, text, tip):
        b = QPushButton(text)
        b.setToolTip(tip)
        return b

    # --- the table ---------------------------------------------------------------
    def current_row(self):
        rows = self.table.selectionModel().selectedRows()
        return rows[0].row() if rows else -1

    def refresh(self, keep=None):
        keep = self.current_row() if keep is None else keep
        self._clashing = {}
        for target, rows in self.queue.collisions():
            for r in rows:
                self._clashing[r] = target
        self.table.blockSignals(True)
        self.table.setRowCount(0)
        for job in self.queue:
            s = job.settings
            self._append((
                job.source(),
                s.effective_name(),
                s.fit,
                s.dither if s.dither != 'none' else '-',
                '%.2f' % s.effective_bias(),
                job.summary(),
            ), job)
        self.table.blockSignals(False)
        if 0 <= keep < self.table.rowCount():
            self.table.selectRow(keep)
        self._status()

    def _append(self, values, job):
        r = self.table.rowCount()
        self.table.insertRow(r)
        for c, v in enumerate(values):
            item = QTableWidgetItem(str(v))
            if c == len(values) - 1:
                item.setForeground(self._result_colour(job))
                note = job.note()
                if note:
                    item.setToolTip(note)
                    # A run that "worked" but whose dither did nothing is the
                    # one result you must not read as a plain success.
                    item.setForeground(theme.WARN)
            elif c == 0:
                item.setToolTip(job.settings.input)
            elif c == 1 and r in self._clashing:
                item.setForeground(theme.WARN)
                item.setToolTip(
                    'Converting this queue writes %s more than once - these '
                    'jobs would overwrite each other.  Preview all keeps them '
                    'all, numbered, under previews/.' % self._clashing[r])
            self.table.setItem(r, c, item)

    def _result_colour(self, job):
        if job.state == jobs.FAILED:
            return theme.ERR
        if job.state == jobs.RUNNING:
            return theme.ACCENT
        if job.state == jobs.DONE:
            return (theme.OK if (job.stats or {}).get('lossless')
                    else theme.TEXT)
        return theme.TEXT_DIM

    def _status(self):
        """The counts, and the warning that matters most before you press Run.

        A COLLISION IS THE ONE THING THE TABLE CANNOT SHOW BY ITSELF.  Four
        rows differing only in `dither` look like four results; converting
        them produces one, because a conversion is named after its image.
        Saying so here means reading it while you are still building the
        queue, rather than working it out from a folder afterwards.
        """
        done, failed, total = self.queue.counts()
        if not total:
            self.status.setText('the queue is empty - Add puts the current '
                                'settings in it')
            return
        bits = ['%d job%s' % (total, '' if total == 1 else 's')]
        if done:
            bits.append('%d done' % done)
        if failed:
            bits.append('%d failed' % failed)
        clash = self.queue.collisions()
        if clash:
            worst = max(len(rows) for _t, rows in clash)
            bits.append('%d jobs write to the same output - Run all would '
                        'leave only the last; use Preview all to keep them '
                        'all' % worst)
            self.status.setStyleSheet(theme.caption_style(theme.WARN))
        else:
            self.status.setStyleSheet(theme.caption_style())
        self.status.setText(', '.join(bits))

    # --- editing --------------------------------------------------------------------
    def _selection(self):
        r = self.current_row()
        if 0 <= r < len(self.queue):
            self.selected.emit(self.queue[r])

    def _remove(self):
        r = self.current_row()
        if r >= 0:
            self.queue.remove(r)
            self.refresh(keep=min(r, len(self.queue) - 1))

    def _clear(self):
        """Empty the queue.  ASKS FIRST: an unsaved queue is fifteen jobs
        of settings with no other copy anywhere."""
        if not len(self.queue):
            return
        n = len(self.queue)
        if QMessageBox.question(
                self, 'Clear the queue',
                'Remove all %d job%s from the queue?  Output already on '
                'disk is not touched.' % (n, '' if n == 1 else 's'),
                QMessageBox.Yes | QMessageBox.No,
                QMessageBox.No) != QMessageBox.Yes:
            return
        self.queue.clear()
        self.refresh()

    def _move(self, delta):
        r = self.current_row()
        if r >= 0:
            self.refresh(keep=self.queue.move(r, delta))

    # --- run state --------------------------------------------------------------------
    def set_running(self, running, index=0):
        self.b_run.setEnabled(not running)
        self.b_stop.setEnabled(running)
        for b in (self.b_add, self.b_files, self.b_retarget, self.b_update,
                  self.b_remove, self.b_clear, self.b_up, self.b_down,
                  self.b_save,
                  self.b_load, self.b_preview):
            b.setEnabled(not running)
        self.progress.setVisible(running)
        if running:
            self.progress.setRange(0, max(1, len(self.queue)))
            self.progress.setValue(index)
            self.progress.setFormat('%d of %d' % (index, len(self.queue)))
