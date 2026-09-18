# Loads ANGLE's GN-generated CMake source lists and turns them into absolute
# paths. The lists live in the ANGLE checkout and are keyed off `is_*` /
# `angle_*` variables that the WebKit top-level CMakeLists normally sets; we set
# them ourselves so nothing from WebKit's build system is required.

include_guard()

# --- Target identification -------------------------------------------------
set(is_win FALSE)
set(is_linux FALSE)
set(is_apple FALSE)
set(is_mac FALSE)
set(is_ios FALSE)
set(is_android FALSE)
set(is_chromeos FALSE)
set(is_fuchsia FALSE)

if (CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(is_win TRUE)
elseif (CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(is_linux TRUE)
elseif (CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(is_apple TRUE)
    set(is_mac TRUE)
else ()
    message(FATAL_ERROR "zig-angle: unsupported CMAKE_SYSTEM_NAME '${CMAKE_SYSTEM_NAME}'")
endif ()

# --- Feature switches consumed by the generated lists ----------------------
set(angle_is_winuwp FALSE)
set(angle_use_x11 FALSE)                          # Linux uses the dlopen'd EGL backend
set(angle_enable_cgl ${ANGLE_ENABLE_CGL})
set(angle_enable_d3d9 ${ANGLE_ENABLE_D3D9})
set(angle_enable_d3d11 ${ANGLE_ENABLE_D3D11})
set(angle_enable_d3d11_compositor_native_window FALSE)
set(angle_enable_cl FALSE)
set(angle_enable_explicit_context FALSE)
set(angle_has_astc_encoder FALSE)
set(angle_enable_unwind_backtrace_support FALSE)

include(${ANGLE_SOURCE_DIR}/Compiler.cmake)
include(${ANGLE_SOURCE_DIR}/GLESv2.cmake)
include(${ANGLE_SOURCE_DIR}/GL.cmake)
include(${ANGLE_SOURCE_DIR}/linux.cmake)
if (is_win)
    include(${ANGLE_SOURCE_DIR}/D3D.cmake)
endif ()
if (is_apple)
    # Metal.cmake leaves metal_internal_shader_compilation_supported empty, so
    # no metallib is produced here; the backend compiles its internal shaders at
    # runtime from mtl_internal_shaders_src_autogen.h. That is exactly what a
    # cross build needs, since Apple's metal compiler is not available.
    include(${ANGLE_SOURCE_DIR}/Metal.cmake)
endif ()

# ANGLE_COLLECT_SOURCES(<out-var> <list-var>...)
#
# Concatenates the named ANGLE source lists, drops entries that are not
# compilable translation units (headers, .inc, .gni, .def) and rewrites the
# remainder to absolute paths inside ANGLE_SOURCE_DIR.
function(ANGLE_COLLECT_SOURCES _out)
    set(_result "")
    foreach (_list_var IN LISTS ARGN)
        foreach (_file IN LISTS ${_list_var})
            if (_file MATCHES "\.(cpp|cc|c|mm|m)$")
                cmake_path(ABSOLUTE_PATH _file BASE_DIRECTORY "${ANGLE_SOURCE_DIR}"
                           NORMALIZE OUTPUT_VARIABLE _abs)
                list(APPEND _result "${_abs}")
            endif ()
        endforeach ()
    endforeach ()
    list(REMOVE_DUPLICATES _result)
    set(${_out} "${_result}" PARENT_SCOPE)
endfunction()
