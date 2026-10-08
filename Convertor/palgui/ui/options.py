"""options.py - every palettize4 flag, as a control that says why it exists.

THE TOOLTIPS ARE THE README, NOT THE ARGPARSE HELP, and that is deliberate.
`--coherence L   spatial smoothing` tells you nothing you could not guess and
nothing you can act on.  "Neighbouring cells decide independently, so mixed
regions go blocky; raise this until they stop" tells you what to do when you
are looking at a blocky preview, which is the only moment anyone reads a
tooltip.

CONTROLS THAT CANNOT MATTER ARE DISABLED RATHER THAN HIDDEN.  --display-aspect
is only read by cover and fit, and --coherence only bites when the bias is
above zero.  Greying them out where they are, with the reason in the tooltip,
teaches the dependency; hiding them would just make the panel appear to lose
controls at random.

FLAGS THE VIEWER FIXES ARE NOT CONTROLS AT ALL, which is a different case and
gets a different treatment.  --resize, --cell, --palettes and --slots have
exactly one legal value each on this hardware, so they are STATED - one caption
apiece - rather than shown as widgets nobody may touch.  A disabled control
still invites the question "what would happen if"; a sentence answers it.

ONE SIGNAL OUT.  `changed` fires whenever any control moves, and the window
decides what that is worth - re-enabling Preview, marking the result stale.
The panel never runs anything itself.
"""

import os
import sys

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (QCheckBox, QComboBox, QDoubleSpinBox,
                               QFileDialog, QFormLayout, QGroupBox,
                               QHBoxLayout, QLabel, QLineEdit, QSpinBox,
                               QToolButton, QVBoxLayout, QWidget)

from ..settings import (CELL_FIXED, DITHER_DIFFUSION, DITHER_ORDERED,
                        FILTERS, FITS, PALETTES_FIXED, RESIZE_FIXED,
                        SLOTS_FIXED, Settings)
from ..imageslst import NAME_CAP as DESC_CAP
from . import lastdir, theme

#: The four fixed flags, said once where their controls used to be.
FIXED_SIZE_TEXT = '%s   (fixed by the viewer)' % RESIZE_FIXED
FIXED_MODEL_TEXT = ('%d-pixel cells, %d palettes x %d slots   (fixed by the '
                    'viewer)' % (CELL_FIXED, PALETTES_FIXED, SLOTS_FIXED))

#: Why they are fixed, on both of them.
FIXED_TIP = (
    'The VBXE viewer that reads these files runs ONE mode: %s, attributes '
    'every %d pixels, %d palettes of %d entries.  A conversion at any other '
    'setting produces files it cannot display, so these are stated rather '
    'than offered - a control you can only use to make a mistake is worse '
    'than no control.\n\n'
    'palettize4.py itself still takes --resize, --cell, --palettes and '
    '--slots on the command line if you are ever targeting something else.'
    % (RESIZE_FIXED, CELL_FIXED, PALETTES_FIXED, SLOTS_FIXED))


