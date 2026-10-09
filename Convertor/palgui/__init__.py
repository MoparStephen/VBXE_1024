"""palgui - VBXE PAL Studio, the GUI front end for palettize4.py.

palettize4.py HAS TWENTY-ONE FLAGS AND FOUR OF THEM CANNOT BE READ AS NUMBERS.
`--dither`, `--dither-strength`, `--color-bias` and `--coherence` are settings
you judge by looking at the picture, and judging them from a command line means
edit, re-run, open the PNG, forget what the last one looked like.  This is the
same converter with the loop closed: change a control, press Preview, and the
two images are side by side with a key that flips between them.

THE PREVIEW IS THE REAL CONVERTER, NOT A MODEL OF IT.  runner.py shells out to
palettize4.py exactly as you would from a shell, into a scratch directory, and
shows the {name}_preview.png it wrote.  Anything on screen is byte-for-byte
what Convert will put on disk - there is no second implementation of the packer
here to drift away from the first one.  It also means palettize4.py is not
modified by any of this; the --quiet/--json/{name}_stats.json interface it grew
in commit 4592645 is the whole contract.

Layered so everything below the UI runs headless and is testable without Qt:

    settings    one field per palettize4 flag; Settings.to_argv() is the
                single place that knows how a flag is spelled
    runner      resolve the script, build the argv, parse the stats, classify
                the failures palettize4 exits with
    presets     named Settings as JSON under palgui/presets/
    jobs        the batch queue as plain data
    ui.*        PySide6

Run `python -m palgui` from the Convertor directory, or use run_palgui.cmd /
run_palgui.sh at the repo root, which get the interpreter and the working
directory right for you.
"""

# The repo's single release number - must match the viewer's V_0..V_3 in
# Viewer/view1024.asm and the v* git tag; packaging/check_version.py enforces it.
__version__ = '0.25'
