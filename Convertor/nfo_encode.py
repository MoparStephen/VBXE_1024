#!/usr/bin/env python3
"""Encode a plain-text report into the viewer-native binary .NFO, in colour.

palettize4.py writes {name}.nfo through encode() here; this tool also
restages older files without a full reconversion.  The output is the byte
image of the Atari viewer's 80-column VBXE text screen: fixed 160-byte line
records of 80 {glyph, attr} cell pairs, space-padded, no terminators, plus
one all-$00 record marking the end.  Every input line must be <= 80
characters (the viewer contract).

The attr byte is the VBXE text-mode colour: bits 0-6 = palette-0 entry
e = hue*8 + luma/2 (the viewer's de-interleaved palette, even lumas only),
bit 7 = opaque background (never set here).  line_attrs() colours the
palettize_4 report layout - gold labels, blue values; see PEN_* below, which
ui.asm's UI_PEN_* mirror for the selector screen.

    python nfo_encode.py Chrome_cr_report.txt Chrome_cr.nfo
    python nfo_encode.py in.txt                # -> in.nfo
    python nfo_encode.py old.nfo               # recolour an existing .nfo in place
    python nfo_encode.py Viewer/out            # recolour every *.nfo under a folder
    python nfo_encode.py x.nfo --preview x.png # render it as the viewer shows it
    python nfo_encode.py --restyle <file|folder>

--restyle brings reports written before 0.21 up to the current layout
(restyle() below) without reconverting anything: every *_report.txt is
rewritten and its sibling .nfo re-encoded from it; a .nfo with no report
beside it (the staged copies in Viewer/out) is decoded, restyled and
re-encoded; a *_summary.txt has only its embedded palettize_4 report
restyled.  The Convertor Version row is set to the current release, since
the text now follows that release's layout; numbers and pictures are
untouched (_stats.json and the summary header keep the version that actually
converted the image).  Running it twice changes nothing the second time.
"""

import sys, os, re

NFO_COLS = 80
RECORD = NFO_COLS * 2


def pen(hue, luma):
    """Atari (hue, even luma) -> VBXE text-mode foreground entry."""
    return hue * 8 + luma // 2


# Colour scheme - mirrored by UI_PEN_* in Viewer/ui.asm.
PEN_LABEL = pen(15, 8)    # $7C gold        - the category left of ':'
PEN_SEP = pen(8, 8)       # $44 blue        - the ':' itself
PEN_RULE = pen(7, 8)      # $3C deep blue   - the ==== banner rule
PEN_VALUE = pen(7, 4)     # $3A blue        - everything right of ':'
PEN_NOTE = pen(8, 6)      # $43 blue        - ( ... ) and <- ... asides
PEN_TITLE = pen(1, 14)    # $0F bright gold - banner title, section headings
PEN_GOOD = pen(12, 12)    # $66 green       - Result: Lossless
PEN_BAD = pen(3, 6)       # $1B red         - Result: Lossy
PEN_PLAIN = pen(0, 14)    # $07 near-white  - the old single pen

# The ==== banner rule follows the menu separator bar's colours, one char per
# 2 lo-res separator px.  Written by Convertor/make_logo.py --export-sep from
# the exported separator - don't hand-edit between the markers.
# RULE_ATTRS-BEGIN
RULE_ATTRS = [
    0x38, 0x38, 0x38, 0x38, 0x38, 0x39, 0x39, 0x39, 0x39, 0x39,
    0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3B, 0x3B, 0x3B, 0x3B,
    0x3B, 0x3C, 0x3C, 0x3C, 0x3C, 0x3C, 0x3D, 0x3D, 0x3D, 0x7D,
    0x0D, 0x7D, 0x7E, 0x7E, 0x7E, 0x7E, 0x7F, 0x0F, 0x7F, 0x0F,
    0x0F, 0x7F, 0x0F, 0x7F, 0x7E, 0x7E, 0x7E, 0x7E, 0x7D, 0x0D,
    0x7D, 0x3D, 0x3D, 0x3D, 0x3C, 0x3C, 0x3C, 0x3C, 0x3C, 0x3B,
    0x3B, 0x3B, 0x3B, 0x3B, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A,
    0x39, 0x39, 0x39, 0x39, 0x39, 0x38, 0x38, 0x38, 0x38, 0x38,
]
# RULE_ATTRS-END

