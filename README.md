# zig-angle

Cross-compiles [ANGLE](https://chromium.googlesource.com/angle/angle) — the copy
vendored in WebKit at `Source/ThirdParty/ANGLE` — with `zig cc` / `zig c++`,
driven by CMake and the toolchain from
[zig-cross](https://github.com/cristianadam/zig-cross).

One Windows host builds Linux, Windows and macOS libraries. The output for each
target is what a consumer of ANGLE actually needs:

```
dist/<triple>/
  include/            EGL/ GLES/ GLES2/ GLES3/ KHR/ GLSLANG/ platform/
                      angle_gl.h  export.h
  lib/                libGLESv2.so / .dylib, libEGL.so / .dylib
                      (Windows: import libs libGLESv2.dll.a, libEGL.dll.a)
  bin/                angle_smoke, the consumer test
                      (Windows: also libGLESv2.dll, libEGL.dll)
```

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
  use, and it is the only one that cross-compiles cleanly: the GLX backend would
  need X11 development headers, which zig does not bundle. The Vulkan backend is
  not an option here at all — WebKit strips `third_party/vulkan-headers`,
  `glslang` and `spirv-tools` down to their licence files.

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
* **Vulkan** is not buildable from this tree on *any* platform, never mind
  macOS. There is no `Vulkan.cmake` source list, and WebKit strips
  `vulkan-headers`, `glslang` and `spirv-tools` to their licence files, with
  `vulkan-loader` and `vulkan-utility-libraries` down to a single
  `README.chromium`. On macOS it would also mean MoltenVK, which is itself a
  Metal translation layer — an extra dependency to avoid a dependency you
  would still need. If you want the Vulkan backend, start from upstream ANGLE,
  whose `DEPS` fetches all of that.

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

## Layout

```
CMakeLists.txt               targets, backend selection, install rules
cmake/AngleSources.cmake     loads ANGLE's GN-generated .cmake source lists
cmake/AngleZlib.cmake        fetches and builds a static zlib
cmake/AngleMacosSdk.cmake    attaches a macOS SDK to a zig cross build
cmake/AngleVerify.cmake      script-mode export/linkage checks, run by CTest
toolchains/zig-cross.cmake   shared toolchain shim over zig-cross
toolchains/<triple>.cmake    two lines each: set(ZIG_TARGET …) + include
tests/angle_smoke.cpp        consumer test: WebGL-style context, draw, readback
tests/CMakeLists.txt         registers the CTest tests, picks a runner
CMakePresets.json            one configure/build/test/workflow preset per triple
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

Each of `ZIG_EXECUTABLE`, `ZIG_CROSS_DIR` and `ANGLE_MACOS_SDK` also reads the
same-named environment variable.
