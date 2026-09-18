# Dependencies of ANGLE's Vulkan backend.
#
# Only reachable with an upstream ANGLE checkout: WebKit strips vulkan-headers,
# spirv-tools and glslang down to their licence files, and never generated a
# Vulkan.cmake source list.
#
# What is actually needed is smaller than it first looks. ANGLE carries its own
# SPIR-V builder and parser in src/common/spirv, the Vulkan internal shaders are
# checked in pre-compiled as vk_internal_shaders_autogen.cpp (so glslang is a
# generation-time tool, not a build dependency), and common/vulkan/
# libvulkan_loader.cpp dlopens the system loader at runtime rather than linking
# it. That leaves three header-only trees and one library to build.

include_guard()

set(ANGLE_VULKAN_HEADERS_DIR "${ANGLE_SOURCE_DIR}/third_party/vulkan-headers/src/include"
    CACHE PATH "Vulkan-Headers include directory")
set(ANGLE_SPIRV_HEADERS_DIR "${ANGLE_SOURCE_DIR}/third_party/spirv-headers/src"
    CACHE PATH "SPIRV-Headers source directory")
set(ANGLE_SPIRV_TOOLS_DIR "${ANGLE_SOURCE_DIR}/third_party/spirv-tools/src"
    CACHE PATH "SPIRV-Tools source directory")
set(ANGLE_VMA_DIR "${ANGLE_SOURCE_DIR}/third_party/vulkan_memory_allocator"
    CACHE PATH "VulkanMemoryAllocator source directory")

foreach (_dep
        "ANGLE_VULKAN_HEADERS_DIR:vulkan/vulkan.h"
        "ANGLE_SPIRV_HEADERS_DIR:include/spirv/unified1/spirv.hpp"
        "ANGLE_SPIRV_TOOLS_DIR:CMakeLists.txt"
        "ANGLE_VMA_DIR:include/vk_mem_alloc.h")
    string(REPLACE ":" ";" _dep "${_dep}")
    list(GET _dep 0 _var)
    list(GET _dep 1 _probe)
    if (NOT EXISTS "${${_var}}/${_probe}")
        message(FATAL_ERROR
            "zig-angle: ANGLE_ENABLE_VULKAN needs ${_var} to contain ${_probe}, but "
            "'${${_var}}' does not. WebKit's ANGLE copy strips these; use an upstream "
            "checkout with its Vulkan dependencies synced, or point ${_var} at one.")
    endif ()
endforeach ()

# SPIRV-Tools generates its grammar tables with Python, so nothing has to be
# compiled for the host and it cross-compiles like any other library.
set(SPIRV-Headers_SOURCE_DIR "${ANGLE_SPIRV_HEADERS_DIR}" CACHE PATH "" FORCE)
set(SPIRV_SKIP_TESTS ON CACHE BOOL "" FORCE)
set(SPIRV_SKIP_EXECUTABLES ON CACHE BOOL "" FORCE)
set(SPIRV_WERROR OFF CACHE BOOL "" FORCE)
set(SPIRV_TOOLS_BUILD_STATIC ON CACHE BOOL "" FORCE)
add_subdirectory("${ANGLE_SPIRV_TOOLS_DIR}" "${CMAKE_BINARY_DIR}/spirv-tools" EXCLUDE_FROM_ALL)

foreach (_t SPIRV-Tools-static SPIRV-Tools-opt)
    if (NOT TARGET ${_t})
        message(FATAL_ERROR "zig-angle: SPIRV-Tools did not define the ${_t} target")
    endif ()
    target_compile_options(${_t} PRIVATE -w)
endforeach ()

set(ANGLE_VULKAN_INCLUDE_DIRECTORIES
    "${ANGLE_VULKAN_HEADERS_DIR}"
    "${ANGLE_SOURCE_DIR}/src/third_party/volk"
    "${ANGLE_VMA_DIR}/include"
    "${ANGLE_SPIRV_HEADERS_DIR}/include"
    "${ANGLE_SPIRV_TOOLS_DIR}"
    "${ANGLE_SPIRV_TOOLS_DIR}/include"
)

set(ANGLE_VULKAN_LIBRARIES SPIRV-Tools-static SPIRV-Tools-opt)
