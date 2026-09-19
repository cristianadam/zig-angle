#!/bin/bash
# Cross-build a Qt module with zig cc against an already installed target Qt.
#
#   xbuild-qt-module.sh <module-source> <toolchain-file> <target-qt-prefix> \
#                       <host-qt-prefix> [extra cmake args ...]
#
# The module is installed into the target Qt's prefix, so build them in
# dependency order - qtshadertools before qtdeclarative.
#
# Everything target-specific goes in the extra arguments. What each one tends
# to need:
#
#   Linux   -DZIG_SYSROOT=<root> -DZIG_GLIBC_VERSION=<ver>
#           and -DCMAKE_PREFIX_PATH additions for ANGLE, see below
#   Windows -DVulkan_INCLUDE_DIR=<dir> when the target Qt has Vulkan on:
#           Qt Quick guards its use of QRhiVulkanInitParams on QT_CONFIG(vulkan)
#           while rhi/qrhi_platform.h declares it under
#           QT_CONFIG(vulkan) && __has_include(<vulkan/vulkan.h>), so a module
#           that cannot see the headers compiles a call to something undeclared
#   macOS   -DANGLE_MACOS_SDK=<sdk> -DQT_XCRUN=<stub>
#           -DPython_EXECUTABLE=<python>, because Qt stops qt_find_package
#           consulting PATH on Apple (so a Mac build will not pick up Homebrew)
#           and that also hides host tools like Python, which qtdeclarative
#           requires as a code generator
#
# ANGLE_PREFIX, if set, is appended to CMAKE_PREFIX_PATH alongside the Qt one.
# BUILD_DIR overrides where the build tree goes.
set -u

SRC=${1:-}
TOOLCHAIN=${2:-}
PREFIX=${3:-}
HOST=${4:-}
if [ -z "$SRC" ] || [ -z "$TOOLCHAIN" ] || [ -z "$PREFIX" ] || [ -z "$HOST" ]; then
    echo "usage: $0 <module-source> <toolchain-file> <target-qt-prefix> <host-qt-prefix> [extra cmake args ...]" >&2
    exit 1
fi
shift 4

for p in "$SRC" "$TOOLCHAIN" "$PREFIX" "$HOST"; do
    if [ ! -e "$p" ]; then
        echo "does not exist: $p" >&2
        exit 1
    fi
done

name=$(basename "$SRC")
BUILD=${BUILD_DIR:-$PWD/$name-$(basename "$TOOLCHAIN" .cmake)}
search=$PREFIX
if [ -n "${ANGLE_PREFIX:-}" ]; then
    search="$PREFIX;$ANGLE_PREFIX"
fi

echo "===== $name -> $(basename "$TOOLCHAIN" .cmake) ====="
cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$search" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DQT_HOST_PATH="$HOST" \
    -DQT_BUILD_TESTS=OFF -DQT_BUILD_EXAMPLES=OFF \
    "$@" || exit 1
cmake --build "$BUILD" --parallel || exit 1
cmake --install "$BUILD" || exit 1

echo "installed $name into $PREFIX"
