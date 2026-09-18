# Turns the build into something other projects can actually consume: headers,
# libraries, pkg-config files and a CMake package.
#
# The pkg-config files matter more than they look. Qt finds EGL through
# extra-cmake-modules' FindEGL, which starts with pkg_check_modules(egl) and
# uses the result as HINTS for find_path/find_library; Qt's own FindGLESv2 then
# does the same for GLESv2 and compiles a test program against both. Shipping
# egl.pc and glesv2.pc is what makes that work without hand-feeding Qt paths.

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

set(ANGLE_PACKAGE_VERSION "${ANGLE_VERSION_MAJOR}.${ANGLE_VERSION_MINOR}.${ANGLE_VERSION_PATCH}")

# --- Headers ---------------------------------------------------------------
foreach (_dir IN ITEMS EGL GLES GLES2 GLES3 KHR GLSLANG platform)
    install(DIRECTORY "${ANGLE_SOURCE_DIR}/include/${_dir}"
            DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
            FILES_MATCHING PATTERN "*.h")
endforeach ()
install(FILES
    "${ANGLE_SOURCE_DIR}/include/angle_gl.h"
    "${ANGLE_SOURCE_DIR}/include/export.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")

# --- Libraries -------------------------------------------------------------
install(TARGETS GLESv2 EGL
    RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
    LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")

# --- pkg-config ------------------------------------------------------------
#
# Written relocatably: prefix is derived from the .pc file's own location, so
# moving the install tree (or mounting it at a different path inside a sysroot)
# does not invalidate it.
function(_angle_write_pc _name _lib _description _version _requires)
    set(_content
"prefix=\${pcfiledir}/../..
exec_prefix=\${prefix}
libdir=\${prefix}/${CMAKE_INSTALL_LIBDIR}
includedir=\${prefix}/${CMAKE_INSTALL_INCLUDEDIR}

Name: ${_name}
Description: ${_description}
Version: ${_version}
Requires.private: ${_requires}
Libs: -L\${libdir} -l${_lib}
Cflags: -I\${includedir}
")
    file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/pkgconfig/${_name}.pc" CONTENT "${_content}")
    install(FILES "${CMAKE_CURRENT_BINARY_DIR}/pkgconfig/${_name}.pc"
            DESTINATION "${CMAKE_INSTALL_LIBDIR}/pkgconfig")
endfunction()

# Version numbers follow the convention Mesa uses: the .pc version tracks the
# implementation, not the API level, so consumers comparing against a minimum
# get something meaningful.
_angle_write_pc(egl     EGL     "EGL library for ANGLE (${ANGLE_ENABLED_BACKENDS})"     "${ANGLE_PACKAGE_VERSION}" "glesv2")
_angle_write_pc(glesv2  GLESv2  "OpenGL ES 3.2 library for ANGLE (${ANGLE_ENABLED_BACKENDS})" "${ANGLE_PACKAGE_VERSION}" "")

# --- CMake package ---------------------------------------------------------
configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ANGLEConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/ANGLEConfig.cmake"
    INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/ANGLE"
    PATH_VARS CMAKE_INSTALL_INCLUDEDIR CMAKE_INSTALL_LIBDIR CMAKE_INSTALL_BINDIR)

write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/ANGLEConfigVersion.cmake"
    VERSION "${ANGLE_PACKAGE_VERSION}"
    COMPATIBILITY SameMajorVersion)

install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/ANGLEConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/ANGLEConfigVersion.cmake"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/ANGLE")
