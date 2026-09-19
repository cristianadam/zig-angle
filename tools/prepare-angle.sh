#!/bin/bash
# Turn a plain ANGLE checkout into one this project can build against.
#
#   prepare-angle.sh [-f] [angle-checkout]    (default: third_party/angle)
#
# Two things are missing from a bare clone.
#
# Dependencies. ANGLE's are gclient DEPS rather than submodules, so cloning the
# repository does not bring them, and gclient itself pulls gigabytes of
# Chromium build infrastructure that is not needed here: ANGLE carries its own
# SPIR-V builder and parser, vendors volk, and checks its Vulkan internal
# shaders in pre-compiled, so glslang is a generation-time tool rather than a
# build dependency. Five directories are actually required. Their revisions are
# read out of the checkout's own DEPS, so they follow whatever commit the
# submodule is pinned to instead of drifting away from it, and they are fetched
# from the Chromium mirror DEPS names - which is the only source for
# VulkanMemoryAllocator, whose pinned revision does not exist upstream.
#
# Generated source lists. The build reads ANGLE's file lists from
# Compiler.cmake and friends, produced from the GN build files by the converter
# WebKit ships. Upstream does not carry that script, so point WEBKIT_ANGLE_DIR
# at a WebKit ANGLE directory the first time; it is copied in and patched with
# tools/gni-to-cmake.patch. See the README for what the two fixes are.
#
# Re-running is cheap: dependencies already at the right revision are left
# alone, and the CMake lists are only regenerated with -f.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
FORCE=0
if [ "${1:-}" = "-f" ]; then
    FORCE=1
    shift
fi
ANGLE=${1:-$HERE/../third_party/angle}

if [ ! -f "$ANGLE/DEPS" ] || [ ! -f "$ANGLE/src/libGLESv2.gni" ]; then
    echo "not an ANGLE checkout: $ANGLE" >&2
    exit 1
fi
ANGLE=$(cd "$ANGLE" && pwd)

CHROMIUM_GIT=https://chromium.googlesource.com

# Pull "<path-after-the-host>@<sha>" out of the DEPS entry for a given path.
# Both spellings appear: '{chromium_git}/x@sha' and Var('chromium_git') + '/x@sha'.
dep_spec() {
    awk -v want="'$1':" '
        index($0, want) { found = 1 }
        found && /url/ {
            if (match($0, /\/[^"'\''+]*@[0-9a-f]{40}/)) {
                print substr($0, RSTART, RLENGTH)
            }
            exit
        }
    ' "$ANGLE/DEPS"
}

DEP_PATHS="
third_party/vulkan-headers/src
third_party/spirv-headers/src
third_party/spirv-tools/src
third_party/vulkan_memory_allocator
third_party/zlib
"

for path in $DEP_PATHS; do
    spec=$(dep_spec "$path")
    if [ -z "$spec" ]; then
        echo "no DEPS entry for $path" >&2
        exit 1
    fi
    rev=${spec##*@}
    url=$CHROMIUM_GIT${spec%@*}
    dir=$ANGLE/$path

    if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$rev" ]; then
        echo "  have  $path"
        continue
    fi
    echo "  fetch $path @ ${rev:0:12}"
    mkdir -p "$dir" || exit 1
    git -C "$dir" init -q 2>/dev/null
    if ! git -C "$dir" fetch -q --depth 1 "$url" "$rev"; then
        echo "failed to fetch $rev from $url" >&2
        exit 1
    fi
    git -C "$dir" checkout -q FETCH_HEAD || exit 1
done

# --- the generated source lists ------------------------------------------
if [ "$FORCE" = 0 ] && [ -f "$ANGLE/GLESv2.cmake" ]; then
    echo "  have  the generated CMake lists (-f to regenerate)"
    exit 0
fi

# The converter is Apple's, carried in WebKit rather than upstream ANGLE. Take
# it from a local WebKit checkout if there is one, otherwise fetch the single
# file. The revision is pinned because tools/gni-to-cmake.patch has to apply.
WEBKIT_REV=${WEBKIT_REV:-69dd461c251a}
WEBKIT_RAW=https://raw.githubusercontent.com/WebKit/WebKit/$WEBKIT_REV/Source/ThirdParty/ANGLE/gni-to-cmake.py

if [ ! -f "$ANGLE/gni-to-cmake.py" ]; then
    if [ -n "${WEBKIT_ANGLE_DIR:-}" ] && [ -f "$WEBKIT_ANGLE_DIR/gni-to-cmake.py" ]; then
        echo "  copy  gni-to-cmake.py from $WEBKIT_ANGLE_DIR"
        cp "$WEBKIT_ANGLE_DIR/gni-to-cmake.py" "$ANGLE/gni-to-cmake.py" || exit 1
    else
        echo "  fetch gni-to-cmake.py from WebKit $WEBKIT_REV"
        curl -fsSL "$WEBKIT_RAW" -o "$ANGLE/gni-to-cmake.py" || {
            echo "could not fetch $WEBKIT_RAW; set WEBKIT_ANGLE_DIR instead" >&2
            exit 1
        }
    fi
    if ! ( cd "$ANGLE" && patch -p1 --forward < "$HERE/gni-to-cmake.patch" ); then
        echo "tools/gni-to-cmake.patch did not apply to this gni-to-cmake.py" >&2
        rm -f "$ANGLE/gni-to-cmake.py"
        exit 1
    fi
fi

# Without this the converter reads .gni files as cp1252 and dies on the first
# non-ASCII byte.
export PYTHONUTF8=1
# Not just "is it on PATH": Windows ships a python3 that is a Store shim and
# exits telling you to install one.
PY=""
for cand in ${PYTHON:-} python3 python py; do
    [ -n "$cand" ] || continue
    if "$cand" -c "import sys" >/dev/null 2>&1; then
        PY=$cand
        break
    fi
done
if [ -z "$PY" ]; then
    echo "no working Python found; set PYTHON=<interpreter>" >&2
    exit 1
fi
if ! "$PY" -c "import ply" >/dev/null 2>&1; then
    echo "the converter needs ply: $PY -m pip install ply" >&2
    exit 1
fi

gen() {
    echo "  generate $2"
    ( cd "$ANGLE" && "$PY" gni-to-cmake.py "$@" ) || exit 1
}
gen src/compiler.gni Compiler.cmake
gen src/libGLESv2.gni GLESv2.cmake
gen src/libANGLE/renderer/gl/BUILD.gn GL.cmake --prepend src/libANGLE/renderer/gl/
gen src/libANGLE/renderer/d3d/BUILD.gn D3D.cmake --prepend src/libANGLE/renderer/d3d/
gen src/libANGLE/renderer/metal/BUILD.gn Metal.cmake --prepend src/libANGLE/renderer/metal/
gen src/libANGLE/renderer/vulkan/BUILD.gn Vulkan.cmake --prepend src/libANGLE/renderer/vulkan/

echo "ANGLE ready at $ANGLE"
