# Standalone, zig-cross-compilable build of the ANGLE copy that ships inside
# WebKit. Produces libGLESv2 / libEGL plus the public EGL/GLES headers for
# Linux, Windows and macOS.
#
#   cmake -B build/x86_64-linux-gnu -G Ninja \
#         --toolchain toolchains/x86_64-linux-gnu.cmake
#   cmake --build build/x86_64-linux-gnu
#   cmake --install build/x86_64-linux-gnu --prefix dist/x86_64-linux-gnu

cmake_minimum_required(VERSION 3.25)

project(zig-angle LANGUAGES C CXX)

# -D wins, then the environment, then WebKit's in-tree copy. The Vulkan
# backend needs this pointed at an upstream checkout instead.
if (DEFINED ENV{ANGLE_SOURCE_DIR})
    set(_angle_source_dir_default "$ENV{ANGLE_SOURCE_DIR}")
else ()
    set(_angle_source_dir_default "C:/Projects/github/WebKit/Source/ThirdParty/ANGLE")
endif ()
set(ANGLE_SOURCE_DIR "${_angle_source_dir_default}"
    CACHE PATH "Path to the ANGLE checkout (WebKit's copy, or upstream for Vulkan)")
set(ZLIB_SOURCE_DIR "" CACHE PATH "Existing zlib source tree; empty means download")

if (NOT EXISTS "${ANGLE_SOURCE_DIR}/GLESv2.cmake")
    message(FATAL_ERROR "zig-angle: ANGLE_SOURCE_DIR='${ANGLE_SOURCE_DIR}' is not an ANGLE checkout")
endif ()

# The Vulkan backend is only reachable from an upstream ANGLE checkout, so it is
# opt-in and orthogonal to the per-platform backend defaults below.
option(ANGLE_ENABLE_VULKAN "Build the Vulkan backend (needs upstream ANGLE)" OFF)
if (ANGLE_ENABLE_VULKAN AND NOT EXISTS "${ANGLE_SOURCE_DIR}/Vulkan.cmake")
    message(FATAL_ERROR
        "zig-angle: ANGLE_ENABLE_VULKAN needs a Vulkan.cmake source list next to "
        "GLESv2.cmake. WebKit's ANGLE copy has none; generate one in an upstream "
        "checkout with:
"
        "  python gni-to-cmake.py src/libANGLE/renderer/vulkan/BUILD.gn Vulkan.cmake "
        "--prepend src/libANGLE/renderer/vulkan/")
endif ()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
# OBJC/OBJCXX need this as much as C/CXX do - without it the Metal backend
# exports the whole of rx::*Mtl from the dylib.
foreach (_lang C CXX OBJC OBJCXX)
    set(CMAKE_${_lang}_VISIBILITY_PRESET hidden)
