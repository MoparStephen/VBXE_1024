"""compare.py - the source and the conversion, in register, with a flip key.

THE FLIP IS THE FEATURE.  Two pictures side by side tell you almost nothing
about a dither: your eye cannot hold enough of one to compare it with the other
across six inches of screen.  One picture that SWAPS in place, under the same
magnification, at the same pixel, turns the difference into motion - banding
that survived, grain that appeared, a block artifact that moved.  Hold SPACE
(or press A/B) and the pane alternates; the badge in the corner says which you
are looking at, because after four flips you will not know.

SIDE BY SIDE IS STILL HERE AND IS FOR A DIFFERENT QUESTION: framing.  --fit
cover crops and --fit fit letterboxes, and to see what a crop threw away you
need the whole original next to the whole result, not one on top of the other.

ONE SPLITTER, TWO MODES, NO REPARENTING.  Both views live in the splitter for
good, and flipping HIDES one rather than moving it - a splitter gives the
surviving child the full width by itself, which is exactly the flip.  The
obvious implementation instead moves the two views between a QSplitter and a
QStackedWidget, and it is quietly broken: a QStackedWidget explicitly hides
every page but the current one, that hidden state survives being reparented,
and QSplitter.addWidget will not show a widget that was explicitly hidden.  So
switching to side-by-side produced a splitter correctly holding two widgets,
both invisible, and an empty pane under a caption confidently saying "source
left, converted right".  Visibility IS the mode here; nothing moves.

BOTH VIEWS SHARE ONE ZOOM AND ONE PAN, wired through view_changed.  If they
could drift the flip would be worthless - it would be showing you a pan, not a
difference.
"""

from PySide6.QtCore import QPoint, Qt, QTimer, Signal
from PySide6.QtGui import QPainter
from PySide6.QtWidgets import QLabel, QSplitter, QVBoxLayout, QWidget

from . import theme
from .imageview import FIT, ZOOMS, ImageView

SIDE_BY_SIDE = 'side'
FLIP = 'flip'

#: The split when both are shown.  Even, because neither is the subject.
EVEN = [500, 500]

#: Auto-flip period until the toolbar says otherwise, in ms.
FLIP_MS = 500


class _Badge(ImageView):
    """An ImageView that says, in its own corner, which image it is showing.

    On the flip pane this is not decoration.  The images are meant to look
    nearly the same - that is what a good dither means - so without a label a
    flip becomes an argument with yourself about which one is on screen.
    """

    def __init__(self, label, colour, parent=None):
        ImageView.__init__(self, parent)
        self.label = label
        self.colour = colour
        self.show_badge = True

    def _placeholder(self):
        if self.label.lower().startswith('source'):
            return 'open an image to begin'
        return 'press Preview to convert'

    def paintEvent(self, ev):
        ImageView.paintEvent(self, ev)
        if not self.show_badge or not self.has_image():
            return
        p = QPainter(self)
        p.setFont(theme.label_font(9, bold=True))
        text = ' %s ' % self.label
        r = p.fontMetrics().boundingRect(text).adjusted(0, -2, 6, 2)
        r.moveTo(8, 8)
        p.fillRect(r, theme.BG)
        p.setPen(theme.pen(self.colour))
        p.drawRect(r)
        p.setPen(self.colour)
        p.drawText(r, Qt.AlignCenter, text)


