"""reviewpane.py - a folder of saved previews, as a list you can step through.

THE QUEUE IS A PLAN; THIS IS A RECORD.  They look alike and they are not the
same thing: a queue row is a run that has not happened yet and can be edited,
reordered and run, while a row here is a picture that already exists on disk
and cannot be changed by anything you do in this window.  Keeping them in one
table would have meant a Run button that has to refuse half its rows and a
Remove button that either deletes files or does not, depending which kind of
row you picked - so they are two panes, and each one means exactly one thing.

SELECTING A ROW PUTS ITS SETTINGS BACK IN THE PANEL, which is the entire point.
Stepping through thirty previews is only useful if, when one of them wins, the
options that produced it are already loaded and Convert is the next click.

PREV AND NEXT LIVE ON THE TOOLBAR TOO.  Comparing pictures means looking at the
picture, and a button you have to find in a dock at the bottom of the window
pulls your eye off the thing you are judging on every single step.  The pair
here are for when the pane has focus; ui/main.py wires the same movement to the
toolbar and to a shortcut.
"""

import os

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (QAbstractItemView, QHBoxLayout, QHeaderView,
                               QLabel, QPushButton, QTableWidget,
                               QTableWidgetItem, QVBoxLayout, QWidget)

from .. import review
from . import theme

#: `dither` and `bias` because those are what an afternoon of previews varies.
#: The source is not a column: a previews folder belongs to ONE image, so it
#: would be the same string on every row.
COLUMNS = ('preview', 'dither', 'bias', 'result')


class ReviewPane(QWidget):
    """A table over review.shots(), plus the buttons that walk it."""

    #: The user landed on a row; the window loads its picture and settings.
    selected = Signal(object)
    #: Ask the window for a folder - it owns the file dialog and the default.
    open_requested = Signal()

    def __init__(self, parent=None):
        QWidget.__init__(self, parent)
        self.shots = []
        self._dir = ''

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

        self.status = QLabel('')
        self.status.setFont(theme.label_font(8))
        self.status.setStyleSheet(theme.caption_style())

        self.b_open = self._button(
            'Open folder...',
            'Read a previews folder - out/<image>/previews - back in.  Every '
            'Preview_NN pair becomes a row: its picture goes in the middle '
            'pane and its settings go back into the options panel, so the one '
            'you like is one Convert away.')
        self.b_prev = self._button('< prev', 'The previous preview.')
        self.b_next = self._button('next >', 'The next preview.')
        self.b_clear = self._button(
            'Clear', 'Empty this list.  Nothing on disk is touched - these '
            'rows are files, not jobs.')
        self.b_open.clicked.connect(self.open_requested)
        self.b_prev.clicked.connect(lambda: self.step(-1))
        self.b_next.clicked.connect(lambda: self.step(1))
        self.b_clear.clicked.connect(self.clear)

        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.addWidget(self.b_open)
        row.addWidget(self.b_prev)
        row.addWidget(self.b_next)
        row.addStretch(1)
        row.addWidget(self.b_clear)
        bar = QWidget()
        bar.setLayout(row)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(4, 4, 4, 4)
        lay.setSpacing(4)
        lay.addWidget(bar)
        lay.addWidget(self.table, 1)
        lay.addWidget(self.status)
        self.refresh()

    def _button(self, text, tip):
        b = QPushButton(text)
        b.setToolTip(tip)
        return b

    # --- contents ------------------------------------------------------------
    def load(self, directory):
        """Read a folder.  Returns how many pairs were found.

        SELECTS THE FIRST ROW, which emits `selected` and therefore puts a
        picture on screen.  Loading a folder and being shown an empty pane
        until you happen to click something is a feature that looks broken.
        """
        self.shots = review.shots(directory)
        self._dir = directory
        self.refresh()
        if self.shots:
            self.table.selectRow(0)
        return len(self.shots)

    def clear(self):
        self.shots = []
        self._dir = ''
        self.refresh()

    def directory(self):
        return self._dir

    def count(self):
        return len(self.shots)

    def current(self):
        r = self.current_row()
        return self.shots[r] if 0 <= r < len(self.shots) else None

    def current_row(self):
        rows = self.table.selectionModel().selectedRows()
        return rows[0].row() if rows else -1

    def step(self, delta):
        """Move the selection, and stop at the ends rather than wrapping.

        WRAPPING WOULD LOSE YOUR PLACE.  Thirty-one previews all of the same
        face look much alike; rolling silently from the last to the first is
        how you end up comparing 31 against 01 believing they are 31 and 32.
        """
        if not self.shots:
            return False
        r = self.current_row()
        n = min(max(0 if r < 0 else r + delta, 0), len(self.shots) - 1)
        if n == r:
            return False
        self.table.selectRow(n)
        return True

    def refresh(self):
        self.table.blockSignals(True)
        self.table.setRowCount(0)
        for shot in self.shots:
            self._append(shot)
        self.table.blockSignals(False)
        self._status()
        for b in (self.b_prev, self.b_next, self.b_clear):
            b.setEnabled(bool(self.shots))

    def _append(self, shot):
        r = self.table.rowCount()
        self.table.insertRow(r)
        values = (shot.label(), shot.dither(), shot.bias(), shot.result())
        for c, v in enumerate(values):
            item = QTableWidgetItem(str(v))
            if c == len(values) - 1 and not shot.stats:
                # Not a failure - a file written before summaries carried
                # their numbers.  Dim, so it reads as absent rather than bad.
                item.setForeground(theme.TEXT_DIM)
            elif c == 0:
                item.setToolTip(shot.png)
            self.table.setItem(r, c, item)

    def _status(self):
        if not self._dir:
            self.status.setText('no previews loaded - Open folder... reads an '
                                'out/<image>/previews directory')
            return
        where = os.path.basename(os.path.dirname(self._dir)) or self._dir
        if not self.shots:
            self.status.setText('%s holds no Preview_NN pairs' % self._dir)
            return
        older = sum(1 for s in self.shots if not s.stats)
        self.status.setText(
            '%d preview%s of %s%s'
            % (len(self.shots), '' if len(self.shots) == 1 else 's', where,
               ' - %d written before summaries carried their numbers'
               % older if older else ''))

    # --- selection ------------------------------------------------------------
    def _selection(self):
        shot = self.current()
        if shot is not None:
            self.selected.emit(shot)
