# Shared entry point for every zig-angle toolchain file.
#
# Each toolchains/<triple>.cmake sets ZIG_TARGET and includes this file, which
# locates the zig-cross checkout and hands off to its zig-toolchain.cmake.
#
#   -DZIG_CROSS_DIR=<path>    zig-cross checkout (default C:/Projects/github/zig-cross)
#   -DZIG_EXECUTABLE=<path>   use this zig instead of whatever is on PATH
#   -DANGLE_MACOS_SDK=<path>  macOS SDK, required for the Metal backend
#
# Each of those also reads the same-named environment variable.

foreach (_var ZIG_CROSS_DIR ZIG_EXECUTABLE ANGLE_MACOS_SDK)
    if (NOT ${_var} AND DEFINED ENV{${_var}})
        set(${_var} "$ENV{${_var}}")
    endif ()
    # Persist into the cache. Otherwise a later reconfigure in a shell without
    # the environment variable set would fall back to a different zig, and CMake
    # would reject the build tree because the compiler changed.
    if (${_var})
        set(${_var} "${${_var}}" CACHE PATH "Resolved by toolchains/zig-cross.cmake" FORCE)
    endif ()
endforeach ()

if (NOT ZIG_CROSS_DIR)
    set(ZIG_CROSS_DIR "C:/Projects/github/zig-cross")
endif ()

if (NOT EXISTS "${ZIG_CROSS_DIR}/cmake/zig-toolchain.cmake")
    message(FATAL_ERROR
        "zig-angle: no zig-toolchain.cmake under ZIG_CROSS_DIR='${ZIG_CROSS_DIR}'. "
        "Pass -DZIG_CROSS_DIR=<path to zig-cross checkout>.")
endif ()

# zig targets glibc 2.31 by default for *-linux-gnu, and a version can be
# pinned by appending it to the triple. Raising the floor is occasionally
# necessary because zig's glibc headers are one copy of a recent glibc with the
# *declarations* version-gated but some *macros* not. bits/unistd_ext.h, for
# instance, defines CLOSE_RANGE_CLOEXEC unconditionally while close_range()
# itself only appears at 2.34 - so the usual "#ifdef CLOSE_RANGE_CLOEXEC then
# call close_range()" reads as available and then fails to compile. qtbase does
# exactly that. Build such projects with -DZIG_GLIBC_VERSION=2.34.
if (NOT ZIG_GLIBC_VERSION AND DEFINED ENV{ZIG_GLIBC_VERSION})
    set(ZIG_GLIBC_VERSION "$ENV{ZIG_GLIBC_VERSION}")
endif ()
if (ZIG_GLIBC_VERSION)
    set(ZIG_GLIBC_VERSION "${ZIG_GLIBC_VERSION}" CACHE STRING
        "glibc version to target for *-linux-gnu" FORCE)
    if (ZIG_TARGET MATCHES "-gnu$")
        set(ZIG_TARGET "${ZIG_TARGET}.${ZIG_GLIBC_VERSION}")
    endif ()
endif ()

# Sets CMAKE_SYSTEM_NAME/PROCESSOR, ZIG_ARCH/ZIG_OS/ZIG_ABI and points the
# compiler, ar, ranlib and rc at zig-cross's wrapper scripts.
include("${ZIG_CROSS_DIR}/cmake/zig-toolchain.cmake")

# zig-cross's wrappers invoke whatever `zig` is first on PATH. When a specific
# zig is requested, swap in equivalent wrappers that hardcode its path so the
# build does not depend on PATH order. (zig ar/ranlib/rc need the subcommand
# baked in, so a wrapper script is unavoidable for those.)
if (ZIG_EXECUTABLE)
    string(MD5 _zig_hash "${ZIG_EXECUTABLE}")
    string(SUBSTRING "${_zig_hash}" 0 8 _zig_hash)
    set(_zig_bin "${CMAKE_CURRENT_LIST_DIR}/../.zig-bin/${_zig_hash}")

    foreach (_tool cc c++ ar ranlib rc)
        set(_wrapper "${_zig_bin}/zig-${_tool}${SCRIPT_SUFFIX}")
        if (NOT EXISTS "${_wrapper}")
            if (SCRIPT_SUFFIX STREQUAL ".cmd")
                file(WRITE "${_wrapper}" "@echo off\r\n\"${ZIG_EXECUTABLE}\" ${_tool} %*\r\n")
            else ()
                file(WRITE "${_wrapper}" "#!/bin/sh\nexec \"${ZIG_EXECUTABLE}\" ${_tool} \"$@\"\n")
                file(CHMOD "${_wrapper}" PERMISSIONS
                     OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE
                     WORLD_READ WORLD_EXECUTE)
            endif ()
        endif ()
    endforeach ()

    set(CMAKE_C_COMPILER   "${_zig_bin}/zig-cc${SCRIPT_SUFFIX}"  -target ${ZIG_TARGET})
    set(CMAKE_CXX_COMPILER "${_zig_bin}/zig-c++${SCRIPT_SUFFIX}" -target ${ZIG_TARGET})
    set(CMAKE_AR           "${_zig_bin}/zig-ar${SCRIPT_SUFFIX}")
    set(CMAKE_RANLIB       "${_zig_bin}/zig-ranlib${SCRIPT_SUFFIX}")
    set(CMAKE_RC_COMPILER  "${_zig_bin}/zig-rc${SCRIPT_SUFFIX}")
