"""statspane.py - what the run actually did, in the order you want to ask it.

A RENDERER, NOT AN AUTHOR.  The rows, their order and their wording come from
palgui/summary.py; this file turns them into a QTableWidget and turns semantic
tones into theme colours.  The same rows are rendered as plain text into the
Preview_NN.txt beside a saved snapshot, which is the point: a summary you read
on disk next week has to match the pane you were looking at when you saved it.

WHAT IS STILL DECIDED HERE is presentation only - that a warning is amber, that
a note wraps in column 1, that the key column hugs its contents.

THE RECIPE IS SHOWN BACK.  A preview is worth nothing if you cannot tell which
settings produced it - especially two minutes later when you have moved three
sliders.  The `run with` block is the command line for the result on screen,
not for the controls as they now stand.
"""

from PySide6.QtWidgets import (QAbstractItemView, QHeaderView, QPlainTextEdit,
                               QTableWidget, QTableWidgetItem, QTabWidget)

from .. import summary
from . import theme


#: summary.py speaks in tones; the pane is where they become colours.  Keeping
#: the mapping here is what lets summary.py stay importable without PySide6.
TONES = {
    summary.OK: 'OK',
    summary.WARN: 'WARN',
    summary.ERR: 'ERR',
}


def _colour(tone):
    if tone is None:
        return None
    if isinstance(tone, tuple):             # ('palette', index)
        return theme.PALETTE_IDS[tone[1] % len(theme.PALETTE_IDS)]
    return getattr(theme, TONES[tone])


class StatsPane(QTabWidget):
    """The right dock: the numbers, then palettize4's own text report."""

    def __init__(self, parent=None):
        QTabWidget.__init__(self, parent)
        self.table = QTableWidget(0, 2)
        self.table.setHorizontalHeaderLabels(['', ''])
        self.table.horizontalHeader().hide()
        self.table.verticalHeader().hide()
        self.table.setShowGrid(False)
        self.table.setAlternatingRowColors(True)
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.setSelectionMode(QAbstractItemView.NoSelection)
        self.table.setWordWrap(True)
        self.table.horizontalHeader().setSectionResizeMode(
            0, QHeaderView.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(
            1, QHeaderView.Stretch)
        self.table.setFont(theme.label_font(8))

        self.report = QPlainTextEdit()
        self.report.setReadOnly(True)
        self.report.setFont(theme.label_font(8))
        self.report.setLineWrapMode(QPlainTextEdit.NoWrap)

        self.addTab(self.table, 'Result')
        self.addTab(self.report, 'Report')
        self.clear()

    # --- content ---------------------------------------------------------------
    def clear(self):
        self.table.setRowCount(0)
        self._row('', 'no run yet - press Preview')
        self.report.setPlainText('')

    def set_stats(self, settings, stats, command=''):
        """Render summary.rows() - see that module for why it is not inline.

        THE TABLE IS A RENDERER, NOT AN AUTHOR.  Every word and every ordering
        decision here now comes from palgui/summary.py, which the saved
        Preview_NN.txt renders too, so the pane and the file cannot end up
        describing the same run differently.
        """
        self.table.setRowCount(0)
        if not stats:
            self.clear()
            return
        for row in summary.rows(settings, stats, command=command):
            if row[0] == 'head':
                self._head(row[1])
            elif row[0] == 'row':
                self._row(row[1], row[2], _colour(row[3]))
            else:
                self._note(row[1])
        self.table.resizeRowsToContents()

    def set_note(self, text):
        """One sentence where the table would be.

        NOT THE SAME AS clear().  "no run yet - press Preview" is wrong for a
        snapshot taken before summaries carried their numbers: that run DID
        happen, and its numbers are sitting in the Report tab in prose.  An
        empty-looking table under a picture reads as a failure.
        """
        self.table.setRowCount(0)
        self._row('', text)

    def set_report(self, text):
        self.report.setPlainText(text or '')

    # --- rows -------------------------------------------------------------------
    def _head(self, text):
        r = self.table.rowCount()
        self.table.insertRow(r)
        item = QTableWidgetItem(text.upper())
        item.setForeground(theme.ACCENT)
        item.setFont(theme.label_font(8, bold=True))
        self.table.setItem(r, 0, item)
        self.table.setItem(r, 1, QTableWidgetItem(''))

    def _row(self, key, value, colour=None):
        r = self.table.rowCount()
        self.table.insertRow(r)
        k = QTableWidgetItem(key)
        k.setForeground(theme.TEXT_DIM)
        v = QTableWidgetItem(str(value))
        v.setForeground(colour or theme.TEXT)
        self.table.setItem(r, 0, k)
        self.table.setItem(r, 1, v)

    def _note(self, text):
        """A wrapped sentence in the value column - advice, not a datum.

        IN COLUMN 1, NOT SPANNED ACROSS BOTH.  Column 0 is ResizeToContents so
        that the keys line up tightly, and a spanned row counts as content in
        column 0 - so one long sentence dragged the key column out to the full
        width of the dock and squeezed every actual VALUE off the right-hand
        edge.  The whole table read as a list of labels with no numbers.
        """
        r = self.table.rowCount()
        self.table.insertRow(r)
        item = QTableWidgetItem(text)
        item.setForeground(theme.TEXT_DIM)
        self.table.setItem(r, 0, QTableWidgetItem(''))
        self.table.setItem(r, 1, item)
