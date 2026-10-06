# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec - one-dir build with two exes sharing one runtime.

    dist/VBXE PAL Studio/
        VBXE PAL Studio.exe     windowed GUI          (packaging/gui_entry.py)
        palettize4.exe          console converter     (Convertor/palettize4.py)
        _internal/              Python + Qt + numpy + Pillow + scipy, once

MERGE() strips everything the CLI analysis shares with the GUI analysis, so the
converter exe rides on the GUI's _internal/ instead of shipping its own copy of
scipy.  build_app.ps1 (Windows) / build_app.sh (Linux) drive this - on Linux the
two binaries have no .exe suffix; see packaging/README.md.
"""

import os
import sys

from PyInstaller.utils.hooks import collect_all

REPO = os.path.dirname(os.path.abspath(SPECPATH))          # noqa: F821 (PyInstaller global)
CONVERTOR = os.path.join(REPO, 'Convertor')
# app.ico is a Windows resource; PyInstaller only warns and ignores it on Linux,
# so hand it over only where it means something.
ICON = os.path.join(REPO, 'packaging', 'app.ico') if sys.platform == 'win32' else None

# scipy is the fragile one to freeze - grab it whole rather than chase
# submodules.  numpy / Pillow / PySide6 all have solid built-in hooks.
_scipy_datas, _scipy_bins, _scipy_hidden = collect_all('scipy')

_EXCLUDES = [
    'tkinter', 'matplotlib', 'pytest', 'PyQt5', 'PyQt6', 'PySide2',
    'palgui.tests',
    # Qt add-ons the app never imports (pyside6_essentials does not even ship
    # most of these; listed so a stray transitive import cannot pull them in).
    'PySide6.QtQml', 'PySide6.QtQuick', 'PySide6.QtQuick3D',
    'PySide6.QtWebEngineCore', 'PySide6.QtWebEngineWidgets',
    'PySide6.QtMultimedia', 'PySide6.QtCharts', 'PySide6.QtDataVisualization',
    'PySide6.Qt3DCore', 'PySide6.QtPdf', 'PySide6.QtDesigner',
    'PySide6.QtSql', 'PySide6.QtTest', 'PySide6.QtNetworkAuth',
]

gui_a = Analysis(
    [os.path.join(REPO, 'packaging', 'gui_entry.py')],
    pathex=[CONVERTOR],
    binaries=list(_scipy_bins),
    datas=list(_scipy_datas),
    hiddenimports=[
        'palettize4',                       # runner.palettize4() imports it when frozen
        'atari_name',                       # imported by palettize4 + palgui.imageslst
        'nfo_encode',                       # imported by palettize4 + palgui.describe
        'PySide6.QtCore', 'PySide6.QtGui', 'PySide6.QtWidgets',
        'PIL.Image', 'PIL.ImageDraw',
        'scipy.ndimage', 'scipy.spatial', 'scipy.spatial.distance',
        'scipy.spatial._ckdtree',
    ] + list(_scipy_hidden),
    hookspath=[],
    runtime_hooks=[],
    excludes=_EXCLUDES,
    noarchive=False,
)

cli_a = Analysis(
    [os.path.join(CONVERTOR, 'palettize4.py')],
    pathex=[CONVERTOR],
    binaries=[],
    datas=[],
    hiddenimports=[
        'scipy.ndimage', 'scipy.spatial', 'scipy.spatial._ckdtree',
        'palgui',                           # __version__ for the report/.nfo
    ],
    hookspath=[],
    runtime_hooks=[],
    excludes=_EXCLUDES,
    noarchive=False,
)

# Deduplicate: cli_a keeps only what the GUI analysis does not already carry.
MERGE(
    (gui_a, 'gui_entry', os.path.join('VBXE PAL Studio', 'VBXE PAL Studio')),
    (cli_a, 'palettize4', os.path.join('VBXE PAL Studio', 'palettize4')),
)

gui_pyz = PYZ(gui_a.pure, gui_a.zipped_data)
cli_pyz = PYZ(cli_a.pure, cli_a.zipped_data)

gui_exe = EXE(
    gui_pyz, gui_a.scripts, [],
    exclude_binaries=True,
    name='VBXE PAL Studio',
    console=False,
    icon=ICON,
)

cli_exe = EXE(
    cli_pyz, cli_a.scripts, [],
    exclude_binaries=True,
    name='palettize4',
    console=True,
    icon=ICON,
)

COLLECT(
    gui_exe, gui_a.binaries, gui_a.zipfiles, gui_a.datas,
    cli_exe, cli_a.binaries, cli_a.zipfiles, cli_a.datas,
    strip=False,
    upx=False,
    name='VBXE PAL Studio',
)
