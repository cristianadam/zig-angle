# zig-angle

Cross-compiles [ANGLE](https://chromium.googlesource.com/angle/angle) — the copy
vendored in WebKit at `Source/ThirdParty/ANGLE` — with `zig cc` / `zig c++`,
driven by CMake and the toolchain from
[zig-cross](https://github.com/cristianadam/zig-cross).

One Windows host builds Linux, Windows and macOS libraries. The output for each
target is what a consumer of ANGLE actually needs:

```
dist/<triple>/
  include/              EGL/ GLES/ GLES2/ GLES3/ KHR/ GLSLANG/ platform/
                        angle_gl.h  export.h
  lib/                  libGLESv2.so / .dylib, libEGL.so / .dylib
                        (Windows: import libs libGLESv2.dll.a, libEGL.dll.a)
  lib/pkgconfig/        egl.pc, glesv2.pc
  lib/cmake/ANGLE/      ANGLEConfig.cmake, ANGLEConfigVersion.cmake
  bin/                  angle_smoke, the consumer test
                        (Windows: also libGLESv2.dll, libEGL.dll)
```

The workflow presets install, so `dist/<triple>` is populated by
`cmake --workflow --preset <triple>`. The build tree holds only the libraries;
headers and package metadata appear at install time.

Nothing is copied out of or written into the WebKit checkout; `ANGLE_SOURCE_DIR`
is read-only input.

## Prerequisites

| Tool  | Version                                    |
| ----- | ------------------------------------------ |
| zig   | **0.17.0-dev or newer** (see note below)   |
| CMake | 3.25+ (workflow presets)                   |
| Ninja | any                                        |

> **zig 0.16.0 does not work on ARM64 Windows hosts.** It segfaults the moment
> the bundled clang driver is invoked — even `zig cc --version` dies with an
> access violation, and the official ziglang.org build behaves the same as the
> winget one, so it is not a packaging problem. The fix is in master; use a
> 0.17.0-dev build from <https://ziglang.org/download/>. Check yours with
> `zig cc --version` — `zig version` alone will happily lie to you.

The first configure downloads zlib 1.3.1 (ANGLE compresses program binaries with
it). Point `-DZLIB_SOURCE_DIR=<path>` at an existing zlib checkout to build
offline.

## Building

Everything is driven by CMake presets, one per target triple. Set whichever of
these apply, once:

```powershell
$env:ZIG_EXECUTABLE       = "C:\tools\zig-0.17.0-dev\zig.exe"  # if PATH zig is not the one you want
$env:ANGLE_MACOS_SDK      = "D:\sdks\MacOSX15.5.sdk"           # required for macOS targets
$env:ANGLE_LLVM_TOOLS_DIR = "C:\llvm\bin"                      # enables the static tests
```

then configure, build and test a target in one command:

```sh
cmake --workflow --preset aarch64-linux-gnu
```

or drive the steps separately:

```sh
cmake --preset aarch64-linux-gnu
cmake --build --preset aarch64-linux-gnu
ctest --preset aarch64-linux-gnu
cmake --install build/aarch64-linux-gnu     # installDir comes from the preset
```

`cmake --list-presets` shows what is available. Each preset builds into
`build/<triple>` and installs into `dist/<triple>`. Anything settable by
environment variable can equally be passed as `-D` at configure time.

## The test program

`tests/angle_smoke.cpp` is built for every target and installed as
`dist/<triple>/bin/angle_smoke`. It is deliberately written as a *consumer*:
it includes only the public headers from `include/` and links only libEGL and
libGLESv2, so anything missing from the installed tree shows up as a compile or
link error rather than being silently papered over by the build's own private
include paths.

The context it creates is the one a WebGL implementation asks ANGLE for:

| Attribute                                     | Why                                         |
| --------------------------------------------- | ------------------------------------------- |
| `EGL_CONTEXT_WEBGL_COMPATIBILITY_ANGLE`        | tightens validation to WebGL's rules         |
| `EGL_ROBUST_RESOURCE_INITIALIZATION_ANGLE`     | WebGL forbids reading uninitialized memory   |

Both are negotiated — the program queries the display extension string first and
reports what it got. What it checks:

* a pbuffer config and surface, and a current context;
* a shader compiles and a program links (this is the path that actually runs
  ANGLE's translator — on D3D11 it goes all the way to HLSL);
* a triangle renders and `glReadPixels` returns the expected green;
* with robust resource initialization on, an untouched renderbuffer reads back
  as all zeros — the guarantee WebGL depends on.

It takes an optional backend argument (`default`, `d3d11`, `gl`, `gles`,
`metal`, `vulkan`, `null`) and selects it through `EGL_ANGLE_platform_angle`.

## Verifying with CTest

`ctest --preset <triple>` runs three tests:

| Test            | Label     | What it does                                                   |
| --------------- | --------- | -------------------------------------------------------------- |
| `angle.exports` | `static`  | counts exported `gl*` / `egl*` entry points                     |
| `angle.linkage` | `static`  | libEGL really loads libGLESv2; no host paths or backslashes     |
| `angle.smoke`   | `runtime` | runs `angle_smoke` — added only when the host can execute it   |

The two static tests inspect the binaries rather than running them, so they work
for every target. They shell out to `llvm-nm`, `llvm-readelf`, `llvm-readobj`
and `llvm-objdump` (zig does not bundle those); without them the tests are
skipped and configure says so. Point `ANGLE_LLVM_TOOLS_DIR` at any LLVM `bin`
to enable them.

The export counts are the load-bearing check: a library can link perfectly and
still export nothing at all — see *Exported symbols* below.

`angle.smoke` is added when the build host happens to be able to execute the
target, which covers more cases than you would expect:

* **Windows targets on a Windows host.** An ARM64 host also runs the x64 and x86
  builds under emulation.
* **Linux targets under WSL,** when the distro's architecture matches the target
  and the ABI is glibc. Configure discovers this itself, translates the build
  directory with `wslpath` and runs the binary through `wsl`. A musl target is
  skipped, since it would need its own loader.

Otherwise configure reports that there is no way to run the target here and the
test is simply not registered. If the binary runs but EGL cannot be brought up
— a headless box, no driver — `angle_smoke` exits 77 and CTest records a skip
rather than a failure, because that says nothing about the build.

```
$ cmake --workflow --preset aarch64-linux-gnu
-- zig-angle: angle.smoke will run under WSL (aarch64)
...
1/3 Test #1: angle.exports ....................   Passed    0.14 sec
2/3 Test #2: angle.linkage ....................   Passed    0.07 sec
3/3 Test #3: angle.smoke ......................   Passed    4.36 sec
100% tests passed out of 3
```

Use `ctest --preset <triple> -L static` to skip anything that needs a GPU.

## Consuming the result

Two discovery mechanisms are installed, because different build systems reach
for different ones.

**CMake.** `find_package(ANGLE)` gives you `ANGLE::GLESv2` and `ANGLE::EGL`:

```cmake
find_package(ANGLE REQUIRED)
target_link_libraries(app PRIVATE ANGLE::EGL)   # pulls in ANGLE::GLESv2
```

```sh
cmake -B b --toolchain <zig-angle>/toolchains/aarch64-linux-gnu.cmake \
      -DCMAKE_PREFIX_PATH=<zig-angle>/dist/aarch64-linux-gnu
```

`ANGLE_BACKENDS` and `ANGLE_VERSION` are set too, so a consumer can check which
renderers the build actually has.

The config file is written by hand rather than produced by `install(EXPORT)`.
libGLESv2 and libEGL link the ANGLE static library, zlib and (with Vulkan)
SPIRV-Tools privately, and an exported target set would drag all of those into
the package as `$<LINK_ONLY:...>` entries that consumers have no business
seeing.

**pkg-config.** `egl.pc` and `glesv2.pc` are relocatable — `prefix` is derived
from `${pcfiledir}`, so moving the tree or mounting it elsewhere in a sysroot
does not invalidate them:

```sh
PKG_CONFIG_PATH=<dist>/lib/pkgconfig pkg-config --cflags --libs egl
```

### Building Qt against it

Qt does not look for a package called ANGLE. It goes through
extra-cmake-modules' `FindEGL`, which starts with `pkg_check_modules(egl)` and
uses the result as hints for `find_path`/`find_library`, and then Qt's own
`FindGLESv2`, which does the same for GLESv2 and compiles a test program
linking both. Installing the `.pc` files is what makes that work without
hand-feeding Qt paths.

qtbase 6.13.0 cross-compiles against this with zig cc, for both
`x86_64-linux-gnu` and `aarch64-linux-gnu`, and `libQt6Gui.so` comes out linked
against our `libGLESv2.so` and `libEGL.so`:

```
Building for: linux-clang (x86_64)      Compiler: clang 22.1.8
  EGL .................................... yes
  OpenGL ES 2.0 / 3.0 / 3.1 / 3.2 ........ yes
  EGLFS .................................. yes
```

```sh
cmake -S <qt>/qtbase -B build-qt -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=<zig-angle>/toolchains/x86_64-linux-gnu.cmake \
    -DZIG_GLIBC_VERSION=2.34 \
    -DQT_HOST_PATH=<host qt of the same version> \
    -DCMAKE_PREFIX_PATH=<zig-angle>/dist/x86_64-linux-gnu \
    -DINPUT_opengl=es2 \
    -DFEATURE_dbus=OFF -DFEATURE_glib=OFF -DFEATURE_icu=OFF -DFEATURE_xcb=OFF
```

Qt needs no patching for this: it sees an ordinary `linux-clang` build. The two
adjustments both live in the toolchain and are described under *zig cc
limitations* below - PCH must be off, and `ZIG_GLIBC_VERSION=2.34` is required
because `qprocess_unix.cpp` calls `close_range()`.

`QT_HOST_PATH` must point at a host Qt of *exactly* the version being built, so
in practice you build host tools first; `-no-gui -no-widgets -nomake tests
-nomake examples` is enough and takes a few minutes.

**How far this runs.** The aarch64 build executes on a real target (tested under
WSL), Qt loads the platform plugins, and Qt's EGL path opens and initialises an
ANGLE display:

```
qt.qpa.plugin: Successfully loaded Qt platform plugin "eglfs"
Initialized display 1 5
```

Getting that far needs the Vulkan backend plus `ANGLE_DEFAULT_PLATFORM=vulkan`
in the environment, because Qt calls plain `eglGetDisplay(EGL_DEFAULT_DISPLAY)`
and passes none of ANGLE's platform attributes. With the GL backend that
returns `EGL_NO_DISPLAY`: `CreateDisplayFromAttribs` only reaches `DisplayEGL`
when the caller asks for `EGL_PLATFORM_ANGLE_DEVICE_TYPE_EGL_ANGLE`, and
nothing in the environment ever selects it. The Vulkan backend has a usable
fallback, which this build enables with `ANGLE_USE_VULKAN_DISPLAY`.

Window surfaces need one more choice. The display that fallback lands on is
itself a compile-time decision, set with `ANGLE_VULKAN_DISPLAY_MODE`:

| Mode        | Display                        | Window surfaces                    |
| ----------- | ------------------------------ | ---------------------------------- |
| `offscreen` | `CreateVulkanOffscreenDisplay` | no - `EGL_BAD_NATIVE_WINDOW`       |
| `headless`  | `VK_EXT_headless_surface`      | yes, with no display hardware      |
| `simple`    | `VK_KHR_display`               | yes, scanning out to a connector   |

`offscreen` is the default because it asks least of the driver. With
`-DANGLE_VULKAN_DISPLAY_MODE=headless` a full Qt application runs:

```
$ QT_QPA_PLATFORM=eglfs ANGLE_DEFAULT_PLATFORM=vulkan ./qtgl
GL_VENDOR  : Google Inc. (Mesa)
GL_RENDERER: ANGLE (Mesa, Vulkan 1.4.318 (llvmpipe (LLVM 20.1.2 128 bits)), llvmpipe-25.2.8)
GL_VERSION : OpenGL ES 3.1 (ANGLE 2.1.1 git hash: 97941c8fa290)
qtgl: PASS
```

That is Qt's eglfs QPA plugin, going through EGL into ANGLE, onto Vulkan. One
environment setting is still doing real work: eglfs's base device integration
insists on opening a framebuffer node, so `QT_QPA_EGLFS_FB` has to point
somewhere readable (`/dev/zero` will do) with
`QT_QPA_EGLFS_WIDTH`/`HEIGHT` supplying the size. On real hardware with a
framebuffer or a KMS device none of that is needed.

`simple` mode is the one for actual display hardware, and it is also what Qt's
own `vkkhrdisplay` platform plugin wants. Be aware that a driver can advertise
`VK_KHR_display` and still report no displays - llvmpipe does exactly that, so
neither `simple` mode nor `vkkhrdisplay` is testable under WSL.

#### Qt's own Vulkan support

Separate from ANGLE, and worth knowing about because the pieces are already
here. Qt's `vkkhrdisplay` platform plugin renders with Vulkan directly, so it
does not involve ANGLE at all - it refuses OpenGL outright:

```
vkkhrdisplay platform plugin only supports QWindow with surfaceType == VulkanSurface
```

`QT_FEATURE_vulkan` needs only **headers**; `WrapVulkanHeaders` does not look
for a library, because `QVulkanInstance` loads libvulkan at runtime. The
vulkan-headers already fetched for ANGLE's Vulkan backend serve:

```sh
cmake <qt build> -DVulkan_INCLUDE_DIR=<angle>/third_party/vulkan-headers/src/include                  -DFEATURE_vulkan=ON
```

`-DFEATURE_vulkan=ON` is only needed on a tree that was first configured
*without* the headers: Qt pins the user-facing `FEATURE_*` entries in the
cache, so the computed condition never gets a look in afterwards. Configure
fresh with `Vulkan_INCLUDE_DIR` set and it comes out `yes` on its own.

`libqvkkhrdisplay.so` then builds, and Qt's Vulkan works -
`QVulkanInstance::create()` succeeds, 24 extensions, llvmpipe enumerated. The
plugin just cannot find a display to scan out to under WSL.

A clean configure of qtbase with EGL, OpenGL ES and Vulkan all on builds
1490/1490, and both paths run:

```
===== Qt OpenGL ES through ANGLE (eglfs) =====
GL_RENDERER: ANGLE (Mesa, Vulkan 1.4.318 (llvmpipe), llvmpipe-25.2.8)
GL_VERSION : OpenGL ES 3.1 (ANGLE 2.1.1)
qtgl: PASS

===== Qt Vulkan directly (vkkhrdisplay) =====
physical devices: 1
   llvmpipe (LLVM 20.1.2, 128 bits)
qtvk: PASS
```

Also worth stating: Qt wants far more from a sysroot than GL - fontconfig,
xkbcommon, the platform integration of your choice - none of which this project
provides. The configuration above disables what it can and uses Qt's bundled
copies of zlib, libpng, libjpeg, freetype, harfbuzz and pcre2.

## Targets and backends

| Triple                | Renderer backends          | Needs                |
| --------------------- | -------------------------- | -------------------- |
| `x86_64-linux-gnu`    | OpenGL via EGL (`dlopen`)  | —                    |
| `aarch64-linux-gnu`   | OpenGL via EGL (`dlopen`)  | —                    |
| `x86_64-linux-musl`   | OpenGL via EGL (`dlopen`)  | —                    |
| `aarch64-linux-musl`  | OpenGL via EGL (`dlopen`)  | —                    |
| `x86_64-windows-gnu`  | D3D11 + D3D9 + WGL         | —                    |
| `aarch64-windows-gnu` | D3D11 + D3D9 + WGL         | —                    |
| `x86-windows-gnu`     | D3D11 + D3D9 + WGL         | —                    |
| `x86_64-macos-none`   | Metal                      | a macOS SDK          |
| `aarch64-macos-none`  | Metal                      | a macOS SDK          |

Add a triple by dropping a two-line `toolchains/<triple>.cmake` next to the
existing ones.

### Why these backends

* **Linux** uses ANGLE's `gl/egl` backend, which `dlopen`s the system
  `libEGL.so.1` at runtime. That is the configuration WebKit's GTK/WPE ports
  use, and the GLX alternative would need X11 development headers that zig does
  not bundle. Vulkan is available too, from an upstream checkout — see below.

  The libraries deliberately carry no `SOVERSION`, matching what upstream ANGLE
  ships. `DisplayEGL` looks the vendor driver up as exactly `libEGL.so.1`, so
  shipping our own `libEGL.so.1` would let ANGLE `dlopen` itself.

  **A Linux consumer has to ask for the display explicitly.** With no X11,
  Wayland or GBM compiled in, `CreateDisplayFromAttribs` has only two routes to
  a `DisplayEGL`: an explicit `EGL_PLATFORM_ANGLE_DEVICE_TYPE_EGL_ANGLE`, or
  `EGL_PLATFORM_SURFACELESS_MESA`. A plain `eglGetDisplay(EGL_DEFAULT_DISPLAY)`
  hands back `EGL_NO_DISPLAY` — and, unhelpfully, leaves `eglGetError()` at
  `EGL_SUCCESS`. `tests/angle_smoke.cpp` shows the attribute list to use; it is
  what WebKit's GTK and WPE ports pass.

* **Windows** gets the full set. zig ships the mingw-w64 headers, which cover
  `d3d11.h` / `d3d9.h` / `dxgi.h`, and synthesises import libraries from the
  bundled `.def` files. One substitution is needed: `common/SimpleMutex.cpp`
  wants `WaitOnAddress`, which MSVC gets from `synchronization.lib` — there is
  no mingw equivalent, so the build links the API-set library
  `api-ms-win-core-synch-l1-2-0` instead.

  D3D11 is ANGLE's default on Windows and is the path `angle_smoke` exercises.
  The WGL backend builds but was seen to crash inside `eglInitialize` on an
  ARM64 Windows box that has no desktop-GL ICD registered — only Microsoft's
  software `opengl32.dll`. That looks like ANGLE failing ungracefully with
  nothing to sit on rather than a problem with this build, and it does not
  affect the default path, so the backend is left enabled. Turn it off with
  `-DANGLE_ENABLE_OPENGL=OFF` if you would rather it were not there.

* **macOS** gets Metal. ANGLE compiles the backend's internal shaders at runtime
  from MSL embedded in `mtl_internal_shaders_src_autogen.h`, so Apple's `metal`
  compiler is never invoked — but an SDK is still required, see below.

### Cross-building Qt for macOS

Qt's build system assumes it is running on a Mac.
`qt_build_internals_set_up_private_api`, on the critical path of every
Apple-targeted configure, calls out to `xcrun`:

```
CMake Error at cmake/QtPublicAppleHelpers.cmake:901:
  Can't find xcrun in PATH
```

It only asks three questions (`--show-sdk-path`, `--show-sdk-version`,
`xcodebuild -version`), so a stub binary gets past it - `find_program` on
Windows only considers `.exe`/`.com`, and priming `-DQT_XCRUN=` is easier
still. Qt then configures as `macx-clang (arm64)`.

Past that it needs, in addition to the patch below:

| Flag | Why |
| ---- | --- |
| `-DINPUT_opengl=es2` | otherwise the SDK's OpenGL.framework satisfies desktop GL, and `opengles2` - which requires `NOT QT_FEATURE_opengl_desktop` - loses the condition |
| `-DFEATURE_framework=OFF` | a framework's binary has no file extension and zig cc refuses to link one, with `unrecognized file extension`. Plain dylibs are fine |
| `-DFEATURE_system_*=OFF`, `-DFEATURE_{cups,gssapi,icu,dbus,backtrace}=OFF` | the SDK is headers and stub libraries, not a package manager |

What comes out is a Qt that renders through ANGLE rather than through Metal or
desktop GL, which is the point of the exercise - see *Getting Qt to use ANGLE
on Windows and macOS* below.

### WebAssembly is not one of the targets

zig-cross ships `wasm32-wasi-musl` and `wasm32-emscripten-musl` toolchains, and
they are deliberately not wired up here. Two independent reasons:

**There is no meaningful library to build.** In a browser, WebGL *is* the GPU
API, and ANGLE has no WebGL backend to sit on it. Its WebGPU backend
(`src/libANGLE/renderer/wgpu`) would be the interesting one, since Emscripten
exposes WebGPU — but WebKit strips `third_party/dawn`, so `webgpu/webgpu.h` and
`dawn/dawn_proc_table.h` are simply absent, exactly like the Vulkan headers.
There is no `WGPU.cmake` either. The only artifact that would make sense is the
shader **translator** on its own: useful for validating or translating GLSL ES
in a sandbox, no renderer needed.

**And that translator will not link against zig's wasi libc++.** It does
compile, with `-DEMSCRIPTEN` (ANGLE's `platform.h` maps that to
Linux/POSIX; `__wasi__` alone hits `#error Unsupported platform`),
`-DEGL_NO_PLATFORM_SPECIFIC_TYPES` and `-fno-exceptions`. But ANGLE uses
`std::thread` and `std::mutex` in `common/angleutils.h` and elsewhere, and the
libc++ zig bundles for wasi is built without threading support. Forcing
`-D_LIBCPP_HAS_THREADS=1` gets the headers to cooperate and then fails at link:

```
wasm-ld: error: undefined symbol: std::__1::thread::join()
wasm-ld: error: undefined symbol: std::__1::mutex::~mutex()
wasm-ld: error: undefined symbol: std::__1::__thread_struct::__thread_struct()
```

That is a missing prebuilt library, not a missing flag.

If you do want it, `wasm32-emscripten` is the target to aim at — it is the one
ANGLE already recognises, and Emscripten's libc++ has pthreads (Web Workers
behind a `SharedArrayBuffer`). It needs the emsdk sysroot, which zig does not
bundle, so `zig cc` would have to be pointed at an emsdk install. At that point
emscripten is supplying libc, libc++ and the linker, and zig is only really
supplying clang.

#### What about hand-written WebGL bindings?

There is a nice writeup of
[using Zig for writing OpenGL in browsers](https://tchayen.com/using-zig-for-writing-opengl-in-browsers)
that gets GL running in a page with nothing but
`zig build-lib -target wasm32-freestanding -dynamic`, declaring the `gl*` calls
as imports and wiring them to a `webgl.js` shim on the JavaScript side. It is a
good technique, and it is worth being clear that it solves the opposite problem
to this repository.

That approach is the *caller* of a GL implementation: the module declares the
entry points it wants and the browser's WebGL answers them. ANGLE is the
*implementation* — it only has something to do if it owns a GPU backend
underneath. In a browser it does not: it is already on the far side of that
boundary, since the WebGL such a module calls is, in WebKit and Chromium, ANGLE
running natively in the GPU process. Shipping ANGLE into the wasm module would
be putting a second copy above the first, with nothing for it to draw on.

It also does not shorten the road to the translator. `wasm32-freestanding` is
the leanest wasm target zig has — no libc at all, `#include <stdio.h>` already
fails, and the only wasm libc zig ships is `wasm-wasi-musl`. That works
beautifully for Zig code calling imported functions, and is strictly further
from what a large C++ codebase like ANGLE needs than the wasi target that
already fails above.

### Getting Qt to use ANGLE on Windows and macOS

Out of the box it will not: `qt_feature("opengles2")` is excluded on WIN32, and
`qt_feature("eglfs")` on both WIN32 and APPLE, so Qt finds ANGLE and then
declines to use it. `patches/qtbase-angle-eglfs.patch` removes those
exclusions and fills in what is missing behind them. Against qtbase dev
(6.13.0):

```sh
cd <qtbase> && git apply <zig-angle>/patches/qtbase-angle-eglfs.patch
```

It is 666 added lines over 26 files, and most of it is small:

| Change | Why |
| ------ | --- |
| `opengles2`, `eglfs` feature conditions | drop `NOT WIN32` / `NOT APPLE` |
| `qunixnativeinterface.cpp` built when `UNIX OR QT_FEATURE_egl` | `QEGLContext`'s native interface is *declared* under `QT_CONFIG(egl)` but only *defined* in that Unix-only file, so enabling EGL elsewhere left an undefined symbol. The file is `QT_CONFIG`-guarded throughout, so off Unix only the EGL block survives. |
| eglfs device integration: HWND / CALayer | eglfs owns its native window, and only knew how to make one on Linux. Windows gets a `WS_POPUP`; Apple a `CALayer`, which is what ANGLE's Metal backend checks for. |
| eglfs screen metrics on Windows | the `q_*FromFb` helpers are `#ifdef Q_OS_UNIX`; GDI answers the same questions. |
| eglfs + minimalegl font database, event dispatcher, theme | `QGenericUnixFontDatabase` is the fontconfig-aware subclass of the portable `QFreeTypeFontDatabase`. minimalegl already handled Windows for the dispatcher. Three conditions rather than one: QtGui builds the generic Unix font database and theme for `UNIX AND NOT APPLE`, but the generic Unix event dispatcher for all of `UNIX`, so macOS wants the portable font database *with* the Unix dispatcher. |
| `qopengl.h` includes the Khronos ES headers on macOS | see below. |
| `qcocoaeglcontext.{h,mm}`, new | the same for the `cocoa` plugin, rendering into the window's content `CALayer`. See below. |
| NSOpenGL not built in an ES build | `qcocoaglcontext.mm` is desktop GL and does not compile against ES headers; macOS has no system ES, so an ES build is a third-party implementation reached through EGL. |
| `qwindowseglcontext.{h,cpp}`, new | EGL support in the `windows` plugin, so ordinary decorated desktop windows render through ANGLE. See below. |
| WGL not built in an ES build | `qwindowsglcontext.cpp` is desktop GL and does not compile against ES headers; in an ES build there is nothing for it to do. Same split in the direct2d plugin, which shares the sources. |
| `opengl-dynamic` disabled by `INPUT_opengl=es2` | see below. |
| `eglfs_emu` declines when the emulator is not there | see below. |
| `FindGLESv2.cmake` picks the header it found | see below. |

Three of these look like genuine upstream bugs rather than missing features.
`QEGLContext` being declared everywhere and defined only on Unix is one.

The second is in `qopengl.h`, which in an ES build reads

```c
#if QT_CONFIG(opengles2)
# if defined(Q_OS_IOS) || defined(Q_OS_TVOS)
#   include <OpenGLES/ES3/gl.h>
# elif !defined(Q_OS_DARWIN)      // "uncontrolled" ES2 platforms
#   include <GLES2/gl2.h>
```

macOS is Darwin but neither iOS nor tvOS, so it matches *neither* branch and no
GL header is included at all; `qopenglcontext.h` then fails on `unknown type
name 'GLuint'` long before anything ANGLE-specific is reached. macOS has no
system OpenGL ES, so an ES build there is by definition a third-party
implementation shipping the Khronos headers - the patch lets macOS into that
branch.

The third is `FindGLESv2.cmake`, whose compile test reads

```cmake
#ifdef __APPLE__
#  include <OpenGLES/ES2/gl.h>
```

That is the iOS system framework. Detection therefore looks for a header no ES
implementation on macOS installs, and fails with the library and the headers
both sitting there found. The patch tests whichever of the two it located.

#### EGL in the `windows` plugin

eglfs gets a full screen and nothing else. For ordinary decorated windows the
`windows` plugin has to do it, and in Qt 6 its only OpenGL backend is WGL.
Qt 5 had `qwindowseglcontext.cpp` for exactly this and it went away with ANGLE
support; the abstraction it used did not. `QWindowsStaticOpenGLContext` still
declares `createWindowSurface`/`destroyWindowSurface` "if the windowing system
interface needs explicitly created window surfaces (like EGL)", and
`QWindowsWindow` still creates one lazily and drops it from
`invalidateSurface()` when the HWND is recreated. Only the backend was
missing.

The new one is about 120 lines rather than Qt 5's thousand, because it builds
on `QEGLPlatformContext` - the same QtGui class eglfs uses - instead of
resolving EGL through its own function table. All it adds is a static context
holding the `EGLDisplay`, and `eglSurfaceForPlatformSurface()` asking
`QWindowsWindow` for the surface. One consequence worth noting: the static
context's `createContext()` had to widen from `QWindowsOpenGLContext *` to
`QPlatformOpenGLContext *`, because `QEGLPlatformContext` is a sibling of
`QWindowsOpenGLContext`, not a subclass.

While wiring it up, `QT_FEATURE_dynamicgl` turned out to be on *together with*
`QT_FEATURE_opengles2`. `opengl-dynamic` is disabled by `INPUT_opengl` of `no`
or `desktop`, but never `es2` - which made sense when "dynamic" meant choosing
between desktop GL and ANGLE at runtime, and does not now that both of its
choices are desktop GL. Adding `es2` to that list settles the configuration,
and with WGL out of the build the desktop-only `GL_CONTEXT_CORE_PROFILE_BIT`
workaround goes with it.

```
$ ./qtglwindow.exe
platform  : "windows"
GL_RENDERER: ANGLE (Qualcomm, Qualcomm(R) Adreno(TM) X1-85 GPU, Direct3D11 vs_5_0 ps_5_0)
GL_VERSION : OpenGL ES 3.0 (ANGLE 2.1.28778)
centre pixel: 0 255 0 255
qtglwindow: PASS
```

That is a real on-screen `QWindow` with `QSurface::OpenGLSurface`, cleared and
read back. `QOffscreenSurface` works through the same path - the plugin has no
`createPlatformOffscreenSurface`, so QtGui falls back to a hidden window - and
the GDI backing store still drives raster windows, which is worth checking
because the plugin no longer links `opengl32`.

#### EGL in the `cocoa` plugin

The same gap as on Windows, and the same answer, but without the scaffolding:
`QCocoaIntegration::createPlatformOpenGLContext()` just does
`return new QCocoaGLContext(context)`, with no static-context indirection and
no window-surface hook to fill in. What macOS does have is the important part -
`QNSView` is layer-backed, and `QCocoaWindow::contentLayer()` hands over the
`CALayer` that ANGLE's Metal backend accepts as its `EGLNativeWindowType`.
ANGLE checks it with `-isKindOfClass` and, finding a plain `CALayer`, adds a
`CAMetalLayer` of its own beneath it, set to autoresize with the parent - so
window resizes need no handling at all on Qt's side.

`QCocoaEGLContext` is another `QEGLPlatformContext` subclass. The surface
itself is owned by `QCocoaWindow`, as a `void *` so the EGL headers stay out of
that header, and released in its destructor. Two smaller adjustments came with
it: `QCocoaOffscreenSurface` is a stub, because an `NSOpenGLContext` needs no
drawable to be made current, so an ES build hands out QtGui's `QEGLPbuffer`
instead; and the macOS 26 software-renderer probe in `hasCapability()` is
skipped, since it casts the context to `QCocoaGLContext` to ask a question that
only has an NSOpenGL answer.

Unlike the Windows one, **none of this has been run** - see the macOS note at
the end of this section.

#### eglfs picking `eglfs_emu`

`eglfs_emu` is the Qt Emulator integration and is built whenever OpenGL is,
so on a desktop it was the only device integration plugin present and eglfs
took it - then `screenInit()` reached
`qFatal("EGL library doesn't support Emulator extensions")` and killed the
process. Working around it meant setting `QT_QPA_EGLFS_INTEGRATION=none` on
every run.

The plugin already knows: it resolves `qgsGetDisplays` through
`eglGetProcAddress` and that is null anywhere but the emulator. Returning
nullptr from `create()` is the factory's existing way of declining - the
caller walks its candidate list and ends at the base device integration - so
that is all it takes. The "Failed to load EGL device integration" warning
alongside it became misleading once declining is a normal outcome, so it is
now a debug message.

**Windows is verified end to end** - a Qt application cross-compiled here runs
on the machine's Adreno GPU:

```
$ QT_QPA_PLATFORM=eglfs ./qtglwin.exe
GL_RENDERER: ANGLE (Qualcomm, Adreno(TM) X1-85 GPU, Direct3D11 vs_5_0 ps_5_0, D3D11-31.0.160.0)
GL_VERSION : OpenGL ES 3.0 (ANGLE 2.1.28778)
qtgl: PASS
```

**macOS is built and linked, not run.** qtbase cross-compiles for
`aarch64-macos-none` with both `eglfs` and `cocoa`, and a windowed Qt
application links against it into an arm64 `MH_EXECUTE` resolving Qt and ANGLE
through `@rpath`:

```
cputype 0x100000c filetype 2 (MH_EXECUTE)
dep     @rpath/libQt6Gui.6.dylib
dep     @rpath/libGLESv2.dylib
dep     @rpath/libEGL.dylib
```

Nothing here can execute a macOS binary though, so neither `CALayer` path -
eglfs's fabricated layer nor cocoa's content layer - has ever run. Treat the
macOS side as a starting point rather than a finished port. Building it also
needs the flags under *Cross-building Qt for macOS*.

### Vulkan, from an upstream ANGLE checkout

WebKit's copy cannot build the Vulkan backend: there is no `Vulkan.cmake` source
list, and `vulkan-headers`, `spirv-tools` and `glslang` are stripped to their
licence files. Point `ANGLE_SOURCE_DIR` at an upstream checkout instead and use
the `-vulkan` presets:

```powershell
$env:ANGLE_SOURCE_DIR = "C:\Projects\github\angle-upstream"
cmake --workflow --preset aarch64-linux-gnu-vulkan
```

There is a `<triple>-vulkan` preset for every non-macOS triple, and
`-DANGLE_ENABLE_VULKAN=ON` works on any triple including macOS — there is just
no preset for it, because on macOS it is a strictly longer path to the same
place (see the SDK section below). Configuring it against a tree
with no `Vulkan.cmake` fails with instructions rather than a wall of errors.

**Preparing the upstream checkout.** `gclient sync` pulls gigabytes of Chromium
build infrastructure; almost none of it is needed here. ANGLE carries its own
SPIR-V builder and parser in `src/common/spirv`, vendors volk in
`src/third_party/volk`, and checks the Vulkan internal shaders in pre-compiled
as `vk_internal_shaders_autogen.cpp` — so glslang is a generation-time tool,
not a build dependency. What is actually required is four dependencies at the
revisions pinned in `DEPS`, three of them header-only:

| Path under the checkout                | What for            |
| -------------------------------------- | ------------------- |
| `third_party/vulkan-headers/src`        | `vulkan/vulkan.h`   |
| `third_party/spirv-headers/src`         | SPIR-V grammar      |
| `third_party/vulkan_memory_allocator`   | VMA, header-only    |
| `third_party/spirv-tools/src`           | the one real build  |
| `third_party/zlib`                      | `compression_utils_portable.cc` |

Each is a `git init` + `git fetch --depth 1 <url> <rev>` + `git checkout
FETCH_HEAD` away. Two of them are only reachable from the Chromium mirrors
rather than GitHub, VMA included — its pinned SHA does not exist upstream.
SPIRV-Tools is added with `add_subdirectory`; it generates its grammar tables
with Python, so nothing has to be compiled for the host and it cross-compiles
like any other library.

Then generate the CMake source lists with the converter WebKit ships:

```sh
cp <webkit>/Source/ThirdParty/ANGLE/gni-to-cmake.py .
pip install ply
export PYTHONUTF8=1
python gni-to-cmake.py src/compiler.gni Compiler.cmake
python gni-to-cmake.py src/libGLESv2.gni GLESv2.cmake
python gni-to-cmake.py src/libANGLE/renderer/gl/BUILD.gn GL.cmake --prepend src/libANGLE/renderer/gl/
python gni-to-cmake.py src/libANGLE/renderer/d3d/BUILD.gn D3D.cmake --prepend src/libANGLE/renderer/d3d/
python gni-to-cmake.py src/libANGLE/renderer/metal/BUILD.gn Metal.cmake --prepend src/libANGLE/renderer/metal/
python gni-to-cmake.py src/libANGLE/renderer/vulkan/BUILD.gn Vulkan.cmake --prepend src/libANGLE/renderer/vulkan/
```

That script needs two fixes first, neither of which WebKit hit because it never
generated a Vulkan list. They are in `tools/gni-to-cmake.patch`:

```sh
patch -p1 < <zig-angle>/tools/gni-to-cmake.patch
```


(`PYTHONUTF8=1` is the third thing you need, and is not a patch: without it the
script reads `.gni` files as cp1252 and dies on the first non-ASCII byte.)

* Root-relative GN imports, spelled `//build_overrides/swiftshader.gni`, are
  joined onto the current directory and become UNC paths on Windows. They have
  to resolve against the ANGLE root.
* `foo_sources += bar_sources`, where the right hand side is another list
  variable rather than a literal, emits `list(APPEND foo_sources` and then
  nothing — no items, no closing paren — which swallows the next statement.
  It needs to emit `${bar_sources})`. Exactly one line in the Vulkan GN hits
  this, and it corrupts the whole file.

The patch is against WebKit's copy of the script, which is the one to start
from; the converter itself is Apple's, under the BSD licence in its header.

Unlike WebKit's copy, an upstream checkout has no checked-in `angle_commit.h` or
`ANGLEShaderProgramVersion.h`; `cmake/AngleGeneratedHeaders.cmake` runs ANGLE's
own scripts to produce them into the build tree.

**How Vulkan is loaded.** The build defines `ANGLE_SHARED_LIBVULKAN=1`, which
despite the name selects the volk path: every entry point is a function pointer
resolved at runtime after `vk_renderer.cpp` dlopens the system loader
(`libvulkan.so.1`, `vulkan-1.dll`, `libMoltenVK.dylib`). Without it ANGLE
expects the `vk*` symbols from libvulkan at link time, which a cross build has
no import library for.

**Asking for a Vulkan display on Linux** takes a different attribute from the GL
backend. With no X11, Wayland or GBM compiled in, `CreateVulkanOffscreenDisplay`
is reachable only through `EGL_PLATFORM_ANGLE_NATIVE_PLATFORM_TYPE_ANGLE` set to
`EGL_PLATFORM_SURFACELESS_MESA` — not the `EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE`
the GL backend wants. `tests/angle_smoke.cpp` picks the right one per backend.

### macOS needs an Apple SDK

This is ANGLE's requirement, not a zig limitation, and the distinction is worth
keeping straight. zig cross-compiles ordinary C and C++ to macOS perfectly well
with no SDK at all — it bundles the Darwin libc headers, `libSystem.tbd` and its
own libc++, so threads, `dlopen`, containers and the rest link into a valid
Mach-O against `/usr/lib/libSystem.B.dylib`. What it ships no copy of is Apple's
*frameworks*, and a handful of SDK-only headers alongside them.

ANGLE crosses that line almost at once, in code that does not look
platform-specific: `common/debug.cpp` includes `<os/log.h>` (a plain C header,
so this is not merely an Objective-C problem), `system_utils_apple.cpp` includes
`<CoreServices/…>`, and the Metal backend is Objective-C++ against `Foundation`
and `Metal`. The first two are in `libangle_common_sources`, which even a
translator-only build would need, so there is no useful reduced configuration
that stays on the libc side.

Picking a different renderer does not get you out of it either, because the
requirement sits *below* the backend layer — compiling `debug.cpp` for macOS
with no backend defines at all still fails on `<os/log.h>`. For the record:

* **CGL** (`-DANGLE_ENABLE_CGL=ON`) is Objective-C++ against `Cocoa`,
  `OpenGL` and `QuartzCore`, so it needs the SDK exactly as much as Metal
  does — and OpenGL has been deprecated on macOS since 10.14.
* **Vulkan** builds on macOS from an upstream checkout (`-DANGLE_ENABLE_VULKAN=ON`
  alongside or instead of Metal) but does not avoid the SDK, for two reasons
  stacked on top of each other. ANGLE's macOS Vulkan *display* code is
  Objective-C++ against Cocoa, IOSurface and QuartzCore — `DisplayVkMac.mm`
  will not get past `<Cocoa/Cocoa.h>` — and underneath that the common code
  still wants `<os/log.h>`. Only the portable core, `vk_renderer.cpp`, compiles
  without an SDK. At runtime it would also want MoltenVK, which is itself a
  Metal translation layer, so you end up at GLES → ANGLE → Vulkan → MoltenVK →
  Metal where Metal alone would do. It works; it is just strictly more layers
  and no fewer dependencies.

Point `ANGLE_MACOS_SDK` at a real `MacOSX.sdk`:

```powershell
$env:ANGLE_MACOS_SDK = "D:\sdks\MacOSX15.5.sdk"
cmake --workflow --preset aarch64-macos-none
```

Configuring a macOS target without one fails fast with an explanatory error.
Apple licenses their SDK for use on Apple-branded hardware, so obtaining one is
your call; nothing here downloads it for you.

Attaching the SDK is not simply `-isysroot`. See the comments in
`cmake/AngleMacosSdk.cmake` — in short, `zig cc` ignores `-isysroot` for cross
macOS targets, the SDK has to come *after* zig's own Darwin headers on the
include path (`-isystem`, not `-I`) or the two header sets collide, and a bug in
zig's bundled Apple `math.h` has to be worked around with `-include float.h`.

## Exported symbols

Worth knowing, because getting it wrong produces a library that links cleanly
and exports nothing. The public `gl*` / `egl*` entry points in
`libGLESv2_autogen.cpp` and `libEGL_autogen.cpp` carry no visibility attribute
of their own — they inherit it from the prototype in the Khronos header. ANGLE's
`khrplatform.h` only maps `KHRONOS_APICALL` to `visibility("default")` under
`__ANDROID__`, so on Linux and macOS it expands to nothing and
`-fvisibility=hidden` swallows the entire API.

Upstream's GN build works around this in `angle_gl_visibility_config`; this
build mirrors it, defining `GL_APICALL`, `GL_API` and `EGLAPI` as the visibility
attribute outright on non-Windows targets. On Windows the `.def` files decide
the exported surface, so the same macros are defined empty instead.

The expected result is roughly 828 `gl*` exports from libGLESv2 and 115 `egl*`
from libEGL, which is what `angle.exports` checks.

## zig cc limitations this toolchain works around

These are not ANGLE-specific. They surfaced while cross-compiling other things
with `toolchains/zig-cross.cmake` and are handled there, so anything built
through it inherits the workarounds.

**Precompiled headers do not work.** CMake drives clang with

```sh
-Xclang -emit-pch -x c++-header -o foo.pch -c foo.cxx
```

where `-Xclang -emit-pch` changes the cc1 action so a PCH comes out instead of
an object. zig does not model that: it runs its own step over the result as if
it were an object, and the linker rejects it with `ld.lld: error: foo.o:
unknown file type`. Plain clang accepts the identical command line. Note this
is specifically `-Xclang -emit-pch` together with `-c`; `-x c++-header` alone
is fine. The toolchain sets `CMAKE_DISABLE_PRECOMPILE_HEADERS`; set
`ZIG_ALLOW_PRECOMPILE_HEADERS` to undo that if a later zig fixes it.

**Some mingw import libraries are missing.** zig synthesises Windows import
libraries from the `.def` files it vendors under `lib/libc/mingw`, and that set
is a subset of real mingw-w64's. Two of the missing ones get linked by plain
name in ordinary projects:

```
error: unable to find dynamic system library 'synchronization'
error: unable to find dynamic system library 'runtimeobject'
```

qtbase links both. `synchronization` it links deliberately *before* `kernel32`,
because the same symbols appear in some kernel32 import libraries and resolving
them there makes the process load the wrong DLL at runtime.

Both DLLs are pure forwarders, so a correct import library can be generated
from a `.def` - and zig can do it itself, since it ships a drop-in `lib.exe`:

```sh
zig lib /def:synchronization.def /machine:arm64 /out:libsynchronization.a
```

`cmake/ZigMingwImportLibs.cmake` does that at configure time for Windows
targets and puts the result on the link path, so nothing external is needed.
ANGLE's own build sidesteps the issue differently, by naming the API-set
library `api-ms-win-core-synch-l1-2-0` directly; a third-party project cannot
be asked to do that.

**`-bundle` is not implemented.** CMake links a `MODULE` library on Darwin
with `-bundle`; zig cc reports `argument unused during compilation: '-bundle'`
and links an executable instead, so the first plugin in a build fails with
`undefined symbol: _main`. A dylib is `dlopen()`-able on macOS exactly like a
bundle and plugin loaders do not care which they get, so
`toolchains/zig-darwin-rules.cmake` links `MODULE` libraries with `-shared`.

That file is a `CMAKE_USER_MAKE_RULES_OVERRIDE` rather than part of the
toolchain because `Platform/Darwin.cmake` sets these variables unconditionally
and runs *after* the toolchain file; `CMake<LANG>Information.cmake` includes
the override after that, which is the first point at which a new value sticks.

**Not zig, but next door: install names pick up a Windows separator.** The
Darwin link rules spell the install name
`<SONAME_FLAG> <TARGET_INSTALLNAME_DIR><TARGET_SONAME>`, and CMake produces
`TARGET_INSTALLNAME_DIR` by running `@rpath/` through shell conversion - which
on a Windows host rewrites the separator. Every dylib then identifies itself as
`@rpath\libFoo.dylib`, and a backslash being an ordinary character in a Mach-O
path, nothing linked against it would ever load. `TARGET_SONAME` is a bare
filename and is not converted, so the same rules override folds `@rpath/` into
the soname flag and drops `TARGET_INSTALLNAME_DIR`. The cost is that a custom
`INSTALL_NAME_DIR` stops having an effect - which on this host it could not
have had anyway, there being no `install_name_tool`.

**The SDK version is reported as macOS 27, whatever SDK is attached.**
`AvailabilityInternal.h` as zig ships it hardcodes

```c
#define __MAC_OS_X_VERSION_MAX_ALLOWED __MAC_27_0
```

so every "is the SDK new enough" test answers yes, and code gets compiled
against symbols the SDK has never heard of. Qt's
`QT_APPLE_SDK_EQUAL_OR_ABOVE(MACOS(26))` guard around
`NSAccessibilityLanguageAttribute` is one: the constant is new in macOS 26, the
guard is there precisely so an older SDK skips it, and with a 15.5 SDK the
build still fails on `use of undeclared identifier`.

The whole block is skipped when `__MAC_OS_X_VERSION_MIN_REQUIRED` is already
defined, so the toolchain defines both - the minimum deferring to clang's own
`__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__`, and the maximum taken from the
`Version` in the SDK's `SDKSettings.json`:

```
-D__MAC_OS_X_VERSION_MIN_REQUIRED=__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__
-D__MAC_OS_X_VERSION_MAX_ALLOWED=150500
```

One trap worth knowing while we are here, and not zig's: `CMAKE_<LANG>_FLAGS_INIT`
seeds the cache only on the *first* configure. A build tree first configured
without `ANGLE_MACOS_SDK` caches empty flags, and every configure after that -
SDK or no SDK - silently builds without one, announcing itself much later as
`os/log.h file not found`. The toolchain now refuses such a tree and says to
delete it.

**Some glibc feature macros are exposed below the version that provides the
function.** zig ships a single copy of recent glibc headers and gates the
*declarations* by version, but not every *macro*. `bits/unistd_ext.h` is the
one that bites:

```c
/* zig's copy - no version gate at all */
#ifndef CLOSE_RANGE_CLOEXEC
# define CLOSE_RANGE_CLOEXEC (1U << 2)
#endif
```

zig targets glibc 2.31 by default, where `close_range()` does not exist, yet
the macro is defined. Real glibc introduces both together in 2.34, so the
ordinary idiom

```c
#ifdef CLOSE_RANGE_CLOEXEC
    r = close_range(fd, INT_MAX, CLOSE_RANGE_CLOEXEC);
#endif
```

compiles everywhere except here. qtbase's `qprocess_unix.cpp` does exactly
this. Any `#ifdef` guard around a version-gated glibc function is exposed to
it.

Raise the floor with `-DZIG_GLIBC_VERSION=2.34`, which appends the version to
the triple (`x86_64-linux-gnu.2.34`). The default is left at zig's 2.31 so the
libraries stay portable; only raise it when a dependency demands it, since
2.34 means Ubuntu 22.04 / RHEL 9 or newer.

## Layout

```
CMakeLists.txt               targets, backend selection, install rules
cmake/AngleSources.cmake     loads ANGLE's GN-generated .cmake source lists
cmake/AngleZlib.cmake        fetches and builds a static zlib
cmake/AngleMacosSdk.cmake    attaches a macOS SDK to a zig cross build
cmake/AngleVerify.cmake      script-mode export/linkage checks, run by CTest
cmake/AngleInstall.cmake     headers, pkg-config and the CMake package
cmake/ANGLEConfig.cmake.in   template for find_package(ANGLE)
toolchains/zig-cross.cmake   shared toolchain shim over zig-cross
toolchains/zig-darwin-rules.cmake  Darwin link-rule fixes: -bundle, install names
toolchains/<triple>.cmake    two lines each: set(ZIG_TARGET …) + include
tests/angle_smoke.cpp        consumer test: WebGL-style context, draw, readback
tests/CMakeLists.txt         registers the CTest tests, picks a runner
CMakePresets.json            one configure/build/test/workflow preset per triple
tools/gni-to-cmake.patch     two fixes to WebKit's GN-to-CMake converter
patches/qtbase-angle-eglfs.patch  makes Qt able to use ANGLE on Windows/macOS
```

`cmake/AngleSources.cmake` includes `Compiler.cmake`, `GLESv2.cmake`,
`GL.cmake`, `D3D.cmake`, `Metal.cmake` and `linux.cmake` straight out of the
ANGLE checkout, so the file lists stay in sync with WebKit automatically. Only
the `is_*` / `angle_*` switches those files branch on are set here — none of
WebKit's `WEBKIT_*` CMake machinery is required.

## Knobs

| Variable                    | Meaning                                                     |
| --------------------------- | ----------------------------------------------------------- |
| `ZIG_EXECUTABLE`            | zig to use; otherwise `zig` from `PATH`                      |
| `ZIG_CROSS_DIR`             | zig-cross checkout (default `C:/Projects/github/zig-cross`)  |
| `ANGLE_SOURCE_DIR`          | ANGLE checkout                                               |
| `ANGLE_MACOS_SDK`           | macOS SDK root                                               |
| `ZLIB_SOURCE_DIR`           | existing zlib source tree; skips the download                |
| `ANGLE_ENABLE_D3D11`/`_D3D9`| Windows backends, both `ON`                                  |
| `ANGLE_ENABLE_OPENGL`       | GL backend (WGL on Windows, EGL on Linux), `ON`              |
| `ANGLE_ENABLE_METAL`        | macOS Metal backend, `ON`                                    |
| `ANGLE_ENABLE_CGL`          | macOS CGL backend, `OFF`                                     |
| `ANGLE_BUILD_TESTS`         | build `angle_smoke`, `ON`                                    |
| `ZIG_GLIBC_VERSION`         | pin the glibc floor for `*-linux-gnu`, e.g. `2.34`           |
| `ANGLE_VULKAN_DISPLAY_MODE` | Linux Vulkan display: `offscreen`, `headless` or `simple`    |

Each of `ZIG_EXECUTABLE`, `ZIG_CROSS_DIR` and `ANGLE_MACOS_SDK` also reads the
same-named environment variable.
