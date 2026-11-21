# kvstore: build with the QNX toolchain file; ctest runs each test in the QNX 8.0 guest through
# tools/qnx-run (CMAKE_CROSSCOMPILING_EMULATOR). run_tests.sh does all of this.
cmake_minimum_required(VERSION 3.21)
project(kvstore C)
enable_testing()
set(CMAKE_C_STANDARD 11)
add_compile_options(-Wall -Wextra)
add_library(kv STATIC src/kvserver.c src/kvclient.c)
target_include_directories(kv PUBLIC src)
foreach(t test_basic test_large test_stop)
  add_executable(${t} tests/${t}.c)
  target_link_libraries(${t} kv)
  add_test(NAME ${t} COMMAND ${t})
endforeach()
