"""atari_name.py - the 8-character base name every Atari-bound file gets.

SpartaDOS X only sees 8.3 names, and every image the viewer loads is
<NAME>.V1K (+ <NAME>.NFO), so the converter settles the NAME itself rather
than leaving it to whatever the disk-image step does with a long filename.

THE RULE: upper-case, keep only A-Z 0-9 _, at most 8 characters, and never a
digit first.  Illegal characters are DROPPED and the gap closed - "Charger 01"
-> CHARGER0, not "CHARGER_" - which is what the host-folder -> disk-image step
has always done, so names already on disks keep matching.  A leading digit
gets an 'I' in front ("2024 trip" -> I2024TRI); a name with nothing legal in
it becomes IMG.

Standalone and dependency-free: palettize4.py imports it as a sibling, palgui
imports it from here too, so the converter and the manifest can never disagree.
"""

import re

MAX_LEN = 8
PREFIX = "I"              # put in front of a name that would start with a digit
FALLBACK = "IMG"          # a name with no legal characters at all

_BAD = re.compile(r"[^A-Z0-9_]")
_GOOD = re.compile(r"^[A-Z_][A-Z0-9_]{0,%d}$" % (MAX_LEN - 1))


def short_name(stem):
    """The legal 8-char Atari base name for `stem` (a filename without extension)."""
    s = _BAD.sub("", (stem or "").upper())
    if not s:
        s = FALLBACK
    if s[0].isdigit():
        s = PREFIX + s
    return s[:MAX_LEN]


def is_short_name(s):
    """True if `s` already is a legal base name (and short_name(s) == s)."""
    return bool(_GOOD.match(s or ""))


def problem(s):
    """'' if `s` is a legal base name, else one sentence saying which rule it
    breaks - for an editor that has to say why it will not take a name."""
    if not s:
        return "the name is empty"
    bad = sorted(set(_BAD.findall(s)))
    if bad:
        return ("only A-Z, 0-9 and _ are allowed (not %s)"
                % " ".join(repr(c) for c in bad))
    if len(s) > MAX_LEN:
        return "at most %d characters (this is %d)" % (MAX_LEN, len(s))
    if s[0].isdigit():
        return "it cannot start with a digit"
    return ""


def unique_name(name, taken):
    """`name`, or a variant of it not in `taken`: the tail is overwritten with
    a counter, CHARGER0 -> CHARGE01, CHARGE02 ... (three digits after 99).
    `taken` is any container of names already assigned; it is not modified."""
    if name not in taken:
        return name
    n = 1
    while True:
        tail = "%02d" % n
        cand = name[:MAX_LEN - len(tail)] + tail
        if not cand[0].isdigit() and cand not in taken:
            return cand
        n += 1