endif ()

# zig-cross only wires up C, CXX and RC. ANGLE's Apple backends are
# Objective-C++, and enable_language(OBJC/OBJCXX) would otherwise go looking for
# a clang on the host PATH and compile for the host triple.
set(CMAKE_OBJC_COMPILER   ${CMAKE_C_COMPILER})
set(CMAKE_OBJCXX_COMPILER ${CMAKE_CXX_COMPILER})

# zig cc cannot build precompiled headers. CMake drives clang with
#
#     -Xclang -emit-pch -x c++-header -o foo.pch -c foo.cxx
#
# where -Xclang -emit-pch changes the cc1 action so a PCH comes out instead of
# an object. zig does not model that: it runs its own step over the result as
# if it were an object, and the linker rejects it with
#
#     ld.lld: error: foo.o: unknown file type
#
# Plain clang handles the same command line. Until zig understands the flag,
# any project using this toolchain has to do without PCH - set
# ZIG_ALLOW_PRECOMPILE_HEADERS to override if a future zig fixes it.
if (NOT ZIG_ALLOW_PRECOMPILE_HEADERS)
    set(CMAKE_DISABLE_PRECOMPILE_HEADERS ON)
endif ()

# Unlike plain clang, zig cc emits DWARF unless told not to, and CMake's
# Release/MinSizeRel flags do not pass -g0. Left alone, libGLESv2.so ends up
# around 71 MB of which 65 MB is .debug_*; with this it is under 6 MB.
#
# CMake re-reads a toolchain file once per enable_language(), so the append has
# to be idempotent or the flag piles up.
foreach (_lang C CXX OBJC OBJCXX)
    foreach (_cfg RELEASE MINSIZEREL)
        if (NOT CMAKE_${_lang}_FLAGS_${_cfg}_INIT MATCHES "(^| )-g0( |$)")
            string(APPEND CMAKE_${_lang}_FLAGS_${_cfg}_INIT " -g0")
        endif ()
    endforeach ()
endforeach ()

# zig's set of mingw import libraries is a subset of real mingw-w64's, and
# projects link the missing ones by plain name. Generate them and put them on
# the link path. (ANGLE itself sidesteps this by naming the API-set library
# directly; a third-party project cannot be asked to do that.)
if (ZIG_OS STREQUAL "windows")
    if (ZIG_EXECUTABLE)
        set(ZIG_EXECUTABLE_RESOLVED "${ZIG_EXECUTABLE}")
    else ()
        set(ZIG_EXECUTABLE_RESOLVED "zig")
    endif ()
    include("${CMAKE_CURRENT_LIST_DIR}/../cmake/ZigMingwImportLibs.cmake")
    if (ZIG_MINGW_IMPORT_LIB_DIR)
        foreach (_kind EXE SHARED MODULE)
            if (NOT CMAKE_${_kind}_LINKER_FLAGS_INIT MATCHES "implib-${ZIG_ARCH}")
                string(APPEND CMAKE_${_kind}_LINKER_FLAGS_INIT
                       " \"-L${ZIG_MINGW_IMPORT_LIB_DIR}\"")
            endif ()
        endforeach ()
    endif ()
endif ()

