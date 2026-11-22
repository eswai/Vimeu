find_package(Fcitx5ModuleTestFrontend REQUIRED)

add_executable(testvimeu testvimeu.cpp)
target_link_libraries(testvimeu PRIVATE Fcitx5::Core Fcitx5::Module::TestFrontend)
target_compile_definitions(testvimeu PRIVATE
    TESTING_BINARY_DIR="${CMAKE_BINARY_DIR}"
    VIMEU_TEST_DIC="${VIMEU_ROOT}/dict/vimeu.dic")
add_dependencies(testvimeu fcitx5-vimeu)
add_test(NAME testvimeu COMMAND testvimeu)
