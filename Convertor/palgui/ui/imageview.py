"""imageview.py - a QImage magnified with hard pixel edges, pannable.

NEAREST-NEIGHBOUR, ALWAYS, AND THAT IS THE WHOLE POINT OF THIS WIDGET.  The
settings this GUI exists to tune - dither algorithm, dither strength - produce
a GRAIN, and a smooth scale is precisely a filter for removing grain.  Judging
`blue` against `floyd` through Qt.SmoothTransformation would show two identical
blurs.  Every draw here is Qt.FastTransformation and every zoom above 1 is an
INTEGER, because a fractional nearest-neighbour scale invents a moire of its
own that looks like dither and is not.

ZOOM AND PAN ARE STATE THIS WIDGET DOES NOT OWN.  compare.py drives two of
these from one transform so the source and the result cannot drift out of
register - flipping between two views of the same pixel is the comparison, and
it only works if they are the same pixel.  Hence view_changed, and hence
set_view() taking values rather than adjusting its own.
"""

from PySide6.QtCore import QPoint, QRect, Qt, Signal
from PySide6.QtGui import QPainter, QPixmap
from PySide6.QtWidgets import QSizePolicy, QWidget

from . import theme

#: The integer steps the zoom control offers.  1 is where you check framing;
#: 4 and up is where the dither grain is actually legible.
ZOOMS = (1, 2, 3, 4, 6, 8, 12, 16)

#: Sentinel zoom: scale to fit the widget, recomputed on every resize.
FIT = 0


