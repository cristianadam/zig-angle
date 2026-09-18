# Script-mode checks over the built libraries, run by CTest.
#
# Nothing here executes the artifacts, so it works for every target regardless
# of whether the host can run them. What it guards against is the pair of
# failure modes that produce a library which links perfectly and is still
# useless: no exported entry points (see the visibility note in the README), and
# a libEGL that cannot find its libGLESv2 at load time.
#
#   cmake -DCHECK=exports -DFORMAT=elf -DGLESV2=... -DEGL=... -P AngleVerify.cmake

cmake_minimum_required(VERSION 3.25)

foreach (_required CHECK FORMAT GLESV2 EGL)
    if (NOT DEFINED ${_required})
        message(FATAL_ERROR "AngleVerify: -D${_required} is required")
    endif ()
endforeach ()

foreach (_lib "${GLESV2}" "${EGL}")
    if (NOT EXISTS "${_lib}")
        message(FATAL_ERROR "AngleVerify: no such library: ${_lib}")
    endif ()
endforeach ()

# Runs a tool and returns its stdout, failing the test if the tool itself does.
function(_angle_tool_output _out_var _tool)
    if (NOT _tool OR NOT EXISTS "${_tool}")
        message(FATAL_ERROR "AngleVerify: tool not available: ${_tool}")
    endif ()
    execute_process(
        COMMAND "${_tool}" ${ARGN}
        OUTPUT_VARIABLE _stdout
        ERROR_VARIABLE _stderr
        RESULT_VARIABLE _rc
    )
    if (NOT _rc EQUAL 0)
        message(FATAL_ERROR "AngleVerify: ${_tool} failed (${_rc}): ${_stderr}")
    endif ()
    set(${_out_var} "${_stdout}" PARENT_SCOPE)
endfunction()

function(_angle_count_matches _out_var _text _pattern)
    string(REGEX MATCHALL "${_pattern}" _matches "${_text}")
    list(LENGTH _matches _count)
    set(${_out_var} "${_count}" PARENT_SCOPE)
endfunction()

if (CHECK STREQUAL "exports")
    if (NOT MIN_GL)
        set(MIN_GL 700)
    endif ()
    if (NOT MIN_EGL)
        set(MIN_EGL 100)
    endif ()

    if (FORMAT STREQUAL "pe")
        # The .def files decide the exported surface on Windows.
        _angle_tool_output(_gles_syms "${READOBJ}" --coff-exports "${GLESV2}")
        _angle_tool_output(_egl_syms  "${READOBJ}" --coff-exports "${EGL}")
        set(_gl_pattern "Name: gl[A-Z][A-Za-z0-9_]*")
        set(_egl_pattern "Name: egl[A-Z][A-Za-z0-9_]*")
    else ()
        # ELF needs --dynamic to read .dynsym; Mach-O has only the one table and
        # prefixes every C symbol with an underscore.
        set(_nm_args --defined-only --extern-only)
        if (FORMAT STREQUAL "elf")
            list(APPEND _nm_args --dynamic)
            set(_prefix "")
        else ()
            set(_prefix "_")
        endif ()
        _angle_tool_output(_gles_syms "${NM}" ${_nm_args} "${GLESV2}")
        _angle_tool_output(_egl_syms  "${NM}" ${_nm_args} "${EGL}")
        set(_gl_pattern " T ${_prefix}gl[A-Z][A-Za-z0-9_]*")
        set(_egl_pattern " T ${_prefix}egl[A-Z][A-Za-z0-9_]*")
    endif ()

    _angle_count_matches(_gl_count "${_gles_syms}" "${_gl_pattern}")
    _angle_count_matches(_egl_count "${_egl_syms}" "${_egl_pattern}")

    message(STATUS "libGLESv2 exports ${_gl_count} gl* entry points (need >= ${MIN_GL})")
    message(STATUS "libEGL exports ${_egl_count} egl* entry points (need >= ${MIN_EGL})")

    if (_gl_count LESS MIN_GL)
        message(FATAL_ERROR
            "libGLESv2 exports only ${_gl_count} gl* entry points. Expected at least "
            "${MIN_GL} - the GL_APICALL/GL_API visibility definitions are probably missing.")
    endif ()
    if (_egl_count LESS MIN_EGL)
        message(FATAL_ERROR
            "libEGL exports only ${_egl_count} egl* entry points. Expected at least "
            "${MIN_EGL} - the EGLAPI visibility definition is probably missing.")
    endif ()

elseif (CHECK STREQUAL "linkage")
    if (FORMAT STREQUAL "pe")
        _angle_tool_output(_imports "${READOBJ}" --coff-imports "${EGL}")
        if (NOT _imports MATCHES "libGLESv2\\.dll")
            message(FATAL_ERROR "libEGL.dll does not import libGLESv2.dll")
        endif ()
        message(STATUS "libEGL.dll imports libGLESv2.dll")

    elseif (FORMAT STREQUAL "macho")
        _angle_tool_output(_used "${OBJDUMP}" --macho --dylibs-used "${EGL}")
        # CMake's CMAKE_INSTALL_NAME_DIR goes through ConvertToOutputPath, so on
        # a Windows host it yields "@rpath\" and dyld would never resolve it.
        if (_used MATCHES "@rpath\\\\")
            message(FATAL_ERROR
                "libEGL.dylib has a backslash in an install name:\n${_used}")
        endif ()
        if (NOT _used MATCHES "@rpath/libGLESv2\\.dylib")
            message(FATAL_ERROR
                "libEGL.dylib does not load @rpath/libGLESv2.dylib:\n${_used}")
        endif ()
        message(STATUS "libEGL.dylib loads @rpath/libGLESv2.dylib")

    else ()
        _angle_tool_output(_dynamic "${READELF}" -d "${EGL}")
        if (NOT _dynamic MATCHES "NEEDED[^\n]*libGLESv2\\.so")
            message(FATAL_ERROR "libEGL.so has no NEEDED entry for libGLESv2.so")
        endif ()
        # A leaked build-tree RUNPATH would put a Windows path inside the ELF.
        if (_dynamic MATCHES "R(UN)?PATH[^\n]*[A-Za-z]:[\\\\/]")
            message(FATAL_ERROR
                "libEGL.so has a host path in its RUNPATH:\n${_dynamic}")
        endif ()
        message(STATUS "libEGL.so needs libGLESv2.so, RUNPATH is clean")
    endif ()

else ()
    message(FATAL_ERROR "AngleVerify: unknown CHECK '${CHECK}'")
endif ()