# Apple frameworks are not bundled with zig, so anything past the shader
# translator needs a real macOS SDK (copy MacOSX.sdk over from a Mac). The SDK
# is validated here; the flags that attach it are applied by the project, in
# cmake/AngleMacosSdk.cmake.
if (ZIG_OS STREQUAL "macos" AND ANGLE_MACOS_SDK)
    if (NOT EXISTS "${ANGLE_MACOS_SDK}/System/Library/Frameworks/Foundation.framework")
        message(FATAL_ERROR
            "zig-angle: ANGLE_MACOS_SDK='${ANGLE_MACOS_SDK}' has no "
            "System/Library/Frameworks/Foundation.framework; it does not look "
            "like a macOS SDK root.")
    endif ()
    set(CMAKE_FIND_ROOT_PATH "${ANGLE_MACOS_SDK}")

    # -isysroot is not the way in: zig cc ignores it for cross macOS targets and
    # always uses the Darwin headers it bundles. Putting the SDK ahead of those
    # with -I does not work either - the two header sets fight, and libc++ ends
    # up reporting that it "tried including <ctype.h> but didn't find libc++'s".
    # -isystem lands the SDK *after* zig's copies, so zig keeps owning libc and
    # libc++ while the SDK supplies what zig has not got: os/log.h, CoreServices
    # and every framework.
    #
    # This belongs in the toolchain rather than the project: any target built
    # through it needs the SDK, not just ANGLE.
    foreach (_lang C CXX OBJC OBJCXX)
        if (NOT CMAKE_${_lang}_FLAGS_INIT MATCHES "MacOSX|isysroot|${ANGLE_MACOS_SDK}")
            string(APPEND CMAKE_${_lang}_FLAGS_INIT
                " -isystem \"${ANGLE_MACOS_SDK}/usr/include\""
                " -iframework \"${ANGLE_MACOS_SDK}/System/Library/Frameworks\"")
        endif ()
    endforeach ()
    foreach (_kind EXE SHARED MODULE)
        if (NOT CMAKE_${_kind}_LINKER_FLAGS_INIT MATCHES "${ANGLE_MACOS_SDK}")
            string(APPEND CMAKE_${_kind}_LINKER_FLAGS_INIT
                " -F \"${ANGLE_MACOS_SDK}/System/Library/Frameworks\""
                " -L \"${ANGLE_MACOS_SDK}/usr/lib\"")
        endif ()
    endforeach ()

    # Two of CMake's Darwin link rules need rewriting - -bundle, which zig cc
    # does not implement, and the install name, which a Windows host mangles.
    # See the file for both, and for why they cannot be done here.
    if (NOT CMAKE_USER_MAKE_RULES_OVERRIDE)
        set(CMAKE_USER_MAKE_RULES_OVERRIDE
            "${CMAKE_CURRENT_LIST_DIR}/zig-darwin-rules.cmake")
    endif ()

    # zig's AvailabilityInternal.h hardcodes __MAC_OS_X_VERSION_MAX_ALLOWED to
    # __MAC_27_0 whatever SDK is on the include path, so every "is the SDK new
    # enough" test answers yes and code gets compiled against symbols the SDK
    # has never heard of - Qt reaching for NSAccessibilityLanguageAttribute
    # behind QT_APPLE_SDK_EQUAL_OR_ABOVE(MACOS(26)), for one. That whole block
    # is skipped when __MAC_OS_X_VERSION_MIN_REQUIRED is already defined, so
    # define both: the minimum stays whatever clang worked out for the target,
    # and the maximum becomes the SDK actually attached.
    set(_zig_sdk_version "")
    if (EXISTS "${ANGLE_MACOS_SDK}/SDKSettings.json")
        file(READ "${ANGLE_MACOS_SDK}/SDKSettings.json" _zig_sdk_settings)
        string(JSON _zig_sdk_version ERROR_VARIABLE _zig_sdk_json_error
            GET "${_zig_sdk_settings}" "Version")
    endif ()
    if (NOT _zig_sdk_version AND ANGLE_MACOS_SDK MATCHES "MacOSX([0-9]+\.[0-9]+)")
        set(_zig_sdk_version "${CMAKE_MATCH_1}")
    endif ()
    if (_zig_sdk_version MATCHES "^([0-9]+)\.([0-9]+)")
        math(EXPR _zig_sdk_max "${CMAKE_MATCH_1} * 10000 + ${CMAKE_MATCH_2} * 100")
        foreach (_lang C CXX OBJC OBJCXX)
            if (NOT CMAKE_${_lang}_FLAGS_INIT MATCHES "__MAC_OS_X_VERSION_MAX_ALLOWED")
                string(APPEND CMAKE_${_lang}_FLAGS_INIT
                    " -D__MAC_OS_X_VERSION_MIN_REQUIRED=__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__"
                    " -D__MAC_OS_X_VERSION_MAX_ALLOWED=${_zig_sdk_max}")
            endif ()
        endforeach ()
    else ()
        message(WARNING
            "zig-angle: could not determine the version of the SDK at "
            "'${ANGLE_MACOS_SDK}'. zig will report it as macOS 27 and any "
            "availability-gated code will be compiled against symbols the SDK "
            "may not have.")
    endif ()

    # CMAKE_<LANG>_FLAGS_INIT only seeds the cache on the first configure, so a
    # build tree first configured without the SDK - which fails, but not before
    # caching empty flags - would silently go on building without it, and say
    # so only as "os/log.h file not found".
    foreach (_lang C CXX OBJC OBJCXX)
        if (DEFINED CACHE{CMAKE_${_lang}_FLAGS}
                AND NOT "$CACHE{CMAKE_${_lang}_FLAGS}" MATCHES "${ANGLE_MACOS_SDK}")
            message(FATAL_ERROR
                "zig-angle: this build tree has cached CMAKE_${_lang}_FLAGS that "
                "do not attach '${ANGLE_MACOS_SDK}'. CMake applies a toolchain's "
                "flags only to a fresh cache, so a tree first configured without "
                "the SDK keeps building without it. Delete the build directory "
                "and configure again.")
        endif ()
    endforeach ()

    # zig's bundled Apple math.h asks for a partial <float.h> and poisons
    # libc++'s guard, so FLT_MAX goes missing later in the translation unit.
    # See cmake/AngleMacosSdk.cmake for the full story.
    if (NOT CMAKE_CXX_FLAGS_INIT MATCHES "include float.h")
        foreach (_lang C CXX OBJC OBJCXX)
            string(APPEND CMAKE_${_lang}_FLAGS_INIT " -include float.h")
        endforeach ()
    endif ()
endif ()