endforeach ()
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
if (NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif ()

# libEGL has to find its sibling libGLESv2 wherever the pair is unpacked. Bake
# the final rpath in at link time: CMake's usual trick of relinking (or
# patching) during install is not available when cross-compiling, and the
# default build rpath would otherwise leave a Windows path inside an ELF
# RUNPATH.
if (APPLE)
    set(CMAKE_INSTALL_RPATH "@loader_path")
else ()
    set(CMAKE_INSTALL_RPATH "$ORIGIN")
endif ()
set(CMAKE_BUILD_WITH_INSTALL_RPATH ON)

# --- Backend selection ------------------------------------------------------
if (CMAKE_SYSTEM_NAME STREQUAL "Windows")
    option(ANGLE_ENABLE_D3D11 "Build the Direct3D 11 backend" ON)
    option(ANGLE_ENABLE_D3D9  "Build the Direct3D 9 backend"  ON)
    option(ANGLE_ENABLE_OPENGL "Build the desktop GL (WGL) backend" ON)
    set(ANGLE_ENABLE_METAL OFF)
    set(ANGLE_ENABLE_CGL OFF)
elseif (CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    # ANGLE's Apple support is not optional at the source level: even
    # common/debug.cpp reaches for <os/log.h>, and the Metal backend is
    # Objective-C++. None of that exists in the libc zig bundles, so a real
    # macOS SDK has to be supplied.
    if (NOT ANGLE_MACOS_SDK)
        message(FATAL_ERROR
            "zig-angle: a macOS build needs an Apple SDK. Pass "
            "-DANGLE_MACOS_SDK=<path to MacOSX.sdk> (or set the ANGLE_MACOS_SDK "
            "environment variable). zig does not bundle Apple's frameworks.")
    endif ()
    include(AngleMacosSdk)
    enable_language(OBJC)
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 20)

    option(ANGLE_ENABLE_METAL "Build the Metal backend" ON)
    option(ANGLE_ENABLE_CGL "Build the CGL backend" OFF)
    set(ANGLE_ENABLE_OPENGL ${ANGLE_ENABLE_CGL})
    set(ANGLE_ENABLE_D3D11 OFF)
    set(ANGLE_ENABLE_D3D9 OFF)
else ()
    option(ANGLE_ENABLE_OPENGL "Build the desktop GL backend (EGL via dlopen)" ON)
    set(ANGLE_ENABLE_D3D11 OFF)
    set(ANGLE_ENABLE_D3D9 OFF)
    set(ANGLE_ENABLE_METAL OFF)
    set(ANGLE_ENABLE_CGL OFF)
endif ()

include(AngleGeneratedHeaders)
include(AngleSources)
include(AngleZlib)
if (ANGLE_ENABLE_VULKAN)
    include(AngleVulkan)
endif ()

# --- Include paths and preprocessor state ----------------------------------
set(ANGLE_PRIVATE_INCLUDE_DIRECTORIES
    "${ANGLE_GENERATED_INCLUDE_DIR}"      # angle_commit.h, ANGLEShaderProgramVersion.h
    "${ANGLE_SOURCE_DIR}/include"
    "${ANGLE_SOURCE_DIR}/include/KHR"
    "${ANGLE_SOURCE_DIR}/src"
    "${ANGLE_SOURCE_DIR}/src/common/base"
    "${ANGLE_SOURCE_DIR}/src/common/third_party/xxhash"
    "${ANGLE_SOURCE_DIR}/third_party/zlib/google"
)

set(no_gl_prototypes GL_GLES_PROTOTYPES=0 EGL_EGL_PROTOTYPES=0)
set(gl_prototypes
    GL_GLES_PROTOTYPES=1
    EGL_EGL_PROTOTYPES=1
    GL_GLEXT_PROTOTYPES
    EGL_EGLEXT_PROTOTYPES
)

set(ANGLE_DEFINITIONS ANGLE_ENABLE_ESSL ANGLE_ENABLE_GLSL)

# What makes the public gl*/egl* entry points visible in the built library.
#
# On Windows the .def files pin the exported surface, so GL_APICALL/GL_API/
# EGLAPI must expand to nothing - otherwise the Khronos headers decorate the
# definitions with __declspec(dllimport).
#
# Everywhere else the entry points in libGLESv2_autogen.cpp and
# libEGL_autogen.cpp carry no attribute of their own; they inherit visibility
# from the prototype in the Khronos header. ANGLE's own khrplatform.h only maps
# KHRONOS_APICALL to visibility("default") under __ANDROID__, so on Linux and
# macOS it expands to nothing and -fvisibility=hidden swallows the entire API.
# Upstream's GN build works around this in angle_gl_visibility_config by
# defining the macros outright; mirror that.
if (is_win)
    set(_angle_entry_point_prototypes ${no_gl_prototypes})
    set(_angle_gl_visibility GL_APICALL= GL_API=)
    set(_angle_egl_visibility EGLAPI=)
    list(APPEND ANGLE_DEFINITIONS GL_APICALL= GL_API= NOMINMAX)
    # ANGLE's D3D11 backend wants the Windows 10 era SDK surface
    # (IDXGIFactory4, ID3D11Device3, ...), which the mingw-w64 headers zig
    # ships gate behind _WIN32_WINNT.
    list(APPEND ANGLE_DEFINITIONS
        _WIN32_WINNT=0x0A00 WINVER=0x0A00 NTDDI_VERSION=0x0A000000)
else ()
    set(_angle_entry_point_prototypes ${gl_prototypes})
    set(_angle_default_visibility "__attribute__((visibility(\"default\")))")
    set(_angle_gl_visibility
        "GL_APICALL=${_angle_default_visibility}"
        "GL_API=${_angle_default_visibility}"
    )
    set(_angle_egl_visibility "EGLAPI=${_angle_default_visibility}")
endif ()

# --- Per-platform source and dependency selection --------------------------
set(ANGLE_EXTRA_SOURCE_LISTS "")
set(ANGLE_PLATFORM_LIBRARIES "")

if (is_win)
    list(APPEND ANGLE_EXTRA_SOURCE_LISTS
        libangle_gpu_info_util_sources
        libangle_gpu_info_util_win_sources
    )
    if (ANGLE_ENABLE_D3D11)
        list(APPEND ANGLE_EXTRA_SOURCE_LISTS
            d3d11_backend_sources d3d_shared_sources angle_translator_hlsl_sources)
        list(APPEND ANGLE_DEFINITIONS ANGLE_ENABLE_D3D11 ANGLE_ENABLE_HLSL)
        list(APPEND ANGLE_PLATFORM_LIBRARIES dxguid dxgi)
    endif ()
    if (ANGLE_ENABLE_D3D9)
        list(APPEND ANGLE_EXTRA_SOURCE_LISTS
            d3d9_backend_sources d3d_shared_sources angle_translator_hlsl_sources)
        list(APPEND ANGLE_DEFINITIONS ANGLE_ENABLE_D3D9 ANGLE_ENABLE_HLSL)
        list(APPEND ANGLE_PLATFORM_LIBRARIES d3d9)
    endif ()
    if (ANGLE_ENABLE_OPENGL)
        list(APPEND ANGLE_EXTRA_SOURCE_LISTS gl_backend_sources)
        list(APPEND ANGLE_DEFINITIONS ANGLE_ENABLE_OPENGL)
        list(APPEND ANGLE_PLATFORM_LIBRARIES gdi32 opengl32)
    endif ()
    list(APPEND ANGLE_PLATFORM_LIBRARIES user32)

    # common/SimpleMutex.cpp needs WaitOnAddress/WakeByAddressSingle. MSVC gets
    # those from synchronization.lib, which has no mingw equivalent; zig builds
    # import libraries straight from the mingw API-set .def files instead.
    if (MSVC OR ZIG_ABI MATCHES "msvc")
        list(APPEND ANGLE_PLATFORM_LIBRARIES synchronization)
    else ()
        list(APPEND ANGLE_PLATFORM_LIBRARIES api-ms-win-core-synch-l1-2-0)
    endif ()
elseif (is_linux)
    list(APPEND ANGLE_DEFINITIONS
        ANGLE_PLATFORM_LINUX
        EGL_NO_PLATFORM_SPECIFIC_TYPES
        USE_SYSTEM_EGL
    )
    list(APPEND ANGLE_EXTRA_SOURCE_LISTS
        libangle_gpu_info_util_sources
        libangle_gpu_info_util_linux_sources
        angle_dma_buf_sources
    )
    if (ANGLE_ENABLE_OPENGL)
        list(APPEND ANGLE_EXTRA_SOURCE_LISTS gl_backend_sources)
        list(APPEND ANGLE_DEFINITIONS ANGLE_ENABLE_OPENGL)
    endif ()
elseif (is_apple)
    list(APPEND ANGLE_EXTRA_SOURCE_LISTS
        libangle_mac_sources
        libangle_gpu_info_util_sources
        libangle_gpu_info_util_mac_sources
    )
    list(APPEND ANGLE_PLATFORM_LIBRARIES
        "-framework CoreFoundation" "-framework CoreServices" "-framework Foundation")
    if (ANGLE_ENABLE_METAL)
        list(APPEND ANGLE_EXTRA_SOURCE_LISTS
            metal_backend_sources angle_translator_lib_msl_sources)
        list(APPEND ANGLE_DEFINITIONS ANGLE_ENABLE_METAL)
        list(APPEND ANGLE_PLATFORM_LIBRARIES
            "-framework Cocoa" "-framework CoreGraphics" "-framework IOKit"
            "-framework IOSurface" "-framework Metal" "-framework QuartzCore")
    endif ()
    if (ANGLE_ENABLE_CGL)
        list(APPEND ANGLE_EXTRA_SOURCE_LISTS gl_backend_sources)
        list(APPEND ANGLE_DEFINITIONS ANGLE_ENABLE_OPENGL)
        list(APPEND ANGLE_PLATFORM_LIBRARIES "-framework OpenGL")
    endif ()
endif ()

if (ANGLE_ENABLE_VULKAN)
    list(APPEND ANGLE_EXTRA_SOURCE_LISTS
        vulkan_backend_sources
        angle_translator_lib_spirv_sources
        libangle_gpu_info_util_vulkan_sources
    )
    # ANGLE_SHARED_LIBVULKAN is badly named: it selects the volk path, where
    # every Vulkan entry point is a function pointer resolved at runtime after
    # vk_renderer.cpp dlopens the system loader. Without it ANGLE expects the
    # vk* symbols to come from libvulkan at link time, which a cross build has
    # no import library for. volk is vendored in ANGLE itself.
    list(APPEND ANGLE_DEFINITIONS ANGLE_ENABLE_VULKAN ANGLE_SHARED_LIBVULKAN=1)
    # vulkan.h only declares a platform's surface extensions when asked. Linux
    # needs none of them: with no X11, Wayland or GBM compiled in, the only
    # display ANGLE can create there is the surfaceless offscreen one.
    if (is_win)
        list(APPEND ANGLE_DEFINITIONS VK_USE_PLATFORM_WIN32_KHR)
    elseif (is_apple)
        list(APPEND ANGLE_DEFINITIONS VK_USE_PLATFORM_METAL_EXT)
    endif ()
    # vulkan_icd.cpp wants a path for the mock ICD manifest even though nothing
    # here ships one; it is only consulted when a test explicitly asks for the
    # mock driver.
    list(APPEND ANGLE_DEFINITIONS "ANGLE_VK_MOCK_ICD_JSON=\"VkICD_mock_icd.json\"")
    list(APPEND ANGLE_VULKAN_EXTRA_SOURCES "${ANGLE_SOURCE_DIR}/src/third_party/volk/volk.c")
    list(APPEND ANGLE_PRIVATE_INCLUDE_DIRECTORIES ${ANGLE_VULKAN_INCLUDE_DIRECTORIES})
    list(APPEND ANGLE_PLATFORM_LIBRARIES ${ANGLE_VULKAN_LIBRARIES})

    # ANGLE's own SPIR-V builder/parser and the loader shim are plain source
    # files rather than entries in any generated list.
    list(APPEND ANGLE_VULKAN_EXTRA_SOURCES
        "${ANGLE_SOURCE_DIR}/src/common/spirv/angle_spirv_utils.cpp"
        "${ANGLE_SOURCE_DIR}/src/common/spirv/spirv_instruction_builder_autogen.cpp"
        "${ANGLE_SOURCE_DIR}/src/common/spirv/spirv_instruction_parser_autogen.cpp"
        "${ANGLE_SOURCE_DIR}/src/common/vulkan/libvulkan_loader.cpp"
        "${ANGLE_SOURCE_DIR}/src/common/vulkan/vulkan_icd.cpp"
        # Its own GN target, so it is not in vulkan_backend_sources. This is the
        # only translation unit that instantiates VulkanMemoryAllocator.
        "${ANGLE_SOURCE_DIR}/src/libANGLE/renderer/vulkan/vk_mem_alloc_wrapper.cpp"
        # VulkanMemoryAllocator is header-only; vma.cpp is the single TU that
        # instantiates it (Chromium adds it to the upstream checkout).
        "${ANGLE_VMA_DIR}/vma.cpp"
    )
    # Matching VMA's own BUILD.gn. Both function-pointer modes are off because
    # ANGLE hands VMA an explicit vtable of entry points it resolved via volk.
    list(APPEND ANGLE_DEFINITIONS
        VMA_DYNAMIC_VULKAN_FUNCTIONS=0
        VMA_STATIC_VULKAN_FUNCTIONS=0
        VMA_USE_STL_CONTAINERS=1
    )
endif ()

# --- ANGLE core (translator + frontend + backends) -------------------------
ANGLE_COLLECT_SOURCES(ANGLE_CORE_SOURCES
    libangle_common_sources
    libangle_common_shader_state_sources
    angle_preprocessor_sources
    angle_translator_glsl_base_sources
    angle_translator_essl_sources
    angle_translator_essl_symbol_table_sources
    angle_translator_glsl_and_vulkan_base_sources
    angle_translator_glsl_sources
    angle_translator_sources
    libangle_sources
    libangle_image_util_sources
    xxhash_sources
    ${ANGLE_EXTRA_SOURCE_LISTS}
)
if (is_apple)
    ANGLE_COLLECT_SOURCES(_apple_glsl_sources angle_translator_glsl_apple_sources)
    list(APPEND ANGLE_CORE_SOURCES ${_apple_glsl_sources})
endif ()

list(APPEND ANGLE_CORE_SOURCES ${ANGLE_VULKAN_EXTRA_SOURCES})

list(APPEND ANGLE_CORE_SOURCES
    "${ANGLE_SOURCE_DIR}/src/common/angle_version_info.cpp"
    "${ANGLE_SOURCE_DIR}/src/libANGLE/capture/FrameCapture_mock.cpp"
    "${ANGLE_SOURCE_DIR}/src/libANGLE/capture/serialize_mock.cpp"
    "${ANGLE_SOURCE_DIR}/third_party/zlib/google/compression_utils_portable.cc"
)
if (is_win)
    list(APPEND ANGLE_CORE_SOURCES
        "${ANGLE_SOURCE_DIR}/src/libANGLE/renderer/dxgi_format_map_autogen.cpp"
        "${ANGLE_SOURCE_DIR}/src/libANGLE/renderer/dxgi_support_table_autogen.cpp"
    )
endif ()

add_library(ANGLE STATIC ${ANGLE_CORE_SOURCES})
target_include_directories(ANGLE PRIVATE ${ANGLE_PRIVATE_INCLUDE_DIRECTORIES})
target_compile_definitions(ANGLE PRIVATE ${no_gl_prototypes} LIBANGLE_IMPLEMENTATION)
target_compile_definitions(ANGLE PUBLIC ${ANGLE_DEFINITIONS})
target_link_libraries(ANGLE PRIVATE ZLIB::ZLIB ${CMAKE_DL_LIBS})

# --- libGLESv2 --------------------------------------------------------------
ANGLE_COLLECT_SOURCES(GLESV2_SOURCES libglesv2_entry_point_sources libglesv2_sources)

add_library(GLESv2 SHARED ${GLESV2_SOURCES})
target_include_directories(GLESv2 PRIVATE ${ANGLE_PRIVATE_INCLUDE_DIRECTORIES})
target_compile_definitions(GLESv2 PRIVATE
    ${_angle_entry_point_prototypes}
    ${_angle_gl_visibility}
    LIBGLESV2_IMPLEMENTATION
)
target_link_libraries(GLESv2 PRIVATE ANGLE ${ANGLE_PLATFORM_LIBRARIES} ${CMAKE_DL_LIBS})

# --- libEGL -----------------------------------------------------------------
ANGLE_COLLECT_SOURCES(EGL_SOURCES libegl_sources)

add_library(EGL SHARED ${EGL_SOURCES})
target_include_directories(EGL PRIVATE ${ANGLE_PRIVATE_INCLUDE_DIRECTORIES})
target_compile_definitions(EGL PRIVATE
    ${ANGLE_DEFINITIONS}
    ${gl_prototypes}
    ${_angle_egl_visibility}
    LIBEGL_IMPLEMENTATION
)
target_link_libraries(EGL PRIVATE GLESv2 ${CMAKE_DL_LIBS})
set_target_properties(EGL PROPERTIES LINKER_LANGUAGE CXX)

if (is_apple)
    # CMAKE_INSTALL_NAME_DIR is not usable when cross-compiling to Darwin from
    # Windows: CMake runs the directory through ConvertToOutputPath, so
    # "@rpath" reaches the linker as "@rpath\" and the recorded install name
    # becomes "@rpath\libGLESv2.dylib", which no dyld will ever resolve. Turn
    # CMake's -install_name off and write it out here instead.
    foreach (_t IN ITEMS GLESv2 EGL)
        set_property(TARGET ${_t} PROPERTY NO_SONAME ON)
        target_link_options(${_t} PRIVATE
            "-Wl,-install_name,@rpath/$<TARGET_FILE_NAME:${_t}>")
    endforeach ()
endif ()

if (is_win)
    # The .def files name the exports and pin the output basename.
    target_sources(GLESv2 PRIVATE "${ANGLE_SOURCE_DIR}/src/libGLESv2/libGLESv2_autogen.def")
    target_sources(EGL PRIVATE "${ANGLE_SOURCE_DIR}/src/libEGL/libEGL_autogen.def")
    set_target_properties(GLESv2 EGL PROPERTIES PREFIX "" IMPORT_PREFIX "")
    set_target_properties(GLESv2 PROPERTIES OUTPUT_NAME libGLESv2)
    set_target_properties(EGL PROPERTIES OUTPUT_NAME libEGL)

    # PlatformMethods.h keys its dllimport/dllexport off LIBANGLE_IMPLEMENTATION
    # alone, so referencing ANGLEGetDisplayPlatform from a libGLESv2 translation
    # unit marks it dllimport even though libANGLE is linked into this very DLL
    # (LNK4217). The .def file is what decides the exports here, so neuter the
    # decoration instead.
    target_compile_definitions(GLESv2 PRIVATE ANGLE_PLATFORM_EXPORT=)
endif ()

# ANGLE is third-party code; it is not warning-clean against this compiler.
foreach (_t IN ITEMS ANGLE GLESv2 EGL)
    target_compile_options(${_t} PRIVATE -w)
    if (is_apple)
        # ANGLE's Objective-C++ is manual retain/release (mtl_common.h and
        # ObjCPtr.h both branch on !__has_feature(objc_arc)), matching the
        # -fno-objc-arc that upstream's metal BUILD.gn passes.
        target_compile_options(${_t} PRIVATE
            "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fno-objc-arc>")
    endif ()
endforeach ()

# --- Installation -----------------------------------------------------------
# Which backends ended up in the build, for the package metadata.
set(ANGLE_ENABLED_BACKENDS "")
foreach (_b D3D11 D3D9 OPENGL METAL VULKAN)
    if (ANGLE_ENABLE_${_b})
        list(APPEND ANGLE_ENABLED_BACKENDS ${_b})
    endif ()
endforeach ()
list(JOIN ANGLE_ENABLED_BACKENDS ", " ANGLE_ENABLED_BACKENDS)

# ANGLE's own version, so the installed package advertises the API level a
# consumer actually gets rather than a number invented here.
file(STRINGS "${ANGLE_SOURCE_DIR}/src/common/angle_version.h" _angle_version_lines
     REGEX "#define ANGLE_(MAJOR|MINOR)_VERSION ")
string(REGEX MATCH "ANGLE_MAJOR_VERSION ([0-9]+)" _m "${_angle_version_lines}")
set(ANGLE_VERSION_MAJOR "${CMAKE_MATCH_1}")
string(REGEX MATCH "ANGLE_MINOR_VERSION ([0-9]+)" _m "${_angle_version_lines}")
set(ANGLE_VERSION_MINOR "${CMAKE_MATCH_1}")
set(ANGLE_VERSION_PATCH 0)

include(AngleInstall)

option(ANGLE_BUILD_TESTS "Build the angle_smoke consumer test" ON)
set(ANGLE_LLVM_TOOLS_DIR "" CACHE PATH
    "Directory holding llvm-nm/readelf/readobj/objdump, for the static CTest checks")
if (ANGLE_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif ()
