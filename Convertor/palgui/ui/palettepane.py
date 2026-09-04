"""palettepane.py - the four palettes as they came out, read off the .pal files.

WHERE THE COLOURS WENT IS A DIFFERENT QUESTION FROM HOW MANY THERE ARE.  The
stats pane says palette 2 holds 254 colours; this says they are all browns,
which is the thing that explains a blocky sky.  Reading the four 768-byte .pal
files back is also a free end-to-end check that the data half of the run is
sane - if the swatch sheet looks right, the bytes the Atari will load are right.

READ FROM {name}#.pal, NOT FROM {name}_palettes.png.  palettize4 writes a
swatch sheet too, but it is a picture of the palettes at a fixed 12px per slot;
parsing the actual files means this pane can lay them out at whatever width the
dock happens to be, and it means an unreadable .pal shows up HERE rather than
three weeks later on the hardware.

UNUSED SLOTS ARE DRAWN AS A HATCH, NOT AS BLACK.  A palette that filled 254 of
255 and one that filled 12 both end in a run of (0,0,0), and on a dark theme
those two look identical - which is exactly the difference you opened this pane
to see.
"""

from PySide6.QtCore import QRect, Qt
from PySide6.QtGui import QColor, QPainter
from PySide6.QtWidgets import QSizePolicy, QWidget

from . import theme

#: Bytes in one palette file: 256 entries x RGB.
PAL_BYTES = 768

#: Height of the strip under each palette's swatches that carries its label.
#: SIZED FOR THE TEXT, not for a gap: at 6px the caption was drawn straight
#: over the top row of the palette below it.
GUTTER = 14


class PalettePane(QWidget):
    """A row per palette, a cell per slot."""

    def __init__(self, parent=None):
        QWidget.__init__(self, parent)
        self.pals = []          # list of lists of (r, g, b)
        self.used = []          # list of sets of slot indices actually used
        self.reserve0 = True
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMinimumHeight(120)
        self.setMouseTracking(True)
        self._hover = None      # (palette, slot)
        self.setToolTip('')

    # --- content -------------------------------------------------------------
    def clear(self):
        self.pals = []
        self.used = []
        self._hover = None
        self.update()

    def load(self, paths, stats=None, reserve0=True):
        """Read the per-palette .pal files.  `paths` is the stats `palettes` list.

        A file that will not read is skipped rather than fatal: the pane is a
        diagnostic, and losing the other three palettes because one was
        half-written helps nobody.
        """
        self.pals = []
        self.reserve0 = reserve0
        for p in paths or []:
            try:
                with open(p, 'rb') as f:
                    raw = f.read(PAL_BYTES)
            except OSError:              # noqa: BLE001 - see the docstring
                continue
            if len(raw) < 3:
                continue
            self.pals.append([tuple(raw[i:i + 3])
                              for i in range(0, len(raw) - 2, 3)])
        # How many slots each palette really filled, so the tail can be hatched.
        self.used = []
        per = (stats or {}).get('per_palette', [])
        for i in range(len(self.pals)):
            n = per[i].get('colours', 0) if i < len(per) else 0
            self.used.append(n + (1 if reserve0 else 0))
        self.update()

    # --- geometry --------------------------------------------------------------
    def _layout(self):
        """(cols, cell, rows_per_pal) for the current width.

        Wraps a 256-slot palette over as many rows as it needs.  At a wide dock
        that is one row of 256; at a narrow one it becomes a block, which is
        still readable because the slot ORDER is what matters, not the shape.
        """
        if not self.pals:
            return (16, 8, 16)
        slots = max(len(p) for p in self.pals)
        n = len(self.pals)
        best = None
        for cell in range(16, 2, -1):
            cols = max(1, (self.width() - 8) // cell)
            cols = min(cols, slots)
            rows = (slots + cols - 1) // cols
            need = n * (rows * cell + GUTTER) + 8
            if need <= self.height():
                best = (cols, cell, rows)
                break
        if best is None:
            cell = 3
            cols = max(1, (self.width() - 8) // cell)
            cols = min(cols, slots)
            best = (cols, cell, (slots + cols - 1) // cols)
        return best

    def _hit(self, pt):
        if not self.pals:
            return None
        cols, cell, rows = self._layout()
        block = rows * cell + GUTTER
        y = pt.y() - 4
        b = int(y // block)
        if not (0 <= b < len(self.pals)):
            return None
        row = int((y - b * block) // cell)
        col = int((pt.x() - 4) // cell)
        if row < 0 or row >= rows or col < 0 or col >= cols:
            return None
        slot = row * cols + col
        if slot >= len(self.pals[b]):
            return None
        return (b, slot)

    # --- painting ----------------------------------------------------------------
    def paintEvent(self, _ev):
        p = QPainter(self)
        p.fillRect(self.rect(), theme.BG)
        if not self.pals:
            p.setPen(theme.TEXT_DIM)
            p.setFont(theme.label_font(9))
            p.drawText(self.rect(), Qt.AlignCenter,
                       'the four palettes appear here after a run')
            return
        cols, cell, rows = self._layout()
        block = rows * cell + GUTTER
        p.setFont(theme.label_font(7))
        for b, pal in enumerate(self.pals):
            top = 4 + b * block
            used = self.used[b] if b < len(self.used) else len(pal)
            for slot, rgb in enumerate(pal):
                r = QRect(4 + (slot % cols) * cell,
                          top + (slot // cols) * cell, cell, cell)
                if slot >= used:
                    # An empty tail.  Hatched, so 12/255 cannot be mistaken for
                    # 254/255 on a dark theme - see the module docstring.
                    p.fillRect(r, theme.PANEL)
                    p.setPen(theme.pen(theme.GRID))
                    p.drawLine(r.topLeft(), r.bottomRight())
                    continue
                if slot == 0 and self.reserve0:
                    # Slot 0 is the transparent index, not a colour.  Marked, or
                    # it reads as "this palette starts with black".
                    p.fillRect(r, theme.PANEL)
                    p.setPen(theme.pen(theme.ACCENT))
                    p.drawLine(r.bottomLeft(), r.topRight())
                    continue
                p.fillRect(r, QColor(rgb[0], rgb[1], rgb[2]))
            # The palette id, in the gap under its block.
            p.setPen(theme.PALETTE_IDS[b % len(theme.PALETTE_IDS)])
            p.drawText(4, top + rows * cell + GUTTER - 3,
                       'palette %d   %d of %d used'
                       % (b, max(0, used - 1), len(pal) - (1 if self.reserve0
                                                           else 0)))

    # --- hover ---------------------------------------------------------------------
    def mouseMoveEvent(self, ev):
        hit = self._hit(ev.position().toPoint())
        if hit == self._hover:
            return
        self._hover = hit
        if hit is None:
            self.setToolTip('')
            return
        b, slot = hit
        rgb = self.pals[b][slot]
        used = self.used[b] if b < len(self.used) else len(self.pals[b])
        if slot == 0 and self.reserve0:
            self.setToolTip('palette %d slot 0 - reserved transparent index'
                            % b)
        elif slot >= used:
            self.setToolTip('palette %d slot %d - unused' % (b, slot))
        else:
            self.setToolTip('palette %d slot %d - #%02X%02X%02X  '
                            '(rgb %d, %d, %d)'
                            % (b, slot, rgb[0], rgb[1], rgb[2],
                               rgb[0], rgb[1], rgb[2]))
