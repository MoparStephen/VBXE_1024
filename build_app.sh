#!/usr/bin/env bash
#
# Build the standalone Linux app (VBXE PAL Studio + palettize4) and tar it.
#
# The Linux counterpart of build_app.ps1: an isolated build venv, the deps in
# packaging/requirements-build.txt, PyInstaller against
# packaging/vbxe_pal_studio.spec, the shipped presets seeded in, and
# dist/VBXE PAL Studio/ packed into "VBXE PAL Studio v<ver>-linux.tar.gz".
#
# Independent of the .venv used to run from source - it makes its own
# .venv-build and never touches yours.
#
#   ./build_app.sh            # from the repo root
#   ./build_app.sh --clean    # nuke .venv-build / build / dist first
#   PYTHON=python3.11 ./build_app.sh   # force the build interpreter
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

SPEC="packaging/vbxe_pal_studio.spec"
REQS="packaging/requirements-build.txt"
VENV_DIR=".venv-build"
BUILD_DIR="build"
DIST_DIR="dist"
APP_NAME="VBXE PAL Studio"
APP_DIR="$DIST_DIR/$APP_NAME"
PRESET_SRC="Convertor/palgui/presets"
INIT_PY="Convertor/palgui/__init__.py"

step() { printf '\n=== %s ===\n' "$1"; }

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# --- version, straight out of the package -----------------------------------
VERSION="$(sed -n "s/^__version__[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$INIT_PY" | head -n1)"
[ -n "$VERSION" ] || { echo "could not read __version__ from $INIT_PY" >&2; exit 1; }
echo "VBXE PAL Studio v$VERSION"

# --- clean ----------------------------------------------------------------------
if [ "$CLEAN" -eq 1 ]; then
    step "Clean"
    for d in "$VENV_DIR" "$BUILD_DIR" "$DIST_DIR"; do
        [ -e "$d" ] && { rm -rf "$d"; echo "removed $d"; }
    done
fi

# --- pick an interpreter ------------------------------------------------------
step "Locate Python"
pick_python() {
    if [ -n "${PYTHON:-}" ]; then echo "$PYTHON"; return; fi
    for c in python3.12 python3.13 python3.11 python3.10 python3; do
        if command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
    done
    return 1
}
PY="$(pick_python)" || { echo "no usable python3 found (tried python3.12..python3)" >&2; exit 1; }
PYVER="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
echo "using $PY  (Python $PYVER)"
case "$PYVER" in
    3.10|3.11|3.12|3.13) ;;
    *) echo "warning: Python $PYVER is outside the tested range 3.10-3.13; PyInstaller/PySide6 may misbehave. Continuing." >&2 ;;
esac

# --- build venv --------------------------------------------------------------
step "Build venv"
VENV_PY="$VENV_DIR/bin/python"
if [ ! -x "$VENV_PY" ]; then
    "$PY" -m venv "$VENV_DIR"
fi
"$VENV_PY" -m pip install --upgrade pip
"$VENV_PY" -m pip install -r "$REQS"

# --- PyInstaller -----------------------------------------------------------------
step "PyInstaller"
rm -rf "$APP_DIR"
"$VENV_PY" -m PyInstaller --clean --noconfirm \
    --distpath "$DIST_DIR" --workpath "$BUILD_DIR" \
    "$SPEC"
[ -x "$APP_DIR/$APP_NAME" ] || { echo "expected '$APP_DIR/$APP_NAME' - build produced nothing usable" >&2; exit 1; }

# --- seed the shipped presets ----------------------------------------------------
step "Presets"
mkdir -p "$APP_DIR/presets"
cp -f "$PRESET_SRC"/*.json "$APP_DIR/presets/"
echo "copied $(ls "$APP_DIR/presets"/*.json | wc -l) preset(s)"

# --- make the binaries executable (COLLECT does, but be explicit) -------------
chmod +x "$APP_DIR/$APP_NAME" "$APP_DIR/palettize4"

# --- tar ----------------------------------------------------------------------
step "Package"
TARBALL="$APP_NAME v$VERSION-linux.tar.gz"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$DIST_DIR" "$APP_NAME"
MB="$(du -m "$TARBALL" | cut -f1)"
printf '\nBuilt %s (%s MB)\n' "$TARBALL" "$MB"
echo "Folder: $APP_DIR"