class OptionsPanel(QWidget):
    """The left dock.  Reads and writes one Settings."""

    changed = Signal()
    #: The user picked a new input image; the window loads it into the source
    #: pane rather than waiting for a Preview.
    input_changed = Signal(str)

    def __init__(self, parent=None):
        QWidget.__init__(self, parent)
        self._loading = False
        lay = QVBoxLayout(self)
        lay.setContentsMargins(6, 6, 6, 6)
        lay.setSpacing(8)
        lay.addWidget(self._source_group())
        lay.addWidget(self._model_group())
        lay.addWidget(self._strategy_group())
        lay.addWidget(self._dither_group())
        lay.addWidget(self._output_group())
        lay.addStretch(1)
        self._label_tooltips()
        # THE PANEL MUST START WHERE palettize4 STARTS.  A combo comes up on
        # its first item, so `filter` opened on `nearest` while Settings' own
        # default - and the converter's - is `lanczos`.  A GUI whose blank
        # state is not the tool's default state is a GUI that quietly converts
        # your first photograph with the pixel-art filter.
        self.from_settings(Settings())

    # --- tooltips ---------------------------------------------------------------
    def _label_tooltips(self):
        """Give every form row's LABEL the same tooltip as its control.

        SOME CONTROLS HERE SPEND HALF THEIR LIFE DISABLED - display aspect on
        a stretch, coherence at bias 0, dither strength with no dither - and a
        greyed-out control is the exact moment someone wants to know why.  A disabled widget does not take mouse events (they
        pass to its parent), so its own tooltip is unreliable there; the label
        beside it is never disabled, so hovering the WORD always answers.

        Done by walking the forms rather than by hand at each addRow, so a
        control added later cannot forget - and so the text lives in exactly
        one place instead of two that drift apart.
        """
        for form in self.findChildren(QFormLayout):
            for i in range(form.rowCount()):
                field = form.itemAt(i, QFormLayout.FieldRole)
                label = form.itemAt(i, QFormLayout.LabelRole)
                if field is None or label is None:
                    continue
                fw, lw = field.widget(), label.widget()
                if fw is None or lw is None or lw.toolTip():
                    continue
                tip = fw.toolTip()
                if not tip:
                    # Some rows are a container holding the real control plus a
                    # browse button or an "auto" tick, and the text is on the
                    # control inside.  THE LONGEST ONE WINS: the primary
                    # control is the one carrying the actual explanation, and
                    # the first child is as likely to be the tick box with a
                    # one-liner on it.
                    tips = [c.toolTip() for c in fw.findChildren(QWidget)
                            if c.toolTip()]
                    tip = max(tips, key=len) if tips else ''
                if tip:
                    lw.setToolTip(tip)

    # --- source ---------------------------------------------------------------
    def _source_group(self):
        g = QGroupBox('Source')
        f = QFormLayout(g)
        f.setLabelAlignment(Qt.AlignRight)

        self.input = QLineEdit()
        self.input.setToolTip(
            'Any format Pillow can decode - PNG, JPEG, BMP, GIF, TIFF, WebP, '
            'TGA, PCX, PPM.  The format is read from the file contents, not '
            'the extension.\n\n'
            'Prefer a lossless original for photographs: JPEG compression adds '
            'colour noise across smooth regions, which inflates the unique-'
            'colour count and pushes the image deeper into the lossy phase.\n\n'
            'Source alpha is flattened to opaque; the output\'s transparency is '
            'index 0 and is unrelated to it.')
        browse = QToolButton()
        browse.setText('...')
        browse.setToolTip('Choose an image')
        browse.clicked.connect(self._browse_input)
        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.addWidget(self.input, 1)
        row.addWidget(browse)
        w = QWidget()
        w.setLayout(row)
        f.addRow('image', w)
        self.input.editingFinished.connect(self._input_edited)

        self.resize = QLabel(FIXED_SIZE_TEXT)
        self.resize.setStyleSheet(theme.caption_style())
        self.resize.setFont(theme.label_font(8))
        self.resize.setToolTip(FIXED_TIP)
        f.addRow('size', self.resize)

        self.filter = QComboBox()
        self.filter.addItems(FILTERS)
        self.filter.setToolTip(
            'Resampling filter.\n\n'
            'nearest for pixel art and indexed art: it blends nothing, so it '
            'adds no new colours and keeps hard edges crisp.\n\n'
            'lanczos for photographs and portraits.  box is a good alternative '
            'for a clean area-average downscale.')
        self.filter.currentTextChanged.connect(self._touch)
        f.addRow('filter', self.filter)

        self.fit = QComboBox()
        self.fit.addItems(FITS)
        self.fit.setToolTip(
            'What to do when the source is not the target shape.\n\n'
            'stretch resamples straight to WxH.  Correct for a 4:3 master; it '
            'distorts anything else.\n\n'
            'cover centre-crops to the on-screen aspect first, then resamples. '
            'Fills the frame with no distortion but trims the edges - the right '
            'choice for portrait photographs.\n\n'
            'fit letterboxes or pillarboxes instead, so the whole image shows. '
            'The bars are written as index 0 (transparent) in every palette, so '
            'they read as background rather than eating a real palette colour.')
        self.fit.currentTextChanged.connect(self._touch)
        f.addRow('fit', self.fit)

        self.display_aspect = QLineEdit('4:3')
        self.display_aspect.setToolTip(
            'The TRUE ON-SCREEN shape, which is not the pixel grid\'s shape.\n\n'
            'The target is 320x240, whose pixels display square, so 4:3 is '
            'correct and there is rarely a reason to change it.  It exists '
            'because the shape you are cropping TO is a property of the '
            'screen, not of the pixel grid.\n\n'
            'Only used by cover and fit.')
        self.display_aspect.editingFinished.connect(self._touch)
        f.addRow('display aspect', self.display_aspect)

        self.description = QLineEdit()
        self.description.setMaxLength(DESC_CAP)
        self.description.setToolTip(
            'What the Atari viewer\'s selector status line shows for this '
            'image ("Src: <description>"), up to %d characters.\n\n'
            'Left blank, it is the source filename without its extension.\n\n'
            'Saved in the image\'s _stats.json; Build IMAGES.LST and Gather '
            'read it from there.' % DESC_CAP)
        self.description.editingFinished.connect(self._touch)
        f.addRow('description', self.description)
        return g

    # --- the packing model ------------------------------------------------------
    def _model_group(self):
        g = QGroupBox('Palette model')
        g.setToolTip(FIXED_TIP)
        f = QFormLayout(g)
        f.setLabelAlignment(Qt.AlignRight)

        # THREE SPIN BOXES BECAME ONE SENTENCE.  cell / palettes / slots used
        # to be editable, on the argument that a coarser cell or a cut-down
        # palette is an interesting experiment.  It is - but every one of those
        # experiments produces files the viewer cannot show, so in practice the
        # boxes could only be used by accident.  Stating the model reads better
        # than three permanently greyed-out controls, and keeps this panel a
        # complete description of the run, which is the point of showing it.
        self.model = QLabel(FIXED_MODEL_TEXT)
        self.model.setStyleSheet(theme.caption_style())
        self.model.setFont(theme.label_font(8))
        self.model.setToolTip(FIXED_TIP)
        self.model.setWordWrap(True)
        f.addRow('model', self.model)

        self.reserve0 = QCheckBox('slot 0 is transparent')
        self.reserve0.setChecked(True)
        self.reserve0.setToolTip(
            'Reserve slot 0 in every palette and never assign a real colour to '
            'it, leaving 255 usable.  Pixel index 0 then means "transparent / '
            'background" whichever palette the cell is using, and the '
            'letterbox bars from fit land there.\n\n'
            'Turn it off only if you genuinely do not need a transparent index '
            '- it buys one more colour per palette.')
        self.reserve0.toggled.connect(self._touch)
        f.addRow('', self.reserve0)

        self.colors_auto = QCheckBox('auto')
        self.colors_auto.setChecked(True)
        self.colors_auto.setToolTip(
            'Auto = palettes x usable slots, the largest number that could fit.')
        self.colors_auto.toggled.connect(self._touch)
        self.colors = QSpinBox()
        self.colors.setRange(2, 4096)
        self.colors.setValue(1020)
        self.colors.setToolTip(
            'Pre-quantize the source to this many colours before packing.\n\n'
            'AT EXACTLY THE FULL BUDGET THERE IS ZERO SLACK: 4x255 = 1020 means '
            'every palette must end up exactly full and perfectly disjoint, '
            'which photographs almost never allow because gradients tangle '
            'neighbouring cells together.  Quantizing to about 960 first leaves '
            'room to absorb the unavoidable boundary duplication, and usually '
            'ends up displaying MORE colours than asking for all 1020.')
        self.colors.valueChanged.connect(self._touch)
        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.addWidget(self.colors_auto)
        row.addWidget(self.colors, 1)
        w = QWidget()
        w.setLayout(row)
        f.addRow('pre-quantize', w)

        self.budget = QLabel()
        self.budget.setStyleSheet(theme.caption_style())
        self.budget.setFont(theme.label_font(8))
        f.addRow('', self.budget)
        return g

    # --- strategy ----------------------------------------------------------------
    def _strategy_group(self):
        g = QGroupBox('Strategy')
        f = QFormLayout(g)
        f.setLabelAlignment(Qt.AlignRight)

        bias_tip = (
            'How to spend the slot budget: on exact colours, or on distinct '
            'ones.\n\n'
            '0.0 (fidelity) - every pixel keeps its exact colour.  Colours are '
            'duplicated into every palette that needs them and merged only when '
            'a palette overflows.  No block artifacts.  Zero loss whenever the '
            'colours fit, and the right choice for photographs.\n\n'
            '1.0 (max colours) - each colour is placed where it is most used '
            'and the spare slots go to the highest-demand duplicates; pixels '
            'whose colour is not in their cell\'s palette get recoloured to the '
            'nearest one that is.  Most colours on screen, but whole 8-pixel '
            'cells commit to one palette, so cells straddling a colour boundary '
            'can show as recoloured BLOCKS.\n\n'
            '0.5 to 0.75 is often the sweet spot for busy or pixelated images: '
            'most of the extra colours, far fewer blocks than 1.0.')
        self.color_bias = QDoubleSpinBox()
        self.color_bias.setRange(0.0, 1.0)
        self.color_bias.setSingleStep(0.05)
        self.color_bias.setDecimals(2)
        self.color_bias.setToolTip(bias_tip)
        self.color_bias.valueChanged.connect(self._touch)
        self.max_colors = QCheckBox('max')
        self.max_colors.setToolTip(
            'The --max-colors shorthand: exactly the same run as bias 1.0.')
        self.max_colors.toggled.connect(self._touch)
        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.addWidget(self.color_bias, 1)
        row.addWidget(self.max_colors)
        w = QWidget()
        w.setLayout(row)
        f.addRow('colour bias', w)

        self.coherence = QDoubleSpinBox()
        self.coherence.setRange(0.0, 16.0)
        self.coherence.setSingleStep(0.5)
        self.coherence.setDecimals(2)
        self.coherence.setValue(1.5)
        self.coherence.setToolTip(
            'A penalty for a cell choosing a different palette from its '
            'neighbours.\n\n'
            'Above bias 0 each 8-pixel cell picks its own palette, and cells '
            'deciding independently show up as blocks and streaks across smooth '
            'or mixed regions.  This makes a region settle on one palette '
            'instead.  RAISE IT IF THE PREVIEW LOOKS BLOCKY; lower it toward 0 '
            'for the most literal per-cell choice.\n\n'
            'Does nothing at bias 0, where no cell has a choice to make.')
        self.coherence.valueChanged.connect(self._touch)
        f.addRow('coherence', self.coherence)

        self.optimize = QCheckBox('reduce cross-palette duplication')
        self.optimize.setChecked(True)
        self.optimize.setToolTip(
            'In the fidelity strategy, shuffle cells between palettes to cut '
            'the number of colours that have to be copied into more than one.\n\n'
            'Duplication is what usually costs you colours: a colour appearing '
            'in cells scattered all over the image must be copied into every '
            'palette those cells land on, and each copy eats a slot.  Leave it '
            'on unless you are trying to see what it was doing.')
        self.optimize.toggled.connect(self._touch)
        f.addRow('', self.optimize)
        return g

    # --- dither -------------------------------------------------------------------
    def _dither_group(self):
        g = QGroupBox('Dither')
        f = QFormLayout(g)
        f.setLabelAlignment(Qt.AlignRight)

        self.dither = QComboBox()
        self.dither.addItem('none')
        self.dither.insertSeparator(self.dither.count())
        for d in DITHER_DIFFUSION:
            self.dither.addItem(d)
        self.dither.insertSeparator(self.dither.count())
        for d in DITHER_ORDERED:
            self.dither.addItem(d)
        self.dither.setToolTip(
            'Break the banding a big reduction leaves behind.\n\n'
            'A smooth source - a plasma, a sky, soft shading - has far more '
            'colours than the budget, so the reduction snaps it into visible '
            'contour rings.  Dithering spreads the error instead, turning the '
            'bands into fine texture.\n\n'
            'ERROR DIFFUSION (floyd, atkinson, jjn, stucki, sierra, burkes): '
            'smooth and organic, but leaves faint random speckle, occasionally '
            'strands a recoloured pixel after packing, and is serial Python so '
            'it is the slow path.\n\n'
            'ORDERED (bayer2/4/8): fast and deterministic, but shows a regular '
            'grid texture.\n\n'
            'BLUE is the one to reach for on smooth sources.  Blue noise spreads '
            'its perturbations evenly, so it breaks banding with a fine even '
            'grain that has neither Bayer\'s grid nor error diffusion\'s '
            'speckle - and because every cell gets a balanced set of colours it '
            'survives the palette packing best.\n\n'
            'Needs scipy.  Applied BEFORE packing, so the result is still '
            'subject to the cell constraint.')
        self.dither.currentTextChanged.connect(self._touch)
        f.addRow('algorithm', self.dither)

        self.dither_strength = QDoubleSpinBox()
        self.dither_strength.setRange(0.0, 4.0)
        self.dither_strength.setSingleStep(0.1)
        self.dither_strength.setDecimals(2)
        self.dither_strength.setValue(1.0)
        self.dither_strength.setToolTip(
            'Scales the effect.  For error diffusion it is the fraction of the '
            'error passed on; for the ordered masks it scales the perturbation '
            'amplitude.\n\n'
            '1.0 is a good default.  Higher breaks wider bands at the cost of '
            'more visible grain; lower is subtler.')
        self.dither_strength.valueChanged.connect(self._touch)
        f.addRow('strength', self.dither_strength)

        # THE INERT-DITHER WARNING.  palettize4 only dithers inside its
        # pre-quantization branch, so on a source already within the budget the
        # flag is accepted and ignored - and three dithers produce three
        # identical pictures with no explanation anywhere.  The window fills
        # this in from the stats after every run.
        self.dither_note = QLabel()
        self.dither_note.setWordWrap(True)
        self.dither_note.setFont(theme.label_font(8))
        self.dither_note.setStyleSheet(theme.caption_style(theme.WARN))
        self.dither_note.hide()
        f.addRow('', self.dither_note)
        return g

    # --- output --------------------------------------------------------------------
    def _output_group(self):
        g = QGroupBox('Output')
        f = QFormLayout(g)
        f.setLabelAlignment(Qt.AlignRight)

        self.out = QLineEdit('out')
        self.out.setToolTip(
            'The root that Convert writes under.  EACH IMAGE GETS ITS OWN '
            'FOLDER inside it, named after the output base name, so converting '
            'a second picture cannot bury or overwrite the first one - eleven '
            'files per run in one flat directory stops being readable at about '
            'the third image.\n\n'
            'A preview never writes its own output here; it goes to a scratch '
            'directory that is cleaned up when the app closes.  The one thing '
            'a preview can leave under this root is a snapshot - see below.')
        self.out.editingFinished.connect(self._touch)
        browse = QToolButton()
        browse.setText('...')
        browse.clicked.connect(self._browse_out)
        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.addWidget(self.out, 1)
        row.addWidget(browse)
        w = QWidget()
        w.setLayout(row)
        f.addRow('directory', w)

        self.name = QLineEdit()
        self.name.setPlaceholderText('(input file name)')
        self.name.setToolTip(
            'Base name for every output file: NAME.v1k (the single file the '
            'viewer loads), NAME.raw, NAME0.pal through NAME3.pal, NAME.pal, '
            'NAME.map, and the preview/report sidecars.\n\n'
            'Blank means the input\'s file name without its extension.  Set it '
            'to img7 and so on when writing straight into the viewer\'s '
            'directory.')
        self.name.editingFinished.connect(self._touch)
        f.addRow('base name', self.name)

        self.seed = QSpinBox()
        self.seed.setRange(0, 999999)
        self.seed.setToolTip(
            'Seed for the k-means that seeds the four palettes in the lossy '
            'phase.  Change it to get a different-but-equally-valid packing of '
            'an image that will not go lossless; leave it alone to have two '
            'runs of the same settings produce identical bytes.')
        self.seed.valueChanged.connect(self._touch)
        f.addRow('seed', self.seed)

        self.snapshots = QCheckBox('save a numbered snapshot of every '
                                   'preview')
        self.snapshots.setToolTip(
            'Write out/NAME/previews/Preview_01.png and Preview_01.txt every '
            'time you press Preview, numbering upwards.\n\n'
            'THIS IS HOW YOU COMPARE DITHERS HONESTLY.  A preview otherwise '
            'lives in a scratch directory the next one overwrites, so judging '
            'floyd against atkinson against blue means holding three pictures '
            'in your head - which is the one thing eyes cannot do.  The .png '
            'is the converted 320x240 picture with its exact colours; the .txt '
            'is every setting that produced it, the command line, and the full '
            'report.\n\n'
            'Off by default because it does what it says: forty previews is '
            'eighty files.')
        self.snapshots.setChecked(False)
        # DELIBERATELY NOT CONNECTED TO _touch.  This changes where files go,
        # not what the picture looks like, so it must not mark the result on
        # screen stale - and it is not a Settings field, so `changed` would
        # have nothing to report anyway.
        f.addRow('', self.snapshots)

        self.files = QLabel()
        self.files.setStyleSheet(theme.caption_style())
        self.files.setFont(theme.label_font(8))
        self.files.setWordWrap(True)
        f.addRow('', self.files)
        return g

    # --- the snapshot preference ----------------------------------------------------
    # NOT A Settings FIELD, on purpose.  settings.py is one field per
    # palettize4 flag and the tests scrape --help to keep it that way; this is
    # a habit of the GUI's, with no business in a preset or on a command line.
    # ui/main.py remembers it in QSettings beside the window layout.
    def snapshots_wanted(self):
        return self.snapshots.isChecked()

    def set_snapshots_wanted(self, on):
        self.snapshots.setChecked(bool(on))

    # --- browsing --------------------------------------------------------------------
    def _browse_input(self):
        start = lastdir.get('image',
                            os.path.dirname(self.input.text())
                            or _convertor_dir())
        path, _ = QFileDialog.getOpenFileName(
            self, 'Open image', start,
            'Images (*.png *.bmp *.jpg *.jpeg *.gif *.tif *.tiff *.webp '
            '*.tga *.pcx *.ppm);;All files (*)')
        if path:
            lastdir.remember('image', path)
            self.input.setText(path)
            self._input_edited()

    def _browse_out(self):
        start = lastdir.get('output', self.out.text() or _convertor_dir())
        path = QFileDialog.getExistingDirectory(self, 'Output directory', start)
        if path:
            lastdir.remember('output', path)
            self.out.setText(path)
            self._touch()

    def _input_edited(self):
        # A new image's description starts blank - one image's text must not
        # quietly ride along onto the next.  The placeholder shows the default.
        if not self._loading:
            self.description.clear()
        self._sync_description_hint()
        self._touch()
        if not self._loading:
            self.input_changed.emit(self.input.text())

    def _sync_description_hint(self):
        """Placeholder = what palettize4 will use if the field stays blank."""
        stem = os.path.splitext(os.path.basename(self.input.text().strip()))[0]
        self.description.setPlaceholderText(stem.rstrip('.')[:DESC_CAP])

    # --- reading and writing the Settings ------------------------------------------
    def to_settings(self):
        s = Settings()
        s.input = self.input.text().strip()
        s.out = self.out.text().strip() or 'out'
        s.name = self.name.text().strip()
        # The four the viewer fixes are asserted, not read: there is no
        # control to read them from, and a Settings that quietly kept whatever
        # a preset carried would run at a size the viewer cannot show.
        s.cell = CELL_FIXED
        s.palettes = PALETTES_FIXED
        s.slots = SLOTS_FIXED
        s.resize = RESIZE_FIXED
        s.reserve0 = self.reserve0.isChecked()
        s.colors = 0 if self.colors_auto.isChecked() else self.colors.value()
        s.filter = self.filter.currentText()
        s.fit = self.fit.currentText()
        s.display_aspect = self.display_aspect.text().strip() or '4:3'
        s.description = self.description.text().strip()
        s.color_bias = self.color_bias.value()
        s.max_colors = self.max_colors.isChecked()
        s.optimize = self.optimize.isChecked()
        s.coherence = self.coherence.value()
        s.dither = self.dither.currentText()
        s.dither_strength = self.dither_strength.value()
        s.seed = self.seed.value()
        return s

    def from_settings(self, s):
        """Push a Settings into the controls without firing `changed` per field.

        ONE `changed` AT THE END, not twenty.  Loading a preset otherwise looks
        to the window like twenty separate edits, each of which invalidates the
        result and re-enables Preview.
        """
        self._loading = True
        try:
            self.input.setText(s.input)
            self.out.setText(s.out)
            self.name.setText(s.name)
            # s.cell, s.palettes, s.slots and s.resize are deliberately
            # ignored - see to_settings.  An old preset carrying cell=16 or
            # resize='' loads with everything else it does have and converts.
            self.reserve0.setChecked(bool(s.reserve0))
            self.colors_auto.setChecked(int(s.colors) <= 0)
            if int(s.colors) > 0:
                self.colors.setValue(int(s.colors))
            self.filter.setCurrentText(s.filter)
            self.fit.setCurrentText(s.fit)
            self.display_aspect.setText(s.display_aspect)
            self.description.setText(s.description)
            self._sync_description_hint()
            self.color_bias.setValue(float(s.color_bias))
            self.max_colors.setChecked(bool(s.max_colors))
            self.optimize.setChecked(bool(s.optimize))
            self.coherence.setValue(float(s.coherence))
            self.dither.setCurrentText(s.dither)
            self.dither_strength.setValue(float(s.dither_strength))
            self.seed.setValue(int(s.seed))
        finally:
            self._loading = False
        self._sync_enables()
        self.changed.emit()

    # --- reacting to itself -----------------------------------------------------------
    def _touch(self, *_a):
        self._sync_enables()
        if not self._loading:
            self.changed.emit()

    def _sync_enables(self):
        # REENTRANT: it writes to self.colors below, whose valueChanged comes
        # straight back here through _touch.  QSpinBox only signals on a real
        # change so it would settle after one bounce anyway, but the bounce
        # would emit a spurious `changed` and mark the result stale for an edit
        # the user did not make.
        if getattr(self, '_syncing', False):
            return
        self._syncing = True
        try:
            self._sync_enables_once()
        finally:
            self._syncing = False

    def _sync_enables_once(self):
        # filter and fit are unconditional now: there is always a resample,
        # because the target size is always 320x240.
        self.display_aspect.setEnabled(self.fit.currentText() != 'stretch')
        self.colors.setEnabled(not self.colors_auto.isChecked())
        # --max-colors IS bias 1.0, so showing a live bias of anything else
        # beside a ticked box would be a lie about what will run.
        self.color_bias.setEnabled(not self.max_colors.isChecked())
        self.coherence.setEnabled(self.max_colors.isChecked()
                                  or self.color_bias.value() > 0.0)
        self.dither_strength.setEnabled(self.dither.currentText() != 'none')

        s = self.to_settings()
        self.budget.setText('%d palettes x %d usable = %d colours'
                            % (s.palettes, s.usable_per_palette(),
                               s.colour_budget()))
        if self.colors_auto.isChecked():
            self.colors.setValue(min(self.colors.maximum(), s.colour_budget()))
        base = s.effective_name() or 'NAME'
        self.files.setText('writes %s/%s.v1k, %s.raw, %s0-%d.pal, %s.pal, '
                           '%s.map + preview / report / stats'
                           % (base, base, base, base, s.palettes - 1, base,
                              base))

    # --- the inert-dither warning ------------------------------------------------------
    def set_dither_note(self, text):
        self.dither_note.setText(text)
        self.dither_note.setVisible(bool(text))


def _convertor_dir():
    """Where palettize4 and the sample images live - a sensible start dir."""
    if getattr(sys, 'frozen', False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