ROW_COLON = 21           # palettize4 row(): label cols 0-20, ':' at 21
VALUE_COL = ROW_COLON + 2
RULE_RE = re.compile(r"^(=+)([^=].*?)(=+)$")
VERDICT_RE = re.compile(r"(Lossless|Lossy)\b")


def cap_first(text):
    """`text` with its first non-space character upper-cased - every report
    label and value starts with a capital ("n/a" reads "N/A")."""
    body = text.lstrip(" ")
    pad = text[:len(text) - len(body)]
    if body.startswith("n/a"):
        return pad + "N/A" + body[3:]
    return pad + body[:1].upper() + body[1:]


def _value(attrs, line, start, end=None):
    """Colour line[start:end] as a value: VALUE, with ( ... ) and a trailing
    '<- ...' aside in NOTE."""
    end = len(line) if end is None else end
    depth = 0
    aside = False
    for i in range(start, end):
        ch = line[i]
        if line.startswith("<-", i):
            aside = True
        if ch == "(":
            depth += 1
        attrs[i] = PEN_NOTE if (depth or aside) else PEN_VALUE
        if ch == ")" and depth:
            depth -= 1


def line_attrs(line):
    """80 attr bytes for one report line (cells past the text get PEN_PLAIN -
    they are spaces, so the colour never shows)."""
    line = line[:NFO_COLS]
    attrs = [PEN_PLAIN] * NFO_COLS
    if not line.strip():
        return attrs
    m = RULE_RE.match(line)
    if m:                                             # =====title=====
        a, t = len(m.group(1)), len(m.group(2))
        for i in range(len(line)):
            attrs[i] = PEN_TITLE if a <= i < a + t else RULE_ATTRS[i]
        return attrs
    if len(line) > ROW_COLON and line[ROW_COLON] == ":" and line[:ROW_COLON].strip():
        colon = ROW_COLON                             # row(): label : value
        m = VERDICT_RE.match(line, VALUE_COL)
        if line[:ROW_COLON].strip() == "Result" and m:   # Result : Lossy - ...
            attrs[:colon] = [PEN_LABEL] * colon
            attrs[colon] = PEN_SEP
            attrs[m.start():m.end()] = (
                [PEN_GOOD if m.group(1) == "Lossless" else PEN_BAD]
                * len(m.group(1)))
            _value(attrs, line, m.end())
            return attrs
    elif line.startswith(" " * (ROW_COLON + 2)):      # cont(): value only
        _value(attrs, line, 0)
        return attrs
    elif line.rstrip().endswith(":"):                 # Section heading:
        attrs[:len(line)] = [PEN_TITLE] * len(line)
        return attrs
    elif ": " in line:                                # free-form "label: value"
        colon = line.index(": ")
    else:
        _value(attrs, line, 0)
        return attrs
    attrs[:colon] = [PEN_LABEL] * colon
    attrs[colon] = PEN_SEP
    _value(attrs, line, colon + 1)
    return attrs


def encode(text):
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    while lines and lines[-1] == "":
        lines.pop()                       # trailing newline(s) are not records
    out = bytearray()
    for ln in lines:
        ln = ln[:NFO_COLS]                # clip to the 80-col screen
        for ch, attr in zip(ln.ljust(NFO_COLS), line_attrs(ln)):
            out.append(ord(ch) & 0xFF)
            out.append(attr)
    out.extend(b"\x00" * RECORD)          # end-of-text sentinel record
    return bytes(out)


# ---- restyle: pre-0.21 report text -> the current layout ------------------
# Before 0.21 three lines broke the "Label : Value" table (a free-form
# accuracy heading, an over-long duplicated-palettes line, a "note:" pair),
# the verdict was a shouted "RESULT: LOSSY", some labels were indented and
# many labels / values started lower case.  The accuracy heading is gone
# altogether now.  restyle() rewrites exactly those, line by line, so finished
# conversions match a fresh one without being reconverted.  It must stay
# idempotent: a current report passes through unchanged.

AS_ENTERED = ("Input", "Description")    # typed text / filename keep their case
SUMMARY_BANNER = "palettize_4 report"
_OLD_RESULT_RE = re.compile(r"^RESULT: (LOSSLESS|LOSSY)\s+(.*)$")
_OLD_LOSSLESS_RE = re.compile(
    r"^components packed into (\d+) palettes with no colour loss\.$")
