# Rules override for macOS targets, applied through CMAKE_USER_MAKE_RULES_OVERRIDE.
#
# Both fixes below have to live here rather than in the toolchain file:
# Platform/Darwin.cmake sets these variables unconditionally and runs after the
# toolchain, while CMake<LANG>Information.cmake includes this file after that -
# the first point at which a new value will stick.

# 1. MODULE libraries as dylibs rather than bundles.
#
# Platform/Darwin.cmake links a MODULE with -bundle, and zig cc does not
# implement it: it reports "argument unused during compilation: '-bundle'" and
# then links an executable, so the first plugin in the build fails with
# "undefined symbol: _main". A dylib is dlopen()-able on macOS exactly like a
# bundle, and plugin loaders (Qt's included) do not care which they get.
foreach (_zig_lang C CXX OBJC OBJCXX)
    set(CMAKE_SHARED_MODULE_CREATE_${_zig_lang}_FLAGS
        "-shared -Wl,-headerpad_max_install_names")
endforeach ()

# 2. @rpath install names that survive a Windows host.
#
# The link rules spell the install name <SONAME_FLAG> <TARGET_INSTALLNAME_DIR><TARGET_SONAME>,
# and CMake produces TARGET_INSTALLNAME_DIR by running "@rpath/" through shell
# conversion - which on a Windows host rewrites the separator. Every dylib then
# identifies itself as "@rpath\libFoo.dylib", and since a backslash is an
# ordinary character in a Mach-O path, nothing that links against it will ever
# load. TARGET_SONAME is a bare filename and is not converted, so folding the
# prefix into the soname flag and dropping TARGET_INSTALLNAME_DIR gets a
# correct install name out of the stock rules.
#
# The cost is that a custom INSTALL_NAME_DIR no longer has any effect; on this
# host it could not be honoured anyway, there being no install_name_tool.
if (CMAKE_HOST_WIN32)
    foreach (_zig_lang C CXX Fortran OBJC OBJCXX)
        set(CMAKE_SHARED_LIBRARY_SONAME_${_zig_lang}_FLAG "-Wl,-install_name,@rpath/")
        foreach (_zig_rule CREATE_SHARED_LIBRARY CREATE_MACOSX_FRAMEWORK)
            string(REPLACE "<SONAME_FLAG> <TARGET_INSTALLNAME_DIR>" "<SONAME_FLAG>"
                _zig_new "${CMAKE_${_zig_lang}_${_zig_rule}}")
            set(CMAKE_${_zig_lang}_${_zig_rule} "${_zig_new}")
        endforeach ()
    endforeach ()
endif ()

unset(_zig_lang)
unset(_zig_rule)
unset(_zig_new)
