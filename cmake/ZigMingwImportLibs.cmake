# Import libraries that mingw-w64 ships but zig does not.
#
# zig synthesises Windows import libraries from the .def files it vendors under
# lib/libc/mingw. That set is a subset of real mingw-w64's, and two of the
# missing ones are linked unconditionally by ordinary projects:
#
#   -lsynchronization  WaitOnAddress / WakeByAddress*  (qtbase links this, and
#                      deliberately before kernel32 - the same symbols appear in
#                      some kernel32 import libraries, and resolving them there
#                      makes the process load the wrong DLL at runtime)
#   -lruntimeobject    the WinRT Ro*/Windows* string APIs
#
# The library *file* name is what -l matches, but the DLL named inside the .def
# is what the loader goes looking for at run time, and those are not the same
# thing here. There is no synchronization.dll or runtimeobject.dll on Windows -
# MSVC's import libraries of those names are umbrellas over an API set and over
# combase. Naming the .def after the link-time library instead produces a
# binary that links perfectly and then dies at startup with
# STATUS_DLL_NOT_FOUND, so each entry below carries its real DLL.
#
# zig ships a drop-in lib.exe that builds an import library from a .def, which
# keeps this free of any dependency on an external LLVM.
#
# Included from toolchains/zig-cross.cmake for Windows targets; sets
# ZIG_MINGW_IMPORT_LIB_DIR.

include_guard()

# lib.exe spells the architectures differently from zig triples.
if (ZIG_ARCH STREQUAL "x86_64")
    set(_zig_implib_machine x64)
elseif (ZIG_ARCH STREQUAL "aarch64")
    set(_zig_implib_machine arm64)
elseif (ZIG_ARCH STREQUAL "x86")
    set(_zig_implib_machine x86)
else ()
    return ()
endif ()

set(ZIG_MINGW_IMPORT_LIB_DIR
    "${CMAKE_CURRENT_LIST_DIR}/../.zig-bin/implib-${ZIG_ARCH}")

# Resolved by the loader through the API set, as MSVC's synchronization.lib
# does; the functions live in kernelbase.
set(_zig_implib_synchronization_dll "api-ms-win-core-synch-l1-2-0.dll")
set(_zig_implib_synchronization_exports
    WaitOnAddress WakeByAddressAll WakeByAddressSingle)

set(_zig_implib_runtimeobject_dll "combase.dll")

set(_zig_implib_runtimeobject_exports
    RoActivateInstance RoGetActivationFactory RoGetApartmentIdentifier
    RoInitialize RoUninitialize RoOriginateError RoOriginateErrorW
    RoOriginateLanguageException RoCaptureErrorContext RoFailFastWithErrorContext
    RoGetErrorReportingFlags RoSetErrorReportingFlags RoClearError
    RoGetMatchingRestrictedErrorInfo RoReportUnhandledError
    RoTransformError RoTransformErrorW
    WindowsCreateString WindowsCreateStringReference WindowsDeleteString
    WindowsDuplicateString WindowsGetStringLen WindowsGetStringRawBuffer
    WindowsIsStringEmpty WindowsCompareStringOrdinal WindowsConcatString
    WindowsPreallocateStringBuffer WindowsPromoteStringBuffer
    WindowsDeleteStringBuffer WindowsReplaceString WindowsStringHasEmbeddedNull
    WindowsSubstring WindowsSubstringWithSpecifiedLength WindowsTrimStringEnd
    WindowsTrimStringStart)

foreach (_lib synchronization runtimeobject)
    set(_implib "${ZIG_MINGW_IMPORT_LIB_DIR}/lib${_lib}.a")
    if (EXISTS "${_implib}")
        continue ()
    endif ()

    file(MAKE_DIRECTORY "${ZIG_MINGW_IMPORT_LIB_DIR}")
    set(_def "${ZIG_MINGW_IMPORT_LIB_DIR}/${_lib}.def")
    list(JOIN _zig_implib_${_lib}_exports "\n" _exports)
    file(WRITE "${_def}"
         "LIBRARY ${_zig_implib_${_lib}_dll}\nEXPORTS\n${_exports}\n")

    execute_process(
        COMMAND "${ZIG_EXECUTABLE_RESOLVED}" lib
                "/def:${_def}" "/machine:${_zig_implib_machine}" "/out:${_implib}"
        RESULT_VARIABLE _rc
        OUTPUT_VARIABLE _out
        ERROR_VARIABLE _out
    )
    if (NOT _rc EQUAL 0 OR NOT EXISTS "${_implib}")
        message(FATAL_ERROR
            "zig-angle: could not generate lib${_lib}.a with 'zig lib' (${_rc}):\n${_out}")
    endif ()
endforeach ()