_IDEAL_RE = re.compile(r"^  (?:the ideal here =|Ideal)\s*: ")


def _row(label, value):
    return "%-*s: %s" % (ROW_COLON, label, value)


def _cont(text):
    return " " * VALUE_COL + text


def _cap_row(line):
    """A row() line with its label flush left and label + value capitalised
    (cap_first); any other line unchanged."""
    if not (len(line) > ROW_COLON and line[ROW_COLON] == ":"
            and line[:ROW_COLON].strip()):
        return line
    label = line[:ROW_COLON].strip()
    value = line[VALUE_COL:]
    if label in AS_ENTERED:
        return line
    return _row(cap_first(label), cap_first(value))


def restyle(text, version=None):
    """Pre-0.21 palettize_4 report text -> the current layout (see above).
    With `version`, the Convertor Version row is set to it - the text now
    follows that release's layout.  Line endings are the caller's business - pass '\\n'-joined text."""
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        s = lines[i].rstrip()
        m = _OLD_RESULT_RE.match(s)
        if s.startswith("Accuracy vs"):
            # the accuracy heading (any earlier form), its "the ideal here =" /
            # "Ideal" row + continuation, and the blank line above it are all
            # dropped - the accuracy rows follow the Result block directly
            if i + 1 < len(lines) and _IDEAL_RE.match(lines[i + 1]):
                i += 1
                if (i + 1 < len(lines) and lines[i + 1].strip()
                        == "with no cell restriction applied"):
                    i += 1
            if out and not out[-1].strip():
                out.pop()
        elif s.startswith("  duplicated across palettes:"):
            out.append(_row("Duplicated Colours", s.split(":", 1)[1].strip()))
        elif s.startswith("  note: "):
            out.append(_row("Note", cap_first(s[len("  note: "):])))
            if i + 1 < len(lines) and lines[i + 1].startswith("  raise --color-bias"):
                out.append(_cont("raise --color-bias (e.g. 0.5 or 1.0) "
                                 "for more colours."))
                i += 1
        elif m:
            verdict = "Lossless" if m.group(1) == "LOSSLESS" else "Lossy"
            ok = _OLD_LOSSLESS_RE.match(m.group(2))
            if ok:
                out.append(_row("Result", "%s - components packed into %s palettes"
                                % (verdict, ok.group(1))))
                out.append(_cont("with no colour loss."))
            else:
                out.append(_row("Result", "%s - %s" % (verdict, m.group(2))))
        elif version and s.startswith("Convertor Version") and ":" in s:
            out.append(_row("Convertor Version", version))
        else:
            out.append(_cap_row(lines[i]))
        i += 1
    return "\n".join(out)


def restyle_summary(text, version=None):
    """A {name}_summary.txt with only its embedded palettize_4 report (from
    the ==== banner down) restyled - the GUI's own [result] table above it
    is a different layout and is left alone."""
    lines = text.split("\n")
    for n, ln in enumerate(lines):
        if RULE_RE.match(ln.rstrip()) and SUMMARY_BANNER in ln:
            return "\n".join(lines[:n + 1]
                             + [restyle("\n".join(lines[n + 1:]), version)])
    return text


def _rewrite_text(path, fn):
    """Apply fn to a text file, keeping its line endings.  True if changed."""
    with open(path, "r", newline="") as f:
        old = f.read()
    crlf = "\r\n" in old
    new = fn(old.replace("\r\n", "\n"))
    if crlf:
        new = new.replace("\n", "\r\n")
    if new == old:
        return False
    with open(path, "w", newline="") as f:
        f.write(new)
    return True


def _write_if_changed(path, data):
    if os.path.isfile(path):
        with open(path, "rb") as f:
            if f.read() == data:
                return False
    with open(path, "wb") as f:
        f.write(data)
    return True


