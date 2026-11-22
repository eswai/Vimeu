cmake_minimum_required(VERSION 3.21)
project(fcitx5-vimeu VERSION 0.1.0 LANGUAGES CXX)

# fcitx5 front end for vimeu (DESIGN.md §8). The conversion core is the Swift
# library libvimeu.so built by SwiftPM at the repository root:
#   swift build -c release --product vimeu
# Point VIMEU_CORE_DIR at the directory holding libvimeu.so.

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Fcitx5Core 5.1 REQUIRED)
include(GNUInstallDirs)
include("${FCITX_INSTALL_CMAKECONFIG_DIR}/Fcitx5Utils/Fcitx5CompilerSettings.cmake")

get_filename_component(VIMEU_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(VIMEU_CORE_DIR "${VIMEU_ROOT}/.build/release" CACHE PATH "Directory containing libvimeu.so")
# Where libvimeu.so is installed; baked into the addon's RUNPATH. Derived from
# the prefix on every configure (not cached) so a changed prefix follows.
if(NOT VIMEU_CORE_INSTALL_DIR)
    set(VIMEU_CORE_INSTALL_DIR "${CMAKE_INSTALL_FULL_LIBDIR}/vimeu")
endif()
option(VIMEU_DEV_RUNPATH "Also search VIMEU_CORE_DIR at runtime (development builds)" ON)

add_library(vimeu-core SHARED IMPORTED)
set_target_properties(vimeu-core PROPERTIES
    IMPORTED_LOCATION "${VIMEU_CORE_DIR}/libvimeu.so"
    INTERFACE_INCLUDE_DIRECTORIES "${VIMEU_ROOT}/Sources/CVimeu/include")

add_library(fcitx5-vimeu MODULE src/vimeu-engine.cpp)
set_target_properties(fcitx5-vimeu PROPERTIES PREFIX "")
target_link_libraries(fcitx5-vimeu PRIVATE Fcitx5::Core Fcitx5::Config vimeu-core)
target_compile_options(fcitx5-vimeu PRIVATE -Wall -Wextra)

set(_rpath "${VIMEU_CORE_INSTALL_DIR}")
if(VIMEU_DEV_RUNPATH)
    set(_rpath "${VIMEU_CORE_DIR};${_rpath}")
endif()
set_target_properties(fcitx5-vimeu PROPERTIES
    BUILD_RPATH "${_rpath}" INSTALL_RPATH "${_rpath}" SKIP_BUILD_RPATH OFF)

# Config files go where fcitx5 looks for them. The build tree mirrors the
# install layout so a development fcitx5 can load straight from it:
#   share/fcitx5/addon/vimeu.conf, share/fcitx5/inputmethod/vimeu.conf
configure_file(vimeu-addon.conf.in ${CMAKE_BINARY_DIR}/share/fcitx5/addon/vimeu.conf @ONLY)
configure_file(vimeu-im.conf ${CMAKE_BINARY_DIR}/share/fcitx5/inputmethod/vimeu.conf COPYONLY)
set_target_properties(fcitx5-vimeu PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib/fcitx5)

install(TARGETS fcitx5-vimeu DESTINATION "${FCITX_INSTALL_ADDONDIR}")
install(FILES ${CMAKE_BINARY_DIR}/share/fcitx5/addon/vimeu.conf
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")
install(FILES ${CMAKE_BINARY_DIR}/share/fcitx5/inputmethod/vimeu.conf
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod")
install(FILES "${VIMEU_CORE_DIR}/libvimeu.so" DESTINATION "${VIMEU_CORE_INSTALL_DIR}")

include(CTest)
if(BUILD_TESTING)
    add_subdirectory(test)
endif()
