# angle_smoke deliberately consumes the build the way a downstream project
# would: only the public headers from include/, only libEGL and libGLESv2. It
# does not get ANGLE_PRIVATE_INCLUDE_DIRECTORIES and does not link the ANGLE
# static library, so a header or export missing from the installed tree shows up
# here as a compile or link failure.

add_executable(angle_smoke angle_smoke.cpp)

target_include_directories(angle_smoke PRIVATE "${ANGLE_SOURCE_DIR}/include")
target_link_libraries(angle_smoke PRIVATE EGL GLESv2)

# Put it beside the libraries in the build tree so $ORIGIN (and, on Windows, the
# DLL search path) just works without copying anything. After install it lands
# in bin/ with the libraries in lib/, hence the second rpath entry.
set_target_properties(angle_smoke PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
if (APPLE)
    set_target_properties(angle_smoke PROPERTIES
        INSTALL_RPATH "@loader_path;@loader_path/../lib")
elseif (UNIX)
    set_target_properties(angle_smoke PROPERTIES
        INSTALL_RPATH "$ORIGIN:$ORIGIN/../lib")
endif ()

install(TARGETS angle_smoke RUNTIME DESTINATION bin)

# --- Static checks over the built libraries --------------------------------
#
# These work for every target, because they inspect the binaries rather than
# running them. They need LLVM's binutils, which zig does not ship.
set(_angle_llvm_hints ${ANGLE_LLVM_TOOLS_DIR} $ENV{ANGLE_LLVM_TOOLS_DIR})
foreach (_tool nm readelf readobj objdump)
    string(TOUPPER "${_tool}" _TOOL)
    find_program(ANGLE_LLVM_${_TOOL} NAMES llvm-${_tool} HINTS ${_angle_llvm_hints})
endforeach ()

if (is_win)
    set(_angle_format pe)
elseif (is_apple)
    set(_angle_format macho)
else ()
    set(_angle_format elf)
endif ()

if (ANGLE_LLVM_NM AND ANGLE_LLVM_READELF AND ANGLE_LLVM_READOBJ AND ANGLE_LLVM_OBJDUMP)
    foreach (_check exports linkage)
        add_test(NAME angle.${_check}
            COMMAND ${CMAKE_COMMAND}
                -DCHECK=${_check}
                -DFORMAT=${_angle_format}
                -DGLESV2=$<TARGET_FILE:GLESv2>
                -DEGL=$<TARGET_FILE:EGL>
                -DNM=${ANGLE_LLVM_NM}
                -DREADELF=${ANGLE_LLVM_READELF}
                -DREADOBJ=${ANGLE_LLVM_READOBJ}
                -DOBJDUMP=${ANGLE_LLVM_OBJDUMP}
                -P "${CMAKE_CURRENT_SOURCE_DIR}/../cmake/AngleVerify.cmake")
        set_tests_properties(angle.${_check} PROPERTIES LABELS static)
    endforeach ()
else ()
    message(STATUS
        "zig-angle: llvm-nm/readelf/readobj/objdump not found, skipping the static "
        "export and linkage tests. Pass -DANGLE_LLVM_TOOLS_DIR=<llvm bin dir> to enable them.")
endif ()

# --- Running the smoke test ------------------------------------------------
#
# The target binary usually cannot run on the build host, but often enough it
# can, and then the test is worth far more than static inspection. Two cases are
# handled: a Windows host running a Windows target (ARM64 Windows also runs x64
# and x86 under emulation), and WSL running a Linux target of the same
# architecture.
set(_angle_runner "")
set(_angle_runner_note "")

string(TOLOWER "${CMAKE_HOST_SYSTEM_PROCESSOR}" _host_arch)
if (_host_arch MATCHES "^(amd64|x86_64|x64)$")
    set(_host_arch x86_64)
elseif (_host_arch MATCHES "^(arm64|aarch64)$")
    set(_host_arch aarch64)
elseif (_host_arch MATCHES "^(x86|i[356]86)$")
    set(_host_arch x86)
endif ()

# Architectures each host can execute, most preferred first.
if (_host_arch STREQUAL "aarch64")
    set(_runnable_arches aarch64 x86_64 x86)
elseif (_host_arch STREQUAL "x86_64")
    set(_runnable_arches x86_64 x86)
else ()
    set(_runnable_arches ${_host_arch})
endif ()

if (is_win AND CMAKE_HOST_WIN32 AND ZIG_ARCH IN_LIST _runnable_arches)
    # Runs directly; it sits next to its DLLs.
    set(_angle_runner $<TARGET_FILE:angle_smoke>)
    set(_angle_runner_note "natively on this Windows host")

elseif (is_linux AND CMAKE_HOST_WIN32 AND ZIG_ABI MATCHES "^gnu")
    find_program(ANGLE_WSL_EXECUTABLE NAMES wsl)
    if (ANGLE_WSL_EXECUTABLE)
        # A musl target would need its own loader, and the architecture has to
        # match - WSL does not emulate. Ask the distro what it is.
        execute_process(
            COMMAND "${ANGLE_WSL_EXECUTABLE}" -- uname -m
            OUTPUT_VARIABLE _wsl_arch
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
            RESULT_VARIABLE _wsl_rc)
        if (_wsl_rc EQUAL 0 AND _wsl_arch STREQUAL ZIG_ARCH)
            execute_process(
                COMMAND "${ANGLE_WSL_EXECUTABLE}" wslpath -a "${CMAKE_BINARY_DIR}"
                OUTPUT_VARIABLE _wsl_dir
                OUTPUT_STRIP_TRAILING_WHITESPACE
                ERROR_QUIET
                RESULT_VARIABLE _wslpath_rc)
            if (_wslpath_rc EQUAL 0 AND _wsl_dir)
                set(_angle_runner
                    "${ANGLE_WSL_EXECUTABLE}" --cd "${_wsl_dir}" -- ./angle_smoke)
                set(_angle_runner_note "under WSL (${_wsl_arch})")
            endif ()
        endif ()
    endif ()
endif ()

if (_angle_runner)
    add_test(NAME angle.smoke COMMAND ${_angle_runner})
    set_tests_properties(angle.smoke PROPERTIES
        LABELS runtime
        # angle_smoke returns this when EGL will not come up at all, which says
        # something about the machine rather than about the build.
        SKIP_RETURN_CODE 77
        PASS_REGULAR_EXPRESSION "angle_smoke: PASS")
    message(STATUS "zig-angle: angle.smoke will run ${_angle_runner_note}")
else ()
    message(STATUS
        "zig-angle: no way to execute ${ZIG_TARGET} binaries here, angle.smoke not added")
endif ()
