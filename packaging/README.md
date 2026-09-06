# Standalone Windows build

Turns the converter and its GUI into a folder a non-technical Windows user can
unzip and double-click - no Python, no `pip`, no `PATH`, no venv.

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

## Release it

Push a tag:

```
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yml` builds on `windows-latest` and attaches the zip
to a GitHub Release. `workflow_dispatch` also lets you run it by hand from the
Actions tab (artifact only, no Release).

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
- **Build on Python 3.10-3.13.** PyInstaller 6.x + PySide6 6.11 are not reliable
  on 3.14 (the version the source venv uses). `build_app.ps1` picks a supported
  interpreter automatically; the CI workflow pins 3.12.
