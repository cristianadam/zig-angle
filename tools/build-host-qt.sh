#!/bin/bash
# Build the host Qt that a cross build calls out to for its tools.
#
#   build-host-qt.sh <qt-source-root> <install-prefix> [module ...]
#
# Modules default to "qtbase qtshadertools qtdeclarative" and are built in the
# order given, each installed into the prefix before the next is configured.
#
# qtbase alone is enough for cross-building qtbase: all it needs from the host
# is moc, rcc, uic and friends, so a -no-gui build will do. It is not enough
# for anything on top - qtshadertools uses QtGui's rhi and qtdeclarative is Qt
# Quick - and without those two there is no qsb, qmltyperegistrar, qmlcachegen
# or qmlimportscanner for a cross build to call. So the GUI stays in here.
#
# Run it where the host compiler works: a Visual Studio developer prompt on
# Windows, an ordinary shell elsewhere. Nothing about this script is
# cross-compilation - it is the plain native build.
#
# Existing build directories are reused, so re-running it is incremental.
# BUILD_ROOT chooses where they go (default ./host-build).
set -u

SRC=${1:-}
PREFIX=${2:-}
if [ -z "$SRC" ] || [ -z "$PREFIX" ]; then
    echo "usage: $0 <qt-source-root> <install-prefix> [module ...]" >&2
    exit 1
fi
shift 2
MODULES=${*:-qtbase qtshadertools qtdeclarative}
BUILD_ROOT=${BUILD_ROOT:-$PWD/host-build}

for m in $MODULES; do
    if [ ! -d "$SRC/$m" ]; then
        echo "no such module: $SRC/$m" >&2
        exit 1
    fi
done

mkdir -p "$BUILD_ROOT" || exit 1

for m in $MODULES; do
    echo "===== $m ====="
    build=$BUILD_ROOT/$m
    extra=""
    if [ "$m" = qtbase ]; then
        # Nothing here is a host tool, and each costs build time or a
        # dependency the host may not have.
        extra="-DFEATURE_dbus=OFF -DFEATURE_icu=OFF"
    fi
    # shellcheck disable=SC2086
    cmake -S "$SRC/$m" -B "$build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DQT_BUILD_TESTS=OFF -DQT_BUILD_EXAMPLES=OFF \
        $extra || exit 1
    cmake --build "$build" --parallel || exit 1
    cmake --install "$build" || exit 1
done

echo
echo "host Qt in $PREFIX"
for t in moc rcc qsb qmltyperegistrar qmlcachegen qmlimportscanner; do
    if [ -x "$PREFIX/bin/$t" ] || [ -x "$PREFIX/bin/$t.exe" ]; then
        echo "  ok   $t"
    else
        echo "  none $t"
    fi
done
