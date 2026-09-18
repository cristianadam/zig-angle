# angle_commit.h and ANGLEShaderProgramVersion.h.
#
# WebKit checks both into its ANGLE copy under WebKit/. Upstream generates them
# during the GN build, so for an upstream checkout we run the same scripts into
# the build tree and put that on the include path.
#
# Sets ANGLE_GENERATED_INCLUDE_DIR to whichever directory holds them.

include_guard()

if (EXISTS "${ANGLE_SOURCE_DIR}/WebKit/angle_commit.h")
    set(ANGLE_GENERATED_INCLUDE_DIR "${ANGLE_SOURCE_DIR}/WebKit")
    return()
endif ()

find_package(Python3 REQUIRED COMPONENTS Interpreter)

set(ANGLE_GENERATED_INCLUDE_DIR "${CMAKE_BINARY_DIR}/angle_generated")
file(MAKE_DIRECTORY "${ANGLE_GENERATED_INCLUDE_DIR}")

# commit_id.py reads the git metadata of the ANGLE checkout. It degrades to
# "unknown hash" rather than failing if that is not a git tree, so this is safe
# for a tarball too.
execute_process(
    COMMAND ${Python3_EXECUTABLE} "${ANGLE_SOURCE_DIR}/src/commit_id.py"
            gen "${ANGLE_GENERATED_INCLUDE_DIR}/angle_commit.h"
    WORKING_DIRECTORY "${ANGLE_SOURCE_DIR}"
    RESULT_VARIABLE _rc
    OUTPUT_QUIET
)
if (NOT _rc EQUAL 0)
    message(FATAL_ERROR "zig-angle: commit_id.py failed (${_rc})")
endif ()

# ANGLEShaderProgramVersion.h is an md5 over the sources that affect program
# serialization; it exists so a cached program binary is rejected when the
# compiler that produced it changed. The GN build feeds it a curated file list
# through a response file. The exact membership only has to be deterministic and
# to move when the translator moves, so hash the translator and the shader
# state, which is what actually governs the serialized format.
file(GLOB_RECURSE _program_version_inputs
    "${ANGLE_SOURCE_DIR}/src/compiler/translator/*.cpp"
    "${ANGLE_SOURCE_DIR}/src/compiler/translator/*.h"
    "${ANGLE_SOURCE_DIR}/src/common/PackedEnums.h"
)
list(SORT _program_version_inputs)
string(REPLACE ";" "\n" _program_version_response "${_program_version_inputs}")
set(_response_file "${CMAKE_BINARY_DIR}/angle_program_version.rsp")
file(WRITE "${_response_file}" "${_program_version_response}\n")

execute_process(
    COMMAND ${Python3_EXECUTABLE}
            "${ANGLE_SOURCE_DIR}/src/program_serialize_data_version.py"
            "${ANGLE_GENERATED_INCLUDE_DIR}/ANGLEShaderProgramVersion.h"
            "${_response_file}"
    WORKING_DIRECTORY "${ANGLE_SOURCE_DIR}"
    RESULT_VARIABLE _rc
    OUTPUT_QUIET
)
if (NOT _rc EQUAL 0)
    message(FATAL_ERROR "zig-angle: program_serialize_data_version.py failed (${_rc})")
endif ()

message(STATUS "zig-angle: generated angle_commit.h and ANGLEShaderProgramVersion.h")
