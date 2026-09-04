"""theme.py - one place for every colour and font the views draw with.

THE SAME PALETTE AS VBXE RAD STUDIO, deliberately: these are two tools on the
same desk for the same machine, and a reader moving between them should not
have to re-learn what amber means.  Kept out of the widgets so that changing
one does not mean hunting through six files.

THE IMAGE PANES ARE NOT THEMED AND MUST NOT BE.  Everything below is chrome -
labels, gutters, the swatch grid's lines.  The converted image is the thing
being judged, and a tinted surround or a coloured mat would change how its
colours read.  The canvas ground is a neutral dark grey for exactly that
reason, and nothing is ever drawn on top of the picture itself.
"""

from PySide6.QtCore import Qt
from PySide6.QtGui import QBrush, QColor, QFont, QPen

# --- ground -----------------------------------------------------------------
BG = QColor('#14171c')
PANEL = QColor('#1b1f25')
GRID = QColor('#20252d')

#: The mat behind an image.  NEUTRAL, and a shade off the panel so the edge of
#: a dark picture is still findable.  See the docstring: no hue here.
CANVAS = QColor('#101215')
#: The one-pixel edge around a picture, so a black border is not invisible.
FRAME = QColor('#3a424e')

# --- text -------------------------------------------------------------------
TEXT = QColor('#cfd8dc')
TEXT_DIM = QColor('#78909c')
ACCENT = QColor('#4dd0e1')
OK = QColor('#66bb6a')
WARN = QColor('#ffb454')
ERR = QColor('#ef5350')

#: The two sides of the comparison, used for their captions and for the A/B
#: badge.  Grey for the source (it is the reference, it is not a result) and
#: cyan for the conversion (it is what the settings just produced).
SOURCE = QColor('#90a4ae')
RESULT = QColor('#4dd0e1')

# --- the four palettes ------------------------------------------------------
#: One colour per palette id, used by the swatch sheet's row labels and by the
#: map legend.  Four hues that stay apart at a 12px swatch.
PALETTE_IDS = [QColor('#ef5350'), QColor('#66bb6a'),
               QColor('#42a5f5'), QColor('#ffa726')]


def pen(color, width=1.0, style=Qt.SolidLine, cosmetic=True):
    p = QPen(color, width, style)
    p.setCosmetic(cosmetic)
    return p


def brush(color):
    return QBrush(color)


#: Monospace, because nearly every label here is a NUMBER being compared with
#: the one below it - colour counts, percentages, slot occupancy.  A fallback
#: chain rather than one name so this looks the same off Windows.
MONO = ('Consolas', 'Cascadia Mono', 'DejaVu Sans Mono', 'Menlo', 'Monospace')


def label_font(size=8, bold=False):
    f = QFont()
    f.setFamilies(list(MONO))
    f.setStyleHint(QFont.Monospace)
    f.setPointSize(size)
    f.setBold(bold)
    return f


def caption_style(color=None):
    """The stylesheet a small explanatory label under a control wears."""
    return 'color:%s; padding:2px;' % (color or TEXT_DIM).name()
