#!/bin/bash
# Build the sysroot that ZIG_SYSROOT wants, for Qt's xcb platform plugin and
# ANGLE's Vulkan XCB display.
#
# Run it inside a Linux of the same distribution as the target - WSL will do,
# and from Windows the destination can be under /mnt/c. Nothing here needs
# root: apt-get download does not, and dpkg -x only unpacks.
#
#   ./make-linux-sysroot.sh <destination> [target-arch]
#
# target-arch defaults to the architecture of the machine running this. Asking
# for a different one fetches the packages by URL instead, since enabling a
# foreign architecture in dpkg would need root; these packages carry the same
# version on every architecture.
set -u

DEST=${1:-}
if [ -z "$DEST" ]; then
    echo "usage: $0 <destination> [target-arch]" >&2
    exit 1
fi
HOST_ARCH=$(dpkg --print-architecture)
ARCH=${2:-$HOST_ARCH}

case "$ARCH" in
    arm64) GNU_TRIPLE=aarch64-linux-gnu ;;
    amd64) GNU_TRIPLE=x86_64-linux-gnu ;;
    *) echo "unsupported architecture '$ARCH'" >&2; exit 1 ;;
esac

PKGS="libxcb1-dev libxcb-icccm4-dev libxcb-image0-dev libxcb-keysyms1-dev
      libxcb-randr0-dev libxcb-render-util0-dev libxcb-render0-dev
      libxcb-shape0-dev libxcb-shm0-dev libxcb-sync-dev libxcb-util-dev
      libxcb-xfixes0-dev libxcb-xinerama0-dev libxcb-xinput-dev libxcb-xkb-dev
      libxcb-cursor-dev libxcb-glx0-dev libxkbcommon-dev libxkbcommon-x11-dev
      libx11-dev libx11-xcb-dev libxau-dev libxdmcp-dev libxext-dev x11proto-dev
      libglx-dev libgl-dev libglvnd-dev
      libxcb1 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0
      libxcb-render-util0 libxcb-render0 libxcb-shape0 libxcb-shm0 libxcb-sync1
      libxcb-util1 libxcb-xfixes0 libxcb-xinerama0 libxcb-xinput0 libxcb-xkb1
      libxcb-cursor0 libxcb-glx0 libxkbcommon0 libxkbcommon-x11-0 libx11-6
      libx11-xcb1 libxau6 libxdmcp6 libxext6"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# apt drops privileges to the _apt user to download, and _apt cannot write a
# directory that only this user can reach - on a CI runner that turns into
# "E: Handler silently failed" and no packages. Sandbox as ourselves, and open
# the directory up as well, so neither mechanism can bite.
chmod 0755 "$STAGE"
APT_OPTS="-o APT::Sandbox::User=$(id -un)"
cd "$STAGE" || exit 1

missing=""
for p in $PKGS; do
    if [ "$ARCH" = "$HOST_ARCH" ]; then
        apt-get download $APT_OPTS "$p" >/dev/null 2>&1 || missing="$missing $p"
        continue
    fi
    # Foreign architecture: ask apt where it would get the package, then keep
    # only the pool path and put it on the archive that carries the target
    # architecture. Rewriting the host instead would assume the canonical
    # mirror - a GitHub runner is on azure.archive.ubuntu.com, and turning that
    # into azure.ports.ubuntu.com gets a name that does not resolve.
    uri=$(apt-get download $APT_OPTS --print-uris "$p" 2>/dev/null | awk '{print $1}' | tr -d "'")
    case "$uri" in
        */pool/*) ;;
        *) missing="$missing $p"; continue ;;
    esac
    if [ "$ARCH" = amd64 ]; then
        base=http://archive.ubuntu.com/ubuntu
    else
        base=http://ports.ubuntu.com/ubuntu-ports
    fi
    uri=$base/pool/${uri#*/pool/}
    uri=${uri//_$HOST_ARCH.deb/_$ARCH.deb}
    curl -fsSL -O "$uri" 2>/dev/null \
        || curl -fsSL -O "${uri//_$ARCH.deb/_all.deb}" 2>/dev/null \
        || missing="$missing $p"
done

echo "fetched $(ls -1 ./*.deb 2>/dev/null | wc -l) packages"
if [ -n "$missing" ]; then
    echo "could not fetch:$missing" >&2
    exit 1
fi

mkdir -p "$STAGE/root"
for d in ./*.deb; do dpkg -x "$d" "$STAGE/root" 2>/dev/null; done

rm -rf "$DEST"
mkdir -p "$DEST/include" "$DEST/lib"
cp -rL "$STAGE/root/usr/include/." "$DEST/include/" 2>/dev/null

# -L throughout: the destination may be on NTFS, which cannot hold the symlinks
# Debian uses here. Linking uses the "libfoo.so" name and the loader asks for
# the SONAME recorded inside the file, so both names have to be real files.
for so in "$STAGE/root/usr/lib/$GNU_TRIPLE/"*.so; do
    [ -e "$so" ] || continue
    cp -L "$so" "$DEST/lib/"
    soname=$(objdump -p "$so" 2>/dev/null | awk '/SONAME/ {print $2}')
    if [ -n "$soname" ] && [ ! -f "$DEST/lib/$soname" ]; then
        cp -L "$so" "$DEST/lib/$soname"
    fi
done

echo "sysroot at $DEST"
echo "  headers: $(find "$DEST/include" -name '*.h' | wc -l)"
echo "  libraries: $(ls -1 "$DEST/lib" | wc -l)"
du -sh "$DEST"

# Say so here rather than letting a half-built sysroot surface as a puzzling
# "xcb not found" from a configure step much later.
rc=0
for f in include/xcb/xcb.h include/xcb/xcb_icccm.h include/X11/Xlib.h          include/xkbcommon/xkbcommon-x11.h lib/libxcb.so lib/libxcb-cursor.so          lib/libxkbcommon-x11.so; do
    if [ ! -e "$DEST/$f" ]; then
        echo "  MISSING $f" >&2
        rc=1
    fi
done
[ "$rc" = 0 ] || echo "the sysroot is incomplete" >&2
exit $rc
