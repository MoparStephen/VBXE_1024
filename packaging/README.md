# Standalone build

Turns the converter and its GUI into a folder a non-technical user can
unpack and double-click - no Python, no `pip`, no `PATH`, no venv. Windows
(`build_app.ps1` -> `.zip`) and Linux (`build_app.sh` -> `.tar.gz`) share one
PyInstaller spec.

## What comes out

```
VBXE PAL Studio/
    VBXE PAL Studio.exe     double-click this - the GUI
    palettize4.exe          the converter on the command line, same options as palettize4.py
    presets/                the four built-in recipes (also re-seeded on first run)
    out/                    created the first time you press Convert; one sub-folder per image
    _internal/              Python + Qt + numpy + Pillow + scipy - leave it alone
```

Everything the app writes (output images, saved presets, window layout via the
registry) stays with the user. **Keep the folder somewhere writable** - a
`Desktop`, `Documents` or a data drive. Dropped in `C:\Program Files`, presets
and `out/` can't be written next to the exe.

SciPy is bundled, so every dither mode works. Unzipped size is ~350-450 MB.

## Build it locally

```powershell
pwsh ./build_app.ps1            # from the repo root
pwsh ./build_app.ps1 -Clean     # nuke .venv-build / build / dist first
```

`build_app.ps1`:

1. makes `.venv-build` (its own venv, on `py -3.12` - **not** your source venv),
2. installs `packaging/requirements-build.txt`,
3. runs `pyinstaller packaging/vbxe_pal_studio.spec`,
4. copies `Convertor/palgui/presets/*.json` into the output folder,
5. zips `dist/VBXE PAL Studio/` to `VBXE PAL Studio v<version>.zip` (version from
   `Convertor/palgui/__init__.py`).

Build target: **Python 3.12** (3.13 usually fine). 3.14 - the version the source
venv currently uses - is bleeding-edge for PyInstaller and not a supported build
target here. The frozen app carries its own Python, so this is independent of
whatever you run from source.

## Build it on Linux

```bash
./build_app.sh                 # from the repo root
./build_app.sh --clean         # nuke .venv-build / build / dist first
PYTHON=python3.11 ./build_app.sh
```

Same five steps as `build_app.ps1`, same shared spec. Out comes
`VBXE PAL Studio v<version>-linux.tar.gz` wrapping the identical layout, with
`VBXE PAL Studio` and `palettize4` as extension-less ELF binaries.

**It cannot be cross-built.** PyInstaller bundles the *host* OS's Python and
native libraries, so a Linux binary has to be produced on Linux - there is no
Windows -> Linux path. Without a Linux machine, let CI do it (below).

Linux notes:

- Built on the GitHub `ubuntu-latest` runner, so it needs a glibc distro at
  least as new as that runner (Ubuntu 24.04 as of writing). It will not run on
  musl (Alpine).
- The GUI needs a desktop session (X11 or Wayland). `palettize4` is headless and
  runs anywhere.
- `tar xzf` should preserve the executable bit; if not,
  `chmod +x "VBXE PAL Studio/VBXE PAL Studio" "VBXE PAL Studio/palettize4"`.
- No AppImage, no `.deb`, unsigned - same "unpack it somewhere writable" model as
  Windows.

## Release it

The repo has ONE version number, the viewer's (`v0.16` = the `0.16` on the
Atari loading screen), and the converter app is released under the same one.
Three places must agree before tagging:

| Where | What |
|---|---|
| `Viewer/view1024.asm` | `V_0`..`V_3` screen codes (`$10`-`$19` = digits, `V_3` `$00` or a letter) |
| `Convertor/palgui/__init__.py` | `__version__ = '0.16'` - names the zip / tar.gz |
| the git tag | `v0.16` |

Check, commit, then push an annotated tag:

```
python packaging/check_version.py v0.16
git tag -a v0.16 -m "v0.16: <one-line summary>"
git push origin v0.16
```

The workflow's `check-version` job runs the same script first and fails the
release if any of the three disagree.

The release also carries the Atari viewer, `view1024.xex`. CI cannot assemble
it (MADS and the external Libraries repo), so it attaches the **committed**
`Viewer/out/view1024.xex` - rebuild and commit it after bumping `V_0`..`V_3`.
`check_version.py` looks for the version string inside the xex and fails with
"STALE - not rebuilt" if you forgot.

`.github/workflows/release.yml` has two jobs - `build-windows` (`windows-latest`)
and `build-linux` (`ubuntu-latest`, which also smoke-tests the frozen binaries) -
and each attaches its archive to the same GitHub Release, so the tag ends up with
both the `.zip` and the `-linux.tar.gz`. `workflow_dispatch` also lets you run it
by hand from the Actions tab (artifacts only, no Release).

## Files here

| File | Purpose |
|---|---|
| `vbxe_pal_studio.spec` | PyInstaller spec - two `Analysis`, `MERGE`, one `COLLECT` |
| `gui_entry.py` | frozen GUI entry point (no `--selftest` / venv-advice branches) |
| `make_icon.py` / `app.ico` | generates and holds the app icon |
| `requirements-build.txt` | build-only deps (PyInstaller + the runtime libs) |

## Known limitations

- **Unsigned.** SmartScreen may show "Windows protected your PC" on first run -
  *More info -> Run anyway*. Code signing is out of scope.
- `MERGE` in the spec dedupes the converter's runtime against the GUI's. If a
  PyInstaller upgrade ever breaks it, build `palettize4` as `--onefile` into the
  same folder instead (~80 MB larger, no MERGE).
- The GUI's `--selftest` is a from-source tool; it is not wired into the frozen
  build.
- A build has been seen to fail once with `Exception: Qt plugin directory
  '...PySide6/plugins' does not exist!` in the PySide6 hook, then succeed on a
  `-Clean` rebuild against the same versions. If you hit it, rerun with
  `pwsh ./build_app.ps1 -Clean`.
- **"Access to the path '...\_internal\PySide6\...qoffscreen.dll' is denied"**
  means a process is holding `dist\VBXE PAL Studio\_internal\**` open - almost
  always a **running `VBXE PAL Studio.exe`** (an Explorer preview pane or an
  antivirus scan can also do it). Close it and rerun. `build_app.ps1` now
  checks for a running instance up front and says so.
- **Build on Python 3.10-3.13.** PyInstaller 6.x + PySide6 6.11 are not reliable
  on 3.14 (the version the source venv uses). `build_app.ps1` picks a supported
  interpreter automatically; the CI workflow pins 3.12.