def restyle_paths(paths, version=None):
    """Restyle every report / summary / .nfo in `paths` (files or folders,
    walked), stamping `version` on the Convertor Version row if given.
    Returns (files examined, files changed)."""
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, names in os.walk(p):
                files.extend(os.path.join(root, n) for n in sorted(names))
        else:
            files.append(p)
    reports = [f for f in files if f.lower().endswith("_report.txt")]
    summaries = [f for f in files if f.lower().endswith("_summary.txt")]
    nfos = [f for f in files if f.lower().endswith(".nfo")]
    done, changed = set(), 0
    for rp in reports:                    # report first: its .nfo follows it
        changed += _rewrite_text(rp, lambda t: restyle(t, version))
        nfo = rp[:-len("_report.txt")] + ".nfo"
        if os.path.isfile(nfo):
            with open(rp) as f:
                changed += _write_if_changed(nfo, encode(f.read()))
            done.add(os.path.normcase(os.path.abspath(nfo)))
    for nfo in nfos:                      # lone .nfo - e.g. staged copies
        if os.path.normcase(os.path.abspath(nfo)) in done:
            continue
        with open(nfo, "rb") as f:
            data = encode(restyle(decode(f.read()), version))
        changed += _write_if_changed(nfo, data)
    for sp in summaries:
        changed += _rewrite_text(sp, lambda t: restyle_summary(t, version))
    return len(reports) + len(summaries) + len(nfos), changed


def decode(data):
    """A .nfo's text, one line per record up to the sentinel (trailing
    spaces stripped) - the inverse of encode() for recolouring."""
    lines = []
    for r in range(0, len(data) - RECORD + 1, RECORD):
        rec = data[r:r + RECORD]
        if not any(rec):
            break
        lines.append(bytes(rec[0::2]).decode("latin-1").rstrip())
    return "\n".join(lines) + "\n"


def preview(data, png_path, scale=2):
    """Render a .nfo the way the viewer shows it: CGA.F08 glyphs, palette 0."""
    import numpy as np
    from PIL import Image
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    from make_logo import load_pal0
    font = open(os.path.join(here, "..", "Viewer", "Assets", "CGA.F08"), "rb").read()
    pal0 = load_pal0()
    rows = max(1, len(data) // RECORD - 1)
    img = np.zeros((rows * 8, NFO_COLS * 8, 3), np.uint8)
    for r in range(rows):
        for c in range(NFO_COLS):
            g, a = data[r * RECORD + c * 2], data[r * RECORD + c * 2 + 1]
            for y in range(8):
                bits = font[g * 8 + y]
                for x in range(8):
                    if bits & (0x80 >> x):
                        img[r * 8 + y, c * 8 + x] = pal0[a & 0x7F]
    img = np.repeat(np.repeat(img, scale, 0), scale, 1)
    Image.fromarray(img, "RGB").save(png_path)


def _recolour(path):
    with open(path, "rb") as f:
        data = encode(decode(f.read()))
    with open(path, "wb") as f:
        f.write(data)
    return data


def _current_version():
    """The repo release (palgui/__init__.py) - what palettize4 stamps."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from palgui import __version__
    return __version__


def main(argv):
    if argv and argv[0] == "--restyle":
        if len(argv) < 2:
            raise SystemExit(__doc__)
        seen, changed = restyle_paths(argv[1:], _current_version())
        print("restyled: %d of %d report/summary/.nfo files changed"
              % (changed, seen))
        return
    png = None
    if "--preview" in argv:
        i = argv.index("--preview")
        png = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if not 1 <= len(argv) <= 2:
        raise SystemExit(__doc__)
    src = argv[0]
    if os.path.isdir(src):
        n = 0
        for root, _, files in os.walk(src):
            for fn in files:
                if fn.lower().endswith(".nfo"):
                    _recolour(os.path.join(root, fn))
                    n += 1
        print("recoloured %d .nfo files under %s" % (n, src))
        return
    if src.lower().endswith(".nfo") and len(argv) == 1:
        data = _recolour(src)
        print("%s recoloured  (%d records)" % (src, len(data) // RECORD))
    else:
        dst = argv[1] if len(argv) == 2 else os.path.splitext(src)[0] + ".nfo"
        with open(src, "r") as f:
            data = encode(f.read())
        with open(dst, "wb") as f:
            f.write(data)
        print("%s -> %s  (%d records)" % (src, dst, len(data) // RECORD))
    if png:
        preview(data, png)
        print("preview -> %s" % png)


if __name__ == "__main__":
    main(sys.argv[1:])
