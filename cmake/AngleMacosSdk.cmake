# Attaches a macOS SDK to a zig cross build.
#
# These are directory-level options rather than toolchain CMAKE_<LANG>_FLAGS_INIT
# entries so they are applied exactly once: CMake re-reads a toolchain file for
# every enable_language() call and every try_compile, which makes appending
# there duplicate the flags. Compiler detection does not need the SDK anyway -
# CMake's probe files are trivial.

include_guard()

set(_sdk_include "${ANGLE_MACOS_SDK}/usr/include")
set(_sdk_frameworks "${ANGLE_MACOS_SDK}/System/Library/Frameworks")

# -isysroot is not the way in: zig cc ignores it for cross macOS targets and
# always uses the Darwin headers it bundles. Putting the SDK ahead of those with
# -I does not work either - the two header sets fight over typedef guard macros
# and the SDK's alloca.h fails with "unknown type name 'size_t'". -isystem lands
# the SDK *after* zig's copies, so zig keeps owning libc and libc++ while the
# SDK supplies what zig has not got: os/log.h, CoreServices, and the frameworks.
add_compile_options(
    -isystem "${_sdk_include}"
    -iframework "${_sdk_frameworks}"
)
add_link_options(
    -F "${_sdk_frameworks}"
    -L "${ANGLE_MACOS_SDK}/usr/lib"
)

# Work around a zig header bug on macOS targets. zig's bundled Apple math.h
# does
#
#     #define __need_infinity_nan
#     #include <float.h>
#     #undef __need_infinity_nan
#
# to pick up only INFINITY/NAN. In C++ that #include lands on libc++'s float.h,
# which sets its own _LIBCPP_FLOAT_H guard before forwarding to clang's float.h
# - and clang's float.h, seeing __need_infinity_nan already defined, emits only
# __float_infinity_nan.h and never __float_float.h. The libc++ guard is now set,
# so every later <cfloat> is a no-op and FLT_MAX stays undefined for the rest of
# the translation unit. ANGLE trips over this in OutputGLSLBase.cpp. Reduced:
#
#     #include <cmath>
#     #include <cfloat>
#     float f = FLT_MAX;   // error on *-macos-*, fine on *-linux-*
#
# Force-including float.h first makes clang's version take its complete path
# before anything can ask for the partial one.
add_compile_options(-include float.h)
