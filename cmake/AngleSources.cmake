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
# GL.cmake and Vulkan.cmake both branch on angle_use_x11, but they mean
# different things by it: GLX for the GL backend, VK_KHR_xcb_surface for
# Vulkan. GLX needs EGL's X11 native types - Display*, Window, Pixmap - which
# come from defining USE_X11 and change the public EGL ABI. Vulkan's XCB
# display does not: it takes the window id as an integer. So this stays off for
# the GL list and is turned on again just before the Vulkan one.
set(angle_use_x11 FALSE)
set(angle_enable_cgl ${ANGLE_ENABLE_CGL})
set(angle_enable_d3d9 ${ANGLE_ENABLE_D3D9})
set(angle_enable_d3d11 ${ANGLE_ENABLE_D3D11})
set(angle_enable_d3d11_compositor_native_window FALSE)
set(angle_enable_cl FALSE)
set(angle_enable_explicit_context FALSE)
set(angle_has_astc_encoder FALSE)
set(angle_enable_unwind_backtrace_support FALSE)

# Vulkan.cmake branches on these. Everything that would need a windowing system
# header is off; the backend reaches the GPU through the loader it dlopens.
set(angle_has_build FALSE)
set(angle_use_gbm FALSE)
set(angle_use_wayland FALSE)
set(angle_use_vulkan_null_display FALSE)
set(angle_enable_swiftshader FALSE)
set(angle_enable_vulkan_validation_layers FALSE)

include(${ANGLE_SOURCE_DIR}/Compiler.cmake)
include(${ANGLE_SOURCE_DIR}/GLESv2.cmake)
include(${ANGLE_SOURCE_DIR}/GL.cmake)
if (EXISTS ${ANGLE_SOURCE_DIR}/linux.cmake)
    include(${ANGLE_SOURCE_DIR}/linux.cmake)   # WebKit-only; upstream has no such file
elseif (is_linux)
    set(angle_dma_buf_sources
        "src/common/linux/dma_buf_utils.cpp"
        "src/common/linux/dma_buf_utils.h")
endif ()
if (is_win)
    include(${ANGLE_SOURCE_DIR}/D3D.cmake)
endif ()
if (ANGLE_ENABLE_VULKAN)
    set(angle_use_x11 ${ANGLE_USE_X11})
    include(${ANGLE_SOURCE_DIR}/Vulkan.cmake)
    set(angle_use_x11 FALSE)
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