class ComparePane(QWidget):
    """Source | result, or one of them at a time with a flip."""

    #: Image coordinates under the cursor, forwarded for the status bar.
    hovered = Signal(int, int)
    #: The effective zoom, whenever it changes for ANY reason - the wheel, a
    #: keyboard shortcut, a sync from the other view.  The toolbar's zoom box
    #: follows this; without it the box goes on claiming `fit` after the wheel
    #: has taken the view to 4x, and the two then disagree until one of them is
    #: touched again.
    viewChanged = Signal(int)

    def __init__(self, parent=None):
        QWidget.__init__(self, parent)
        self.source = _Badge('SOURCE', theme.SOURCE)
        self.result = _Badge('CONVERTED', theme.RESULT)
        self._syncing = False
        self._held = False              # SPACE is down
        self._showing_source = False    # which side the flip is on
        #: Attribute-cell width in image pixels, for the O-key column overlay.
        #: Set from the settings the result was made with, not the panel.
        self.cell = 8

        # T: flip on a timer, for a comparison that runs while your hands
        # are off the keyboard.
        self._auto = QTimer(self)
        self._auto.setInterval(FLIP_MS)
        self._auto.timeout.connect(self.flip)

        for a, b in ((self.source, self.result), (self.result, self.source)):
            a.view_changed.connect(
                lambda z, o, dst=b: self._sync(dst, z, o))
            a.hovered.connect(self.hovered)

        self.split = QSplitter(Qt.Horizontal)
        self.split.addWidget(self.source)
        self.split.addWidget(self.result)
        self.split.setSizes(EVEN)
        # A splitter will happily let you drag one child to nothing, which in
        # flip mode is indistinguishable from the bug this pane used to have.
        self.split.setChildrenCollapsible(False)

        self.hint = QLabel()
        self.hint.setStyleSheet(theme.caption_style())
        self.hint.setFont(theme.label_font(8))

        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(2)
        lay.addWidget(self.split, 1)
        lay.addWidget(self.hint)

        self.mode = FLIP
        self._apply()
        self.setFocusPolicy(Qt.StrongFocus)

    # --- content ---------------------------------------------------------------
    def set_source(self, img):
        self.source.set_image(img)
        self._apply()

    def set_result(self, img):
        self.result.set_image(img)
        # LAND ON THE RESULT, always.  A preview you have to press a key to see
        # is a preview that did not finish.
        self._showing_source = False
        self._apply()

    def clear_result(self):
        self.result.set_image(None)
        self.stop_auto()
        self._apply()

    def set_cell(self, cell):
        self.cell = max(1, int(cell or 8))
        # Held while a new result lands: follow its cell width.
        for v in (self.source, self.result):
            if v.grid:
                v.set_grid(self.cell)

    def set_grid(self, on):
        for v in (self.source, self.result):
            v.set_grid(self.cell if on else 0)

    # --- mode ------------------------------------------------------------------
    def set_mode(self, mode):
        self.mode = mode
        if mode != FLIP:
            self.stop_auto()
        self._apply()

    def _apply(self):
        """Visibility IS the mode.  See the module docstring."""
        if self.mode == SIDE_BY_SIDE:
            self.source.setVisible(True)
            self.result.setVisible(True)
            self.split.setSizes(EVEN)
        else:
            # With no result yet there is nothing to flip TO, so show the
            # source rather than an empty pane telling the user to press
            # Preview twice.
            show_source = self._showing_source or not self.result.has_image()
            self.source.setVisible(show_source)
            self.result.setVisible(not show_source)
        self._hint()

    def showing(self):
        """The view on screen in flip mode, or None when both are."""
        if self.mode == SIDE_BY_SIDE:
            return None
        return self.source if self.source.isVisible() else self.result

    def flip(self):
        if self.mode != FLIP or not self.result.has_image():
            return
        self._showing_source = not self._showing_source
        self._apply()

    # --- timed flip ------------------------------------------------------------
    def set_flip_interval(self, ms):
        self._auto.setInterval(max(50, int(ms)))
        self._hint()

    def flip_interval(self):
        return self._auto.interval()

    def auto_running(self):
        return self._auto.isActive()

    def toggle_auto(self):
        """Start or stop the timed flip.  Returns whether it is now running.

        Only in flip mode with a result: side by side has nothing to swap, and
        with no result a flip has nothing to swap TO.
        """
        if self._auto.isActive():
            self.stop_auto()
        elif self.mode == FLIP and self.result.has_image():
            self._auto.start()
            self._hint()
        return self._auto.isActive()

    def stop_auto(self):
        if self._auto.isActive():
            self._auto.stop()
            self._hint()

    def show_side(self, source):
        if self.mode != FLIP:
            return
        self._showing_source = bool(source)
        self._apply()

    # --- the shared view --------------------------------------------------------
    def _sync(self, other, zoom, offset):
        if self._syncing:
            return
        self._syncing = True
        other.set_view(zoom, offset)
        self._syncing = False
        self._hint()
        self.viewChanged.emit(zoom)

    def set_zoom(self, zoom):
        for v in (self.source, self.result):
            v.zoom = zoom
            if zoom == FIT:
                v.offset = QPoint(0, 0)
            v._sync_cursor()
            v.update()
        self._hint()
        self.viewChanged.emit(zoom)

    def zoom_step(self, delta):
        cur = self.source.zoom if self.source.zoom != FIT else 1
        try:
            i = ZOOMS.index(cur)
        except ValueError:
            i = 0
        i = max(0, min(len(ZOOMS) - 1, i + delta))
        self.set_zoom(ZOOMS[i])
        return ZOOMS[i]

    def fit(self):
        self.set_zoom(FIT)

    # --- the caption ------------------------------------------------------------
    def _hint(self):
        z = self.source.zoom
        zoom = 'fit' if z == FIT else '%dx' % z
        w, h = self.source.image_size()
        size = ('%dx%d' % (w, h)) if w else '-'
        if self.mode == FLIP:
            if self.result.has_image():
                side = ('source' if self.showing() is self.source
                        else 'converted')
                if self._auto.isActive():
                    what = ('showing %s - auto-flipping every %gs, T to stop'
                            % (side, self._auto.interval() / 1000.0))
                else:
                    what = ('showing %s - hold SPACE or press A / B to flip, '
                            'T to auto-flip' % side)
            else:
                what = ('showing source - press Preview to have something to '
                        'flip to')
        else:
            what = 'source left, converted right - both zoom and pan together'
        self.hint.setText('%s   |   %s   |   zoom %s   |   drag to pan, '
                          'wheel to zoom, O for cell columns'
                          % (what, size, zoom))

    # --- keys --------------------------------------------------------------------
    def keyPressEvent(self, ev):
        # HELD, NOT TOGGLED, for space: the comparison is a flicker, and letting
        # go should put you back where you were rather than leaving you unsure
        # which one is up.  A and B are the sticky form for a longer look.
        # A manual pick always beats the timer: stop it, or the next tick
        # would take the side you just chose straight away again.
        if ev.key() == Qt.Key_Space and not ev.isAutoRepeat():
            self.stop_auto()
            self._held = True
            self.show_side(True)
            ev.accept()
            return
        if ev.key() == Qt.Key_A:
            self.stop_auto()
            self.show_side(True)
            ev.accept()
            return
        if ev.key() == Qt.Key_B:
            self.stop_auto()
            self.show_side(False)
            ev.accept()
            return
        if ev.key() == Qt.Key_T:
            if not ev.isAutoRepeat():
                self.toggle_auto()
            ev.accept()
            return
        # TOGGLED, unlike SPACE: hunting seams takes both hands on the zoom
        # and pan, so the grid stays up until O is pressed again.
        if ev.key() == Qt.Key_O:
            if not ev.isAutoRepeat():
                self.set_grid(not self.result.grid)
            ev.accept()
            return
        QWidget.keyPressEvent(self, ev)

    def keyReleaseEvent(self, ev):
        if ev.key() == Qt.Key_Space and not ev.isAutoRepeat() and self._held:
            self._held = False
            self.show_side(False)
            ev.accept()
            return
        QWidget.keyReleaseEvent(self, ev)
