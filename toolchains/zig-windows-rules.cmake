#[[
Rules override for Windows targets, applied through CMAKE_USER_MAKE_RULES_OVERRIDE.

CMake compiles a resource script with

    <CMAKE_RC_COMPILER> <DEFINES> <INCLUDES> <FLAGS> /fo <OBJECT> <SOURCE>

and <DEFINES> is every compile definition the target carries. A version
resource - which is what Qt generates for each library and plugin - uses none
of them: it includes <windows.h> and reads _DEBUG, and _DEBUG arrives through
<FLAGS> rather than <DEFINES>.

Normally that is only waste. Here it is a wall. The compilers this toolchain
points CMake at are .cmd wrappers, so every invocation is run by cmd.exe, whose
command line limit is 8191 characters rather than the 32767 Windows itself
allows. qtquick3d's assimp importer plugin carries 94 definitions and 80
include directories, which took the resource command to 8233 and failed with

    The command line is too long.

Dropping <DEFINES> takes it to about 5400. <INCLUDES> stays, because an .rc
may legitimately include a header from the project it belongs to.

The same limit applies to any long command run through those wrappers. The
other place it has been seen is AutoMoc's moc_predefs step, which CMake runs
directly rather than through Ninja and so cannot be given a response file;
there the only lever is shorter paths. Replacing the .cmd wrappers with real
executables would remove the limit everywhere, at the cost of invalidating
every existing build tree, since CMake records the compiler path.
]]
set(CMAKE_RC_COMPILE_OBJECT
    "<CMAKE_RC_COMPILER> <INCLUDES> <FLAGS> /fo <OBJECT> <SOURCE>")
