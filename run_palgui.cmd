@echo off
rem ---------------------------------------------------------------------------
rem run_palgui.cmd - launch VBXE PAL Studio (the palettize4 front end) from
rem anywhere.
rem
rem TWO THINGS HAVE TO BE TRUE AND NEITHER IS OBVIOUS, which is why this exists:
rem
rem   1. THE INTERPRETER MUST BE THE VENV'S.  Standing in .venv\Scripts does NOT
rem      put it on PATH - PowerShell does not search the current directory, so
rem      `python` there still resolves to the system install, which has no
rem      PySide6.  The full path below is not optional.
rem
rem   2. THE WORKING DIRECTORY MUST BE Convertor.  `-m palgui` imports the
rem      `palgui` package by name, and Python only finds it if its parent is on
rem      sys.path - which for the -m form means being the current directory.
rem      Get this wrong and it fails at import, before any of the app's own
rem      error handling can say anything useful.
rem
rem AND THE VENV NEEDS MORE THAN QT.  Preview shells out to palettize4.py under
rem the same interpreter, so numpy, Pillow and scipy have to be in there too.
rem Miss scipy and everything works until the first dithered run.
rem
rem %~dp0 is this script's own directory, so both are satisfied wherever it is
rem run from - a shell, a shortcut, or a double-click in Explorer.
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0Convertor"

if not exist "%~dp0.venv\Scripts\python.exe" (
    echo.
    echo The GUI's virtualenv is missing.  Create it with:
    echo.
    echo     python -m venv .venv
    echo     .venv\Scripts\python -m pip install PySide6 Pillow numpy scipy
    echo.
    echo palettize4.py itself needs none of Qt - it runs on any Python with
    echo numpy and Pillow:
    echo.
    echo     python Convertor\palettize4.py IMAGE.png --out build
    echo.
    pause
    exit /b 1
)

"%~dp0.venv\Scripts\python.exe" -m palgui %*
set ERR=%ERRORLEVEL%

rem Keep the window open on failure when double-clicked, so the traceback is
rem readable instead of vanishing with the console.
if not "%ERR%"=="0" pause
exit /b %ERR%
