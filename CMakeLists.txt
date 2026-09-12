cmake_minimum_required(VERSION 3.20)
project(LovenseHaptics CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "REFramework plugins must be 64-bit. Configure with -A x64.")
endif()

# ---------------------------------------------------------------------------
# Lua 5.4.3
#
# REFramework exports no lua_* symbols, so a plugin cannot import them -- it has
# to statically link its own copy and operate on the lua_State* handed to
# on_lua_state_created.
#
# The version MUST stay at 5.4.3 to match the copy REFramework vendors
# (dependencies/lua). REFramework builds it from plain .c sources as a static
# library with stock configuration, so we do exactly the same. Changing the
# version or compiling it as C++ would change the lua_State layout / error
# handling and crash the game.
# ---------------------------------------------------------------------------
include(FetchContent)

FetchContent_Declare(lua
    URL      https://www.lua.org/ftp/lua-5.4.3.tar.gz
    URL_HASH SHA256=f8612276169e3bfcbcfb8f226195bfc6e466fe13042f1076cbde92b7ec96bbfb
    DOWNLOAD_EXTRACT_TIMESTAMP FALSE
)
FetchContent_MakeAvailable(lua)

# Same source list REFramework uses, i.e. everything except the lua/luac CLIs.
set(LUA_SOURCES
    lapi.c lauxlib.c lbaselib.c lcode.c lcorolib.c lctype.c ldblib.c ldebug.c
    ldo.c ldump.c lfunc.c lgc.c linit.c liolib.c llex.c lmathlib.c lmem.c
    loadlib.c lobject.c lopcodes.c loslib.c lparser.c lstate.c lstring.c
    lstrlib.c ltable.c ltablib.c ltm.c lundump.c lutf8lib.c lvm.c lzio.c
)
list(TRANSFORM LUA_SOURCES PREPEND "${lua_SOURCE_DIR}/src/")

add_library(lua_static STATIC ${LUA_SOURCES})
target_include_directories(lua_static PUBLIC "${lua_SOURCE_DIR}/src")
set_target_properties(lua_static PROPERTIES LINKER_LANGUAGE C)

if(MSVC)
    # Lua 5.4.3 is C89-ish and trips a lot of MSVC's C warnings; they're not ours.
    target_compile_options(lua_static PRIVATE /w)
    target_compile_definitions(lua_static PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

# ---------------------------------------------------------------------------
# The plugin itself
# ---------------------------------------------------------------------------
add_library(LovenseHaptics SHARED src/plugin.cpp)

target_include_directories(LovenseHaptics PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/deps/reframework/include")

target_link_libraries(LovenseHaptics PRIVATE lua_static winhttp)

# REFramework loads plugins by filename; no "lib" prefix, keep the .dll name.
set_target_properties(LovenseHaptics PROPERTIES PREFIX "" OUTPUT_NAME "LovenseHaptics")

if(MSVC)
    target_compile_options(LovenseHaptics PRIVATE /W4 /permissive-)
    target_compile_definitions(LovenseHaptics PRIVATE
        _CRT_SECURE_NO_WARNINGS WIN32_LEAN_AND_MEAN NOMINMAX)
    # Static CRT so users don't need the VC++ redistributable installed.
    set_property(TARGET LovenseHaptics PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    set_property(TARGET lua_static PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# Optional: -DGAME_DIR=... to copy straight into the game after a build.
if(GAME_DIR)
    add_custom_command(TARGET LovenseHaptics POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "${GAME_DIR}/reframework/plugins"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:LovenseHaptics>" "${GAME_DIR}/reframework/plugins/"
        COMMENT "Deploying LovenseHaptics.dll to ${GAME_DIR}")
endif()