class ImageView(QWidget):
    """One image, magnified, with a shareable zoom/pan."""

    #: (zoom, offset) whenever the user changed them here, so a partner view
    #: can follow.  Not emitted by set_view(), or the two would ping-pong.
    view_changed = Signal(int, QPoint)
    #: Image coordinates under the cursor, or (-1, -1) when outside.
    hovered = Signal(int, int)

    def __init__(self, parent=None):
        QWidget.__init__(self, parent)
        self._pm = None
        self.zoom = FIT
        self.offset = QPoint(0, 0)      # top-left of the image, in image px
        self._drag = None
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMinimumSize(160, 120)
        self.setMouseTracking(True)
        self.setCursor(Qt.ArrowCursor)
        self.setAutoFillBackground(False)

    # --- content -------------------------------------------------------------
    def set_image(self, img):
        """`img` is a QImage or None.  Keeps the current zoom and pan.

        KEEPING THE VIEW ACROSS A NEW IMAGE IS THE FEATURE.  Preview a dither,
        zoom to 8x on a gradient, change the strength, preview again: the
        second result has to land under the same magnifying glass or there is
        nothing to compare.
        """
        self._pm = QPixmap.fromImage(img) if img is not None else None
        self._sync_cursor()
        self.update()

    def has_image(self):
        return self._pm is not None and not self._pm.isNull()

    def image_size(self):
        if not self.has_image():
            return (0, 0)
        return (self._pm.width(), self._pm.height())

    # --- the view ------------------------------------------------------------
    def set_view(self, zoom, offset):
        """Adopt someone else's zoom and pan.  Emits nothing - see the class
        docstring."""
        self.zoom = zoom
        self.offset = QPoint(offset)
        self._sync_cursor()
        self.update()

    def set_zoom(self, zoom, anchor=None):
        """Change zoom, keeping `anchor` (a widget point) over the same pixel.

        Without the anchor, zooming in at 16x walks the thing you were looking
        at off the screen, and you spend the zoom hunting for it again.
        """
        if anchor is not None and self.has_image():
            before = self.to_image(anchor)
        self.zoom = zoom
        if anchor is not None and self.has_image():
            after = self.to_image(anchor)
            self.offset += QPoint(before.x() - after.x(),
                                  before.y() - after.y())
        self._clamp()
        self._sync_cursor()
        self.update()
        self.view_changed.emit(self.zoom, self.offset)

    def scale(self):
        """The magnification actually in force, honouring FIT."""
        if not self.has_image():
            return 1.0
        if self.zoom != FIT:
            return float(self.zoom)
        w, h = self.image_size()
        return min(self.width() / float(w), self.height() / float(h))

    def _clamp(self):
        """Keep at least a little of the image on screen.

        Not a hard clamp to the edges: at 16x you often WANT the corner pixel
        centred, with grey around it.  This only stops a pan from throwing the
        picture away entirely.
        """
        if not self.has_image():
            return
        w, h = self.image_size()
        self.offset.setX(max(-w + 1, min(w - 1, self.offset.x())))
        self.offset.setY(max(-h + 1, min(h - 1, self.offset.y())))

    def fit(self):
        self.zoom = FIT
        self.offset = QPoint(0, 0)
        self._sync_cursor()
        self.update()
        self.view_changed.emit(self.zoom, self.offset)

    def pannable(self):
        """Is there anywhere to pan TO?

        NOT AT FIT, EVER: fit means the whole image is on screen by
        construction, so a drag has nothing to reveal.  This used to promote
        the view to 1:1 on the first drag instead - a hidden zoom that left the
        toolbar's zoom box still reading `fit` while the caption underneath
        said `1x`, and that could only be undone by picking some other zoom and
        coming back.  A gesture that silently changes a setting the user can
        see is worse than a gesture that does nothing.
        """
        return self.has_image() and self.zoom != FIT

    def _sync_cursor(self):
        """An open hand only where the hand can actually do something."""
        self.setCursor(Qt.OpenHandCursor if self.pannable()
                       else Qt.ArrowCursor)

    # --- coordinates ----------------------------------------------------------
    def _origin(self):
        """Where image pixel (0,0) lands, in widget coordinates."""
        if not self.has_image():
            return QPoint(0, 0)
        w, h = self.image_size()
        k = self.scale()
        if self.zoom == FIT:
            return QPoint(int((self.width() - w * k) / 2),
                          int((self.height() - h * k) / 2))
        # Centred on the panned position rather than pinned to the corner, so
        # an image smaller than the pane sits in the middle of it.
        cx = self.width() / 2.0 - (self.offset.x() + w / 2.0) * k
        cy = self.height() / 2.0 - (self.offset.y() + h / 2.0) * k
        return QPoint(int(cx), int(cy))

    def to_image(self, pt):
        """Widget point -> image point.  May be outside the image."""
        o = self._origin()
        k = self.scale() or 1.0
        return QPoint(int((pt.x() - o.x()) // k), int((pt.y() - o.y()) // k))

    # --- painting -------------------------------------------------------------
    def paintEvent(self, _ev):
        p = QPainter(self)
        p.fillRect(self.rect(), theme.CANVAS)
        if not self.has_image():
            p.setPen(theme.TEXT_DIM)
            p.setFont(theme.label_font(9))
            p.drawText(self.rect(), Qt.AlignCenter, self._placeholder())
            return
        w, h = self.image_size()
        k = self.scale()
        o = self._origin()
        dest = QRect(o.x(), o.y(), max(1, int(w * k)), max(1, int(h * k)))

        # FastTransformation on the way up (hard pixel edges - the whole point)
        # and on the way down too: a fit-to-window view is for framing, and a
        # smooth downscale there would show a grain the hardware will not.
        p.setRenderHint(QPainter.SmoothPixmapTransform, False)
        p.drawPixmap(dest, self._pm)
        p.setPen(theme.pen(theme.FRAME))
        p.drawRect(dest.adjusted(-1, -1, 0, 0))

    def _placeholder(self):
        return 'no image'

    # --- gestures --------------------------------------------------------------
    def mousePressEvent(self, ev):
        if ev.button() == Qt.LeftButton and self.pannable():
            self._drag = (ev.position().toPoint(), QPoint(self.offset))
            self.setCursor(Qt.ClosedHandCursor)

    def mouseMoveEvent(self, ev):
        pt = ev.position().toPoint()
        if self._drag is not None:
            start, base = self._drag
            k = self.scale() or 1.0
            self.offset = QPoint(base.x() - int((pt.x() - start.x()) / k),
                                 base.y() - int((pt.y() - start.y()) / k))
            self._clamp()
            self.update()
            self.view_changed.emit(self.zoom, self.offset)
            return
        if self.has_image():
            ip = self.to_image(pt)
            w, h = self.image_size()
            if 0 <= ip.x() < w and 0 <= ip.y() < h:
                self.hovered.emit(ip.x(), ip.y())
            else:
                self.hovered.emit(-1, -1)

    def mouseReleaseEvent(self, ev):
        if ev.button() == Qt.LeftButton:
            self._drag = None
            self._sync_cursor()

    def leaveEvent(self, _ev):
        self.hovered.emit(-1, -1)

    def wheelEvent(self, ev):
        """Wheel steps through ZOOMS, anchored at the cursor."""
        if not self.has_image():
            return
        delta = ev.angleDelta().y()
        if not delta:
            return
        cur = self.zoom if self.zoom != FIT else 1
        try:
            i = ZOOMS.index(cur)
        except ValueError:
            i = 0
        i = max(0, min(len(ZOOMS) - 1, i + (1 if delta > 0 else -1)))
        self.set_zoom(ZOOMS[i], anchor=ev.position().toPoint())
        ev.accept()
