# ANGLE compresses program binaries and frame captures with zlib. No system
# zlib exists for a cross target, so build a small static one from upstream
# source. Point ZLIB_SOURCE_DIR at an existing checkout to build offline.

include_guard()

set(ZLIB_VERSION 1.3.1)
set(ZLIB_SHA256 9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23)

if (NOT ZLIB_SOURCE_DIR)
    include(FetchContent)
    # SOURCE_SUBDIR names a directory that does not exist on purpose: it makes
    # MakeAvailable download and unpack without add_subdirectory()ing zlib's own
    # CMakeLists, whose shared/static and install rules we do not want here.
    FetchContent_Declare(zlib_src
        URL           https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz
        URL_HASH      SHA256=${ZLIB_SHA256}
        SOURCE_SUBDIR zig-angle-no-configure
    )
    FetchContent_MakeAvailable(zlib_src)
    set(ZLIB_SOURCE_DIR "${zlib_src_SOURCE_DIR}")
endif ()

if (NOT EXISTS "${ZLIB_SOURCE_DIR}/zlib.h")
    message(FATAL_ERROR "zig-angle: no zlib.h under ZLIB_SOURCE_DIR='${ZLIB_SOURCE_DIR}'")
endif ()

add_library(angle_zlib STATIC
    "${ZLIB_SOURCE_DIR}/adler32.c"
    "${ZLIB_SOURCE_DIR}/compress.c"
    "${ZLIB_SOURCE_DIR}/crc32.c"
    "${ZLIB_SOURCE_DIR}/deflate.c"
    "${ZLIB_SOURCE_DIR}/gzclose.c"
    "${ZLIB_SOURCE_DIR}/gzlib.c"
    "${ZLIB_SOURCE_DIR}/gzread.c"
    "${ZLIB_SOURCE_DIR}/gzwrite.c"
    "${ZLIB_SOURCE_DIR}/infback.c"
    "${ZLIB_SOURCE_DIR}/inffast.c"
    "${ZLIB_SOURCE_DIR}/inflate.c"
    "${ZLIB_SOURCE_DIR}/inftrees.c"
    "${ZLIB_SOURCE_DIR}/trees.c"
    "${ZLIB_SOURCE_DIR}/uncompr.c"
    "${ZLIB_SOURCE_DIR}/zutil.c"
)
target_include_directories(angle_zlib PUBLIC "${ZLIB_SOURCE_DIR}")
target_compile_definitions(angle_zlib PRIVATE HAVE_UNISTD_H HAVE_STDARG_H)
set_target_properties(angle_zlib PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_options(angle_zlib PRIVATE -w)

if (WIN32)
    # zlib's gz* layer pulls in io.h/unistd.h differences; the mingw headers
    # zig ships provide unistd.h, so the POSIX path above is correct there too.
    target_compile_definitions(angle_zlib PRIVATE _CRT_SECURE_NO_DEPRECATE)
endif ()

add_library(ZLIB::ZLIB ALIAS angle_zlib)
